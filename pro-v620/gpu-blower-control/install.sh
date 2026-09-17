#!/usr/bin/env bash
# Idempotent installer for gpu-blower-control (Proxmox HOST, not an LXC).
#
# Drives the V620 blowers from amdgpu temps via the BMC, over in-band IPMI.
# Supersedes pro-v620/fan-control/ on the ROMED8-2T, which writes nct6687 PWM
# sysfs — a Super I/O chip no server board has.
set -Eeuo pipefail

BIN=/usr/local/sbin/gpu-blower-control
ENV=/etc/gpu-blower-control.env
UNIT=/etc/systemd/system/gpu-blower-control.service
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
command -v ipmitool >/dev/null || die "ipmitool not installed (apt install ipmitool)"
[[ -c /dev/ipmi0 ]] || die "/dev/ipmi0 missing — is ipmi_devintf loaded?"

install -m 0755 "$SRC/gpu-blower-control.sh" "$BIN"
if [[ -e $ENV ]]; then
  printf 'keeping existing %s (PCI addresses and curve are site-specific)\n' "$ENV"
else
  install -m 0644 "$SRC/gpu-blower-control.env" "$ENV"
  printf 'installed %s — VERIFY THE PCI/FAN PAIRING before trusting it (see README)\n' "$ENV"
fi
install -m 0644 "$SRC/gpu-blower-control.service" "$UNIT"
systemctl daemon-reload
systemctl enable --now gpu-blower-control
systemctl --no-pager --lines=5 status gpu-blower-control || true
