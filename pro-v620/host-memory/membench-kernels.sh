#!/usr/bin/env bash
# Memory bandwidth by store type, and read-only bandwidth, on the EPYC host.
#
# STREAM counts the bytes a kernel names, not the bytes it moves. GCC turns STREAM's Copy loop
# into a memcpy call, and glibc copies blocks that large with non-temporal stores, so Copy
# moves what it counts. Scale, Add and Triad use ordinary stores, which first read each
# destination line (read-for-ownership); STREAM does not count that read. Four binaries built
# from the same pinned STREAM source separate the two:
#
#   stream-gcc    membench.sh's flags: Copy non-temporal (memcpy), the other three ordinary
#   stream-plain  the same plus -fno-tree-loop-distribute-patterns: all four ordinary
#   stream-nt     -DTUNED with membench-stream-nt.c: all four non-temporal
#   readbw        membench-readbw.c: read only, the access pattern of CPU-offloaded decode
#
# Runs on the Proxmox HOST as root, from a harness staged by ../push-harness.sh, with every
# guest shut down (../TEST-RECORDS.md). SMOKE=true builds small arrays for a quick check that
# no record cites; it skips both requirements.
#
# Each run starts once the hottest DIMM is at or below COOL_C. A run during which any DIMM
# reaches CAP_C is marked capped and left out of the summary: at 66 °C the BMC cuts memory
# bandwidth to a third (README.md, "DIMM thermal throttle").
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SMOKE="${SMOKE:-false}"
ROUNDS="${ROUNDS:-3}"
THREADS="${THREADS:-8 16 32}"
COOL_C="${COOL_C:-55}"
CAP_C="${CAP_C:-66}"
COOL_TIMEOUT_S="${COOL_TIMEOUT_S:-1200}"
SAMPLE_S=5
# Doubles per STREAM array (8 GB each, as membench.sh) and in readbw's array (16 GB).
ARRAY_SIZE=1000000000
READ_SIZE=2000000000
NTIMES=20
STREAM_URL=https://www.cs.virginia.edu/stream/FTP/Code/stream.c
# STREAM 5.10; /root/membench/stream was built from this source on 2026-09-17.
STREAM_SHA256=a52bae5e175bea3f7832112af9c085adab47117f7d2ce219165379849231692b
BINARIES=(stream-gcc stream-plain stream-nt readbw)

SUFFIX=""
if [[ ${SMOKE} == true ]]; then
  ARRAY_SIZE=20000000
  READ_SIZE=40000000
  ROUNDS=1
  THREADS="${SMOKE_THREADS:-4}"
  SUFFIX="-smoke"
fi
OUT="${OUT:-/root/membench/kernels-$(date +%F-%H%M)${SUFFIX}}"
SENSORS="${OUT}/sensors.tsv"
RUNS="${OUT}/runs.tsv"
SAMPLER_PID=""

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date +%T)] $*"; }

harness_commit() {
  local d="${HERE}"
  while [[ ${d} != / ]]; do
    if [[ -f ${d}/HARNESS_COMMIT ]]; then head -1 "${d}/HARNESS_COMMIT"; return; fi
    d="$(dirname "${d}")"
  done
}

require_quiet() {
  local running
  running="$( { pct list | awk 'NR > 1 && $2 == "running" {print "CT " $1}'
               qm list | awk 'NR > 1 && $3 == "running" {print "VM " $1}'; } | paste -sd' ')"
  [[ -z ${running} ]] || die "guests running (${running}); shut them down first"
}

# One line: CPU temperature, then DIMMs A-H, in °C ("NA" when the BMC gives no reading).
read_temps() {
  ipmitool sdr type temperature 2>/dev/null | awk -F'|' '
    {name = $1; gsub(/ /, "", name); v = $5; gsub(/[^0-9]/, "", v)}
    name == "CPUTemp" {cpu = v}
    name ~ /DDR4[A-H]$/ {d[substr(name, length(name))] = v}
    END {
      printf "%s", (cpu == "" ? "NA" : cpu)
      n = split("A B C D E F G H", L, " ")
      for (i = 1; i <= n; i++) printf "\t%s", (d[L[i]] == "" ? "NA" : d[L[i]])
      printf "\n"
    }'
}

