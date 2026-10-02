#!/usr/bin/env bash
# GPU blower control — drives BMC fan headers from amdgpu temps over in-band IPMI.
#
# The BMC has NO GPU temperature sensor, so its own fan tables can never respond to a
# passive V620. This closes that loop. The control law is the SAME as the B550-era
# pro-v620/fan-control: a linear ramp on EDGE temp, plus a hotspot override on the
# hottest of junction/mem with hysteresis. Only the transport differs — the B550 wrote
# nct6687 PWM sysfs; this writes BMC fan duty via ipmitool raw 0x3a 0xd6.
#
# A card passed through to a VM (vfio-pci) has no host hwmon. Its temps are then read
# inside the running VM that owns it, through the QEMU guest agent.
#
# Fail-safe is per card: a card whose temps cannot be read is being cooled blind, so ITS
# blower goes to FAIL_DUTY while the other keeps following its own sensor. An IPMI error
# forces both blowers to FAIL_DUTY.
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
: "${GUEST_TIMEOUT:=3}"        # seconds allowed for one guest-agent temp read

log(){ printf '%s %s\n' "$(date -Is)" "$*"; }
die(){ log "FATAL: $*"; exit 1; }
command -v ipmitool >/dev/null || die "ipmitool not installed"
[[ -c /dev/ipmi0 ]] || die "/dev/ipmi0 missing"

# Always returns 0: under `set -e` a failing $(hwmon_of ...) would kill the service.
hwmon_of(){ local h; for h in /sys/bus/pci/devices/"$1"/hwmon/hwmon*; do
  [[ -d $h && $(cat "$h/name" 2>/dev/null) == amdgpu ]] && { echo "$h"; return 0; }; done; return 0; }

# "<edge> <hotspot>" in °C from raw millidegree edge/junction/mem readings, or nothing if
# any is malformed. A missing mem reading falls back to junction.
to_c(){ local e=${1:-} j=${2:-} m=${3:-${2:-}}
  [[ $e =~ ^[0-9]+$ && $j =~ ^[0-9]+$ && $m =~ ^[0-9]+$ ]] || return 0
  e=$((e/1000)); j=$((j/1000)); m=$((m/1000))
  echo "$e $(( j > m ? j : m ))"; }

# echo "<edge> <hotspot>" from a host hwmon dir, or nothing on any failure
read_temps(){
  local h=$1 e j m
  [[ -n $h && -d $h ]] || return 0
  e=$(cat "$h/temp1_input" 2>/dev/null) || return 0   # edge
  j=$(cat "$h/temp2_input" 2>/dev/null) || return 0   # junction
  m=$(cat "$h/temp3_input" 2>/dev/null) || m=$j       # mem (fall back to junction)
  to_c "$e" "$j" "$m"
}

