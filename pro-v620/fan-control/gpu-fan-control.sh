#!/usr/bin/env bash
#
# gpu-fan-control — drive the Radeon Pro V620 blower (wired to PUMP_FAN1) from
# the GPU's own temperature, via the writable out-of-tree nct6687 hwmon driver.
#
# Why this exists: the MSI MAG B550 board's in-tree nct6683 driver is read-only,
# so the BIOS can only steer PUMP_FAN1 off its PCIE temperature probe, never the
# GPU die. This daemon reads amdgpu's edge/junction sensors and writes the fan
# PWM directly (manual mode). PUMP_FAN1 is pwm channel 2 on this board (verified
# empirically: driving pwm2 moved only fan2's RPM). The V620 is a passively
# cooled datacenter card — the blower is its ONLY cooling — so the fan is never
# stopped and reads of the GPU sensor fail toward MORE cooling.
#
# Intentionally NOT `set -e`: this is a long-running loop where a transient
# sysfs read returning nonzero (or an arithmetic (( )) evaluating to 0) must not
# kill the daemon. Errors are handled explicitly.
set -uo pipefail

# ---- config (override via /etc/gpu-fan-control.env) -------------------------
GPU_HWMON_NAME="${GPU_HWMON_NAME:-amdgpu}"
FAN_HWMON_NAME="${FAN_HWMON_NAME:-nct6687}"
FAN_PWM_CHANNEL="${FAN_PWM_CHANNEL:-2}"          # PUMP_FAN1 = pwm2 (verified)

# Curve is driven by the EDGE temperature (the stable "GPU temp").
CURVE_TEMP_LABEL="${CURVE_TEMP_LABEL:-edge}"
EDGE_MIN_C="${EDGE_MIN_C:-35}"                   # at/below -> PWM_MIN_PCT
EDGE_MAX_C="${EDGE_MAX_C:-88}"                   # at/above -> 100%
PWM_MIN_PCT="${PWM_MIN_PCT:-12}"                 # ramp anchor; idle floor pinned by MIN_PWM_RAW

# Safety override: the hotspot (junction) forces full speed, with hysteresis.
OVERRIDE_TEMP_LABEL="${OVERRIDE_TEMP_LABEL:-junction}"
JUNCTION_OVERRIDE_C="${JUNCTION_OVERRIDE_C:-90}"
JUNCTION_RESUME_C="${JUNCTION_RESUME_C:-87}"

POLL_INTERVAL="${POLL_INTERVAL:-4}"              # seconds
PWM_STEP="${PWM_STEP:-4}"                        # min raw delta before re-writing
MIN_PWM_RAW="${MIN_PWM_RAW:-32}"                 # hard floor (~12.5%); never below

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
write_pwm() {  # $1 = raw ; (re)asserts manual mode then writes
  [ -n "$FAN_CHIP" ] || return 1
  local en="$FAN_CHIP/pwm${FAN_PWM_CHANNEL}_enable" pw="$FAN_CHIP/pwm${FAN_PWM_CHANNEL}"
  [ "$(cat "$en" 2>/dev/null)" = "1" ] || echo 1 > "$en" 2>/dev/null || return 1
  echo "$1" > "$pw" 2>/dev/null || return 1
}

failsafe() {  # hand PUMP_FAN1 back to BIOS/SIO auto (enable=2)
  local chip="${FAN_CHIP:-}"
  [ -n "$chip" ] || chip="$(resolve_hwmon "$FAN_HWMON_NAME" || true)"
  [ -n "$chip" ] || return 0
  echo 2 > "$chip/pwm${FAN_PWM_CHANNEL}_enable" 2>/dev/null || true
  log "failsafe: PUMP_FAN1 (pwm${FAN_PWM_CHANNEL}) handed back to BIOS auto (enable=2)"
}

# --failsafe: one-shot used by the unit's ExecStopPost (also covers SIGKILL,
# where the EXIT trap below would not run).
if [ "${1:-}" = "--failsafe" ]; then failsafe; exit 0; fi

trap 'exit 0' INT TERM
trap 'failsafe' EXIT

# ---- startup ---------------------------------------------------------------
GPU_CHIP="$(resolve_hwmon "$GPU_HWMON_NAME" || true)"
FAN_CHIP="$(resolve_hwmon "$FAN_HWMON_NAME" || true)"
[ -n "$FAN_CHIP" ] || { log "FATAL: '$FAN_HWMON_NAME' hwmon not found (is the nct6687 module loaded?)"; exit 1; }
[ -n "$GPU_CHIP" ] || { log "FATAL: '$GPU_HWMON_NAME' hwmon not found (is amdgpu bound to the V620?)"; exit 1; }
log "started: GPU=$GPU_CHIP FAN=$FAN_CHIP pwm${FAN_PWM_CHANNEL}; curve ${PWM_MIN_PCT}%@${EDGE_MIN_C}C..100%@${EDGE_MAX_C}C; junction override>=${JUNCTION_OVERRIDE_C}C"

last_raw=-1
override=0
fail=0
while :; do
  [ -d "$GPU_CHIP" ] || GPU_CHIP="$(resolve_hwmon "$GPU_HWMON_NAME" || true)"
  [ -d "$FAN_CHIP" ] || FAN_CHIP="$(resolve_hwmon "$FAN_HWMON_NAME" || true)"

  edge="$(read_temp_c "$GPU_CHIP" "$CURVE_TEMP_LABEL")"     || edge=""
  junc="$(read_temp_c "$GPU_CHIP" "$OVERRIDE_TEMP_LABEL")"  || junc=""

  if [ -z "$edge" ] && [ -z "$junc" ]; then
    # Can't see the GPU at all -> fail toward cooling.
    fail=$(( fail + 1 ))
    log "WARN: GPU temps unreadable (#$fail); forcing 100%"
    write_pwm 255 || log "ERROR: failed writing PWM"
    last_raw=255
    sleep "$POLL_INTERVAL"; continue
  fi
  fail=0

  # Junction (hotspot) override, with hysteresis to avoid flapping at the edge.
  if [ -n "$junc" ]; then
    if   (( junc >= JUNCTION_OVERRIDE_C )); then override=1
    elif (( junc <= JUNCTION_RESUME_C  )); then override=0
    fi
  fi

  if (( override )); then
    target=255
  else
    # Curve input: edge if present, else fall back to junction (>= edge, so safe).
    if [ -n "$edge" ]; then target="$(raw_for_temp "$edge")"
    else target="$(raw_for_temp "$junc")"; fi
  fi

  # Hysteresis: only write on a meaningful change (or first pass / full speed).
  diff=$(( target - last_raw )); (( diff < 0 )) && diff=$(( -diff ))
  if (( last_raw < 0 || diff >= PWM_STEP || target == 255 )); then
    if write_pwm "$target"; then
      log "edge=${edge:-?}C junction=${junc:-?}C override=$override -> pwm=${target}/255 ($(( target * 100 / 255 ))%)"
      last_raw=$target
    else
      log "ERROR: failed writing pwm=${target} to ${FAN_CHIP:-?}"
    fi
  fi

  sleep "$POLL_INTERVAL"
done
