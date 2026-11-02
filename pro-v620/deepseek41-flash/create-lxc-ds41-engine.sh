#!/usr/bin/env bash

set -Eeuo pipefail

# --- Config (override any via VAR=value) -------------------------------------
# One container per engine, so each engine's build and runtime stay apart (README.md).
ENGINE="${1:-}"
case "${ENGINE}" in
  strata) DEFAULT_VMID=125; DEFAULT_HOSTNAME=ds41-strata; DEFAULT_ONBOOT=1; DEFAULT_FIREWALL=0; DEFAULT_OTHER=126 ;;
  llama) DEFAULT_VMID=126; DEFAULT_HOSTNAME=ds41-llama; DEFAULT_ONBOOT=0; DEFAULT_FIREWALL=1; DEFAULT_OTHER=125 ;;
  *) DEFAULT_VMID=""; DEFAULT_HOSTNAME=""; DEFAULT_ONBOOT=0; DEFAULT_FIREWALL=1; DEFAULT_OTHER="" ;;
esac
VMID="${VMID:-${DEFAULT_VMID}}"
# The other engine's container, which takes GPU 2 when this one stops.
OTHER_VMID="${OTHER_VMID:-${DEFAULT_OTHER}}"
LXC_HOSTNAME="${LXC_HOSTNAME:-${DEFAULT_HOSTNAME}}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
# AMD's ROCm 10.0 repository targets ubuntu2404.
TEMPLATE="${TEMPLATE:-ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"
ROOT_STORAGE="${ROOT_STORAGE:-local-lvm}"
# ROCm is about 8 GB; one engine's builds and logs fit in the rest.
ROOT_SIZE_GB="${ROOT_SIZE_GB:-100}"
# CT 125 and CT 126 get the same CPUs and memory limit, so their numbers compare. The raw CPU
# set gives whole cores 8-31 with both threads: Proxmox moves a `cores`-only container's
# CPUs every few seconds without regard to SMT, and the engines pin one thread per physical
# core. CT 120 and CT 121 share cores 0-7.
CORES="${CORES:-48}"
CPUSET="${CPUSET:-8-31,40-63}"
# The host's memory less the other guests' limits and a 16 GiB reserve, when CT 125 and
# CT 126 were sized (2026-10-27). The Q4 pack keeps its experts and Engram in RAM.
MEMORY_MB="${MEMORY_MB:-466487}"
SWAP_MB="${SWAP_MB:-0}"
BRIDGE="${BRIDGE:-vmbr0}"
# Fixed MAC so the router's DHCP reservation is deterministic.
MAC="${MAC:-BC:24:11:C0:DE:${VMID: -2}}"
# CT 125 serves the LAN and starts at boot; CT 126 is started only for a run.
START_ON_BOOT="${START_ON_BOOT:-${DEFAULT_ONBOOT}}"
# Guest firewall rules, enforced only while the datacenter firewall is on (it is off).
# CT 125 has none: it serves the LAN on :1234.
GUEST_FIREWALL="${GUEST_FIREWALL:-${DEFAULT_FIREWALL}}"
LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"
ROUTER_IP="${ROUTER_IP:-192.168.1.1}"

# The shared GGUF store read-only, the writable directory runs and packs go to, and the
# owner telemetry read-only.
MODELS_DIR="${MODELS_DIR:-/mnt/models/store}"
DEV_DIR="${DEV_DIR:-/mnt/models/store/dev}"
# The container's UID 1000 (AGENT_USER) on the host.
DEV_DIR_OWNER="${DEV_DIR_OWNER:-101000:101000}"
# A small tmpfs the measurement gate writes on the host (strata-v620
# tools/v620/host/ds41-211-gate.sh) and the containers read at /owner-telemetry.
TELEMETRY_DIR="${TELEMETRY_DIR:-/mnt/ds41-telemetry}"
TELEMETRY_SIZE="${TELEMETRY_SIZE:-64m}"

