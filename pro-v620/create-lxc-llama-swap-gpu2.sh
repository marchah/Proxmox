#!/usr/bin/env bash

set -Eeuo pipefail

# This script is intentionally specific (like its CT-120 sibling). It stands up a
# SECOND Radeon Pro V620 service on GPU 2 for the autonomous coding loop: a
# `llama-swap` proxy that hot-swaps between the loop's models — a dedicated coder
# (Qwen3.8-27B) and a reviewer (ThinkingCap-Qwen3.6-27B) — one resident at a time
# (both can't co-reside on one 32 GB card). CT 120's qwen3.6 on GPU 1 stays the
# untouched ops server; the loop's dispatcher is serialized to one task at a time
# so the swap only fires at coder<->reviewer handoffs. Serves an OpenAI-compatible
# API at 0.0.0.0:8080; clients pick the model by name ("qwen3.8-27b" /
# "thinkingcap-27b").
#
# This pair is only the BOOTSTRAP. The live container serves eight models, all
# added by hand to /etc/llama-swap/config.yaml and deliberately not baked here —
# see the note in CLAUDE.md. A rebuild gives you these two and nothing else.
readonly GPU_NAME="Radeon Pro V620"
# This container is pinned to GPU 2 (PCIe-3/chipset slot). GPU 1 (0000:2d:00.0)
# runs CT 120 (qwen3.6 ops). Passthrough binds ONLY GPU 2's DRM nodes — the only
# reboot-stable way to pin one of two IDENTICAL cards (see configure_gpu_passthrough).
readonly GPU_PCI_ADDRESS="${GPU_PCI_ADDRESS:-0000:06:00.0}"    # GPU 2 (PCIe-3/chipset) — the card this container uses
readonly OTHER_GPU_PCI_ADDRESS="${OTHER_GPU_PCI_ADDRESS:-0000:2d:00.0}"  # GPU 1 (PCIe-1/CPU) — runs CT 120, NOT passed through here

# Pinned prebuilt Vulkan llama.cpp release (same as CT 120). llama-swap launches
# this llama-server per model. Bump TAG + SHA256 together from
# https://github.com/ggml-org/llama.cpp/releases (asset llama-<tag>-bin-ubuntu-vulkan-x64.tar.gz).
readonly LLAMACPP_RELEASE_TAG="b10587"
readonly LLAMACPP_ASSET="llama-${LLAMACPP_RELEASE_TAG}-bin-ubuntu-vulkan-x64.tar.gz"
readonly LLAMACPP_ASSET_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMACPP_RELEASE_TAG}/${LLAMACPP_ASSET}"
readonly LLAMACPP_SHA256="1fd5c5edb76e05fa21067c17796ea938cd410500e2cbe18b6483ca031d1fd7cb"

# Pinned llama-swap release (Go proxy). Bump VERSION + SHA256 together from
# https://github.com/mostlygeek/llama-swap/releases (asset llama-swap_<ver>_linux_amd64.tar.gz;
# SHA-256 is in llama-swap_<ver>_checksums.txt).
readonly LLAMASWAP_VERSION="250"
readonly LLAMASWAP_ASSET="llama-swap_${LLAMASWAP_VERSION}_linux_amd64.tar.gz"
readonly LLAMASWAP_ASSET_URL="https://github.com/mostlygeek/llama-swap/releases/download/v${LLAMASWAP_VERSION}/${LLAMASWAP_ASSET}"
readonly LLAMASWAP_SHA256="1675b0bcdb0791f6172d22993ab22a8097c25a0adda4bb8467d2c31871fb77a0"

# --- Coder model: Qwen3.8-27B (dense 27B, multimodal, thinking). Released 2026-08-14
# and adopted the same day: SWE-bench Pro 61.7 vs 53.5 for Qwen3.6-27B, on the one
# SWE-bench variant that covers TS/JS. UD-Q5_K_XL ~20.9 GB. Apache-2.0.
# ⚠️ unsloth REQUANTISED this file on 2026-08-20 (20.2 -> 20.9 GB); the pin below moved
# from revision fdd03b8b to 4ca72078 on 2026-08-22. The chat template is byte-identical
# between the two (sha 12827f24b742ea4e), so only tensor quantisation changed.
# Architecturally IDENTICAL to Qwen3.6-27B (same config.json), so it is a drop-in:
# same KV cost, same footprint, and llama.cpp already supported it on release day.
# ⚠️ Qwen ships NO DFlash drafter for it. Borrowing Qwen3.6-27B's works but only
# partially — acceptance roughly halves and the gain is ~1.34x on code, versus 2.5x
# for a matched pair. That drafter is a live-only addition, not provisioned here:
# its provenance could not be established (the local file matches no published repo).
readonly CODER_REPO="unsloth/Qwen3.8-27B-GGUF"
readonly CODER_FILE="Qwen3.8-27B-UD-Q5_K_XL.gguf"
readonly CODER_SHA256="8601193d3d5760c37fb8ce1b43afebc69df5fb24e1fbc5a547c32e2200305276"
readonly CODER_REVISION="4ca720788d1e01f1bff70c033e0d0028fd02e502"
readonly CODER_ALIAS="qwen3.8-27b-mtp"

