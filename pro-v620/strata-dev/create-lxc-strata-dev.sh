#!/usr/bin/env bash

set -Eeuo pipefail

# --- Config (override any via VAR=value) -------------------------------------
VMID="${VMID:-124}"
LXC_HOSTNAME="${LXC_HOSTNAME:-strata-dev}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
# AMD's ROCm 10.0 repository targets ubuntu2404, as in CT 123.
TEMPLATE="${TEMPLATE:-ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"
ROOT_STORAGE="${ROOT_STORAGE:-local-lvm}"
ROOT_SIZE_GB="${ROOT_SIZE_GB:-200}"
# The starting limit while CT 123 still runs Flash-Next. Handing GPU 2 to this container
# stops CT 123, and the limit is raised then (PLAN.md, Memory). The fork plans reject
# runs that swap.
MEMORY_MB="${MEMORY_MB:-65536}"
SWAP_MB="${SWAP_MB:-0}"
CORES="${CORES:-24}"
BRIDGE="${BRIDGE:-vmbr0}"
# Fixed MAC so the router's DHCP reservation for strata-dev is deterministic.
MAC="${MAC:-BC:24:11:C0:DE:24}"
START_ON_BOOT="${START_ON_BOOT:-1}"

# The shared GGUF store, bound read-only, and the one directory the agent may write.
# Container UID 1000 is host UID 101000 in an unprivileged container.
MODELS_DIR="${MODELS_DIR:-/mnt/models/store}"
DEV_DIR="${DEV_DIR:-/mnt/models/store/dev}"
DEV_DIR_OWNER="${DEV_DIR_OWNER:-101000:101000}"

# ROCm userspace for gfx1030. Keep these equal to ../strata/strata-qwen38fn.env, so CT 123
# and this container run one runtime.
ROCM_PACKAGE="${ROCM_PACKAGE:-amdrocm-core-dev10.0-gfx1030}"
ROCM_VERSION="${ROCM_VERSION:-10.0.0-4}"
ROCM_ROOT="${ROCM_ROOT:-/opt/rocm/core-10.0}"

# OpenCode 2, from the npm tarball its own installer uses. Bump VERSION and SHA256
# together: curl -fsSL "${OPENCODE_URL}" | sha256sum
OPENCODE_VERSION="${OPENCODE_VERSION:-2.0.32}"
OPENCODE_SHA256="${OPENCODE_SHA256:-64a1f4b381c2d2efc18c8d76b2ce399141778b421b54c98b94be8e80803606dc}"
OPENCODE_URL="https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-${OPENCODE_VERSION}.tgz"

AGENT_USER="${AGENT_USER:-agent}"
AGENT_UID="${AGENT_UID:-1000}"
# The DeepSeek fork's checkout; the tmux session starts there.
WORKDIR="${WORKDIR:-/opt/strata-ds41}"
# Public key allowed to log in as AGENT_USER (the owner's Mac).
AGENT_SSH_PUBKEY="${AGENT_SSH_PUBKEY:-}"

# Firewall: SSH in from the LAN; out only DNS to the router and the internet.
LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"
ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
# Guest firewall rules only apply while the datacenter firewall is on. Turning it on
# changes the whole host, so it needs this switch; see enable_datacenter_firewall.
ENABLE_DATACENTER_FIREWALL="${ENABLE_DATACENTER_FIREWALL:-0}"