GPU1_PCI='0000:03:00.0'
GPU2_PCI='0000:83:00.0'
DRI_BY_PATH="${DRI_BY_PATH:-/dev/dri/by-path}"
KFD_NODE="${KFD_NODE:-/dev/kfd}"
WATCHDOG_ENV="${WATCHDOG_ENV:-/etc/gpu-thermal-watchdog.env}"
BAK_DIR="${BAK_DIR:-/root/conf-backups}"

# ROCm userspace for gfx1030.
ROCM_PACKAGE="${ROCM_PACKAGE:-amdrocm-core-dev10.0-gfx1030}"
ROCM_VERSION="${ROCM_VERSION:-10.0.0-4}"
ROCM_ROOT="${ROCM_ROOT:-/opt/rocm/core-10.0}"

AGENT_USER="${AGENT_USER:-agent}"
AGENT_UID="${AGENT_UID:-1000}"
# The agent's authorized_keys are copied from the other engine's container when it runs.
KEYS_FROM_VMID="${KEYS_FROM_VMID:-${OTHER_VMID}}"
# An extra public key allowed to log in as AGENT_USER; needed when neither container runs.
AGENT_SSH_PUBKEY="${AGENT_SSH_PUBKEY:-}"

usage() {
  cat <<'USAGE'
Create or reconfigure the container that runs one DeepSeek-V4.1-Flash engine on GPU 2
(0000:83:00.0). Run on the Proxmox host as root.

  ./create-lxc-ds41-engine.sh strata   # CT 125 ds41-strata: strata-v620's server, onboot 1
  ./create-lxc-ds41-engine.sh llama    # CT 126 ds41-llama: llama.cpp, the comparison, onboot 0

Creates an unprivileged Ubuntu 24.04 LXC with ROCm (ROCM_PACKAGE), build tools, the user
`agent` (passwordless sudo inside the container, groups video and render) and key-only
sshd. It passes GPU 2 through with /dev/kfd, denies GPU 1's DRM nodes, sets the shared CPU
set and memory limit, checks that ROCm lists one gfx1030, and points the thermal
watchdog's GPU 2 entry at the container. The model store is mounted read-only at /models,
the owner telemetry read-only at /owner-telemetry, and /models-dev is writable. No GitHub
credentials.

It refuses while another running container passes GPU 2 through: only one of CT 123, 125
and 126 runs on the card. Engine builds and CT 125's service come from marchah/strata-v620.

Re-running is safe: an existing container is configured, not recreated.
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

run_in_container() {
  pct exec "${VMID}" -- "$@"
}

container_exists() {
  pct status "${VMID}" >/dev/null 2>&1
}

ct_state() {
  pct status "$1" 2>/dev/null | awk '{print $2}'
}

conf_path() {
  printf '/etc/pve/lxc/%s.conf' "${VMID}"
}

backup_conf() {
  install -d -m 0700 "${BAK_DIR}"
  cp -a "$(conf_path)" "${BAK_DIR}/lxc-${VMID}.conf.bak-$(date +%Y%m%d-%H%M%S)"
}

# Rewrite the config from a filtered copy (/etc/pve is the cluster filesystem). Appended
# lines land in the last section, so a config with snapshots is left to a human.
rewrite_conf() {  # <grep -v pattern> <lines to append>
  local conf tmp
  conf="$(conf_path)"
  ! grep -q '^\[' "${conf}" || die "CT ${VMID} has snapshots; edit ${conf} by hand"
  tmp="$(mktemp)"
  grep -vE "$1" "${conf}" >"${tmp}" || true
  printf '%s' "$2" >>"${tmp}"
  cat "${tmp}" >"${conf}"
  rm -f "${tmp}"
}

node_of() {  # <pci> <card|render>: the card's real node name, e.g. renderD128
  local n
  n="$(basename "$(readlink -f "${DRI_BY_PATH}/pci-$1-$2")")"
  [[ ${n} =~ ^(card|renderD)[0-9]+$ ]] || die "${DRI_BY_PATH}/pci-$1-$2 does not resolve to a DRM node"
  printf '%s\n' "${n}"
}

# Only one container runs on GPU 2: CT 123 mounts it by path, CT 125 and CT 126 pass its
# render node through, and CT 120 mounts it in the two-card cutover.
assert_gpu2_free() {
  local render id
  render="$(node_of "${GPU2_PCI}" render)"
  for id in $(pct list | awk 'NR > 1 && $2 == "running" {print $1}'); do
    [[ ${id} == "${VMID}" ]] && continue
    if grep -qE "pci-${GPU2_PCI}-render|^dev[0-9]+: /dev/dri/${render}," "/etc/pve/lxc/${id}.conf" 2>/dev/null; then
      die "CT ${id} is running on GPU 2; stop it first (strata-v620's tools/v620/host/host-switch-gpu2.sh moves the card between CT 125 and CT 126)"
    fi
  done
}

download_template_if_missing() {
  if [[ -f "/var/lib/vz/template/cache/${TEMPLATE}" ]]; then
    return
  fi
  log "Downloading LXC template ${TEMPLATE}"
  pveam update
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
}

prepare_host_dirs() {
  [[ -d ${MODELS_DIR} ]] || die "${MODELS_DIR} is missing; is the models store mounted?"
  log "Writable model directory ${DEV_DIR} (owner ${DEV_DIR_OWNER})"
  install -d -m 0755 "${DEV_DIR}"
  chown "${DEV_DIR_OWNER}" "${DEV_DIR}"

  # fstab mounts the tmpfs before the guests start, so the bind mount always finds it.
  if ! grep -qE "^tmpfs[[:space:]]+${TELEMETRY_DIR}[[:space:]]" /etc/fstab; then
    log "fstab: tmpfs ${TELEMETRY_DIR} (${TELEMETRY_SIZE})"
    install -d -m 0700 "${BAK_DIR}"
    cp -a /etc/fstab "${BAK_DIR}/fstab.bak-$(date +%Y%m%d-%H%M%S)"
    printf 'tmpfs %s tmpfs size=%s,mode=0755,nosuid,nodev,noexec,x-systemd.before=pve-guests.service 0 0\n' \
      "${TELEMETRY_DIR}" "${TELEMETRY_SIZE}" >>/etc/fstab
    systemctl daemon-reload
  fi
  install -d -m 0755 "${TELEMETRY_DIR}"
  mountpoint -q "${TELEMETRY_DIR}" || mount "${TELEMETRY_DIR}"
}

create_container() {
  local fw=""
  if container_exists; then
    log "CT ${VMID} exists; configuring it in place"
    backup_conf
    return
  fi
  [[ ${GUEST_FIREWALL} == 1 ]] && fw=",firewall=1"

  log "Creating LXC ${VMID} (${LXC_HOSTNAME}) mac=${MAC}"
  # nesting=1: systemd in an unprivileged container cannot start logind without it,
  # and every SSH login then waits 25 s on D-Bus (see coder-runner).
  pct create "${VMID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "${LXC_HOSTNAME}" \
    --cores "${CORES}" \
    --memory "${MEMORY_MB}" \
    --swap "${SWAP_MB}" \
    --rootfs "${ROOT_STORAGE}:${ROOT_SIZE_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,hwaddr=${MAC},type=veth${fw}" \
    --unprivileged 1 \
    --features "nesting=1" \
    --onboot "${START_ON_BOOT}" \
    --timezone host \
    --ostype ubuntu
}

configure_container() {
  log "Mounts: /models and /owner-telemetry read-only, /models-dev writable"
  pct set "${VMID}" --mp0 "${MODELS_DIR},mp=/models,ro=1" --mp1 "${DEV_DIR},mp=/models-dev" \
    --mp2 "${TELEMETRY_DIR},mp=/owner-telemetry,ro=1"

  log "${CORES} cores on CPUs ${CPUSET}, ${MEMORY_MB} MiB, onboot=${START_ON_BOOT}"
  pct set "${VMID}" --cores "${CORES}" --memory "${MEMORY_MB}" --swap "${SWAP_MB}" --onboot "${START_ON_BOOT}"
  grep -qxF "lxc.cgroup2.cpuset.cpus: ${CPUSET}" "$(conf_path)" \
    || rewrite_conf '^lxc\.cgroup2\.cpuset\.cpus:' "lxc.cgroup2.cpuset.cpus: ${CPUSET}"$'\n'

  # Both engines page-lock host memory for experts and transfer buffers. An unprivileged
  # container cannot raise RLIMIT_MEMLOCK itself, so LXC sets it for the container.
  grep -qxF 'lxc.prlimit.memlock: unlimited' "$(conf_path)" \
    || rewrite_conf '^lxc\.prlimit\.memlock:' $'lxc.prlimit.memlock: unlimited\n'
}

write_guest_firewall() {
  if [[ ${GUEST_FIREWALL} != 1 ]]; then
    log "No guest firewall for CT ${VMID}"
    return
  fi
  log "Firewall rules for CT ${VMID} (not enforced while the datacenter firewall is off)"
  # Rules apply top to bottom. The `lan` set covers the LAN and IPv6 local scopes, so
  # the internet rule cannot reach the host, the BMC, the NAS or another guest.
  cat >"/etc/pve/firewall/${VMID}.fw" <<FW
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP
dhcp: 1
macfilter: 1

[IPSET lan]
${LAN_CIDR}
fc00::/7
fe80::/10

[RULES]
IN ACCEPT -source ${LAN_CIDR} -p tcp -dport 22 -log nolog
IN ACCEPT -source ${LAN_CIDR} -p icmp -log nolog
OUT ACCEPT -dest ${ROUTER_IP} -p udp -dport 53 -log nolog
OUT ACCEPT -dest ${ROUTER_IP} -p tcp -dport 53 -log nolog
OUT DROP -dest +lan -log nolog
OUT ACCEPT -p tcp -dport 22,80,443 -log nolog
OUT ACCEPT -p icmp -log nolog
FW
}

# GPU 2's entry names the whole container: its GPU work is the service and the gated
# measurement runs, not one unit. GPU 1's entry stays as it is (CT 120's server).
set_watchdog_map() {
  local cur gpu1 want
  [[ -f ${WATCHDOG_ENV} ]] || die "${WATCHDOG_ENV} missing: install ../gpu-thermal-watchdog first"
  cur="$(grep -m1 '^GPU_SERVICE_MAP=' "${WATCHDOG_ENV}" | cut -d= -f2- || true)"
  gpu1="$(tr ',' '\n' <<<"${cur}" | grep "^${GPU1_PCI}=" || true)"
  want="${gpu1:-${GPU1_PCI}=120:llamacpp},${GPU2_PCI}=${VMID}:@container"
  [[ ${cur} == "${want}" ]] && return 0
  install -d -m 0700 "${BAK_DIR}"
  cp -a "${WATCHDOG_ENV}" "${BAK_DIR}/gpu-thermal-watchdog.env.bak-$(date +%Y%m%d-%H%M%S)"
  if grep -q '^GPU_SERVICE_MAP=' "${WATCHDOG_ENV}"; then
    sed -i "s|^GPU_SERVICE_MAP=.*|GPU_SERVICE_MAP=${want}|" "${WATCHDOG_ENV}"
  else
    printf 'GPU_SERVICE_MAP=%s\n' "${want}" >>"${WATCHDOG_ENV}"
  fi
  systemctl restart gpu-thermal-watchdog
  log "Thermal watchdog map -> ${want}"
}

start_container() {
  if [[ "$(ct_state "${VMID}")" != running ]]; then
    log "Starting LXC ${VMID}"
    pct start "${VMID}"
  fi
  for _ in {1..60}; do
    if run_in_container test -d /run/systemd/system >/dev/null 2>&1 \
        && run_in_container getent hosts archive.ubuntu.com >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done
  die "container did not come up with DNS in time"
}

install_packages() {
  log "Build tools, ${ROCM_PACKAGE} ${ROCM_VERSION}"
  pct exec "${VMID}" -- env ROCM_PACKAGE="${ROCM_PACKAGE}" ROCM_VERSION="${ROCM_VERSION}" \
    ROCM_ROOT="${ROCM_ROOT}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
tools=(build-essential cmake ninja-build pkg-config git curl ca-certificates gnupg python3-venv
  python3-dev python3-pip ccache tmux openssh-server sudo jq htop)
apt-get update -q
apt-get install -y -q --no-install-recommends "${tools[@]}"
# SSH clients pass LANG=en_US.UTF-8; without the locale every login warns.
locale -a | grep -qx 'en_US.utf8' || locale-gen en_US.UTF-8 >/dev/null

if [ "$(dpkg-query -W -f='${Version}' "$ROCM_PACKAGE" 2>/dev/null || true)" != "$ROCM_VERSION" ]; then
  install -d -m 0755 /etc/apt/keyrings
  [ -s /etc/apt/keyrings/amdrocm.gpg ] \
    || curl -fsSL https://stable.repo.amd.com/rocm/gpg/packages.gpg | gpg --dearmor -o /etc/apt/keyrings/amdrocm.gpg
  cat >/etc/apt/sources.list.d/amdrocm-stable.sources <<'SRC'
X-Repo-Id: amdrocm-stable
Types: deb
URIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu2404/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/amdrocm.gpg
Enabled: yes
SRC
  apt-get update -q
  apt-get install -y -q --no-install-recommends "${ROCM_PACKAGE}=${ROCM_VERSION}"
  # Its dependencies are pinned to the same version by the package itself.
  apt-mark hold "$ROCM_PACKAGE" >/dev/null
fi
[ -d "$ROCM_ROOT/lib" ] || { echo "FATAL: ${ROCM_ROOT}/lib missing after the install" >&2; exit 1; }

# No Vulkan workload shares this container, so ROCm can sit on every login's paths.
cat >/etc/profile.d/rocm.sh <<PROFILE
export ROCM_PATH=${ROCM_ROOT}
export PATH="\${ROCM_PATH}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${ROCM_PATH}/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
PROFILE
echo "rocm: $(dpkg-query -W -f='${Version}' "$ROCM_PACKAGE")"
CONTAINER_SCRIPT
}

create_agent_user() {
  log "User ${AGENT_USER} (UID ${AGENT_UID}), sudo inside the container"
  pct exec "${VMID}" -- bash -s -- "${AGENT_USER}" "${AGENT_UID}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
user="$1"; uid="$2"
getent group render >/dev/null || groupadd --system render
id "$user" >/dev/null 2>&1 || useradd --create-home --uid "$uid" --shell /bin/bash "$user"
usermod -aG sudo,render,video "$user"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" >"/etc/sudoers.d/${user}"
chmod 0440 "/etc/sudoers.d/${user}"
visudo -cq
CONTAINER_SCRIPT
}

# CT KEYS_FROM_VMID's authorized_keys for AGENT_USER, plus AGENT_SSH_PUBKEY.
authorized_keys() {
  if [[ -n ${KEYS_FROM_VMID} && "$(ct_state "${KEYS_FROM_VMID}")" == running ]]; then
    pct exec "${KEYS_FROM_VMID}" -- runuser -u "${AGENT_USER}" -- cat "/home/${AGENT_USER}/.ssh/authorized_keys" \
      | grep -E '^(ssh-|ecdsa-|sk-)' || true
  else
    log "WARNING: CT ${KEYS_FROM_VMID:-?} is not running; its keys are not copied" >&2
  fi
  [[ -z ${AGENT_SSH_PUBKEY} ]] || printf '%s\n' "${AGENT_SSH_PUBKEY}"
}

configure_ssh() {
  local keys
  keys="$(authorized_keys)"
  [[ -n ${keys} ]] || log "WARNING: no key to authorize; add one to ~${AGENT_USER}/.ssh/authorized_keys"
  log "sshd: keys only, no root login"
  pct exec "${VMID}" -- bash -s -- "${AGENT_USER}" "${keys}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
user="$1"; pubkeys="$2"
cat >/etc/ssh/sshd_config.d/10-ds41-engine.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
SSHD
home="$(getent passwd "$user" | cut -d: -f6)"
install -d -m 0700 -o "$user" -g "$user" "${home}/.ssh"
keys="${home}/.ssh/authorized_keys"
touch "$keys"
while IFS= read -r key; do
  [ -n "$key" ] || continue
  grep -qxF "$key" "$keys" || printf '%s\n' "$key" >>"$keys"
done <<<"$pubkeys"
chown "$user:$user" "$keys"
chmod 0600 "$keys"
# Ubuntu 24.04 starts sshd from a socket, so its runtime directory is missing until the
# first connection, and `sshd -t` refuses to run without it.
install -d -m 0755 /run/sshd
sshd -t
systemctl enable --now ssh >/dev/null
systemctl restart ssh
echo "authorized_keys entries: $(grep -c . "$keys" || true)"
CONTAINER_SCRIPT
}

ct_gid() {
  run_in_container getent group "$1" | cut -d: -f3
}

# /dev/kfd and GPU 2's nodes at their real names: HIP opens /dev/dri/renderD*, and a
# different name inside the container breaks DRM authentication (../README.md). The
# unprivileged container's device cgroup still allows every device no rule denies, and KFD
# reports every GPU whose render node the cgroup allows; with GPU 1 in that list ROCm 10
# fails ("Failed to set mem policy for GPU") and finds no device, so GPU 1's DRM nodes are
# denied. Prints "changed" when a container restart is needed to apply the entries.
attach_gpu2() {
  local render card rgid vgid want have keys kind node deny=""
  render="$(node_of "${GPU2_PCI}" render)"; card="$(node_of "${GPU2_PCI}" card)"
  rgid="$(ct_gid render)"; vgid="$(ct_gid video)"
  [[ ${rgid} =~ ^[0-9]+$ && ${vgid} =~ ^[0-9]+$ ]] || die "CT ${VMID} has no render or video group"
  [[ "$(stat -L -c %F "${KFD_NODE}" 2>/dev/null)" == "character special file" ]] || die "the host has no ${KFD_NODE}"

  want="$(printf 'dev0: %s,gid=%s,mode=0660\ndev1: /dev/dri/%s,gid=%s,mode=0660\ndev2: /dev/dri/%s,gid=%s,mode=0660' \
    "${KFD_NODE}" "${rgid}" "${render}" "${rgid}" "${card}" "${vgid}")"
  have="$(grep -E '^dev[0-9]+: ' "$(conf_path)" || true)"
  if [[ ${have} != "${want}" ]]; then
    [[ -z "$(grep -vE '^dev[0-9]+: (/dev/kfd|/dev/dri/)' <<<"${have}" || true)" ]] \
      || die "CT ${VMID} passes through other devices; review $(conf_path)"
    keys="$(cut -d: -f1 <<<"${have}" | grep . | paste -sd, - || true)"
    [[ -z ${keys} ]] || pct set "${VMID}" --delete "${keys}"
    pct set "${VMID}" --dev0 "${KFD_NODE},gid=${rgid},mode=0660" \
      --dev1 "/dev/dri/${render},gid=${rgid},mode=0660" --dev2 "/dev/dri/${card},gid=${vgid},mode=0660"
    log "GPU 2 (${GPU2_PCI}) -> CT ${VMID} as ${render}, ${card}, with ${KFD_NODE}" >&2
    echo changed
  fi

  for kind in render card; do
    node="$(readlink -f "${DRI_BY_PATH}/pci-${GPU1_PCI}-${kind}")"
    [[ -c ${node} ]] || die "${DRI_BY_PATH}/pci-${GPU1_PCI}-${kind} does not resolve to a device node"
    deny+="lxc.cgroup2.devices.deny: c 226:$((16#$(stat -c %T "${node}"))) rwm"$'\n'
  done
  have="$(grep '^lxc.cgroup2.devices.deny: c 226:' "$(conf_path)" || true)"
  if [[ "${have}"$'\n' != "${deny}" ]]; then
    rewrite_conf '^lxc\.cgroup2\.devices\.deny: c 226:' "${deny}"
    log "CT ${VMID} denies GPU 1's DRM nodes: $(grep -o 'c 226:[0-9]*' <<<"${deny}" | paste -sd' ' -)" >&2
    echo changed
  fi
}

restart_container() {
  log "Restarting CT ${VMID} to apply the device entries"
  pct shutdown "${VMID}" --timeout 120 || pct stop "${VMID}"
  pct start "${VMID}"
  for _ in {1..30}; do
    run_in_container test -d /run/systemd/system 2>/dev/null && return 0
    sleep 2
  done
  die "CT ${VMID} did not come back"
}

check_rocm() {
  local n
  n="$(run_in_container runuser -u "${AGENT_USER}" -- "${ROCM_ROOT}/bin/rocminfo" 2>/dev/null \
    | grep -cE '^[[:space:]]+Name:[[:space:]]+gfx[0-9a-f]+[[:space:]]*$' || true)"
  [[ ${n} == 1 ]] || die "ROCm lists ${n:-no} GPUs in CT ${VMID}, not one"
  log "ROCm lists one GPU in CT ${VMID}"
}

print_summary() {
  local ip
  ip="$(run_in_container hostname -I 2>/dev/null | awk '{print $1}' || true)"

  cat <<SUMMARY

==> LXC ${VMID} (${LXC_HOSTNAME}) is ready.

  IP (this boot):   ${ip:-unknown}  (reserve MAC ${MAC} on the router)
  Login:            ssh ${AGENT_USER}@${ip:-${LXC_HOSTNAME}.lan}  (key only)
  Mounts:           /models and /owner-telemetry read-only, /models-dev writable
  Resources:        CPUs ${CPUSET}, ${MEMORY_MB} MiB, GPU 2; onboot=${START_ON_BOOT}
  Watchdog:         GPU 2 -> CT ${VMID} (the whole container)

  The card to CT ${OTHER_VMID:-?}:  strata-v620's tools/v620/host/host-switch-gpu2.sh ${VMID} ${OTHER_VMID:-?}
  Engine builds and CT 125's service: marchah/strata-v620, tools/v620 (README.md here).
SUMMARY
}

main() {
  local changed
  if [[ ${ENGINE} == "-h" || ${ENGINE} == "--help" ]]; then
    usage
    exit 0
  fi
  [[ -n ${VMID} && -n ${LXC_HOSTNAME} ]] || { usage >&2; exit 2; }

  require_root
  require_command pct
  require_command pveam

  assert_gpu2_free
  download_template_if_missing
  prepare_host_dirs
  create_container
  configure_container
  write_guest_firewall
  set_watchdog_map
  start_container
  install_packages
  create_agent_user
  configure_ssh
  # An assignment, so a failure inside attach_gpu2 stops the script.
  changed="$(attach_gpu2)"
  [[ -z ${changed} ]] || restart_container
  check_rocm
  print_summary
}

main "$@"
