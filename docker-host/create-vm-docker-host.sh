#!/usr/bin/env bash

set -Eeuo pipefail

# Create the homelab's Docker host: a Debian VM running Docker + Compose + Portainer CE, which
# hosts the small self-contained web apps (MealDeal and friends) as Compose stacks.
#
# WHY A VM, NOT AN LXC — the rest of this repo is LXCs, so this is the deliberate exception.
# Proxmox recommends Docker in a VM, and Docker-in-LXC needs nesting=1 + keyctl=1 (and is often
# run privileged), which: weakens namespace isolation, puts Docker's overlay2 on top of a
# container filesystem (the classic breakage), tends to need its nesting/AppArmor tweaks redone
# after a Proxmox kernel bump, and shares a kernel with this host's hand-rolled nftables NAT
# (host-net/wifi-nat) that Docker also writes firewall rules into. A VM walls all of that off
# for ~4 GB of RAM. The GPU/LLM containers stay native LXCs — they need host device access and
# have nothing to gain here.
#
# WHY THIS EXISTS AT ALL — one bespoke provisioning script per app does not scale. With this
# host, a new project is a compose file plus a stack in the Portainer UI, and app updates are a
# UI action (or a git webhook) instead of a rebuild pipeline. See docker-host/README.md.
#
# VMID 300: this repo's 100-119/120-139/... ranges allocate CONTAINERS. VMs get their own
# 300+ range so the two numbering schemes never collide.
#
# Run this script on the Proxmox host as root. Idempotent-ish: it refuses to clobber an
# existing VM, but --reinstall-docker re-runs only the in-guest install.

# --- VM config (override any via VAR=value) ---------------------------------
VMID="${VMID:-300}"
VM_NAME="${VM_NAME:-docker-host}"
CORES="${CORES:-4}"
MEMORY_MB="${MEMORY_MB:-4096}"
# Guest disk. Docker images + volumes live here; grow with `qm resize 300 scsi0 +20G`.
DISK_SIZE="${DISK_SIZE:-40G}"
DISK_STORAGE="${DISK_STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
# Fixed MAC so the dnsmasq reservation (10.10.10.100 docker-host) is deterministic and the
# port-forwards keep resolving to this VM across reboots.
MAC="${MAC:-BC:24:11:D0:CE:00}"
START_ON_BOOT="${START_ON_BOOT:-1}"

# --- Debian cloud image (pinned + SHA-512 verified) -------------------------
# Bump DEBIAN_RELEASE/DEBIAN_IMAGE_VERSION/DEBIAN_IMAGE_SHA512 together. Get the checksum from
#   https://cloud.debian.org/images/cloud/<release>/<version>/SHA512SUMS
# genericcloud (not generic) is the KVM/virtio-only variant — smaller, no legacy drivers.
DEBIAN_RELEASE="${DEBIAN_RELEASE:-trixie}"
# Debian names the image file by major version but the URL path by codename — both needed.
DEBIAN_MAJOR="${DEBIAN_MAJOR:-13}"
DEBIAN_IMAGE_VERSION="${DEBIAN_IMAGE_VERSION:-20260722-2547}"
DEBIAN_IMAGE_SHA512="${DEBIAN_IMAGE_SHA512:-735d1b2d0ef265a0c2323fdaa7d46e7bd7a1b984f73e8a785e638034bf07876e26374a9d809d713501270c071b3464d2ada0c5589f07742b95ed853cc6d48f45}"
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/var/lib/vz/template/iso}"

# --- Guest access -----------------------------------------------------------
# Debian's cloud image ships root SSH disabled, so we drive the guest as its default user
# (passwordless sudo) over a dedicated key generated on the host.
CI_USER="${CI_USER:-debian}"
SSH_KEY_FILE="${SSH_KEY_FILE:-/root/.ssh/docker-host}"

# --- Portainer --------------------------------------------------------------
# CE, pinned to an explicit version (not :latest) so a rebuild is reproducible. Upgrading is
# `docker pull` a newer tag + recreate; settings/users/stacks survive in the portainer_data
# volume. Bump from https://hub.docker.com/r/portainer/portainer-ce/tags
PORTAINER_IMAGE="${PORTAINER_IMAGE:-portainer/portainer-ce:2.39.5}"
PORTAINER_HTTPS_PORT="${PORTAINER_HTTPS_PORT:-9443}"
# Where compose stacks are kept in the guest (a git clone of the stacks repo lands here too).
STACKS_DIR="${STACKS_DIR:-/opt/stacks}"

