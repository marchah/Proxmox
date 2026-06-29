#!/usr/bin/env bash
#
# Install the GPU undervolt service for the Radeon Pro V620 on a Proxmox host.
# Run on the host as root. Idempotent — safe to re-run.
#
# What it does, in order:
#   1. Enable amdgpu OverDrive — the prerequisite for the voltage-offset knob —
#      via a /etc/modprobe.d option + initramfs rebuild. amdgpu reads
#      ppfeaturemask at load, so this needs a REBOOT to take effect.
#   2. Install the gpu-undervolt daemon, its env file, and systemd unit; enable it.
#   3. If OverDrive is already active, apply the offset now; otherwise it applies
#      automatically on the next boot.
#
# Background: the V620's board power is firmware-locked at 250 W (`power1_cap`
# write of any other value -> -EINVAL) and OverDrive exposes no clock-ceiling
# knob (`OD_RANGE` is empty), so a GFX voltage OFFSET is the ONLY power/thermal
# lever available — see README.md for the firmware-lock evidence and A/B data.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly SBIN_PATH="/usr/local/sbin/gpu-undervolt"
readonly ENV_PATH="/etc/gpu-undervolt.env"
readonly UNIT_PATH="/etc/systemd/system/gpu-undervolt.service"
readonly MODPROBE_PATH="/etc/modprobe.d/amdgpu-overdrive.conf"

# OverDrive feature bit (0x4000) OR'd onto amdgpu's vendor-default ppfeaturemask
# (0xfff7bfff on this kernel) => 0xfff7ffff. Enables ONLY OverDrive, leaving the
# other vendor-disabled bit (GFX_DCS, 0x80000) off. 0xffffffff is the broader,
# commonly-cited alternative; override via PPFEATUREMASK= if you prefer it.
readonly PPFEATUREMASK="${PPFEATUREMASK:-0xfff7ffff}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (on the Proxmox host)"; }

# True if amdgpu currently exposes the OverDrive node (i.e. OverDrive is active).
overdrive_active() { compgen -G '/sys/class/drm/card*/device/pp_od_clk_voltage' >/dev/null 2>&1; }

# Persist OverDrive enablement the repo-consistent way (modprobe.d, like
# fan-control's nct6687.conf) rather than a hand-edited kernel cmdline.
enable_overdrive_persistently() {
  local want="options amdgpu ppfeaturemask=${PPFEATUREMASK}"
  if [ -f "$MODPROBE_PATH" ] && grep -qxF "$want" "$MODPROBE_PATH"; then
    log "OverDrive modprobe option already set ($MODPROBE_PATH)"
    return
  fi
  log "enabling amdgpu OverDrive via $MODPROBE_PATH (ppfeaturemask=${PPFEATUREMASK})"
  {
    printf '# Enable amdgpu OverDrive (feature bit 0x4000) so OD_VDDGFX_OFFSET is\n'
    printf '# writable. Managed by pro-v620/undervolt/install.sh. A reboot is\n'
    printf '# required for amdgpu to re-read this at load.\n'
    printf '%s\n' "$want"
  } > "$MODPROBE_PATH"
  log "rebuilding initramfs so the option applies at early amdgpu load"
  update-initramfs -u -k all >/dev/null 2>&1 || update-initramfs -u \
    || warn "update-initramfs failed — verify manually before relying on persistence"
}

install_service() {
  log "installing daemon -> $SBIN_PATH"
  install -m 0755 "$SCRIPT_DIR/gpu-undervolt.sh" "$SBIN_PATH"

  if [ -f "$ENV_PATH" ]; then
    warn "$ENV_PATH exists — leaving your settings untouched (delete it to reset to defaults)"
  else
    log "installing config -> $ENV_PATH"
    install -m 0644 "$SCRIPT_DIR/gpu-undervolt.env" "$ENV_PATH"
  fi

  log "installing unit -> $UNIT_PATH"
  install -m 0644 "$SCRIPT_DIR/gpu-undervolt.service" "$UNIT_PATH"
  systemctl daemon-reload
}

enable_service() {
  log "enabling gpu-undervolt.service"
  systemctl enable gpu-undervolt.service >/dev/null 2>&1 || die "failed to enable the unit"

  if overdrive_active; then
    # restart (not enable --now): on a re-run --now would leave any OLD process
    # state; restart re-applies the (possibly changed) offset immediately.
    log "OverDrive active — applying offset now"
    systemctl restart gpu-undervolt.service
    sleep 2
    systemctl is-active --quiet gpu-undervolt.service \
      || die "service failed to start — see: journalctl -u gpu-undervolt -n 30"
    log "active. Current offset: $(awk 'f{print $1; exit} /OD_VDDGFX_OFFSET/{f=1}' /sys/class/drm/card*/device/pp_od_clk_voltage 2>/dev/null)"
  else
    warn "OverDrive is NOT active yet — a REBOOT is required. The undervolt will apply automatically on the next boot."
  fi
}

main() {
  require_root
  enable_overdrive_persistently
  install_service
  enable_service
  if overdrive_active; then
    log "done. Tune the offset in $ENV_PATH, then: systemctl restart gpu-undervolt"
  else
    log "done. Reboot to activate OverDrive and apply the undervolt:  reboot"
  fi
}

main "$@"
