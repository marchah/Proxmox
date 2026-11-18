# Host memory: store types and read-only bandwidth

Plan committed 2026-11-18 · Run 2026-11-18 · Status: planned

## Question

The [2026-10-08 STREAM run](../qwen38-flash-next/README.md#host-memory-bandwidth--2026-10-08)
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
| `stream-nt` | the same with `-DTUNED` and [`membench-stream-nt.c`](../qwen38-flash-next/membench-stream-nt.c) | non-temporal | non-temporal |
| `readbw` | [`membench-readbw.c`](../qwen38-flash-next/membench-readbw.c), same flags | read only: AVX2 loads summed into four accumulators | — |

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
  [bandwidth cap](../qwen38-flash-next/README.md#dimm-thermal-throttle), is left out.

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

Intended: kernel 7.0.14-29-pve, BIOS P4.30, microcode 0x830107d, governor `schedutil`,
GCC 14.2.0-19, glibc 2.41, transparent huge pages `madvise` (STREAM's and `readbw`'s
static arrays get 4 KiB pages), 8 × 64 GB `M393A8K40B22-CAE` at 3200 MT/s. Replaced
by the run's `env.txt` when it starts.

---

## Results

## Deviations

## Conclusion