REINSTALL_DOCKER=0

usage() {
  cat <<'USAGE'
Create the Docker host VM (VM 300): Debian + Docker + Compose + Portainer CE, the home for
small self-contained app stacks (MealDeal and future projects).

Run this script on the Proxmox host as root.

Useful overrides:
  VMID=300 VM_NAME=docker-host ./create-vm-docker-host.sh
  MEMORY_MB=8192 CORES=6 DISK_SIZE=80G ./create-vm-docker-host.sh
  DEBIAN_IMAGE_VERSION=<ver> DEBIAN_IMAGE_SHA512=<sha> ./create-vm-docker-host.sh
  PORTAINER_HTTPS_PORT=9443 ./create-vm-docker-host.sh

  ./create-vm-docker-host.sh --reinstall-docker   # re-run ONLY the in-guest install on an
                                                 # existing VM (idempotent; no VM recreate)

Why a VM rather than an LXC (the exception to this repo's LXC-everywhere pattern) is explained
at the top of this script. The GPU/LLM containers stay native LXCs.
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

image_filename() {
  printf 'debian-%s-genericcloud-amd64-%s.qcow2\n' "${DEBIAN_MAJOR}" "${DEBIAN_IMAGE_VERSION}"
}

image_path() {
  printf '%s/%s\n' "${IMAGE_CACHE_DIR}" "$(image_filename)"
}

assert_vmid_available() {
  if qm status "${VMID}" >/dev/null 2>&1; then
    die "VMID ${VMID} already exists (use --reinstall-docker to re-run the guest install, or set VMID=)"
  fi
  # A container sharing the id would make `qm`/`pct` ambiguous for the operator.
  if pct status "${VMID}" >/dev/null 2>&1; then
    die "VMID ${VMID} is already used by a CONTAINER — pick another VMID"
  fi
}

download_image_if_missing() {
  local path
  path="$(image_path)"

  if [[ -f ${path} ]]; then
    log "Cloud image already cached: ${path}"
  else
    log "Downloading Debian ${DEBIAN_RELEASE} cloud image ${DEBIAN_IMAGE_VERSION}"
    install -d -m 755 "${IMAGE_CACHE_DIR}"
    curl -fsSL --retry 3 -o "${path}.part" \
      "https://cloud.debian.org/images/cloud/${DEBIAN_RELEASE}/${DEBIAN_IMAGE_VERSION}/$(image_filename)" \
      || { rm -f "${path}.part"; die "failed to download the cloud image"; }
    mv "${path}.part" "${path}"
  fi

  log "Verifying image SHA-512"
  printf '%s  %s\n' "${DEBIAN_IMAGE_SHA512}" "${path}" | sha512sum -c - \
    || die "cloud image SHA-512 mismatch — refusing to build a VM from it (delete ${path} and retry)"
}

ensure_ssh_key() {
  if [[ -f ${SSH_KEY_FILE} ]]; then
    return
  fi
  log "Generating a dedicated SSH key for the Docker host (${SSH_KEY_FILE})"
  install -d -m 700 "$(dirname "${SSH_KEY_FILE}")"
  ssh-keygen -t ed25519 -N '' -C 'proxmox-host -> docker-host' -f "${SSH_KEY_FILE}" >/dev/null
}

create_vm() {
  log "Creating VM ${VMID} (${VM_NAME})"

  # q35 + OVMF is the modern default, but SeaBIOS + i440fx keeps a cloud image boot boringly
  # simple (no EFI vars disk to manage) — this VM has no passthrough needs.
  qm create "${VMID}" \
    --name "${VM_NAME}" \
    --cores "${CORES}" \
    --memory "${MEMORY_MB}" \
    --net0 "virtio=${MAC},bridge=${BRIDGE}" \
    --scsihw virtio-scsi-single \
    --ostype l26 \
    --onboot "${START_ON_BOOT}" \
    --agent enabled=1 \
    --tags docker,portainer \
    || die "qm create failed"

  # Import the cloud image straight into the VM disk (PVE 8+ import-from).
  log "Importing the cloud image as scsi0 on ${DISK_STORAGE}"
  qm set "${VMID}" --scsi0 "${DISK_STORAGE}:0,import-from=$(image_path),discard=on,ssd=1" \
    || die "failed to import the cloud image"

  log "Resizing the guest disk to ${DISK_SIZE}"
  qm disk resize "${VMID}" scsi0 "${DISK_SIZE}" || die "failed to resize scsi0"

  # Cloud-init drive + native cloud-init settings. Deliberately NOT using cicustom/snippets:
  # the `local` storage does not enable the `snippets` content type, and everything this VM
  # needs (user, key, DHCP) is expressible with the built-in options. Package install happens
  # over SSH afterwards instead.
  qm set "${VMID}" --ide2 "${DISK_STORAGE}:cloudinit" || die "failed to add the cloud-init drive"
  qm set "${VMID}" \
    --boot order=scsi0 \
    --ciuser "${CI_USER}" \
    --sshkeys "${SSH_KEY_FILE}.pub" \
    --ipconfig0 ip=dhcp \
    || die "failed to apply cloud-init settings"
}

start_vm() {
  log "Starting VM ${VMID}"
  qm start "${VMID}"
}

# Resolve the guest IP from the dnsmasq lease table (this host IS the LAN's DHCP server), then
# fall back to the guest agent. Waiting on the lease avoids depending on the agent being up.
resolve_guest_ip() {
  local mac_lower ip
  mac_lower="$(printf '%s' "${MAC}" | tr '[:upper:]' '[:lower:]')"

  for _ in $(seq 1 90); do
    ip="$(awk -v m="${mac_lower}" '$2 == m {print $3}' /var/lib/misc/dnsmasq.leases 2>/dev/null | tail -n 1)"
    if [[ -n ${ip} ]]; then
      printf '%s\n' "${ip}"
      return 0
    fi
    ip="$(qm guest cmd "${VMID}" network-get-interfaces 2>/dev/null \
      | sed -n 's/.*"ip-address"[[:space:]]*:[[:space:]]*"\(10\.[0-9.]*\)".*/\1/p' | head -n 1)"
    if [[ -n ${ip} ]]; then
      printf '%s\n' "${ip}"
      return 0
    fi
    sleep 2
  done

  return 1
}

wait_for_ssh() {
  local ip="$1"
  log "Waiting for SSH on ${ip}"
  for _ in $(seq 1 90); do
    if ssh -i "${SSH_KEY_FILE}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -o BatchMode=yes "${CI_USER}@${ip}" true 2>/dev/null; then
      return 0
    fi
    sleep 3
  done
  return 1
}

guest_ssh() {
  local ip="$1"
  shift
  ssh -i "${SSH_KEY_FILE}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 "${CI_USER}@${ip}" "$@"
}

install_docker_and_portainer() {
  local ip="$1"

  log "Installing Docker + Compose + Portainer in the guest"

  guest_ssh "${ip}" "sudo PORTAINER_IMAGE='${PORTAINER_IMAGE}' \
    PORTAINER_HTTPS_PORT='${PORTAINER_HTTPS_PORT}' \
    STACKS_DIR='${STACKS_DIR}' \
    CI_USER='${CI_USER}' bash -s" <<'GUEST_SCRIPT'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

# 1. Base packages + the qemu guest agent (so Proxmox reports IP/shutdown properly). The
#    genericcloud image does not ship the agent.
apt-get update
apt-get install -y ca-certificates curl gnupg git qemu-guest-agent
systemctl enable --now qemu-guest-agent || true

# 2. Docker from Docker's own apt repo (the distro's docker.io lags and omits the compose
#    plugin). Keyring + pinned-by-repo, not a `curl | sh` convenience script.
# shellcheck source=/dev/null
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "${VERSION_CODENAME}") stable
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 3. Let the default user drive docker without sudo (convenience for the operator; the group
#    is root-equivalent, which is expected on a single-purpose Docker host).
usermod -aG docker "${CI_USER}"

# 4. Cap journald + container log growth. A forgotten chatty container filling the disk is the
#    most common way a small Docker host dies.
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl restart docker
systemctl enable docker

# 5. Stacks directory. Compose files live here (and a git clone of the stacks repo), so a stack
#    is inspectable/editable on disk as well as through Portainer.
install -d -m 755 "${STACKS_DIR}"
chown "${CI_USER}:${CI_USER}" "${STACKS_DIR}"

# 6. Portainer CE. Its own container, restart=always, bound to the Docker socket. Data lives in
#    the portainer_data volume so an image upgrade keeps stacks/users/settings.
docker volume create portainer_data >/dev/null
if docker ps -a --format '{{.Names}}' | grep -qx portainer; then
  docker rm -f portainer >/dev/null
fi
docker run -d \
  --name portainer \
  --restart=always \
  -p "${PORTAINER_HTTPS_PORT}:9443" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  "${PORTAINER_IMAGE}" >/dev/null

# 7. Verify: docker works, compose plugin present, Portainer answering HTTPS.
docker --version
docker compose version
for _ in $(seq 1 45); do
  if curl -fsSk "https://127.0.0.1:${PORTAINER_HTTPS_PORT}/api/status" >/dev/null 2>&1; then
    echo "portainer: up"
    exit 0
  fi
  sleep 2
done
echo "error: Portainer did not answer /api/status within ~90s" >&2
docker logs --tail 50 portainer >&2 || true
exit 1
GUEST_SCRIPT
}

print_summary() {
  local ip="$1"

  log "Done"
  printf 'Docker host VM: %s (%s)\n' "${VMID}" "${VM_NAME}"
  printf 'Guest IP: %s   (dnsmasq name: %s)\n' "${ip}" "${VM_NAME}"
  printf 'Portainer UI: https://%s:%s\n' "${ip}" "${PORTAINER_HTTPS_PORT}"
  printf 'Stacks dir (in guest): %s\n' "${STACKS_DIR}"
  printf 'SSH into it: ssh -i %s %s@%s\n' "${SSH_KEY_FILE}" "${CI_USER}" "${ip}"

  printf '\n⚠️  FIRST THING: open the Portainer UI and create the admin user.\n'
  printf '    Portainer leaves initial setup open for a limited window and then LOCKS itself;\n'
  printf '    if that happens, restart the container to reopen it:\n'
  printf '      ssh -i %s %s@%s -- docker restart portainer\n' "${SSH_KEY_FILE}" "${CI_USER}" "${ip}"

  printf '\nReach it from the LAN by adding to host-net/wifi-nat/wifi-nat.env:\n'
  printf '  RESERVATIONS  += "%s 10.10.10.100 %s"\n' "${MAC}" "${VM_NAME}"
  printf '  PORT_FORWARDS += "tcp %s 10.10.10.100 %s"   # Portainer UI\n' \
    "${PORTAINER_HTTPS_PORT}" "${PORTAINER_HTTPS_PORT}"
  printf '  PORT_FORWARDS += "tcp 4000 10.10.10.100 4000"  # MealDeal\n'
  printf '  then: /root/wifi-nat/install.sh --reload-dns && /root/wifi-nat/install.sh --reload-nft\n'
  printf '  (then reboot the VM to take the reserved address: qm reboot %s)\n' "${VMID}"
}

main() {
  case "${1:-}" in
    --help | -h)
      usage
      exit 0
      ;;
    --reinstall-docker) REINSTALL_DOCKER=1 ;;
    '') ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac

  require_root
  require_command qm
  require_command curl
  require_command sha512sum
  require_command ssh-keygen

  local ip

  if ((REINSTALL_DOCKER)); then
    qm status "${VMID}" >/dev/null 2>&1 || die "VM ${VMID} does not exist — run without --reinstall-docker first"
    [[ -f ${SSH_KEY_FILE} ]] || die "missing ${SSH_KEY_FILE} — cannot reach the guest"
    ip="$(resolve_guest_ip)" || die "could not resolve the guest IP for VM ${VMID}"
    wait_for_ssh "${ip}" || die "no SSH on ${ip}"
    install_docker_and_portainer "${ip}" || die "guest install failed"
    print_summary "${ip}"
    return
  fi

  assert_vmid_available
  download_image_if_missing
  ensure_ssh_key
  create_vm
  start_vm

  ip="$(resolve_guest_ip)" || {
    printf 'error: VM %s started but never took a DHCP lease.\n' "${VMID}" >&2
    printf '  Check the console: qm terminal %s   (or the Proxmox UI noVNC)\n' "${VMID}" >&2
    exit 1
  }
  log "Guest IP: ${ip}"

  if ! wait_for_ssh "${ip}"; then
    printf 'error: no SSH on %s after ~4.5 min — cloud-init may still be running.\n' "${ip}" >&2
    printf '  Inspect: qm terminal %s   /   ssh -i %s %s@%s\n' \
      "${VMID}" "${SSH_KEY_FILE}" "${CI_USER}" "${ip}" >&2
    exit 1
  fi

  if ! install_docker_and_portainer "${ip}"; then
    printf '\n' >&2
    log "Docker/Portainer install FAILED on VM ${VMID} (${ip})."
    printf 'The VM exists and is reachable. Re-run just the install with:\n' >&2
    printf '  %s --reinstall-docker\n' "$0" >&2
    exit 1
  fi

  print_summary "${ip}"
}

main "$@"
