#!/usr/bin/env bash

set -Eeuo pipefail

# This script is intentionally specific. Different GPUs or models should get a
# separate script because GPU runtime flags, context sizes, and settings vary.
# The Radeon Pro V620 (Navi 21 / gfx1030, 32 GB) is driven via Vulkan (mesa
# RADV). It replaces the RX 6700 XT; with ~2.7x the VRAM it serves a much larger
# model. This serves Qwen3.6-35B-A3B (MoE: 35B total / ~3B active per token) via
# llama-server on an OpenAI-compatible API at 0.0.0.0:1234. There is no LM Studio
# sibling for this card (see pro-v620/README.md); llama.cpp is the chosen engine.
readonly GPU_NAME="Radeon Pro V620"
# Pinned llama.cpp prebuilt Vulkan release. Bump TAG + SHA256 together; look up
# both on https://github.com/ggml-org/llama.cpp/releases (the asset is
# llama-<tag>-bin-ubuntu-vulkan-x64.tar.gz; the SHA-256 is the release asset's
# digest). The prebuilt is preferred over a source build for reproducibility.
readonly LLAMACPP_RELEASE_TAG="b9835"
readonly LLAMACPP_ASSET="llama-${LLAMACPP_RELEASE_TAG}-bin-ubuntu-vulkan-x64.tar.gz"
readonly LLAMACPP_ASSET_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMACPP_RELEASE_TAG}/${LLAMACPP_ASSET}"
readonly LLAMACPP_SHA256="513debc0497ba6936ef037907d48bca5c2b250756cb7700b5111f1ed2a59323f"
# Qwen3.6-35B-A3B is a Mixture-of-Experts model: 35B total params, ~3B active per
# token, so it runs far faster than a dense 27B/32B while keeping high capability
# — the best capability-per-second on this card for an interactive agent. It is
# the newer-gen successor to Qwen3.5-35B-A3B (same shape/speed/VRAM, improved tool
# calling; see the README bake-off). UD-Q5_K_XL is unsloth's dynamic-quant build
# (~26.6 GB), chosen over Q4 for slightly better quality at ~5% lower speed; a
# single unsharded file.
readonly MODEL_REPO="unsloth/Qwen3.6-35B-A3B-GGUF"
readonly MODEL_FILE="Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"
readonly MODEL_SHA256="25233af7642e3a91bd52cc4aeefdbd4a117479088e06cf1aea5b6bedb443c506"
# Pin the HF repo revision so a publisher update to `main` can't change the file
# under us (the SHA-256 check would then fail and abort a fresh install). Bump
# alongside MODEL_FILE/MODEL_SHA256, from
# https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/commits/main
readonly MODEL_REVISION="a483e9e6cbd595906af30beda3187c2663a1118c"
# Served via llama-server --alias, so /v1/models reports this stable id instead of
# the model file path. The bench-runner auto-detects it from /v1/models; the
# ansible/host benchmark tooling pins model_key to this. NOTE: this id is
# client-facing — OpenAI requests must set "model" to it. See pro-v620/README.md.
readonly MODEL_ALIAS="qwen3.6-35b-a3b"
# 256k total context — the model's native maximum (262144), 64k per slot at
# --parallel 4. This MoE's KV cache is cheap (~20 KB/token), so even 256k fits the
# V620 at Q5: ~29.8 GiB used of ~30 GiB usable (the card exposes 30704 MiB, not a
# full 32) — only ~0.2 GiB real margin. Stress-verified (a 4-concurrent prefill
# held), but NO safety buffer: a heavier transient could OOM. If that bites, drop
# --ctx-size, switch to Q4, or quantize the KV cache. A larger --ctx-size does NOT slow shorter
# requests (attention is over actual length, not the max), so this ceiling is
# "free" — an occasional high-context agent just works, no reload needed. Daytime
# ~4 agents share it (64k per slot); a single agent can use the whole 256k window
# via `llamacpp-reload 262144 1`. Bigger contexts DECODE slower, and a cold 256k
# prefill takes minutes (fine for incremental/prefix-cached growth) — see README.
# Retune live via `llamacpp-reload <context-length> <parallel>`.
readonly MODEL_CONTEXT_LENGTH="262144"
# -ngl 99 offloads every layer (including all MoE experts) to the GPU; the whole
# ~26.6 GB model fits in the V620's 32 GB (the llama.cpp equivalent of LM Studio's
# --gpu max).
readonly MODEL_GPU_LAYERS="99"
# 4 continuous-batching slots (llama-server --parallel). The MoE activates only
# ~3B params/token, so it batches cheaply and should scale well under
# concurrency; tune with `llamacpp-reload <ctx> <parallel>` once benchmarked.
# Continuous batching is on by default in llama-server.
readonly MODEL_PARALLEL="4"
readonly MODEL_SERVER_BIND="0.0.0.0"
readonly MODEL_SERVER_PORT="1234"