# --- Coder accelerators, both bootstrapped so a rebuild matches production ---------------
# Qwen3.8's OWN MTP head as the drafter. A MATCHED drafter is the whole story: 61.7 %
# acceptance vs 28.8 % for Qwen3.6's borrowed DFlash head, worth 1.58x over unaccelerated.
# ⚠️ n-max 2-3 only. Acceptance falls fast as n-max rises AND n>=6 makes the model emit
# degenerate repetition that inflates tok/s — see the sweep notes in CLAUDE.md.
readonly CODER_DRAFT_REPO="a4lg/Qwen3.8-27B-MTP-ONLY-GGUF"
readonly CODER_DRAFT_FILE="Qwen3.8-27B-MTP-ONLY-Q8_0.gguf"
readonly CODER_DRAFT_SHA256="674d0fc3b2b09c48cf77fbab0aba39b9c4ee538bd240fa87c1f13044260f7d7b"
readonly CODER_DRAFT_REVISION="2476d11971c63a9185686ab4ab0d311506d192b0"
readonly CODER_DRAFT_NMAX="${CODER_DRAFT_NMAX:-2}"

# Vision projector. Qwen3.8-27B is multimodal and WITHOUT this the server answers
# "image input is not supported" while the caller carries on regardless — a silent failure
# mode that once cost a 3-hour agent run reasoning about screenshots it never received.
# Measured cost on this card: +1.11 GiB VRAM, no GTT spill, text-only decode 32.2 -> 32.0
# tok/s with BYTE-IDENTICAL output, and MTP stays active on image requests (6/6 accepted).
# ⚠️ VRAM is the binding constraint (2.12 GiB headroom at ctx 65536). If it ever runs out,
# `--mmproj-device none` keeps the projector on CPU for zero VRAM.
readonly CODER_MMPROJ_REPO="unsloth/Qwen3.8-27B-GGUF"
readonly CODER_MMPROJ_FILE="mmproj-F16.gguf"
readonly CODER_MMPROJ_LOCAL="Qwen3.8-27B-mmproj-F16.gguf"   # renamed: /models/hf is shared
readonly CODER_MMPROJ_SHA256="cbb841a9ee0636b2ec172f5bb8df2ea8dfeb01e90fe7c6126581d662a0b4e43e"
readonly CODER_CTX="${CODER_CTX:-65536}"           # explicit — `auto`/--fit over-commits, see below
readonly CODER_NPREDICT="${CODER_NPREDICT:-32768}" # thinking model — 8k truncates mid-reason

# ⚠️ DO NOT SET CTX BACK TO `auto`. `auto` makes llamaswap-guarded-serve pass `--fit on`
# instead of --ctx-size, so llama-server loads the model's native maximum and shrinks it
# to what it *calculates* will fit. On RADV/Vulkan that calculation OVER-COMMITS, and the
# excess does not fail — amdgpu silently places it in GTT (host RAM reached over PCIe).
# The result is a server that starts clean, passes /health, reports a huge n_ctx, and
# then runs an order of magnitude slow because every token streams weights/KV across the
# bus. GPU 2 sits in the chipset x4 slot, which makes it worse.
# Measured on CT 123, 2026-08-15, qwen3.8-27b-dflash, same box same day:
#            --fit on (n_ctx 156416)   ctx 65536      ratio
#   prefill      41.9 tok/s             294.0 tok/s    7.0x
#   decode        2.0 tok/s              23.7 tok/s   11.8x
#   VRAM/GTT   28.93 GiB + 5.83 GiB    25.66 GiB + 0.33 GiB
# It ran that way in production for a day: coding-loop requests in the journal took
# 25-45 MINUTES each. The plain twin at ctx 65536 gives 321.2 / 17.55 tok/s, and that
# 17.55 reproduces the 17.6 recorded for this model unaccelerated — i.e. 65536 restores
# exactly the documented behaviour, and DFlash is worth 1.35x decode on top of it.
# The earlier note here listed the values --fit RESOLVED to (ornith 262144, thinkingcap
# 217088, qwen3.6-35b-a3b 212224, qwen3.8-27b 170240, qwen3.6-27b 167936,
# qwen3.8-27b-dflash 156416, qwen3.6-27b-dflash 149248, muse-glimmer 131072). Those were
# never verified to FIT — they are what the broken calculation returned. Treat them as a
# record of the bug, not as targets.
# ⚠️ The llamaswap-guarded-serve guard does NOT catch this. It only fails loudly when the
# GPU is missing entirely (CPU/software fallback). A GTT spill keeps every layer nominally
# "on GPU", so the guard passes. Verify a new ctx by hand after loading the model:
#   cat /sys/bus/pci/devices/0000:06:00.0/mem_info_{vram_used,gtt_used}
# gtt_used must stay small (~0.3 GiB is normal host-visible scratch); hundreds of MB is
# fine, GiB means the context is too big for this card. Raise ctx only with that check.

