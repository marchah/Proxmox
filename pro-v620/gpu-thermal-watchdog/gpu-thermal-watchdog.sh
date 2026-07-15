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
# Each listed address is required: a missing/late/typo'd one is watched-when-it-appears
# (the set is re-resolved every poll) and loudly warned about, never silently dropped.
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
# Per-GPU protection map: which LXC service OWNS each card, so a trip stops the RIGHT
# workload — not a single hard-coded one. Both V620s now run a workload (GPU 1 = the
# ops model in CT 120; GPU 2 = the coding loop's llama-swap in CT 123), so stopping
# CT 120 when GPU 2 is the hot card would shed the wrong load and leave GPU 2 heating
# toward the hardware reset. Format: "PCI=VMID:service", comma-separated. An over-temp
# card that is NOT in the map falls back to stopping EVERY mapped service (conservative
# — better to over-shed than let a hot card run unshed). If this is empty but the legacy
# LLM_CT_VMID/LLM_SERVICE are set, every watched card maps to that one service (the old
# single-service behavior). PROTECT_CMD/RESUME_CMD still override everything.
GPU_SERVICE_MAP="${GPU_SERVICE_MAP:-0000:2d:00.0=120:llamacpp,0000:06:00.0=123:llama-swap}"
# Leave the server DOWN after a trip (default) or auto-restart it once cooled.
# Default false: reaching the trip temp means cooling could not keep up, so resuming
# into the same load risks a loop — require a human to confirm it is safe.
AUTO_RESUME="${AUTO_RESUME:-false}"

# ---------------------------------------------------------------------------
log() { printf 'gpu-thermal-watchdog: %s\n' "$*"; }

