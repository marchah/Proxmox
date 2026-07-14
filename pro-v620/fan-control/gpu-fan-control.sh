#!/usr/bin/env bash
#
# gpu-fan-control — drive the Radeon Pro V620 blower (wired to PUMP_FAN1) from
# the GPU's own temperature, via the writable out-of-tree nct6687 hwmon driver.
#
# Why this exists: the MSI MAG B550 board's in-tree nct6683 driver is read-only,
# so the BIOS can only steer PUMP_FAN1 off its PCIE temperature probe, never the
# GPU die. This daemon reads amdgpu's sensors and writes the fan PWM directly
# (manual mode). PUMP_FAN1 is pwm channel 2 on this board (verified empirically:
# driving pwm2 moved only fan2's RPM).
#
# The V620 is a passively cooled datacenter card — the blower is its ONLY
# cooling — so the daemon is defensive about it:
#   * the curve is driven by EDGE temp; the HOTTEST of junction+mem forces 100%;
#   * EVERY sensor present at startup is required: if any disappears, force 100%;
#   * the blower's tachometer is watched — if it stops spinning while we command
#     airflow, force 100% and (optionally) power off to protect the GPU;
#   * every PWM write is read back; persistent write failures escalate (we cannot
#     trust the fan when our commands are not taking effect);
#   * the fan never stops, and any read failure fails toward MORE cooling.
#
# Intentionally NOT `set -e`: this is a long-running loop where a transient sysfs
# read returning nonzero (or an arithmetic (( )) evaluating to 0) must not kill
# the daemon. Errors are handled explicitly.
set -uo pipefail

# ---- config (override via /etc/gpu-fan-control-<instance>.env) --------------
GPU_HWMON_NAME="${GPU_HWMON_NAME:-amdgpu}"
# Which GPU(s) this fan cools, by exact PCI address (stable across boots; cardN is
# not). Empty = first amdgpu found. A COMMA-SEPARATED list (e.g.
# "0000:2d:00.0,0000:06:00.0") is supported for ONE fan cooling SEVERAL GPUs (a
# shared shroud): the curve then tracks the HOTTEST card, and any required sensor
# missing on ANY of them forces 100%.
GPU_PCI_ADDRESS="${GPU_PCI_ADDRESS:-}"
FAN_HWMON_NAME="${FAN_HWMON_NAME:-nct6687}"
FAN_PWM_CHANNEL="${FAN_PWM_CHANNEL:-2}"          # pwm channel driving THIS GPU's fan
FAN_LABEL="${FAN_LABEL:-fan}"                    # cosmetic name for logs (e.g. blower, arctic)

# Curve is driven by the EDGE temperature (the stable "GPU temp").
CURVE_TEMP_LABEL="${CURVE_TEMP_LABEL:-edge}"
EDGE_MIN_C="${EDGE_MIN_C:-35}"                   # at/below -> PWM_MIN_PCT
EDGE_MAX_C="${EDGE_MAX_C:-88}"                   # at/above -> 100%
PWM_MIN_PCT="${PWM_MIN_PCT:-12}"                 # ramp anchor; idle floor pinned by MIN_PWM_RAW

# Safety override: the HOTTEST of these hotspot sensors forces 100% (hysteresis).
# Each label listed here must be present at startup (junction crit 100C, mem/GDDR6
# crit 98C) and is then required — losing any one mid-run forces 100%.
HOTSPOT_TEMP_LABELS="${HOTSPOT_TEMP_LABELS:-junction mem}"
HOTSPOT_OVERRIDE_C="${HOTSPOT_OVERRIDE_C:-90}"
HOTSPOT_RESUME_C="${HOTSPOT_RESUME_C:-87}"