VMID="${VMID:-120}"
LXC_HOSTNAME="${LXC_HOSTNAME:-llamacpp}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"
ROOT_STORAGE="${ROOT_STORAGE:-local-lvm}"
ROOT_SIZE_GB="${ROOT_SIZE_GB:-32}"
MODELS_STORAGE="${MODELS_STORAGE:-local-lvm}"
MODELS_SIZE_GB="${MODELS_SIZE_GB:-120}"
# The model lives in VRAM (all layers offloaded), so the container needs host RAM
# only for the llama-server process and the GGUF's (reclaimable) mmap page cache
# during load — 16 GB is ample and stays well under a typical 31 GiB host. Raise
# only if you run with --no-mmap.
MEMORY_MB="${MEMORY_MB:-16384}"
SWAP_MB="${SWAP_MB:-4096}"
CORES="${CORES:-8}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
PASSWORD="${PASSWORD:-}"
START_ON_BOOT="${START_ON_BOOT:-1}"
START_AFTER_CREATE="${START_AFTER_CREATE:-1}"

usage() {
  cat <<'USAGE'
Create an Ubuntu LXC for llama.cpp (llama-server) on a Radeon Pro V620.

Fixed runtime/model target:
  GPU:    Radeon Pro V620 (Navi 21 / gfx1030, 32 GB)
  Engine: llama.cpp llama-server (prebuilt Vulkan release)
  Model:  unsloth/Qwen3.6-35B-A3B-GGUF / Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf (MoE)
  API:    0.0.0.0:1234 (OpenAI-compatible)

Run this script on the Proxmox host as root.

The V620 replaces the RX 6700 XT; this is its provisioning script (there is no
LM Studio sibling for this card). It defaults to VMID 120 (the LLM-runtime
slot). Only one container can serve the GPU at a time, so destroy any existing
CT 120 first (pct stop 120 && pct destroy 120), or set VMID= to a free id.

Useful overrides:
  VMID=120 LXC_HOSTNAME=llamacpp ./create-lxc-llamacpp-qwen3.6-35b-a3b.sh
  MODELS_SIZE_GB=200 MEMORY_MB=24576 CORES=8 ./create-lxc-llamacpp-qwen3.6-35b-a3b.sh
  PASSWORD='temporary-root-password' ./create-lxc-llamacpp-qwen3.6-35b-a3b.sh

After it is up, change context length / parallel slots without re-provisioning:
  pct exec 120 -- llamacpp-reload <context-length> <parallel>

Important:
  The container is privileged so /dev/dri passthrough (the Vulkan render node)
  works with less friction. Treat it as a trusted container.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "run this script as root on the Proxmox host"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

template_ref() {
  printf '%s:vztmpl/%s\n' "${TEMPLATE_STORAGE}" "${TEMPLATE}"
}

download_template_if_missing() {
  local template_path="/var/lib/vz/template/cache/${TEMPLATE}"

  if [[ -f ${template_path} ]]; then
    return
  fi

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
  [[ -d /dev/dri ]] || die "/dev/dri not found; AMD DRM device directory is missing"
  [[ -e /dev/dri/card0 ]] || die "/dev/dri/card0 not found; AMD DRM card device is missing"
  [[ -e /dev/dri/renderD128 ]] || die "/dev/dri/renderD128 not found; AMD DRM render node (Vulkan) is missing"
}

create_container() {
  local ostemplate
  local rootfs
  local net0
  local -a create_args

  ostemplate="$(template_ref)"
  rootfs="${ROOT_STORAGE}:${ROOT_SIZE_GB}"
  net0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},type=veth"

  log "Creating LXC ${VMID} (${LXC_HOSTNAME}) for ${GPU_NAME}"

  create_args=(
    "${VMID}"
    "${ostemplate}"
    --hostname "${LXC_HOSTNAME}"
    --cores "${CORES}"
    --memory "${MEMORY_MB}"
    --swap "${SWAP_MB}"
    --rootfs "${rootfs}"
    --net0 "${net0}"
    --features "nesting=1,keyctl=1"
    --unprivileged 0
    --onboot "${START_ON_BOOT}"
    --ostype ubuntu
  )

  if [[ -n ${PASSWORD} ]]; then
    create_args+=(--password "${PASSWORD}")
  fi

  pct create "${create_args[@]}"
}

