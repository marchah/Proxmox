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
# Tested-safe bounds for OFFSET_MV. -100..0 is the range A/B-validated stable on
# this card (see README); a positive value would OVERvolt and a too-negative one
# risks GPU resets. Widen only with your own stability data.
OFFSET_MIN_MV="${OFFSET_MIN_MV:--100}"
OFFSET_MAX_MV="${OFFSET_MAX_MV:-0}"
# Select the V620 by PCI vendor:device so a SECOND amdgpu GPU can't get the offset.
GPU_PCI_ID="${GPU_PCI_ID:-1002:73a1}"   # Radeon Pro V620 (Navi 21 / gfx1030)
# Optional exact PCI address (e.g. 0000:2d:00.0) to disambiguate identical cards.
GPU_PCI_ADDRESS="${GPU_PCI_ADDRESS:-}"
WAIT_SECS="${WAIT_SECS:-30}"            # max wait for pp_od_clk_voltage at boot

# ---------------------------------------------------------------------------
log()  { printf 'gpu-undervolt: %s\n' "$*"; }
warn() { printf 'gpu-undervolt: WARN: %s\n' "$*" >&2; }
die()  { printf 'gpu-undervolt: ERROR: %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (on the Proxmox host)"; }

# Resolve the V620's card device dir (the one holding pp_od_clk_voltage). Match by
# PCI vendor:device — and, if set, an exact PCI address — NOT by card index (cardN
# is unstable across boots) and NOT by "first amdgpu GPU" (a second AMD card must
# never receive the V620's offset).
#   stdout = matching dir, exit 0 : exactly one match
#   exit 1                        : no match yet (retryable while amdgpu binds)
#   stdout = match list, exit 2   : multiple matches (fatal; set GPU_PCI_ADDRESS)
resolve_card_dev() {
  local dev vid did pci
  local -a matches=()
  for dev in /sys/class/drm/card*/device; do
    [ -e "$dev/pp_od_clk_voltage" ] || continue
    vid="$(cat "$dev/vendor" 2>/dev/null)" || continue   # e.g. 0x1002
    did="$(cat "$dev/device" 2>/dev/null)" || continue   # e.g. 0x73a1
    [ "${vid#0x}:${did#0x}" = "$GPU_PCI_ID" ] || continue
    if [ -n "$GPU_PCI_ADDRESS" ]; then
      pci="$(basename "$(readlink -f "$dev" 2>/dev/null)" 2>/dev/null)"
      [ "$pci" = "$GPU_PCI_ADDRESS" ] || continue
    fi
    matches+=("$dev")
  done
  case "${#matches[@]}" in
    1) printf '%s\n' "${matches[0]}"; return 0 ;;
    0) return 1 ;;
    *) printf '%s\n' "${matches[*]}"; return 2 ;;
  esac
}

# Read the currently-applied GFX voltage offset (e.g. "-100mV") from the OD node.
read_offset() {  # $1 = card dev ; echoes "<n>mV" or empty
  awk 'f{print $1; exit} /OD_VDDGFX_OFFSET/{f=1}' "$1/pp_od_clk_voltage" 2>/dev/null
}

# Reject an out-of-range / non-integer offset BEFORE touching hardware.
validate_offset() {  # $1 = mV
  local mv="$1"
  [[ "$mv" =~ ^-?[0-9]+$ ]] || die "OFFSET_MV must be an integer in mV, got '$mv'"
  (( mv >= OFFSET_MIN_MV && mv <= OFFSET_MAX_MV )) \
    || die "OFFSET_MV=${mv} is outside the tested-safe range [${OFFSET_MIN_MV},${OFFSET_MAX_MV}] mV — override OFFSET_MIN_MV/OFFSET_MAX_MV only with your own stability data"
}