# --- Reviewer model: ThinkingCap-Qwen3.6-27B — a Qwen3.6-27B fine-tune that cuts
# thinking tokens ~46% out-of-domain for -0.8 points of macro accuracy, evaluated with
# 5 seeds and 95% CIs against the base model under identical settings. Q4_K_M ~16.8 GB.
# Apache-2.0. Reasoning-per-token is what a reviewer is paid for.
# ⚠️ This model was previously dropped from the loop for "running away". That was
# measured inside a loop with NO coding harness and an uncapped output; its own
# headline result is that thinking-trace truncation falls 2.9% -> 0.4%. It is
# reinstated deliberately, with --n-predict capped below.
readonly REVIEWER_REPO="bottlecapai/ThinkingCap-Qwen3.6-27B-GGUF"
readonly REVIEWER_FILE="ThinkingCap-Qwen3.6-27B-Q4_K_M.gguf"
readonly REVIEWER_SHA256="b0651e28555bde7d2459ce99f091319b1a547143463e8d49f2aa7f572675fe67"
readonly REVIEWER_REVISION="2ea7e9b3495fefff365b3e1d23fa79cd5f74e7ee"
readonly REVIEWER_ALIAS="thinkingcap-27b"
readonly REVIEWER_CTX="${REVIEWER_CTX:-65536}"           # explicit — see the --fit over-commit note above
readonly REVIEWER_NPREDICT="${REVIEWER_NPREDICT:-32768}" # thinking model — 8k truncates mid-reason

readonly SWAP_SERVER_BIND="0.0.0.0"
readonly SWAP_SERVER_PORT="8080"

VMID="${VMID:-123}"
LXC_HOSTNAME="${LXC_HOSTNAME:-gpu2}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"
ROOT_STORAGE="${ROOT_STORAGE:-local-lvm}"
ROOT_SIZE_GB="${ROOT_SIZE_GB:-32}"
MODELS_STORAGE="${MODELS_STORAGE:-local-lvm}"
MODELS_SIZE_GB="${MODELS_SIZE_GB:-150}"   # room for both GGUFs (~44 GB) + a swap-pool add later
MEMORY_MB="${MEMORY_MB:-16384}"
SWAP_MB="${SWAP_MB:-4096}"
CORES="${CORES:-8}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
# Fixed MAC so the dnsmasq reservation (10.10.10.123 gpu2) is deterministic.
MAC="${MAC:-BC:24:11:C0:DE:23}"
PASSWORD="${PASSWORD:-}"
START_ON_BOOT="${START_ON_BOOT:-1}"