configure_gpu_passthrough() {
  local conf_file
  local dri_major

  log "Configuring ${GPU_NAME} device passthrough (Vulkan render node)"

  conf_file="/etc/pve/lxc/${VMID}.conf"
  dri_major="$(stat -c '%t' /dev/dri/card0 2>/dev/null || true)"

  [[ -n ${dri_major} ]] || die "could not determine /dev/dri/card0 major"

  {
    printf '\n# AMD GPU (/dev/dri) passthrough for llama.cpp Vulkan on %s\n' "${GPU_NAME}"
    printf 'lxc.cgroup2.devices.allow: c %d:* rwm\n' "0x${dri_major}"
    printf 'lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir\n'
  } >>"${conf_file}"
}

add_models_mount() {
  log "Adding local /models mount point (${MODELS_SIZE_GB}G)"

  pct set "${VMID}" \
    -mp0 "${MODELS_STORAGE}:${MODELS_SIZE_GB},mp=/models,backup=0"
}

start_container() {
  if [[ ${START_AFTER_CREATE} == 1 ]]; then
    log "Starting LXC ${VMID}"
    pct start "${VMID}"
  fi
}

wait_for_container() {
  log "Waiting for container startup"
  for _ in {1..60}; do
    if pct exec "${VMID}" -- test -d /run/systemd/system >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done

  die "container did not become ready in time"
}

run_in_container() {
  pct exec "${VMID}" -- "$@"
}

