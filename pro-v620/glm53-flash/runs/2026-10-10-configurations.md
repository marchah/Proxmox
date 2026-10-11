# GLM-5.3-Flash: the fastest configuration on one card, two cards and CPU only

Plan committed 2026-10-10 · Run not started · Status: planned

## Question

GLM-5.3-Flash ([model notes](../README.md)) carries 189.9 GB of routed experts and
9.8 GB of other weights at UD-Q4_K_XL, so one V620 holds the non-expert weights and a few
expert layers, and host RAM serves the rest. On llama.cpp b11505, Vulkan, in CT 123 with
GPU 2 (`0000:83:00.0`), and with both cards in stage 8:

- **Load and contract:** does b11505 load the model and its MTP block on RADV? Do two
  slots work, given #27773's note that several sequences need `--kv-unified`? The template
  opens `<think>` on every turn and has no off switch. Does `--reasoning off` still return
  clean `content` without a reasoning block?
- **What the card holds:** how much VRAM do the non-expert weights take, the KV cache per
  context and type, the compute buffer per micro-batch, and the MTP block with its draft
  context? #29950 reports the compute buffer growing with context × micro-batch, and #28433
  the draft context sized from the total context. These set how many 4,176 MiB expert
  layers fit.
- **Prefill:** Flash-Next's `dio` prefill (391–397 t/s at ~5.8k tokens, micro-batch 1024,
  52.8 GB of experts pinned in host memory; [load-modes
  record](../../qwen38-flash-next/runs/2026-10-08-load-modes.md)) is consistent with
  uploading the host-resident experts once per micro-batch at about 20 GB/s. That is
  inferred, not measured. GLM keeps about 3.3 times those bytes in host memory, so at
  micro-batch 1024 the same mechanism would hold prefill near 120 t/s, and a larger
  micro-batch would raise that cap in proportion. Which load mode and micro-batch prefill
  fastest, and what do they cost in expert layers and decode?
- **Decode:** decode reads most of each token's experts from host RAM. Which thread count
  decodes fastest at one and two streams? How much do the card's expert layers add over
  all experts in RAM?
- **CPU only:** with the whole model in host RAM and no card, how fast do decode and
  prefill run, at CPU only's own best thread count?
- **MTP:** with the built-in MTP block, which draft length (`--spec-draft-n-max`) decodes
  fastest at one and two streams? What share of drafts is accepted? Does the best length
  beat the best configuration without it, including on short replies, where Flash-Next's
  head lost ([short-reply record](../../qwen38-flash-next/runs/2026-10-10-short-reply-decode.md))?
- **Context:** how many expert layers do 128k and 256k contexts cost? How do decode and
  prefill hold up at depth, given that the KDA layers keep a fixed state and the DSA
  indexer attends to at most 2,048 pools of four tokens?
- **Two cards:** GPU 1 adds room for about five more expert layers (an estimate stage 8
  measures). What does that add to decode and prefill, under each load mode and with MTP,
  against the best one-card configuration?

## What answers it

A difference counts when it is larger than the pass-to-pass spread of both cells. Any
cell with a DIMM sample at 66 °C is invalid. Stages 1, 2, 5, 8a and 8b take one pass to
choose what the timed stages measure; their figures are reported but not compared by the
spread rule.

