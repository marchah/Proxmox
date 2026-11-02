#!/usr/bin/env bash

set -Eeuo pipefail

# --- Config (override any via VAR=value) -------------------------------------
# One container per DeepSeek-V4.1-Flash engine, so each engine's build and runtime stay
# apart. The agent's SSH keys come from the other one.
ENGINE="${1:-}"
case "${ENGINE}" in
  # CT 125 serves its API to the LAN on :1234, without guest firewall rules.
  strata) DEFAULT_VMID=125; DEFAULT_HOSTNAME=ds41-strata; DEFAULT_FIREWALL=0; DEFAULT_KEYS_FROM=126 ;;
  llama) DEFAULT_VMID=126; DEFAULT_HOSTNAME=ds41-llama; DEFAULT_FIREWALL=1; DEFAULT_KEYS_FROM=125 ;;
  *) DEFAULT_VMID=""; DEFAULT_HOSTNAME=""; DEFAULT_FIREWALL=1; DEFAULT_KEYS_FROM="" ;;
esac
VMID="${VMID:-${DEFAULT_VMID}}"
LXC_HOSTNAME="${LXC_HOSTNAME:-${DEFAULT_HOSTNAME}}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
# The newest build of this release's standard template, unless TEMPLATE names one. AMD's
# ROCm repository has a path per Ubuntu release, which the container's own release picks.
UBUNTU_RELEASE="${UBUNTU_RELEASE:-24.04}"
TEMPLATE="${TEMPLATE:-}"
ROOT_STORAGE="${ROOT_STORAGE:-local-lvm}"
# ROCm is about 8 GB; one engine's builds and logs fit in the rest.
ROOT_SIZE_GB="${ROOT_SIZE_GB:-100}"
# Cores 8-31 with their SMT siblings 40-63, shared by CT 125 and CT 126: ds41-host.sh lets
# one of them hold GPU 2 and run. Strata's engine pins one thread per physical core. CT 120
# and CT 121 keep cores 0-7: Proxmox's balancer moves `cores` guests off the CPUs of a
# running container with its own cpuset.
CPUSET="${CPUSET:-8-31,40-63}"
CORES="${CORES:-48}"
# The limit without GPU 2. ds41-host.sh take raises it to what the other guests leave.
MEMORY_MB="${MEMORY_MB:-65536}"
SWAP_MB="${SWAP_MB:-0}"
BRIDGE="${BRIDGE:-vmbr0}"
# Fixed MAC so the router's DHCP reservation is deterministic: BC:24:11:C0:DE:<VMID's last two digits>.
MAC="${MAC:-BC:24:11:C0:DE:${VMID: -2}}"
# ds41-host.sh take turns autostart on for the container holding GPU 2.
START_ON_BOOT="${START_ON_BOOT:-0}"
GUEST_FIREWALL="${GUEST_FIREWALL:-${DEFAULT_FIREWALL}}"

# The shared GGUF store read-only, the directory results come back through, and the
# owner's telemetry read-only. Container UID 1000 is host UID 101000 in an unprivileged
# container.
MODELS_DIR="${MODELS_DIR:-/mnt/models/store}"
DEV_DIR="${DEV_DIR:-/mnt/models/store/dev}"
DEV_DIR_OWNER="${DEV_DIR_OWNER:-101000:101000}"
TELEMETRY_DIR="${TELEMETRY_DIR:-/mnt/ds41-telemetry}"

# The newest amdrocm-core-dev<series>-<ROCM_GFX> in AMD's repository. A container that has
# one keeps it: a newer series installs beside it under its own /opt/rocm/core-<series>.
ROCM_GFX="${ROCM_GFX:-gfx1030}"

AGENT_USER="${AGENT_USER:-agent}"
AGENT_UID="${AGENT_UID:-1000}"
# The agent's authorized_keys are copied from this container, so the same keys log in.
KEYS_FROM_VMID="${KEYS_FROM_VMID:-${DEFAULT_KEYS_FROM}}"
# An extra public key allowed to log in as AGENT_USER.
AGENT_SSH_PUBKEY="${AGENT_SSH_PUBKEY:-}"

# Guest firewall rules: SSH in from the LAN; out only DNS to the router and the internet.
# They apply only while the datacenter firewall is on, which stays off (owner, 2026-10-17).
LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"
ROUTER_IP="${ROUTER_IP:-192.168.1.1}"