install_llamacpp_stack() {
  log "Installing llama.cpp (${LLAMACPP_RELEASE_TAG}) and configuring ${MODEL_FILE}"

  run_in_container bash -lc "apt-get update"
  # Vulkan userspace (mesa RADV) + the libglvnd/EGL stack — without the latter
  # the Mesa ICD loader can silently report zero Vulkan devices inside the
  # container even when the host sees the GPU (llama.cpp #16138).
  run_in_container bash -lc "DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git jq tar libatomic1 libgomp1 mesa-vulkan-drivers libvulkan1 vulkan-tools libglvnd0 libgl1 libglx0 libegl1 python3 python3-venv sudo"
  run_in_container bash -lc "useradd --create-home --shell /bin/bash llamacpp || true"
  run_in_container bash -lc "usermod -aG video,render llamacpp 2>/dev/null || usermod -aG video llamacpp || true"
  run_in_container bash -lc "install -d -o llamacpp -g llamacpp /models /models/hf"
  run_in_container bash -lc "install -d /opt/llamacpp"

  pct exec "${VMID}" -- bash -s -- \
    "${LLAMACPP_RELEASE_TAG}" \
    "${LLAMACPP_ASSET_URL}" \
    "${LLAMACPP_SHA256}" \
    "${MODEL_REPO}" \
    "${MODEL_FILE}" \
    "${MODEL_SHA256}" \
    "${MODEL_ALIAS}" \
    "${MODEL_GPU_LAYERS}" \
    "${MODEL_CONTEXT_LENGTH}" \
    "${MODEL_PARALLEL}" \
    "${MODEL_SERVER_BIND}" \
    "${MODEL_SERVER_PORT}" \
    "${MODEL_REVISION}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

LLAMACPP_RELEASE_TAG="$1"
LLAMACPP_ASSET_URL="$2"
LLAMACPP_SHA256="$3"
MODEL_REPO="$4"
MODEL_FILE="$5"
MODEL_SHA256="$6"
MODEL_ALIAS="$7"
MODEL_GPU_LAYERS="$8"
MODEL_CONTEXT_LENGTH="$9"
MODEL_PARALLEL="${10}"
MODEL_SERVER_BIND="${11}"
MODEL_SERVER_PORT="${12}"
MODEL_REVISION="${13}"

LLAMACPP_BASE=/opt/llamacpp
LLAMACPP_DIR="${LLAMACPP_BASE}/llama-${LLAMACPP_RELEASE_TAG}"
MODEL_PATH="/models/hf/${MODEL_FILE}"

# 1. Download + verify + extract the pinned Vulkan llama.cpp release. The
# tarball unpacks to a flat llama-<tag>/ dir (llama-server next to its .so
# libs); a `current` symlink keeps the service path stable across version bumps.
if [[ ! -x "${LLAMACPP_DIR}/llama-server" ]]; then
  tarball="$(mktemp)"
  curl --fail --show-error --silent --location --output "${tarball}" "${LLAMACPP_ASSET_URL}"
  printf '%s  %s\n' "${LLAMACPP_SHA256}" "${tarball}" | sha256sum --check -
  tar -xzf "${tarball}" -C "${LLAMACPP_BASE}"
  rm -f "${tarball}"
fi
ln -sfn "${LLAMACPP_DIR}" "${LLAMACPP_BASE}/current"

# 2. Download + verify the GGUF as the service user (owns /models/hf). The
# UD-Q4_K_XL build is a single unsharded file, so a one-file download + checksum
# is enough (no shard handling needed).
if [[ ! -x /home/llamacpp/.venv/bin/hf ]]; then
  sudo -u llamacpp python3 -m venv /home/llamacpp/.venv
  sudo -u llamacpp /home/llamacpp/.venv/bin/pip install --upgrade pip 'huggingface_hub[cli]'
fi
if [[ ! -f "${MODEL_PATH}" ]]; then
  sudo -u llamacpp /home/llamacpp/.venv/bin/hf download "${MODEL_REPO}" "${MODEL_FILE}" \
    --revision "${MODEL_REVISION}" --local-dir /models/hf
fi
printf '%s  %s\n' "${MODEL_SHA256}" "${MODEL_PATH}" | sha256sum --check -

# 3. Runtime config. Context length and parallel slots are llama-server
# start-time flags (unlike LM Studio's `lms load`, llama.cpp can't hot-reload
# them) — change them with `llamacpp-reload <context> <parallel>`, which
# rewrites this file and restarts the service.
cat >/etc/llamacpp.env <<EOF
LLAMACPP_DIR=${LLAMACPP_BASE}/current
MODEL_PATH=${MODEL_PATH}
MODEL_ALIAS=${MODEL_ALIAS}
MODEL_GPU_LAYERS=${MODEL_GPU_LAYERS}
MODEL_SERVER_BIND=${MODEL_SERVER_BIND}
MODEL_SERVER_PORT=${MODEL_SERVER_PORT}
MODEL_CONTEXT_LENGTH=${MODEL_CONTEXT_LENGTH}
MODEL_PARALLEL=${MODEL_PARALLEL}
EOF

# 4. Server wrapper: read fresh config on each (re)start, pin the lib dir, exec
# llama-server. Continuous batching is on by default, so no -cb flag is needed.
# --flash-attn on + a larger batch (--batch-size 4096 --ubatch-size 1024) were
# picked from an on/off/+batch sweep on this card (see pro-v620/README.md): vs
# flash-attn off they give ~+30% concurrent throughput (~102 -> ~133 tok/s
# aggregate at concurrency 4), ~-40% TTFT, and -0.5 GiB VRAM; the batch bump adds
# the last ~3%. FA's default 'auto' already enabled it here, but pinning 'on' is
# deterministic. (On a single >8k cold prefill FA is marginally slower — a fine
# trade for the concurrency/TTFT win in agent/serving use.)
# --jinja makes llama-server use the model's own chat template, which is REQUIRED
# for OpenAI-style tool/function calling to parse into the `tool_calls` field —
# i.e. for agents. Verified across Qwen3.5/3.6 and Hermes (see README bake-off).
# --reasoning-format none keeps the model's <think> tokens inline in the OpenAI
# `content` stream (instead of siphoning them into `reasoning_content`), so an
# OpenAI-compatible benchmark counts every generated token and measures TTFT at
# the true first token. Qwen3.6 "medium" (incl. this MoE) has thinking ON by
# default, so without this the `content` stream is empty and the benchmark would
# flag every request as invalid_output. (An agent client that can't handle inline
# reasoning should instead disable thinking via chat-template kwargs — see
# pro-v620/README.md.)
cat >/usr/local/bin/llamacpp-serve <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
set -a
source /etc/llamacpp.env
set +a
export LD_LIBRARY_PATH="${LLAMACPP_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
exec "${LLAMACPP_DIR}/llama-server" \
  --model "${MODEL_PATH}" \
  --host "${MODEL_SERVER_BIND}" \
  --port "${MODEL_SERVER_PORT}" \
  --n-gpu-layers "${MODEL_GPU_LAYERS}" \
  --ctx-size "${MODEL_CONTEXT_LENGTH}" \
  --parallel "${MODEL_PARALLEL}" \
  --flash-attn on \
  --batch-size 4096 \
  --ubatch-size 1024 \
  --jinja \
  --reasoning-format none \
  --alias "${MODEL_ALIAS}"
EOS
chmod 755 /usr/local/bin/llamacpp-serve

# 5. Health-wait + reload helpers. llama-server sets context/parallel at start,
# so a "reload" restarts the service; both the initial boot and a reload must
# BLOCK until /health is ready (loading the model into VRAM takes time and
# systemctl returns as soon as the process spawns), so callers — the installer
# below, a benchmark preflight, the context sweep — don't race a not-yet-serving
# (or failed-to-load) server. Run as root.
cat >/usr/local/bin/llamacpp-wait-health <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
port="$(. /etc/llamacpp.env; printf '%s' "${MODEL_SERVER_PORT:-1234}")"
for _ in $(seq 1 150); do
  if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 2
done
printf 'llamacpp: server did not become healthy in time\n' >&2
exit 1
EOS
chmod 755 /usr/local/bin/llamacpp-wait-health

cat >/usr/local/bin/llamacpp-reload <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
ctx="${1:?usage: llamacpp-reload <context-length> <parallel>}"
parallel="${2:?usage: llamacpp-reload <context-length> <parallel>}"
sed -i \
  -e "s/^MODEL_CONTEXT_LENGTH=.*/MODEL_CONTEXT_LENGTH=${ctx}/" \
  -e "s/^MODEL_PARALLEL=.*/MODEL_PARALLEL=${parallel}/" \
  /etc/llamacpp.env
systemctl restart llamacpp.service
exec /usr/local/bin/llamacpp-wait-health
EOS
chmod 755 /usr/local/bin/llamacpp-reload

# 6. Long-running daemon (Type=simple), unlike LM Studio's oneshot + lms daemon.
cat >/etc/systemd/system/llamacpp.service <<'SERVICE'
[Unit]
Description=llama.cpp llama-server (Qwen3.6-35B-A3B) on Radeon Pro V620
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=llamacpp
Group=llamacpp
Environment=HOME=/home/llamacpp
ExecStart=/usr/local/bin/llamacpp-serve
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

# Pin the Vulkan loader to the AMD (RADV) ICD so the engine can't bind to the
# llvmpipe software device that also advertises Vulkan.
RADV_ICD="$(ls /usr/share/vulkan/icd.d/radeon_icd*.json 2>/dev/null | head -1)"
if [[ -n "${RADV_ICD}" ]]; then
  mkdir -p /etc/systemd/system/llamacpp.service.d
  printf '[Service]\nEnvironment=VK_ICD_FILENAMES=%s\n' "${RADV_ICD}" \
    > /etc/systemd/system/llamacpp.service.d/vulkan.conf
fi

systemctl daemon-reload
systemctl enable --now llamacpp.service
# Block until the model is actually serving. Type=simple returns as soon as the
# process spawns, but the model load into VRAM can still fail afterward — without
# this wait, provisioning would report success over a dead/not-ready server.
/usr/local/bin/llamacpp-wait-health
CONTAINER_SCRIPT
}

