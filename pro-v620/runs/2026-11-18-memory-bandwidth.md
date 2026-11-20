# Host memory: store types and read-only bandwidth

Plan committed 2026-11-18 · Run 2026-11-18 · Status: done

## Question

The [2026-10-08 STREAM run](../host-memory/README.md#bandwidth)
reports Copy at 152.7 GB/s but Scale, Add and Triad at 97–107 GB/s on the same memory.
GCC compiles STREAM's Copy loop to a `memcpy` call (confirmed on the host's binary), and
glibc 2.41 copies anything over 12 MiB with non-temporal stores. The other three kernels
use ordinary stores, which read each destination line before writing it, and STREAM does
not count that read. Is the gap only that accounting, so that every kernel moves the same
bytes? And how fast can the host read memory, the access pattern of CPU-offloaded decode?

## What answers it

All figures are the median of three rounds at 16 threads, the best thread count on
2026-10-08, unless stated.

- **Store type.** The gap is accounting if both hold: `stream-nt`'s Scale, Add and Triad
  are each within 5% of `stream-gcc`'s Copy, and `stream-plain`'s Copy is within 5% of
  `stream-plain`'s Scale. Otherwise the record reports how far each kernel's moved bytes
  differ.
- **Read bandwidth.** `readbw` at its best thread count is the host's read-only figure,
  quoted against the 204.8 GB/s theoretical peak and against `stream-gcc`'s Copy.
- **Reproduction.** `stream-gcc`'s Copy within 3% of 152.7 GB/s means the 2026-10-08
  figures still hold on kernel 7.0.14-29.

## Configurations

BIOS as on 2026-10-08: NPS1, APBDIS Auto, DF C-states enabled. The NUMA node count is
checked in-band; APBDIS and DF C-states are not readable without the BMC, so they are the
values last set at the console (2026-09-16).

| Binary | Build | Copy | Scale, Add, Triad |
| --- | --- | --- | --- |
| `stream-gcc` | `membench.sh`'s flags: `gcc -O3 -march=native -fopenmp -mcmodel=medium` | non-temporal (`memcpy`) | ordinary stores |
| `stream-plain` | the same plus `-fno-tree-loop-distribute-patterns` | ordinary stores | ordinary stores |
| `stream-nt` | the same with `-DTUNED` and [`membench-stream-nt.c`](../host-memory/membench-stream-nt.c) | non-temporal | non-temporal |
| `readbw` | [`membench-readbw.c`](../host-memory/membench-readbw.c), same flags | read only: AVX2 loads summed into four accumulators | — |

`membench-kernels.sh` checks each build's instructions before running and stops if one
does not store the way its row says.

Left out:

- The standard model configurations (two GPUs, one GPU, CPU only, optimized) and
  speculative decoding: no model runs; this measures the host's memory.
- NPS4, APBDIS 1 with SOC P-state P0, and DF C-states disabled: each needs a reboot
  and a BIOS change at the console. The owner chose the software tests only for this run.
- 64 threads: on 2026-10-08 it was the slowest count for every kernel.

## Controls

- `stream-gcc` is built exactly as the 2026-10-08 binary, from the same STREAM source
  (SHA-256 pinned in the script), and is the reproduction control.
- STREAM validates its arrays after every run; `readbw` checks every pass's sum. A run
  that fails validation is left out of the summary.
