#!/usr/bin/env bash
# Sustained STREAM: rerun membench.sh's STREAM binary back to back for DURATION seconds and log
# every pass beside the DIMM temperatures. membench.sh reports a best-of-20 from a run lasting
# seconds, so it cannot show whether bandwidth holds once the DIMMs are heat-soaked. On this board
# a DIMM reading 66 °C caps bandwidth to a third without appearing in any log (README.md).
#
# Runs on the Proxmox HOST as root, after membench.sh has built ./stream. Guests may stay up:
# each pass records the CPU time every guest used, so contended passes can be excluded.
set -Eeuo pipefail

BENCH_DIR="${BENCH_DIR:-/root/membench}"
OUT="${OUT:-${BENCH_DIR}/sustained-$(date +%F-%H%M)}"
DURATION="${DURATION:-3600}"
# 16 threads gave the best Copy on both four and eight channels; Triad differs by under 1 %.
THREADS="${THREADS:-16}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-60}"
# Stop early if any DIMM reaches this. The 4-hour stressapptest soak peaked at 66 °C.
DIMM_LIMIT_C="${DIMM_LIMIT_C:-82}"
CONTAINERS="${CONTAINERS:-120 121 123 140}"
VMS="${VMS:-300}"

PASSES="${OUT}/passes.tsv"
SENSORS="${OUT}/sensors.tsv"
SUMMARY="${OUT}/summary.txt"
EDAC=/sys/devices/system/edac/mc/mc0
SAMPLER_PID=""

die() { echo "ERROR: $*" >&2; exit 1; }

guest_cgroups() {
  local id
  for id in ${CONTAINERS}; do echo "ct${id}:/sys/fs/cgroup/lxc/${id}/cpu.stat"; done
  for id in ${VMS}; do echo "vm${id}:/sys/fs/cgroup/qemu.slice/${id}.scope/cpu.stat"; done
}

