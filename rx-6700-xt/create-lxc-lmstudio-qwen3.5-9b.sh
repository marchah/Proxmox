#!/usr/bin/env bash

set -Eeuo pipefail

# This script is intentionally specific. Different GPUs or models should get a
# separate script because GPU runtime flags, context sizes, and settings vary.
# The RX 6700 XT is driven via Vulkan (mesa RADV).
readonly GPU_NAME="Radeon RX 6700 XT"
readonly LMSTUDIO_INSTALL_URL="https://lmstudio.ai/install.sh"
readonly MODEL_REPO="unsloth/Qwen3.5-9B-GGUF"
readonly MODEL_FILE="Qwen3.5-9B-Q4_K_M.gguf"
readonly MODEL_KEY="qwen3.5-9b"
readonly MODEL_SHA256="03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8"
readonly MODEL_CONTEXT_LENGTH="64000"
readonly MODEL_GPU_OFFLOAD="max"
# 4 continuous-batching slots: scales to ~92 tok/s under concurrency vs ~53 tok/s flat
# at 1, with identical single-user latency (see rx-6700-xt/README.md benchmarks).
readonly MODEL_PARALLEL="4"
readonly MODEL_SERVER_BIND="0.0.0.0"
readonly MODEL_SERVER_PORT="1234"

VMID="${VMID:-120}"
LXC_HOSTNAME="${LXC_HOSTNAME:-lmstudio}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"
ROOT_STORAGE="${ROOT_STORAGE:-local-lvm}"
ROOT_SIZE_GB="${ROOT_SIZE_GB:-32}"
MODELS_STORAGE="${MODELS_STORAGE:-local-lvm}"
MODELS_SIZE_GB="${MODELS_SIZE_GB:-350}"
MEMORY_MB="${MEMORY_MB:-24576}"
SWAP_MB="${SWAP_MB:-4096}"
CORES="${CORES:-8}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
PASSWORD="${PASSWORD:-}"
START_ON_BOOT="${START_ON_BOOT:-1}"
START_AFTER_CREATE="${START_AFTER_CREATE:-1}"