hottest_dimm() {
  read_temps | awk -F'\t' '{for (i = 2; i <= 9; i++) if ($i != "NA" && $i + 0 > m) m = $i + 0} END {if (m) print m}'
}

start_sampler() {
  printf 'epoch\tCPU\tDDR4A\tDDR4B\tDDR4C\tDDR4D\tDDR4E\tDDR4F\tDDR4G\tDDR4H\n' > "${SENSORS}"
  ( while :; do printf '%s\t%s\n' "$(date +%s)" "$(read_temps)" >> "${SENSORS}"; sleep "${SAMPLE_S}"; done ) &
  SAMPLER_PID=$!
}

stop_sampler() {
  [[ -n ${SAMPLER_PID} ]] || return 0
  kill "${SAMPLER_PID}" 2>/dev/null || true
  wait "${SAMPLER_PID}" 2>/dev/null || true
  SAMPLER_PID=""
}

wait_cool() {
  local t0=${SECONDS} m
  while :; do
    m="$(hottest_dimm)"
    [[ -n ${m} ]] || die "no DIMM temperature from the BMC"
    if (( m <= COOL_C )); then echo "${m}"; return; fi
    (( SECONDS - t0 < COOL_TIMEOUT_S )) || die "hottest DIMM still ${m} C after ${COOL_TIMEOUT_S} s"
    sleep 15
  done
}

fetch_source() {
  local src="${OUT}/src/stream.c"
  if [[ -f /root/membench/stream.c ]]; then cp /root/membench/stream.c "${src}"; else curl -fsSL -o "${src}" "${STREAM_URL}"; fi
  echo "${STREAM_SHA256}  ${src}" | sha256sum -c --quiet - || die "stream.c does not match the pinned checksum"
}

build() {
  local src="${OUT}/src" bin="${OUT}/bin"
  local common=(-O3 -march=native -fopenmp -mcmodel=medium -DNTIMES="${NTIMES}")
  gcc "${common[@]}" -DSTREAM_ARRAY_SIZE="${ARRAY_SIZE}" -o "${bin}/stream-gcc" "${src}/stream.c"
  gcc "${common[@]}" -DSTREAM_ARRAY_SIZE="${ARRAY_SIZE}" -fno-tree-loop-distribute-patterns \
      -o "${bin}/stream-plain" "${src}/stream.c"
  # STREAM's tuned-kernel stubs, replaced by the non-temporal kernels.
  sed '/stubs for "tuned" versions of the kernels/,/end of stubs for the "tuned" versions of the kernels/d' \
      "${src}/stream.c" > "${src}/stream-nt.c"
  ! grep -q 'tuned_STREAM_Copy()$' "${src}/stream-nt.c" || die "stream.c's tuned stubs were not removed"
  cat "${HERE}/membench-stream-nt.c" >> "${src}/stream-nt.c"
  gcc "${common[@]}" -DSTREAM_ARRAY_SIZE="${ARRAY_SIZE}" -DTUNED -o "${bin}/stream-nt" "${src}/stream-nt.c"
  gcc "${common[@]}" -DREAD_ARRAY_SIZE="${READ_SIZE}L" -o "${bin}/readbw" "${HERE}/membench-readbw.c"
}

# Each binary must store the way its name says, or the comparison means nothing.
verify_builds() {
  local bin="${OUT}/bin"
  count() { objdump -d --no-show-raw-insn "$1" | grep -cE "$2" || true; }
  (( $(count "${bin}/stream-gcc" '(call|jmp) +[0-9a-f]+ <memcpy@plt>') >= 1 )) \
    || die "stream-gcc: Copy no longer calls memcpy, so it no longer matches membench.sh's build"
  (( $(count "${bin}/stream-plain" '<memcpy@plt>$') == 0 )) || die "stream-plain still calls memcpy"
  (( $(count "${bin}/stream-plain" 'movnt') == 0 )) || die "stream-plain has non-temporal stores"
  (( $(count "${bin}/stream-nt" 'vmovntpd') >= 4 )) || die "stream-nt lacks non-temporal stores"
  (( $(count "${bin}/stream-nt" '<memcpy@plt>$') == 0 )) || die "stream-nt calls memcpy"
}

