# Qwen3.8-Flash-Next: the prefill slowdown with `dio` and the MTP head

Plan committed 2026-10-10 · Run 2026-10-10 · Status: planned

## Question

In the [batch with `dio` and the MTP head](2026-10-10-bench.md), prefill fell from
137–305 t/s to 61–91 t/s for 70 minutes. Through that stretch GTT held 1,024 MiB more
than usual, and the card's memory clock read 96 MHz in two thirds of prefill samples.
Earlier, VRAM had peaked 26 MiB short of full.

- **Cause:** was a buffer that llama-server wanted in VRAM evicted to GTT? Or did the
  memory clock drop on its own?
- **Which buffer:** if one was evicted, which one, and when?
- **Placement:** does a placement with more free VRAM avoid the slowdown? If so, does
  that configuration beat the deployed one in the full batch, by the owner's rule from
  the 2026-10-10 batch?

## What answers it

A **slow prefill** is a prompt of at least 1,500 new tokens prefilled below 110 t/s. In
the 2026-10-10 batch the slowest full-speed one ran at 137 t/s, and the fastest slow one
at 91.

`vram-residency-sampler.py` records once a second where llama-server's buffers sit:
- the kernel's per-process counters, including `amd-evicted-vram` (memory that asked
  for VRAM and sits in GTT);
- each buffer of 16 MiB or more that changes placement;
- the card's memory and core clocks, power, busy %, VRAM, GTT and temperatures.

Each request's prefill window is matched to those samples.

- **Eviction is the cause** if, in stages 1 and 2:
  - every slow prefill runs while `amd-evicted-vram` is above zero, or while a buffer
    that started in VRAM sits in GTT;
  - no prefill at 110 t/s or more runs in that state;
  - the 96 MHz memory clock in prefill comes with that state and not without it.
- **The memory clock alone is the cause** if slow prefills with the memory clock at
  96 MHz run with nothing evicted.
- **Which buffer:** the moved buffer's handle, size and the time it moved, matched
  against the buffer sizes llama-server logs at load: model, KV, compute and draft.
  Also the request running at that moment.
- **Placement:** per cell of stage 2, VRAM free at load and after the probe, evicted
  memory, and prefill and decode at ~5.8k tokens. A difference between cells counts when
  it is larger than the pass-to-pass spread of both.
