#!/usr/bin/env bash
#
# gpu-undervolt — apply a fixed GFX voltage offset (undervolt) to the Radeon Pro
# V620, via amdgpu's OverDrive `pp_od_clk_voltage` interface.
#
# Why this exists: the V620's board power is firmware-locked at 250 W
# (`power1_cap` reports min==max==default==250 W; any other write -> -EINVAL,
# the driver logs "New power limit (N) is out of range [250,250]"). Even with
# OverDrive enabled the OD table exposes NO clock-ceiling knob — `OD_RANGE` is
# empty, so there is no `OD_SCLK`/`OD_MCLK` to cap. The ONLY available power/
# thermal lever is `OD_VDDGFX_OFFSET`: a GFX voltage offset. A negative offset
# lowers voltage at the same clocks — measured at -100 mV it cut sustained board
# power ~18% (196 -> 160 W) and peak junction ~8 C (83 -> 75 C) with throughput
# unchanged-to-slightly-higher. See README.md for the full A/B data.
#
# OverDrive must be enabled first (amdgpu loaded with ppfeaturemask bit 0x4000);
# install.sh sets that via /etc/modprobe.d + an initramfs rebuild + reboot.
# Without it `pp_od_clk_voltage` does not exist and `apply` exits non-zero.
#
# Run as root on the Proxmox host. Driven as a systemd oneshot
# (RemainAfterExit): `apply` sets the offset at boot; `--reset` (ExecStop)
# returns the card to stock voltage (0 mV).
#
# Intentionally NOT `set -e`: a transient sysfs read returning nonzero must be
# handled explicitly, not abort the script. Failures `die` with a clear message.
set -uo pipefail

# ---- config (override via /etc/gpu-undervolt.env) ---------------------------
OFFSET_MV="${OFFSET_MV:--100}"          # GFX voltage offset in mV (negative = undervolt)
GPU_HWMON_NAME="${GPU_HWMON_NAME:-amdgpu}"
WAIT_SECS="${WAIT_SECS:-30}"            # max wait for pp_od_clk_voltage at boot

# ---------------------------------------------------------------------------
log() { printf 'gpu-undervolt: %s\n' "$*"; }
die() { printf 'gpu-undervolt: ERROR: %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (on the Proxmox host)"; }

# Resolve the amdgpu card device dir (the one holding pp_od_clk_voltage). The
# cardN number is not stable across boots, so match the driver, not the index.
resolve_card_dev() {  # echoes /sys/class/drm/cardN/device or returns 1
  local dev drv
  for dev in /sys/class/drm/card*/device; do
    [ -e "$dev/pp_od_clk_voltage" ] || continue
    drv="$(basename "$(readlink -f "$dev/driver" 2>/dev/null)" 2>/dev/null)"
    [ "$drv" = "amdgpu" ] && { echo "$dev"; return 0; }
  done
  return 1
}

# Read the currently-applied GFX voltage offset (e.g. "-100mV") from the OD node.
read_offset() {  # $1 = card dev ; echoes "<n>mV" or empty
  awk 'f{print $1; exit} /OD_VDDGFX_OFFSET/{f=1}' "$1/pp_od_clk_voltage" 2>/dev/null
}

# Apply (and commit) a GFX voltage offset, then confirm it took effect.
apply_offset() {  # $1 = card dev, $2 = mV
  local od="$1/pp_od_clk_voltage" mv="$2" got
  echo "vo $mv" > "$od" 2>/dev/null || die "failed writing 'vo $mv' to $od (OverDrive enabled?)"
  echo "c"      > "$od" 2>/dev/null || die "failed committing offset to $od"
  got="$(read_offset "$1")"
  [ "$got" = "${mv}mV" ] || die "offset readback mismatch: wanted ${mv}mV, got '${got:-<none>}'"
  log "GFX voltage offset = ${got}"
}

# Wait for the OverDrive node to appear (amdgpu can bind a few seconds into boot).
wait_for_card() {  # echoes card dev or dies
  local dev waited=0
  while ! dev="$(resolve_card_dev)"; do
    (( waited >= WAIT_SECS )) && die "no amdgpu card exposing pp_od_clk_voltage after ${WAIT_SECS}s — OverDrive not enabled? Check: cat /sys/module/amdgpu/parameters/ppfeaturemask (needs bit 0x4000); reboot after install.sh writes /etc/modprobe.d/amdgpu-overdrive.conf"
    sleep 2; waited=$(( waited + 2 ))
  done
  echo "$dev"
}

main() {
  require_root
  local mode="${1:-apply}" dev
  case "$mode" in
    apply)
      dev="$(wait_for_card)"
      apply_offset "$dev" "$OFFSET_MV"
      ;;
    --reset)
      # Best-effort return to stock voltage (used on service stop). If the OD
      # node is gone (amdgpu unloaded), there is nothing to reset.
      if dev="$(resolve_card_dev)"; then apply_offset "$dev" 0; else log "no OverDrive node present; nothing to reset"; fi
      ;;
    *) die "usage: gpu-undervolt [apply|--reset]" ;;
  esac
}

main "$@"
