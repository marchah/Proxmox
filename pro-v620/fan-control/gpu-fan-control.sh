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
#   * a required sensor going missing forces 100% (never silently lose a limit);
#   * the blower's tachometer is watched — if it stops spinning while we command
#     airflow, force 100% and (optionally) power off to protect the GPU;
#   * the fan never stops, and any read failure fails toward MORE cooling.
#
# Intentionally NOT `set -e`: this is a long-running loop where a transient sysfs
# read returning nonzero (or an arithmetic (( )) evaluating to 0) must not kill
# the daemon. Errors are handled explicitly.
set -uo pipefail

# ---- config (override via /etc/gpu-fan-control.env) -------------------------
GPU_HWMON_NAME="${GPU_HWMON_NAME:-amdgpu}"
FAN_HWMON_NAME="${FAN_HWMON_NAME:-nct6687}"
FAN_PWM_CHANNEL="${FAN_PWM_CHANNEL:-2}"          # PUMP_FAN1 = pwm2/fan2 (verified)

# Curve is driven by the EDGE temperature (the stable "GPU temp").
CURVE_TEMP_LABEL="${CURVE_TEMP_LABEL:-edge}"
EDGE_MIN_C="${EDGE_MIN_C:-35}"                   # at/below -> PWM_MIN_PCT
EDGE_MAX_C="${EDGE_MAX_C:-88}"                   # at/above -> 100%
PWM_MIN_PCT="${PWM_MIN_PCT:-12}"                 # ramp anchor; idle floor pinned by MIN_PWM_RAW

# Safety override: the HOTTEST of these hotspot sensors forces 100% (hysteresis).
# Both junction (crit 100C) and mem/GDDR6 (crit 98C) are watched.
HOTSPOT_TEMP_LABELS="${HOTSPOT_TEMP_LABELS:-junction mem}"
HOTSPOT_OVERRIDE_C="${HOTSPOT_OVERRIDE_C:-90}"
HOTSPOT_RESUME_C="${HOTSPOT_RESUME_C:-87}"

POLL_INTERVAL="${POLL_INTERVAL:-4}"              # seconds
PWM_STEP="${PWM_STEP:-4}"                        # min raw delta before re-writing
MIN_PWM_RAW="${MIN_PWM_RAW:-32}"                 # hard floor (~12.5%); never below

# Blower tach watchdog (the only cooling — a dead blower must not pass silently).
FAN_RPM_MONITOR="${FAN_RPM_MONITOR:-auto}"       # auto|on|off (auto = on iff a tach reads >0 at start)
FAN_MIN_RPM="${FAN_MIN_RPM:-150}"                # below this, while commanding airflow, = not spinning
FAN_FAIL_GRACE="${FAN_FAIL_GRACE:-3}"            # consecutive bad polls before declaring failure
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

