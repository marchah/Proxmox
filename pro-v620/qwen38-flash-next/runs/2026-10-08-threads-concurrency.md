# Qwen3.8-Flash-Next: threads and concurrent streams on one card

Plan committed 2026-10-08 · Run not started · Status: planned

## Question

At CT 123's production placement (`-ncmoe 34`, one V620) on eight memory channels and
llama.cpp b11505:

- **Threads:** which `--threads` value (8, 16, 24) gives the best decode at one, two and
  four concurrent streams, and does it change prefill? The CPU-side expert FFN is
  memory-bound, and a thread count tuned at one stream can be wrong at another, so
  threads are measured at each slot count.
- **Slots:** what do two and four streams give per user and in total, and what does
  loading two or four slots cost a single user?

## What answers it

- Every cell loads, shows no GTT spill and passes the output gate (`SUMMARY.md` flags
  degenerate output and passes that disagree). The concurrency probe reports no
  degenerate output, no failed request and at least as many slots as streams.
- **Threads at one stream:** median decode per prompt class at d0 and d8000, and median
  prefill at d8000, for `t8-p1`, `t16-p1` and `t24-p1`.
- **Threads under concurrency:** per-stream and aggregate decode at two and four streams
  for each thread count.
- **Slot cost:** single-stream decode at parallel 2 and 4 against parallel 1, at the same
  thread count.
- **Utilization:** per phase, the card's power, clocks and busy %, and the CPU cores in
  use (`SUMMARY.md`'s Utilization table), to show what limits each cell.
- A difference counts when it is larger than the pass-to-pass spread of both cells.
- A cell with any DIMM at 66 °C is reported as capped and left out of the comparisons.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| One GPU | threads 8, 16 and 24 × parallel 1, 2 and 4 at CT 123's production placement (nine cells) |

The cells are in [`2026-10-08-threads-concurrency.cells`](2026-10-08-threads-concurrency.cells).

- **Two GPUs:** left out. Threads and slots act on the CPU side, which is the same with
  either card count at a given `-ncmoe`; CT 123 holds one card.
- **CPU only and optimized (`-ncmoe 48`):** left out. Both move more of the model onto the
  CPU, so their best thread count can differ from this one; each gets its own sweep if
  the configurations record makes it a candidate.
- CT 123 has 24 cores, so 24 threads is its ceiling.

## Controls

- `t16-p1` is CT 123's production configuration and the reference.
- Cells run round-robin, three passes each, in one container. Each cell loads at its own
  `--parallel`, so no concurrency figure comes from a server loaded at a different slot
  count.

## Method

Harness: `placement-sweep.sh` and `concurrency-probe.py` at the branch head when the run
starts (its commit is in the run's `manifest.json`), staged with
[`push-harness.sh`](../../push-harness.sh). The sweep's method rules are in its header
and in [Benchmark tools](../README.md#benchmark-tools).

```bash
# Host; CT 123 holds 0000:83:00.0
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
# Shell 1
VMID=123 ./thermal-guard.sh
# Shell 2
VMID=123 CELLS=runs/2026-10-08-threads-concurrency.cells DEPTHS="0,8000" ./placement-sweep.sh
```

- Each cell runs the placement probe (one request at a time, all three prompt classes, at
  d0 and d8000, ~5.8k tokens), then, where it sets `STREAMS`, `concurrency-probe.py` with
  that many simultaneous streams at d0, each a different prompt with prompt caching off.
- ctx 65536 is shared by the slots: 32768 per slot at parallel 2, 16384 at parallel 4.
- Sweep defaults: `REPS=3`, `N_PREDICT=256`, q8_0 KV, batch 4096/1024, projector on the
  CPU.
- Expected duration: about 2.5 hours.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`, with each concurrency run in
  `<cell>-r<pass>.concurrency.json`.

## Safety

- The sweep starts no cell while the hottest DIMM is above 58 °C (`DIMM_START_MAX_C`),
  so one cell's heat does not carry into the next. A cell with any DIMM sample at
  66 °C ran at a third of the memory bandwidth and is invalid.
- Every other guest stays shut down: CT 120 `llamacpp`, CT 121 `hermes`, CT 140 `kb-rag`,
  VM 300 `docker-host`, CT 200 and CT 201. Starting them again waits for the owner's
  go-ahead.
- `thermal-guard.sh` runs with `VMID=123`; on a trip the sweep starts no further cell.
- The sweep records the hottest DIMM per cell; a capped cell is left out.
- Keep clear of the Sunday 01:00 backup window.

## Environment

Intended: llama.cpp b11505 (release tarball), Mesa 26.2.4, kernel `7.0.14-22-pve`,
8 × 64 GB DDR4-3200, the V620 at `0000:83:00.0` at 0 mV, CT 123 with 24 cores and
120 GiB. The run's `environment.json` replaces this paragraph when the run starts.

---

## Results

Not run.

## Deviations

## Conclusion