# A non-numeric threshold would make every (( )) comparison treat it as 0 and trip
# instantly (stopping the model in a loop) — validate up front, clamp to a default.
validate_int() {  # $1=name $2=value $3=default ; echoes ONLY the sanitized int
  if [[ "$2" =~ ^[0-9]+$ ]] && (( 10#$2 >= 1 )); then echo $(( 10#$2 )); return; fi
  # WARN to STDERR, not stdout: callers capture stdout via $(...), so a warning printed
  # to stdout would be appended to the returned value and corrupt the threshold (the very
  # thing this function guards against). stderr still reaches the journal.
  log "WARN: $1='$2' invalid (need integer >=1); using $3" >&2
  echo "$3"
}

# Find the amdgpu hwmon dir for one PCI address. Matching by address is boot-stable
# (the hwmon's `device` symlink basename is the PCI address); cardN is not. Echoes
# the path; returns 1 if that card is not currently present.
find_hwmon_for_addr() {  # $1 = pci address
  local addr="$1" h pci
  for h in /sys/class/drm/card*/device/hwmon/hwmon* /sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    [ "$(cat "$h/name" 2>/dev/null)" = "$GPU_HWMON_NAME" ] || continue
    pci="$(basename "$(readlink -f "$h/device" 2>/dev/null)" 2>/dev/null)"
    [ "$pci" = "$addr" ] || continue
    echo "$h"; return 0
  done
  return 1
}

# Auto mode (no addresses configured): echo every amdgpu hwmon found, one per line.
find_all_hwmons() {
  local h
  for h in /sys/class/drm/card*/device/hwmon/hwmon* /sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    [ "$(cat "$h/name" 2>/dev/null)" = "$GPU_HWMON_NAME" ] && echo "$h"
  done
}

# Rebuild GPU_CHIPS (present hwmon paths) and MISSING_ADDRS from the EXPECTED set.
# Explicit list: resolve EACH expected address, recording which are absent so a
# missing/late/typo'd card is known (not silently dropped). Auto mode: every amdgpu
# found is present, nothing is "missing". Called at startup AND unconditionally every
# poll, so an empty result can never wedge the daemon and a returning card is picked
# up. Assigns the two globals; no return value.
refresh_present() {
  GPU_CHIPS=(); MISSING_ADDRS=()
  local addr path
  if (( ${#EXPECTED_ADDRS[@]} == 0 )); then
    mapfile -t GPU_CHIPS < <(find_all_hwmons)
    return 0
  fi
  for addr in "${EXPECTED_ADDRS[@]}"; do
    if path="$(find_hwmon_for_addr "$addr")"; then GPU_CHIPS+=("$path")
    else MISSING_ADDRS+=("$addr"); fi
  done
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

# PCI address that owns a hwmon dir (its `device` symlink basename). Empty if unresolvable.
addr_of_hwmon() { basename "$(readlink -f "$1/device" 2>/dev/null)" 2>/dev/null; }

# Stop the workload OWNING the over-temp card ($1 = its PCI addr). An unmapped card
# stops EVERY mapped service (conservative). PROTECT_CMD overrides (gets PROTECT_ADDR).
do_protect() {  # $1 = PCI addr of the over-temp card
  local addr="${1:-}" a rc=0
  if [ -n "$PROTECT_CMD" ]; then PROTECT_ADDR="$addr" bash -c "$PROTECT_CMD"; return $?; fi
  if [ -n "${SVC_VMID[$addr]:-}" ]; then
    pct exec "${SVC_VMID[$addr]}" -- systemctl stop "${SVC_NAME[$addr]}"; return $?
  fi
  log "WARN: over-temp card '${addr}' not in GPU_SERVICE_MAP — stopping ALL mapped services"
  for a in "${!SVC_VMID[@]}"; do pct exec "${SVC_VMID[$a]}" -- systemctl stop "${SVC_NAME[$a]}" || rc=1; done
  return "$rc"
}
do_resume() {  # $1 = PCI addr of the cooled card
  local addr="${1:-}" a rc=0
  if [ -n "$RESUME_CMD" ]; then RESUME_ADDR="$addr" bash -c "$RESUME_CMD"; return $?; fi
  if [ -n "${SVC_VMID[$addr]:-}" ]; then
    pct exec "${SVC_VMID[$addr]}" -- systemctl start "${SVC_NAME[$addr]}"; return $?
  fi
  for a in "${!SVC_VMID[@]}"; do pct exec "${SVC_VMID[$a]}" -- systemctl start "${SVC_NAME[$a]}" || rc=1; done
  return "$rc"
}

TRIP_JUNCTION_C="$(validate_int TRIP_JUNCTION_C "$TRIP_JUNCTION_C" 102)"
TRIP_MEM_C="$(validate_int TRIP_MEM_C "$TRIP_MEM_C" 101)"
RESUME_C="$(validate_int RESUME_C "$RESUME_C" 95)"
POLL_SECS="$(validate_int POLL_SECS "$POLL_SECS" 2)"
(( RESUME_C < TRIP_JUNCTION_C )) || log "WARN: RESUME_C ($RESUME_C) >= TRIP_JUNCTION_C ($TRIP_JUNCTION_C) — hysteresis disabled; re-arm may not work"

trap 'exit 0' INT TERM

# ---- startup ---------------------------------------------------------------
# Parse the EXPECTED address set once (comma list, whitespace-stripped). Empty =
# auto mode (watch every amdgpu found). EXPECTED_COUNT is what we must keep watching.
declare -a EXPECTED_ADDRS=() GPU_CHIPS=() MISSING_ADDRS=() _raw=()
IFS=',' read -ra _raw <<< "$GPU_PCI_ADDRESS"
for _a in ${_raw[@]+"${_raw[@]}"}; do _a="${_a// /}"; [ -n "$_a" ] && EXPECTED_ADDRS+=("$_a"); done

# Per-GPU stop map (assoc: PCI addr -> VMID / service). Parse GPU_SERVICE_MAP; if empty,
# fall back to the legacy single service (LLM_CT_VMID/LLM_SERVICE) for every watched card.
declare -A SVC_VMID=() SVC_NAME=()
declare -a _pairs=()
IFS=',' read -ra _pairs <<< "$GPU_SERVICE_MAP"
for _p in ${_pairs[@]+"${_pairs[@]}"}; do
  _p="${_p// /}"; [ -n "$_p" ] || continue
  _addr="${_p%%=*}"; _rest="${_p#*=}"
  if [ -z "$_addr" ] || [ "$_rest" = "$_p" ] || [[ "$_rest" != *:* ]]; then
    log "WARN: ignoring malformed GPU_SERVICE_MAP entry '$_p' (want PCI=VMID:service)"; continue
  fi
  SVC_VMID["$_addr"]="${_rest%%:*}"; SVC_NAME["$_addr"]="${_rest#*:}"
done
if (( ${#SVC_VMID[@]} == 0 )) && [ -n "$LLM_CT_VMID" ] && [ -n "$LLM_SERVICE" ]; then
  for _a in ${EXPECTED_ADDRS[@]+"${EXPECTED_ADDRS[@]}"}; do
    SVC_VMID["$_a"]="$LLM_CT_VMID"; SVC_NAME["$_a"]="$LLM_SERVICE"
  done
  log "GPU_SERVICE_MAP empty — legacy: mapping all watched cards to ${LLM_SERVICE} in CT ${LLM_CT_VMID}"
fi

refresh_present
if (( ${#EXPECTED_ADDRS[@]} > 0 )); then EXPECTED_COUNT=${#EXPECTED_ADDRS[@]}
else EXPECTED_COUNT=${#GPU_CHIPS[@]}; fi

# A totally absent GPU stack (0 present) is a hard problem (amdgpu not bound) — fail
# loud; systemd Restart=always retries. A PARTIAL set does NOT die (that would remove
# the only graceful protection): watch what is present, warn about the rest, and the
# per-poll re-resolve below picks up a card the moment it appears.
(( ${#GPU_CHIPS[@]} >= 1 )) || { log "FATAL: no '$GPU_HWMON_NAME' hwmon found${GPU_PCI_ADDRESS:+ for $GPU_PCI_ADDRESS} (is amdgpu bound to the V620(s)?)"; exit 1; }

# junction is the primary metric and MUST be present on a watched card (its absence
# means the wrong label/card — fail loud). mem is secondary: warn (junction tracks it
# closely, so junction alone still protects the card); it is probed inline each poll.
for gc in "${GPU_CHIPS[@]}"; do
  read_temp_c "$gc" junction >/dev/null 2>&1 \
    || { log "FATAL: junction sensor not present on $gc — cannot watch it"; exit 1; }
  read_temp_c "$gc" mem >/dev/null 2>&1 \
    || log "WARN: mem sensor absent on $gc — watching junction only there"
done

if (( ${#MISSING_ADDRS[@]} > 0 )); then
  log "WARN: only ${#GPU_CHIPS[@]}/${EXPECTED_COUNT} configured GPU(s) present — MISSING ${MISSING_ADDRS[*]}; watching the rest and retrying each poll"
fi

_mapdesc=""; for _a in "${!SVC_VMID[@]}"; do _mapdesc+="${_mapdesc:+, }${_a}->CT${SVC_VMID[$_a]}:${SVC_NAME[$_a]}"; done
log "started: watching ${#GPU_CHIPS[@]}/${EXPECTED_COUNT} GPU(s) [${GPU_CHIPS[*]}]; trip junction>=${TRIP_JUNCTION_C}C mem>=${TRIP_MEM_C}C, resume<${RESUME_C}C; action=${WATCHDOG_ACTION}; per-GPU stop map: ${_mapdesc:-<none>}; auto_resume=${AUTO_RESUME}; poll=${POLL_SECS}s"

tripped=0
loops=0
miss_logged=0
declare -a STOPPED_ADDRS=()
while :; do
  loops=$(( loops + 1 ))
  # Re-resolve the EXPECTED set every poll (cheap): an empty list can then never wedge
  # the daemon (a transient vanish always recovers) and a late/returning card is picked
  # up. Warn on any change, and periodically while still short of the expected count.
  prev_present=${#GPU_CHIPS[@]}
  refresh_present
  cur=${#GPU_CHIPS[@]}
  miss=""; (( ${#MISSING_ADDRS[@]} )) && miss=" — MISSING ${MISSING_ADDRS[*]}"
  if (( cur != prev_present )); then
    if (( cur < EXPECTED_COUNT )); then log "WARN: ${cur}/${EXPECTED_COUNT} configured GPU(s) present${miss}; watching the rest, retrying each poll"
    else log "all ${EXPECTED_COUNT} configured GPU(s) present again [${GPU_CHIPS[*]}]"; fi
  elif (( cur < EXPECTED_COUNT )) && (( loops % 30 == 1 )); then
    log "WARN: still ${cur}/${EXPECTED_COUNT} configured GPU(s) present${miss}"
  fi

  max_j=""; max_m=""; hot_gc=""; read_ok=0; read_miss=0; over_addrs=()
  for gc in "${GPU_CHIPS[@]}"; do
    j="$(read_temp_c "$gc" junction)" || { read_miss=1; continue; }
    read_ok=1
    if [ -z "$max_j" ] || (( j > max_j )); then max_j="$j"; hot_gc="$gc"; fi
    # Probe mem inline (no cached map) so coverage follows a card across hwmon-path
    # changes on rebind; absent mem is fine — junction alone still protects the card.
    m=""
    if mm="$(read_temp_c "$gc" mem)"; then
      m="$mm"
      if [ -z "$max_m" ] || (( mm > max_m )); then max_m="$mm"; fi
    fi
    # Per-card over check → record THIS card's PCI addr, so the trip stops the service
    # that OWNS it (and stops both cards if both are over), not just the hottest.
    _co=0
    (( j >= TRIP_JUNCTION_C )) && _co=1
    { [ -n "$m" ] && (( m >= TRIP_MEM_C )); } && _co=1
    if (( _co )); then _ca="$(addr_of_hwmon "$gc")"; [ -n "$_ca" ] && over_addrs+=("$_ca"); fi
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
      log "CRITICAL: GPU over thermal trip (junction=${max_j:-?}C mem=${max_m:-?}C, hottest ${hot_gc}; limits ${TRIP_JUNCTION_C}/${TRIP_MEM_C}C) — protecting owning workload(s) for: ${over_addrs[*]-<none resolved>}"
    fi
    if [ "$WATCHDOG_ACTION" = stop ]; then
      # Stop the service that OWNS each over-temp card (both, if both are hot) — not a
      # hard-coded one. Idempotent: re-issued while hot in case an earlier stop failed.
      for _addr in ${over_addrs[@]+"${over_addrs[@]}"}; do
        if do_protect "$_addr"; then
          case " ${STOPPED_ADDRS[*]-} " in *" ${_addr} "*) : ;; *) STOPPED_ADDRS+=("$_addr") ;; esac
          (( loops % 15 == 1 )) && log "stop issued for ${_addr}: ${SVC_NAME[$_addr]:-<all mapped>} in CT ${SVC_VMID[$_addr]:-?} (junction=${max_j:-?}C)"
        else
          log "ERROR: protect action for ${_addr} failed (junction=${max_j:-?}C) — retrying; hardware resets at emergency temp if uncooled"
        fi
      done
    else
      (( loops % 15 == 1 )) && log "WARN (action=warn): would stop owning workload(s) for [${over_addrs[*]-}] now (junction=${max_j:-?}C) — no action taken"
    fi
  elif (( tripped == 1 )); then
    rearm=1
    { [ -n "$max_j" ] && (( max_j >= RESUME_C )); } && rearm=0
    { [ -n "$max_m" ] && (( max_m >= RESUME_C )); } && rearm=0
    if (( rearm )); then
      tripped=0
      if [ "$AUTO_RESUME" = true ] && [ "$WATCHDOG_ACTION" = stop ]; then
        for _addr in ${STOPPED_ADDRS[@]+"${STOPPED_ADDRS[@]}"}; do
          if do_resume "$_addr"; then log "cooled to junction=${max_j:-?}C — restarted ${SVC_NAME[$_addr]:-<all>} in CT ${SVC_VMID[$_addr]:-?} (AUTO_RESUME=true)"
          else log "cooled but restart for ${_addr} FAILED — start it manually"; fi
        done
      else
        log "cooled to junction=${max_j:-?}C — stopped workload(s) [${STOPPED_ADDRS[*]-}] left down; restart manually once the thermal cause is resolved"
      fi
      STOPPED_ADDRS=()
    fi
  fi

  sleep "$POLL_SECS"
done
