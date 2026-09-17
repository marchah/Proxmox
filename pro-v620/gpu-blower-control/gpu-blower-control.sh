#!/usr/bin/env bash
# GPU blower control — drives BMC fan headers from amdgpu temps over in-band IPMI.
#
# The BMC has NO GPU temperature sensor, so its own fan tables can never respond to a
# passive V620. This closes that loop. The control law is the SAME as the B550-era
# pro-v620/fan-control: a linear ramp on EDGE temp, plus a hotspot override on the
# hottest of junction/mem with hysteresis. Only the transport differs — the B550 wrote
# nct6687 PWM sysfs; this writes BMC fan duty via ipmitool raw 0x3a 0xd6.
#
# Fail-safe: any missing sensor, unreadable temp or IPMI error forces 100%.
set -Eeuo pipefail

CONF=${CONF:-/etc/gpu-blower-control.env}
# shellcheck source=/dev/null  # runtime config, path is site-specific
[[ -r $CONF ]] && . "$CONF"

: "${GPU1_PCI:=0000:03:00.0}"; : "${GPU1_FAN:=4}"
: "${GPU2_PCI:=0000:83:00.0}"; : "${GPU2_FAN:=5}"
: "${EDGE_MIN_C:=35}"          # at/below -> PWM_MIN_PCT
: "${EDGE_MAX_C:=88}"          # at/above -> 100%
: "${PWM_MIN_PCT:=20}"         # BMC enforces Fan_PWM_Min=20, so 12 (the nct6687 floor) is not reachable
: "${HOTSPOT_OVERRIDE_C:=90}"  # hottest of junction/mem at/above this -> 100%
: "${HOTSPOT_RESUME_C:=87}"    # ...until it falls to/below this
: "${OTHER_DUTY:=0x14}"        # slots this service does not own (inert while they are Customized)
: "${FAIL_DUTY:=100}"
: "${INTERVAL:=4}"
: "${DUTY_STEP:=3}"            # min duty delta before re-writing

log(){ printf '%s %s\n' "$(date -Is)" "$*"; }
die(){ log "FATAL: $*"; exit 1; }
command -v ipmitool >/dev/null || die "ipmitool not installed"
[[ -c /dev/ipmi0 ]] || die "/dev/ipmi0 missing"

hwmon_of(){ local h; for h in /sys/bus/pci/devices/"$1"/hwmon/hwmon*; do
  [[ -d $h && $(cat "$h/name" 2>/dev/null) == amdgpu ]] && { echo "$h"; return; }; done; }

# echo "<edge> <hotspot>" or nothing on any failure
read_temps(){
  local h=$1 e j m
  [[ -n $h && -d $h ]] || return 0
  e=$(cat "$h/temp1_input" 2>/dev/null) || return 0   # edge
  j=$(cat "$h/temp2_input" 2>/dev/null) || return 0   # junction
  m=$(cat "$h/temp3_input" 2>/dev/null) || m=$j       # mem (fall back to junction)
  [[ $e =~ ^[0-9]+$ && $j =~ ^[0-9]+$ && $m =~ ^[0-9]+$ ]] || return 0
  e=$((e/1000)); j=$((j/1000)); m=$((m/1000))
  echo "$e $(( j > m ? j : m ))"
}

pct_for_edge(){ local t=$1
  (( t <= EDGE_MIN_C )) && { echo "$PWM_MIN_PCT"; return; }
  (( t >= EDGE_MAX_C )) && { echo 100; return; }
  echo $(( PWM_MIN_PCT + (t - EDGE_MIN_C) * (100 - PWM_MIN_PCT) / (EDGE_MAX_C - EDGE_MIN_C) ))
}

set_duties(){ local d1=$1 d2=$2 i args=()
  for (( i=1; i<=16; i++ )); do
    if   (( i == GPU1_FAN )); then args+=("$(printf '0x%02x' "$d1")")
    elif (( i == GPU2_FAN )); then args+=("$(printf '0x%02x' "$d2")")
    else args+=("$OTHER_DUTY"); fi
  done
  ipmitool raw 0x3a 0xd6 "${args[@]}" >/dev/null 2>&1; }

claim_fans(){ local modes i args=()
  modes=$(ipmitool raw 0x3a 0xd9 2>/dev/null) || die "cannot read fan modes"
  read -r -a modes <<<"$modes"; (( ${#modes[@]} == 16 )) || die "bad mode table width ${#modes[@]}"
  for (( i=1; i<=16; i++ )); do
    if (( i == GPU1_FAN || i == GPU2_FAN )); then args+=(0x01); else args+=("0x${modes[i-1]}"); fi
  done
  ipmitool raw 0x3a 0xd8 "${args[@]}" >/dev/null 2>&1 || die "cannot set fan modes"
  log "claimed FAN$GPU1_FAN/FAN$GPU2_FAN in Manual; ramp edge ${EDGE_MIN_C}-${EDGE_MAX_C}C ${PWM_MIN_PCT}-100%, hotspot override ${HOTSPOT_OVERRIDE_C}/${HOTSPOT_RESUME_C}C"; }

trap 'log "exiting — forcing ${FAIL_DUTY}%"; set_duties "$FAIL_DUTY" "$FAIL_DUTY" || true' EXIT INT TERM
claim_fans
last1=-99; last2=-99; ov1=0; ov2=0
while :; do
  h1=$(hwmon_of "$GPU1_PCI"); h2=$(hwmon_of "$GPU2_PCI")
  r1=$(read_temps "$h1");     r2=$(read_temps "$h2")
  if [[ -z $r1 || -z $r2 ]]; then
    log "WARN sensors missing (gpu1='${r1:-?}' gpu2='${r2:-?}') — forcing ${FAIL_DUTY}%"
    set_duties "$FAIL_DUTY" "$FAIL_DUTY" || log "WARN ipmi write failed"
    last1=-99; last2=-99; sleep "$INTERVAL"; continue
  fi
  read -r e1 hs1 <<<"$r1"; read -r e2 hs2 <<<"$r2"
  (( hs1 >= HOTSPOT_OVERRIDE_C )) && ov1=1; (( hs1 <= HOTSPOT_RESUME_C )) && ov1=0
  (( hs2 >= HOTSPOT_OVERRIDE_C )) && ov2=1; (( hs2 <= HOTSPOT_RESUME_C )) && ov2=0
  (( ov1 )) && d1=100 || d1=$(pct_for_edge "$e1")
  (( ov2 )) && d2=100 || d2=$(pct_for_edge "$e2")
  a=$(( d1 - last1 )); (( a<0 )) && a=$(( -a ))
  b=$(( d2 - last2 )); (( b<0 )) && b=$(( -b ))
  if (( a >= DUTY_STEP || b >= DUTY_STEP || d1 == 100 || d2 == 100 )); then
    if set_duties "$d1" "$d2"; then
      (( d1 != last1 || d2 != last2 )) && \
        log "gpu1 edge=${e1}C hot=${hs1}C ov=${ov1} -> ${d1}%  |  gpu2 edge=${e2}C hot=${hs2}C ov=${ov2} -> ${d2}%"
      last1=$d1; last2=$d2
    else
      log "WARN ipmi write failed — forcing ${FAIL_DUTY}%"
      set_duties "$FAIL_DUTY" "$FAIL_DUTY" || true; last1=-99; last2=-99
    fi
  fi
  sleep "$INTERVAL"
done
