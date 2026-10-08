# Qwen3.8-Flash-Next: cold load modes on one card

Plan committed 2026-10-08 · Run not started · Status: planned

## Question

llama.cpp b11505's `--load-mode` offers `auto` (mmap), `none`, `dio` (direct I/O),
`mlock` and `mmap+mlock`. Loading cold from the NVMe store at CT 123's production
placement (`-ncmoe 34`, one V620):

- How long does each mode take to reach a healthy `/health`?
- How is the model charged to CT 123's 120 GiB memory limit: anonymous memory or page
  cache?
- Do decode and prefill change after the load?

The 2026-09 study's governor trial is not repeated: `cpu-governor.service` sets
`schedutil`, `capture-env.sh` records it in every run, and the `powersave` result was a
1500 MHz pin rather than a tuning choice.

## What answers it

- Every cell loads, shows no GTT spill and passes the output gate (`SUMMARY.md` flags
  degenerate output and passes that disagree).
- **Load time:** median seconds to a healthy `/health` per mode. A difference counts
  when it is larger than the pass-to-pass spread of both cells.
- **Memory:** the container's total, anonymous and page-cache memory after the load.
- **Speed:** median decode per prompt class at d0 and d8000, and prefill at d8000,
  against `auto`, by the same rule. d0 is the first request after each load.
- A cell with any DIMM at 66 °C is reported as capped and left out of the comparisons.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| One GPU | `auto` (production), `none`, `dio`, each loaded cold at the production placement |

The cells are in [`2026-10-08-load-modes.cells`](2026-10-08-load-modes.cells).

- **Two GPUs, CPU only and optimized:** left out. Every configuration reads the same four
  shards; only the split between VRAM and RAM differs, so one configuration answers the
  question.
- **`mlock` and `mmap+mlock`:** left out. The unit runs with systemd's default 8 MiB
  `LimitMEMLOCK`, so both would fall back to unlocked memory without a unit change, and
  the container's own limit is about 63 GiB. Locking matters under memory pressure,
  which a run with every other guest shut down cannot create.

## Controls

- `auto` is CT 123's production load mode and the reference.
- Cells run round-robin, three passes each, in one container.

## Method

Harness: `placement-sweep.sh` at the commit that adds this record, staged with
[`push-harness.sh`](../../push-harness.sh). The sweep's method rules are in its header
and in [Benchmark tools](../README.md#benchmark-tools).

```bash
# Host; CT 123 holds 0000:83:00.0
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
# Shell 1
VMID=123 ./thermal-guard.sh
# Shell 2
VMID=123 CELLS=runs/2026-10-08-load-modes.cells DEPTHS="0,8000" DROP_CACHES=true \
  ./placement-sweep.sh
```

- `DROP_CACHES=true`: before every load the sweep stops the server and drops the host
  page cache, so each load reads the 111 GB from the NVMe store (`BIWIN NV7400 2TB`,
  ext4 on LVM). With the cache dropped, CT 123 is the first reader, so the page cache is
  charged to it.
- Load time is wall-clock from the service restart to the first healthy `/health`, polled
  every second.
- Sweep defaults: `REPS=3`, `N_PREDICT=256`, prompt classes code, list and prose (d8000 is
  ~5.8k tokens); ctx 65536, parallel 1, 16 threads, q8_0 KV, batch 4096/1024, projector
  on the CPU.
- Expected duration: about 1 hour.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`.

## Safety

- Every other guest stays shut down: CT 120 `llamacpp`, CT 121 `hermes`, CT 140 `kb-rag`,
  VM 300 `docker-host`, CT 200 and CT 201. Dropping the page cache is host-wide, so this
  run needs them off. Starting them again waits for the owner's go-ahead.
- `none` and `dio` copy the CPU-resident weights into anonymous memory: about 80 GB at
  `-ncmoe 34` (111 GB of shards less ~28 GB on the card), within CT 123's 120 GiB. A load the container cannot hold is recorded
  as a failed cell.
- `thermal-guard.sh` runs with `VMID=123`; on a trip the sweep starts no further cell.
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
