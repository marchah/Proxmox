# GLM-5.3-Flash: the fastest configuration on one card, two cards and CPU only

Plan committed 2026-10-10 · Run 2026-10-10 to 2026-10-12 · Status: done

## Question

GLM-5.3-Flash ([model notes](../README.md)) carries 189.9 GB of routed experts and
9.8 GB of other weights at UD-Q4_K_XL, so one V620 holds the non-expert weights and a few
expert layers, and host RAM serves the rest. On llama.cpp b11505, Vulkan, in CT 123 with
GPU 2 (`0000:83:00.0`), and with both cards in stage 6:

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
- **Context:** how many expert layers do 128k and 256k contexts cost? How do decode and
  prefill hold up at depth, given that the KDA layers keep a fixed state and the DSA
  indexer attends to at most 2,048 pools of four tokens?
- **Two cards:** GPU 1 adds room for about five more expert layers (an estimate stage 6
  measures). What does that add to decode and prefill, under each load mode, against the
  best one-card configuration?
- **MTP, last:** on the configuration the stages before it settle, which draft length
  (`--spec-draft-n-max`) decodes fastest at one and two streams? What share of drafts is
  accepted? Does the best length beat the same configuration without it, including on
  short replies, where Flash-Next's head lost ([short-reply
  record](../../qwen38-flash-next/runs/2026-10-10-short-reply-decode.md))?

## What answers it

