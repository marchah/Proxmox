#!/usr/bin/env bash
# Samples what cell() does not record, into the overnight RUN dir. Host-side, additive:
# it is started ALONGSIDE a running sweep rather than edited into it, because bash reads a
# script incrementally and rewriting one mid-run can corrupt its execution.
#
# 🔴 The reason this exists: GTT. Below roughly 1 GiB of VRAM headroom RADV starts spilling
# to host memory, which is a ~12x decode collapse that the startup loud-guard does NOT
# catch — so a spilled cell looks like a legitimately slow placement. VRAM alone cannot
# show it; you have to read mem_info_gtt_used next to it.
set -uo pipefail
OUT="${1:?usage: placement-sampler.sh <run-dir>}"
INTERVAL="${INTERVAL:-15}"
F="${OUT}/placement-telemetry.jsonl"

while :; do
  ts=$(date -u +%FT%TZ)
  line="{\"ts\":\"${ts}\""
  for pci in 0000:03:00.0 0000:83:00.0; do
    d=/sys/bus/pci/devices/$pci
    v=$(( $(cat "$d/mem_info_vram_used" 2>/dev/null || echo 0) / 1048576 ))
    t=$(( $(cat "$d/mem_info_vram_total" 2>/dev/null || echo 1) / 1048576 ))
    g=$(( $(cat "$d/mem_info_gtt_used"  2>/dev/null || echo 0) / 1048576 ))
    b=$(cat "$d/gpu_busy_percent" 2>/dev/null || echo -1)
    key="${pci%%:*}"; key="gpu${pci:5:2}"
    j=0; m=0; w=0
    for h in "$d/hwmon/"hwmon*; do
      [ -d "$h" ] || continue
      j=$(( $(cat "$h/temp2_input" 2>/dev/null || echo 0) / 1000 ))
      m=$(( $(cat "$h/temp3_input" 2>/dev/null || echo 0) / 1000 ))
      w=$(( $(cat "$h/power1_average" 2>/dev/null || echo 0) / 1000000 ))
    done
    line="${line},\"${key}_vram\":${v},\"${key}_vram_free\":$(( t - v ))"
    line="${line},\"${key}_gtt\":${g},\"${key}_busy\":${b}"
    line="${line},\"${key}_junction\":${j},\"${key}_mem_temp\":${m},\"${key}_watts\":${w}"
  done
  # p90 of the per-core clocks: the MEAN is useless when half the cores are idle.
  clk=$(awk '{print int($1/1000)}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null \
        | sort -n | awk '{v[NR]=$1} END{print (NR?v[int(NR*0.9)]:0)}')
  line="${line},\"busy_clk_mhz\":${clk:-0}"
  # CPU package watts from RAPL. The driver is named intel-rapl but works on Zen.
  e1=$(cat /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null || echo 0)
  line="${line},\"rapl_uj\":${e1}"
  # shellcheck disable=SC2034  # _mt is the unused total field
  read -r _mt mu ma < <(free -m | awk '/^Mem:/{print $2, $3, $7}')
  line="${line},\"host_mem_used_mib\":${mu},\"host_mem_avail_mib\":${ma}"
  # DIMM channels: the BMC is the only source, and an unpopulated channel reads No Reading.
  dimm=$(ipmitool sdr type Temperature 2>/dev/null | awk -F'|' '/DDR4/ {
      gsub(/[^0-9]/,"",$5); if ($5 != "") { gsub(/^ +| +$/,"",$1); printf "\"%s\":%d,", $1, $5 } }' | sed 's/,$//')
  [ -n "$dimm" ] && line="${line},\"dimm\":{${dimm}}"
  cpu=$(ipmitool sdr type Temperature 2>/dev/null | awk -F'|' '/CPU Temp/{gsub(/[^0-9]/,"",$5); print $5+0; exit}')
  line="${line},\"cpu_temp\":${cpu:-0}}"
  printf '%s\n' "$line" >>"$F"
  sleep "$INTERVAL"
done