# Does VM config $1 pass PCI device $2 through? Only the main section counts: snapshot
# sections carry hostpci lines too. A hostpci entry naming a resource mapping is not
# resolved, so such a card reads as blind (FAIL_DUTY).
owns_pci(){ awk -v pci="${2#0000:}" '
  BEGIN { dev = pci; sub(/\.[0-7]$/, "", dev) }        # "83:00" passes every function
  /^\[/ { exit }
  $1 ~ /^hostpci[0-9]+:$/ {
    n = split($2, opt, ",")
    for (i = 1; i <= n; i++) {
      v = opt[i]; sub(/^host=/, "", v)
      if (v ~ /=/) continue                              # pcie=1, mapping=..., rombar=...
      k = split(v, ids, ";")
      for (x = 1; x <= k; x++) { d = ids[x]; sub(/^0000:/, "", d); if (d == pci || d == dev) found = 1 }
    }
  }
  END { exit !found }' "$1"; }

# VMID of the RUNNING VM that passes $1 through, or nothing.
passthrough_vm(){ local f vmid pid
  for f in /etc/pve/qemu-server/*.conf; do
    [[ -e $f ]] || continue
    owns_pci "$f" "$1" || continue
    vmid=$(basename "$f" .conf)
    pid=$(cat "/var/run/qemu-server/$vmid.pid" 2>/dev/null) || continue
    kill -0 "$pid" 2>/dev/null && { echo "$vmid"; return 0; }
  done; return 0; }

# Run inside the guest: raw "<edge> <junction> <mem>" of its ONE amdgpu card. The guest's
# PCI addresses differ from the host's, so more than one amdgpu card there is ambiguous and
# prints nothing.
# shellcheck disable=SC2016  # expands in the guest, not here
GUEST_READ='n=0
for h in /sys/class/hwmon/hwmon*; do
  [ "$(cat "$h/name" 2>/dev/null)" = amdgpu ] || continue
  n=$((n + 1))
  t="$(cat "$h/temp1_input") $(cat "$h/temp2_input") $(cat "$h/temp3_input" 2>/dev/null)"
done
[ "$n" -eq 1 ] && echo "$t"'

# echo "<edge> <hotspot>" read inside VM $1 through the guest agent, or nothing on any failure
guest_temps(){ local out e j m
  out=$(timeout -k 1 "$GUEST_TIMEOUT" qm guest exec "$1" --timeout "$GUEST_TIMEOUT" -- sh -c "$GUEST_READ" 2>/dev/null) \
    || return 0
  out=$(perl -MJSON::PP -e '
    my $r = eval { decode_json(do { local $/; <STDIN> }) } or exit 1;
    exit 1 unless $r->{exited} && !$r->{exitcode};
    print $r->{"out-data"} // ""' <<<"$out") || return 0
  read -r e j m <<<"$out" || true
  to_c "${e:-}" "${j:-}" "${m:-}"
}

# "<edge> <hotspot> <source>" for one card — its host hwmon, else the guest of the running VM
# it is passed through to — or nothing when it cannot be read.
card_temps(){ local r vmid
  r=$(read_temps "$(hwmon_of "$1")")
  [[ -n $r ]] && { echo "$r host"; return 0; }
  vmid=$(passthrough_vm "$1")
  [[ -n $vmid ]] || return 0
  r=$(guest_temps "$vmid")
  [[ -n $r ]] && echo "$r vm$vmid"
  return 0
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

# Log where a card's temps come from whenever that changes, rather than every poll.
note_source(){ local n=$1 pci=$2 fan=$3 old=$4 new=$5
  if [[ $new == blind ]]; then log "WARN gpu$n $pci unreadable (was: $old) — FAN$fan forced to ${FAIL_DUTY}%"
  else log "gpu$n $pci temps from: $new (was: $old)"; fi; }

trap 'log "exiting — forcing ${FAIL_DUTY}%"; set_duties "$FAIL_DUTY" "$FAIL_DUTY" || true' EXIT INT TERM
claim_fans
last1=-99; last2=-99; ov1=0; ov2=0; src1=start; src2=start
while :; do
  r1=$(card_temps "$GPU1_PCI") || r1=""
  r2=$(card_temps "$GPU2_PCI") || r2=""
  e1=- hs1=- s1=blind; e2=- hs2=- s2=blind
  [[ -n $r1 ]] && read -r e1 hs1 s1 <<<"$r1"
  [[ -n $r2 ]] && read -r e2 hs2 s2 <<<"$r2"
  [[ $s1 != "$src1" ]] && { note_source 1 "$GPU1_PCI" "$GPU1_FAN" "$src1" "$s1"; src1=$s1; }
  [[ $s2 != "$src2" ]] && { note_source 2 "$GPU2_PCI" "$GPU2_FAN" "$src2" "$s2"; src2=$s2; }
  # A blind card keeps its override state, so a hot card that drops out and comes back
  # between RESUME and OVERRIDE stays at 100%.
  if [[ $s1 == blind ]]; then d1=$FAIL_DUTY; else
    (( hs1 >= HOTSPOT_OVERRIDE_C )) && ov1=1; (( hs1 <= HOTSPOT_RESUME_C )) && ov1=0
    (( ov1 )) && d1=100 || d1=$(pct_for_edge "$e1"); fi
  if [[ $s2 == blind ]]; then d2=$FAIL_DUTY; else
    (( hs2 >= HOTSPOT_OVERRIDE_C )) && ov2=1; (( hs2 <= HOTSPOT_RESUME_C )) && ov2=0
    (( ov2 )) && d2=100 || d2=$(pct_for_edge "$e2"); fi
  a=$(( d1 - last1 )); (( a<0 )) && a=$(( -a ))
  b=$(( d2 - last2 )); (( b<0 )) && b=$(( -b ))
  if (( a >= DUTY_STEP || b >= DUTY_STEP || d1 == 100 || d2 == 100 )); then
    if set_duties "$d1" "$d2"; then
      (( d1 != last1 || d2 != last2 )) && \
        log "gpu1[$s1] edge=${e1}C hot=${hs1}C ov=${ov1} -> ${d1}%  |  gpu2[$s2] edge=${e2}C hot=${hs2}C ov=${ov2} -> ${d2}%"
      last1=$d1; last2=$d2
    else
      log "WARN ipmi write failed — forcing ${FAIL_DUTY}%"
      set_duties "$FAIL_DUTY" "$FAIL_DUTY" || true; last1=-99; last2=-99
    fi
  fi
  sleep "$INTERVAL"
done
