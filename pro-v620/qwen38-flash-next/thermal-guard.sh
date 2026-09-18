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
CARDS="${CARDS:-0000:03:00.0 0000:83:00.0}"

mkdir -p "$(dirname "$LOG")"

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
    h="$(hwmon_for "$pci")" || continue
    # 🔴 `|| echo 0` made an unreadable sensor read as 0 °C — below every threshold, so the
    # guard sailed past a card it could not see. That is failing OPEN, and the comment above
    # promises the opposite. A missing sensor is now treated as over-temp: this guard exists
    # precisely because the systemd watchdog cannot protect a hand-driven benchmark, so if it
    # cannot see a card it must shed load rather than assume the card is cold.
    jr="$(cat "${h}/temp2_input" 2>/dev/null || true)"
    mr="$(cat "${h}/temp3_input" 2>/dev/null || true)"
    case "${jr}${mr}" in
      *[!0-9]*|"")
        echo "$(date -u +%FT%TZ) 🔴 ${pci}: junction/mem sensor unreadable (junction='${jr}' mem='${mr}') — treating as OVER-TEMP" | tee -a "$LOG"
        j=999; m=999 ;;
      *) j=$(( jr / 1000 )); m=$(( mr / 1000 )) ;;
    esac
    hot=$(( j > m ? j : m ))
    if [ "$hot" -ge "$LIMIT" ]; then
      echo "$(date -u +%FT%TZ) THERMAL GUARD: ${pci} junction=${j}C mem=${m}C >= ${LIMIT}C — killing [${PATTERNS}]" \
        | tee -a "$LOG"
      for p in $PATTERNS; do pkill -f "$p" || true; done
      # Also stop the managed unit inside CT 120, since a sweep drives it.
      pct exec 120 -- systemctl stop llamacpp-qwen38fn 2>/dev/null || true
    fi
  done
  sleep "$POLL"
done
