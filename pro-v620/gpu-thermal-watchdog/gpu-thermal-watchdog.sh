#!/usr/bin/env bash
#
# gpu-thermal-watchdog — last-resort over-temp protection for the Radeon Pro V620(s).
#
# It sits BETWEEN the GPU hardware's own two thermal protections:
#   * ~100C junction / 98C mem  -> the GPU THROTTLES its clocks (automatic; it keeps
#     running, just slower). This is normal and fine — we do NOT act on it.
#   * ~105C junction / 103C mem -> the amdgpu driver forces a GPU RESET (MODE1),
#     which crashes/corrupts whatever is running on the card (ungraceful).
#
# This daemon watches junction+mem on every V620 and, if either crosses a trip
# threshold (default 102C junction / 101C mem — above the throttle, below the
# emergency), GRACEFULLY stops the LLM server (llama.cpp in CT 120) to shed the
# load so the card cools before the hardware has to reset it. It is a safety net,
# not a performance tool: the split (normal) workload never gets near these temps;
# only a sustained SOLO full-load on one card does.
#
# Failure philosophy is the OPPOSITE of the fan controller's: stopping the model
# server is DISRUPTIVE, so an unreadable sensor must NOT cause a false trip — it is
# logged loudly and skipped, and the 105C hardware emergency remains the final
# backstop. We only ever act on a temperature we actually read at/over the limit.
#
# Runs on the Proxmox HOST as root (it reads amdgpu hwmon and stops an LXC service
# via pct). Intentionally NOT `set -e`: this is a long-running loop where a transient
# sysfs read returning nonzero must not kill the daemon. Errors are handled explicitly.
set -uo pipefail

# ---- config (override via /etc/gpu-thermal-watchdog.env) --------------------
GPU_HWMON_NAME="${GPU_HWMON_NAME:-amdgpu}"
# Which GPU(s) to watch, by exact PCI address (stable across boots; cardN is not).
# Empty = every amdgpu found. A comma-separated list watches several (both V620s).
GPU_PCI_ADDRESS="${GPU_PCI_ADDRESS:-0000:2d:00.0,0000:06:00.0}"

# Trip thresholds (whole °C). junction emergency is 105C, mem emergency 103C, so
# these sit a few degrees below each — after the 100C/98C throttle, before the reset.
TRIP_JUNCTION_C="${TRIP_JUNCTION_C:-102}"
TRIP_MEM_C="${TRIP_MEM_C:-101}"
# Hysteresis: once tripped, re-arm only after temps drop below this.
RESUME_C="${RESUME_C:-95}"

POLL_SECS="${POLL_SECS:-2}"

# Action on trip: stop = gracefully stop the LLM service; warn = log only (for tests).
WATCHDOG_ACTION="${WATCHDOG_ACTION:-stop}"
# The LLM server lives in an LXC; the host stops it via pct. Override PROTECT_CMD /
# RESUME_CMD (run via `bash -c`) to protect something else entirely.
LLM_CT_VMID="${LLM_CT_VMID:-120}"
LLM_SERVICE="${LLM_SERVICE:-llamacpp}"
PROTECT_CMD="${PROTECT_CMD:-}"
RESUME_CMD="${RESUME_CMD:-}"
# Leave the server DOWN after a trip (default) or auto-restart it once cooled.
# Default false: reaching the trip temp means cooling could not keep up, so resuming
# into the same load risks a loop — require a human to confirm it is safe.
AUTO_RESUME="${AUTO_RESUME:-false}"

# ---------------------------------------------------------------------------
log() { printf 'gpu-thermal-watchdog: %s\n' "$*"; }