POLL_INTERVAL="${POLL_INTERVAL:-4}"              # seconds
PWM_STEP="${PWM_STEP:-4}"                        # min raw delta before re-writing
MIN_PWM_RAW="${MIN_PWM_RAW:-32}"                 # hard floor (~12.5%); never below
PWM_READBACK_TOL="${PWM_READBACK_TOL:-4}"        # max |written-readback| counted as success
# nct6687 refreshes its sensor cache only ~once per second (measured), so the readback
# window MUST span more than one refresh or every read returns the same stale value.
# Window = (RETRIES-1)*SLEEP; default 5 x 0.5s = ~2s (TTL ~1.0s + margin).
PWM_READBACK_RETRIES="${PWM_READBACK_RETRIES:-5}"           # readback attempts per write
PWM_READBACK_RETRY_SLEEP="${PWM_READBACK_RETRY_SLEEP:-0.5}"  # backoff between attempts

# Failure handling — the V620 is passively cooled, so loss of control = no cooling.
FAN_RPM_MONITOR="${FAN_RPM_MONITOR:-auto}"       # auto|on|off (auto = on iff a tach reads >0 at start)
FAN_MIN_RPM="${FAN_MIN_RPM:-150}"                # below this, while commanding airflow, = not spinning
FAN_FAIL_GRACE="${FAN_FAIL_GRACE:-3}"            # consecutive bad polls before declaring a blower failure
WRITE_FAIL_GRACE="${WRITE_FAIL_GRACE:-3}"        # consecutive failed PWM writes before CRITICAL
FAN_FAIL_ACTION="${FAN_FAIL_ACTION:-warn}"       # warn | poweroff (power off to protect the GPU)
FAN_FAIL_POWEROFF_GRACE="${FAN_FAIL_POWEROFF_GRACE:-15}"  # bad polls before poweroff (if enabled)

# ---------------------------------------------------------------------------
log() { printf 'gpu-fan-control: %s\n' "$*"; }

# Resolve a hwmon dir by its `name` (the hwmonN number is not stable across boots).
resolve_hwmon() {  # $1 = name ; echoes path or returns 1
  local want="$1" h
  for h in /sys/class/hwmon/hwmon* /sys/class/drm/card*/device/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    if [ "$(cat "$h/name" 2>/dev/null)" = "$want" ]; then echo "$h"; return 0; fi
  done
  return 1
}

# Resolve the GPU hwmon dir(s) this fan cools. GPU_PCI_ADDRESS may be empty (first
# amdgpu found), a single PCI address, or a comma-separated list (one fan cooling
# several GPUs via a shared shroud). Echoes one hwmon path per resolved GPU, in the
# listed order; returns 1 if none found. The hwmon's `device` symlink resolves to the
# PCI device dir; its basename is the PCI address (matching by address is boot-stable).
resolve_gpu_hwmons() {  # echoes path(s), one per line; returns 1 if none
  local h pci addr found=0
  local -a addrs
  if [ -z "$GPU_PCI_ADDRESS" ]; then
    for h in /sys/class/drm/card*/device/hwmon/hwmon* /sys/class/hwmon/hwmon*; do
      [ -r "$h/name" ] || continue
      [ "$(cat "$h/name" 2>/dev/null)" = "$GPU_HWMON_NAME" ] || continue
      echo "$h"; return 0
    done
    return 1
  fi
  IFS=',' read -ra addrs <<< "$GPU_PCI_ADDRESS"
  for addr in "${addrs[@]}"; do
    addr="${addr// /}"; [ -n "$addr" ] || continue
    for h in /sys/class/drm/card*/device/hwmon/hwmon* /sys/class/hwmon/hwmon*; do
      [ -r "$h/name" ] || continue
      [ "$(cat "$h/name" 2>/dev/null)" = "$GPU_HWMON_NAME" ] || continue
      pci="$(basename "$(readlink -f "$h/device" 2>/dev/null)" 2>/dev/null)"
      [ "$pci" = "$addr" ] || continue
      echo "$h"; found=1; break
    done
  done
  (( found )) && return 0 || return 1
}

