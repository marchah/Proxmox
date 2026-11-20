#!/usr/bin/env bash
# Measure real memory bandwidth (STREAM) and idle latency (pointer chase) on the EPYC host.
# Runs on the Proxmox HOST as root. Re-run verbatim after the remaining DIMMs land — the
# whole point is that the 4-stick and 8-stick numbers come from an identical harness.
#
# Why STREAM and not the acceptance soak's `stressapptest`: that tool checksums as well as
# copies, so it understates pure streaming. The open question is whether 76.4 GB/s on four
# channels is the tool under-reporting or the hardware under-delivering, and only a
# streaming benchmark separates them.
#
# ⚠️ Needs a QUIET box. A running model server or sweep will steal bandwidth and contaminate
# both directions.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

OUT="${OUT:-/root/membench}"
mkdir -p "$OUT"
cd "$OUT"

# STREAM's rule is each array >= 4x the sum of all caches. The 7532 has 256 MB of L3, so the
# floor is ~1 GB per array; 8 GB each (24 GB total) is comfortably past it and still tiny
# against 251 GiB. -mcmodel=medium is required for static arrays this large.
ARRAY_SIZE="${ARRAY_SIZE:-1000000000}"
NTIMES="${NTIMES:-20}"

[ -f stream.c ] || curl -fsSL -o stream.c https://www.cs.virginia.edu/stream/FTP/Code/stream.c

if [ ! -x ./stream ]; then
  echo "==> building STREAM (array ${ARRAY_SIZE} doubles = $((ARRAY_SIZE * 8 / 1000000000)) GB each)"
  gcc -O3 -march=native -fopenmp -mcmodel=medium \
      -DSTREAM_ARRAY_SIZE="${ARRAY_SIZE}" -DNTIMES="${NTIMES}" \
      -o stream stream.c
fi

# Idle-latency probe: a random pointer chase defeats every prefetcher, so the number is
# loaded DRAM latency rather than bandwidth. This is the measurement that speaks to the
# 3DS question — 3DS stacking is expected to cost latency, not bandwidth.
cat > latency.c <<'LATC'
// Random pointer chase over a working set far larger than L3: reports ns per dependent load.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
int main(int argc, char **argv) {
    size_t mb = (argc > 1) ? strtoul(argv[1], 0, 10) : 4096;
    size_t n = mb * 1024ULL * 1024ULL / sizeof(size_t);
    size_t *a = aligned_alloc(2 << 20, n * sizeof(size_t));
    if (!a) { perror("alloc"); return 1; }
    // Load-bearing: THP on this host is `madvise`, not `always`, so without this the arrays
    // get 4 KiB pages and a random walk misses the TLB on essentially every access. The
    // 2026-09-17 run measured 226.95 ns/load at 4 GiB WITHOUT it -- that is DRAM latency
    // PLUS a full page-table walk, roughly 2x the real figure and not comparable to any
    // published number. Do not compare runs across this flag.
    madvise(a, n * sizeof(size_t), MADV_HUGEPAGE);
    for (size_t i = 0; i < n; i++) a[i] = i;
    // Fisher-Yates so the chase order is a single random cycle, not a stride.
    srandom(12345);
    for (size_t i = n - 1; i > 0; i--) {
        size_t j = (size_t)((random() ^ ((size_t)random() << 31)) % (i + 1));
        size_t t = a[i]; a[i] = a[j]; a[j] = t;
    }
    // Build the cycle: follow[a[i]] = a[i+1]
    size_t *follow = aligned_alloc(2 << 20, n * sizeof(size_t));
    madvise(follow, n * sizeof(size_t), MADV_HUGEPAGE);
    for (size_t i = 0; i < n; i++) follow[a[i]] = a[(i + 1) % n];
    free(a);
    size_t iters = 50000000, p = 0;
    struct timespec t0, t1;
    for (size_t i = 0; i < 1000000; i++) p = follow[p];          // warm the TLB a little
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (size_t i = 0; i < iters; i++) p = follow[p];
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ns = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / (double)iters;
    printf("working_set=%zu MiB  latency=%.2f ns/load  (hugepages requested) (sink %zu)\n", mb, ns, p);
    free(follow);
    return 0;
}
LATC
[ -x ./latency ] || gcc -O3 -o latency latency.c

CHANNELS=$(ipmitool sdr type Temperature 2>/dev/null | grep -c "DDR4.*degrees" || echo "?")
echo
echo "############ populated channels: ${CHANNELS} ############"
echo

echo "############ STREAM — thread sweep ############"
# 16 threads is what the acceptance soak used; 8 and 32 bracket it so we learn whether that
# choice left bandwidth on the table. OMP_PROC_BIND=spread puts threads on distinct CCDs.
for t in 8 16 32; do
  echo "--- OMP_NUM_THREADS=${t} ---"
  OMP_NUM_THREADS="$t" OMP_PROC_BIND=spread OMP_PLACES=cores \
    ./stream | grep -E "^(Copy|Scale|Add|Triad|Function)"
  echo
done

echo "############ idle latency — random pointer chase ############"
for mb in 256 4096; do ./latency "$mb"; done

echo
echo "############ context ############"
ipmitool sdr type Temperature 2>/dev/null | grep -E "DDR4|CPU Temp" | grep -v "No Reading" |
  awk -F'|' '{gsub(/^ +| +$/,"",$1); gsub(/ *degrees C */,"",$5); printf "  %-18s %s C\n", $1, $5}'

echo
echo "NOTE: STREAM kernels run for seconds, so these temps are NOT heat-soaked and must not"
echo "      be compared against the 4-hour acceptance soak's 58 C peak. Only a sustained run"
echo "      is comparable to that."

