#!/usr/bin/env bash
# Create the disposable test VM, without the GPU (card.sh to-vm attaches it). HOST, root.
#
# q35 + OVMF with Secure Boot off (pre-enrolled-keys=0), so the unsigned amdgpu-dkms module
# loads. Ballooning is off: passthrough pins all guest RAM anyway. The guest agent is on
# because gpu-blower-control reads the passed-through card's temps through it.
# Destroy with: qm destroy 301 --purge
set -Eeuo pipefail

VMID="${VMID:-301}"; NAME="${NAME:-rocm-ab}"
ROOT="${ROOT:-/root/rocm-ab}"
IMG="${ROOT}/dl/noble-server-cloudimg-amd64.img"
CORES="${CORES:-16}"; MEMORY="${MEMORY:-65536}"; DISK="${DISK:-120G}"
SSH_KEY="${SSH_KEY:-/root/.ssh/id_rsa.pub}"

qm status "$VMID" >/dev/null 2>&1 && { echo "VM ${VMID} already exists" >&2; exit 1; }
[ -s "$IMG" ] || { echo "missing ${IMG}; run stage-host.sh first" >&2; exit 1; }

qm create "$VMID" --name "$NAME" \
  --description "DISPOSABLE Vulkan/ROCm A/B VM (pro-v620/rocm-ab). Destroy with: qm destroy ${VMID} --purge" \
  --machine q35 --bios ovmf --cpu host --sockets 1 --cores "$CORES" \
  --memory "$MEMORY" --balloon 0 --ostype l26 --onboot 0 \
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 \
  --agent enabled=1 --serial0 socket --vga std \
  --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0 \
  --scsi0 "local-lvm:0,import-from=${IMG},iothread=1,discard=on,ssd=1" \
  --ide2 local-lvm:cloudinit --boot order=scsi0 \
  --ciuser ubuntu --sshkeys "$SSH_KEY" --ipconfig0 ip=dhcp
qm resize "$VMID" scsi0 "$DISK"
qm config "$VMID"