usage() {
  cat <<'USAGE'
Create an Ubuntu LXC running llama-swap on GPU 2 of a dual-V620 host — the
autonomous coding loop's model server (swaps a coder + a reviewer model).

Fixed target:
  GPU:    Radeon Pro V620 GPU 2 (0000:06:00.0) — GPU 1 runs CT 120 (qwen3.6 ops)
  Engine: llama-swap (Go proxy) launching llama.cpp llama-server per model
  Models: qwen3.8-27b-mtp (Qwen3.8-27B coder, MTP-accelerated + vision)
          + thinkingcap-27b (ThinkingCap-Qwen3.6-27B, reviewer)
          — bootstrap pair only; the live container serves four (2026-08-22), rest by hand
  API:    0.0.0.0:8080 (OpenAI-compatible; pick model by name)

Run this script on the Proxmox host as root. Defaults to VMID 123 / hostname gpu2.

Useful overrides:
  VMID=123 LXC_HOSTNAME=gpu2 ./create-lxc-llama-swap-gpu2.sh
  GPU_PCI_ADDRESS=0000:06:00.0 ./create-lxc-llama-swap-gpu2.sh
  CODER_CTX=131072 REVIEWER_CTX=65536 ./create-lxc-llama-swap-gpu2.sh

Notes:
  Privileged (GPU passthrough). Only ONE model is resident at a time (both
  ~21.7 GB can't co-reside on 32 GB) — a request for a different model swaps it
  in (~5-30 s cold load). Keep the loop dispatcher at concurrency 1 so the swap
  only happens at coder<->reviewer handoffs.
USAGE
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }
require_root() { [[ ${EUID} -eq 0 ]] || die "run this script as root on the Proxmox host"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
template_ref() { printf '%s:vztmpl/%s\n' "${TEMPLATE_STORAGE}" "${TEMPLATE}"; }

download_template_if_missing() {
  local template_path="/var/lib/vz/template/cache/${TEMPLATE}"
  [[ -f ${template_path} ]] && return
  log "Downloading LXC template ${TEMPLATE}"
  pveam update
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
}

assert_vmid_available() {
  if pct status "${VMID}" >/dev/null 2>&1; then
    die "VMID ${VMID} already exists (destroy the existing CT ${VMID} or set VMID=)"
  fi
}

assert_gpu_devices_exist() {
  [[ -d /dev/dri/by-path ]] || die "/dev/dri/by-path not found; DRM by-path symlinks missing (udev not populating them?)"
  [[ -e "/dev/dri/by-path/pci-${GPU_PCI_ADDRESS}-render" ]] || \
    die "GPU 2 render node (${GPU_PCI_ADDRESS}) not found at /dev/dri/by-path/pci-${GPU_PCI_ADDRESS}-render; is the card present and amdgpu-bound?"
}

create_container() {
  local ostemplate rootfs net0
  local -a create_args
  ostemplate="$(template_ref)"
  rootfs="${ROOT_STORAGE}:${ROOT_SIZE_GB}"
  net0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},hwaddr=${MAC},type=veth"

  log "Creating LXC ${VMID} (${LXC_HOSTNAME}) on ${GPU_NAME} GPU 2 (${GPU_PCI_ADDRESS})"
  create_args=(
    "${VMID}" "${ostemplate}"
    --hostname "${LXC_HOSTNAME}"
    --cores "${CORES}" --memory "${MEMORY_MB}" --swap "${SWAP_MB}"
    --rootfs "${rootfs}" --net0 "${net0}"
    --features "nesting=1,keyctl=1"
    --unprivileged 0
    --onboot "${START_ON_BOOT}"
    --ostype ubuntu
  )
  [[ -n ${PASSWORD} ]] && create_args+=(--password "${PASSWORD}")
  pct create "${create_args[@]}"
}

configure_gpu_passthrough() {
  local conf_file dri_major render_link card_link render_node card_node
  log "Configuring single-GPU passthrough: only GPU 2 (${GPU_PCI_ADDRESS})"
  conf_file="/etc/pve/lxc/${VMID}.conf"
  # Resolve GPU 2's DRM nodes by PCI address via the udev-stable by-path symlinks;
  # bind-mount the symlink (kernel resolves it at each start, follows the physical
  # card across reboots) at the node's REAL name.
  render_link="/dev/dri/by-path/pci-${GPU_PCI_ADDRESS}-render"
  card_link="/dev/dri/by-path/pci-${GPU_PCI_ADDRESS}-card"
  [[ -e ${render_link} ]] || die "render node for GPU 2 (${GPU_PCI_ADDRESS}) not found at ${render_link}; is the card present and amdgpu-bound?"
  # CRITICAL: mount at the node's REAL name (GPU 2 = renderD128/card0 on this host),
  # NOT a renamed node. Inside the LXC, /sys/class/drm shows the HOST's names and
  # RADV correlates /dev/dri/<name> to /sys/class/drm/<name> for DRM auth; a renamed
  # node -> `amdgpu_get_auth failed` -> RADV can't init -> llama.cpp silently runs
  # on CPU. Keep /dev name == /sys name.
  render_node="$(basename "$(readlink -f "${render_link}")")"
  card_node="$(basename "$(readlink -f "${card_link}")")"
  dri_major="$(stat -Lc '%t' "${render_link}" 2>/dev/null || true)"
  [[ -n ${dri_major} ]] || die "could not determine DRM major for ${render_link}"
  {
    printf '\n# Single-GPU passthrough for llama-swap Vulkan: ONLY GPU 2 (%s).\n' "${GPU_PCI_ADDRESS}"
    printf '# GPU 1 (%s) runs CT 120 and is NOT passed through here.\n' "${OTHER_GPU_PCI_ADDRESS}"
    printf 'lxc.cgroup2.devices.allow: c %d:* rwm\n' "0x${dri_major}"
    printf 'lxc.mount.entry: %s dev/dri/%s none bind,optional,create=file\n' "${render_link}" "${render_node}"
    printf 'lxc.mount.entry: %s dev/dri/%s none bind,optional,create=file\n' "${card_link}" "${card_node}"
  } >>"${conf_file}"
}

add_models_mount() {
  log "Adding local /models mount point (${MODELS_SIZE_GB}G)"
  pct set "${VMID}" -mp0 "${MODELS_STORAGE}:${MODELS_SIZE_GB},mp=/models,backup=0"
}

start_container() { log "Starting LXC ${VMID}"; pct start "${VMID}"; }

wait_for_container() {
  log "Waiting for container startup"
  for _ in {1..60}; do
    pct exec "${VMID}" -- test -d /run/systemd/system >/dev/null 2>&1 && return
    sleep 2
  done
  die "container did not become ready in time"
}

run_in_container() { pct exec "${VMID}" -- "$@"; }

install_swap_stack() {
  local models_manifest assets_manifest coder_extra
  # Non-served files: downloaded + verified, but they get no llama-swap entry because they
  # are loaded alongside a target via --model-draft / --mmproj.
  # repo|file|sha256|revision|localname
  assets_manifest="$(printf '%s|%s|%s|%s|%s\n%s|%s|%s|%s|%s\n' \
    "${CODER_DRAFT_REPO}" "${CODER_DRAFT_FILE}" "${CODER_DRAFT_SHA256}" "${CODER_DRAFT_REVISION}" "${CODER_DRAFT_FILE}" \
    "${CODER_MMPROJ_REPO}" "${CODER_MMPROJ_FILE}" "${CODER_MMPROJ_SHA256}" "${CODER_REVISION}" "${CODER_MMPROJ_LOCAL}")"

  # EXTRA_ARGS for the coder: reasoning format + MTP speculation + vision.
  coder_extra="--reasoning-format auto"
  coder_extra+=" --spec-type draft-mtp --model-draft /models/hf/${CODER_DRAFT_FILE}"
  coder_extra+=" --spec-draft-n-max ${CODER_DRAFT_NMAX} --spec-draft-ngl 99"
  coder_extra+=" --mmproj /models/hf/${CODER_MMPROJ_LOCAL}"

  # repo|file|sha256|revision|ctx|alias|npredict|extra_args  (one line per model)
  models_manifest="$(printf '%s|%s|%s|%s|%s|%s|%s|%s\n%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${CODER_REPO}" "${CODER_FILE}" "${CODER_SHA256}" "${CODER_REVISION}" "${CODER_CTX}" "${CODER_ALIAS}" "${CODER_NPREDICT}" "${coder_extra}" \
    "${REVIEWER_REPO}" "${REVIEWER_FILE}" "${REVIEWER_SHA256}" "${REVIEWER_REVISION}" "${REVIEWER_CTX}" "${REVIEWER_ALIAS}" "${REVIEWER_NPREDICT}" "--reasoning-format auto")"

  log "Installing Vulkan deps + llama.cpp ${LLAMACPP_RELEASE_TAG} + llama-swap ${LLAMASWAP_VERSION}"
  run_in_container bash -lc "apt-get update"
  run_in_container bash -lc "DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git jq tar libatomic1 libgomp1 mesa-vulkan-drivers libvulkan1 vulkan-tools libglvnd0 libgl1 libglx0 libegl1 python3 python3-venv sudo"
  run_in_container bash -lc "useradd --create-home --shell /bin/bash llamacpp || true"
  run_in_container bash -lc "usermod -aG video,render llamacpp 2>/dev/null || usermod -aG video llamacpp || true"
  run_in_container bash -lc "install -d -o llamacpp -g llamacpp /models /models/hf"
  run_in_container bash -lc "install -d /opt/llamacpp /opt/llama-swap /etc/llama-swap"

  pct exec "${VMID}" -- bash -s -- \
    "${LLAMACPP_ASSET_URL}" "${LLAMACPP_SHA256}" \
    "${LLAMASWAP_ASSET_URL}" "${LLAMASWAP_SHA256}" \
    "${SWAP_SERVER_BIND}" "${SWAP_SERVER_PORT}" \
    "${models_manifest}" "${assets_manifest}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
LLAMACPP_ASSET_URL="$1"; LLAMACPP_SHA256="$2"
LLAMASWAP_ASSET_URL="$3"; LLAMASWAP_SHA256="$4"
SWAP_BIND="$5"; SWAP_PORT="$6"
MODELS_MANIFEST="$7"; ASSETS_MANIFEST="${8:-}"

# 1. llama.cpp (llama-server + libs) — the engine llama-swap launches per model.
if [[ ! -x /opt/llamacpp/current/llama-server ]]; then
  t="$(mktemp)"
  curl --fail --show-error --silent --location --output "$t" "$LLAMACPP_ASSET_URL"
  printf '%s  %s\n' "$LLAMACPP_SHA256" "$t" | sha256sum --check -
  tar -xzf "$t" -C /opt/llamacpp
  rm -f "$t"
  d="$(dirname "$(find /opt/llamacpp -name llama-server -type f | head -1)")"
  ln -sfn "$d" /opt/llamacpp/current
fi

# 2. llama-swap binary.
if [[ ! -x /opt/llama-swap/llama-swap ]]; then
  t="$(mktemp)"
  curl --fail --show-error --silent --location --output "$t" "$LLAMASWAP_ASSET_URL"
  printf '%s  %s\n' "$LLAMASWAP_SHA256" "$t" | sha256sum --check -
  tar -xzf "$t" -C /opt/llama-swap
  rm -f "$t"
  [[ -x /opt/llama-swap/llama-swap ]] || ln -sfn "$(find /opt/llama-swap -name llama-swap -type f | head -1)" /opt/llama-swap/llama-swap
fi

# 3. HF downloader (service user owns /models/hf).
if [[ ! -x /home/llamacpp/.venv/bin/hf ]]; then
  sudo -u llamacpp python3 -m venv /home/llamacpp/.venv
  sudo -u llamacpp /home/llamacpp/.venv/bin/pip install --upgrade pip 'huggingface_hub[cli]'
fi

# 3b. Guarded serve wrapper — every llama-swap model cmd goes through this. It
# fails LOUD if RADV can't see the pinned GPU (GPU 2), instead of letting
# llama.cpp silently fall back to CPU when the passed-through DRM node no longer
# matches /sys (renderD*/card* renumber after a reboot / GPU add-remove / kernel
# change). Runs with the unit's VK_ICD_FILENAMES (RADV-only) so a match is the
# real V620, not llvmpipe. Centralizes the (identical) llama-server flags; the
# per-model config passes only model path / ${PORT} / ctx / alias.
cat >/usr/local/bin/llamaswap-guarded-serve <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
MODEL="$1"; PORT="$2"; CTX="$3"; ALIAS="$4"; NPREDICT="${5:--1}"   # NPREDICT default -1 = unlimited

# LLAMACPP_DIR pins ONE model entry to a different llama.cpp build without moving the
# /opt/llamacpp/current symlink that every other entry shares. Set it per-model with
# `env LLAMACPP_DIR=... ` in the llama-swap cmd. Needed when a model's architecture landed
# upstream after the pinned build (e.g. muse_glimmer, merged in b10342 — b10308 cannot load it).
# LD_LIBRARY_PATH is set to exactly that dir rather than prepended to the unit's inherited
# value, so a newer build never resolves a .so from the older one.
LS="${LLAMACPP_DIR:-/opt/llamacpp/current}"
export LD_LIBRARY_PATH="${LS}"

# EXTRA_ARGS appends extra llama-server flags (e.g. --model-draft for speculative decoding).
# Deliberately word-split via read -ra so a multi-flag string works.
EXTRA=()
if [[ -n "${EXTRA_ARGS:-}" ]]; then read -ra EXTRA <<< "${EXTRA_ARGS}"; fi

# Require the AMD V620 (RADV) SPECIFICALLY — a bare "Vulkan" match would also accept a
# software device (llvmpipe/lavapipe) and defeat the guard. Belt-and-suspenders with the
# unit's RADV-only VK_ICD_FILENAMES.
if ! "${LS}/llama-server" --list-devices 2>/dev/null | grep -qiE 'V620|RADV'; then
  echo "FATAL: the V620 (RADV) is not visible to llama.cpp on GPU 2 — RADV failed to init the GPU (would run on CPU/software)." >&2
  echo "CT 123's /dev/dri passthrough likely no longer matches /sys (renderD*/card* renumber after a" >&2
  echo "reboot / GPU add-remove / kernel change). Re-resolve GPU 2's two lxc.mount.entry lines in" >&2
  echo "/etc/pve/lxc/123.conf and restart the CT." >&2
  exit 1
fi
# --n-predict caps tokens generated per request (-1 = unlimited). Bound it (e.g. 8192) so a model that
# runs away can't fill its whole ctx window and stall the loop.
# ⚠️ CORRECTED 2026-08-22: this used to claim "the loop's models are non-thinking so 8k is
# ample", which contradicted CODER_NPREDICT's own comment above and is simply false.
# Qwen3.8-27B IS a thinking model and its default effort runs away: measured 8000 tokens /
# 32,901 chars of reasoning with `content` STILL EMPTY. The bound below is a backstop, not a
# fix — reasoning is controlled per-request by the client (see the reasoning matrix in
# CLAUDE.md) or server-side via --reasoning-budget.
# CTX=auto omits --ctx-size so llama.cpp sizes the window itself via --fit. ⚠️ Kept only
# for A/B testing — it is NOT a safe default on this card. --fit over-commits on
# RADV/Vulkan and the overflow lands silently in GTT (host RAM over PCIe), costing ~7x
# prefill and ~12x decode with no error anywhere. Pass an explicit integer instead, and
# confirm mem_info_gtt_used stays small after the model loads. Full measurements and the
# verification recipe are in the CODER_CTX block near the top of this script.
CTX_ARGS=(--ctx-size "${CTX}")
if [[ "${CTX}" == "auto" ]]; then CTX_ARGS=(--fit on); fi

# --metrics exposes Prometheus counters at GET /metrics on the UPSTREAM port (without it
# that route returns 501, which is what /upstream/<model>/metrics answered before). CT 120
# has carried this since it was built; GPU 2 did not, so this box could report throughput
# only by timing a synthetic request. That is how the --fit GTT spill above went unnoticed
# for a day — prompt_per_second / predicted_per_second is exactly the signal that would
# have shown 2 tok/s, and nothing was collecting it.
# ⚠️ Same caveats as CT 120: these are counters SINCE PROCESS START. On this host they are
# even less durable, because llama-swap unloads and reloads models on demand — every swap
# resets them. Treat a scrape as "since this model was last loaded", never as a total, and
# do NOT wire it into CT 121's token ledger (the `hermes_accounted` source already covers
# anything Hermes sends here; see the token-accounting note in CLAUDE.md).
exec "${LS}/llama-server" --model "${MODEL}" --host 127.0.0.1 --port "${PORT}" \
  --n-gpu-layers 99 "${CTX_ARGS[@]}" --parallel 1 --flash-attn on \
  --batch-size 4096 --ubatch-size 1024 --jinja --reasoning-format none \
  --metrics \
  --n-predict "${NPREDICT}" --alias "${ALIAS}" ${EXTRA[@]+"${EXTRA[@]}"}
EOS
chmod 755 /usr/local/bin/llamaswap-guarded-serve

# 4. Download + verify each model, and build the llama-swap config.yaml. Each
# model's `cmd` runs the guarded wrapper on llama-swap's auto-assigned ${PORT}
# (literal in the YAML — llama-swap substitutes it), --parallel 1 (single
# serialized consumer). Only one model is loaded at a time (default swap).
CONFIG=/etc/llama-swap/config.yaml
{
  printf 'healthCheckTimeout: 500\n'
  printf 'logLevel: info\n'
  printf 'models:\n'
} > "$CONFIG"

# Non-served assets first: a drafter/projector referenced by a model entry must already be
# on disk when llama-swap starts that entry.
while IFS='|' read -r repo file sha rev localname; do
  [[ -n "$repo" ]] || continue
  ap="/models/hf/${localname}"
  if [[ ! -f "$ap" ]]; then
    sudo -u llamacpp /home/llamacpp/.venv/bin/hf download "$repo" "$file" --revision "$rev" --local-dir /models/hf
    # /models/hf is shared by every model, so a generic upstream name (mmproj-F16.gguf) is
    # renamed to something unambiguous.
    [[ "$file" == "$localname" ]] || mv "/models/hf/${file}" "$ap"
  fi
  printf '%s  %s\n' "$sha" "$ap" | sha256sum --check -
done <<< "$ASSETS_MANIFEST"

while IFS='|' read -r repo file sha rev ctx alias npredict extra; do
  [[ -n "$repo" ]] || continue
  mp="/models/hf/${file}"
  if [[ ! -f "$mp" ]]; then
    sudo -u llamacpp /home/llamacpp/.venv/bin/hf download "$repo" "$file" --revision "$rev" --local-dir /models/hf
  fi
  printf '%s  %s\n' "$sha" "$mp" | sha256sum --check -
  {
    printf '  %s:\n' "$alias"
    printf '    checkEndpoint: /health\n'
    printf '    cmd: |\n'
    # single-quoted format => ${PORT} stays literal for llama-swap to substitute
    if [[ -n "$extra" ]]; then
      printf '      env EXTRA_ARGS="%s" /usr/local/bin/llamaswap-guarded-serve %s ${PORT} %s %s %s\n' \
        "$extra" "$mp" "$ctx" "$alias" "$npredict"
    else
      printf '      /usr/local/bin/llamaswap-guarded-serve %s ${PORT} %s %s %s\n' "$mp" "$ctx" "$alias" "$npredict"
    fi
  } >> "$CONFIG"
done <<< "$MODELS_MANIFEST"

chown -R llamacpp:llamacpp /models/hf

# 5. systemd unit. LD_LIBRARY_PATH + the RADV ICD are set on the service so every
# llama-server llama-swap spawns inherits them (pin RADV so it can't bind llvmpipe;
# the CT-120 silent-CPU-fallback lesson).
RADV_ICD="$(ls /usr/share/vulkan/icd.d/radeon_icd*.json 2>/dev/null | head -1)"
# Fail rather than ship a service with an EMPTY VK_ICD_FILENAMES: without the RADV pin the
# loader enumerates every ICD (incl. software lavapipe) and the guard above loses its teeth.
[ -n "$RADV_ICD" ] || { echo "FATAL: RADV Vulkan ICD not found (/usr/share/vulkan/icd.d/radeon_icd*.json) — is mesa-vulkan-drivers installed? Refusing to install an unpinned service." >&2; exit 1; }
cat >/etc/systemd/system/llama-swap.service <<SERVICE
[Unit]
Description=llama-swap (GPU 2 coder/reviewer models) on Radeon Pro V620
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=llamacpp
Group=llamacpp
Environment=HOME=/home/llamacpp
Environment=LD_LIBRARY_PATH=/opt/llamacpp/current
Environment=VK_ICD_FILENAMES=${RADV_ICD}
ExecStart=/opt/llama-swap/llama-swap --config /etc/llama-swap/config.yaml --listen ${SWAP_BIND}:${SWAP_PORT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now llama-swap.service

# 6. Wait for the proxy to answer /v1/models (lists the pool WITHOUT loading a
# model — a model loads lazily on first inference, verified separately).
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${SWAP_PORT}/v1/models" >/dev/null 2>&1; then
    echo "llama-swap up; models:"; curl -fsS "http://127.0.0.1:${SWAP_PORT}/v1/models" | (jq -r '.data[].id' 2>/dev/null || cat)
    exit 0
  fi
  sleep 2
done
echo "llama-swap did not answer /v1/models in time" >&2
journalctl -u llama-swap.service --no-pager -n 40 >&2 || true
exit 1
CONTAINER_SCRIPT
}

print_summary() {
  local ip
  ip="$(pct exec "${VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  log "Done"
  printf 'LXC: %s (%s)\n' "${VMID}" "${LXC_HOSTNAME}"
  printf 'GPU pin: %s (GPU 2) only; GPU 1 (%s) runs CT 120\n' "${GPU_PCI_ADDRESS}" "${OTHER_GPU_PCI_ADDRESS}"
  printf 'Engine: llama-swap %s launching llama.cpp %s (Vulkan)\n' "${LLAMASWAP_VERSION}" "${LLAMACPP_RELEASE_TAG}"
  if [[ -n ${ip} ]]; then
    printf 'llama-swap endpoint: http://%s:%s/v1  (also http://%s:%s/v1 by dnsmasq name)\n' "${ip}" "${SWAP_SERVER_PORT}" "${LXC_HOSTNAME}" "${SWAP_SERVER_PORT}"
  fi
  printf 'Models (pick by name): %s (%s), %s (%s)\n' "${CODER_ALIAS}" "${CODER_FILE}" "${REVIEWER_ALIAS}" "${REVIEWER_FILE}"
  printf 'Config: /etc/llama-swap/config.yaml  (edit it, then systemctl restart llama-swap, to retune ctx)\n'
  printf 'Reminder: keep the loop dispatcher at concurrency 1 so swaps fire only at role handoffs.\n'
}

main() {
  if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then usage; exit 0; fi
  require_root
  require_command pct
  require_command pveam
  assert_vmid_available
  assert_gpu_devices_exist
  download_template_if_missing
  create_container
  configure_gpu_passthrough
  add_models_mount
  start_container
  wait_for_container
  install_swap_stack
  print_summary
}

main "$@"
