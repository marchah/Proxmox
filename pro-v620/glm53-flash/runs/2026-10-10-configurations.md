# GLM-5.3-Flash: the fastest configuration on one card, two cards and CPU only

Plan committed 2026-10-10 · Run from 2026-10-10 (stage 1 done) · Status: running

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
- **Stage 5, context** (timed): stages 3–4's configuration at 65536, 131072 and 262144, each
  at its own fit. Per context: the VRAM it costs, in MiB and in expert layers, and decode
  and prefill at each depth it holds. Stage 7 runs at the context the owner picks from
  these results, and at 65536 without a pick.
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
| 5 | `context` | `PROBE_CLASSES=code PROBE_CHAT=true`; depths per cell |
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
- Stage 5's cells set their own depths, code class only: 0, 8000, 82000 (~59k tokens) at
  every context, 165000 (~119k) at 131072 and 262144, and 330000 (~237k) at 262144.
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
- **Peak VRAM sits above the load reading at long context.** During `base-ctx256k`'s prefill the
  least free VRAM was 9,794 MiB, so about 20.9 GiB in use against 19,967 MiB after load;
  `base-ub4096` reached 17,081 MiB.
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

**Contract** (bare chat and `reasoning_effort` `none`, `low`, `high`, `max`):

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

## Conclusion
