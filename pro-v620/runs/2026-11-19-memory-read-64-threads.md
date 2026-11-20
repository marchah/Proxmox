# Host memory: read bandwidth at 64 threads

Plan committed 2026-11-19 · Run 2026-11-19 · Status: done

## Question

On [2026-11-18](2026-11-18-memory-bandwidth.md) the read-only pass rose with every step in
thread count, 113.0, 136.6 and 141.7 GB/s at 8, 16 and 32 threads, so 32, the highest
count tested, may not be the host's read peak. Does it read faster with 64 threads, one per
SMT thread of the EPYC 7532? STREAM at 64 threads was the slowest count for every kernel on
[2026-10-08](../host-memory/README.md#bandwidth); does that
still hold for every store type?

## What answers it

All figures are the median of three rounds' best rates, in this session.

- **Read bandwidth.** `readbw` at 64 threads against 32 threads. 64 threads reads faster if
  its median is more than 2% above 32's; the three rounds of every cell were within 1.3% of
  each other on 2026-11-18. The higher of the two is the host's read-only figure.
- **STREAM.** Each binary's four kernels at 64 against 32 threads, in bytes moved (the
  2026-11-18 record's factors), reported as a percentage difference.
- **Reproduction.** `readbw` at 32 threads within 3% of 141.7 GB/s, and `stream-gcc`'s Copy
  at 32 threads within 3% of 146.1 GB/s, the 2026-11-18 figures.

## Configurations

BIOS, binaries and build flags as on 2026-11-18: NPS1, APBDIS Auto, DF C-states enabled;
`stream-gcc`, `stream-plain`, `stream-nt` and `readbw`, built by the same
[`membench-kernels.sh`](../host-memory/membench-kernels.sh), unchanged. Two thread
counts: 32 (one per core) and 64 (two per core, both SMT threads), each with
`OMP_PROC_BIND=spread OMP_PLACES=cores`.

Left out:

- 8 and 16 threads: measured on 2026-11-18, and neither can be the peak, since 32 read
  faster than both.
- The standard model configurations and speculative decoding: no model runs; this
  measures the host's memory.
- NPS4, APBDIS 1 with SOC P-state P0, and DF C-states disabled: each needs a reboot and a
  BIOS change; the owner has not scheduled that run.

## Controls

- 32 threads is the in-session control for 64, and the reproduction check against
  2026-11-18.
- STREAM validates its arrays after every run and `readbw` checks every pass's sum; a run
  that fails validation is left out.
- Each run starts with the hottest DIMM at or below 55 °C, and a run during which any DIMM
  reaches 66 °C, the [bandwidth cap](../host-memory/README.md#dimm-thermal-throttle),
  is left out.

## Method

- Harness: this commit, staged with `../push-harness.sh`, run as
  `THREADS="32 64" /root/harness/<sha12>/pro-v620/qwen38-flash-next/membench-kernels.sh`,
  otherwise with its defaults (`ROUNDS=3 COOL_C=55 CAP_C=66`), the arrays and passes of
  2026-11-18.
- Three rounds; in each round both thread counts run all four binaries, in an order
  rotated by one each round.
- Expected duration: 15–30 minutes.
- Raw data: `/root/membench/kernels-<date-time>/` on the host, laid out as on 2026-11-18.

## Safety

- Shut down before the run: CT 121 (`hermes`), then CT 120 (`llamacpp`) once `/slots`
  shows no request in progress, then CT 125 (`ds41-strata`). CT 123, 126, 127, 200 and 201
  are already stopped. `pct shutdown` leaves `onboot` unchanged.
- The guests stay down after the run until the owner says to start them.
- No reboot and no BIOS change. The host's governor stays `schedutil`.

## Environment

From the run's `env.txt` (`/root/membench/kernels-2026-11-19-1448/env.txt`):

```text
date: 2026-11-19T14:48:39-05:00
harness: 2bbc5e69bc1555ba9bab90839ce24d98df92bc8b
smoke: false
kernel: 7.0.14-29-pve
bios: P4.30 05/20/2026
cpu: AMD EPYC 7532 32-Core Processor
microcode: 0x830107d
governor: schedutil
numa_nodes: 1
thp: always [madvise] never
gcc: gcc (Debian 14.2.0-19) 14.2.0
glibc: ldd (Debian GLIBC 2.41-12+deb13u4) 2.41
glibc_copy_thresholds: x86.cpu_features.non_temporal_threshold=0xc00000 x86.cpu_features.rep_movsb_threshold=0xc00000 x86.cpu_features.rep_movsb_stop_threshold=0xc00000
array_doubles: stream 1000000000 x 3, readbw 2000000000; ntimes 20
threads: 32 64; rounds 3; cool 55 C; cap 66 C
omp: OMP_PROC_BIND=spread OMP_PLACES=cores
dimms: 8 x (64 GB, M393A8K40B22-CAE, 3200 MT/s)
guests: 120, 121, 123, 125, 126, 127, 200, 201 all stopped
load: 1.02 0.41 0.25
checksums:
  a52bae5e175bea3f7832112af9c085adab47117f7d2ce219165379849231692b  src/stream.c
  1a4e6be3319b874fadfa24823642028557122853ffc22a85987a021956cd780d  src/stream-nt.c
  9b61e9c27f7021fe18e9e53f41eaf3c08c556b58831684c2c16259e37b16d7f9  bin/readbw
  7333b0b11f1e5717337daa543f9a7b478de8474aa992118f7d5cdfaa1f2da886  bin/stream-gcc
  2e3c3e01e65b6bed94a2497bbfe7b598ce81a1d90bcd04cc682dfd9a10b9be2c  bin/stream-nt
  94b4c0a75403934ed2cb59d9bbebe928bb52ce9e7e5014eb33f2765c0d4db8e9  bin/stream-plain
  131a870e92ac2280be2d7ca4301a28ea037aeb3b1381a7271a09ede7041980dd  membench-stream-nt.c
  1017b29d9a5fd6f22e3ee0ae45d9258bbcebf31c1e1802be5a1d6c90a9d47171  membench-readbw.c
```

The DIMM and guest lists are condensed from eight identical lines each. Every binary's
checksum matches the 2026-11-18 run's.

---

## Results

Run 2026-11-19 14:48–15:01 ET, 24 runs, all validated. Every run started with the hottest
DIMM at or below 55 °C; the hottest reading during the run was 57 °C, so no run was capped
and none was left out. The three rounds of each cell are within 1.2% of each other. Full
table: `summary.md` in the raw data directory, `/root/membench/kernels-2026-11-19-1448/`.

Best rate in GB/s, median of three rounds. "Reported" is what STREAM prints. "Moved"
adds the read each ordinary store makes of its destination: ×1.5 for Copy and Scale and
×4/3 for Add and Triad wherever a kernel uses ordinary stores (`stream-gcc`'s Scale, Add
and Triad, and all of `stream-plain`).

| Binary | Kernel | Reported, 32 | Reported, 64 | Moved, 32 | Moved, 64 | 64 against 32 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `stream-gcc` | Copy | 146.4 | 140.5 | 146.4 | 140.5 | −4.0% |
| `stream-gcc` | Scale | 94.8 | 93.6 | 142.2 | 140.4 | −1.3% |
| `stream-gcc` | Add | 103.4 | 102.9 | 137.9 | 137.2 | −0.5% |
| `stream-gcc` | Triad | 103.3 | 102.9 | 137.7 | 137.2 | −0.4% |
| `stream-plain` | Copy | 95.1 | 93.9 | 142.6 | 140.9 | −1.3% |
| `stream-plain` | Scale | 94.0 | 93.2 | 141.0 | 139.8 | −0.9% |
| `stream-plain` | Add | 105.2 | 104.4 | 140.3 | 139.2 | −0.8% |
| `stream-plain` | Triad | 105.4 | 104.5 | 140.5 | 139.3 | −0.9% |
| `stream-nt` | Copy | 144.3 | 140.0 | 144.3 | 140.0 | −3.0% |
| `stream-nt` | Scale | 145.1 | 140.2 | 145.1 | 140.2 | −3.4% |
| `stream-nt` | Add | 144.7 | 141.2 | 144.7 | 141.2 | −2.4% |
| `stream-nt` | Triad | 144.9 | 140.9 | 144.9 | 140.9 | −2.8% |
| `readbw` | Read | 141.5 | 142.1 | 141.5 | 142.1 | +0.4% |

`readbw`'s rounds: 140.2–141.6 GB/s at 32 threads, 141.0–142.7 at 64. At the average pass
time instead of the best, it reads 140.4 GB/s at 32 threads and 138.0 at 64 (−1.7%).

## Deviations

- `env.txt` names every DIMM "DIMM 0", as on 2026-11-18: the harness is unchanged, so it
  still prints dmidecode's `Locator`, and this board puts the channel letter in
  `Bank Locator`.

## Conclusion

- **Read bandwidth: 64 threads does not read faster.** `readbw` reads 142.1 GB/s at 64
  threads against 141.5 at 32, 0.4% more (criterion: more than 2%), and the two cells'
  rounds overlap. At the average pass time 64 threads is 1.7% slower. The host's read-only
  figure is 142.1 GB/s, 69% of the 204.8 GB/s peak. Together with 2026-11-18, read
  bandwidth rises up to 32 threads and no further.
- **STREAM: 64 threads is slower than 32 for every kernel of every build**, as on
  2026-10-08: by 2.4–4.0% in bytes moved for the kernels with non-temporal stores
  (`stream-gcc`'s Copy and all of `stream-nt`), and by 0.4–1.3% for those with ordinary
  stores.
- **Reproduction: holds.** `readbw` at 32 threads reads 141.5 GB/s, 0.1% below 141.7, and
  `stream-gcc`'s Copy at 32 threads is 146.4 GB/s, 0.2% above 146.1 (criterion: within 3%).