- Each run starts with the hottest DIMM at or below 55 °C. The BMC's DIMM temperatures are
  sampled every 5 s; a run during which any DIMM reaches 66 °C, the
  [bandwidth cap](../host-memory/README.md#dimm-thermal-throttle), is left out.

## Method

- Harness: this commit, staged with `../push-harness.sh`, run as
  `/root/harness/<sha12>/pro-v620/qwen38-flash-next/membench-kernels.sh` with the defaults
  (`ROUNDS=3 THREADS="8 16 32" COOL_C=55 CAP_C=66`).
- STREAM 5.10 with three arrays of 10⁹ doubles (8 GB each) and 20 passes, as
  `membench.sh`; `readbw` reads one array of 2×10⁹ doubles (16 GB) for 20 passes. Both
  drop the first pass and report the best rate; the summary also gives the rate at the
  average pass time.
- `OMP_PROC_BIND=spread OMP_PLACES=cores`, as `membench.sh`.
- Three rounds. In each round every thread count runs all four binaries, in an order
  rotated by one each round.
- Bytes moved per bytes counted: an ordinary store adds one read of the destination, so
  Copy and Scale move 1.5× what STREAM counts and Add and Triad 4/3×. A non-temporal
  store and a read-only pass add nothing.
- Expected duration: 25–40 minutes, most of it STREAM's array initialization and
  waiting for the DIMMs to cool.
- Raw data: `/root/membench/kernels-<date-time>/` on the host: `runs.tsv` (one row per
  kernel per run), `sensors.tsv`, `env.txt`, `summary.md` and each run's output in `logs/`.

## Safety

- Shut down before the run: CT 121 (`hermes`), then CT 120 (`llamacpp`) once
  `/slots` shows no request in progress, then CT 125 (`ds41-strata`). CT 123, 126, 127,
  200 and 201 are already stopped. `pct shutdown` leaves `onboot` unchanged.
- The guests stay down after the run until the owner says to start them.
- No reboot and no BIOS change. The host's governor stays `schedutil`.

## Environment

From the run's `env.txt` (`/root/membench/kernels-2026-11-18-1518/env.txt`):

```text
date: 2026-11-18T15:18:09-05:00
harness: 3533a8b96204cc7ead2e1b732bf864fbe077435b
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
threads: 8 16 32; rounds 3; cool 55 C; cap 66 C
omp: OMP_PROC_BIND=spread OMP_PLACES=cores
dimms: 8 x (64 GB, M393A8K40B22-CAE, 3200 MT/s)
guests: 120, 121, 123, 125, 126, 127, 200, 201 all stopped
load: 1.77 0.79 1.30
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

The DIMM and guest lists are condensed from eight identical lines each.

---

## Results

Run 2026-11-18 15:18–15:35 ET, 36 runs, all validated. Every run started with the hottest
DIMM at or below 55 °C; the hottest reading during the run was 57 °C, so no run was capped
and none was left out. The three rounds of each cell are within 1.3% of each other. Full
table, per thread count: `summary.md` in the raw data directory,
`/root/membench/kernels-2026-11-18-1518/`.

Best rate in GB/s at 16 threads, median of three rounds, as STREAM reports it:

| Binary | Copy | Scale | Add | Triad |
| --- | ---: | ---: | ---: | ---: |
| `stream-gcc` | 149.9 | 96.3 | 104.9 | 104.9 |
| `stream-plain` | 96.8 | 95.4 | 106.9 | 107.1 |
| `stream-nt` | 145.6 | 147.7 | 144.7 | 144.9 |

The same runs in bytes moved, counting the read each ordinary store makes of its
destination (×1.5 for Copy and Scale, ×4/3 for Add and Triad):

| Binary | Copy | Scale | Add | Triad |
| --- | ---: | ---: | ---: | ---: |
| `stream-gcc` | 149.9 | 144.4 | 139.9 | 139.9 |
| `stream-plain` | 145.2 | 143.1 | 142.5 | 142.8 |
| `stream-nt` | 145.6 | 147.7 | 144.7 | 144.9 |

Read only, `readbw`, best rate in GB/s:

| Threads | 8 | 16 | 32 |
| --- | ---: | ---: | ---: |
| `readbw` | 113.0 | 136.6 | 141.7 |

`stream-gcc` against 2026-10-08: Copy 148.6, 149.9 and 146.1 GB/s at 8, 16 and 32
threads, against 151.0, 152.7 and 148.6. Every `stream-gcc` figure is 0.8–2.8% below the
2026-10-08 one.

## Deviations

- `env.txt` names every DIMM "DIMM 0": the script prints dmidecode's `Locator`, and this
  board puts the channel letter in `Bank Locator`. Part number and speed are listed for all
  eight.

## Conclusion

- **Store type: the gap is accounting.** `stream-nt`'s Scale, Add and Triad are 1.5%,
  3.5% and 3.3% below `stream-gcc`'s Copy (criterion: within 5%), and `stream-plain`'s Copy
  is 1.5% above its Scale (criterion: within 5%). Counted by bytes moved, every kernel of
  every build moves 139.9–149.9 GB/s at 16 threads, 68–73% of the 204.8 GB/s peak.
  Non-temporal stores raise STREAM's reported Scale by 53% and Add and Triad by 38%, but
  not the bandwidth. Kernels with ordinary stores move 140–145 GB/s, slightly less than
  those with non-temporal stores (145–150). glibc's `memcpy` copies 3% faster than the
  AVX2 non-temporal loop, 149.9 against 145.6 GB/s.
- **Read bandwidth: 141.7 GB/s** at 32 threads, 69% of 204.8 GB/s and 5.5% below
  `stream-gcc`'s Copy. It rose with every step in thread count (113.0, 136.6, 141.7), so
  32, the highest count tested, may not be its peak; 64 threads was not measured.
- **Reproduction: holds.** `stream-gcc`'s Copy at 16 threads is 149.9 GB/s, 1.8% below
  152.7 (criterion: within 3%).