print_summary() {
  local ip
  ip="$(pct exec "${VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

  log "Done"
  printf 'LXC: %s (%s)\n' "${VMID}" "${LXC_HOSTNAME}"
  printf 'GPU target: %s\n' "${GPU_NAME}"
  printf 'Engine: llama.cpp llama-server %s (Vulkan)\n' "${LLAMACPP_RELEASE_TAG}"
  printf 'Models mount: /models (%sG on %s, backup disabled)\n' "${MODELS_SIZE_GB}" "${MODELS_STORAGE}"
  if [[ -n ${ip} ]]; then
    printf 'llama-server endpoint: http://%s:%s/v1\n' "${ip}" "${MODEL_SERVER_PORT}"
  else
    printf 'llama-server endpoint: check container IP, port %s\n' "${MODEL_SERVER_PORT}"
  fi
  printf 'Model: %s / %s (served as "%s")\n' "${MODEL_REPO}" "${MODEL_FILE}" "${MODEL_ALIAS}"
  printf 'Reload at a new context/parallel: pct exec %s -- llamacpp-reload <ctx> <parallel>\n' "${VMID}"
}

main() {
  if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
    usage
    exit 0
  fi

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
  if [[ ${START_AFTER_CREATE} != 1 ]]; then
    log "Container ${VMID} created but not started (START_AFTER_CREATE=0); model not installed."
    log "Start it and re-run with START_AFTER_CREATE=1 to install ${MODEL_FILE}."
    return 0
  fi
  wait_for_container
  install_llamacpp_stack
  print_summary
}

main "$@"
