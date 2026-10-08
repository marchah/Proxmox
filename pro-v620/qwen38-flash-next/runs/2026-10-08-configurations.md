# Qwen3.8-Flash-Next: the standard configurations on eight channels

Plan committed 2026-10-08 · Run not started · Status: planned

## Question

On eight memory channels and llama.cpp b11505, what does each standard configuration
deliver: decode by prompt class and depth, prefill at 8k, VRAM and GTT? The 2026-09
answers were measured on four channels and b11018 and have been deleted. Two narrower
questions ride along:

- **One card or two at the same placement?** At `-ncmoe 34` and batch 4096/1024, does
  the two-card decode cost from the QSA indexer's per-token transfers
  (llama.cpp #28699, still an open draft) persist on eight channels?
- **Layer or tensor split on two cards?** `-sm tensor` was re-enabled for qwen4exp in
  llama.cpp #28569. At `-ncmoe 16` and batch 1024/256, does it beat the layer split?

## What answers it

- Every cell loads, shows no GTT spill, and passes the output gate: no degenerate
  output, and its three passes agree per prompt cell (`SUMMARY.md` flags both).
- For each configuration: median decode per prompt class at d0 and d8000, median
  prefill at d8000, VRAM used and free per card, load time.
- **One vs two cards:** `2gpu-34` against `1gpu-34`. A difference counts when it is larger
  than the pass-to-pass spread of both cells.
- **Split mode:** `2gpu-16-tensor` against `2gpu-16`, by the same rule.
- A cell with any DIMM at 66 °C is reported as capped and left out of the comparisons.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| Two GPUs | `2gpu-16` (the shipped two-card config, split `30,18`, 1024/256); `2gpu-16-tensor` (`-sm tensor`, 1024/256); `2gpu-34` (split `39,9`, 4096/1024, matched to `1gpu-34`) |
| One GPU | `1gpu-34` (CT 123's production placement, 4096/1024); `1gpu-40` |
| CPU only | `cpu` (`--device none`, `-ngl 0`, 4096/1024) |
| Optimized | `1gpu-48`: every expert in RAM, leaving about 23 GB of VRAM for a second model |

The cells are in [`2026-10-08-configurations.cells`](2026-10-08-configurations.cells).

## Controls

- `1gpu-34` is the reference: the production placement, also measured as the
  `--moe-cache-mib` record's control on the same build.
- `2gpu-16` is the reference for the split-mode question.
- Cells run round-robin, three passes each, in one container, so every configuration
  sees the same build, stack and time window.

## Method

Harness: `placement-sweep.sh` at the commit that adds this record, staged with
[`push-harness.sh`](../../push-harness.sh). The sweep's method rules are in its header
and in [Benchmark tools](../README.md#benchmark-tools).

```bash
# Host: CT 120 takes both cards (CT 123 stopped first; the cutover stops it anyway)
pct shutdown 123 && pct start 120
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
VMID=120 ./install.sh && ./ct120-cutover.sh to-qwen38fn
# Shell 1
VMID=120 ./thermal-guard.sh
# Shell 2
VMID=120 CELLS=runs/2026-10-08-configurations.cells DEPTHS="0,8000" ./placement-sweep.sh
```

- Sweep defaults: `REPS=3`, `N_PREDICT=256`, prompt classes code, list and prose;
  ctx 65536, parallel 1, 16 threads, q8_0 KV, projector on the CPU.
- Each cell's batch comes from its mode: two cards 1024/256 (the shape the split rule
  was found at), one card and CPU 4096/1024; `2gpu-34` overrides to 4096/1024 to match
  `1gpu-34`.
- One-GPU cells run on `Vulkan0` in a two-card container; the sweep reads VRAM from the
  card each cell loaded onto. CT 123's card and CT 120's card were validated
  equivalent.
- Expected duration: about 3–3.5 hours, the CPU-only cell being the slowest.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`.

## Safety

- Every other guest stays shut down: CT 121 `hermes`, CT 140 `kb-rag`, VM 300
  `docker-host`, and CT 123, which must not hold GPU 2 while CT 120 does. CT 200 and
  CT 201 are already stopped. The cutover clears CT 123's `onboot`.
- After the run, `./ct120-cutover.sh to-qwen36` gives GPU 2 back and restores CT 123's
  `onboot`; it also starts CT 120's Qwen3.6 server, so CT 120 is then shut down again for
  the following one-card tests. No guest is restarted without the owner's go-ahead.
- `thermal-guard.sh` runs with `VMID=120` and watches both cards. On a trip it writes
  `/root/qwen38-flash-next/THERMAL_TRIP`; the sweep then starts no further cell.
- The cutover gives CT 120 48 cores and 160 GiB, enough for the CPU-only cell's
  ~104 GiB of weights.
- DIMM airflow stays as in the 2026-10-08 soak; the sweep records the hottest DIMM.
- Keep clear of the Sunday 01:00 backup window.

## Environment

Intended: llama.cpp b11505 (release tarball), Mesa 26.2.4, kernel `7.0.14-22-pve`,
8 × 64 GB DDR4-3200, both V620s at 0 mV, CT 120 with 48 cores and 160 GiB after the
cutover. The run's `environment.json` replaces this paragraph when the run starts.

---

## Results

Not run.

## Deviations

## Conclusion