- **Stage 3**, judged against the [2026-10-09 batch](2026-10-09-bench.md) by the criterion
  in the [2026-10-10 batch's Deviations](2026-10-10-bench.md#deviations), and showing
  whether any slow prefill or eviction occurs.
- A run with any DIMM sample at 66 °C is reported as capped.

## Configurations

| Stage | Cells |
| --- | --- |
| 1. Reproduce | The 2026-10-10 batch's configuration: `-ncmoe 36`, `--load-mode dio`, Q4_K_M head at n-max 3, one 64k slot; the workloads item only (agent sessions and document ingestion) |
| 2. Placement | `h35`, `h36`, `h37`: the same with `-ncmoe` 35, 36 and 37 ([cells](2026-10-10-prefill-slowdown.cells)), three passes, interleaved |
| 3. Full batch | `make bench GPU=2` at the placement chosen by the rule below |

Placement for stage 3, decided by stages 1 and 2:
- **Eviction is the cause, or neither stage shows a slow prefill:** the smallest `-ncmoe`
  above 36 whose stage-2 cell leaves at least 2,048 MiB free after the probe with nothing
  evicted. The README asks for 2,048 MiB; `-ncmoe 36` left 1,822 in the best-configuration
  record.
- **The memory clock alone is the cause:** `-ncmoe 36` with the card's `COMPUTE` power
  profile, which sets an 850 MHz minimum active memory clock. It is set on
  `0000:83:00.0` for the batch and put back to `BOOTUP_DEFAULT` afterwards.

The record behind each setting is the [2026-10-10 batch's](2026-10-10-bench.md#configurations).
One more CPU-resident expert layer costs about 1.8% of decode and 2.3% of prefill
([MTP record](2026-10-09-mtp.md)).

- **One slot, one card:** as in the 2026-10-10 batch (owner, 2026-10-10).
- **Without the head:** left out. `dio` alone leaves 2,076 MiB more VRAM free and showed no
  slowdown in the [best-configuration record](2026-10-10-best-config.md). The question is
  about this configuration.

## Controls

- Stage 1 repeats the 2026-10-10 batch's workloads item under the same code, build, card,
  prompts and configuration, so its timings compare with that run's.
- Stage 2's cells differ only in `-ncmoe`.
- Stage 3's reference is the 2026-10-09 batch, the deployed configuration.

## Method

The code is the branch head when each stage starts, staged with
[`push-harness.sh`](../../push-harness.sh); the batch also records its commit.

```bash
# Host: start the residency sampler (one unit per stage; stop it after the stage)
H=/root/harness/<sha12>/pro-v620/qwen38-flash-next
systemd-run --unit=vram-residency --collect /usr/bin/python3 $H/vram-residency-sampler.py \
  --pci 0000:83:00.0 --output /root/qwen38-flash-next/residency-<stage>.jsonl
systemctl stop vram-residency

# Stage 1 (and 3): install the configuration, as in the 2026-10-10 batch's Method, with
# MODEL_CPU_MOE set for the stage; the deployed file is still backed up in CT 123 as
# /etc/llamacpp-qwen38fn.env.pre-bench-20261010
pct exec 123 -- /usr/local/bin/llamacpp-qwen38fn-reload 65536 1
# Mac, repo root, stage 1: the workloads item only
ansible-playbook ansible/benchmark.yml -e @<main checkout>/ansible/secrets.yml -e gpu=2 \
  -e runtime=llamacpp -e allow_dirty=false -e suite=full -e run_agent_sessions=true \
  -e run_doc_ingest=true -e '{"regression_benchmarks": []}'
# Mac, stage 3: the full batch
make bench GPU=2 SECRETS=<main checkout>/ansible/secrets.yml
# Host, after stages 1 and 3: restore the deployed configuration
pct exec 123 -- cp -p /etc/llamacpp-qwen38fn.env.pre-bench-20261010 /etc/llamacpp-qwen38fn.env
pct exec 123 -- systemctl restart llamacpp-qwen38fn

# Stage 2, host
cd $H
VMID=123 ./thermal-guard.sh            # shell 1
VMID=123 CELLS=runs/2026-10-10-prefill-slowdown.cells DEPTHS="0,8000" DROP_CACHES=true \
  ./placement-sweep.sh                 # shell 2
```

- After each load, llama-server's buffer sizes are read from CT 123's journal, to name the
  buffers the sampler lists.
- Stage 1 uses the batch's own items, prompts and reloads; only the regression items are
  left out. The 2026-10-10 batch slowed 20 minutes into the same item.
- Stage 3 keeps the configuration if it meets the criterion, as the owner asked for the
  2026-10-10 batch (2026-10-10). Otherwise the deployed env file is restored.
- Expected duration: stage 1 about 1 to 2 hours, stage 2 about 45 minutes, stage 3 about 3
  to 3.5 hours.
- Raw data:
  - Batch runs: `pro-v620/results/llamacpp-gpu2/parallel-1/<run>/` on the Mac.
  - Sweep: `/root/qwen38-flash-next/sweep-<timestamp>/` on the host.
  - Residency samples: `/root/qwen38-flash-next/residency-<stage>.jsonl` on the host.

## Safety

- Every guest the stages do not use stays shut down: CT 120 `llamacpp`, CT 121 `hermes`,
  CT 140 `kb-rag`, VM 300 `docker-host` and CT 201. CT 200 runs for stages 1 and 3 and is
  shut down by the batch afterwards; stage 2 drops the host page cache, so it runs with
  CT 200 off. Starting any other guest waits for the owner's go-ahead.
- `gpu-thermal-watchdog` stops `llamacpp-qwen38fn` at 102 °C junction or 101 °C memory;
  `thermal-guard.sh` covers stage 2's sweep.
- `h35` may not fit: the [MTP record](2026-10-09-mtp.md) fitted the head at `-ncmoe 36`.
  A cell that does not load, or loads with buffers in GTT, is recorded as such; that is
  the condition stage 2 looks at.
- The sampler only reads sysfs, debugfs and `/proc`.
- Keep clear of the Sunday 01:00 backup window.

## Environment

Intended: as in the [2026-10-10 batch](2026-10-10-bench.md#environment). Replaced by each
stage's capture when it runs.

---

## Results

## Deviations

## Conclusion
