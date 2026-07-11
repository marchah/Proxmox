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
# (RemainAfterExit): `apply` sets the offset at boot; `--reset` (ExecStopPost)
# returns the card to stock voltage (0 mV) on stop or a failed start.
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

# Resolve the V620 card device dir(s) holding pp_od_clk_voltage. Match by PCI
# vendor:device — and, if GPU_PCI_ADDRESS is set, an exact PCI address — NOT by
# card index (cardN is unstable across boots). Matching by the V620 PCI ID means a
# second AMD card that is NOT a V620 can never receive the offset, while EVERY V620
# in the box does (this host runs two). Pin GPU_PCI_ADDRESS to target just one.
#   stdout = matching dir(s), one per line, exit 0 : >=1 match
#   exit 1                                         : no match yet (amdgpu binding)
resolve_card_devs() {
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
  (( ${#matches[@]} >= 1 )) || return 1
  printf '%s\n' "${matches[@]}"
  return 0
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
# `auto`; the readback below confirms the commit took before we restore.) If the
# apply fails AFTER the offset is committed, it is rolled back to 0 (stock) so a
# failed run never leaves the card modified, no matter how it was invoked — the
# in-script counterpart to the unit's ExecStopPost=--reset (which only fires under
# systemd, not for a manual `gpu-undervolt apply`).
apply_offset() {  # $1 = card dev, $2 = mV
  local dev="$1" mv="$2" od="$1/pp_od_clk_voltage" plf="$1/power_dpm_force_performance_level"
  local prev_level="" got="" rc=0 err="" use_manual="" restored="" committed=""

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
    committed=1
    got="$(read_offset "$dev")"
    [ "$got" = "${mv}mV" ] || { err="offset readback mismatch: wanted ${mv}mV, got '${got:-<none>}'"; rc=1; }
  fi

  # Restore the performance level — REQUIRED, and done even when the offset write
  # failed (a bare die mid-sequence would leave the card pinned in `manual`). Try
  # the prior level, then `auto`; if BOTH fail, record it as a failure (rc=1) so we
  # roll back below and die — never report success on a card stuck in `manual`.
  if [ -n "$use_manual" ]; then
    if echo "$prev_level" > "$plf" 2>/dev/null; then
      restored="$prev_level"
    elif echo auto > "$plf" 2>/dev/null; then
      warn "could not restore performance level to '$prev_level' ($plf) — fell back to 'auto'"
      restored="auto"
    else
      (( rc == 0 )) && err="failed to restore performance level ($plf) — card may be stuck in 'manual'"
      rc=1
    fi
  fi

  # Self-rollback: a failed apply must not leave the card undervolted. If we
  # committed an offset and the apply then failed (readback mismatch OR a failed
  # perf-level restore), undo it to stock here — covering a manual run, not just the
  # systemd ExecStopPost backstop. Skipped when applying 0 (nothing to undo). The
  # write works in whatever level we ended in (auto after a normal restore, else the
  # manual we couldn't leave).
  if (( rc != 0 )) && [ -n "$committed" ] && (( mv != 0 )); then
    if echo "vo 0" > "$od" 2>/dev/null && echo "c" > "$od" 2>/dev/null \
       && [ "$(read_offset "$dev")" = "0mV" ]; then
      log "rolled back offset to 0mV after a failed apply"
    else
      warn "rollback to 0mV may have failed — verify $od"
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
CARD_DEVS=()
# Wait for the V620 OverDrive node(s) to appear and settle. amdgpu can bind a few
# seconds into boot, and with two cards the second may show up just after the first,
# so we wait until the match COUNT is stable across two consecutive scans (or
# WAIT_SECS elapses, after which we act on whatever is present). Sets CARD_DEVS.
# MUST be called directly, never via `x="$(wait_for_cards)"`: it dies on failure,
# and a die() inside command substitution would only kill the subshell.
wait_for_cards() {  # sets CARD_DEVS or dies
  local waited=0 prev=-1 n
  local -a cur
  while :; do
    mapfile -t cur < <(resolve_card_devs)
    n=${#cur[@]}
    if (( n >= 1 && n == prev )); then CARD_DEVS=("${cur[@]}"); return 0; fi
    if (( waited >= WAIT_SECS )); then
      (( n >= 1 )) && { CARD_DEVS=("${cur[@]}"); return 0; }
      die "no GPU matching ${GPU_PCI_ID}${GPU_PCI_ADDRESS:+ @ ${GPU_PCI_ADDRESS}} exposing pp_od_clk_voltage after ${WAIT_SECS}s — OverDrive not enabled? Check: cat /sys/module/amdgpu/parameters/ppfeaturemask (needs bit 0x4000); reboot after install.sh writes /etc/modprobe.d/amdgpu-overdrive.conf"
    fi
    prev=$n; sleep 2; waited=$(( waited + 2 ))
  done
}

main() {
  require_root
  local mode="${1:-apply}" dev
  case "$mode" in
    apply)
      validate_offset "$OFFSET_MV"
      wait_for_cards                      # sets CARD_DEVS or dies (called directly so die aborts)
      for dev in "${CARD_DEVS[@]}"; do apply_offset "$dev" "$OFFSET_MV"; done
      ;;
    --reset)
      # Best-effort return to stock voltage (used on service stop). Reset every
      # matching V620; if none are present (amdgpu unloaded) there is nothing to do.
      mapfile -t CARD_DEVS < <(resolve_card_devs)
      if (( ${#CARD_DEVS[@]} >= 1 )); then
        for dev in "${CARD_DEVS[@]}"; do apply_offset "$dev" 0; done
      else
        log "no matching OverDrive node present; nothing to reset"
      fi
      ;;
    *) die "usage: gpu-undervolt [apply|--reset]" ;;
  esac
}

main "$@"
