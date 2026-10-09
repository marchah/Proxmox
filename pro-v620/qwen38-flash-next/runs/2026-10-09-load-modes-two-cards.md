# Qwen3.8-Flash-Next: cold load modes on two cards

Plan committed 2026-10-09 · Run not started · Status: planned

## Question

On one card at `-ncmoe 34`, `--load-mode none` and `dio` prefilled 3.2–3.3 times as fast
as `auto` with the same decode
([load-modes record](2026-10-08-load-modes.md)). On two cards at `-ncmoe 16`, the
two-card configuration with the fastest decode, `auto` prefilled 90 t/s against 123
on one card ([configurations record](2026-10-08-configurations.md)). Loading cold, in CT 120
holding both V620s:

- Does `none` change two-card prefill, decode, load time and memory as it does on one
  card?
- Under each load mode, how do two cards at `-ncmoe 16` compare with one card at
  `-ncmoe 34`, in the same container and time window?

## What answers it

- Every cell loads, shows no GTT spill and passes the output gate (`SUMMARY.md` flags
  degenerate output and passes that disagree). The spill flag's static GTT threshold
  does not apply to `none`, whose pinned weights RADV counts as GTT; GTT growth during
  the probe still flags it.
- **Load time:** median seconds to a healthy `/health` per cell. A difference counts
  when it is larger than the pass-to-pass spread of both cells.
- **Memory:** the container's total, anonymous and page-cache memory after the load, and
  each card's VRAM and GTT.
- **Speed:** median decode per prompt class at d0 and d8000, and prefill at d8000, of
  each `none` cell against its `auto` cell, and of the two-card cells against the
  one-card cells under the same mode, by the same rule.
- **Utilization:** per phase, each card's power, clocks and busy %, and the CPU cores in
  use (`SUMMARY.md`'s Utilization table), to show what limits each cell.
- A cell with any DIMM sample at 66 °C is invalid.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| Two GPUs | `2gpu-16-auto` (the two-card configuration in `qwen38fn.env`), `2gpu-16-none` |
| One GPU | `1gpu-34-auto` (CT 123's production placement), `1gpu-34-none`, on `0000:83:00.0` |

The cells are in [`2026-10-09-load-modes-two-cards.cells`](2026-10-09-load-modes-two-cards.cells).

- **The one-card cells** repeat the load-modes record's comparison in this container, so
  the one- and two-card results share a container, card and time window.
- **CPU only:** left out. The load mode decides how the CPU-resident weights are held
  for the cards to read; with no card, there is no transfer to change.
- **Optimized (`-ncmoe 48`) and the other two-card shapes:** left out. The question is
  about the two configurations a deployment would choose between.
- **`dio`:** left out. It matched `none` on one card in load time, memory and speed.

## Controls

- Each `auto` cell is the control for the `none` cell of the same shape.
- Cells run round-robin, three passes each, in one container, every load cold.

## Method

Harness: `placement-sweep.sh` at the branch head when the run starts (its commit is in
the run's `manifest.json`), staged with [`push-harness.sh`](../../push-harness.sh). The
sweep's method rules are in its header and in [Benchmark
tools](../README.md#benchmark-tools). It runs after the
[card comparison](../../runs/2026-10-08-card-ab.md), with CT 120 still holding both cards.

```bash
# Host; CT 120 holds both cards after ct120-cutover.sh to-qwen38fn; CT 123 stopped
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
# Shell 1
VMID=120 ./thermal-guard.sh
# Shell 2
VMID=120 CELLS=runs/2026-10-09-load-modes-two-cards.cells DEPTHS="0,8000" \
  DROP_CACHES=true ./placement-sweep.sh
```

- `DROP_CACHES=true`: before every load the sweep stops the server and drops the host
  page cache, so each load reads the 111 GB from the NVMe store.
- `DEVICE=Vulkan1` is `0000:83:00.0` if the card comparison maps it so; otherwise the
  cells file changes before the run. Each cell's JSON records the card it loaded onto.
- Sweep defaults: `REPS=3`, `N_PREDICT=256`, prompt classes code, list and prose (d8000 is
  ~5.8k tokens); ctx 65536, parallel 1, 16 threads, q8_0 KV, projector on the CPU. Two
  cards use batch 1024/256 and the split rule's `--tensor-split 30,18`; one card uses
  4096/1024.
- Expected duration: about 1.25 hours.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`.

## Safety

- Every other guest stays shut down: CT 121 `hermes`, CT 123 `gpu2` (it must stay stopped
  while CT 120 holds its card), CT 140 `kb-rag`, VM 300 `docker-host`, CT 200 and CT 201.
  Dropping the page cache is host-wide, so this run needs them off. Starting them again
  waits for the owner's go-ahead.
- On one card, `none` held the CPU-resident weights in 52.8 GB of pinned host memory and
  CT 123 was charged 79.7 GiB. Two cards at `-ncmoe 16` keep fewer weights on the host.
  Both fit CT 120's 160 GiB.
- The sweep starts no cell while the hottest DIMM is above 58 °C.
- `thermal-guard.sh` runs with `VMID=120` and watches both cards; on a trip the sweep
  starts no further cell.
- Keep clear of the Sunday 01:00 backup window.

## Environment

Intended: llama.cpp b11505 (release tarball), Mesa 26.2.4, kernel `7.0.14-22-pve`,
8 × 64 GB DDR4-3200, both V620s at 0 mV and 250 W, CT 120 with 48 cores and 160 GiB on
both cards after the cutover. The run's `environment.json` replaces this paragraph when
the run starts.

---

## Results

Not run.

## Deviations

## Conclusion