usage() {
  cat <<'USAGE'
Create an Ubuntu LXC for LM Studio on a Radeon RX 6700 XT.

Fixed runtime/model target:
  GPU:   Radeon RX 6700 XT
  Model: unsloth/Qwen3.5-9B-GGUF / Qwen3.5-9B-Q4_K_M.gguf
  API:   0.0.0.0:1234

Run this script on the Proxmox host as root.

Useful overrides:
  VMID=120 LXC_HOSTNAME=lmstudio ./create-lxc-lmstudio-qwen3.5-9b.sh
  MODELS_SIZE_GB=500 MEMORY_MB=24576 CORES=8 ./create-lxc-lmstudio-qwen3.5-9b.sh
  PASSWORD='temporary-root-password' ./create-lxc-lmstudio-qwen3.5-9b.sh

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
    die "VMID ${VMID} already exists"
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

  log "Configuring RX 6700 XT device passthrough (Vulkan render node)"

  conf_file="/etc/pve/lxc/${VMID}.conf"
  dri_major="$(stat -c '%t' /dev/dri/card0 2>/dev/null || true)"

  [[ -n ${dri_major} ]] || die "could not determine /dev/dri/card0 major"

  {
    printf '\n# AMD GPU (/dev/dri) passthrough for LM Studio Vulkan on RX 6700 XT\n'
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

install_lmstudio_stack() {
  log "Installing LM Studio and configuring ${MODEL_FILE}"

  run_in_container bash -lc "apt-get update"
  run_in_container bash -lc "DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git jq libatomic1 libgomp1 mesa-vulkan-drivers libvulkan1 vulkan-tools python3 python3-venv sudo"
  run_in_container bash -lc "useradd --create-home --shell /bin/bash lmstudio || true"
  run_in_container bash -lc "usermod -aG video,render lmstudio 2>/dev/null || usermod -aG video lmstudio || true"
  run_in_container bash -lc "install -d -o lmstudio -g lmstudio /models /models/hf /models/lmstudio-home"
  run_in_container bash -lc "ln -sfn /models/lmstudio-home /home/lmstudio/.lmstudio && chown -h lmstudio:lmstudio /home/lmstudio/.lmstudio"

  pct exec "${VMID}" -- bash -s -- \
    "${LMSTUDIO_INSTALL_URL}" \
    "${MODEL_REPO}" \
    "${MODEL_FILE}" \
    "${MODEL_KEY}" \
    "${MODEL_SHA256}" \
    "${MODEL_CONTEXT_LENGTH}" \
    "${MODEL_GPU_OFFLOAD}" \
    "${MODEL_PARALLEL}" \
    "${MODEL_SERVER_BIND}" \
    "${MODEL_SERVER_PORT}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

LMSTUDIO_INSTALL_URL="$1"
MODEL_REPO="$2"
MODEL_FILE="$3"
MODEL_KEY="$4"
MODEL_SHA256="$5"
MODEL_CONTEXT_LENGTH="$6"
MODEL_GPU_OFFLOAD="$7"
MODEL_PARALLEL="$8"
MODEL_SERVER_BIND="$9"
MODEL_SERVER_PORT="${10}"

cat >/usr/local/bin/install-lmstudio-qwen3.5-9b <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail

LMSTUDIO_INSTALL_URL="$1"
MODEL_REPO="$2"
MODEL_FILE="$3"
MODEL_KEY="$4"
MODEL_SHA256="$5"
MODEL_CONTEXT_LENGTH="$6"
MODEL_GPU_OFFLOAD="$7"
MODEL_PARALLEL="$8"
MODEL_SERVER_BIND="$9"
MODEL_SERVER_PORT="${10}"

export HOME=/home/lmstudio
cd "${HOME}"

mkdir -p /models/hf /models/lmstudio-home

if [[ ! -x "${HOME}/.lmstudio/bin/lms" ]]; then
  installer="$(mktemp)"
  curl --fail --show-error --silent --location \
    --output "${installer}" \
    "${LMSTUDIO_INSTALL_URL}"
  sh -n "${installer}"
  sh "${installer}" --quiet
  rm -f "${installer}"
fi

LMS_BIN="${HOME}/.lmstudio/bin/lms"
MODEL_PATH="/models/hf/${MODEL_FILE}"

if [[ ! -x "${HOME}/.venv/bin/hf" ]]; then
  python3 -m venv "${HOME}/.venv"
  "${HOME}/.venv/bin/pip" install --upgrade pip huggingface_hub[cli]
fi

if [[ ! -f "${MODEL_PATH}" ]]; then
  "${HOME}/.venv/bin/hf" download "${MODEL_REPO}" "${MODEL_FILE}" \
    --local-dir /models/hf
fi

printf '%s  %s\n' "${MODEL_SHA256}" "${MODEL_PATH}" | sha256sum --check -

"${LMS_BIN}" daemon up
sleep 5

"${LMS_BIN}" import "${MODEL_PATH}" \
  --copy \
  --user-repo "${MODEL_REPO}" \
  --yes || true

# Unload any prior copy, then load with GPU offload via the selected Vulkan
# runtime. Don't gate on /sys VRAM counters — they are unreliable under this
# passthrough (they read near-zero even while the GPU is doing the inference);
# verify with throughput instead.
"${LMS_BIN}" unload --all >/dev/null 2>&1 || true
"${LMS_BIN}" load "${MODEL_KEY}" \
  --context-length "${MODEL_CONTEXT_LENGTH}" \
  --gpu "${MODEL_GPU_OFFLOAD}" \
  --parallel "${MODEL_PARALLEL}" \
  --yes

"${LMS_BIN}" server start \
  --bind "${MODEL_SERVER_BIND}" \
  --port "${MODEL_SERVER_PORT}"
EOS

chmod 755 /usr/local/bin/install-lmstudio-qwen3.5-9b

cat >/etc/systemd/system/lmstudio.service <<EOF
[Unit]
Description=LM Studio Qwen3.5 9B server on RX 6700 XT
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=lmstudio
Group=lmstudio
Environment=HOME=/home/lmstudio
ExecStart=/usr/local/bin/install-lmstudio-qwen3.5-9b '${LMSTUDIO_INSTALL_URL}' '${MODEL_REPO}' '${MODEL_FILE}' '${MODEL_KEY}' '${MODEL_SHA256}' '${MODEL_CONTEXT_LENGTH}' '${MODEL_GPU_OFFLOAD}' '${MODEL_PARALLEL}' '${MODEL_SERVER_BIND}' '${MODEL_SERVER_PORT}'
ExecStop=/home/lmstudio/.lmstudio/bin/lms daemon down
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Pin the Vulkan loader to the AMD (RADV) ICD so the engine can't bind to the
# llvmpipe software device that also advertises Vulkan.
RADV_ICD="$(ls /usr/share/vulkan/icd.d/radeon_icd*.json 2>/dev/null | head -1)"
if [[ -n "${RADV_ICD}" ]]; then
  mkdir -p /etc/systemd/system/lmstudio.service.d
  printf '[Service]\nEnvironment=VK_ICD_FILENAMES=%s\n' "${RADV_ICD}" \
    > /etc/systemd/system/lmstudio.service.d/vulkan.conf
fi

systemctl daemon-reload
systemctl enable --now lmstudio.service
CONTAINER_SCRIPT
}

print_summary() {
  local ip
  ip="$(pct exec "${VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

  log "Done"
  printf 'LXC: %s (%s)\n' "${VMID}" "${LXC_HOSTNAME}"
  printf 'GPU target: %s\n' "${GPU_NAME}"
  printf 'Models mount: /models (%sG on %s, backup disabled)\n' "${MODELS_SIZE_GB}" "${MODELS_STORAGE}"
  if [[ -n ${ip} ]]; then
    printf 'LM Studio endpoint: http://%s:%s/v1\n' "${ip}" "${MODEL_SERVER_PORT}"
  else
    printf 'LM Studio endpoint: check container IP, port %s\n' "${MODEL_SERVER_PORT}"
  fi
  printf 'Model: %s / %s\n' "${MODEL_REPO}" "${MODEL_FILE}"
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
  wait_for_container
  install_lmstudio_stack
  print_summary
}

main "$@"