# Read a labelled temperature (whole °C) from an amdgpu hwmon dir.
read_temp_c() {  # $1 = hwmon dir, $2 = label ; echoes °C or returns 1
  local d="$1" want="$2" f base milli
  [ -n "$d" ] || return 1
  for f in "$d"/temp*_label; do
    [ -r "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "$want" ] || continue
    base="${f%_label}"
    milli="$(cat "${base}_input" 2>/dev/null)" || return 1
    [ -n "$milli" ] || return 1
    echo $(( milli / 1000 ))
    return 0
  done
  return 1
}

pct_to_raw() {  # $1 = pct ; echoes 0-255 clamped to [MIN_PWM_RAW,255]
  local raw=$(( $1 * 255 / 100 ))
  (( raw < MIN_PWM_RAW )) && raw=$MIN_PWM_RAW
  (( raw > 255 )) && raw=255
  echo "$raw"
}

raw_for_temp() {  # $1 = curve-input °C ; echoes target raw pwm via the curve
  local t="$1" pct
  if   (( t <= EDGE_MIN_C )); then pct=$PWM_MIN_PCT
  elif (( t >= EDGE_MAX_C )); then pct=100
  else pct=$(( PWM_MIN_PCT + (t - EDGE_MIN_C) * (100 - PWM_MIN_PCT) / (EDGE_MAX_C - EDGE_MIN_C) ))
  fi
  pct_to_raw "$pct"
}

FAN_CHIP=""
read_fan_rpm() {  # echoes the blower RPM (fanN_input) or returns 1
  [ -n "$FAN_CHIP" ] || return 1
  cat "$FAN_CHIP/fan${FAN_PWM_CHANNEL}_input" 2>/dev/null
}

# Read pwmN back until it settles within `tol` of `target`. nct6687 refreshes its
# sensor cache only ~once per second (measured), so a read within ~1s of the write
# returns the PRE-write value; the retry window ((RETRIES-1)*SLEEP, ~2s by default)
# must span more than one refresh. A transient read error / empty read does NOT abort
# — it just consumes one attempt; we fail only if NO attempt yields a matching value.
# Echoes the settled value (or the last one read); returns 0 iff some reading matched.
pwm_read_settled() {  # $1 = pwm path, $2 = target, $3 = tol
  local pw="$1" target="$2" tol="$3" got d i last=""
  for (( i = 0; i < PWM_READBACK_RETRIES; i++ )); do
    (( i > 0 )) && sleep "$PWM_READBACK_RETRY_SLEEP"
    got="$(cat "$pw" 2>/dev/null)"; [ -n "$got" ] || continue
    last="$got"
    d=$(( got - target )); (( d < 0 )) && d=$(( -d ))
    if (( d <= tol )); then printf '%s' "$got"; return 0; fi
  done
  printf '%s' "$last"
  return 1
}

# Write PWM in manual mode and CONFIRM it took effect (the SIO can reject/clamp a
# write, which must not be mistaken for success). Returns nonzero on any failure.
write_pwm() {  # $1 = raw
  [ -n "$FAN_CHIP" ] || return 1
  local en="$FAN_CHIP/pwm${FAN_PWM_CHANNEL}_enable" pw="$FAN_CHIP/pwm${FAN_PWM_CHANNEL}"
  [ "$(cat "$en" 2>/dev/null)" = "1" ] || echo 1 > "$en" 2>/dev/null || return 1
  echo "$1" > "$pw" 2>/dev/null || return 1
  pwm_read_settled "$pw" "$1" "$PWM_READBACK_TOL" >/dev/null
}

# Apply a target PWM, tracking success/failure. last_raw is updated ONLY on a
# confirmed write, so a failed write keeps us retrying (and the failure visible)
# rather than pretending the new speed is in effect. Persistent write failures
# escalate exactly like a dead blower — control is effectively lost either way.
write_fail=0
apply_pwm() {  # $1 = target raw ; returns write_pwm status
  local target="$1"
  if write_pwm "$target"; then
    last_raw="$target"
    write_fail=0
    return 0
  fi
  write_fail=$(( write_fail + 1 ))
  if (( write_fail == WRITE_FAIL_GRACE )) || (( write_fail % 15 == 0 )); then
    log "CRITICAL: PWM write/readback failing (#${write_fail}, target=${target}) on ${FAN_CHIP:-?} — fan control may be lost"
  fi
  if [ "$FAN_FAIL_ACTION" = poweroff ] && (( write_fail >= FAN_FAIL_POWEROFF_GRACE )); then
    log "CRITICAL: PWM control not restored after ${write_fail} writes; powering off to protect the GPU (FAN_FAIL_ACTION=poweroff)"
    systemctl poweroff 2>/dev/null || poweroff 2>/dev/null || true
  fi
  return 1
}

# Restore a verified-safe fan state. Prefer BIOS/SIO auto (enable=2); if that
# can't be confirmed, fall back to a verified manual 100%. Returns nonzero only
# if NEITHER safe state could be confirmed (so ExecStopPost surfaces the failure).
# Auto is attempted first (not 100%-first) to avoid a spurious full-speed blip on
# every clean stop; if auto fails we still end at a verified 100%, never at idle.
failsafe() {
  local chip="${FAN_CHIP:-}"
  [ -n "$chip" ] || chip="$(resolve_hwmon "$FAN_HWMON_NAME" || true)"
  if [ -z "$chip" ]; then
    log "FAILSAFE ERROR: '$FAN_HWMON_NAME' hwmon not found; cannot set a safe fan state"
    return 1
  fi
  local en="$chip/pwm${FAN_PWM_CHANNEL}_enable" pw="$chip/pwm${FAN_PWM_CHANNEL}" v
  echo 2 > "$en" 2>/dev/null
  if [ "$(cat "$en" 2>/dev/null)" = "2" ]; then
    log "failsafe: ${FAN_LABEL} (pwm${FAN_PWM_CHANNEL}) handed back to BIOS auto (enable=2)"
    return 0
  fi
  echo 1 > "$en" 2>/dev/null
  echo 255 > "$pw" 2>/dev/null
  # Same async-cache race as write_pwm: retry the readback (tol 15 => accept >=240).
  if v="$(pwm_read_settled "$pw" 255 15)" && [ "$(cat "$en" 2>/dev/null)" = "1" ]; then
    log "WARN failsafe: could not restore BIOS auto; forced ${FAN_LABEL} to 100% (manual, pwm=$v)"
    return 0
  fi
  log "CRITICAL failsafe: could not set ANY safe fan state (auto or 100%) on pwm${FAN_PWM_CHANNEL}"
  return 1
}

# Validate the readback-retry knobs up front — a bad value would make EVERY verified
# write fail and could escalate to a false poweroff. Runs before BOTH the --failsafe
# one-shot and the control loop; clamp to safe defaults.
# RETRIES must be a base-10 integer >= 1. Force base-10 (10#) so a value like "08"
# is not mis-parsed as invalid octal by the later (( )) (which would run zero attempts
# and fail every write); this also normalizes away leading zeros.
if [[ "$PWM_READBACK_RETRIES" =~ ^[0-9]+$ ]] && (( 10#$PWM_READBACK_RETRIES >= 1 )); then
  PWM_READBACK_RETRIES=$(( 10#$PWM_READBACK_RETRIES ))
else
  log "WARN: PWM_READBACK_RETRIES='${PWM_READBACK_RETRIES}' invalid (need integer >=1); using 5"
  PWM_READBACK_RETRIES=5
fi
# RETRY_SLEEP must be a POSITIVE number — zero (0, 0.0, 00) removes the backoff the
# retries rely on to let the async EC cache update, defeating the fix. Reject
# non-numbers and any all-zero value.
if ! [[ "$PWM_READBACK_RETRY_SLEEP" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ "$PWM_READBACK_RETRY_SLEEP" =~ ^0*([.]0*)?$ ]]; then
  log "WARN: PWM_READBACK_RETRY_SLEEP='${PWM_READBACK_RETRY_SLEEP}' invalid (need a positive number); using 0.1"
  PWM_READBACK_RETRY_SLEEP=0.1
fi

# --failsafe: one-shot used by the unit's ExecStopPost (also covers SIGKILL,
# where the EXIT trap below would not run). Propagate its exit status.
if [ "${1:-}" = "--failsafe" ]; then failsafe; exit $?; fi

trap 'exit 0' INT TERM
trap 'failsafe' EXIT

# ---- startup ---------------------------------------------------------------
mapfile -t GPU_CHIPS < <(resolve_gpu_hwmons)
FAN_CHIP="$(resolve_hwmon "$FAN_HWMON_NAME" || true)"
[ -n "$FAN_CHIP" ] || { log "FATAL: '$FAN_HWMON_NAME' hwmon not found (is the nct6687 module loaded?)"; exit 1; }
(( ${#GPU_CHIPS[@]} >= 1 )) || { log "FATAL: no '$GPU_HWMON_NAME' hwmon found${GPU_PCI_ADDRESS:+ for $GPU_PCI_ADDRESS} (is amdgpu bound to the V620(s)?)"; exit 1; }

# Curve + hotspot sensors are mandatory on EVERY cooled GPU: with one fan cooling
# several cards the curve tracks the hottest, and a missing sensor on ANY card forces
# the safety state at runtime — so a card lacking one must fail loudly here at startup.
read -ra HOTSPOT_LABELS <<< "$HOTSPOT_TEMP_LABELS"
for gc in "${GPU_CHIPS[@]}"; do
  read_temp_c "$gc" "$CURVE_TEMP_LABEL" >/dev/null 2>&1 \
    || { log "FATAL: curve sensor '$CURVE_TEMP_LABEL' not present on $gc"; exit 1; }
done
if (( ${#HOTSPOT_LABELS[@]} == 0 )); then
  log "WARN: no hotspot sensors configured (HOTSPOT_TEMP_LABELS empty) — high-temp override DISABLED"
else
  for gc in "${GPU_CHIPS[@]}"; do
    for label in "${HOTSPOT_LABELS[@]}"; do
      read_temp_c "$gc" "$label" >/dev/null 2>&1 \
        || { log "FATAL: hotspot sensor '$label' not present on $gc (adjust HOTSPOT_TEMP_LABELS if this card differs)"; exit 1; }
    done
  done
fi

# Watch the blower tach? (auto: only if it reports RPM now — off for 2-wire fans.)
fan_monitor=0
case "$FAN_RPM_MONITOR" in
  on)  fan_monitor=1 ;;
  off) fan_monitor=0 ;;
  *)
    rpm0="$(read_fan_rpm)"
    if [ -n "$rpm0" ] && (( rpm0 > 0 )); then fan_monitor=1
    else log "WARN: blower tach reads no RPM at start — tach watchdog DISABLED (set FAN_RPM_MONITOR=on to force)"; fi
    ;;
esac

log "started[${FAN_LABEL}]: GPUs=${GPU_CHIPS[*]} FAN=$FAN_CHIP pwm${FAN_PWM_CHANNEL}; curve ${PWM_MIN_PCT}%@${EDGE_MIN_C}C..100%@${EDGE_MAX_C}C (hottest of ${#GPU_CHIPS[@]} GPU(s)); hotspot override>=${HOTSPOT_OVERRIDE_C}C (${HOTSPOT_TEMP_LABELS:-none}); tach_watchdog=${fan_monitor} fail_action=${FAN_FAIL_ACTION}"

last_raw=-1
override=0
fan_fail=0
loops=0
while :; do
  loops=$(( loops + 1 ))
  # Re-resolve GPU chips if any went missing (e.g. amdgpu rebind).
  for gc in "${GPU_CHIPS[@]}"; do [ -d "$gc" ] || { mapfile -t GPU_CHIPS < <(resolve_gpu_hwmons); break; }; done
  [ -d "$FAN_CHIP" ] || FAN_CHIP="$(resolve_hwmon "$FAN_HWMON_NAME" || true)"

  # edge = HOTTEST curve-temp across all cooled GPUs (one fan may cool several). A card
  # whose sensor is unreadable, or none readable at all, is a fault (fail toward cooling).
  edge=""; edge_missing=0
  for gc in "${GPU_CHIPS[@]}"; do
    v="$(read_temp_c "$gc" "$CURVE_TEMP_LABEL")" || { edge_missing=1; continue; }
    if [ -z "$edge" ] || (( v > edge )); then edge="$v"; fi
  done
  rpm="$(read_fan_rpm)" || rpm=""

  # Hotspot = hottest of the REQUIRED labels across all cooled GPUs; flag any missing.
  hotspot=""
  hotspot_missing=0
  if (( ${#HOTSPOT_LABELS[@]} )); then
    for gc in "${GPU_CHIPS[@]}"; do
      for label in "${HOTSPOT_LABELS[@]}"; do
        v="$(read_temp_c "$gc" "$label")" || { hotspot_missing=1; continue; }
        if [ -z "$hotspot" ] || (( v > hotspot )); then hotspot="$v"; fi
      done
    done
  fi

  # --- sensor fault: a required sensor present at startup is now missing ---
  sensor_fault=0
  { [ -z "$edge" ] || (( edge_missing )); } && sensor_fault=1
  (( hotspot_missing )) && sensor_fault=1

  # --- blower fault: commanding airflow but the tach says it's not spinning ---
  blower_fault=0
  if (( fan_monitor )); then
    if (( last_raw >= MIN_PWM_RAW )) && { [ -z "$rpm" ] || (( rpm < FAN_MIN_RPM )); }; then
      fan_fail=$(( fan_fail + 1 ))
    else
      fan_fail=0
    fi
    (( fan_fail >= FAN_FAIL_GRACE )) && blower_fault=1
  fi

  # --- faults force 100% and fail loud (writes still verified by apply_pwm) ---
  if (( sensor_fault || blower_fault )); then
    (( sensor_fault )) && (( loops % 10 == 1 )) && \
      log "WARN: required GPU sensor missing (edge='${edge:-}' hotspot_missing=${hotspot_missing}); forcing 100%"
    if (( blower_fault )); then
      if (( fan_fail == FAN_FAIL_GRACE )) || (( fan_fail % 15 == 0 )); then
        log "CRITICAL: blower not spinning (rpm='${rpm:-?}' < ${FAN_MIN_RPM} while commanding pwm>=${MIN_PWM_RAW}) — V620 has NO other cooling; forced 100%"
      fi
      if [ "$FAN_FAIL_ACTION" = poweroff ] && (( fan_fail >= FAN_FAIL_POWEROFF_GRACE )); then
        log "CRITICAL: airflow not restored after ${fan_fail} polls; powering off to protect the GPU (FAN_FAIL_ACTION=poweroff)"
        systemctl poweroff 2>/dev/null || poweroff 2>/dev/null || true
      fi
    fi
    apply_pwm 255
    sleep "$POLL_INTERVAL"; continue
  fi

  # --- normal control ---
  if [ -n "$hotspot" ]; then
    if   (( hotspot >= HOTSPOT_OVERRIDE_C )); then override=1
    elif (( hotspot <= HOTSPOT_RESUME_C  )); then override=0
    fi
  fi

  if (( override )); then target=255
  else                    target="$(raw_for_temp "$edge")"
  fi

  # Write on first pass, a meaningful change, or to hold full speed; log only on a
  # real change (so a sustained override / re-assert does not spam the journal).
  diff=$(( target - last_raw )); (( diff < 0 )) && diff=$(( -diff ))
  if (( last_raw < 0 || diff >= PWM_STEP || target == 255 )); then
    prev=$last_raw
    if apply_pwm "$target" && (( prev != target )); then
      log "edge=${edge}C hotspot=${hotspot:-?}C rpm=${rpm:-?} override=$override -> pwm=${target}/255 ($(( target * 100 / 255 ))%)"
    fi
  fi

  sleep "$POLL_INTERVAL"
done
