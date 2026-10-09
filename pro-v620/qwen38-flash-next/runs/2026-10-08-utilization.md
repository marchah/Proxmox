# Qwen3.8-Flash-Next: what each configuration uses, rerun with telemetry

Plan committed 2026-10-08 · Run not started · Status: planned

## Question

The [configurations](2026-10-08-configurations.md),
[context depth and KV type](2026-10-08-kv-context.md) and
[`--moe-cache-mib`](2026-10-08-moe-cache.md) runs measured speed but not what limits it.
Rerun their cells with per-phase telemetry:

- **Utilization:** in prefill, decode and, where measured, concurrent streams, how hard
  does each card work (power against its 250 W cap, clocks, busy %) and how many CPU
  cores does the container use? A 60-second sample during a ~119k-token prefill read
  30–180 W and under one CPU core.
- **Reproducibility:** do the reruns reproduce the first runs' decode and prefill?

## What answers it

- Every cell loads, shows no GTT spill and passes the output gate (`SUMMARY.md` flags
  each). The q8_0 128k cell loads under 1 GiB free and is flagged, as in its first run.
- **Utilization:** `SUMMARY.md`'s Utilization table for every cell and phase: median
  busy %, power and sclk per card holding the model, the highest junction temperature,
  and the CPU cores in use.
- **Reproducibility:** each cell's median decode per prompt cell and prefill at d8000
  against its first run. A difference counts when it is larger than the pass-to-pass
  spread of both runs.
- A cell with any DIMM sample at 66 °C is invalid.

## Configurations

| Rerun of | Container | Cells |
| --- | --- | --- |
| Configurations | CT 120, both cards | the seven cells of [`2026-10-08-configurations.cells`](2026-10-08-configurations.cells): two GPUs, one GPU, CPU only and optimized |
| Context depth and KV type | CT 123 | [`2026-10-08-kv-context.cells`](2026-10-08-kv-context.cells): q8_0 and f16 at 64k, q8_0 at 128k |
| `--moe-cache-mib` | CT 123 | `CONFIGS="34 34:auto 40:auto 48:leave12288"` |

The standard configurations included and left out are as in each first run's record.

## Controls

- Each first run is the control for its rerun: same cells, depths, prompt classes,
  container, card and build.
- The harness differs in two ways. A host-side sampler reads sysfs and the container's
  CPU counter once a second. No cell starts while the hottest DIMM is above 58 °C.
- Cells run round-robin, three passes each, as in the first runs.

## Method

Harness: `placement-sweep.sh` at the branch head when the queue starts (its commit is in
each run's `manifest.json`), staged with [`push-harness.sh`](../../push-harness.sh). A
queue on the host runs these after the cold-load-modes run:

```bash
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
# CT 123, with the VMID=123 thermal guard already running
VMID=123 CELLS=runs/2026-10-08-kv-context.cells DEPTHS="0,8000,44000,82000" \
  PROBE_CLASSES=code ./placement-sweep.sh
VMID=123 CONFIGS="34 34:auto 40:auto 48:leave12288" DEPTHS="0,8000" ./placement-sweep.sh
# CT 120 takes both cards; the guard moves to VMID=120
pct shutdown 123 && pct start 120
VMID=120 ./install.sh && ./ct120-cutover.sh to-qwen38fn
VMID=120 ./thermal-guard.sh
VMID=120 CELLS=runs/2026-10-08-configurations.cells DEPTHS="0,8000" ./placement-sweep.sh
./ct120-cutover.sh to-qwen36 && pct shutdown 120
```

- Each sweep's settings are its first run's: `REPS=3`, `N_PREDICT=256`; for the
  context cells, code prompts only, targets to ~59k tokens and ~119k for the 128k cell;
  for the cache cells, `CACHE_MARGIN_MIB=1024` and `-lv 4`.
- **Telemetry:** once a second, each card's busy %, VRAM-controller busy %, sclk, power
  and junction temperature, and the container's CPU time. The probe records each
  request's start and its prompt and generation times, which place each sample in
  prefill or decode.
- Expected duration: about 3.5 hours for the context cells, 1.5 for the cache cells and
  2.5 for the configurations, plus the cutovers: about 7.5 hours.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`, one per sweep.

## Safety

- Every other guest stays shut down. CT 123 is shut down before the cutover, and the
  cutover clears its `onboot`; `to-qwen36` restores it and gives GPU 2 back. CT 120 is
  shut down at the end. Starting any guest again waits for the owner's go-ahead.
- `thermal-guard.sh` watches the cards of the container under test. On a trip it writes
  `/root/qwen38-flash-next/THERMAL_TRIP`, and the queue starts nothing further.
- The sweep starts no cell while the hottest DIMM is above 58 °C.
- Keep clear of the Sunday 01:00 backup window.

## Environment

Intended: llama.cpp b11505 (release tarball), Mesa 26.2.4, kernel `7.0.14-22-pve`,
8 × 64 GB DDR4-3200, both V620s at 0 mV and 250 W; CT 123 with 24 cores and 120 GiB on
`0000:83:00.0`; CT 120 with 48 cores and 160 GiB on both cards after the cutover. Each
run's `environment.json` replaces this paragraph when the run starts.

---

## Results

Not run.

## Deviations

## Conclusion