# Hottest of the configured hotspot labels; echoes °C or returns 1 if none read.
read_hotspot_c() {  # $1 = gpu hwmon dir
  local d="$1" label v max="" labels
  read -ra labels <<< "$HOTSPOT_TEMP_LABELS"
  for label in "${labels[@]}"; do
    v="$(read_temp_c "$d" "$label")" || continue
    if [ -z "$max" ] || (( v > max )); then max="$v"; fi
  done
  [ -n "$max" ] && { echo "$max"; return 0; }
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

write_pwm() {  # $1 = raw ; (re)asserts manual mode then writes
  [ -n "$FAN_CHIP" ] || return 1
  local en="$FAN_CHIP/pwm${FAN_PWM_CHANNEL}_enable" pw="$FAN_CHIP/pwm${FAN_PWM_CHANNEL}"
  [ "$(cat "$en" 2>/dev/null)" = "1" ] || echo 1 > "$en" 2>/dev/null || return 1
  echo "$1" > "$pw" 2>/dev/null || return 1
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
    log "failsafe: PUMP_FAN1 (pwm${FAN_PWM_CHANNEL}) handed back to BIOS auto (enable=2)"
    return 0
  fi
  # Auto not confirmed -> force verified manual 100%.
  echo 1 > "$en" 2>/dev/null
  echo 255 > "$pw" 2>/dev/null
  v="$(cat "$pw" 2>/dev/null)"
  if [ "$(cat "$en" 2>/dev/null)" = "1" ] && [ -n "$v" ] && (( v >= 240 )); then
    log "WARN failsafe: could not restore BIOS auto; forced PUMP_FAN1 to 100% (manual, pwm=$v)"
    return 0
  fi
  log "CRITICAL failsafe: could not set ANY safe fan state (auto or 100%) on pwm${FAN_PWM_CHANNEL}"
  return 1
}

# --failsafe: one-shot used by the unit's ExecStopPost (also covers SIGKILL,
# where the EXIT trap below would not run). Propagate its exit status.
if [ "${1:-}" = "--failsafe" ]; then failsafe; exit $?; fi

trap 'exit 0' INT TERM
trap 'failsafe' EXIT

# ---- startup ---------------------------------------------------------------
GPU_CHIP="$(resolve_hwmon "$GPU_HWMON_NAME" || true)"
FAN_CHIP="$(resolve_hwmon "$FAN_HWMON_NAME" || true)"
[ -n "$FAN_CHIP" ] || { log "FATAL: '$FAN_HWMON_NAME' hwmon not found (is the nct6687 module loaded?)"; exit 1; }
[ -n "$GPU_CHIP" ] || { log "FATAL: '$GPU_HWMON_NAME' hwmon not found (is amdgpu bound to the V620?)"; exit 1; }

# Which sensors exist now becomes what we REQUIRE later: if one disappears
# mid-run we fail toward cooling rather than silently dropping a limit.
EXPECT_EDGE=0;    read_temp_c   "$GPU_CHIP" "$CURVE_TEMP_LABEL" >/dev/null 2>&1 && EXPECT_EDGE=1
EXPECT_HOTSPOT=0; read_hotspot_c "$GPU_CHIP"                    >/dev/null 2>&1 && EXPECT_HOTSPOT=1
(( EXPECT_EDGE )) || { log "FATAL: curve sensor '$CURVE_TEMP_LABEL' not present on $GPU_CHIP"; exit 1; }
(( EXPECT_HOTSPOT )) || log "WARN: no hotspot sensor ($HOTSPOT_TEMP_LABELS) found — high-temp override DISABLED"

# Decide whether to watch the blower tach (auto: only if it reports RPM now).
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

log "started: GPU=$GPU_CHIP FAN=$FAN_CHIP pwm${FAN_PWM_CHANNEL}; curve ${PWM_MIN_PCT}%@${EDGE_MIN_C}C..100%@${EDGE_MAX_C}C; hotspot override>=${HOTSPOT_OVERRIDE_C}C (${HOTSPOT_TEMP_LABELS}); tach_watchdog=${fan_monitor} fail_action=${FAN_FAIL_ACTION}"

last_raw=-1
override=0
fan_fail=0
loops=0
while :; do
  loops=$(( loops + 1 ))
  [ -d "$GPU_CHIP" ] || GPU_CHIP="$(resolve_hwmon "$GPU_HWMON_NAME" || true)"
  [ -d "$FAN_CHIP" ] || FAN_CHIP="$(resolve_hwmon "$FAN_HWMON_NAME" || true)"

  edge="$(read_temp_c "$GPU_CHIP" "$CURVE_TEMP_LABEL")" || edge=""
  hotspot="$(read_hotspot_c "$GPU_CHIP")"               || hotspot=""
  rpm="$(read_fan_rpm)"                                 || rpm=""

  # --- sensor fault: a sensor we relied on at startup is now missing ---
  sensor_fault=0
  if (( EXPECT_EDGE ))    && [ -z "$edge" ];    then sensor_fault=1; fi
  if (( EXPECT_HOTSPOT )) && [ -z "$hotspot" ]; then sensor_fault=1; fi

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

  # --- faults force 100% and fail loud ---
  if (( sensor_fault || blower_fault )); then
    (( sensor_fault )) && (( loops % 10 == 1 )) && \
      log "WARN: required GPU sensor missing (edge='${edge:-}' hotspot='${hotspot:-}'); forcing 100%"
    if (( blower_fault )); then
      if (( fan_fail == FAN_FAIL_GRACE )) || (( fan_fail % 15 == 0 )); then
        log "CRITICAL: blower not spinning (rpm='${rpm:-?}' < ${FAN_MIN_RPM} while commanding pwm>=${MIN_PWM_RAW}) — V620 has NO other cooling; forced 100%"
      fi
      if [ "$FAN_FAIL_ACTION" = poweroff ] && (( fan_fail >= FAN_FAIL_POWEROFF_GRACE )); then
        log "CRITICAL: airflow not restored after ${fan_fail} polls; powering off to protect the GPU (FAN_FAIL_ACTION=poweroff)"
        systemctl poweroff 2>/dev/null || poweroff 2>/dev/null || true
      fi
    fi
    write_pwm 255 || log "ERROR: failed writing PWM during fault"
    last_raw=255
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

  # Hysteresis: only write on a meaningful change (or first pass / full speed).
  diff=$(( target - last_raw )); (( diff < 0 )) && diff=$(( -diff ))
  if (( last_raw < 0 || diff >= PWM_STEP || target == 255 )); then
    if write_pwm "$target"; then
      log "edge=${edge}C hotspot=${hotspot:-?}C rpm=${rpm:-?} override=$override -> pwm=${target}/255 ($(( target * 100 / 255 ))%)"
      last_raw=$target
    else
      log "ERROR: failed writing pwm=${target} to ${FAN_CHIP:-?}"
    fi
  fi

  sleep "$POLL_INTERVAL"
done
