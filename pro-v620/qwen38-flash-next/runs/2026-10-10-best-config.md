# Qwen3.8-Flash-Next: `dio` and the MTP head together on one card

Plan committed 2026-10-10 · Run 2026-10-10 · Status: planned

## Question

Two changes ran faster than CT 123's deployed configuration on `0000:83:00.0`, each
measured alone against it:

- `--load-mode dio` prefilled 3.2–3.3 times as fast at `-ncmoe 34`, with the same decode
  and text ([load-modes record](2026-10-08-load-modes.md)).
- The Q4_K_M MTP head at `--spec-draft-n-max 3`, at `-ncmoe 36` under `auto`, raised
  single-stream decode by 40% (median of six, 14.2 to 19.9 t/s) and lowered prefill by
  6–10%, in CT 120 with two slots ([MTP record](2026-10-09-mtp.md)).

`make bench GPU=2` is the usage test and runs the best configuration found
([TEST-RECORDS.md](../../TEST-RECORDS.md)). Together, in CT 123 at its one slot:

- Does the pair load, fit and pass the output gate?
- Does `dio` keep its prefill gain with the head, and the head its decode gain with `dio`?
- Which configuration does the next `make bench GPU=2` run?

## What answers it

- **Gates,** per cell: it loads; shows no GTT growth during the probe (`dio` holds the
  CPU-resident weights in GTT, which the sweep exempts from its static threshold); keeps
  at least 1 GiB of VRAM free on `83:00.0` after the d8000 request; passes the output
  gate (`SUMMARY.md` flags degenerate output and the template-contract checks); has no
  DIMM sample at 66 °C; and does not trip the thermal guard.
- **Speed:** median decode per prompt class at d0 and d8000 and their median of six, and
  prefill per class at d8000. A difference counts when it is larger than the
  pass-to-pass spread of both cells.
- **Also reported:** draft acceptance, load time, VRAM and GTT, the container's memory,
  and per phase the card's power, clocks and busy % and the CPU cores in use.
- **The batch's configuration,** fixed now:
  - `dio-mtp3` if it passes every gate, its median of six is higher than `dio`'s and
    higher beyond the spread in at least four of the six prompt cells, and its d8000
    prefill is within 10% of `dio`'s in every class. 10% is the prefill the head cost
    under `auto`, about where its decode gain repays that loss on the batch's largest
    prompt (48k tokens in, a 640-token note out).
  - Otherwise `dio`, if it passes every gate.
  - If `dio-mtp3` fails a gate, the record says why, and the owner chooses between `dio`
    and the MTP record's `auto` with the head before the batch is planned.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| One GPU | `auto` (deployed: `-ncmoe 34`), `dio` (`-ncmoe 34`), `dio-mtp3` (`-ncmoe 36`, `dio`, Q4_K_M head at n-max 3) |

The cells are in [`2026-10-10-best-config.cells`](2026-10-10-best-config.cells).

- **Two GPUs:** left out. GPU 1 stays with CT 120 for Hermes (owner, 2026-10-10).
- **CPU only and optimized:** left out. The [configurations
  record](2026-10-08-configurations.md) measured both slower than `-ncmoe 34`, and no
  second model shares GPU 2.
- **`none`:** left out. It matched `dio`'s speed within the spread and loaded 6 s slower.
- **`auto` with the head:** left out. The MTP record measured it; it is only needed if
  `dio-mtp3` fails a gate (see above).
- **Speculative decoding:** the Q4_K_M head is the drafter the MTP record chose on one card
  (Q8_0 decoded within 2% and took 985 MiB more VRAM); n-max 3 had its highest median of
  six. That record found no other drafter llama.cpp loads for this model, and left n-gram
  speculation to a workload that edits text already in the context.

## Controls

- `auto` is CT 123's deployed configuration and the reference; it also repeats the
  load-modes record's `auto` cell.
- `dio` is the reference for the head. It runs at `-ncmoe 34`, so `dio-mtp3` against it
  includes the two extra CPU-resident layers the head needs, as a deployment would.
- Cells run round-robin, three passes each, in one container.

## Method

Harness: `placement-sweep.sh` at the branch head when the run starts (its commit is in
the run's `manifest.json`), staged with [`push-harness.sh`](../../push-harness.sh). The
sweep's method rules are in its header and in [Benchmark
tools](../README.md#benchmark-tools).

```bash
# Host; CT 123 holds 0000:83:00.0
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
# Shell 1
VMID=123 ./thermal-guard.sh
# Shell 2
VMID=123 CELLS=runs/2026-10-10-best-config.cells DEPTHS="0,8000" DROP_CACHES=true \
  ./placement-sweep.sh
```

- `DROP_CACHES=true`: before every load the sweep stops the server and drops the host
  page cache, as in the load-modes record, so every load is cold and `auto`'s page cache
  is not held beside a `dio` cell's pinned weights.
- Sweep defaults: `REPS=3`, `N_PREDICT=256`, prompt classes code, list and prose (d8000 is
  ~5.8k tokens); ctx 65536, parallel 1, 16 threads, q8_0 KV, batch 4096/1024, projector
  on the CPU. The sweep restores CT 123's env file and service when it ends.
- Expected duration: about 1 hour.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`.

## Safety

- The sweep starts no cell while the hottest DIMM is above 58 °C (`DIMM_START_MAX_C`).
  A cell with any DIMM sample at 66 °C ran at a third of the memory bandwidth and is
  invalid.
- Every other guest stays shut down: CT 120 `llamacpp`, CT 121 `hermes`, CT 140 `kb-rag`,
  VM 300 `docker-host`, CT 200 and CT 201. Dropping the page cache is host-wide, so this
  run needs them off. Starting them again waits for the owner's go-ahead.
- `dio` pins 52.8 GB at `-ncmoe 34`, and CT 123 held 79.2 GiB; at `-ncmoe 36` two more
  layers' experts, about 3 GiB, stay in RAM, within CT 123's 120 GiB. A load the
  container cannot hold is recorded as a failed cell.
- `thermal-guard.sh` runs with `VMID=123`; on a trip the sweep starts no further cell.

## Environment

Intended: llama.cpp b11505 (`ff5888f99`, release tarball), Vulkan, Mesa 26.2.4 (kisak),
kernel `7.0.14-22-pve`, 8 × 64 GB DDR4-3200. CT 123 with 24 cores and 120 GiB holding
`0000:83:00.0` at 0 mV and 250 W. Replaced by the sweep's `environment.json` when the run
starts.

---

## Results

## Deviations

## Conclusion