A difference counts when it is larger than the pass-to-pass spread of both cells. Any
cell with a DIMM sample at 66 °C is invalid. Stages 1, 2, 6a, 7a and 7b take one pass to
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
- **Stage 2, fit** (no speculation): per variant, the smallest `--n-cpu-moe` that leaves at
  least 3,072 MiB free right after load, with requested-minus-resident VRAM at zero through
  a d8000 code request at one and two streams. Flash-Next's head left 1,822 MiB free after a
  probe and still had buffers created in GTT ([prefill-slowdown
  record](../../qwen38-flash-next/runs/2026-10-10-prefill-slowdown.md)). Variants:
  - micro-batch 1024;
  - the largest micro-batch from stage 1 that costs at most one expert layer more than 1024.
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
- **Stage 5, context** (stages 3–4's configuration, one slot):
  - **5a, fit** (one pass): the stage 2 rule at one slot, with requested-minus-resident VRAM at
    zero through the d8000 request and the context's deepest request.
    - 65536 is checked at `-ncmoe 44`, and 131072 and 262144 at 44 and 46.
    - Without MTP, 45 and 46 are the same placement, so 46 (every expert in RAM) is the step
      back from 44.
    - A context that does not fit at 46 is left out of 5b, and the record says so.
  - **5b, timed:** each context at its 5a fit. Per context: the VRAM it costs, in MiB and in
    expert layers, and decode and prefill at each depth it holds. Stage 7 runs at the context
    the owner picks from these results, and at 65536 without a pick.
- **Stage 6, two cards** (no speculation; `ct123-test-host.sh two-card` gives CT 123 GPU 1
  as well; context 65536, as in stages 3–4):
  - **6a, fit and split** (one pass): the stage 2 rule on each card at stage 3's
    micro-batch. The split starts from the sweep's rule with 46 blocks and moves one block
    at a time towards the card with more VRAM free. One cell runs `-sm tensor` at the fit;
    if its median single-stream decode beats the layer split's by more than 2%, it joins 6b.
  - **6b, timed:** `2c-auto` and `2c-dio` at the fit; the tensor-split cell if 6a
    qualifies it; and `1c-best`, stages 3–4's configuration with only GPU 2 visible
    (`VK_DEVICES`).
  - `1c-best` stands in for the one-card results if its median d8000 prefill and
    single-stream decode are within the spread of the same configuration's stage 4 cell.
    If not, the record says the two-card container changes one-card results.
  - **What the second card adds:** the best two-card cell by the stage 3 rule against
    `1c-best`, on median single-stream decode across the six prompt cells, two-stream
    aggregate decode, d8000 prefill, and the expert layers each card holds. Whether GPU 1
    goes to GLM stays the owner's decision, and with it whether stage 7 also runs on two
    cards.
- **Stage 7, MTP** (last, on the configuration stages 2–6 settle):
  - **7a, fit** (one pass): the stage 2 rule at stage 5's context, for MTP at n-max 8 with
    block 45's experts on the card and in RAM. The fit is at the scan's longest draft:
    Flash-Next's head grew about 225 MiB per draft token, and a fit at n-max 3 spilled at
    5–8. The draft context grows with the total context (#28433), so this fit holds only
    at the context it was measured at.
  - **7b, block placement and scan** (one pass): block 45's experts on the card or in RAM, at
    n-max 3; the higher median single-stream decode wins, and within 2% the one with more
    VRAM free. Then n-max 1 to 8 at one and two streams, with decode and acceptance per
    length. The scan has gone far enough once decode at both stream counts is at least 10%
    below its best length's. If not by 8, a second scan adds 10, 12 and 16 after a refit.
  - **7c, timed:** the scan's best single-stream length and the lengths one below and above
    it; the best two-stream length if it differs; the no-speculation control at the same
    placement; the best configuration from stages 3–5. Measures: the stage 3 measures, plus
    `SUMMARY.md`'s draft acceptance per prompt cell and at two streams. A short-reply sweep:
    32-token replies at d0 and d700 (~500 tokens), the best MTP cell against the best
    no-speculation configuration. Greedy verification keeps the target's choices, so each
    MTP cell's text is compared with its control's per prompt cell, and any difference is
    read for sense.
  - **MTP joins the best configuration** if all four hold:
    1. median single-stream decode across the six prompt cells beats both the
       same-placement control and the best no-speculation configuration;
    2. two-stream aggregate decode is not lower than the best no-speculation
       configuration's;
    3. d8000 prefill is within 10% of the best no-speculation configuration's in every
       class;
    4. 32-token replies are not slower at either depth.
    If (1) holds and another fails, the record names the failure and the owner decides.

The best configuration is the stages' combined choice. The full benchmark batch on it
gets its own record and plan. Whether to deploy GLM-5.3-Flash is a separate decision.

## Configurations

CT 123 runs every stage. It already holds GPU 2 with b11505 and Mesa 26.2.4 and binds
the model store, and GPU 2 is the card a GLM deployment could use while GPU 1 stays with
CT 120. All of Flash-Next's one-card records were measured on it, so the two models'
results compare on the same card.

| Standard configuration | Cells |
| --- | --- |
| One GPU | Stages 1–5 and 7 on `0000:83:00.0`, and `1c-best` in stage 6 |
| Two GPUs | Stage 6: layer split (and tensor split if it qualifies), `auto` and `dio`; stage 7 too if the owner keeps two cards in play |
| CPU only | `cpu` in stages 1, 3 and 4: the whole model in host RAM, `--device none`, at 16, 24 and 32 threads |
| Optimized | `dio-experts-ram` in stage 3: every routed expert in RAM (`-ncmoe 46`), leaving the VRAM stage 1 measures free for a second model |
| Speculative decoding | The built-in MTP block (GGUF block 45, `--spec-type draft-mtp`, no separate file), stage 7, last before the usage test |

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
- From stage 2 on, every GPU cell except stage 5's loads at `--parallel 2`, so one load
  gives the single-stream and two-stream figures. The context totals 65536, shared by the
  slots. Stage 5 loads one slot.
- Output: the probe's greedy settings and 8-gram gate. Each prompt cell's text is
  compared across cells.
- Spill: `vram-residency-sampler.py` runs for the whole run, one per card in stage 6.
  Read requested-minus-resident VRAM, not the GTT total, which under `dio` holds the
  pinned experts.
- In stage 6, `dio`'s pinned memory is charged to Vulkan0. With both cards visible that is
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
# Shell 2, one sampler file per stage (and per card in stage 6)
systemd-run --unit=vram-residency --collect /usr/bin/python3 \
  $H/qwen38-flash-next/vram-residency-sampler.py --pci 0000:83:00.0 \
  --output /root/glm53-flash/residency-<stage>.jsonl
# Shell 3, per stage, with that stage's cells file and settings from the table below
cd $H/qwen38-flash-next
VMID=123 UNIT=llamacpp-glm53f N_BLOCKS=46 CONTRACT_EFFORTS=none,low,high,max \
  CELLS=../glm53-flash/runs/2026-10-10-configurations-<stage>.cells \
  OUT_DIR=/root/glm53-flash/sweep-<stage>-$(date -u +%Y%m%dT%H%M%SZ) \
  <settings> ./placement-sweep.sh

# Host, before stage 6 (CT 120 must be stopped), and after the last stage
cd $H/glm53-flash && ./ct123-test-host.sh two-card
cd $H/glm53-flash && ./ct123-test-host.sh restore   # also if the run stops early
systemctl stop vram-residency
```

| Stage | `<stage>` | `<settings>` |
| --- | --- | --- |
| 1 | `screen` | `REPS=1 DEPTHS=0,8000 PROBE_CLASSES=code` |
| 2 | `fit` | `REPS=1 DEPTHS=8000 PROBE_CLASSES=code` |
| 3 | `load` | `DEPTHS=0,8000 CONC_REPS=3 PROBE_CHAT=true` |
| 4 | `threads` | `DEPTHS=0,8000 CONC_REPS=3 PROBE_CHAT=true` |
| 5a | `ctx-fit` | `REPS=1 PROBE_CLASSES=code PROBE_CHAT=true`; depths per cell |
| 5b | `context` | `PROBE_CLASSES=code PROBE_CHAT=true`; depths per cell |
| 6a | `2c-fit` | `REPS=1 DEPTHS=8000 PROBE_CLASSES=code PROBE_CHAT=true` |
| 6b | `2c` | `DEPTHS=0,8000 CONC_REPS=3 PROBE_CHAT=true` |
| 7a | `mtp-fit` | `REPS=1 DEPTHS=8000 PROBE_CLASSES=code PROBE_CHAT=true` |
| 7b | `mtp-scan` | `REPS=1 DEPTHS=0,8000 PROBE_CHAT=true` |
| 7c | `mtp` | `DEPTHS=0,8000 CONC_REPS=3 PROBE_CHAT=true` |
| 7c, short replies | `short` | `N_PREDICT=32 DEPTHS=0,700 PROBE_CHAT=true` |

- Sweep defaults: `N_PREDICT=256`, classes code, list and prose, 16 threads (stage 4
  varies it), the projector on the CPU, batch 4096. Micro-batch is per cell. The
  concurrency probe runs two streams at d0, each a different prompt.
- From stage 3, `PROBE_CHAT=true` sends both probes' prompts through the chat template
  (`/v1/chat/completions`), with the same text, sampling and `cache_prompt: false`, and
  reads the same `timings` block. GLM's figures from stage 3 on are therefore not
  comparable with Flash-Next's records, which use raw `/completion`.
- Stage 5b's cells set their own depths, code class only: 0, 8000, 82000 (~59k tokens) at
  every context, 165000 (~119k) at 131072 and 262144, and 330000 (~237k) at 262144. 5a's
  cells run 8000 and the context's deepest of these.
- `two-card` prints the Vulkan device order in CT 123; `1c-best`'s `VK_DEVICES` is GPU 2's
  index there, and its cell JSON must show `active_card` `0000:83:00.0`.
- After `restore`, Flash-Next must load and answer with its free VRAM as deployed (about
  3.2 GiB) and nothing outside VRAM.
- Expected duration, from Flash-Next's cell times scaled by the prefill estimate above:
  - stage 1: about 1.5 h (ran in 1 h);
  - stage 2: about 30 min;
  - stage 3: 3.5 h;
  - stage 4: 4.5 h, the CPU-only cells about half of it;
  - stage 5: 4–5 h;
  - stage 6: about 4 h;
  - stage 7: about 7 h.
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
- Stage 6: `two-card` refuses unless CT 120 is stopped, and turns CT 120's autostart off
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

llama.cpp b11505 (`ff5888f99`, release tarball), Mesa 26.2.4 (kisak-mesa), kernel
`7.0.14-22-pve`, pve-firmware 3.18-7, `schedutil`, 8 × 64 GB DDR4-3200. CT 123 with 48 cores
and 240 GiB holding `0000:83:00.0` (`unique_id` `99b104541144b36c`) on PCIe 4.0 x16 at 0 mV and
250 W. Model `unsloth/GLM-5.3-Flash-GGUF` UD-Q4_K_XL at revision `a38483c8`, all seven files
checked against the Hub's SHA-256. Stage 1's capture (2026-10-11 01:23 UTC) is below; later
stages add theirs if anything but the time and free VRAM changes.

<details>
<summary>environment.json, stage 1</summary>

```json
{
 "captured_at": "2026-10-11T01:23:40Z",
 "host": {
  "hostname": "proxmox",
  "kernel": "7.0.14-22-pve",
  "pve_manager": "9.2.21",
  "pve_firmware": "3.18-7",
  "cpu": "AMD EPYC 7532 32-Core Processor",
  "governor": "schedutil",
  "mem_gib": 504,
  "dimms": [
   {
    "locator": "P0 CHANNEL A",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL B",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL C",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL D",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL E",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL F",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL G",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL H",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   }
  ]
 },
 "guest": {
  "unit": "llamacpp-glm53f",
  "env_file": "/etc/llamacpp-glm53f.env",
  "env": {
   "LLAMACPP_DIR": "/opt/llamacpp/llama-b11505",
   "MODEL_PATH": "/models/hf/glm-5.3-flash/GLM-5.3-Flash-UD-Q4_K_XL-00001-of-00006.gguf",
   "MODEL_ALIAS": "glm-5.3-flash",
   "MODEL_MMPROJ": "/models/hf/glm-5.3-flash/mmproj-F16.gguf",
   "MODEL_SERVER_BIND": "0.0.0.0",
   "MODEL_SERVER_PORT": "1234",
   "MODEL_GPU_LAYERS": "99",
   "MODEL_CPU_MOE": "46",
   "MODEL_OT_OVERRIDE": "",
   "MODEL_CONTEXT_LENGTH": "65536",
   "MODEL_PARALLEL": "1",
   "MODEL_THREADS": "16",
   "MODEL_EXPECTED_GPUS": "1",
   "MODEL_VK_VISIBLE_DEVICES": "",
   "MODEL_TENSOR_SPLIT": "",
   "MODEL_LOAD_MODE": "",
   "MODEL_REASONING_BUDGET": "",
   "EXTRA_ARGS": "--device Vulkan0",
   "MODEL_BATCH_SIZE": "4096",
   "MODEL_UBATCH_SIZE": "1024",
   "MODEL_KV_TYPE": "f16",
   "MODEL_MMPROJ_ON_CPU": "true"
  },
  "unit_active": "inactive",
  "server_cmdline": null,
  "llamacpp": {
   "dir": "/opt/llamacpp/llama-b11505",
   "version": "version: 0.6.0-dev (build 11505, commit ff5888f99)",
   "built_with": "built with GNU 11.4.0 for Linux x86_64",
   "llama_server_sha256": "b8f67ab0ac46efeed0bc84fe84ef51e9eee08a52c5f7fe56375ec89d3f79729c",
   "devices": "Vulkan0: AMD Radeon Pro V620 (RADV NAVI21) (30704 MiB, 30687 MiB free)"
  },
  "os": "Ubuntu 24.04 LTS",
  "guest_kernel": "7.0.14-22-pve",
  "mesa": "26.2.4~kisak1~n",
  "vulkan_driver": "Mesa 26.2.4 - kisak-mesa PPA",
  "rocm": null,
  "model_files": [
   {
    "path": "/models/hf/glm-5.3-flash/GLM-5.3-Flash-UD-Q4_K_XL-00001-of-00006.gguf",
    "exists": true,
    "bytes": 9429984,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/glm-5.3-flash/GLM-5.3-Flash-UD-Q4_K_XL-00002-of-00006.gguf",
    "exists": true,
    "bytes": 49198039200,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/glm-5.3-flash/GLM-5.3-Flash-UD-Q4_K_XL-00003-of-00006.gguf",
    "exists": true,
    "bytes": 49988626304,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/glm-5.3-flash/GLM-5.3-Flash-UD-Q4_K_XL-00004-of-00006.gguf",
    "exists": true,
    "bytes": 48700701344,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/glm-5.3-flash/GLM-5.3-Flash-UD-Q4_K_XL-00005-of-00006.gguf",
    "exists": true,
    "bytes": 49026026752,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/glm-5.3-flash/GLM-5.3-Flash-UD-Q4_K_XL-00006-of-00006.gguf",
    "exists": true,
    "bytes": 2784497888,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/glm-5.3-flash/mmproj-F16.gguf",
    "exists": true,
    "bytes": 1128047296,
    "verified_stamp": true
   }
  ],
  "vmid": 123,
  "kind": "lxc",
  "config": {
   "cores": "48",
   "hostname": "gpu2",
   "memory": "245760",
   "ostype": "ubuntu",
   "swap": "4096"
  }
 },
 "cards": [
  {
   "pci": "0000:83:00.0",
   "name": "Advanced Micro Devices, Inc. [AMD/ATI] Navi 21 [Radeon Pro V620]",
   "driver": "amdgpu",
   "unique_id": "99b104541144b36c",
   "vbios": "113-D6030500-100",
   "vram_total_mib": 30704,
   "od_vddgfx_offset": "0mV",
   "power_cap_w": 250,
   "pcie_link": "16.0GT/s, x16 619Mhz"
  }
 ]
}
```

</details>

---

## Results

### Stage 1, screen — 2026-10-10 21:23–22:20 ET

Harness `d0be39a` (`push-harness.sh`), run as `systemd-run` units on the host: the sweep
(`REPS=1 DEPTHS=0,8000 PROBE_CLASSES=code`, `UNIT=llamacpp-glm53f N_BLOCKS=46
CONTRACT_EFFORTS=none,low,high,max`), `thermal-guard.sh` (`VMID=123 UNIT=llamacpp-glm53f`) and
`vram-residency-sampler.py` on `0000:83:00.0`. `ct123-test-host.sh one-card` set CT 123 up first.
Raw data: `/root/glm53-flash/sweep-screen-20261011T012335Z/`, `residency-screen.jsonl` and
`handcheck-*.json` on the host.

Every cell loaded and answered. Every routed expert is in host RAM (`-ncmoe 46`), `auto` load
mode unless noted, f16 KV, context 65536, micro-batch 1024, one slot unless noted. VRAM is
`mem_info_vram_used` on the 30,704 MiB card. One pass, so the speed columns are a screen, not a
comparison.

| Cell | Differs from `base` | VRAM after load, MiB | Δ vs `base` | Load, s | Decode d0 / d8000, t/s | Prefill d8000, t/s |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `base` | — | 15,461 | — | 29 | 6.75 / 5.94 | 47.7 |
| `base-q8` | q8_0 KV | 14,884 | −577 | 29 | 6.64 / 6.19 | 47.5 |
| `base-ctx128k` | context 131072 | 17,047 | +1,586 | 28 | 6.60 / 6.11 | 47.7 |
| `base-ctx256k` | context 262144 | 19,967 | +4,506 | 28 | 6.54 / 6.14 | 47.5 |
| `base-ub2048` | micro-batch 2048 | 15,986 | +525 | 28 | 6.47 / 6.04 | 73.9 |
| `base-ub4096` | micro-batch 4096 | 17,951 | +2,490 | 28 | 6.55 / 5.95 | 90.5 |
| `base-n45` | block 45's experts eligible for the card | 15,461 | 0 | 29 | 6.66 / 6.15 | 46.6 |
| `base-mtp3` | MTP, n-max 3 | 16,667 | +1,206 | 29 | 9.90 / 9.97 | 47.2 |
| `base-p2` | two slots, `--kv-unified` | 15,703 | +242 | 29 | 6.54 / 6.00 | 47.3 |
| `base-p2-nokvu` | two slots | 15,538 | +77 | 28 | 6.85 / 6.06 | 47.6 |
| `base-dio` | `--load-mode dio` | 15,462 | +1 | 119 | 6.58 / 6.05 | 139.4 |
| `cpu` | no card (`--device none`, `-ngl 0`) | 16 | — | 151 | 5.32 / — | — |

- **Nothing left VRAM.** `residency-summary.py` over the 11 deep prefills: VRAM-requested memory
  outside VRAM 0 MiB and nothing evicted in every one. The sweep's "possible spill" flags on
  `base-ub2048`, `base-ub4096`, `base-mtp3` and `base-p2` were GTT growth of 273–296 MiB during the
  probe, against `base`'s own 224 MiB, which stays under the flag's 256 MiB.
- **Peak VRAM sits at the load reading.** Through `base-ctx256k`'s prefill the card read at most
  19,971 MiB in use, against 19,967 MiB after load; `base-ub4096` reached 17,955 MiB against
  17,951.
  - One `base-ctx256k` sample read 20,910 MiB in use (9,794 MiB free), above the server's own
    allocation.
  - That sample is a compute-buffer swap, which the card counts twice for up to 0.2 s
    ([findings record](2026-10-13-findings.md)).
- **Block 45 loads only with MTP.** `base-n45` used exactly `base`'s VRAM, and the load log lists
  block 45's tensors as unused. Without speculation `-ncmoe 45` and `46` are the same placement.
- **MTP:** the head without its experts, plus its draft context, took 1,206 MiB at n-max 3.
  Acceptance was 77% at d0 and 99% at d8000; the d8000 figure measures copying the filler (see the
  output gate below), not drafting.
- **`dio`** pinned 177,777 MiB of GTT and loaded in 119 s against 28–29 s under `auto` with the
  page cache warm. It prefilled 2.9 times as fast (139.4 against 47.7 t/s) at the same decode.
  That is about 26 GB/s of expert upload per micro-batch, on the reading in the Question.
- **Card and CPU use, `base`:** prefill 70 W at 534 MHz on under one CPU core; decode 50 W with
  15.2 cores. `base-dio` prefill: 170 W at 2,370 MHz, 99% busy. CPU only decoded on 16.0 cores, and
  its weights repacked into 106.5 GiB of anonymous memory.
- **Two slots:** both two-stream rounds completed, at 9.1 t/s aggregate with `--kv-unified` and
  9.0 without (4.6 and 4.5 per stream). One round each.
- **DIMMs:** hottest 51–56 °C; no sample at 66 °C.

**Output gate.** Every GPU cell's d8000 code reply is flagged degenerate (8-gram uniqueness 0.29
in `base`). The probe sends `/completion` a raw prompt of ~5.8k tokens of repeated filler followed
by the instruction. GLM restates the instruction and then continues the filler. Sent through the
chat template as a user turn, the same prompt (5,804 tokens) was answered: a TypeScript debounce
with JSDoc. So long-context attention works on this build, and the flag comes from the probe's
prompt shape on this model. The d0 replies are coherent.

**Contract** on `base`, the one cell the sweep checked (bare chat and `reasoning_effort` `none`,
`low`, `high`, `max`):

| Server flags | Bare chat | `none` | `low` | `high` | `max` |
| --- | --- | --- | --- | --- | --- |
| `--reasoning off` | empty, 302 reasoning chars, stopped at the 64-token limit | empty, 161 chars | `OK` | `OK`, 45 reasoning chars | empty, 161 chars |
| `--reasoning off --reasoning-budget 0` | `OK` | `OK` | `OK` | `OK` | `OK` |

No think tag reached `content` in either row. The budget-0 row was run by hand: `base` started
with `MODEL_REASONING_BUDGET=0` and `placement-probe.py --contract` from the same harness.

**Hand checks** on `base` with `--reasoning-budget 0`:
- Tool calls parse non-streamed (`get_weather`, `{"city":"Paris"}`, `finish_reason`
  `tool_calls`) and streamed; a tool-result follow-up answers in plain text.
- An image request (a 64 × 64 PNG, red left and blue right) is answered "Red and blue." without
  MTP. With `--spec-type draft-mtp --spec-draft-n-max 3` it fails with HTTP 500 `decode() failed:
  failed to process speculative batch` (#30204). The server survives, and the next text request
  drafts normally.

**Stage 1 rules applied:**
- **KV type: f16.** q8_0 freed 577 MiB at 65536, under one expert layer (4,176 MiB).
- **Reasoning: `--reasoning-budget 0`** joins every later stage; `glm53f.env` now sets it.
- **Two slots: no `--kv-unified`.** `base-p2-nokvu` completed both streams.
- **Larger micro-batch for stage 2: 4096.** It costs 2,490 MiB over 1024, under one expert layer.

### Stage 2, fit — 2026-10-10 22:55–23:13 ET

Harness `644c589`, cells
[`2026-10-10-configurations-fit.cells`](2026-10-10-configurations-fit.cells): no speculation,
`dio`, f16 KV, context 65536, two slots, `--reasoning-budget 0`, raw `/completion` (this stage
measures VRAM and residency only). One pass with `REPS=1 DEPTHS=8000 PROBE_CLASSES=code`, and the
residency sampler read over each cell's d8000 request and two-stream round. Raw data:
`/root/glm53-flash/sweep-fit-20261011T025441Z/` and `residency-fit.jsonl` on the host.

| Cell | Micro-batch | `-ncmoe` (expert layers on the card) | VRAM after load, MiB | Free | VRAM-requested memory outside VRAM, max | Passes |
| --- | ---: | --- | ---: | ---: | ---: | --- |
| `f1-42` | 1024 | 42 (blocks 42–44) | 28,375 | 2,329 | 0 | no: under 3,072 free |
| `f1-43` | 1024 | 43 (blocks 43–44) | 24,198 | 6,506 | 0 | **yes** |
| `f2-43` | 4096 | 43 (blocks 43–44) | 25,927 | 4,777 | 1,890 MiB, 12 of 134 samples | no: memory outside VRAM |
| `f2-44` | 4096 | 44 (block 44) | 21,750 | 8,954 | 0 | **yes** |

- **Fits:** `-ncmoe 43` at micro-batch 1024 and `-ncmoe 44` at 4096. The larger micro-batch costs
  one expert layer.
- `f2-43` passed the free-VRAM test with 4,777 MiB but still had up to 1,890 MiB of
  VRAM-requested memory outside VRAM during its prefill, the effect seen on Flash-Next. The
  residency condition, not the margin, rejected it.
- Each cell pinned 165–174 GiB of GTT (the CPU-resident experts) and loaded in 111–115 s.
- One pass, so not compared, but for orientation: decode at d8000 6.2–6.5 t/s in every cell;
  prefill at d8000 143–145 t/s at micro-batch 1024 and 180–188 t/s at 4096. Prefill drew
  166–177 W on under one CPU core, decode 52 W on about 15 cores. Two streams completed in every
  cell, 8.7–9.4 t/s aggregate. Hottest DIMM 51–54 °C.

### Stage 3, load mode and micro-batch — 2026-10-11 08:18–12:18 ET

Harness `3ab9c25`, cells
[`2026-10-10-configurations-load.cells`](2026-10-10-configurations-load.cells): three passes,
round-robin, `DEPTHS=0,8000 CONC_REPS=3 PROBE_CHAT=true`, all three prompt classes, f16 KV,
context 65536, two slots, 16 threads, batch 4096, `--reasoning-budget 0`. Requests go through
the chat template. The weekly backup had finished at 01:08 ET. Raw data:
`/root/glm53-flash/sweep-load-20261011T121827Z/`, `residency-load.jsonl` and
`handcheck-prefill-ab/` on the host.

Decode is the median of the six prompt cells (three classes at d0 and d8000) per pass; prefill
the median of the three d8000 requests per pass. Each figure is the median of the three passes,
with their range in brackets.

| Cell | Load mode, micro-batch, `-ncmoe` | VRAM after load, MiB | Free | Load, s | Decode, t/s | Prefill d8000, t/s | Two streams, aggregate t/s |
| --- | --- | ---: | ---: | ---: | --- | --- | --- |
| `auto-1024` | `auto`, 1024, 43 | 24,196 | 6,508 | 30–33 | 6.545 [6.475–6.545] | 41.4 [41.4–41.5] | 8.76 [8.73–8.92] |
| `dio-1024` | `dio`, 1024, 43 | 24,198 | 6,506 | 113–114 | **6.680** [6.615–6.750] | 116.6 [116.5–116.6] | 9.09 [8.98–9.39] |
| `dio-4096` | `dio`, 4096, 44 | 21,750 | 8,954 | 115–116 | 6.605 [6.460–6.675] | **174.4** [174.2–174.4] | 8.99 [8.76–9.15] |
| `dio-experts-ram` | `dio`, 4096, 46 | 17,272 | 13,432 | 119–126 | 6.475 [6.360–6.505] | 172.7 [172.4–172.8] | 8.82 [8.69–9.07] |
| `cpu` | no card, 1024 | 16 | — | 152–153 | 4.775 [4.565–4.790] | 17.1 [17.0–17.3] | 7.13 [6.64–7.30] |

Decode per prompt cell, t/s, median of the three passes:

| Cell | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `auto-1024` | 6.88 | 6.75 | 6.72 | 6.28 | 6.15 | 6.23 |
| `dio-1024` | 6.93 | 6.95 | 6.93 | 6.39 | 6.44 | 6.47 |
| `dio-4096` | 6.89 | 6.87 | 6.94 | 6.31 | 6.31 | 6.27 |
| `dio-experts-ram` | 6.67 | 6.77 | 6.89 | 6.01 | 6.18 | 6.28 |
| `cpu` | 5.35 | 5.21 | 5.23 | 4.26 | 4.24 | 4.12 |

**Stage 3 rule applied: next stages use `dio-4096`** (`--load-mode dio`, micro-batch 4096,
`-ncmoe 44`).
- Best decode: `dio-1024`, 6.680 t/s, spread 0.135.
- Within the spread: `dio-4096` (0.075 lower, against spreads of 0.135 and 0.215) and
  `auto-1024` (0.135 lower, equal to `dio-1024`'s spread, so it does not count).
- Outside: `dio-experts-ram`, 0.205 lower, beyond both spreads (0.135 and 0.145).
- Highest d8000 prefill among the three: `dio-4096`, 174.4 t/s, against 116.6 for `dio-1024`
  and 41.4 for `auto-1024`.

What each step changed, by the spread rule:
- **`dio` against `auto`** (same placement): prefill 2.8 times as fast (116.6 against 41.4 t/s);
  decode within the spread. Under `auto` the card prefilled at 67 W and 505 MHz; under `dio` at
  166–177 W and about 2,365 MHz, 99% busy.
- **Micro-batch 4096 against 1024** (both `dio`): prefill +50%, for one expert layer; decode within
  the spread.
- **Block 44's experts on the card against in RAM** (`dio-4096` against `dio-experts-ram`):
  decode within the spread (0.13 lower, against spreads of 0.215 and 0.145); prefill 1.0% lower,
  beyond both spreads. Keeping every expert in RAM frees 4,478 MiB more, 13,432 MiB in all.
- **CPU only** (16 threads; stage 4 varies them): decode 4.775 t/s, 28.5% below `dio-1024`; prefill
  17.1 t/s, a tenth of `dio-4096`'s; two streams 7.13 t/s aggregate. The repacked weights took
  106.6 GiB of anonymous memory.
- **Two streams:** every GPU cell completed every round. Aggregates were 8.76–9.09 t/s, all within
  the spread of the best, at 4.4–4.6 t/s per stream.

- **Nothing left VRAM.** Over 14,465 residency samples, VRAM-requested memory outside VRAM was
  0 MiB in every cell and nothing was evicted. The sweep's "GTT spill" flag on `auto-1024` is GTT
  growing from 344 to 837 MiB during the probe, with residency at zero.
- **VRAM in use moves at micro-batch 4096.** In `dio-4096` the server's own allocation fell by
  1.2–2.0 GiB at the start of each request and returned to 21,689 MiB (21,737 after load) during
  prefill. That is why the sweep's after-probe reading is lower (19,702 MiB in two passes).
  - In four of the six micro-batch 4096 passes, one or two samples of about 520 read the card's
    total 1.9–5.7 GiB above the server's own allocation.
  - The lowest free reading was 5,436 MiB (25,268 MiB in use, `dio-4096`'s third pass), and
    9,685 MiB in `dio-experts-ram`.
  - At micro-batch 1024 the allocation stayed within 24,181–24,256 MiB, and the card's total
    within 16 MiB of it.
- **Output:** each cell's text was identical across its three passes in all six prompt cells, and
  `auto-1024` and `dio-1024` matched each other in all six. The micro-batch 4096 cells differed from
  1024 in four of six (d0 list, and all three at d8000), and CPU only in all six. All read
  coherently and none was flagged degenerate; the lowest 8-gram uniqueness was 0.974
  (`dio-experts-ram`, d8000 list, a numbered list). One example: at d8000 prose, micro-batch 1024
  says the log record must be durable before the data page "is modified", while 4096 and CPU only
  say "is durable".
- **Contract:** bare chat and `reasoning_effort` `none`, `low`, `high` and `max` all answered with
  clean `content` and no reasoning block, on `auto-1024`'s first pass.
  - The harness ran the contract once per sweep, on the first cell that loaded, so the other
    cells were not checked.
- **Card and CPU use:** decode ran at about 52 W and 499 MHz on about 15 cores in every GPU cell;
  prefill used under one core. CPU only used 14–16 cores.
- **DIMMs:** hottest 57–58 °C in the GPU cells and 60 °C in CPU only; no sample at 66 °C.

**Hand check: prefill, raw `/completion` against the chat template** (12:22–12:34 ET, `dio-1024`
loaded once, the d8000 code prompt sent alternately, three of each after a raw warm-up):

| Request | Prompt tokens | Prefill, t/s |
| --- | ---: | --- |
| raw `/completion` | 5,792 | 143.3, 142.1, 142.0 (warm-up 143.2) |
| chat template | 5,804 | 115.6, 115.5, 115.5 |

- Raw requests prefilled as fast as in stage 2 (`f1-43`, the same placement, 143.3 t/s). So
  `dio-1024`'s 116.6 t/s comes from the chat-template request, not from a change in the host.
- At micro-batch 4096, stage 2's raw figure for the same placement was 188.0 t/s against 174.4
  here. That is 7% lower, across two stages rather than alternated.
- The text is the same and the prompt is 12 tokens longer, so prefill speed depends on the
  request, not only on its length; the cause was not measured. Stages 1–2's prefill figures, and
  Flash-Next's, come from raw prompts the model continued instead of answering.

### Stage 4, threads — 2026-10-11 12:43–18:44 ET

Harness `ff349a6`, cells
[`2026-10-10-configurations-threads.cells`](2026-10-10-configurations-threads.cells): stage 3's
settings and three passes, on `dio-4096` (`dio`, micro-batch 4096, `-ncmoe 44`) and on CPU only.
CT 123 has 48 of the host's 64 CPUs (32 cores). Raw data:
`/root/glm53-flash/sweep-threads-20261011T164242Z/` and `residency-threads.jsonl` on the host.
Figures as in stage 3; CPU cores are the container's during decode.

| Cell | Threads | Decode, t/s | Prefill d8000, t/s | Two streams, aggregate t/s | CPU cores |
| --- | ---: | --- | --- | --- | ---: |
| `dio-4096-t16` | 16 | 6.625 [6.430–6.690] | 174.2 [174.1–174.3] | 8.87 [8.86–9.20] | 15.0 |
| `dio-4096-t24` | 24 | 6.495 [6.465–6.535] | 174.7 [174.7–174.8] | 8.97 [8.85–9.02] | 22.7 |
| `dio-4096-t32` | 32 | **6.635** [6.585–6.655] | 174.7 [174.4–174.7] | **9.07** [9.06–9.12] | 30.3 |
| `cpu-t16` | 16 | 4.720 [4.690–4.740] | 17.0 [16.9–17.5] | 7.02 [6.64–7.69] | 16.0 |
| `cpu-t24` | 24 | 4.780 [4.750–4.805] | 16.8 [16.5–16.8] | 7.26 [7.07–7.62] | 24.0 |
| `cpu-t32` | 32 | **4.875** [4.875–4.985] | **19.2** [19.1–19.2] | 7.55 [7.44–7.70] | 32.0 |

Decode per prompt cell, t/s, median of the three passes:

| Cell | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `dio-4096-t16` | 6.94 | 6.87 | 6.92 | 6.22 | 6.31 | 6.34 |
| `dio-4096-t24` | 6.72 | 6.78 | 6.80 | 6.21 | 6.27 | 6.29 |
| `dio-4096-t32` | 6.92 | 6.90 | 6.90 | 6.41 | 6.37 | 6.37 |
| `cpu-t16` | 5.05 | 5.08 | 4.98 | 4.46 | 4.37 | 4.34 |
| `cpu-t24` | 5.17 | 5.08 | 5.00 | 4.47 | 4.48 | 4.47 |
| `cpu-t32` | 5.06 | 5.26 | 5.20 | 4.53 | 4.53 | 4.70 |

**Stage 4 rule applied: next stages use 32 threads** (the highest median decode, 6.635 t/s).
- Its lead over 16 threads (6.625) is within both spreads (0.070 and 0.260).
- Its lead over 24 threads (6.495) counts: 0.140, against spreads of 0.070 and 0.070.
- 32 threads also has the highest two-stream aggregate (9.07 t/s). Its lead over 16 threads
  (8.87) is within 16's spread (0.34), so no other count wins and there is nothing to report
  separately.
- 32 threads kept 30.3 cores busy in decode, against 15.0 at 16.
- Prefill runs on the card, on 0.4 cores, at 174.2–174.7 t/s at every count.
- **Card, per phase** (`SUMMARY.md` medians), the same at every thread count within 1 W and
  2 MHz:
  - prefill 174–175 W at 2,362–2,364 MHz, 99% busy;
  - decode 52–53 W at 499 MHz, 51% busy;
  - two streams 48–49 W at 499 MHz, 39–42% busy.
- **CPU only** used 14.3, 17.1 and 23.7 cores in prefill at 16, 24 and 32 threads, and every
  thread in decode.

**CPU only's result: 32 threads.**
- Decode 4.875 t/s. That beats 16 threads (0.155, against spreads of 0.110 and 0.050) and is
  within the spread of 24 (0.095, against 0.110).
- Prefill 19.2 t/s, against 17.0 at 16 threads; the difference counts.
- Two streams 7.55 t/s aggregate.

Against the best GPU configuration (`dio-4096-t32`):
- decode 26.5% lower (4.875 against 6.635 t/s);
- prefill 9.1 times slower (19.2 against 174.7 t/s);
- two-stream aggregate 17% lower (7.55 against 9.07 t/s).

- **Nothing left VRAM:** 0 MiB outside VRAM and nothing evicted over 22,718 samples. Every
  `dio-4096` pass loaded at 21,750 MiB in 115–116 s.
- **Output:** each cell's text was identical across its three passes.
  - The GPU cells gave the same text at every thread count, and the same as stage 3's `dio-4096`
    in all six prompt cells.
  - CPU only gave a different text per thread count in five of six prompt cells; 16 threads
    matched stage 3's `cpu`.
  - All read coherently; none was flagged degenerate.
- **Contract:** clean at every effort value on `dio-4096-t16`'s first pass, the one cell the sweep
  checked.
- **DIMMs:** hottest 57–58 °C in the GPU cells and 60–63 °C in CPU only, highest at 32 threads;
  no sample at 66 °C.

### Stage 5a, context fit — 2026-10-11 19:13–20:16 ET

Harness `8bb6a89`, cells
[`2026-10-10-configurations-ctx-fit.cells`](2026-10-10-configurations-ctx-fit.cells): one pass,
`REPS=1 PROBE_CLASSES=code PROBE_CHAT=true`, `dio`, micro-batch 4096, 32 threads, one slot. Raw
data: `/root/glm53-flash/sweep-ctx-fit-20261011T231324Z/` and `residency-ctx-fit.jsonl` on the
host.

| Cell | Context | `-ncmoe` | VRAM after load, MiB | Free | VRAM-requested memory outside VRAM, max | d8000 prefill / decode, t/s | Deepest request | Fit |
| --- | ---: | --- | ---: | ---: | --- | --- | --- | --- |
| `ctx64k-n44` | 65536 | 44 | 22,434 | 8,270 | 0 | 174.8 / 6.41 | 59,296 tokens: prefill 146.3, decode 5.61 | **yes** |
| `ctx128k-n44` | 131072 | 44 | 24,755 | 5,949 | 1,890 MiB, 79 of 612 samples | 174.3 / 6.43 | GPU job timeout after 9:01 | no: memory outside VRAM |
| `ctx128k-n46` | 131072 | 46 | 20,273 | 10,431 | 0 until the timeout | 171.8 / 6.29 | GPU job timeout after 9:00 | not completed |
| `ctx256k-n44` | 262144 | 44 | 27,722 | 2,982 | 1,890 MiB, 513 of 658 samples | 133.0 / 6.38 | GPU job timeout after 9:35 | no: under 3,072 free, memory outside VRAM |
| `ctx256k-n46` | 262144 | 46 | 23,240 | 7,464 | 0 until the timeout | 172.6 / 6.29 | GPU job timeout after 9:00 | not completed |

- **64k fits at `-ncmoe 44`** through a 59,296-token request. Prefill there averaged 146.3 t/s,
  16% below the ~5.8k request's, and the card reached 87 °C junction, against 76–78 °C in the
  other cells' ~5.8k prefills.
- **`-ncmoe 44` fails at 128k and 256k.**
  - At 128k, 1,890 MiB of VRAM-requested memory went outside VRAM from 6.5 minutes into the deep
    request until its end.
  - At 256k, the load left 2,982 MiB free, and memory was outside VRAM from the ~5.8k request
    on. That request prefilled at 133.0 t/s, against 172.6 at `-ncmoe 46`.
- **Every request deeper than 64k failed** with HTTP 500, at both placements of both contexts,
  after 9:00–9:35 of prefill.
  - llama-server logged `decode() failed: vk::Queue::submit: ErrorDeviceLost`.
  - For each failure, the host kernel logged `ring comp_1.x timeout` on `0000:83:00.0`, reset that
    compute ring, and reported "device wedged, but recovered through reset". There were four
    resets. Each later cell loaded and answered normally, and the card read idle afterwards.
- **The cause is amdgpu's job timeout:** `amdgpu.lockup_timeout` is at its default of 2,000 ms
  (`modinfo amdgpu`; the kernel command line does not set it), and a GPU job longer than that is
  treated as a hang.
  - llama.cpp #26447 (open) reports the same failure on other AMD GPUs past about 50k tokens. The
    Vulkan backend's maintainer says there that a single large operation can exceed the timeout
    and cannot be split further. Raising the timeout was the workaround reported there.
  - From the 64k cell's prefill rate, nine minutes is past about 65k tokens. Which operation ran
    long was not identified, and how the limit depends on micro-batch was not measured.
- **What 5a leaves open:** at 128k and 256k, `-ncmoe 46` met the load rule with nothing outside
  VRAM up to the timeout. Neither context's deepest request completed, so both fits stand
  unconfirmed. 5b's cells wait for the owner's choice of how to get past the timeout.

**5a rerun, compute job timeout 10 s** (2026-10-11 20:38–21:46 ET). Harness `28afac9`, cells
[`2026-10-10-configurations-ctx-fit-rerun.cells`](2026-10-10-configurations-ctx-fit-rerun.cells),
same settings, after the host change under Deviations. Raw data:
`/root/glm53-flash/sweep-ctx-fit-rerun-20261012T003825Z/` and `residency-ctx-fit-rerun.jsonl`
on the host.

| Cell | VRAM after load, MiB | Free | d8000 prefill / decode, t/s | Deepest request | Least free VRAM | VRAM-requested memory outside VRAM, max | Fit |
| --- | ---: | ---: | --- | --- | ---: | --- | --- |
| `ctx128k-n46` | 20,273 | 10,431 | 171.9 / 6.27 | 119,281 tokens: prefill 122.9 t/s (16 min), decode 4.80 t/s | 10,100 | 0 | **yes** |
| `ctx256k-n46` | 23,240 | 7,464 | 172.6 / 6.32 | 238,520 tokens: prefill 94.9 t/s (42 min), decode 4.49 t/s | 1,767 | 2,354 MiB, 1,533 of 2,644 samples | no: memory outside VRAM |

- **No timeout:** no compute ring timed out since the reboot. Both deep requests completed and
  answered coherently, with 8-gram uniqueness 1.0.
- **128k fits at `-ncmoe 46`,** one expert layer fewer than 64k's `-ncmoe 44`.
- **256k does not fit on one card at micro-batch 4096.**
  - From 10 minutes into its deep request until the end, VRAM-requested memory was outside
    VRAM.
  - The server's own allocation peaked at 28,179 MiB, 4,939 more than after load.
  - `-ncmoe 46` already holds every expert in RAM, so no further step is left. 5b leaves 256k
    out, as the plan says.
- Junction peaked at 87 °C and memory at 72 °C in both cells; hottest DIMM 55–58 °C.

### Stage 5b, context timed — 2026-10-12 08:06–10:43 ET

Harness `b58bfc0`, cells
[`2026-10-10-configurations-context.cells`](2026-10-10-configurations-context.cells): three
passes, `PROBE_CLASSES=code PROBE_CHAT=true`, `dio`, micro-batch 4096, 32 threads, one slot,
compute job timeout 10 s. 256k is left out (5a). Raw data:
`/root/glm53-flash/sweep-context-20261012T120620Z/` and `residency-context.jsonl` on the host.
Figures are the median of the three passes [range]; prefill is the average over the whole
prompt. `SUMMARY.md`'s header lists the sweep's default depths (`0,8000,32000`); each cell ran
the depths below.

| Cell | Context | `-ncmoe` | Expert layers on the card | VRAM after load, MiB | VRAM peak, MiB | Least free, MiB | VRAM-requested memory outside VRAM |
| --- | ---: | --- | --- | ---: | ---: | ---: | --- |
| `ctx64k-n44` | 65536 | 44 | 1 (block 44, 4,482 MiB) | 22,434 | 22,438 | 8,266 | 0 |
| `ctx64k-n46` | 65536 | 46 | 0 | 17,952 | 17,958 | 12,746 | 0 |
| `ctx128k-n46` | 131072 | 46 | 0 | 20,273 | 20,604 | 10,100 | 0 |

Decode, t/s, by prompt length:

| Cell | d0 (42 tokens) | d8000 (5,804) | d82000 (59,296) | d165000 (119,281) |
| --- | --- | --- | --- | --- |
| `ctx64k-n44` | 6.77 [6.71–6.86] | 6.27 [6.25–6.35] | **5.62** [5.49–5.65] | — |
| `ctx64k-n46` | 6.83 [6.74–6.84] | 6.32 [6.21–6.37] | 5.44 [5.40–5.47] | — |
| `ctx128k-n46` | 6.82 [6.76–6.84] | 6.22 [6.18–6.25] | 5.48 [5.32–5.51] | 4.84 [4.72–4.84] |

Prefill, t/s, and prompt time:

| Cell | d8000 (5,804 tokens) | d82000 (59,296) | d165000 (119,281) |
| --- | --- | --- | --- |
| `ctx64k-n44` | **174.5** [174.5–174.8], 33 s | **146.4** [146.4–146.6], 6.8 min | — |
| `ctx64k-n46` | 173.1 [171.4–173.1], 34 s | 145.4 [145.4–146.0], 6.8 min | — |
| `ctx128k-n46` | 172.7 [172.7–173.2], 34 s | 145.2 [145.2–145.3], 6.8 min | 123.1 [123.0–123.2], 16.2 min |

- **What 128k costs:**
  - **VRAM:** at the same placement, 128k loads 2,321 MiB above 64k (20,273 against 17,952). During
    the 119,281-token request it grew another 331 MiB; 64k's stayed at its load figure.
  - **Expert layers:** one. 64k fits with block 44's experts on the card; 128k fits only with every
    expert in RAM. 5a's `ctx128k-n44` put 1,890 MiB outside VRAM during its deep request.
- **Context size alone:** 64k and 128k at `-ncmoe 46` are within each other's spread in decode
  and prefill at every shared depth.
- **Block 44 on the card** (64k at `-ncmoe 44` against 46):
  - Prefill is faster at 59,296 tokens: 146.4 against 145.4 t/s (+0.7%), beyond both spreads
    (0.22 and 0.57). At 5,804 tokens it is within `ctx64k-n46`'s spread (1.69, one pass at 171.4).
  - Decode is faster at 59,296 tokens: 5.62 against 5.44 t/s (+3.3%), beyond both spreads
    (0.16 and 0.07). At 42 and 5,804 tokens it is within the spread.
  - Against `ctx128k-n46`, 64k at `-ncmoe 44` prefills faster at both depths (+1.0% and +0.8%,
    beyond both spreads). Its decode is within the spread at every depth: the 59,296-token
    difference is 0.15 t/s, against `ctx128k-n46`'s 0.20.
- **Depth at 128k:**
  - Decode falls 29%, from 6.82 t/s on a 42-token prompt to 4.84 at 119,281 tokens. From 5,804
    tokens to 119,281 it falls 22%.
  - Average prefill falls 29% from 5,804 tokens to 119,281.
  - The 119,281-token prompt took 16.1–16.2 minutes before the first token.
- **Nothing left VRAM:** 0 MiB outside VRAM and nothing evicted over 9,459 samples.
  - The card's total matched the server's own allocation within 16 MiB. The exceptions were
    single samples: one to five per deep prompt, plus some during loads and unloads.
  - In those samples the card's total read up to 8.4 GiB above the server's own allocation,
    while the server freed and reallocated its compute buffer.
  - The card keeps counting a freed buffer until the driver has wiped it, for up to 0.2 s
    ([findings record](2026-10-13-findings.md)).
  - The next sample matched again, so the peaks above leave them out.
- **Output:** each depth gave the same text in every cell and every pass, and the same as
  stage 5a's at that depth. None was flagged degenerate; 8-gram uniqueness was 1.0 throughout.
- **Contract:** clean at every effort value on `ctx64k-n44`'s first pass, the one cell the sweep
  checked.
- **Heat:**
  - Junction peaked at 85–89 °C during the deep prompts, and memory at 70–72 °C. The 89 °C was
    `ctx64k-n44`, pass 3.
  - Prefill drew 213–220 W of the 250 W cap.
  - Hottest DIMM 53–56 °C; no sample reached 66 °C.

### Stage 6a, two-card fit and split — 2026-10-12 12:12–12:41 ET

`ct123-test-host.sh two-card` gave CT 123 both cards at 12:11 ET. Vulkan0 is GPU 1 (`03:00.0`)
and Vulkan1 is GPU 2 (`83:00.0`).

Two rounds:
- Round 1: harness `2ca751c`, cells
  [`2026-10-10-configurations-2c-fit.cells`](2026-10-10-configurations-2c-fit.cells), at the
  sweep's split.
- Round 2: harness `de875ff`, cells
  [`2026-10-10-configurations-2c-fit-2.cells`](2026-10-10-configurations-2c-fit-2.cells), after
  round 1.

Each round was one pass, `REPS=1 DEPTHS=8000 PROBE_CLASSES=code PROBE_CHAT=true`: `dio`, batch
and micro-batch 4096, 32 threads, f16 KV, context 65536, two slots. A residency sampler ran on
each card. Raw data on the host: `/root/glm53-flash/sweep-2c-fit-20261012T161210Z/`,
`sweep-2c-fit-2-20261012T163210Z/` and `residency-2c-fit-gpu{1,2}.jsonl`.

The split is llama.cpp's `--tensor-split` value. The blocks each card holds follow from the
measured VRAM: at 39,7, GPU 1 holds blocks 0–39 and GPU 2 blocks 40–44.

| Cell | `-ncmoe` | Split | Expert layers, GPU 1 + GPU 2 | VRAM after load, MiB, GPU 1 / GPU 2 | Least free, MiB, GPU 1 / GPU 2 | VRAM-requested memory outside VRAM, max | Fit |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `2c-n37` | 37 | 39,7 | 3 + 5 | 28,165 / 25,465 | 2,537 / 5,124 | GPU 1: 1,890 MiB, 137 of 154 samples | no: under 3,072 free, memory outside VRAM |
| `2c-n38` | 38 | 40,6 | 3 + 4 | 28,345 / 21,110 | 2,358 / 9,480 | GPU 1: 1,890 MiB, 141 of 150 samples | no: under 3,072 free, memory outside VRAM |
| `2c-n39` | 39 | 40,6 | 2 + 4 | 24,168 / 21,110 | 6,534 / 9,592 | 0 | yes |
| `2c-n40` | 40 | 41,5 | 2 + 3 | 24,347 / 16,754 | 6,356 / 13,947 | 0 | yes |
| `2c-n38-s39` | 38 | 39,7 | 2 + 5 | 23,988 / 25,465 | 6,713 / 5,235 | 0 | **yes: the fit** |
| `2c-n38-tensor` | 38 | `-sm tensor`, even | — | did not load | — | — | no |
| `2c-n37-s38` | 37 | 38,8 | 2 + 6 | 23,717 / 29,513 | 6,987 / 1,076 | GPU 2: 1,023 MiB, 120 of 140 samples | no: margin test (Deviations) |

- **The fit is `-ncmoe 38` at split 39,7**, with seven expert layers on the cards (blocks 38–44)
  against one on one card. The plan estimated five more; the measurement is six.
  - The sweep's split, 40,6, left GPU 1 short, and one block moved to GPU 2.
  - `-ncmoe 37` has no layer split that fits: at 39,7 GPU 1 runs short, and at 38,8 GPU 2 does.
- **The cards carry unequal loads besides their experts.**
  - GPU 1 holds 15,365–15,995 MiB besides its experts; GPU 2 holds 3,920–4,279 MiB.
  - GPU 1 holds every block whose experts are in RAM, and it does the prefill: median power
    171–181 W against 6–7 W on GPU 2. In decode, GPU 1 drew 52–53 W and GPU 2 25–29 W.
- **Every placement under the margin put memory outside VRAM:**
  - **GPU 1** at 2,358–2,537 MiB free: 1,584–1,890 MiB, from the d8000 request on. d8000
    prefill fell to 140.7–144.2 t/s, against 181.5–185.5 t/s in the cells without.
  - **GPU 2** at 1,076 MiB least free: 1,023 MiB, from 12 seconds into the d8000 request.
    Prefill was 180.7 t/s.
  - Nothing went outside VRAM on either card with 5,235 MiB or more free.
- **`-sm tensor` does not load** on b11505: `LLAMA_SPLIT_MODE_TENSOR not implemented for
  architecture 'glm5-next'`. It does not join 6b.
- **For orientation only** (one pass, so not compared): at the fit, d8000 prefill was 185.5 t/s,
  d8000 decode 6.51 t/s and two streams 9.39 t/s aggregate. Stage 4's one-card configuration
  gave 174.7, 6.41 and 9.07.
- **Output:** the d8000 text was the same in every two-card cell that loaded. It matches the
  one-card text for its first ~500 characters, then differs, and it reads coherently. Two
  streams completed in every cell.
- **Contract:** clean at every effort value on the first pass of `2c-n37` (round 1) and
  `2c-n38-s39` (round 2), the one cell each sweep checked.
- **The sweep's flag:** "possible spill" fired on every cell, because GPU 1's GTT grew 260 MiB
  during each probe. Requested-minus-resident VRAM read zero in the cells marked 0.
- **Heat:** hottest DIMM 52–54 °C. Junction peaked at 72–77 °C on GPU 1 and 54–61 °C on GPU 2.

### Stage 6b, two cards timed — 2026-10-12 12:44–14:20 ET

Harness `004ebe6`, cells
[`2026-10-10-configurations-2c.cells`](2026-10-10-configurations-2c.cells): three passes,
`DEPTHS=0,8000 CONC_REPS=3 PROBE_CHAT=true`, every prompt class. Batch and micro-batch 4096,
32 threads, f16 KV, context 65536, two slots, compute job timeout 10 s. A residency sampler ran
on each card. Raw data on the host: `/root/glm53-flash/sweep-2c-20261012T164416Z/` and
`residency-2c-gpu{1,2}.jsonl`. Figures as in stage 3.

`1c-best` runs stage 4's `dio-4096-t32` with the same server command line, with only GPU 2
visible. Stage 4's row is repeated for comparison.

| Cell | Cards, `-ncmoe`, load mode | Expert layers, GPU 1 + GPU 2 | VRAM after load, MiB, GPU 1 / GPU 2 | Least free, MiB, GPU 1 / GPU 2 | Load, s | Decode, t/s | Prefill d8000, t/s | Two streams, aggregate t/s |
| --- | --- | --- | ---: | ---: | ---: | --- | --- | --- |
| `2c-auto` | both, 38 at 39,7, `auto` | 2 + 5 | 23,987 / 25,465 | 6,714 / 5,206 | 30–32 | **6.745** [6.600–6.835] | 98.3 [98.2–98.4] | 9.39 [9.35–9.44] |
| `2c-dio` | both, 38 at 39,7, `dio` | 2 + 5 | 23,988 / 25,465 | 6,713 / 5,124 | 104–105 | 6.720 [6.670–6.785] | **187.9** [187.8–188.0] | **9.43** [9.33–9.51] |
| `1c-best` | GPU 2, 44, `dio` | 0 + 1 | 16 / 21,750 | — / 8,951 | 112 | 6.625 [6.610–6.640] | 174.8 [174.5–174.9] | 9.04 [9.04–9.07] |
| stage 4 `dio-4096-t32` | GPU 2, 44, `dio` | 1 | 21,750 | — | 115–116 | 6.635 [6.585–6.655] | 174.7 [174.4–174.7] | 9.07 [9.06–9.12] |

Decode per prompt cell, t/s, median of the three passes:

| Cell | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `2c-auto` | 6.98 | 7.06 | 7.09 | 6.50 | 6.52 | 6.53 |
| `2c-dio` | 7.04 | 7.09 | 7.04 | 6.41 | 6.50 | 6.46 |
| `1c-best` | 6.91 | 6.83 | 6.86 | 6.38 | 6.31 | 6.43 |

**Stage 3 rule applied to the two-card cells: `2c-dio`.**
- Best decode: `2c-auto`, 6.745 t/s, spread 0.235. `2c-dio` is 0.025 lower, within both spreads.
- Of the two, `2c-dio` has the higher d8000 prefill: 187.9 t/s against 98.3.

**`1c-best` stands in for the one-card results.** Against stage 4's `dio-4096-t32`:
- decode 0.010 t/s lower, against spreads of 0.030 and 0.070;
- prefill 0.1 t/s higher, against 0.38 and 0.30;
- two streams 0.03 t/s lower, against 0.03 and 0.06;
- the same VRAM after load (21,750 MiB) and the same text in all six prompt cells.

The two-card container left GPU 1 at 16 MiB. The sweep recorded `0000:83:00.0` as the active
card in every pass.

**What the second card adds** (`2c-dio` against `1c-best`):
- **Single-stream decode:** 6.720 against 6.625 t/s (+1.4%), within `2c-dio`'s spread (0.115), so
  it does not count.
  - Per prompt cell, two cards were 0.13–0.26 t/s higher at d0 and 0.03–0.19 at d8000.
  - Only d0 list's difference (0.26) is beyond both cells' spreads (0.25 and 0.13).
- **Two streams:** 9.43 against 9.04 t/s aggregate (+4.3%), beyond both spreads (0.18 and 0.03).
  Per stream, 4.67–4.75 against 4.52–4.53 t/s.
- **d8000 prefill:** 187.9 against 174.8 t/s (+7.5%), beyond both spreads (0.17 and 0.38).
- **Expert layers on the cards:** seven (blocks 38–39 on GPU 1, 40–44 on GPU 2) against one.
  - Under `dio`, the pinned GTT fell by 25,056 MiB (174,376 to 149,320), exactly six of the
    4,176 MiB expert layers.
  - Decode used 26.1–26.2 CPU cores, against 30.3 on one card.
- **VRAM:** the two-card cells hold 49,452–49,453 MiB across both cards after load, against
  21,750 on one. They leave GPU 1 6,713 MiB free at the least.
- **The prefill runs on different cards.** Two-card prefill runs on GPU 1 at 2,468–2,470 MHz
  and 180–184 W, with GPU 2 at 6–7 W. One card's runs on GPU 2 at 2,354–2,359 MHz and 178–179 W.
  - The [card A/B record](../../runs/2026-10-08-card-ab.md) measured `83:00.0` 3.4–4.8% slower
    in prefill and 1.1–1.3% in decode, on a model held entirely on the card.
  - Part of the prefill difference may therefore come from the card rather than from the second
    card. This stage did not separate the two.
- Whether GPU 1 goes to GLM stays the owner's decision, and with it whether stage 7 runs on two
  cards.

**`dio` against `auto` on two cards** (same placement):
- `dio` prefills 1.91 times as fast: 187.9 against 98.3 t/s.
  - Under `auto`, GPU 1 prefilled at 86–93 W and 509–549 MHz, 53–54% busy.
  - Under `dio`, it prefilled at 180–184 W and about 2,470 MHz, 99% busy.
- Decode is within the spread (0.025 apart), and so are two streams (0.04 apart, against 0.09 and
  0.18).
- `auto` loads in 30–32 s against 104–105 s. GPU 1's GTT after load is 1,329 MiB under `auto`
  and 149,320 under `dio`, which pins the experts held in RAM.

- **Nothing left VRAM:** 0 MiB outside VRAM and nothing evicted on either card, over
  5,797 samples per card.
  - The cards' totals matched the server's allocation within 16 MiB, except in single samples:
    six on GPU 1 and three on GPU 2 across the stage. In those, the card's total read 1.9–6.7 GiB
    above the server's allocation while the server freed and reallocated its buffers, as in 5b.
    The least-free figures leave them out.
  - In the two-card cells, GPU 2's allocation grew by 24–115 MiB during requests, and GPU 1's by
    2 MiB.
- **The sweep's flag:** "possible spill" fired on both two-card cells, because GPU 1's GTT grew
  during the probe: by 684 MiB under `auto` and 260 under `dio`. Residency read zero.
- **No compute ring timed out.**
- **Output:**
  - Each cell gave the same text in all three passes, in all six prompt cells.
  - `2c-auto` and `2c-dio` matched each other in all six. Their d8000 code text is 6a's.
  - Two-card and one-card text matched at d0 code and d0 prose, and differed at d0 list and
    all three d8000 cells.
  - None was flagged degenerate; 8-gram uniqueness was 1.0 throughout.
- **Two streams:** all 54 replies (nine rounds of two streams per cell) ran to the 256-token
  limit and none was flagged degenerate. Each stream's text varied between rounds in every cell,
  with 2–4 distinct texts over nine rounds. Stage 4's cell had 2–3.
- **Contract:** run once, on `2c-auto`'s first pass; clean at every effort value.
- **Heat:**
  - Hottest DIMM 56–57 °C on two cards and 58 °C on one; no sample reached 66 °C.
  - On two cards, GPU 1's junction peaked at 76–77 °C under `auto` and 80–81 °C under `dio`;
    GPU 2's peaked at 59–64 °C.
  - In `1c-best`, GPU 2's junction peaked at 79–80 °C.

### Stage 7a, MTP fit — 2026-10-12 15:34–16:01 ET

The owner chose one card and context 65536 after stage 6. `ct123-test-host.sh one-card` took
GPU 1 back from CT 123 at 15:32 ET. CT 120 stayed stopped, and `one-card` put its autostart back.

Two rounds:
- Round 1: harness `cd24986`, cells
  [`2026-10-10-configurations-mtp-fit.cells`](2026-10-10-configurations-mtp-fit.cells).
- Round 2: harness `07dc6ee`, cells
  [`2026-10-10-configurations-mtp-fit-2.cells`](2026-10-10-configurations-mtp-fit-2.cells).

Each round ran one pass, `REPS=1 DEPTHS=8000 PROBE_CLASSES=code PROBE_CHAT=true`, with stages
3–5's configuration: `dio`, batch and micro-batch 4096, 32 threads, f16 KV, two slots. MTP ran
at n-max 8 (`--spec-type draft-mtp --spec-draft-n-max 8`). Raw data on the host:
`/root/glm53-flash/sweep-mtp-fit-20261012T193444Z/`, `sweep-mtp-fit-2-20261012T195513Z/` and
`residency-mtp-fit.jsonl`.

`--n-cpu-moe N` puts the experts of blocks 0 to N−1 in RAM. `m8-n44-r45` keeps block 45's
experts in RAM with `-ot blk\.45\.ffn_(up|gate|down)_exps=CPU`.

| Cell | `-ncmoe` | Expert layers on the card | VRAM after load, MiB | Free | VRAM-requested memory outside VRAM, max | d8000 prefill / decode, t/s | Fit |
| --- | --- | --- | ---: | ---: | --- | --- | --- |
| `m8-n44` | 44 | blocks 44 and 45 | 29,769 | 935 | 3,863 MiB, 254 of 261 samples | 124.2 / 3.40 | no: under 3,072 free, memory outside VRAM |
| `m8-n45` | 45 | block 45 | 26,307 | 4,397 | 1,890 MiB, 203 of 225 samples | 156.9 / 3.62 | no: memory outside VRAM |
| `m8-n44-r45` | 44, block 45 in RAM | block 44 | 26,613 | 4,091 | 1,890 MiB, 215 of 237 samples | 158.0 / 3.19 | no: memory outside VRAM |
| `m8-n46` | 46 | none | 22,131 | 8,573 | 0 | 168.9 / 3.20 | **yes** |

- **Block 45's experts on the card have no fit at n-max 8.**
  - At `-ncmoe 44`, the server requested 30,774 MiB at load, and 1,021 MiB of it stayed outside
    VRAM from the start.
  - At `-ncmoe 45`, with only block 45's experts on the card, 4,397 MiB was free after load.
    From the d8000 request on, 1,584–1,890 MiB was still outside VRAM.
  - No placement with block 45's experts on the card holds fewer experts than `-ncmoe 45`.
- **With block 45's experts in RAM, the fit is `-ncmoe 46`:** every expert in RAM.
  - `-ncmoe 44` with block 45 overridden to RAM left 4,091 MiB free and put the same
    1,584–1,890 MiB outside VRAM.
  - `-ncmoe 46` left 8,573 MiB free after load and 8,229 MiB at the least, with nothing outside
    VRAM.
- **What MTP takes in VRAM at n-max 8:** 4,859 MiB for the head without its experts and its
  draft context. That is `m8-n46` against stage 3's `dio-experts-ram` (17,272 MiB, the same
  placement without MTP).
  - Stage 1's `base-mtp3` measured 1,206 MiB at micro-batch 1024, one slot and n-max 3.
  - Block 45's experts add 4,176 MiB and block 44's 4,482. The cells' loads are `m8-n46` plus
    those figures, and the server's request at `-ncmoe 44` was within 15 MiB of their sum.
- **Free VRAM at micro-batch 4096 on one card:** every cell with 4.1–4.8 GiB free after load has
  put memory outside VRAM: here, and stage 2's `f2-43`. Cells with 7.4 GiB or more stayed clean
  through the ~5.8k-token request. In both cells here the margin was met, and the residency
  check did the rejecting.
- **Decode at n-max 8 is about half of decode without speculation.**
  - d8000 code decode was 3.19–3.62 t/s in all four cells, 3.20 in `m8-n46` with nothing
    outside VRAM.
  - Without MTP, d8000 code decode was 6.41 t/s for stage 4's `dio-4096-t32` and 6.01 for stage
    3's `dio-experts-ram` (16 threads).
  - Draft acceptance was 24.6–28.8% at d8000 and 27.5–29.6% at two streams.
  - Two streams gave 5.64–6.07 t/s aggregate, against stage 4's 9.07.
  - One pass, so these figures are for orientation; 7b scans the draft length.
- **Output:** each cell's d8000 code text differs from the others' and from stage 4's text
  without MTP; the differences start within the first ~200 characters. All read coherently,
  with 8-gram uniqueness 1.0. Two streams completed in every cell.
- **Contract:** clean at every effort value, with MTP on, on the first pass of `m8-n44` and of
  `m8-n46`, the one cell each sweep checked.
- **Card and CPU, per phase** (`SUMMARY.md` medians, all four cells):
  - prefill 146–175 W at 2,356–2,382 MHz, 99% busy;
  - decode 46 W at 528–538 MHz, 64–69% busy, on 18.8–20.1 cores;
  - two streams 42–44 W, 57–63% busy, on 22.5–23.1 cores.
- **Heat:** junction peaked at 72–74 °C in prefill; hottest DIMM 55–56 °C.

### Stage 7b, MTP draft-length scan — 2026-10-12 16:04–17:26 ET

Harness `e34917a`, cells
[`2026-10-10-configurations-mtp-scan.cells`](2026-10-10-configurations-mtp-scan.cells): one
pass, `REPS=1 DEPTHS=0,8000 PROBE_CHAT=true`, every prompt class, two streams. 7a's fit,
`-ncmoe 46` (every expert in RAM), with `dio`, batch and micro-batch 4096, 32 threads, f16 KV,
context 65536, two slots and compute job timeout 10 s. The lengths ran in the order 3, 7, 1,
5, 2, 8, 6, 4. Raw data on the host: `/root/glm53-flash/sweep-mtp-scan-20261012T200414Z/` and
`residency-mtp-scan.jsonl`.

Decode is the median of the six prompt cells, and prefill the d8000 requests' median. Stage
4's `dio-4096-t32` (`-ncmoe 44`, no speculation, same card, three passes) is shown for
orientation; one-pass figures are not compared by the spread rule.

| n-max | VRAM after load, MiB | Least free, MiB | Decode, t/s | d8000 prefill, t/s | Two streams, aggregate t/s | Acceptance at two streams |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 19,911 | 10,254 | 7.82 | 169.4 | 11.71 | 89.9% |
| **2** | 20,202 | 9,957 | **8.47** | 169.9 | **12.34** | 74.1% |
| 3 | 20,493 | 9,663 | 6.94 | 169.9 | 12.01 | 65.0% |
| 4 | 21,135 | 9,386 | 6.60 | 169.8 | 7.42 | 54.8% |
| 5 | 21,434 | 9,096 | 6.20 | 170.0 | 7.32 | 47.4% |
| 6 | 21,733 | 8,803 | 5.52 | 169.7 | 7.03 | 39.7% |
| 7 | 21,840 | 8,512 | 4.97 | 169.8 | 7.14 | 36.4% |
| 8 | 22,131 | 8,220 | 3.14 | 169.1 | 6.12 | 29.7% |
| stage 4 `dio-4096-t32` | 21,750 | — | 6.635 | 174.7 | 9.07 | — |

Decode per prompt cell, t/s, with draft acceptance:

| n-max | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 8.65 (90%) | 7.47 (65%) | 7.75 (71%) | 7.97 (86%) | 6.81 (57%) | 7.89 (82%) |
| 2 | 9.30 (73%) | 7.03 (47%) | 8.50 (63%) | 8.56 (73%) | 6.31 (40%) | 8.44 (70%) |
| 3 | 8.98 (64%) | 6.02 (30%) | 7.85 (50%) | 7.29 (57%) | 5.38 (31%) | 6.59 (46%) |
| 4 | 8.49 (54%) | 5.31 (24%) | 7.18 (41%) | 7.03 (47%) | 4.72 (24%) | 6.18 (37%) |
| 5 | 7.75 (44%) | 4.82 (20%) | 6.74 (35%) | 6.67 (41%) | 4.19 (18%) | 5.74 (32%) |
| 6 | 6.82 (37%) | 4.32 (16%) | 5.91 (29%) | 6.09 (35%) | 3.90 (16%) | 5.12 (27%) |
| 7 | 6.02 (29%) | 4.11 (15%) | 5.34 (24%) | 5.06 (26%) | 3.91 (17%) | 4.87 (24%) |
| 8 | 3.44 (27%) | 2.34 (14%) | 3.19 (23%) | 3.13 (25%) | 2.00 (11%) | 3.15 (25%) |
| stage 4 `dio-4096-t32` | 6.92 | 6.90 | 6.90 | 6.41 | 6.37 | 6.37 |

- **Best length: n-max 2, at one stream and at two.**
  - n-max 4 to 8 are more than 10% below it at both stream counts (n-max 4: 22% and 40%), so
    the scan has gone far enough.
  - n-max 1 is 7.7% below at one stream and 5.1% at two. n-max 3 is 18.1% and 2.7% below.
  - 7c times n-max 1, 2 and 3.
- **Against stage 4's best configuration without speculation**, n-max 2 decoded 28% faster at
  one stream and 36% faster at two. Its d8000 prefill was 2.7% lower.
  - It led in five of the six prompt cells. In d8000 list it was 6.31 t/s at 40% acceptance,
    against stage 4's 6.37.
  - The placements differ: here every expert is in RAM, and in stage 4 block 44's are on the
    card. 7c's control runs `-ncmoe 46` without speculation.
- **Acceptance falls with length in every class.** List is accepted least at every length: at
  n-max 2, 40–47%, against 63–73% for code and prose.
- **Two drops, where a step checks more than 8 tokens** (n-max plus one per stream).
  - Two streams: 11.71–12.34 t/s aggregate at n-max 1–3, then 7.03–7.42 at 4–7 and 6.12 at 8.
    At n-max 4, two streams check 10 tokens per step.
  - One stream: decode falls gradually from n-max 2 to 7, then from 4.97 to 3.14 t/s at 8,
    while acceptance falls by at most 6 points in any prompt cell. At n-max 8, one stream
    checks 9 tokens.
  - In those phases the container used 20–23 CPU cores, against 28–31 in the others, and
    GPU busy rose to 50–66%, from 39–45%.
  - Flash-Next's head dropped at the same two points ([MTP record](../../qwen38-flash-next/runs/2026-10-09-mtp.md)).
- **Card and CPU, per phase** (`SUMMARY.md` medians):
  - prefill 175–181 W at 2,352–2,360 MHz, 99% busy, at every length;
  - decode 50–51 W at 499 MHz on 28.4–29.8 cores at n-max 1–7, and 46 W at 525 MHz on
    20.2 cores at 8;
  - two streams 48–49 W on 30.2–30.5 cores at n-max 1–3, and 43–44 W on 22.4–23.1 cores at
    4–8.
- **VRAM:** load grew by about 317 MiB per draft token, from 19,911 MiB at n-max 1 to 22,131 at
  8. n-max 8 reproduced 7a's `m8-n46` load exactly.
  - Nothing went outside VRAM at any length. The least free was 8,220–10,254 MiB.
  - Left out of the least-free figures: one or two samples per cell that read the card total
    1.9–4.8 GiB above the server's request. They match, in size and in lasting one sample,
    the compute-buffer swaps the [findings record](2026-10-13-findings.md) traced, or caught the
    previous server unloading.
  - At n-max 1 and 3, VRAM after the probe read 1.4–1.5 GiB below VRAM after load. The server's
    request moves with requests (18.4–20.4 GiB at n-max 1), and the card total follows it. The
    after-probe reading fell between requests.
- **Block 45's experts on the card at a short draft were not tested.** The fit was set at n-max
  8. At n-max 1–3, adding block 45's 4,176 MiB to these loads would leave an expected 6.0–6.6
  GiB free after load. That lies between the 4.1–4.8 GiB at which cells have put memory outside
  VRAM and the 7.4 GiB at which cells have stayed clean.
- **Prefill:** 169.1–170.0 t/s at d8000 at every length.
- **Output:**
  - n-max 8's d8000 code text is identical to 7a's `m8-n46` text, from a separate load of the
    same configuration.
  - The text changes with draft length, and no length's text matches stage 4's without MTP in
    any prompt cell. Some lengths share a text:
    - n-max 1 and 2 at d0 code;
    - n-max 3 to 6 at d0 code and d0 list;
    - n-max 3, 4 and 6 at d0 prose;
    - n-max 3 and 4 at d8000 code and list;
    - n-max 5 and 6 at d8000 code and prose.
  - Every text reads coherently. 7c compares each length's text with its control's.
  - Only d0 list stopped before the 256-token limit: at n-max 1–7, after 20 items (202–248
    tokens).
  - At n-max 8, the d0 list reply listed 21 items, then wrote "Wait, that's 21. Let me fix that.
    Here are exactly 20:" and started the list again. That reply's 8-gram uniqueness is 0.976.
    Every other reply's is 1.0.
  - Two streams completed in every cell; all replies reached the limit.
- **Contract:** clean at every effort value, at n-max 3, the first cell.
- **Heat:** junction peaked at 77–81 °C in prefill; hottest DIMM 57–58 °C.

### Stage 7c, MTP timed — 2026-10-12 17:29–20:08 ET

Harness `3a88a0c`, cells [`2026-10-10-configurations-mtp.cells`](2026-10-10-configurations-mtp.cells):
three passes, `DEPTHS=0,8000 CONC_REPS=3 PROBE_CHAT=true`, every prompt class. `dio`, batch and
micro-batch 4096, 32 threads, f16 KV, context 65536, two slots, compute job timeout 10 s. Raw data
on the host: `/root/glm53-flash/sweep-mtp-20261012T212915Z/` and `residency-mtp.jsonl`. Figures as
in stage 3; acceptance at two streams is the range over passes.

7b's best length at one and two streams was n-max 2. `mtp-n1`, `mtp-n2` and `mtp-n3` run it and
the lengths one below and above at `-ncmoe 46`. `nospec-n46` is the same placement without
speculation, and `nospec-n44` is stage 4's `dio-4096-t32`. Stage 4's row is repeated for
comparison.

| Cell | `-ncmoe`, n-max | VRAM after load, MiB | Least free, MiB | Load, s | Decode, t/s | d8000 prefill, t/s | Two streams, aggregate t/s | Acceptance at two streams |
| --- | --- | ---: | ---: | ---: | --- | --- | --- | ---: |
| `mtp-n1` | 46, 1 | 19,911 | 10,252 | 119–121 | 7.685 [7.675–7.890] | 169.6 [169.2–169.7] | 11.21 [11.00–11.23] | 83–89% |
| `mtp-n2` | 46, 2 | 20,202 | 9,957 | 118–119 | **8.410** [8.235–8.465] | 169.6 [169.6–169.6] | **12.01** [11.86–12.31] | 74–78% |
| `mtp-n3` | 46, 3 | 20,493 | 9,661 | 118–119 | 6.865 [6.835–6.965] | 169.7 [169.4–169.9] | 11.69 [11.60–11.72] | 63–65% |
| `nospec-n46` | 46, — | 17,268 | 13,431 | 115–116 | 6.455 [6.445–6.495] | 173.1 [172.7–173.2] | 8.71 [8.70–8.86] | — |
| `nospec-n44` | 44, — | 21,750 | 8,951 | 112 | 6.495 [6.465–6.505] | **174.7** [174.6–174.8] | 9.01 [8.95–9.03] | — |
| stage 4 `dio-4096-t32` | 44, — | 21,750 | — | 115–116 | 6.635 [6.585–6.655] | 174.7 [174.4–174.7] | 9.07 [9.06–9.12] | — |

Decode per prompt cell, t/s, median of the three passes, with draft acceptance (the same in
every pass):

| Cell | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `mtp-n1` | 8.53 (90%) | 7.45 (65%) | 7.74 (71%) | 7.96 (86%) | 6.71 (57%) | 7.63 (82%) |
| `mtp-n2` | 9.00 (73%) | 7.24 (47%) | 8.45 (63%) | 8.51 (73%) | 6.29 (40%) | 8.37 (70%) |
| `mtp-n3` | 9.25 (64%) | 6.09 (30%) | 7.86 (50%) | 7.36 (57%) | 5.25 (31%) | 6.41 (46%) |
| `nospec-n46` | 6.76 | 6.75 | 6.76 | 6.17 | 6.23 | 6.16 |
| `nospec-n44` | 6.82 | 6.82 | 6.70 | 6.18 | 6.26 | 6.16 |

d8000 prefill per class, t/s, median of the three passes:

| Cell | code | list | prose |
| --- | ---: | ---: | ---: |
| `mtp-n2` | 168.3 | 169.6 | 169.8 |
| `nospec-n44` | 174.4 | 175.0 | 174.7 |
| `mtp-n2` against `nospec-n44` | −3.5% | −3.1% | −2.8% |

**Best MTP cell: `mtp-n2`.**
- Its decode leads `mtp-n1` by 0.725 t/s and `mtp-n3` by 1.545, beyond both cells' spreads.
- At two streams it leads `mtp-n1` beyond the spread. Its lead over `mtp-n3`, 0.32 t/s, is
  within its own spread of 0.45.

**`mtp-n2` against the configurations without speculation:**

| | Decode | d8000 prefill | Two streams |
| --- | ---: | ---: | ---: |
| Against `nospec-n46` (same placement) | +30.3% | −2.0% | +37.9% |
| Against `nospec-n44` (stage 4's configuration) | +29.5% | −2.9% | +33.3% |

- Every difference is beyond both cells' spreads.
- Per prompt cell against `nospec-n44`, decode leads beyond the spread in five of six. In d8000
  list it is within the spread: 6.29 against 6.26, at 40% acceptance.
- MTP at n-max 2 takes 2,934 MiB at load: `mtp-n2` against `nospec-n46`.

**Card and CPU, per phase** (`SUMMARY.md` medians; prefill ran on 0.4 cores in every cell, and
every phase at 499 MHz except prefill):

| Cell | Prefill: W, MHz, busy | Decode: W, busy, cores | Two streams: W, busy, cores |
| --- | --- | --- | --- |
| `mtp-n1` | 176, 2,362, 99% | 51, 42%, 29.6 | 48, 39%, 30.5 |
| `mtp-n2` | 179, 2,362, 99% | 51, 42%, 29.8 | 48, 36%, 30.3 |
| `mtp-n3` | 176, 2,364, 99% | 51, 44%, 28.4 | 48, 36%, 30.4 |
| `nospec-n46` | 178, 2,357, 99% | 52, 50%, 30.7 | 48, 40%, 30.8 |
| `nospec-n44` | 176, 2,363, 99% | 52, 49%, 30.3 | 49, 41%, 30.4 |

**MTP criteria, `mtp-n2`:**
1. Decode beats both `nospec-n46` and `nospec-n44`: **holds**.
2. Two streams are not lower than `nospec-n44`'s: **holds**.
3. d8000 prefill is within 10% of `nospec-n44`'s in every class (−2.8% to −3.5%): **holds**.
4. 32-token replies: the short-reply sweep below.

**Placement without speculation** (`nospec-n44` against `nospec-n46`):
- Decode is within the spread: 6.495 against 6.455.
- Block 44's experts on the card add 0.9% d8000 prefill and 3.4% at two streams, both beyond
  the spreads.

**`nospec-n44` decoded 2.1% below stage 4's same configuration**, beyond both spreads.
- Decode: 6.495 against 6.635, and 6b's `1c-best` had 6.625. It was lower in every prompt cell,
  by 1.2–3.6%.
- Prefill matched stage 4 (174.7), and two streams were within the spread (9.01 against 9.07).
- The server command line, the captured environment and the six texts are the same as stage
  4's. Decode used 30.3–30.4 CPU cores and 52 W on the card in both.
- Cause not measured. 7c's comparisons are among its own interleaved cells.

**Residency:** nothing went outside VRAM in 9,571 samples.

- Up to two single samples per pass read the card total 1.3–6.7 GiB above the server's request.
- They match, in size and in lasting one sample, the compute-buffer swaps the
  [findings record](2026-10-13-findings.md) traced, or caught a server unloading.
- They were excluded.

**Output:**
- Every cell gave the same text in every pass.
  - Each MTP cell's texts are 7b's at that length, in all six prompt cells.
  - `nospec-n44`'s are stage 4's.
- MTP texts differ from the control's (`nospec-n46`) in every prompt cell, at every length.
  - The texts diverge between the first character (d0 code) and character 267 (d8000 prose).
  - Read for sense: both sides answer the prompt coherently, and the differences are wording,
    order and choice of items. For example, at d0 code, `mtp-n2` opens with a heading where the
    control opens with "Here's a robust implementation". At d8000 list, the two diverge at
    "partitions isolate" against "partition isolates", 37 characters in.
- Without speculation, the placement also changes the text: `nospec-n46` and `nospec-n44` match
  in four prompt cells. They differ in both list cells, from character 264 at d0 and 617 at
  d8000.
- **The control's d8000 list reply repeats item 14, then breaks off:** "14. Ret asked to list 20
  distinct failure modes".
  - Its 8-gram uniqueness is 0.974, the same in all three passes.
  - No MTP reply repeats a line, and every other reply's 8-gram uniqueness is 1.0.
- d0 list stopped after 20 items in every cell (213–248 tokens); every other reply reached the
  256-token limit.
- **Two streams:** every round completed in every cell and pass, and every reply reached the
  limit. Each stream gave 2–5 distinct texts per cell.
- **Contract:** clean at every effort value, on `mtp-n2`'s first pass.
- **Heat:** junction peaked at 77–82 °C in prefill; hottest DIMM 58–59 °C.

### Stage 7c, short replies — 2026-10-12 20:11–20:32 ET

Harness `7a44e90`, cells
[`2026-10-10-configurations-short.cells`](2026-10-10-configurations-short.cells): three passes,
`N_PREDICT=32 DEPTHS=0,700 PROBE_CHAT=true`, every prompt class, `mtp-n2` against `nospec-n44`
with 7c's settings. Prompts were 31–42 tokens at d0 and 504–515 at d700. Raw data on the host:
`/root/glm53-flash/sweep-short-20261013T001059Z/` and `residency-short.jsonl`.

Decode and prefill are the median across the three classes in each pass; request time is the
median time per request. Each figure is the median of the three passes [range].

| Cell | Depth | Decode, t/s | Prefill, t/s | Request time, s |
| --- | --- | --- | --- | --- |
| `mtp-n2` | d0 | **8.966** [8.863–9.045] | 12.2 [12.1–13.4] | 7.04 [6.20–7.13] |
| `nospec-n44` | d0 | 6.808 [6.757–6.858] | 14.5 [13.9–14.5] | 7.20 [7.14–7.32] |
| `mtp-n2` | d700 | **8.561** [8.500–8.620] | 55.6 [55.2–55.7] | 12.86 [12.83–12.99] |
| `nospec-n44` | d700 | 6.704 [6.679–6.781] | 57.6 [57.6–57.8] | 13.44 [13.38–13.47] |

Decode per prompt cell, t/s, median of the three passes, with draft acceptance:

| Cell | d0 code | d0 list | d0 prose | d700 code | d700 list | d700 prose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `mtp-n2` | 8.97 (75%) | 6.81 (42%) | 9.04 (75%) | 8.62 (69%) | 6.38 (38%) | 8.56 (69%) |
| `nospec-n44` | 6.81 | 6.71 | 6.86 | 6.65 | 6.95 | 6.70 |

- **32-token replies decode faster with MTP at both depths**: +31.7% at d0 and +27.7% at d700,
  beyond both cells' spreads. Criterion 4 holds.
- **Request time:**
  - At d700 it was 4.3% shorter with MTP, beyond the spreads.
  - At d0 it was 2.2% shorter, within MTP's spread of 0.93 s.
- **Prefill was slower with MTP**, beyond the spreads at both depths:
  - −15.9% at d0 (12.2 against 14.5 t/s, on 31–42 tokens);
  - −3.5% at d700.
- **List is the weakest class.** At d700 list, MTP decoded 6.38 t/s against 6.95 (−8.2%),
  within MTP's spread of 0.72; one pass read 5.66. At d0 list it was 6.81 against 6.71.
- **Two streams** (one round per pass, 32 tokens): 11.67 [11.57–11.70] t/s aggregate against 8.67
  [8.22–8.83], +34.6%, at 78.7% acceptance.
- **Output:**
  - Every cell gave the same text in every pass.
  - The two cells' 32-token texts match in three prompt cells: d0 list, d700 code and d700
    prose.
  - Every reply reached the 32-token limit, with 8-gram uniqueness 1.0.
- **Residency and heat:**
  - Nothing went outside VRAM in 499 samples.
  - Contract clean on `mtp-n2`'s first pass.
  - Junction peaked at 60–63 °C; hottest DIMM 53–55 °C.
- **Card and CPU, per phase** (`SUMMARY.md` medians):
  - `mtp-n2` prefilled at 138 W and 2,379 MHz on 0.6 cores, and decoded at 48 W and 499 MHz,
    41% busy, on 29.8 cores;
  - `nospec-n44` prefilled at 132 W and 2,383 MHz on 0.6 cores, and decoded at 51 W and
    499 MHz, 44% busy, on 30.4 cores;
  - two streams: 46 W on 23.5 cores with MTP, against 48 W on 29.4 without.

**All four MTP criteria hold for `mtp-n2`, so by the plan's rule MTP at n-max 2 joins the best
configuration.**

### Restore — 2026-10-12 20:33–20:35 ET

`ct123-test-host.sh restore` from harness `7a44e90`, with a residency sampler on GPU 2
(`residency-restore.jsonl`):
- **What restore put back:**
  - CT 123's limits are back to 24 cores and 120 GiB.
  - CT 120's `onboot` is 1, and CT 120 stays stopped.
  - The watchdog map is back to `0000:03:00.0=120:llamacpp,0000:83:00.0=123:llamacpp-qwen38fn`.
  - `llamacpp-qwen38fn` is enabled and running, and `llamacpp-glm53f` is disabled.
- **Flash-Next:**
  - It served at 20:34:57 ET.
  - It answered "OK" to a short chat request.
  - It summarized an 8,803-token prompt correctly, at 329.0 t/s prefill and 23.1 t/s decode,
    with 12 of 12 drafts accepted.
  - The least free VRAM was 3,255 MiB, and nothing went outside VRAM in 129 samples. GTT is
    58,044 MiB, its pinned experts.
- The residency sampler and the GLM thermal guard were stopped at 20:35 ET.
- CT 121, 140, 200 and 201 and VM 300 are still off; starting them waits for the owner.

## Deviations

- **Stage order, changed after stage 1** (owner, 2026-10-10): MTP runs last, as stage 7,
  on the configuration the other stages settle, right before the usage test. The committed
  plan ran MTP as stages 5–6, fitted its placements in stage 2 and scanned it again on two
  cards. MTP's fit and best draft length depend on micro-batch, threads, context and card
  count, and its draft context grows with the total context (#28433). Stage 5 is now
  context (was 7), stage 6 two cards without MTP (was 8), and stage 7 MTP (was 5–6, plus
  the MTP fit from stage 2). Stage 1's `base-mtp3` cell measured only MTP's VRAM and its
  image-request failure.
- **Probe mode from stage 3** (owner, after stage 1): requests go through the chat template
  (`PROBE_CHAT=true`). With the raw `/completion` prompt, GLM continued the d8000 filler
  instead of answering, which failed the output gate and put MTP's d8000 acceptance at 99%;
  through the chat template the same prompt was answered. Stages 1 and 2 used raw
  `/completion`; stage 2 measures only VRAM and residency.
- **Stage 1:** b11505's llama-server prints no per-buffer sizes at its default log level
  (`-lv 3`), so the VRAM components come from the differences between cells.
- **Stage 1:** the `--reasoning-budget 0` repeat of `base` ran by hand, as described under the
  contract table, not as a sweep cell.
- **Stage 1:** `ct123-test-host.sh one-card` warned that CT 123 was "not fully up" and waited 60 s.
  CT 123 had booted in 2.5 s: it reports `degraded` because AppArmor cannot load profiles in an
  unprivileged container, and under `pipefail` the script never matched that state. Fixed after
  the stage, with a mocked-test check.
- **Stage 3:** a hand check, not in the plan, followed the sweep: `dio-1024`'s prefill was 19%
  below stage 2's for the same placement, and raw and chat requests were alternated on one load to
  tell a host change from a request change. It ran from a scratch script, not from the pinned
  harness. It used the harness's `placement-probe.py` and the cell's settings.
- **Stage 3:** the stage took 4 h against the 3.5 h estimate. Its CPU-only cells took about
  29 min each.
- **Stage 4:** the stage took 6 h against the 4.5 h estimate. The CPU-only cells took 28–30 min
  each, and three of them ran per pass.
- **Stage 5 split into 5a (fit) and 5b (timed)**, after stage 4.
  - The plan ran each context "at its own fit" but had no step that finds it.
  - Stage 1 measured 128k and 256k only at micro-batch 1024. #29950 has the compute buffer
    growing with context × micro-batch, so 4096 needs its own fit.
  - 5a applies the stage 2 rule at one slot. Its residency check runs through each context's
    deepest request, because the least free VRAM in stage 1's 256k cell came during prefill.
- **Host change after 5a: amdgpu compute job timeout 10 s** (owner, 2026-10-11).
  - 5a's requests deeper than 64k hit amdgpu's 2,000 ms job timeout (see 5a).
  - `amdgpu-lockup-timeout.sh` sets `lockup_timeout=2000,10000,2000,2000` (GFX, compute, SDMA,
    video), and the host was rebooted to apply it. Before the reboot, the `onboot` flags of
    CT 120, 121 and 140 and VM 300 were turned off, and restored afterwards, so that no other
    guest started.
  - 5a's two `-ncmoe 46` cells rerun with
    [`2026-10-10-configurations-ctx-fit-rerun.cells`](2026-10-10-configurations-ctx-fit-rerun.cells).
    Stages 5b–7 run with the new timeout. Stages 1–5a ran with the default, except the 5a
    rerun.
- **Stage 5b adds `ctx64k-n46`**, 64k at 128k's placement. 64k and 128k fit at different
  placements (`-ncmoe 44` and 46), so without it a difference between the two contexts could
  come from the expert layer.
- **The 3,072 MiB margin is provisional** (owner, 2026-10-12, during stage 6a). It stays in the
  fit rule, and each stage's fit still meets it, but it is not a hard limit until a test shows
  GLM putting memory outside VRAM because less was free.
  - The margin comes from Flash-Next, not from GLM ([prefill-slowdown
    record](../../qwen38-flash-next/runs/2026-10-10-prefill-slowdown.md)). There, `-ncmoe 37`
    kept everything in VRAM with 3,274 MiB free. `-ncmoe 36`, with about 1,800 MiB free, was
    clean through the sweep's probe but put a 1,024 MiB buffer in GTT during the usage batch.
  - On GLM, the residency check has done the rejecting: stage 2's `f2-43` put 1,890 MiB outside
    VRAM with 4,777 MiB free.
  - A placement that misses only the margin, with nothing outside VRAM through its probe, is
    reported as margin-only, so the owner can choose it. Stage 2's `f1-42` (2,329 MiB free) was
    one. As on Flash-Next, a clean probe is not the whole test: the usage test is where such a
    placement would show buffers outside VRAM.
- **Stage 6a round 2 adds `2c-n37-s38`,** a margin test. In round 1, the memory that went
  outside VRAM was on GPU 1, and GPU 2's allocation grew by only about 100 MiB during requests.
  `-ncmoe 37` at split 38,8 leaves GPU 2 an expected 700–900 MiB free. It tests whether GPU 2
  needs the margin; it cannot be the fit, which still meets the margin.
- **Stage 6a tested the margin on two cards.** Every placement under it put memory outside VRAM:
  GPU 1 at 2.4–2.5 GiB free, and GPU 2 at 1.1 GiB. One card at micro-batch 1024 kept everything
  in VRAM with 2.3 GiB free (stage 2's `f1-42`). The headroom needed depends on the
  configuration, so the margin stays in the rule as before.
- **Stage 7b has no block-placement comparison.** The plan compared block 45's experts on the
  card and in RAM at n-max 3, each at its n-max 8 fit. Block 45's experts on the card have no
  fit at n-max 8 (7a), so the scan runs at the one fit, `-ncmoe 46`.
- **Corrected after the record was done** (owner, 2026-10-13, after PR review):
  - **Stage 1's peak-VRAM sentence misstated two readings.** It gave 20,910 MiB as "about
    20.9 GiB" and `base-ub4096`'s 17,955 MiB peak as 17,081. It also read one sample's
    compute-buffer swap as a peak above the load reading.
  - **Stages 4 and 7 lacked the per-phase card figures** the plan asks for. They are now
    added from each sweep's `SUMMARY.md` on the host.
  - **Stages 5b, 7b and 7c left the brief VRAM rises unexplained or called them read races.**
    The findings record traced rises of the same sizes to compute-buffer swaps. Those passages
    now point there.

## Conclusion

All figures are from b11505 on Vulkan (RADV, Mesa 26.2.4), UD-Q4_K_XL, in CT 123. One card is
GPU 2 (`0000:83:00.0`). Decode is the median of the six prompt cells and prefill is at ~5.8k
tokens, unless noted.

- **Load and contract:**
  - b11505 loads the model and its MTP block on RADV, on one card and on two.
  - Two slots work without `--kv-unified`.
  - `--reasoning off` alone does not give clean content: bare chat, `none` and `max` returned
    empty content. With `--reasoning-budget 0`, every effort value answered with no
    reasoning block, and no think tag reached `content`.
  - Tool calls work streamed and not.
  - Image requests work without MTP and fail with HTTP 500 under MTP (#30204).
  - **The contract was checked on one cell per sweep:** its first load, named in each stage.
    Other KV types, placements and draft lengths were not each checked. From PR #103,
    `placement-sweep.sh` runs it after every cell load.
- **What the card holds** (stage 1: context 65536, micro-batch 1024, one slot):
  - Every routed expert in RAM: 15,461 MiB at load.
  - q8_0 KV saves 577 MiB.
  - 128k context adds 1,586 MiB and 256k 4,506 MiB at load, and more at depth.
  - Micro-batch 4096 adds 2,490 MiB, and a second slot 77 MiB.
  - At micro-batch 4096 with two slots, MTP takes 2,643 MiB at n-max 1 and 4,859 at n-max 8,
    about 317 MiB per draft token (2,934 at n-max 2).
  - An expert layer is 4,176 MiB, and block 44's 4,482.
- **Prefill:** `dio` prefills fastest.
  - At micro-batch 1024, `-ncmoe 43`: 116.6 t/s, against 41.4 for `auto`. Through raw
    `/completion` on the same load it was 142–143 t/s; the chat-template request prefilled 19%
    slower, cause not measured.
  - At micro-batch 4096 it reached 174.4 t/s at `-ncmoe 44`. That is 1.5 times micro-batch
    1024's, not 4, for one expert layer, with decode within the spread.
- **Decode:**
  - 32 threads decoded fastest: 6.635 t/s at `-ncmoe 44`, 9.07 aggregate at two streams. 16
    threads were within the spread and 24 below it.
  - Block 44's experts on the card against every expert in RAM: decode within the spread at
    ~5.8k tokens, +3.3% at 59k tokens. Prefill +0.9%, and two streams +3.4% in 7c.
- **CPU only:** best at 32 threads, 4.875 t/s decode, 19.2 t/s prefill and 7.55 at two
  streams. Against the best GPU configuration: decode 26.5% lower, prefill 9.1 times slower.
- **Context:**
  - 128k costs one expert layer (`-ncmoe 46` against 44).
  - 256k does not fit on one card at micro-batch 4096: 2.3 GiB went outside VRAM at depth,
    even with every expert in RAM.
  - At 128k, decode fell 29% from 42 tokens to 119k tokens (6.82 to 4.84 t/s). Prefill fell 29%
    from ~5.8k tokens to 119k (172.7 to 123.1 t/s); the 119k request took 16.2 min.
  - At the same placement, 64k and 128k were within each other's spread.
  - Requests past about 65k tokens needed amdgpu's compute job timeout raised from 2 s to 10 s.
- **Two cards:**
  - The fit is `-ncmoe 38` at split 39,7, seven expert layers on the cards against one.
  - Against one card: decode within the spread (+1.4%), two streams +4.3%, prefill +7.5% (187.9
    against 174.8 t/s). Prefill runs on GPU 1 with two cards and on GPU 2 with one; the card
    difference was not separated.
  - `dio` prefilled 1.91 times as fast as `auto`.
  - `-sm tensor` does not load for glm5-next.
- **MTP** (one card, 64k, the owner's choice after stage 6):
  - At n-max 8, micro-batch 4096 and two 32k slots, the MTP block fits only with every expert in
    RAM (`-ncmoe 46`). Block 45's experts on the card at a shorter draft, or at one 64k slot,
    were not tested.
  - The best draft length is n-max 2, at one stream and at two.
    - It was chosen at two 32k slots with timed prompts of about 5.8k tokens.
    - It was not retuned at the one 64k slot the batch used, nor for deep single-slot tasks. Acceptance per prompt cell is
    63–73% for code and prose, 40–47% for list, and 74–78% at two streams.
  - Against the best configuration without it (stage 4's): decode +29.5% (8.410 against 6.495
    t/s) and two streams +33.3%. d8000 prefill is 2.9% lower, within 10% in every class.
  - 32-token replies decode +31.7% at d0 and +27.7% at d700.
  - Against the same placement without it: decode +30.3%, two streams +37.9%, prefill −2.0%.
  - Steps that check more than 8 tokens drop sharply: two streams from n-max 4, one stream at
    n-max 8.
  - MTP's texts differ from the control's in every prompt cell, and both read coherently.
- **Best configuration by the plan's rules:** one card (GPU 2), context 65536, `dio`, batch and
  micro-batch 4096, 32 threads, f16 KV, two slots, `--reasoning-budget 0`, `-ncmoe 46` and MTP
  at n-max 2.
  - It loads at 20,202 MiB, and the least free during requests was 9,957 MiB.
  - Image requests fail with it (#30204).
  - The full benchmark batch on it gets its own record and plan. Whether to deploy GLM is
    decided separately.
- **The 3,072 MiB margin** decided one fit. At micro-batch 1024, `f1-42` kept everything in VRAM
  with 2,329 MiB free, so `-ncmoe 43` is that fit only because of the margin. It is the record's
  only margin-only placement. Elsewhere the residency check did the rejecting:
  - At micro-batch 4096 on one card, every placement with 4.1–4.8 GiB free put memory outside
    VRAM.
  - On two cards, every placement under the margin did.
- **Repeatability:** in 7c, stage 4's configuration decoded 2.1% below its stage 4 figure, with
  the same command line, environment and texts and the same prefill. The cause was not
  measured.
