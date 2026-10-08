#!/usr/bin/env bash

set -Eeuo pipefail

# Shared GGUF store for the GPU containers: one ext4 thin volume on the `models`
# LVM-thin pool, mounted on the host and bind-mounted into CT 120 and CT 123 at
# /models. Idempotent; run on the Proxmox host as root. See ../README.md#host-storage.

# Whole disk for the pool. Only used when the `models` volume group does not exist.
DEVICE="${DEVICE:-/dev/nvme0n1}"
# Storage ID, volume group and thin pool name (pvesh uses one name for all three).
POOL="${POOL:-models}"
LV="${LV:-shared}"
LV_SIZE="${LV_SIZE:-1.75T}"
MOUNT_DIR="${MOUNT_DIR:-/mnt/models}"
# Containers bind this subdirectory, not the mount itself: when the volume is not
# mounted the directory is absent and the container refuses to start, instead of
# starting on an empty /models.
STORE_DIR="${STORE_DIR:-${MOUNT_DIR}/store}"
# llamacpp's UID in the GPU containers; the provisioners pin it.
STORE_UID="${STORE_UID:-1000}"

usage() {
  cat <<'USAGE'
Create the shared model store bound into the GPU containers at /models.

Steps, each skipped when already done:
  1. LVM-thin pool + Proxmox storage `models` on DEVICE (whole disk)
  2. thin volume models/shared, formatted ext4
  3. /etc/fstab entry and mount at /mnt/models
  4. /mnt/models/store owned by llamacpp (UID 1000)

Overrides: DEVICE=/dev/nvme0n1 LV_SIZE=1.75T ./create-models-store.sh
USAGE
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }
require_root() { [[ ${EUID} -eq 0 ]] || die "run this script as root on the Proxmox host"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

ensure_pool() {
  vgs "${POOL}" >/dev/null 2>&1 && return
  [[ -b ${DEVICE} ]] || die "${DEVICE} is not a block device"
  [[ -z $(wipefs -n "${DEVICE}") ]] || die "${DEVICE} has existing signatures; refusing to overwrite it"
  log "Creating LVM-thin pool and storage ${POOL} on ${DEVICE}"
  pvesh create "/nodes/$(hostname)/disks/lvmthin" --device "${DEVICE}" --name "${POOL}" --add_storage 1
}

ensure_volume() {
  lvs "${POOL}/${LV}" >/dev/null 2>&1 && return
  log "Creating thin volume ${POOL}/${LV} (${LV_SIZE})"
  lvcreate -q -V "${LV_SIZE}" -T "${POOL}/${POOL}" -n "${LV}"
}

ensure_filesystem() {
  [[ -n $(blkid -o value -s TYPE "/dev/${POOL}/${LV}" || true) ]] && return
  log "Formatting /dev/${POOL}/${LV} as ext4"
  mkfs.ext4 -q -m 0 -L "${POOL}" "/dev/${POOL}/${LV}"
}

ensure_mount() {
  if ! grep -q "^/dev/${POOL}/${LV} " /etc/fstab; then
    log "Adding ${MOUNT_DIR} to /etc/fstab"
    # nofail: a missing disk must not stop the host booting; the containers then
    # fail to start on the absent STORE_DIR instead.
    printf '%s\n' \
      "# Shared GGUF store bound into CT 120 and CT 123 at /models (pro-v620/README.md)" \
      "/dev/${POOL}/${LV} ${MOUNT_DIR} ext4 defaults,noatime,nofail 0 2" >>/etc/fstab
    systemctl daemon-reload
  fi
  install -d "${MOUNT_DIR}"
  findmnt "${MOUNT_DIR}" >/dev/null || mount "${MOUNT_DIR}"
}

ensure_store_dir() {
  install -d -o "${STORE_UID}" -g "${STORE_UID}" "${STORE_DIR}"
}

main() {
  if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then usage; exit 0; fi
  require_root
  require_command pvesh
  require_command lvcreate
  ensure_pool
  ensure_volume
  ensure_filesystem
  ensure_mount
  ensure_store_dir
  log "Done"
  findmnt "${MOUNT_DIR}"
  printf 'Bind into a container: pct set <vmid> -mp0 %s,mp=/models\n' "${STORE_DIR}"
}

main "$@"
