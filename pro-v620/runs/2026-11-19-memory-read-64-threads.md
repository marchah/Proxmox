# Host memory: read bandwidth at 64 threads

Plan committed 2026-11-19 · Run 2026-11-19 · Status: planned

## Question

On [2026-11-18](2026-11-18-memory-bandwidth.md) the read-only pass rose with every step in
thread count, 113.0, 136.6 and 141.7 GB/s at 8, 16 and 32 threads, so 32, the highest
count tested, may not be the host's read peak. Does it read faster with 64 threads, one per
SMT thread of the EPYC 7532? STREAM at 64 threads was the slowest count for every kernel on
[2026-10-08](../qwen38-flash-next/README.md#host-memory-bandwidth--2026-10-08); does that
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
[`membench-kernels.sh`](../qwen38-flash-next/membench-kernels.sh), unchanged. Two thread
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
  reaches 66 °C, the [bandwidth cap](../qwen38-flash-next/README.md#dimm-thermal-throttle),
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

Intended: the stack of 2026-11-18 (kernel 7.0.14-29-pve, BIOS P4.30, NPS1, gcc 14.2.0,
glibc 2.41); replaced by the run's `env.txt` when it starts.

---

## Results

## Deviations

## Conclusion
