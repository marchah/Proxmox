#!/usr/bin/env bash
# Safety net for THIS benchmark only. The production gpu-thermal-watchdog stops the
# CT's model *service*; llama-bench is not that service, so the watchdog cannot stop
# it. Kill llama-bench directly if either card's junction crosses the limit.
set -Eeuo pipefail
LIMIT="${LIMIT:-100}"
while :; do
  for pci in 0000:2d:00.0 0000:06:00.0; do
    for h in "/sys/bus/pci/devices/$pci/hwmon/"hwmon*; do
      j=$(( $(cat "$h/temp2_input") / 1000 ))
      if [ "$j" -ge "$LIMIT" ]; then
        echo "$(date -u +%FT%TZ) THERMAL GUARD: $pci junction ${j}C >= ${LIMIT}C — killing llama-bench" \
          | tee -a "${BENCH_DIR:-/root/gpu-ab-bench}/guard.log"
        pkill -f llama-bench || true
      fi
    done
  done
  sleep 2
done