capture_env() {
  local commit="$1"
  {
    echo "date: $(date -Is)"
    echo "harness: ${commit}"
    echo "smoke: ${SMOKE}"
    echo "kernel: $(uname -r)"
    echo "bios: $(dmidecode -s bios-version) $(dmidecode -s bios-release-date)"
    echo "cpu: $(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)"
    echo "microcode: $(awk '/^microcode/ {print $3; exit}' /proc/cpuinfo)"
    echo "governor: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)"
    echo "numa_nodes: $(find /sys/devices/system/node -maxdepth 1 -name 'node[0-9]*' | wc -l)"
    echo "thp: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
    echo "gcc: $(gcc --version | head -1)"
    echo "glibc: $(ldd --version | head -1)"
    echo "glibc_copy_thresholds: $(/lib64/ld-linux-x86-64.so.2 --list-diagnostics 2>/dev/null |
      grep -E 'cpu_features\.(non_temporal_threshold|rep_movsb_threshold|rep_movsb_stop_threshold)=' | paste -sd' ')"
    echo "array_doubles: stream ${ARRAY_SIZE} x 3, readbw ${READ_SIZE}; ntimes ${NTIMES}"
    echo "threads: ${THREADS}; rounds ${ROUNDS}; cool ${COOL_C} C; cap ${CAP_C} C"
    echo "omp: OMP_PROC_BIND=spread OMP_PLACES=cores"
    echo "dimms:"
    dmidecode -t 17 | awk -F': ' '
      /^\tSize:/ {size = $2} /^\tLocator:/ {loc = $2} /^\tPart Number:/ {part = $2}
      /^\tConfigured Memory Speed:/ {if (size !~ /No Module/) print "  " loc ", " size ", " part ", " $2}'
    echo "guests:"
    pct list | sed 's/^/  /'
    qm list | sed 's/^/  /'
    echo "load: $(cut -d' ' -f1-3 /proc/loadavg)"
    echo "checksums:"
    (cd "${OUT}" && sha256sum src/* bin/* "${HERE}/membench-stream-nt.c" "${HERE}/membench-readbw.c") | sed 's/^/  /'
  } > "${OUT}/env.txt"
}

# One binary at one thread count; appends a row per kernel to runs.tsv.
run_one() {
  local round="$1" bin="$2" threads="$3" log cool start end peak elems
  log="${OUT}/logs/r${round}-${bin}-t${threads}.out"
  elems="${ARRAY_SIZE}"
  [[ ${bin} != readbw ]] || elems="${READ_SIZE}"
  cool="$(wait_cool)"
  start="$(date +%s)"
  OMP_NUM_THREADS="${threads}" OMP_PROC_BIND=spread OMP_PLACES=cores "${OUT}/bin/${bin}" > "${log}" 2>&1 || true
  end="$(date +%s)"
  peak="$( { awk -F'\t' -v s="${start}" -v e="${end}" 'NR > 1 && $1 >= s && $1 <= e {print}' "${SENSORS}"
             printf '%s\t%s\n' "${end}" "$(read_temps)"; } |
           awk -F'\t' '{for (i = 3; i <= 10; i++) if ($i != "NA" && $i + 0 > m) m = $i + 0} END {print m + 0}')"
  awk -v round="${round}" -v bin="${bin}" -v t="${threads}" -v n="${elems}" -v cool="${cool}" \
      -v peak="${peak}" -v cap="${CAP_C}" -v start="${start}" -v end="${end}" '
    /Solution Validates/ {ok = 1}
    /^(Copy|Scale|Add|Triad|Read):/ {k = substr($1, 1, length($1) - 1); best[k] = $2 / 1000; avg[k] = $3; order[++nk] = k}
    END {
      thermal = (peak >= cap ? "capped" : "clean")
      for (i = 1; i <= nk; i++) {
        k = order[i]
        bytes = (k == "Add" || k == "Triad") ? 24 * n : (k == "Read" ? 8 * n : 16 * n)
        printf "%d\t%s\t%d\t%s\t%.1f\t%.1f\t%s\t%d\t%d\t%s\t%d\t%d\n", round, bin, t, k, best[k],
               (avg[k] > 0 ? bytes / avg[k] / 1e9 : 0), (ok ? "ok" : "FAIL"), cool, peak, thermal, start, end
      }
      if (nk == 0) printf "%d\t%s\t%d\tnone\t0\t0\tFAIL\t%d\t%d\t%s\t%d\t%d\n", round, bin, t, cool, peak, thermal, start, end
    }' "${log}" >> "${RUNS}"
  log "  $(awk -F'\t' -v r="${round}" -v b="${bin}" -v t="${threads}" \
      '$1 == r && $2 == b && $3 == t {s = s $4 " " $5 " "; v = $7; th = $10} END {print s "GB/s best; " v ", " th}' \
      "${RUNS}"); DIMM ${cool} -> ${peak} C"
}

# Median of the clean, validated runs per binary, kernel and thread count, and the bytes each
# kernel moves: an ordinary store adds one read of the destination, so Copy and Scale move
# 1.5x what STREAM counts and Add and Triad 4/3x; a non-temporal store adds nothing.
summarize() {
  python3 -I - "${RUNS}" <<'PY'
import csv, statistics, sys

rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
RFO = {"Copy": 1.5, "Scale": 1.5, "Add": 4 / 3, "Triad": 4 / 3}

def moved_factor(binary, kernel):
    if binary in ("stream-nt", "readbw") or (binary == "stream-gcc" and kernel == "Copy"):
        return 1.0
    return RFO[kernel]

groups, left_out = {}, []
for r in rows:
    if r["valid"] != "ok" or r["thermal"] != "clean":
        left_out.append(f"round {r['round']} {r['binary']} {r['threads']}t {r['kernel']}: {r['valid']}, {r['thermal']}")
        continue
    key = (r["binary"], r["kernel"], int(r["threads"]))
    groups.setdefault(key, []).append((float(r["best_gbs"]), float(r["avg_gbs"])))

bins = ["stream-gcc", "stream-plain", "stream-nt", "readbw"]
kernels = ["Copy", "Scale", "Add", "Triad", "Read"]
print("| Binary | Kernel | Threads | Best GB/s, median | Range | Avg-time GB/s, median | Runs | Moved/counted | Moved GB/s |")
print("| --- | --- | ---: | ---: | --- | ---: | ---: | ---: | ---: |")
for b in bins:
    for k in kernels:
        for t in sorted({key[2] for key in groups if key[0] == b and key[1] == k}):
            v = groups[(b, k, t)]
            best = [x[0] for x in v]
            med = statistics.median(best)
            f = moved_factor(b, k)
            print(f"| {b} | {k} | {t} | {med:.1f} | {min(best):.1f}-{max(best):.1f} | "
                  f"{statistics.median(x[1] for x in v):.1f} | {len(v)} | {f:.2f} | {med * f:.1f} |")
print()
print(f"Rows left out: {len(left_out)}")
for line in left_out:
    print(f"- {line}")
PY
}

main() {
  [[ ${EUID} -eq 0 ]] || die "run as root on the Proxmox host"
  local commit round t i bin
  commit="$(harness_commit)"
  if [[ ${SMOKE} != true ]]; then
    [[ -n ${commit} ]] || die "no HARNESS_COMMIT: stage with ../push-harness.sh (SMOKE=true for an uncited check)"
    require_quiet
  fi
  [[ ! -e ${OUT} ]] || die "${OUT} already exists"
  mkdir -p "${OUT}"/{src,bin,logs}

  log "building into ${OUT}"
  fetch_source
  build
  verify_builds
  capture_env "${commit:-unpinned}"

  printf 'round\tbinary\tthreads\tkernel\tbest_gbs\tavg_gbs\tvalid\tdimm_start_c\tdimm_peak_c\tthermal\tstart\tend\n' > "${RUNS}"
  start_sampler
  trap stop_sampler EXIT
  for (( round = 1; round <= ROUNDS; round++ )); do
    for t in ${THREADS}; do
      # Rotate the binary order each round so no binary always runs first or last.
      for (( i = 0; i < ${#BINARIES[@]}; i++ )); do
        bin="${BINARIES[(i + round - 1) % ${#BINARIES[@]}]}"
        log "round ${round}/${ROUNDS}, ${t} threads, ${bin}"
        run_one "${round}" "${bin}" "${t}"
      done
    done
  done
  stop_sampler

  summarize > "${OUT}/summary.md"
  cat "${OUT}/summary.md"
  log "done: ${OUT}"
}

main "$@"