usage() {
  cat <<'USAGE'
Create a container that runs one DeepSeek-V4.1-Flash engine on GPU 2 (README.md). Run on
the Proxmox host as root.

  ./create-lxc-ds41-engine.sh strata   # CT 125 ds41-strata: upstream Strata (strata-dsv41)
  ./create-lxc-ds41-engine.sh llama    # CT 126 ds41-llama: llama.cpp
  ./ds41-host.sh take 125              # then GPU 2, its memory and autostart

Creates an unprivileged Ubuntu LXC (the newest UBUNTU_RELEASE template) with the newest
ROCm for ROCM_GFX, build tools, the user `agent` (passwordless sudo inside the container,
groups video and render) and key-only sshd. The agent's authorized_keys are copied from the
other engine container (KEYS_FROM_VMID), plus AGENT_SSH_PUBKEY. No GitHub credentials:
results come back through /models-dev. The model store is mounted read-only at /models, the
owner telemetry read-only at /owner-telemetry, and /models-dev is writable. Both containers
share the CPUs in CPUSET.

GPU 2 is not attached here: only one of CT 125 and CT 126 holds it, and ds41-host.sh moves
it with the thermal watchdog's map.

Re-running is safe: an existing container is configured, not recreated, and keeps its
ROCm.
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

resolve_template() {
  [[ -n ${TEMPLATE} ]] && return
  pveam update >/dev/null
  TEMPLATE="$(pveam available --section system | awk '{print $2}' \
    | grep -E "^ubuntu-${UBUNTU_RELEASE}-standard_.*_amd64\.tar\.zst$" | sort -V | tail -1)"
  [[ -n ${TEMPLATE} ]] || die "pveam lists no ubuntu-${UBUNTU_RELEASE}-standard template"
}

download_template_if_missing() {
  if [[ -f "/var/lib/vz/template/cache/${TEMPLATE}" ]]; then
    return
  fi
  log "Downloading LXC template ${TEMPLATE}"
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
}

prepare_host_dirs() {
  [[ -d ${MODELS_DIR} ]] || die "${MODELS_DIR} is missing; is the models store mounted?"
  install -d -m 0755 "${DEV_DIR}"
  chown "${DEV_DIR_OWNER}" "${DEV_DIR}"
  mountpoint -q "${TELEMETRY_DIR}" || die "${TELEMETRY_DIR} is not mounted; /etc/fstab needs:
  tmpfs ${TELEMETRY_DIR} tmpfs size=64m,mode=0755,nosuid,nodev,noexec,x-systemd.before=pve-guests.service 0 0"
}

create_container() {
  if container_exists; then
    log "CT ${VMID} exists; configuring it in place"
    return
  fi

  log "Creating LXC ${VMID} (${LXC_HOSTNAME}) from ${TEMPLATE}, mac=${MAC}"
  # nesting=1: systemd in an unprivileged container cannot start logind without it,
  # and every SSH login then waits 25 s on D-Bus (see coder-runner).
  pct create "${VMID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "${LXC_HOSTNAME}" \
    --cores "${CORES}" \
    --memory "${MEMORY_MB}" \
    --swap "${SWAP_MB}" \
    --rootfs "${ROOT_STORAGE}:${ROOT_SIZE_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,hwaddr=${MAC},type=veth,firewall=${GUEST_FIREWALL}" \
    --unprivileged 1 \
    --features "nesting=1" \
    --onboot "${START_ON_BOOT}" \
    --timezone host \
    --ostype ubuntu
}

configure_container() {
  local conf="/etc/pve/lxc/${VMID}.conf" tmp

  log "Mounts: /models and /owner-telemetry read-only, /models-dev writable"
  pct set "${VMID}" --mp0 "${MODELS_DIR},mp=/models,ro=1" --mp1 "${DEV_DIR},mp=/models-dev" \
    --mp2 "${TELEMETRY_DIR},mp=/owner-telemetry,ro=1"

  # Both engines page-lock host memory for experts and transfer buffers. An unprivileged
  # container cannot raise RLIMIT_MEMLOCK itself, so LXC sets it for the container.
  if ! grep -q '^lxc.prlimit.memlock:' "${conf}"; then
    log "lxc.prlimit.memlock: unlimited"
    printf 'lxc.prlimit.memlock: unlimited\n' >>"${conf}"
  fi

  # Rewritten from a filtered copy: /etc/pve is the cluster filesystem.
  if ! grep -qxF "lxc.cgroup2.cpuset.cpus: ${CPUSET}" "${conf}"; then
    log "lxc.cgroup2.cpuset.cpus: ${CPUSET} (applies at the next start)"
    tmp="$(mktemp)"
    grep -v '^lxc.cgroup2.cpuset.cpus:' "${conf}" >"${tmp}" || true
    printf 'lxc.cgroup2.cpuset.cpus: %s\n' "${CPUSET}" >>"${tmp}"
    cat "${tmp}" >"${conf}"
    rm -f "${tmp}"
  fi
}

write_guest_firewall() {
  [[ ${GUEST_FIREWALL} == 1 ]] || return 0
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

start_container() {
  if [[ "$(pct status "${VMID}" | awk '{print $2}')" != running ]]; then
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
  log "Build tools; ROCm for ${ROCM_GFX}"
  pct exec "${VMID}" -- env ROCM_GFX="${ROCM_GFX}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
tools=(build-essential cmake ninja-build pkg-config git curl ca-certificates gnupg python3-venv
  python3-dev python3-pip ccache tmux openssh-server sudo jq htop)
apt-get update -q
apt-get install -y -q --no-install-recommends "${tools[@]}"
# SSH clients pass LANG=en_US.UTF-8; without the locale every login warns.
locale -a | grep -qx 'en_US.utf8' || locale-gen en_US.UTF-8 >/dev/null

. /etc/os-release
install -d -m 0755 /etc/apt/keyrings
[ -s /etc/apt/keyrings/amdrocm.gpg ] \
  || curl -fsSL https://stable.repo.amd.com/rocm/gpg/packages.gpg | gpg --dearmor -o /etc/apt/keyrings/amdrocm.gpg
cat >/etc/apt/sources.list.d/amdrocm-stable.sources <<SRC
X-Repo-Id: amdrocm-stable
Types: deb
URIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu${VERSION_ID//./}/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/amdrocm.gpg
Enabled: yes
SRC

# The series is part of the package name (amdrocm-core-dev10.1-gfx1030), so the newest
# series is the newest name. Its dependencies are pinned to its version by the package.
# Installed means the status letter is i, whatever the selection (a held package is hi).
pattern="^amdrocm-core-dev[0-9]+\.[0-9]+-${ROCM_GFX}\$"
pkg="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'amdrocm-core-dev*' 2>/dev/null \
  | awk 'substr($1, 2, 1) == "i" {print $2}' | grep -E "$pattern" | sort -V | tail -1 || true)"
if [ -z "$pkg" ]; then
  apt-get update -q
  pkg="$(apt-cache pkgnames amdrocm-core-dev | grep -E "$pattern" | sort -V | tail -1 || true)"
  [ -n "$pkg" ] || { echo "FATAL: AMD's ubuntu${VERSION_ID//./} repository has no ${ROCM_GFX} core package" >&2; exit 1; }
  apt-get install -y -q --no-install-recommends "$pkg"
fi
series="${pkg#amdrocm-core-dev}"; series="${series%-"${ROCM_GFX}"}"
root="/opt/rocm/core-${series}"
[ -d "$root/lib" ] || { echo "FATAL: ${root}/lib missing after the install" >&2; exit 1; }

# No Vulkan workload shares this container, so ROCm can sit on every login's paths.
cat >/etc/profile.d/rocm.sh <<PROFILE
export ROCM_PATH=${root}
export PATH="\${ROCM_PATH}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${ROCM_PATH}/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
PROFILE
echo "rocm: ${pkg} $(dpkg-query -W -f='${Version}' "$pkg") at ${root}"
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
  if [[ "$(pct status "${KEYS_FROM_VMID}" 2>/dev/null | awk '{print $2}')" == running ]]; then
    pct exec "${KEYS_FROM_VMID}" -- runuser -u "${AGENT_USER}" -- cat "/home/${AGENT_USER}/.ssh/authorized_keys" \
      | grep -E '^(ssh-|ecdsa-|sk-)' || true
  else
    log "WARNING: CT ${KEYS_FROM_VMID} is not running; its keys are not copied" >&2
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

print_summary() {
  local ip
  ip="$(run_in_container hostname -I 2>/dev/null | awk '{print $1}' || true)"

  cat <<SUMMARY

==> LXC ${VMID} (${LXC_HOSTNAME}) is ready.

  IP (this boot):   ${ip:-unknown}  (reserve MAC ${MAC} on the router)
  Login:            ssh ${AGENT_USER}@${ip:-<ip>}  (key only)
  Mounts:           /models and /owner-telemetry read-only, /models-dev writable
  CPUs:             ${CPUSET}, shared with the other engine container

  GPU 2 is not attached: ./ds41-host.sh take ${VMID} gives it the card, its memory and
  autostart, and stops the other one.
SUMMARY
}

main() {
  if [[ ${ENGINE} == "-h" || ${ENGINE} == "--help" ]]; then
    usage
    exit 0
  fi
  [[ -n ${VMID} && -n ${LXC_HOSTNAME} ]] || { usage >&2; exit 2; }

  require_root
  require_command pct
  require_command pveam

  prepare_host_dirs
  if ! container_exists; then
    resolve_template
    download_template_if_missing
  fi
  create_container
  configure_container
  write_guest_firewall
  start_container
  install_packages
  create_agent_user
  configure_ssh
  print_summary
}

main "$@"
