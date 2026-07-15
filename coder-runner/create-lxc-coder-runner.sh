#!/usr/bin/env bash

set -Eeuo pipefail

# --- Config (override any via VAR=value) -------------------------------------
VMID="${VMID:-122}"
LXC_HOSTNAME="${LXC_HOSTNAME:-coder-runner}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-}"
ROOT_STORAGE="${ROOT_STORAGE:-local-lvm}"
ROOT_SIZE_GB="${ROOT_SIZE_GB:-24}"
MEMORY_MB="${MEMORY_MB:-4096}"
SWAP_MB="${SWAP_MB:-1024}"
CORES="${CORES:-4}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
# Fixed MAC so the dnsmasq reservation (10.10.10.122 coder-runner) is deterministic.
MAC="${MAC:-BC:24:11:C0:DE:22}"
PASSWORD="${PASSWORD:-}"
START_ON_BOOT="${START_ON_BOOT:-1}"

# Pinned Node.js — official prebuilt linux-x64 tarball, verified by SHA-256 (no
# NodeSource `curl | bash`; matches the repo's llama.cpp/llama-swap pinning). Bump
# VERSION + SHA256 together from https://nodejs.org/dist/<VERSION>/SHASUMS256.txt
# (the `node-<VERSION>-linux-x64.tar.xz` line). mealdeal + the agent repos need >= 26.
NODE_VERSION="${NODE_VERSION:-v26.5.0}"
NODE_SHA256="${NODE_SHA256:-9f619528f1db5ddc41dccf54211066fb42228d69a156733c69cb9d6cc92e358c}"

# Public key of the caller (CT 121 hermes) that will drive this runner over ssh.
# Get it on CT 121 with:  cat /root/.ssh/coder-runner.pub
# If empty, the container is still created; add the key later to
#   /root/.ssh/authorized_keys  inside the container.
CODER_SSH_PUBKEY="${CODER_SSH_PUBKEY:-}"

# Optional: install aider in the runner (off by default — the coder edits
# natively on CT 121; only *execution* is offloaded here). When 1, aider talks
# to the LLM runtime (CT 120) at the address below.
INSTALL_AIDER="${INSTALL_AIDER:-0}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-llamacpp}"
OPENAI_API_BASE="${OPENAI_API_BASE:-http://${TARGET_HOSTNAME}:1234/v1}"

usage() {
  cat <<'USAGE'
Create the coder-runner LXC: a generic, disposable execution sandbox for the
autonomous coding loop. The Hermes LXC (CT 121) drives it over ssh+rsync so that
untrusted project code (npm ci, builds, tests) runs HERE, not inside CT 121.

Run this script on the Proxmox host as root.

Useful overrides:
  VMID=122 LXC_HOSTNAME=coder-runner ./create-lxc-coder-runner.sh
  CODER_SSH_PUBKEY="$(ssh pve pct exec 121 -- cat /root/.ssh/coder-runner.pub)" ./create-lxc-coder-runner.sh
  NODE_VERSION=v26.5.0 NODE_SHA256=<linux-x64 sha> ./create-lxc-coder-runner.sh
  INSTALL_AIDER=1 ./create-lxc-coder-runner.sh
  MEMORY_MB=8192 CORES=6 ./create-lxc-coder-runner.sh

Creates an unprivileged Debian LXC with: pinned Node (NODE_VERSION), git, build toolchain,
rsync, and sshd (authorizing CODER_SSH_PUBKEY). It holds NO secrets and is
disposable — rebuild any time with:  pct destroy 122 --purge  &&  re-run this.
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

resolve_template() {
  if [[ -n ${TEMPLATE} ]]; then
    return
  fi

  log "Resolving latest Debian 12 LXC template"
  TEMPLATE="$(
    pveam available --section system \
      | awk '/debian-12-standard_[^[:space:]]+_amd64\.tar\.zst/ {print $2}' \
      | sort -V \
      | tail -n 1
  )"

  [[ -n ${TEMPLATE} ]] || die "could not find a Debian 12 LXC template via pveam"
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

create_container() {
  local ostemplate
  local rootfs
  local net0
  local -a create_args

  ostemplate="$(template_ref)"
  rootfs="${ROOT_STORAGE}:${ROOT_SIZE_GB}"
  net0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},hwaddr=${MAC},type=veth"

  log "Creating coder-runner LXC ${VMID} (${LXC_HOSTNAME}) mac=${MAC}"

  # Unprivileged, no nesting/keyctl needed — there is no docker inside; execution
  # is native Node/git on this container's own userspace.
  create_args=(
    "${VMID}"
    "${ostemplate}"
    --hostname "${LXC_HOSTNAME}"
    --cores "${CORES}"
    --memory "${MEMORY_MB}"
    --swap "${SWAP_MB}"
    --rootfs "${rootfs}"
    --net0 "${net0}"
    --unprivileged 1
    --onboot "${START_ON_BOOT}"
    --ostype debian
  )

  if [[ -n ${PASSWORD} ]]; then
    create_args+=(--password "${PASSWORD}")
  fi

  pct create "${create_args[@]}"
}

