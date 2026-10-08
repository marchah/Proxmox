# Qwen3.8-Flash-Next: context depth and KV type on one card

Plan committed 2026-10-08 · Run 2026-10-08 · Status: running

## Question

At CT 123's production placement (`-ncmoe 34`, one V620) on eight memory channels and
llama.cpp b11505:

- **Depth:** how do decode and prefill change from an empty context to about 59k tokens?
- **KV type:** what does f16 KV cost against q8_0 at a 65536 context, in VRAM, decode and
  prefill? The env files keep reasoning off with q8_0 and name f16 as the type to use
  before enabling it.
- **128k:** does a 131072 context with q8_0 KV run on the card without spill, and what do
  decode and prefill measure at about 119k tokens?

## What answers it

- Every cell loads, shows no GTT spill (no GTT growth during the probe, at least 1 GiB of
  VRAM free after it) and passes the output gate: no degenerate output, and its three
  passes agree per prompt cell (`SUMMARY.md` flags both).
- **Depth:** median code-prompt decode and prefill at each depth, per cell.
- **KV type:** `f16-64k` against `q8-64k` at each depth, and VRAM used after load. A
  difference counts when it is larger than the pass-to-pass spread of both cells.
- **128k:** `q8-128k` runs if it loads and passes the spill check after its ~119k probe.
  Its decode and prefill at ~119k are reported, and its shallower depths against
  `q8-64k` show what the larger allocation costs, by the same rule.
- A cell with any DIMM at 66 °C is reported as capped and left out of the comparisons.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| One GPU | `q8-64k` (production: q8_0, ctx 65536); `f16-64k`; `q8-128k` (q8_0, ctx 131072) |

The cells are in [`2026-10-08-kv-context.cells`](2026-10-08-kv-context.cells).

- **Two GPUs:** left out. CT 123 holds one card; the configurations record measures the
  two-card shapes.
- **CPU only:** left out. Its attention runs on the CPU, a different depth curve from the
  deployed one; the configurations record measures it at d0 and d8000.
- **Optimized (`-ncmoe 48`):** left out. It frees VRAM for a second model, which a larger
  KV would consume.
- **f16 at 131072:** left out. Its KV, about 3 GiB at 24 KiB per token, is 2.25 GiB more
  than the production cell's, and `-ncmoe 34` leaves about 2 GiB free.

## Controls

- `q8-64k` is CT 123's production configuration and the reference for both comparisons.
- Cells run round-robin, three passes each, in one container.

## Method

Harness: `placement-sweep.sh` at the branch head when the run starts (its commit is in
the run's `manifest.json`), staged with [`push-harness.sh`](../../push-harness.sh). The
sweep's method rules are in its header and in [Benchmark
tools](../README.md#benchmark-tools).

```bash
# Host, after the configurations run has given GPU 2 back to CT 123
pct start 123
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
VMID=123 ENV_FILE=qwen38fn-gpu2.env ./install.sh
# Shell 1
VMID=123 ./thermal-guard.sh
# Shell 2
VMID=123 CELLS=runs/2026-10-08-kv-context.cells DEPTHS="0,8000,44000,82000" \
  PROBE_CLASSES=code ./placement-sweep.sh
```

- Depth targets: the probe's filler tokenizes at about 5.5 characters per token, so a
  target yields ~0.72 as many prompt tokens (d8000 measured 5,787 on 2026-10-08).
  Targets 8000, 44000, 82000 and 165000 give about 5.8k, 31.8k, 59.3k and 119.4k
  tokens; the summary prints the measured sizes. d8000 matches the configurations
  record's depth.
- Code prompts only (`PROBE_CLASSES=code`): each prompt class at depth costs its own full
  prefill, and three classes would triple the run. Decode is quoted for code prompts.
- Sweep defaults: `REPS=3`, `N_PREDICT=256`, parallel 1, 16 threads, batch 4096/1024,
  projector on the CPU.
- Expected duration: about 4 hours, an estimate since prefill at depth has not been
  measured on eight channels: ~18 minutes per pass for each 64k cell, ~45 for the 128k
  cell.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`.

## Safety

- The sweep starts no cell while the hottest DIMM is above 58 °C (`DIMM_START_MAX_C`),
  so one cell's heat does not carry into the next. A cell with any DIMM sample at
  66 °C ran at a third of the memory bandwidth and is invalid.
- Every other guest stays shut down: CT 120 `llamacpp` (shut down again after the
  configurations run's rollback restarts it), CT 121 `hermes`, CT 140 `kb-rag`, VM 300
  `docker-host`, CT 200 and CT 201. Starting them again waits for the owner's go-ahead.
- `thermal-guard.sh` runs with `VMID=123`. The deepest prefills hold the card and the CPU
  under load for tens of minutes. On a trip it writes
  `/root/qwen38-flash-next/THERMAL_TRIP`; the sweep then starts no further cell.
- Those prefills also stream the CPU-side experts from RAM throughout; the sweep records
  the hottest DIMM, and a capped cell is left out.
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