# Microseconds of CPU each guest has used so far; a stopped guest reads 0.
guest_usec() {
  local entry
  while IFS= read -r entry; do
    if [[ -f ${entry#*:} ]]; then awk '/^usage_usec/ {print $2}' "${entry#*:}"; else echo 0; fi
  done < <(guest_cgroups)
}

# One line in ipmitool order: CPU and DIMM A-H temperatures, FAN1-3 RPM, EDAC counters.
read_sensors() {
  local temps fans
  temps=$(ipmitool sdr type temperature 2>/dev/null |
    awk -F'|' '/DDR4[A-H] |CPU Temp/ {v=$5; gsub(/[^0-9]/, "", v); printf "%s\t", (v == "" ? "NA" : v)}') || true
  fans=$(ipmitool sdr type fan 2>/dev/null |
    awk -F'|' '/^FAN[123] / {v=$5; gsub(/[^0-9]/, "", v); printf "%s\t", (v == "" ? "NA" : v)}') || true
  printf '%s%s%s\t%s\n' "${temps}" "${fans}" "$(cat "${EDAC}/ce_count")" "$(cat "${EDAC}/ue_count")"
}

sample_sensors() {
  local line max
  while [[ ! -f ${OUT}/done ]]; do
    line=$(read_sensors)
    printf '%s\t%s\n' "$(date +%s)" "${line}" >> "${SENSORS}"
    # Columns 2-9 of the sensor line are DDR4 A-H.
    max=$(cut -f2-9 <<< "${line}" | tr '\t' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
    if [[ -n ${max} && ${max} -ge ${DIMM_LIMIT_C} ]]; then
      echo "DIMM reached ${max} C (limit ${DIMM_LIMIT_C}); stopping at $(date -Is)" >> "${SUMMARY}"
      touch "${OUT}/stop"
    fi
    sleep "${SAMPLE_SECONDS}"
  done
}

# STREAM prints the best rate and the average time over its passes; the average rate is the
# figure that would fall if refresh or throttling cut into bandwidth mid-run.
run_pass() {
  local n="$1" start end before after log
  log="${OUT}/stream.out"
  before=$(guest_usec | paste -sd' ')
  start=$(date +%s)
  OMP_NUM_THREADS="${THREADS}" OMP_PROC_BIND=spread OMP_PLACES=cores "${BENCH_DIR}/stream" > "${log}"
  end=$(date +%s)
  after=$(guest_usec | paste -sd' ')
  awk -v n="${n}" -v start="${start}" -v end="${end}" -v before="${before}" -v after="${after}" '
    /^Array size =/ {elems = $4}
    /^Copy:/  {cb = $2; ca = 2 * 8 * elems / $3 / 1e6}
    /^Triad:/ {tb = $2; ta = 3 * 8 * elems / $3 / 1e6}
    /Solution Validates/ {ok = "ok"}
    END {
      split(before, b, " "); split(after, a, " ")
      guests = ""
      for (i = 1; i in a; i++) guests = guests sprintf("\t%.1f", (a[i] - b[i]) / 1e6)
      printf "%d\t%d\t%d\t%.1f\t%.1f\t%.1f\t%.1f\t%s%s\n", n, start, end, cb / 1000, ca / 1000, tb / 1000, ta / 1000, (ok ? ok : "FAIL"), guests
    }' "${log}" >> "${PASSES}"
}

summarize() {
  awk -F'\t' -v window=600 '
    NR == 1 {next}
    {t0 = (t0 ? t0 : $2); w = int(($2 - t0) / window); n[w]++; c[w] += $5; t[w] += $7
     if (!min || $7 < min) min = $7; if ($7 > max) max = $7; if ($8 != "ok") bad++; last = w}
    END {
      printf "passes=%d failed_validation=%d triad_avg_min=%.1f triad_avg_max=%.1f GB/s\n", NR - 1, bad, min, max
      for (i = 0; i <= last; i++) if (n[i]) printf "  minute %3d-%3d: %2d passes  copy_avg %.1f  triad_avg %.1f GB/s\n", i * 10, i * 10 + 10, n[i], c[i] / n[i], t[i] / n[i]
    }' "${PASSES}"
  awk -F'\t' 'NR > 1 {for (i = 3; i <= 10; i++) if ($i != "NA" && $i + 0 > m) m = $i + 0; if ($2 + 0 > cpu) cpu = $2 + 0}
    END {printf "peak DIMM %s C, peak CPU %s C\n", m, cpu}' "${SENSORS}"
  tail -1 "${SENSORS}" | awk -F'\t' '{printf "EDAC at end: ce=%s ue=%s\n", $(NF - 1), $NF}'
}

main() {
  [[ ${EUID} -eq 0 ]] || die "run as root on the Proxmox host"
  [[ -x ${BENCH_DIR}/stream ]] || die "${BENCH_DIR}/stream missing; run membench.sh first"
  [[ ! -e ${OUT} ]] || die "${OUT} already exists"
  mkdir -p "${OUT}"

  printf 'epoch\tCPU\tDDR4A\tDDR4B\tDDR4C\tDDR4D\tDDR4E\tDDR4F\tDDR4G\tDDR4H\tFAN1\tFAN2\tFAN3\tce\tue\n' > "${SENSORS}"
  printf 'pass\tstart\tend\tcopy_best\tcopy_avg\ttriad_best\ttriad_avg\tvalid\t%s\n' \
    "$(guest_cgroups | cut -d: -f1 | sed 's/$/_cpu_s/' | paste -sd'\t')" > "${PASSES}"
  {
    echo "start $(date -Is) kernel $(uname -r) duration ${DURATION}s threads ${THREADS}"
    echo "governor $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor) load $(cut -d' ' -f1-3 /proc/loadavg)"
  } > "${SUMMARY}"

  sample_sensors &
  SAMPLER_PID=$!
  trap 'touch "${OUT}/done"; kill "${SAMPLER_PID}" 2>/dev/null || true' EXIT
  local n=0 deadline=$(( $(date +%s) + DURATION ))

  while [[ $(date +%s) -lt ${deadline} && ! -f ${OUT}/stop ]]; do
    n=$((n + 1))
    run_pass "${n}"
  done

  touch "${OUT}/done"
  wait "${SAMPLER_PID}" 2>/dev/null || true
  echo "end $(date -Is)" >> "${SUMMARY}"
  summarize >> "${SUMMARY}"
  cat "${SUMMARY}"
}

main "$@"