start_container() {
  # Always start: provisioning runs INSIDE the container (install/ssh/config), so a
  # stopped CT would just hang wait_for_container and leave a partial CT. If you want
  # it off afterward, `pct stop` it once provisioning finishes.
  log "Starting LXC ${VMID}"
  pct start "${VMID}"
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

install_toolchain() {
  log "Installing base packages + git toolchain + rsync + sshd"
  run_in_container bash -lc "apt-get update"
  run_in_container bash -lc "DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git jq build-essential python3 python3-venv rsync openssh-server pipx procps xz-utils"

  log "Installing pinned Node ${NODE_VERSION} (official tarball, SHA-256 verified)"
  pct exec "${VMID}" -- bash -s -- "${NODE_VERSION}" "${NODE_SHA256}" <<'CONTAINER_SCRIPT'
set -euo pipefail
NODE_VERSION="$1"; NODE_SHA256="$2"

if [ "$(node -v 2>/dev/null || true)" != "${NODE_VERSION}" ]; then
  arch="$(uname -m)"
  case "$arch" in
    x86_64) narch=x64 ;;
    aarch64) narch=arm64 ;;
    *) echo "unsupported arch: $arch" >&2; exit 1 ;;
  esac
  tarball="node-${NODE_VERSION}-linux-${narch}.tar.xz"
  curl --fail --show-error --silent --location -o "/tmp/${tarball}" "https://nodejs.org/dist/${NODE_VERSION}/${tarball}"
  if [ "$narch" = x64 ]; then
    # NODE_SHA256 pins the linux-x64 tarball (this repo's host is amd64).
    printf '%s  /tmp/%s\n' "${NODE_SHA256}" "${tarball}" | sha256sum --check -
  else
    echo "WARNING: NODE_SHA256 pins linux-x64; skipping checksum on ${narch}" >&2
  fi
  tar -xJf "/tmp/${tarball}" -C /usr/local --strip-components=1
  rm -f "/tmp/${tarball}"
fi

corepack enable 2>/dev/null || true
echo "node: $(node -v)  npm: $(npm -v)"
[ "$(node -v 2>/dev/null || true)" = "${NODE_VERSION}" ] || { echo "Node ${NODE_VERSION} install failed" >&2; exit 1; }
CONTAINER_SCRIPT
}

configure_ssh() {
  log "Configuring sshd + authorized key + /build workdir"
  run_in_container bash -lc "systemctl enable --now ssh"
  run_in_container bash -lc "install -d -m 700 /root/.ssh && install -d -m 755 /build"

  if [[ -n ${CODER_SSH_PUBKEY} ]]; then
    # Pass the key as a positional arg (never interpolate into the quoted heredoc).
    pct exec "${VMID}" -- bash -s -- "${CODER_SSH_PUBKEY}" <<'CONTAINER_SCRIPT'
set -euo pipefail
PUBKEY="$1"
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
grep -qxF "$PUBKEY" /root/.ssh/authorized_keys || printf '%s\n' "$PUBKEY" >> /root/.ssh/authorized_keys
echo "authorized_keys entries: $(wc -l < /root/.ssh/authorized_keys)"
CONTAINER_SCRIPT
  else
    log "WARNING: CODER_SSH_PUBKEY empty — add CT 121's key to /root/.ssh/authorized_keys later"
  fi
}

configure_runner_env() {
  if [[ ${INSTALL_AIDER} != 1 ]]; then
    return
  fi
  log "Installing aider (optional) pointed at ${OPENAI_API_BASE}"
  pct exec "${VMID}" -- bash -s -- "${OPENAI_API_BASE}" <<'CONTAINER_SCRIPT'
set -euo pipefail
OPENAI_API_BASE="$1"
pipx install aider-chat || pipx upgrade aider-chat || true
pipx ensurepath >/dev/null 2>&1 || true
printf 'export OPENAI_API_BASE=%s\nexport OPENAI_API_KEY=dummy\n' "$OPENAI_API_BASE" > /etc/profile.d/aider.sh
echo "aider: $(/root/.local/bin/aider --version 2>/dev/null || echo 'installed (restart shell for PATH)')"
CONTAINER_SCRIPT
}

print_summary() {
  local ip
  ip="$(pct exec "${VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

  cat <<SUMMARY

==> coder-runner LXC ${VMID} (${LXC_HOSTNAME}) is ready.

  IP (this boot):   ${ip:-unknown}
  Reserved name:    coder-runner  (add 10.10.10.122 reservation in host-net/wifi-nat/wifi-nat.env)
  Node:             $(pct exec "${VMID}" -- bash -lc 'node -v' 2>/dev/null || echo '?')
  SSH:              key-only; driven by CT 121 (hermes)
  Build workdir:    /build

  Verify from CT 121:
    pct exec 121 -- ssh -i /root/.ssh/coder-runner -o StrictHostKeyChecking=accept-new coder-runner 'node -v'

  Rebuild (disposable):
    pct stop ${VMID} && pct destroy ${VMID} --purge
    CODER_SSH_PUBKEY=... ./create-lxc-coder-runner.sh
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
  require_command tar

  assert_vmid_available
  resolve_template
  download_template_if_missing
  create_container
  start_container
  wait_for_container
  install_toolchain
  configure_ssh
  configure_runner_env
  print_summary
}

main "$@"