# Apply (and commit) a GFX voltage offset following the documented OverDrive
# protocol: select the `manual` performance level, write + commit the offset,
# verify the readback, then RESTORE the prior performance level. The restore runs
# even when a write fails — a bare `die` mid-sequence would otherwise leave the
# card pinned in `manual`. (The committed offset persists once the level returns to
# `auto`; the readback below confirms the commit took before we restore.)
apply_offset() {  # $1 = card dev, $2 = mV
  local dev="$1" mv="$2" od="$1/pp_od_clk_voltage" plf="$1/power_dpm_force_performance_level"
  local prev_level="" got="" rc=0 err="" use_manual="" restored=""

  # Guard against an empty/invalid dev: with dev="" the paths above collapse to
  # root-relative (/pp_od_clk_voltage), so a stray write could land on the host
  # filesystem. Never write unless the real OverDrive node is present.
  [ -n "$dev" ] && [ -e "$od" ] || die "apply_offset: no OverDrive node at '$od' — refusing to write"

  # Documented OverDrive edit protocol: select `manual`, write+commit, then restore
  # the prior level. Only enter manual if we can FIRST read a level to put back —
  # switching with nothing to restore would leave the card silently pinned in
  # `manual`. (When the node isn't writable we skip the dance and apply in the
  # active level, which this card already tolerates.)
  if [ -w "$plf" ]; then
    prev_level="$(cat "$plf" 2>/dev/null)" \
      || die "cannot read performance level ($plf) — refusing to switch to manual with nothing to restore"
    [ -n "$prev_level" ] \
      || die "performance level ($plf) read back empty — refusing to switch to manual"
    echo manual > "$plf" 2>/dev/null || die "failed selecting 'manual' performance level ($plf)"
    use_manual=1
  fi

  if ! echo "vo $mv" > "$od" 2>/dev/null; then
    err="failed writing 'vo $mv' to $od (OverDrive enabled?)"; rc=1
  elif ! echo "c" > "$od" 2>/dev/null; then
    err="failed committing offset to $od"; rc=1
  else
    got="$(read_offset "$dev")"
    [ "$got" = "${mv}mV" ] || { err="offset readback mismatch: wanted ${mv}mV, got '${got:-<none>}'"; rc=1; }
  fi

  # Restore the performance level — REQUIRED, and done even when the offset write
  # failed (a bare die mid-sequence would leave the card pinned in `manual`). Fall
  # back to `auto` if the exact prior level won't take; a restore that STILL fails
  # is fatal, so systemd never reports success on a card left stuck in `manual`.
  if [ -n "$use_manual" ]; then
    if echo "$prev_level" > "$plf" 2>/dev/null; then
      restored="$prev_level"
    elif echo auto > "$plf" 2>/dev/null; then
      warn "could not restore performance level to '$prev_level' ($plf) — fell back to 'auto'"
      restored="auto"
    else
      die "FAILED to restore performance level ($plf) — card may be stuck in 'manual'; investigate"
    fi
  fi

  (( rc == 0 )) || die "$err"
  log "GFX voltage offset = ${got}${restored:+ (perf level restored to ${restored})}"
}

# Wait for the V620's OverDrive node to appear (amdgpu can bind a few seconds into
# boot) and set CARD_DEV. A multiple-match (exit 2) is fatal immediately — retrying
# won't help. MUST be called directly, never via `dev="$(wait_for_card)"`: this
# function dies on failure, and a die() inside a command substitution would only
# kill the subshell — without `set -e`, main would then barrel on with an empty dev
# and apply_offset would write to a root-relative path. resolve_card_dev returns
# status codes (never dies) for exactly that reason, so it IS safe in `$(...)`.
CARD_DEV=""
wait_for_card() {  # sets CARD_DEV or dies
  local rc waited=0
  while :; do
    CARD_DEV="$(resolve_card_dev)"; rc=$?
    (( rc == 0 )) && return 0
    (( rc == 2 )) && die "multiple GPUs match ${GPU_PCI_ID}${GPU_PCI_ADDRESS:+ @ ${GPU_PCI_ADDRESS}} ($CARD_DEV) — set GPU_PCI_ADDRESS in /etc/gpu-undervolt.env to pick one"
    (( waited >= WAIT_SECS )) && die "no GPU matching ${GPU_PCI_ID}${GPU_PCI_ADDRESS:+ @ ${GPU_PCI_ADDRESS}} exposing pp_od_clk_voltage after ${WAIT_SECS}s — OverDrive not enabled? Check: cat /sys/module/amdgpu/parameters/ppfeaturemask (needs bit 0x4000); reboot after install.sh writes /etc/modprobe.d/amdgpu-overdrive.conf"
    sleep 2; waited=$(( waited + 2 ))
  done
}

main() {
  require_root
  local mode="${1:-apply}" dev rc
  case "$mode" in
    apply)
      validate_offset "$OFFSET_MV"
      wait_for_card                       # sets CARD_DEV or dies (called directly so die aborts)
      apply_offset "$CARD_DEV" "$OFFSET_MV"
      ;;
    --reset)
      # Best-effort return to stock voltage (used on service stop). If the OD node
      # is gone (amdgpu unloaded), there is nothing to reset.
      dev="$(resolve_card_dev)"; rc=$?
      case "$rc" in
        0) apply_offset "$dev" 0 ;;
        1) log "no matching OverDrive node present; nothing to reset" ;;
        2) die "multiple GPUs match ${GPU_PCI_ID}${GPU_PCI_ADDRESS:+ @ ${GPU_PCI_ADDRESS}} ($dev) — set GPU_PCI_ADDRESS in /etc/gpu-undervolt.env to pick one" ;;
      esac
      ;;
    *) die "usage: gpu-undervolt [apply|--reset]" ;;
  esac
}

main "$@"
