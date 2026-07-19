#!/usr/bin/env bash

set -Eeuo pipefail

# This script is intentionally specific (like its CT-120 sibling). It stands up a
# SECOND Radeon Pro V620 service on GPU 2 for the autonomous coding loop: a
# `llama-swap` proxy that hot-swaps between the loop's models — a dedicated coder
# (Qwen3-30B-A3B-Instruct-2507) and a reviewer (Qwen3-Coder-30B-A3B-Instruct) —
# one resident at a time (both can't co-reside on one 32 GB card). CT 120's
# qwen3.6 on GPU 1 stays the untouched ops server; the loop's dispatcher is
# serialized to one task at a time so the swap only fires at coder<->reviewer
# handoffs. Serves an OpenAI-compatible API at 0.0.0.0:8080; clients pick the
# model by name ("qwen3-instruct-2507" / "qwen3-coder-reviewer").
readonly GPU_NAME="Radeon Pro V620"
# This container is pinned to GPU 2 (PCIe-3/chipset slot). GPU 1 (0000:2d:00.0)
# runs CT 120 (qwen3.6 ops). Passthrough binds ONLY GPU 2's DRM nodes — the only
# reboot-stable way to pin one of two IDENTICAL cards (see configure_gpu_passthrough).
readonly GPU_PCI_ADDRESS="${GPU_PCI_ADDRESS:-0000:06:00.0}"    # GPU 2 (PCIe-3/chipset) — the card this container uses
readonly OTHER_GPU_PCI_ADDRESS="${OTHER_GPU_PCI_ADDRESS:-0000:2d:00.0}"  # GPU 1 (PCIe-1/CPU) — runs CT 120, NOT passed through here

# Pinned prebuilt Vulkan llama.cpp release (same as CT 120). llama-swap launches
# this llama-server per model. Bump TAG + SHA256 together from
# https://github.com/ggml-org/llama.cpp/releases (asset llama-<tag>-bin-ubuntu-vulkan-x64.tar.gz).
readonly LLAMACPP_RELEASE_TAG="b9835"
readonly LLAMACPP_ASSET="llama-${LLAMACPP_RELEASE_TAG}-bin-ubuntu-vulkan-x64.tar.gz"
readonly LLAMACPP_ASSET_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMACPP_RELEASE_TAG}/${LLAMACPP_ASSET}"
readonly LLAMACPP_SHA256="513debc0497ba6936ef037907d48bca5c2b250756cb7700b5111f1ed2a59323f"

# Pinned llama-swap release (Go proxy). Bump VERSION + SHA256 together from
# https://github.com/mostlygeek/llama-swap/releases (asset llama-swap_<ver>_linux_amd64.tar.gz;
# SHA-256 is in llama-swap_<ver>_checksums.txt).
readonly LLAMASWAP_VERSION="240"
readonly LLAMASWAP_ASSET="llama-swap_${LLAMASWAP_VERSION}_linux_amd64.tar.gz"
readonly LLAMASWAP_ASSET_URL="https://github.com/mostlygeek/llama-swap/releases/download/v${LLAMASWAP_VERSION}/${LLAMASWAP_ASSET}"
readonly LLAMASWAP_SHA256="3e0c3fd2649f2b0eb417ab2bc337da65e3bbb5374fae9769e74ab90bdaa3739c"

# --- Coder model: Qwen3-30B-A3B-Instruct-2507 (instruct MoE, ~3B active; strong
# agentic-coding instruction-follower, non-thinking by design so no runaway <think>
# chains). Q5_K_M ~21.7 GB. Apache-2.0. Replaced Ornith (false-completed / stalled).
readonly CODER_REPO="unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF"
readonly CODER_FILE="Qwen3-30B-A3B-Instruct-2507-Q5_K_M.gguf"
readonly CODER_SHA256="74cf6e525344a184e59f8dbd1d18e59587f1a03eaff66f6b1fbd0ee3a53a3d68"
readonly CODER_REVISION="eea7b2be5805a5f151f8847ede8e5f9a9284bf77"
readonly CODER_ALIAS="qwen3-instruct-2507"
readonly CODER_CTX="${CODER_CTX:-65536}"          # Hermes requires >=64K; per-slot window at --parallel 1
readonly CODER_NPREDICT="${CODER_NPREDICT:-8192}" # cap tokens/request (non-thinking, 8k is ample)

# --- Reviewer model: Qwen3-Coder-30B-A3B-Instruct (coder MoE, ~3B active; non-thinking
# by architecture — cannot emit <think>, so it can't do the unbounded-reasoning budget
# exhaustion that killed the prior ThinkingCap reviewer). UD-Q5_K_XL ~21.7 GB. Apache-2.0.
readonly REVIEWER_REPO="unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
readonly REVIEWER_FILE="Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL.gguf"
readonly REVIEWER_SHA256="eb331a4eee8eb6b5a8eb25f44f96f45c71b8d10f553c0a456190dd590a7ef77d"
readonly REVIEWER_REVISION="b17cb02dd882d5b6ab62fc777ad2995f19668350"
readonly REVIEWER_ALIAS="qwen3-coder-reviewer"
readonly REVIEWER_CTX="${REVIEWER_CTX:-65536}"          # reviewer reads a diff + a few files
readonly REVIEWER_NPREDICT="${REVIEWER_NPREDICT:-8192}" # cap tokens/request

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
  Models: qwen3-instruct-2507 (Qwen3-30B-A3B-Instruct-2507, coder) + qwen3-coder-reviewer (Qwen3-Coder-30B-A3B-Instruct, reviewer)
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
  local models_manifest
  # repo|file|sha256|revision|ctx|alias|npredict  (one line per model)
  models_manifest="$(printf '%s|%s|%s|%s|%s|%s|%s\n%s|%s|%s|%s|%s|%s|%s\n' \
    "${CODER_REPO}" "${CODER_FILE}" "${CODER_SHA256}" "${CODER_REVISION}" "${CODER_CTX}" "${CODER_ALIAS}" "${CODER_NPREDICT}" \
    "${REVIEWER_REPO}" "${REVIEWER_FILE}" "${REVIEWER_SHA256}" "${REVIEWER_REVISION}" "${REVIEWER_CTX}" "${REVIEWER_ALIAS}" "${REVIEWER_NPREDICT}")"

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
    "${models_manifest}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
LLAMACPP_ASSET_URL="$1"; LLAMACPP_SHA256="$2"
LLAMASWAP_ASSET_URL="$3"; LLAMASWAP_SHA256="$4"
SWAP_BIND="$5"; SWAP_PORT="$6"
MODELS_MANIFEST="$7"

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
LS=/opt/llamacpp/current
export LD_LIBRARY_PATH="${LS}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
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
# runs away can't fill its whole ctx window and stall the loop; the loop's models are non-thinking so 8k is ample.
exec "${LS}/llama-server" --model "${MODEL}" --host 127.0.0.1 --port "${PORT}" \
  --n-gpu-layers 99 --ctx-size "${CTX}" --parallel 1 --flash-attn on \
  --batch-size 4096 --ubatch-size 1024 --jinja --reasoning-format none \
  --n-predict "${NPREDICT}" --alias "${ALIAS}"
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

while IFS='|' read -r repo file sha rev ctx alias npredict; do
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
    printf '      /usr/local/bin/llamaswap-guarded-serve %s ${PORT} %s %s %s\n' "$mp" "$ctx" "$alias" "$npredict"
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