# A non-numeric threshold would make every (( )) comparison treat it as 0 and trip
# instantly (stopping the model in a loop) — validate up front, clamp to a default.
validate_int() {  # $1=name $2=value $3=default ; echoes a valid int >=1
  if [[ "$2" =~ ^[0-9]+$ ]] && (( 10#$2 >= 1 )); then echo $(( 10#$2 )); return; fi
  log "WARN: $1='$2' invalid (need integer >=1); using $3"; echo "$3"
}

# Resolve the amdgpu hwmon dir(s) to watch. GPU_PCI_ADDRESS may be empty (every
# amdgpu found) or a comma-separated list. Matching by PCI address is boot-stable
# (the hwmon's `device` symlink basename is the PCI address); cardN is not.
resolve_gpu_hwmons() {  # echoes path(s), one per line; returns 1 if none
  local h pci addr found=0
  local -a addrs
  if [ -z "$GPU_PCI_ADDRESS" ]; then
    for h in /sys/class/drm/card*/device/hwmon/hwmon* /sys/class/hwmon/hwmon*; do
      [ -r "$h/name" ] || continue
      [ "$(cat "$h/name" 2>/dev/null)" = "$GPU_HWMON_NAME" ] || continue
      echo "$h"; found=1
    done
    (( found )) && return 0 || return 1
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

do_protect() {
  if [ -n "$PROTECT_CMD" ]; then bash -c "$PROTECT_CMD"; return $?; fi
  pct exec "$LLM_CT_VMID" -- systemctl stop "$LLM_SERVICE"
}
do_resume() {
  if [ -n "$RESUME_CMD" ]; then bash -c "$RESUME_CMD"; return $?; fi
  pct exec "$LLM_CT_VMID" -- systemctl start "$LLM_SERVICE"
}

TRIP_JUNCTION_C="$(validate_int TRIP_JUNCTION_C "$TRIP_JUNCTION_C" 102)"
TRIP_MEM_C="$(validate_int TRIP_MEM_C "$TRIP_MEM_C" 101)"
RESUME_C="$(validate_int RESUME_C "$RESUME_C" 95)"
POLL_SECS="$(validate_int POLL_SECS "$POLL_SECS" 2)"
(( RESUME_C < TRIP_JUNCTION_C )) || log "WARN: RESUME_C ($RESUME_C) >= TRIP_JUNCTION_C ($TRIP_JUNCTION_C) — hysteresis disabled; re-arm may not work"

trap 'exit 0' INT TERM

# ---- startup ---------------------------------------------------------------
mapfile -t GPU_CHIPS < <(resolve_gpu_hwmons)
(( ${#GPU_CHIPS[@]} >= 1 )) || { log "FATAL: no '$GPU_HWMON_NAME' hwmon found${GPU_PCI_ADDRESS:+ for $GPU_PCI_ADDRESS} (is amdgpu bound to the V620(s)?)"; exit 1; }

# junction is the primary metric and MUST be present on every watched card (its
# absence means the wrong label/card — fail loud). mem is secondary: warn + skip it
# there (junction tracks it closely, so junction alone still protects the card).
declare -A WATCH_MEM=()
for gc in "${GPU_CHIPS[@]}"; do
  read_temp_c "$gc" junction >/dev/null 2>&1 \
    || { log "FATAL: junction sensor not present on $gc — cannot watch it"; exit 1; }
  if read_temp_c "$gc" mem >/dev/null 2>&1; then WATCH_MEM[$gc]=1
  else log "WARN: mem sensor absent on $gc — watching junction only there"; WATCH_MEM[$gc]=0; fi
done

log "started: watching ${#GPU_CHIPS[@]} GPU(s) [${GPU_CHIPS[*]}]; trip junction>=${TRIP_JUNCTION_C}C mem>=${TRIP_MEM_C}C, resume<${RESUME_C}C; action=${WATCHDOG_ACTION} (stop ${LLM_SERVICE} in CT ${LLM_CT_VMID}); auto_resume=${AUTO_RESUME}; poll=${POLL_SECS}s"

tripped=0
loops=0
miss_logged=0
while :; do
  loops=$(( loops + 1 ))
  # Re-resolve if a chip dir vanished (e.g. amdgpu rebind).
  for gc in "${GPU_CHIPS[@]}"; do [ -d "$gc" ] || { mapfile -t GPU_CHIPS < <(resolve_gpu_hwmons); break; }; done

  max_j=""; max_m=""; hot_gc=""; read_ok=0; read_miss=0
  for gc in "${GPU_CHIPS[@]}"; do
    j="$(read_temp_c "$gc" junction)" || { read_miss=1; continue; }
    read_ok=1
    if [ -z "$max_j" ] || (( j > max_j )); then max_j="$j"; hot_gc="$gc"; fi
    if [ "${WATCH_MEM[$gc]:-0}" = "1" ]; then
      m="$(read_temp_c "$gc" mem)" || { read_miss=1; m=""; }
      if [ -n "$m" ] && { [ -z "$max_m" ] || (( m > max_m )); }; then max_m="$m"; fi
    fi
  done

  # A disruptive action must never fire on missing data — log (rate-limited) + skip.
  if (( ! read_ok )); then
    (( loops % 30 == 1 )) && log "WARN: no junction reading from any watched GPU this poll — monitoring degraded (105C hardware emergency remains the backstop)"
    sleep "$POLL_SECS"; continue
  fi
  if (( read_miss )); then
    (( miss_logged == 0 )) && { log "WARN: a temperature read failed this poll — skipping those sensors (will not trip on missing data)"; miss_logged=1; }
  else
    miss_logged=0
  fi

  over=0
  { [ -n "$max_j" ] && (( max_j >= TRIP_JUNCTION_C )); } && over=1
  { [ -n "$max_m" ] && (( max_m >= TRIP_MEM_C )); } && over=1

  if (( over )); then
    if (( tripped == 0 )); then
      tripped=1
      log "CRITICAL: GPU over thermal trip (junction=${max_j:-?}C mem=${max_m:-?}C on ${hot_gc}; limits ${TRIP_JUNCTION_C}/${TRIP_MEM_C}C) — protecting the card"
    fi
    if [ "$WATCHDOG_ACTION" = stop ]; then
      # Idempotent: keep issuing while hot in case an earlier stop did not take.
      if do_protect; then
        (( loops % 15 == 1 )) && log "stop issued: ${LLM_SERVICE} in CT ${LLM_CT_VMID} (junction=${max_j:-?}C)"
      else
        log "ERROR: protect action failed (junction=${max_j:-?}C) — retrying; hardware will reset at emergency temp if uncooled"
      fi
    else
      (( loops % 15 == 1 )) && log "WARN (action=warn): would stop ${LLM_SERVICE} now (junction=${max_j:-?}C) — no action taken"
    fi
  elif (( tripped == 1 )); then
    rearm=1
    { [ -n "$max_j" ] && (( max_j >= RESUME_C )); } && rearm=0
    { [ -n "$max_m" ] && (( max_m >= RESUME_C )); } && rearm=0
    if (( rearm )); then
      tripped=0
      if [ "$AUTO_RESUME" = true ] && [ "$WATCHDOG_ACTION" = stop ]; then
        if do_resume; then log "cooled to junction=${max_j:-?}C — restarted ${LLM_SERVICE} (AUTO_RESUME=true)"
        else log "cooled to junction=${max_j:-?}C but restart of ${LLM_SERVICE} FAILED — start it manually"; fi
      else
        log "cooled to junction=${max_j:-?}C — ${LLM_SERVICE} left stopped; restart it manually once the thermal cause is resolved"
      fi
    fi
  fi

  sleep "$POLL_SECS"
done
