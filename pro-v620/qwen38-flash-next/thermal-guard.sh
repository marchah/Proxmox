#!/usr/bin/env bash
# Safety net for a HAND-DRIVEN benchmark on the EPYC platform. Runs on the host.
#
# The production gpu-thermal-watchdog stops the container's model *service*; a
# llama-server or llama-bench started by hand is not that service, so the watchdog
# cannot stop it and the 105C hardware MODE1 reset becomes the only backstop.
#
# ⚠️ gpu-ab-bench/thermal-guard.sh is the B550-era original and still names
# 0000:2d:00.0 / 0000:06:00.0. Those paths do not exist on this board, so its hwmon glob
# never matches, `cat` fails, and `set -e` kills the guard within a second of starting —
# i.e. it fails SILENTLY OPEN. Use this one for anything on the EPYC box.
set -Eeuo pipefail

LIMIT="${LIMIT:-100}"
POLL="${POLL:-2}"
LOG="${LOG:-/root/qwen38-flash-next/guard.log}"
# What to kill. Defaults cover a hand-started server and llama-bench, not the managed
# unit (leave that to the production watchdog).
PATTERNS="${PATTERNS:-llama-bench llama-server}"
# VMID=<ct> guards only that container's cards and acts only inside it, so a sweep on
# CT 123 cannot take down CT 120's production server. Unset, it watches both cards and
# acts in whichever running container owns the hot card.
VMID="${VMID:-}"
if [ -n "$VMID" ]; then
  CARDS="$(pct config "$VMID" | grep -oE 'pci-0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | sed 's/^pci-//' | sort -u | paste -sd' ' -)"
  [ -n "$CARDS" ] || { echo "FATAL: CT ${VMID} has no passed-through card" >&2; exit 1; }
fi
CARDS="${CARDS:-0000:03:00.0 0000:83:00.0}"
# placement-sweep.sh refuses to start a cell while this file exists, and does not restart
# the server on exit. Remove it once cooling is checked.
TRIP_FILE="${TRIP_FILE:-/root/qwen38-flash-next/THERMAL_TRIP}"

mkdir -p "$(dirname "$LOG")"

# The running container whose config binds this card, if any.
owner_of() {
  local ct
  for ct in $(pct list | awk 'NR > 1 && $2 == "running" {print $1}'); do
    if pct config "$ct" | grep -q "pci-${1}-render"; then printf '%s' "$ct"; return 0; fi
  done
  return 1
}

hwmon_for() {
  local pci="$1" h
  for h in "/sys/bus/pci/devices/${pci}/hwmon/"hwmon*; do
    [ -d "$h" ] && { printf '%s' "$h"; return 0; }
  done
  return 1
}

# Fail CLOSED on a missing sensor: if the guard cannot read a card it must say so and
# exit, not poll forever believing everything is cool.
for pci in $CARDS; do
  hwmon_for "$pci" >/dev/null || { echo "FATAL: no hwmon for ${pci} — refusing to run blind" >&2; exit 1; }
done
echo "$(date -u +%FT%TZ) guard armed: cards=[${CARDS}] limit=${LIMIT}C patterns=[${PATTERNS}]" | tee -a "$LOG"

while :; do
  for pci in $CARDS; do
    # This guard exists because the systemd watchdog cannot protect a hand-driven benchmark,
    # so anything it cannot SEE must shed load rather than be assumed cold.
    # ⚠️ Validate each reading SEPARATELY. Testing `${jr}${mr}` lets one empty reading beside
    # one numeric reading concatenate to a numeric string and pass, after which the empty one
    # becomes 0 °C and never trips. A missing hwmon directory routes the same way — the
    # startup check only proves it existed at startup.
    unreadable=""
    if ! h="$(hwmon_for "$pci")"; then
      unreadable="hwmon directory gone"
    else
      jr="$(cat "${h}/temp2_input" 2>/dev/null || true)"
      mr="$(cat "${h}/temp3_input" 2>/dev/null || true)"
      case "$jr" in ""|*[!0-9]*) unreadable="junction='${jr}'" ;; esac
      case "$mr" in ""|*[!0-9]*) unreadable="${unreadable:+${unreadable} }mem='${mr}'" ;; esac
    fi
    if [ -n "$unreadable" ]; then
      echo "$(date -u +%FT%TZ) 🔴 ${pci}: UNREADABLE (${unreadable}) — treating as OVER-TEMP" | tee -a "$LOG"
      j=999; m=999
    else
      j=$(( jr / 1000 )); m=$(( mr / 1000 ))
    fi
    hot=$(( j > m ? j : m ))
    if [ "$hot" -ge "$LIMIT" ]; then
      echo "$(date -u +%FT%TZ) THERMAL GUARD: ${pci} junction=${j}C mem=${m}C >= ${LIMIT}C — killing [${PATTERNS}]" \
        | tee -a "$LOG"
      echo "$(date -u +%FT%TZ) ${pci} junction=${j}C mem=${m}C" >>"$TRIP_FILE"
      ct="${VMID:-$(owner_of "$pci" || true)}"
      if [ -n "$ct" ]; then
        for p in $PATTERNS; do pct exec "$ct" -- pkill -f "$p" || true; done
        # A sweep drives this unit; stopping it ends the cell.
        pct exec "$ct" -- systemctl stop llamacpp-qwen38fn 2>/dev/null || true
      else
        # No container owns the card: the load was started on the host.
        for p in $PATTERNS; do pkill -f "$p" || true; done
      fi
    fi
  done
  sleep "$POLL"
done
