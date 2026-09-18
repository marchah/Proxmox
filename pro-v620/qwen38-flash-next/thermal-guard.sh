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
      for p in $PATTERNS; do pkill -f "$p" || true; done
      # Also stop the managed unit inside CT 120, since a sweep drives it.
      pct exec 120 -- systemctl stop llamacpp-qwen38fn 2>/dev/null || true
    fi
  done
  sleep "$POLL"
done