usage() {
  cat <<'USAGE'
Create the strata-dev LXC: the container in which an OpenCode agent develops the
DeepSeek-V4.1-Flash fork of Strata (PLAN.md in this directory). Run on the Proxmox
host as root.

  AGENT_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" ./create-lxc-strata-dev.sh
  ENABLE_DATACENTER_FIREWALL=1 ./create-lxc-strata-dev.sh   # re-run: also enforce the rules

Creates an unprivileged Ubuntu 24.04 LXC with ROCm (ROCM_PACKAGE), build tools, gh,
tmux, OpenCode (OPENCODE_VERSION), the user `agent` (passwordless sudo inside the
container), key-only sshd, and a tmux session `agent` started at boot. The model store
is mounted read-only at /models; /models-dev is writable. Its firewall allows SSH in
from the LAN and, out, DNS to the router and the internet only.

The GPU is not attached here: handing GPU 2 to this container also stops CT 123 and
changes the thermal watchdog's map, which strata-dev-host.sh does.

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

download_template_if_missing() {
  if [[ -f "/var/lib/vz/template/cache/${TEMPLATE}" ]]; then
    return
  fi
  log "Downloading LXC template ${TEMPLATE}"
  pveam update
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
}

prepare_dev_dir() {
  [[ -d ${MODELS_DIR} ]] || die "${MODELS_DIR} is missing; is the models store mounted?"
  log "Writable model directory ${DEV_DIR} (owner ${DEV_DIR_OWNER})"
  install -d -m 0755 "${DEV_DIR}"
  chown "${DEV_DIR_OWNER}" "${DEV_DIR}"
}

create_container() {
  if container_exists; then
    log "CT ${VMID} exists; configuring it in place"
    return
  fi

  log "Creating LXC ${VMID} (${LXC_HOSTNAME}) mac=${MAC}"
  # nesting=1: systemd in an unprivileged container cannot start logind without it,
  # and every SSH login then waits 25 s on D-Bus (see coder-runner).
  pct create "${VMID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "${LXC_HOSTNAME}" \
    --cores "${CORES}" \
    --memory "${MEMORY_MB}" \
    --swap "${SWAP_MB}" \
    --rootfs "${ROOT_STORAGE}:${ROOT_SIZE_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,hwaddr=${MAC},type=veth,firewall=1" \
    --unprivileged 1 \
    --features "nesting=1" \
    --onboot "${START_ON_BOOT}" \
    --timezone host \
    --ostype ubuntu
}

configure_container() {
  local conf="/etc/pve/lxc/${VMID}.conf"

  log "Mounts: ${MODELS_DIR} read-only at /models, ${DEV_DIR} at /models-dev"
  pct set "${VMID}" --mp0 "${MODELS_DIR},mp=/models,ro=1" --mp1 "${DEV_DIR},mp=/models-dev"

  # Strata page-locks its expert arena and HIP pins transfer buffers. An unprivileged
  # container cannot raise RLIMIT_MEMLOCK itself, so LXC sets it for the container.
  if ! grep -q '^lxc.prlimit.memlock:' "${conf}"; then
    log "lxc.prlimit.memlock: unlimited"
    printf 'lxc.prlimit.memlock: unlimited\n' >>"${conf}"
  fi
}

write_guest_firewall() {
  log "Firewall rules for CT ${VMID}: SSH in from ${LAN_CIDR}; out DNS to ${ROUTER_IP}, internet only"
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
  log "Base packages, ${ROCM_PACKAGE} ${ROCM_VERSION}"
  pct exec "${VMID}" -- env ROCM_PACKAGE="${ROCM_PACKAGE}" ROCM_VERSION="${ROCM_VERSION}" \
    ROCM_ROOT="${ROCM_ROOT}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
tools=(build-essential cmake ninja-build git curl ca-certificates gnupg python3-venv python3-dev
  python3-pip ccache tmux openssh-server sudo gh jq htop)
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
  log "User ${AGENT_USER} (UID ${AGENT_UID}), sudo inside the container, ${WORKDIR}"
  pct exec "${VMID}" -- bash -s -- "${AGENT_USER}" "${AGENT_UID}" "${WORKDIR}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
user="$1"; uid="$2"; workdir="$3"
getent group render >/dev/null || groupadd --system render
id "$user" >/dev/null 2>&1 || useradd --create-home --uid "$uid" --shell /bin/bash "$user"
usermod -aG sudo,render,video "$user"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" >"/etc/sudoers.d/${user}"
chmod 0440 "/etc/sudoers.d/${user}"
visudo -cq
install -d -o "$user" -g "$user" "$workdir"
CONTAINER_SCRIPT
}

configure_ssh() {
  log "sshd: keys only, no root login"
  pct exec "${VMID}" -- bash -s -- "${AGENT_USER}" "${AGENT_SSH_PUBKEY}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
user="$1"; pubkey="$2"
cat >/etc/ssh/sshd_config.d/10-strata-dev.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
SSHD
home="$(getent passwd "$user" | cut -d: -f6)"
install -d -m 0700 -o "$user" -g "$user" "${home}/.ssh"
keys="${home}/.ssh/authorized_keys"
touch "$keys"
if [ -n "$pubkey" ]; then
  grep -qxF "$pubkey" "$keys" || printf '%s\n' "$pubkey" >>"$keys"
fi
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
  [[ -n ${AGENT_SSH_PUBKEY} ]] || log "WARNING: AGENT_SSH_PUBKEY empty; add a key to ~${AGENT_USER}/.ssh/authorized_keys"
}

install_opencode() {
  log "OpenCode ${OPENCODE_VERSION}"
  pct exec "${VMID}" -- bash -s -- "${OPENCODE_VERSION}" "${OPENCODE_SHA256}" "${OPENCODE_URL}" "${AGENT_USER}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
version="$1"; sha="$2"; url="$3"; user="$4"
# It prints `opencode v2.0.32`.
if ! /usr/local/bin/opencode --version 2>/dev/null | grep -qxF "opencode v${version}"; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "${tmp}/opencode.tgz" "$url"
  printf '%s  %s\n' "$sha" "${tmp}/opencode.tgz" | sha256sum --check --quiet -
  tar -xzf "${tmp}/opencode.tgz" -C "$tmp"
  install -m 0755 "${tmp}/package/bin/opencode" /usr/local/bin/opencode
fi

# Updates stay with this script's pin. Force pushes are refused: the private repository
# has no branch rules to stop one.
home="$(getent passwd "$user" | cut -d: -f6)"
install -d -o "$user" -g "$user" "${home}/.config" "${home}/.config/opencode"
config="${home}/.config/opencode/opencode.json"
if [ ! -e "$config" ]; then
  cat >"$config" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "update": "disable",
  "permission": {
    "bash": {
      "*": "allow",
      "git push --force*": "deny",
      "git push -f*": "deny",
      "git push * --force*": "deny",
      "git push * -f*": "deny"
    }
  }
}
JSON
  chown "$user:$user" "$config"
fi
echo "opencode: $(/usr/local/bin/opencode --version)"
CONTAINER_SCRIPT
}

install_agent_session() {
  log "agent-session.service: tmux session 'agent' running OpenCode in ${WORKDIR}"
  pct exec "${VMID}" -- bash -s -- "${AGENT_USER}" "${WORKDIR}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
user="$1"; workdir="$2"
home="$(getent passwd "$user" | cut -d: -f6)"
cat >/etc/systemd/system/agent-session.service <<UNIT
[Unit]
Description=OpenCode agent session (tmux "agent")
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=${user}
Environment=HOME=${home}
WorkingDirectory=${workdir}
# A login shell picks up ROCm's paths. When OpenCode exits, the window stays as a shell.
ExecStart=/usr/bin/tmux new-session -d -s agent -c ${workdir} "bash -lc 'opencode; exec bash -l'"
ExecStop=/usr/bin/tmux kill-session -t agent

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable agent-session >/dev/null
systemctl is-active --quiet agent-session || systemctl start agent-session
echo "agent-session: $(systemctl is-active agent-session)"
CONTAINER_SCRIPT
}

enable_datacenter_firewall() {
  local node host_fw cluster_fw="/etc/pve/firewall/cluster.fw"
  node="$(hostname)"
  host_fw="/etc/pve/nodes/${node}/host.fw"

  if grep -qE '^enable:[[:space:]]*1' "${cluster_fw}" 2>/dev/null; then
    log "Datacenter firewall already on"
    return
  fi
  if [[ ${ENABLE_DATACENTER_FIREWALL} != 1 ]]; then
    log "WARNING: the datacenter firewall is off, so CT ${VMID}'s rules are not enforced." \
      "Re-run with ENABLE_DATACENTER_FIREWALL=1 to turn it on (the host stays unfiltered)."
    return
  fi

  # With the datacenter switch on, the host's own firewall defaults to on with an inbound
  # DROP policy. Turn the host's off first, so only guests with rules are filtered.
  if [[ -e ${host_fw} ]] && ! grep -qE '^enable:[[:space:]]*0' "${host_fw}"; then
    die "${host_fw} exists without 'enable: 0'; review it before turning the datacenter firewall on"
  fi
  if [[ ! -e ${host_fw} ]]; then
    log "Host firewall for ${node}: off (${host_fw})"
    printf '[OPTIONS]\nenable: 0\n' >"${host_fw}"
  fi
  if [[ -e ${cluster_fw} ]]; then
    die "${cluster_fw} exists with the firewall off; review it, then set 'enable: 1' by hand"
  fi
  log "Datacenter firewall: on (${cluster_fw})"
  printf '[OPTIONS]\nenable: 1\n' >"${cluster_fw}"
  pve-firewall compile >/dev/null
  pve-firewall restart
}

print_summary() {
  local ip
  ip="$(run_in_container hostname -I 2>/dev/null | awk '{print $1}' || true)"

  cat <<SUMMARY

==> strata-dev LXC ${VMID} (${LXC_HOSTNAME}) is ready.

  IP (this boot):   ${ip:-unknown}  (reserve MAC ${MAC} on the router)
  Login:            ssh ${AGENT_USER}@${LXC_HOSTNAME}.lan  (key only)
  Agent session:    tmux attach -t agent  (OpenCode ${OPENCODE_VERSION} in ${WORKDIR})
  Models:           /models read-only, /models-dev writable
  Firewall:         $(pve-firewall status 2>/dev/null | head -1)

  GPU 2 is not attached; strata-dev-host.sh hands it over (PLAN.md).
SUMMARY
}

main() {
  if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
  fi

  require_root
  require_command pct
  require_command pveam
  require_command pve-firewall

  download_template_if_missing
  prepare_dev_dir
  create_container
  configure_container
  write_guest_firewall
  start_container
  install_packages
  create_agent_user
  configure_ssh
  install_opencode
  install_agent_session
  enable_datacenter_firewall
  print_summary
}

main "$@"