- **Stage 1, screen** (every routed expert in RAM):
  - Whether each cell loads and answers, and passes the output gate.
  - The probe's `--contract` result.
  - VRAM and GTT after the probe, per cell, and the buffer sizes in each cell's load log.
    Together they give the non-expert weights, KV per context (64k, 128k, 256k) and type
    (f16, q8_0), the compute buffer at micro-batch 1024, 2048 and 4096, the MTP block and
    its draft context, and a second slot.
  - Two hand checks: tool calls (streamed and not), and one image request with and
    without MTP (#30204).
  - **KV type:** f16 unless q8_0 frees at least one expert layer (4,176 MiB) at 65536 and
    its text reads coherently. The choice holds for every later stage.
  - **Reasoning:** if `--reasoning off` leaves a reasoning block, the screen repeats
    `base` with `--reasoning-budget 0`. Later stages use whichever returns clean `content`
    with no reasoning block. If neither does, the record says so; throughput rows use
    `/completion`, which applies no template, so they stay valid.
  - **Two slots:** `--kv-unified` joins every two-slot cell if `base-p2-nokvu` fails or
    drops a stream.
- **Stage 2, fit:** per variant, the smallest `--n-cpu-moe` that leaves at least
  3,072 MiB free right after load, with requested-minus-resident VRAM at zero through a
  d8000 code request at one and two streams. Flash-Next's head left 1,822 MiB free after a
  probe and still had buffers created in GTT ([prefill-slowdown
  record](../../qwen38-flash-next/runs/2026-10-10-prefill-slowdown.md)). Variants:
  - no speculation at micro-batch 1024;
  - no speculation at the largest micro-batch from stage 1 that costs at most one expert
    layer more than 1024;
  - MTP at n-max 8 with block 45's experts on the card;
  - MTP at n-max 8 with block 45's experts in RAM.
  The MTP fit is at the scan's longest draft: Flash-Next's head grew about 225 MiB per
  draft token, and a fit at n-max 3 spilled at 5–8.
- **Stage 3, load mode and micro-batch** (timed):
  - Cells: `auto` and `dio` at micro-batch 1024, and `dio` at stage 2's larger micro-batch,
    each at its fit; `dio-experts-ram`; `cpu`.
  - Per cell: median single-stream decode per prompt class at d0 and d8000, prefill at
    d8000, and two-stream aggregate decode.
  - `SUMMARY.md`'s utilization per phase: card power against the 250 W cap, clocks and
    CPU cores.
  - **Next stages use** the GPU cell with the highest median d8000 prefill among those
    whose median single-stream decode is within the spread of the best.
- **Stage 4, threads** (timed): 16, 24 and 32 threads on stage 3's choice and on CPU
  only. **Next stages use** the count with the highest median single-stream decode across
  the six prompt cells. If another count wins the two-stream aggregate beyond the spread,
  the record reports both. CPU only's best count, by the same rule, is reported as CPU
  only's result: its decode and prefill against the best GPU configuration's.
- **Stage 5, MTP screen and scan** (one pass):
  - **Block placement:** block 45's experts on the card or in RAM, at n-max 3. The higher
    median single-stream decode wins; within 2%, the one with more VRAM free.
  - **Scan:** n-max 1 to 8 at one and two streams, with decode and acceptance per length.
    The scan has gone far enough once decode at both stream counts is at least 10% below
    its best length's. If not by 8, a second scan adds 10, 12 and 16 after a refit.
- **Stage 6, MTP timed:**
  - Cells: the scan's best single-stream length and the lengths one below and above it;
    the best two-stream length if it differs; the no-speculation control at the same
    placement; the best configuration from stages 3–4.
  - Measures: the stage 3 measures, plus `SUMMARY.md`'s draft acceptance per prompt cell
    and at two streams.
  - A short-reply sweep: 32-token replies at d0 and d700 (~500 tokens), the best MTP cell
    against the best no-speculation configuration.
  - Greedy verification keeps the target's choices, so each MTP cell's text is compared
    with its control's per prompt cell, and any difference is read for sense.
  - **MTP joins the best configuration** if all four hold:
    1. median single-stream decode across the six prompt cells beats both the
       same-placement control and the best no-speculation configuration;
    2. two-stream aggregate decode is not lower than the best no-speculation
       configuration's;
    3. d8000 prefill is within 10% of the best no-speculation configuration's in every
       class;
    4. 32-token replies are not slower at either depth.
    If (1) holds and another fails, the record names the failure and the owner decides.
- **Stage 7, context** (timed): the best configuration at 65536, 131072 and 262144, each
  at its own fit. Per context: the VRAM it costs, in MiB and in expert layers, and decode
  and prefill at each depth it holds. The choice of context is left to the usage test's
  plan.
- **Stage 8, two cards** (`ct123-test-host.sh two-card` gives CT 123 GPU 1 as well):
  - **8a, fit and split** (one pass): the stage 2 rule on each card, for no speculation at
    stage 3's micro-batch and for MTP at n-max 8 with stage 5's block placement. The split
    starts from the sweep's rule with 46 blocks and moves one block at a time towards the
    card with more VRAM free. One cell runs `-sm tensor` at the no-speculation fit; if its
    median single-stream decode beats the layer split's by more than 2%, it joins 8c.
  - **8b, MTP scan** (one pass): stage 5's scan on two cards.
  - **8c, timed:** `2c-auto` and `2c-dio` at the no-speculation fit; `2c-mtp` with `dio`
    at 8b's best single-stream length, and at its best two-stream length if that differs;
    the tensor-split cell if 8a qualifies it; and `1c-best`, the best one-card
    configuration with only GPU 2 visible (`VK_DEVICES`).
  - `1c-best` stands in for the one-card results if its median d8000 prefill and
    single-stream decode are within the spread of the same configuration's stage 6 or 7
    cell. If not, the record says the two-card container changes one-card results.
  - **What the second card adds:** the best two-card cell against `1c-best`, on median
    single-stream decode across the six prompt cells, two-stream aggregate decode, d8000
    prefill, and the expert layers each card holds. The stage 3 rule picks the best
    no-speculation two-card cell; `2c-mtp` replaces it if its median single-stream decode
    is higher and it meets stage 6's conditions 2 and 3 against it. Whether GPU 1 goes to
    GLM stays the owner's decision.

The best configuration is the stages' combined choice. The full benchmark batch on it
gets its own record and plan. Whether to deploy GLM-5.3-Flash is a separate decision.

## Configurations

CT 123 runs every stage. It already holds GPU 2 with b11505 and Mesa 26.2.4 and binds
the model store, and GPU 2 is the card a GLM deployment could use while GPU 1 stays with
CT 120. All of Flash-Next's one-card records were measured on it, so the two models'
results compare on the same card.

| Standard configuration | Cells |
| --- | --- |
| One GPU | Stages 1–7 on `0000:83:00.0`, and `1c-best` in stage 8 |
| Two GPUs | Stage 8: layer split (and tensor split if it qualifies), `auto`, `dio` and MTP |
| CPU only | `cpu` in stages 1, 3 and 4: the whole model in host RAM, `--device none`, at 16, 24 and 32 threads |
| Optimized | `dio-experts-ram` in stage 3: every routed expert in RAM (`-ncmoe 46`), leaving the VRAM stage 1 measures free for a second model |
| Speculative decoding | The built-in MTP block (GGUF block 45, `--spec-type draft-mtp`, no separate file), stages 5–6 |

Stage 1's cells are in
[`2026-10-10-configurations-screen.cells`](2026-10-10-configurations-screen.cells). Each
later stage's cells follow from the stage before and are committed before it runs.

- **DFlash 2:** left out. Drafters exist (`incoai/GLM-5.3-Flash-DFlash2`, with GGUFs from
  `Anbeeld` and `vcruz305`), but `--spec-type draft-dflash` with a glm5-next target aborts on
  the first request (#30093, open). The Anbeeld GGUFs name the BeeLlama.cpp fork.
- **DFlash** (`modal-labs/GLM-5.3-Flash-DFlash`): left out; safetensors only, and it would
  run through the same `draft-dflash` path.
- **DSpark** (`RedHatAI/GLM-5.3-Flash-speculator.dspark-preview`): left out; a preview in
  safetensors with no GGUF.
- **EAGLE-3:** none found on Hugging Face (2026-10-10).
- **MTP on CPU only:** left out, as for Flash-Next. CPU only is the reference for what
  the cards add; the MTP block's gain is measured where it would be deployed.
- **N-gram speculation:** left out. The probe measures fresh generation; n-gram drafts pay
  off on edits of text already in the context, which the usage test's agent sessions
  exercise.
- **Other quantizations:** left out. UD-Q4_K_XL is Unsloth's dynamic 4-bit, the same
  family and level as Flash-Next's served quantization.
  - Under `dio` its host-resident experts, about 172–176 GB at three layers on the card,
    fit the 251.8 GiB GTT limit (`mem_info_gtt_total`) with room left.
  - UD-IQ4_XS (156.8 GB) and UD-Q3_K_XL (147.5 GB) would read fewer bytes per token, at
    top-1 agreement Unsloth puts at 88.2% and 86.3% against 92.2%. A follow-up record can
    measure one if decode here is too slow.
  - `ggml-org/GLM-5.3-Flash-GGUF` Q4_K (181.4 GB, MTP as a separate file) stores every
    routed expert at Q4_K, and its README names an imatrix only for its Q2 quantizations.
- **MoE expert cache:** left out. On Flash-Next every cache configuration decoded slower
  than the same card without one ([utilization
  record](../../qwen38-flash-next/runs/2026-10-08-utilization.md)), and RADV's 4 GiB
  allocation limit caps it.
- **ROCm:** left out; it needs a passthrough VM, and CT 123 is a container.

## Controls

- One binary, one set of model files and one time window per stage. Every one-card cell
  runs on `0000:83:00.0`, including `1c-best` in the two-card container.
- Cells run round-robin. Timed stages (3, 4, 6, 7) take three passes.
- Each MTP cell has a no-speculation control at its own placement and the best
  no-speculation configuration.
- From stage 2 on, every GPU cell except stage 7's loads at `--parallel 2`, so one load
  gives the single-stream and two-stream figures. The context totals 65536, shared by the
  slots. Stage 7 loads one slot.
- Output: the probe's greedy settings and 8-gram gate. Each prompt cell's text is
  compared across cells.
- Spill: `vram-residency-sampler.py` runs for the whole run, one per card in stage 8.
  Read requested-minus-resident VRAM, not the GTT total, which under `dio` holds the
  pinned experts.
- In stage 8, `dio`'s pinned memory is charged to Vulkan0. With both cards visible that is
  GPU 1 ([two-card load-mode
  record](../../qwen38-flash-next/runs/2026-10-09-load-modes-two-cards.md)); `1c-best`
  sees only GPU 2, so for it GPU 2 is Vulkan0.

## Method

### Harness

Built with this plan, in [`pro-v620/glm53-flash/`](..) and the shared sweep in
[`pro-v620/qwen38-flash-next/`](../../qwen38-flash-next/):

- `glm53f-download.sh` checks the six UD-Q4_K_XL shards and `mmproj-F16.gguf` in
  `/models/hf/glm-5.3-flash/` against the Hub's SHA-256 at revision `a38483c8`, and
  downloads what is missing. The files were already in the store on 2026-10-10.
- `install.sh` installs `glm53f.env`, the launcher `llamacpp-serve-glm53f`, the reload
  helper and the `llamacpp-glm53f` unit (port 1234, alias `glm-5.3-flash`) in CT 123. The
  unit conflicts with Flash-Next's and Qwen3.6's units, so it never loads beside them.
- `ct123-test-host.sh` switches CT 123 between `one-card`, `two-card` and `restore`. It
  changes CT 123's limits, its units, GPU 1's passthrough, CT 120's autostart and the
  watchdog map together.
- `placement-sweep.sh` takes `UNIT`, `N_BLOCKS` and `CONTRACT_EFFORTS` and a `VK_DEVICES`
  cell key. `thermal-guard.sh` takes `UNIT`, and `capture-env.sh` reads any
  `llamacpp-*` unit's env file. `placement-probe.py --contract` takes the effort values
  and records any reasoning block.

### Run

```bash
# Mac
./pro-v620/push-harness.sh       # prints /root/harness/<sha12>/pro-v620

# Host, before stage 1
H=/root/harness/<sha12>/pro-v620
cd $H/glm53-flash
VMID=123 ./install.sh --download          # verifies the model files (unit glm53f-dl)
./ct123-test-host.sh one-card             # after glm53f-dl reports DONE

# Shell 1; restart it after each ct123-test-host.sh call, since it reads the cards at start
cd $H/qwen38-flash-next && VMID=123 UNIT=llamacpp-glm53f ./thermal-guard.sh
# Shell 2, one sampler file per stage (and per card in stage 8)
systemd-run --unit=vram-residency --collect /usr/bin/python3 \
  $H/qwen38-flash-next/vram-residency-sampler.py --pci 0000:83:00.0 \
  --output /root/glm53-flash/residency-<stage>.jsonl
# Shell 3, per stage, with that stage's cells file and settings from the table below
cd $H/qwen38-flash-next
VMID=123 UNIT=llamacpp-glm53f N_BLOCKS=46 CONTRACT_EFFORTS=none,low,high,max \
  CELLS=../glm53-flash/runs/2026-10-10-configurations-<stage>.cells \
  OUT_DIR=/root/glm53-flash/sweep-<stage>-$(date -u +%Y%m%dT%H%M%SZ) \
  <settings> ./placement-sweep.sh

# Host, before stage 8 (CT 120 must be stopped), and after the last stage
cd $H/glm53-flash && ./ct123-test-host.sh two-card
cd $H/glm53-flash && ./ct123-test-host.sh restore   # also if the run stops early
systemctl stop vram-residency
```

| Stage | `<stage>` | `<settings>` |
| --- | --- | --- |
| 1 | `screen` | `REPS=1 DEPTHS=0,8000 PROBE_CLASSES=code` |
| 2 | `fit` | `REPS=1 DEPTHS=8000 PROBE_CLASSES=code` |
| 3 | `load` | `DEPTHS=0,8000 CONC_REPS=3` |
| 4 | `threads` | `DEPTHS=0,8000 CONC_REPS=3` |
| 5 | `mtp-scan` | `REPS=1 DEPTHS=0,8000` |
| 6 | `mtp` | `DEPTHS=0,8000 CONC_REPS=3` |
| 6, short replies | `short` | `N_PREDICT=32 DEPTHS=0,700` |
| 7 | `context` | `PROBE_CLASSES=code`; depths per cell |
| 8a | `2c-fit` | `REPS=1 DEPTHS=8000 PROBE_CLASSES=code` |
| 8b | `2c-mtp-scan` | `REPS=1 DEPTHS=0,8000` |
| 8c | `2c` | `DEPTHS=0,8000 CONC_REPS=3` |

- Sweep defaults: `N_PREDICT=256`, classes code, list and prose, 16 threads (stage 4
  varies it), the projector on the CPU, batch 4096. Micro-batch is per cell. The
  concurrency probe runs two streams at d0, each a different prompt.
- Stage 7's cells set their own depths, code class only: 0, 8000, 82000 (~59k tokens) at
  every context, 165000 (~119k) at 131072 and 262144, and 330000 (~237k) at 262144.
- `two-card` prints the Vulkan device order in CT 123; `1c-best`'s `VK_DEVICES` is GPU 2's
  index there, and its cell JSON must show `active_card` `0000:83:00.0`.
- After `restore`, Flash-Next must load and answer with its free VRAM as deployed (about
  3.2 GiB) and nothing outside VRAM.
- Expected duration, from Flash-Next's cell times scaled by the prefill estimate above:
  - stage 1: about 1.5 h;
  - stage 2: about 1 h;
  - stage 3: 3.5 h;
  - stage 4: 4.5 h, the CPU-only cells about half of it;
  - stage 5: 2 h;
  - stage 6: 4 h;
  - stage 7: 4–5 h;
  - stage 8: about 6 h.
  Each stage is a separate session, with its cells committed first.
- Raw data: `/root/glm53-flash/sweep-<stage>-<timestamp>/` and the residency files, on the
  host.

## Safety

- At plan time every guest but CT 123 is stopped: CT 120 `llamacpp`, CT 121 `hermes`,
  CT 140 `kb-rag`, CT 200 `bench-runner`, CT 201 `llamacpp-builder` and VM 300
  `docker-host`. They stay down for the whole run, and starting any of them again waits for
  the owner.
- CT 123's Flash-Next service is disabled for the run, so a container restart cannot start
  two models on one card. `ct123-test-host.sh restore` re-enables it.
- Stage 8: `two-card` refuses unless CT 120 is stopped, and turns CT 120's autostart off
  while CT 123 holds GPU 1, so a host reboot cannot put two servers on one card. `restore`
  detaches GPU 1 and puts CT 120's autostart back; CT 120 stays stopped.
- Memory: CT 123 gets 240 GiB for the run, enough for the model under `auto` page cache or
  `dio` pinning. `dio` pins at most 190 GB (`base-dio`, every expert in RAM), within the
  251.8 GiB GTT limit.
- `thermal-guard.sh` runs with `VMID=123 UNIT=llamacpp-glm53f`, and the host watchdog maps
  each card CT 123 holds to the GLM unit.
  On a trip the sweep starts no further cell, and the unit stays stopped until cooling is
  checked.
- The sweep starts no cell while the hottest DIMM is above 58 °C. Decode here reads more
  host memory per token than Flash-Next did. If two cells in one stage are invalidated by a
  66 °C sample, the stage stops and the owner decides on airflow before it reruns.
- Keep clear of the Sunday 01:00 backup window.

## Environment

Intended at plan time; replaced by `environment.json` when the run starts.

- llama.cpp b11505 (`ff5888f99`, release tarball, `/opt/llamacpp/llama-b11505`).
- Mesa 26.2.4 (kisak-mesa), kernel `7.0.14-22-pve`, `schedutil`.
- 8 × 64 GB DDR4-3200.
- CT 123, 48 cores and 240 GiB for the run, holding `0000:83:00.0` (`unique_id`
  `99b104541144b36c`), and in stage 8 also `0000:03:00.0` (`150e6a6800f84ebe`), each on
  PCIe 4.0 x16 at 0 mV and 250 W.
- Model: `unsloth/GLM-5.3-Flash-GGUF` UD-Q4_K_XL at revision `a38483c8`.

---

## Results

## Deviations

## Conclusion
