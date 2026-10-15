# GLM-5.3-Flash: tuning one 64k slot for long tasks

Plan committed 2026-10-13 · Run from 2026-10-13 · Status: running

Issue #106. The tests, their order and the cuts were agreed with the owner on 2026-10-13. A
second review the same day trimmed the campaign from about 46 h to about 23–29 h of runs.

## Question

The batch configuration ([bench record](2026-10-12-bench.md)) was tuned on two 32k slots with
prompts of about 5.8k tokens, and decoded greedily. Five things about it are untested on the
layout it serves, one 64k slot, with long agent sessions and document ingestion:

- **Placement:** can MTP's block 45 keep its experts on the card at n-max 2? The
  configurations record's stage 7a rejected it at n-max 8 and two slots.
- **Micro-batch:** does 2048 trade prefill for room?
- **Draft length and confidence gating:** how do n-max and p-min behave at depth?
- **CPU settings:** threads, polling and affinity with MTP on.
- **Ingestion prompt:** would a more concise one finish within budget?

Two questions come from the data already collected:

- **Each agent turn pays a fixed ~6.8 s of prefill, whatever its size.**
  - Fitting the batch's 129 warm `hermes` turns gives prompt time = 6.83 s + 6.2 ms per new
    token. Turns under 300 new tokens took a median of 7.6 s, about 17% of `hermes`' request
    time.
  - `coding`'s turns under 32 tokens took 2.3 s.
  - This fits llama.cpp's op offload. For a batch of at least `GGML_OP_OFFLOAD_MIN_BATCH`
    tokens (default 32), Vulkan computes the RAM-resident experts on the card, reading their
    ~190 GB of `dio`-pinned memory over PCIe.
  - Can a higher threshold make short turns cheaper?
- **Every MTP result so far is greedy** (temperature 0, top-k 1), as is the whole suite. Real
  clients use the model's own sampling. Does the choice of n-max hold there?

A newer build is checked first, in stage 0:
- b11583 changes how MTP decodes image input (llama.cpp #30257); images fail under MTP on
  b11505 (#30204).
- It reports compute-graph reallocations (#30329).
- It changes Vulkan's handling of duplicate expert ids (#29998).

## What answers it

Each stage names its winner by the rule below. A later stage runs on the winners before it,
rather than on a Cartesian product.

The **estimated batch time** is used by several stages. It prices every warm `hermes` and
`coding` turn of the bench (186 turns):
- each turn's prefill comes from the cell's turn time per size, interpolated to its new-token
  count;
- its decode is its generated tokens at the cell's median d8000 decode.

0. **Build.** b11583 replaces b11505 for every later stage if all of these hold:
   - its median decode over the six d8000 prompt cells and its d8000 prefill are not lower
     beyond both cells' spreads;
   - every request succeeds, no text is degenerate, and the contract is clean on every load;
   - it loads with the same launcher and settings.

   An image request under MTP is checked on each build and reported either way. If b11583
   is adopted, stage 1's control cell is the baseline rerun on it.
1. **Op-offload threshold** (`GGML_OP_OFFLOAD_MIN_BATCH`).
   - **Measure:** the estimated batch time's prefill part, from each threshold's turn times.
   - **Winner:** the lowest, provided d0 and d8000 decode and d8000 prefill stay within the
     control's spread.
   - Stage 5 checks the winner on real sessions.
2. **Micro-batch and placement**, on stage 1's winner at n-max 2 and one 64k slot.
   - **Fit pass** (one pass, with the trace): `-ncmoe 46` (the control) and `-ncmoe 45`
     (block 45's experts on the card), each at micro-batch 4096 and 2048. If `45` fits at
     neither, a second fit pass tries it at 1024.
   - **Fit rule, recorded before the fit pass.** A cell fits when all four hold through a
     48k-token prompt and the turn probe:
     1. nothing VRAM-requested is outside VRAM, in any sample;
     2. no VRAM allocation fails in the trace;
     3. the least free VRAM including swaps is at least 1,024 MiB;
     4. the least free outside swaps is at least 3,072 MiB.
   - Rule 3 is the swap-transient margin: the batch reached 1,007 MiB free during a swap
     with nothing outside VRAM, and less has not been tested. Rule 4 is the provisional
     margin.
   - A cell that holds rules 1 and 2 but misses 3 or 4 is reported as margin-only, for the
     owner.
   - **Timed:** the control and every other cell that fits, for three passes.
   - **Reported:** decode, d8000 prefill, the turn probe's 30k prime (a cold prefill), turn
     times, steady free VRAM, and the least free including swaps, with swap sizes from the
     trace.
   - **Winner:** the lowest estimated batch time.
3. **Draft length and confidence.** n-max 1, 2 and 3, each at `--spec-draft-p-min` 0, 0.2,
   0.3 and 0.5: 12 cells.
   - **Prompts:** code, list and prose at 8k and 48k tokens of the pinned corpus, with a
     640-token output.
   - **Screen:** one pass over all 12 cells and a no-speculation cell at the same placement
     (`nospec`), the correctness control CLAUDE.md requires when a drafter is tested.
   - **Retained cells:** the three with the lowest summed decode time over the six requests,
     plus n-max 2 at p-min 0 (the control). They get two more interleaved passes, three in
     all. A cell with a failed, empty or degenerate reply is not retained.
   - **Winner:** the lowest summed request time over the three passes. Also reported:
     - acceptance, and draft tokens wasted (drafted minus accepted);
     - whether each text matches the n-max 2 control's;
     - whether each text matches `nospec`'s. Batched verification can change the text, as
       in the configurations record's stage 7c, so a text that differs is read for
       coherence, not failed.
   - **Model's own sampling:** the winner, the runner-up and the control run again for
     three passes with `--sampling server --seed 1234`. If the order changes, the record
     says so.
4. **CPU.** On stages 1–3's configuration, compare:
   - 24 and 32 threads;
   - 32 with `--poll 0`;
   - 32 pinned one thread per physical core of the container's cpuset (`--cpu-mask`,
     `--cpu-strict 1`).

   Measures: decode at d0 and d8000, turn times, CPU cores per phase, and the hottest DIMM.
   The winner is the lowest estimated batch time.
5. **Long tasks.** `make bench GPU=2 MODEL=glm53f SUITE=workloads` runs agent sessions to 56k
   and ingestion on the winner of stages 1–4.
   - **The control** is the bench's own workload run when stage 0 keeps b11505: same build,
     configuration and suite, a week earlier. The record quotes that age, since stage 7c of
     the configurations record measured a 2.1% repeat drift. If stage 0 adopts b11583, the
     control runs again on it.
   - **Reported:**
     - session time, prefill time per turn, decode, cache continuity;
     - ingestion latency, complete notes and the quality check;
     - per-token speed separately from any saving from shorter replies.
   - A tool-call check (streamed and not) runs on the winner by hand.
6. **Concise ingestion prompt.** On the winner, `--prompt standard` against `--prompt
   concise` at 8k and 48k, with a 2,048-token cap so both can finish. Three alternating
   repetitions.
   - **Reported:** time to a complete note, word count, the format check (5 summary
     sentences, 8 key facts, 3 open questions) and key facts holding a value found verbatim
     in the documents.
   - A note that drops a required section fails, however short.
   - Facts without such a value are read by hand.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| One GPU | CT 123 holding `0000:83:00.0`, the batch's configuration as the starting point and control: `-ncmoe 46`, `dio`, batch and micro-batch 4096, 32 threads, f16 KV, context 65536 in one slot, `--reasoning-budget 0`, MTP at n-max 2. Each stage varies only its own settings. |

- **Two GPUs and CPU only:** left out. The owner chose one card, and #106 tunes that layout.
- **Optimized:** stage 2 measures the room left on the card.
- **Speculative decoding:** MTP throughout. Stage 3 tunes it; the issue rules out another
  full workload without MTP. A cell without speculation runs only as a correctness
  control: stage 3's `nospec`, one screen pass.
- **Cut from #106 (owner, 2026-10-13):**
  - **The MoE cache with `dio`.** Including swaps the batch had about 1 GiB free, so a cache
    would hold under one expert layer of 46.
  - **Ingestion at four depths:** two are enough, because each depth's text repeats
    exactly across reps.
  - **`-ncmoe 44` with block 45's experts in RAM.** It puts a larger layer on the card
    (4,482 MiB), and stage 7c of the configurations record measured no decode gain beyond
    the spread from block 44 on the card.
  - **Stage 3's outputs of 256 and 1,024 tokens, and the 32k depth.** Under greedy decoding,
    the 256- and 640-token replies are the first part of the 1,024 one, and 32k lies
    between 8k and 48k.
  - **The turn probe in stage 0**, which stage 1 runs anyway, and **16, 20 and 28 threads**
    in stage 4.
  - **A separate micro-batch stage:** 2048 is tested inside stage 2, where its point is the
    room it frees.
- **Added (owner, 2026-10-13):** the op-offload threshold, the model's own sampling, and the
  build check.

**Install and restore:**
- `ct123-test-host.sh one-card` stops Flash-Next and gives CT 123 240 GiB and 48 cores.
- `install.sh` with `glm53f-bench.env` writes the configuration.
- `install-llamacpp-release.sh` adds b11583 beside b11505.
- Each sweep writes its cells' settings into the env file and restores it afterwards.
- Stage 5 installs the winner as an env file committed before the stage.
- `ct123-test-host.sh restore` puts Flash-Next back after the campaign, and after any
  pause the owner asks for.

## Controls

- **Stages 0–4:** the batch's configuration on the stage's build is the control cell. It
  runs interleaved with the other cells, at least three passes each, in every timed stage.
- **Stage 3:** n-max 2 at p-min 0 is the speed control. `nospec`, the same placement
  without speculation, is the correctness control. Every MTP text is compared with both.
  Under server sampling no text is compared: MTP changes how the sampler's random draws are
  consumed, so texts may differ by design.
- **Stage 5:** the bench's workload run, or its rerun on b11583 if stage 0 adopts it.
- **Stage 6:** the unchanged prompt.

## Method

**Code.** Each stage runs from this branch's head at that stage's start, staged with
`push-harness.sh`. Its cells file is committed before it runs, and the record names the
commit. A stage's cells depend on the winners before it, so only stage 0's file exists at
plan time.

**Corpus.** The deep contexts are the suite's pinned corpus: this repository at
`f7e762c53388`, `docs.txt` then `code.txt`.
- It is built with `bench_common.build_corpus`, and its checksums are checked against
  `CORPUS_SHA256`.
- It is copied to `/root/glm53-flash/corpus-f7e762c53388.txt`, and the sweep's manifest
  records the file's SHA-256.
- Depths are exact token counts, cut with GLM's tokenizer. The probe's default filler is not
  used.

**Sweep settings** (stages 0–4): `VMID=123 UNIT=llamacpp-glm53f N_BLOCKS=46
CONTRACT_EFFORTS=none,low,high,max PROBE_CHAT=true CTX=65536 PARALLEL=1
CONTEXT_FILE=/root/glm53-flash/corpus-f7e762c53388.txt TURN_DEPTH=30000`, with
`thermal-guard.sh`, the residency sampler and `vram-release-trace.sh` running beside it.

```bash
# Host, as root
H=/root/harness/<sha12>/pro-v620
cd $H/glm53-flash
./ct123-test-host.sh one-card
VMID=123 ENV_FILE=glm53f-bench.env ./install.sh
VMID=123 ./install-llamacpp-release.sh                 # b11583, SHA-256 checked
cd $H/qwen38-flash-next
VMID=123 ./thermal-guard.sh                            # separate shell
systemd-run --unit=vram-residency --collect /usr/bin/python3 $PWD/vram-residency-sampler.py \
  --pci 0000:83:00.0 --output /root/glm53-flash/residency-106-<stage>.jsonl
systemd-run --unit=vram-release-trace --collect $PWD/vram-release-trace.sh \
  /root/glm53-flash/trace-106-<stage>.txt
VMID=123 UNIT=llamacpp-glm53f N_BLOCKS=46 CONTRACT_EFFORTS=none,low,high,max PROBE_CHAT=true \
  CTX=65536 PARALLEL=1 CONTEXT_FILE=/root/glm53-flash/corpus-f7e762c53388.txt \
  TURN_DEPTH=30000 REPS=3 DEPTHS=0,8000 \
  CELLS=../glm53-flash/runs/2026-10-13-long-tasks-<stage>.cells \
  OUT_DIR=/root/glm53-flash/sweep-106-<stage>-$(date -u +%Y%m%dT%H%M%SZ) ./placement-sweep.sh
systemctl stop vram-release-trace vram-residency
```

| Stage | Cells | Passes | Probe | Expected |
| --- | --- | --- | --- | --- |
| 0 build | `b11505`, `b11583` (committed: [`-build.cells`](2026-10-13-long-tasks-build.cells)) | 3 | `DEPTHS=0,8000` | ~1 h |
| 1 offload | thresholds 32 (control), 128, 256, 512, 1024 via `ENV` | 3 | `DEPTHS=0,8000`, `TURNS` | ~4 h |
| 2 micro-batch and placement | `-ncmoe` 46 (control) and 45 at micro-batch 4096 and 2048 (45 at 1024 if needed) | 1 fit, then 3 timed for the cells that fit | fit: `DEPTHS=0,8000,48000`, `TURNS`; timed: `DEPTHS=0,8000`, `TURNS` | ~2.5–4.5 h |
| 3 MTP | n-max 1/2/3 × p-min 0/0.2/0.3/0.5, plus `nospec` in the screen | 1 screen; 2 more for the retained 4; 3 under server sampling for 3 | `DEPTHS=8000,48000`, `PROBE_ARGS="--n-predict 640 --cache"` | screen ~3.7 h, retained ~2.3 h, sampling ~2.5 h |
| 4 CPU | 24 and 32 threads, 32 + `--poll 0`, 32 pinned | 3 | `DEPTHS=0,8000`, `TURNS` | ~3.2 h |

- **Stage 3's prompts share the corpus prefix.** With `--cache`, each cell prefills the 48k
  context cold once, and its 8k context and the other classes reuse it, so the screen's time
  is decode. Prefill at depth comes from the 48k cold request and from stages 0–2.
- **Stage 5:** `make bench GPU=2 MODEL=glm53f SUITE=workloads` from the Mac, after
  `install.sh` writes the winner's env file; about 3 h per run, and 6 h if the control
  reruns. CT 200 runs for it, as in the batch.
- **Stage 6:** from CT 200, as in the findings record. `benchmark-doc-ingest.py --depths
  8192 49152 --max-tokens 2048 --reps 1` runs six times, alternating `--prompt standard` and
  `--prompt concise`; about 1.2 h.
- **Expected duration: about 23–29 h of runs**, over several days. Each stage's results are
  appended when it ends. The owner can stop the campaign after any stage.
- **Raw data:**
  - on the host: `/root/glm53-flash/sweep-106-<stage>-<ts>/`, `residency-106-<stage>.jsonl`
    and `trace-106-<stage>.txt`;
  - on the Mac, stage 5's results under `pro-v620/results/llamacpp-gpu2-glm53f/parallel-1/`;
  - stage 6's results under `pro-v620/results/llamacpp-gpu2-glm53f/long-tasks-<date>/`.

## Safety

- **Guests:** CT 123 runs throughout. CT 200 runs for stages 5–6 and is shut down after
  each.
  - CT 120 `llamacpp`, CT 121 `hermes`, CT 140 `kb-rag`, CT 201 and VM 300 `docker-host`
    stay shut down. Starting any of them again waits for the owner's go-ahead.
  - The builder (CT 201) is not needed: b11583 is a release tarball, checked by SHA-256.
- **Cards:** CT 123 holds only `0000:83:00.0`; CT 120 holds only `0000:03:00.0` and is
  stopped.
- **Thermal:**
  - `gpu-thermal-watchdog` maps `0000:83:00.0` to `llamacpp-glm53f` while `one-card` is in
    place, and `thermal-guard.sh` runs beside every sweep.
  - The sweep starts no cell above 58 °C on the hottest DIMM, and flags any sample at 66 °C.
- **Stops:** a cell that puts memory outside VRAM, fails a VRAM allocation in the trace, or
  reaches 66 °C on a DIMM is marked invalid and is not carried forward.
- **Tracing:** `vram-release-trace.sh` removes its probes on stop. If it dies uncleanly, the
  [findings record](2026-10-13-findings.md#safety) has the manual cleanup.
- **Job timeout:** amdgpu's compute job timeout is 10 s; the deepest request is 48k tokens.

## Environment

llama.cpp b11505 (`ff5888f99`, release tarball, `llama-server` SHA-256 `b8f67ab0…729c`) and
b11583 (`988015788`, release tarball, asset SHA-256 `2c331fa6…3332`, `llama-server` SHA-256
`42ad308d…53b3`), Vulkan with Mesa 26.2.4 RADV, kernel `7.0.14-22-pve`, `schedutil`,
8 × 64 GB DDR4-3200. CT 123 with 48 cores and 240 GiB holding `0000:83:00.0` (`unique_id`
`99b104541144b36c`) at 0 mV and 250 W; amdgpu's compute job timeout is 10 s (not in the
capture). Stage 0's capture, taken before its sweep with the env file on b11505:

<details>
<summary>environment.json, stage 0</summary>

```json
{
 "captured_at": "2026-10-13T16:00:12Z",
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
   "MODEL_THREADS": "32",
   "MODEL_EXPECTED_GPUS": "1",
   "MODEL_VK_VISIBLE_DEVICES": "",
   "MODEL_TENSOR_SPLIT": "",
   "MODEL_LOAD_MODE": "dio",
   "MODEL_REASONING_BUDGET": "0",
   "EXTRA_ARGS": "--device Vulkan0 --spec-type draft-mtp --spec-draft-n-max 2",
   "MODEL_BATCH_SIZE": "4096",
   "MODEL_UBATCH_SIZE": "4096",
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

### Stage 0, build — 2026-10-13 12:00–12:54 ET

Harness `0faeb4420b8e`, cells [`-build.cells`](2026-10-13-long-tasks-build.cells), three
passes. Raw data on the host: `/root/glm53-flash/sweep-106-build-20261013T160008Z/`,
`residency-106-build.jsonl`, `trace-106-build.txt` and `image-check-106.log`. The corpus file
is `corpus-f7e762c53388.txt`: `docs.txt` then `code.txt`, each matching `CORPUS_SHA256`,
SHA-256 `ed17f002…2439` combined.

| Cell | Decode, median of six prompt cells (t/s) | d8000 prefill (t/s) | Free after load | Load |
| --- | ---: | ---: | ---: | ---: |
| `b11505` | 7.910 [7.795–7.925] | 180.8 [180.8–180.9] | 10,927 MiB | 119 s |
| `b11583` | 7.925 [7.895–8.005] | 180.0 [178.9–180.1] | 10,927 MiB | 119–120 s |

Decode per prompt cell, t/s, median of three passes, with draft acceptance (the same in both
builds):

| Cell | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `b11505` | 9.41 | 7.36 | 8.74 | 8.06 | 6.95 | 7.77 |
| `b11583` | 9.38 | 7.42 | 8.82 | 8.01 | 6.97 | 7.87 |
| acceptance | 72.6% | 46.5% | 63.4% | 62.8% | 46.4% | 58.3% |

The d8000 prompts were 8,038–8,049 tokens: 8,000 of the corpus plus the instruction and the
template.

- **Decode:** b11583 is 0.015 t/s ahead, within both cells' spreads (0.13 and 0.11).
- **Prefill at d8000:** b11583 is 0.8 t/s lower (−0.4%). That is beyond b11505's spread
  (0.1) but within its own (1.1), so it is not lower beyond both.
- **Output:** each build returned the same text in every pass, and the two builds returned
  the same text as each other in all six prompt cells.
  - No request failed, and no text was degenerate.
  - The contract was clean on every load: six, three per build.
- **VRAM:** nothing was outside VRAM, and no VRAM allocation failed in the trace.
  - Steady least free was 10,486 MiB in both builds.
  - The compute buffer swapped 21 times on b11505 and 24 times on b11583 over three passes.
  - The 1 Hz sampler caught one swap at 8,560 MiB free on b11505, and one at 4,684 MiB on
    b11583. Which swap a sample catches is chance; the mechanism is the same.
- **Reallocation reports (#30329):** b11583 logged no reallocation line at the default log
  level.
- **Card, per phase:** prefill 175–177 W at 2,358–2,360 MHz, 99% busy, on 0.4 CPU cores. Decode
  51 W at 499 MHz, 42–44% busy, on 29.8 cores. Junction peaked at 80–82 °C; the hottest DIMM
  reached 53–56 °C.

**Image request under MTP** (12:49–12:54 ET, `glm53f-bench.env` with each build). The request
was a 64 × 64 PNG, red on the left and blue on the right, through `/v1/chat/completions`:

| Build | Result |
| --- | --- |
| b11505 | HTTP 500 `decode() failed: failed to process speculative batch`; the log shows `llama_process(ctx_dft) head=0 failed rc=-1` (#30204) |
| b11583 | HTTP 200, "Red (left) and blue (right).", 48 prompt tokens, 11 generated, 5 of 10 drafts accepted |

Both servers answered a text request after the image request.

**Stage 0's rule holds for b11583, so stages 1–6 run on b11583.**
- Decode and d8000 prefill are not lower beyond both spreads.
- Every request succeeded, no text was degenerate, the contract was clean, and the text is
  identical to b11505's.
- It loaded with the same launcher and settings.

Stage 1's control cell is the baseline rerun on b11583. Stage 5's control reruns on b11583
too, since the bench ran on b11505.

### Stage 1, op-offload threshold — 2026-10-13 13:51–18:12 ET

Harness `aee7e6fae37a`, cells [`-offload.cells`](2026-10-13-long-tasks-offload.cells), three
passes, b11583. This is the rerun after the turn-probe fix; see Deviations. Raw data on the
host: `/root/glm53-flash/sweep-106-offload-20261013T175150Z/`, `residency-106-offload.jsonl`
and `trace-106-offload.txt`. The last two also hold the stopped first attempt's samples; the
figures below use each cell's own time windows.

**Turn prefill on a 30,023-token cached context**, seconds, median of three passes:

| New tokens | 41 | 73 | 137 | 264 | 521 | 1,033 | 2,056 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `thr32` (control) | 4.38 | 5.67 | 7.21 | 8.77 | 10.46 | 13.08 | 18.70 |
| `thr128` | **2.34** | **3.12** | 7.22 | 8.78 | 10.43 | 13.08 | 18.71 |
| `thr256` | **2.33** | **3.06** | **4.51** | 8.77 | 10.46 | 13.08 | 18.70 |
| `thr512` | **2.36** | **3.07** | **4.50** | **7.41** | 10.44 | 13.08 | 18.70 |
| `thr1024` | **2.32** | **3.05** | **4.53** | **7.43** | *13.70* | 13.07 | 18.68 |

Bold: the turn ran on the CPU, below the threshold. Italic: on the CPU and slower than on
the card.

- **The cache served the whole context on every turn** (cache_n 30,025 of 30,023). Each
  turn prefilled its chunk plus 8–9 template tokens. No turn failed.
- **The two paths:**
  - Below the threshold, prefill takes about 1.3 s plus 23 ms per token. On the card it
    rises steeply to about 8.8 s at 264 tokens, then gains about 6.5 ms per token.
  - The two cross at about 340 new tokens. A threshold between 256 and 512 was not
    measured.
- **Cold short prompts are not affected.** The d0 prompts (31–42 tokens, no context) took
  2.5–2.8 s at every threshold, on either path. The card's extra cost for a short batch
  appears only on top of a deep context; its cause was not measured.

**Estimated batch prefill** (the bench's 186 warm agent turns priced by these turn times) and
the checks:

| Cell | Warm-turn prefill, s | `hermes` / `coding` | Decode d0 / d8000, t/s | d8000 prefill, t/s |
| --- | ---: | --- | --- | ---: |
| `thr32` | 2,999 [2,992–3,019] | 1,746 / 1,253 | 8.73 [8.68–8.83] / 7.78 [7.77–7.89] | 179.7 |
| `thr128` | 2,957 [2,955–2,959] | 1,737 / 1,220 | 8.74 / 7.82 | 179.9 |
| `thr256` | 2,864 [2,862–2,865] | 1,647 / 1,218 | 8.61 / 7.78 | 180.2 |
| **`thr512`** | **2,821 [2,821–2,835]** | **1,603 / 1,219** | 8.64 [8.58–8.64] / 7.76 [7.69–7.96] | 180.0 |
| `thr1024` | 2,878 [2,870–2,879] | 1,661 / 1,217 | 8.73 / 7.72 | 180.1 |

- **The saving is 178 s over the bench's six sessions (−5.9%), most of it in `hermes`.**
  `hermes` turns have a median of 349 new tokens, where the paths are close. `coding` turns
  have a median of about 3,900, always above the threshold.
- **Per session**, that is about 48 s of a `hermes` session's 1,700 s, about 3%.
- **The estimate tracks the bench.** For `thr32` it is within 4% of the bench's measured
  `hermes` prefill (1,746 against 1,815 s, on b11505) and 7% of its `coding` prefill (1,253
  against 1,346 s).
- **Output and checks, every cell:**
  - The text in every prompt cell is identical to `thr32`'s and the same in every pass.
  - The contract was clean on every load: fifteen.
  - No request failed and no text was degenerate.
- **VRAM:** nothing was outside VRAM, and no VRAM allocation failed in the trace.
  - Steady least free was 9,593–9,789 MiB.
  - Compute-buffer swaps fell with the threshold: 105 at 32, 88 at 128, 78 at 256, 69 at
    512 and 61 at 1024, over three passes.
  - The sampler caught swaps at 3,132–4,681 MiB free.
- **Card, per phase:**
  - Prefill 173–190 W at 2,355–2,366 MHz, 99% busy, on 0.4 cores.
  - Decode 52 W at 499 MHz, 43–46% busy, on 29.8 cores.
  - The turn probe's span is dominated by its 30k prime: 171–174 W.
  - Junction peaked at 81–85 °C; the hottest DIMM reached 55–58 °C.

**Stage 1's winner is `thr512`** (`GGML_OP_OFFLOAD_MIN_BATCH=512`). It has the lowest estimate,
beyond both spreads. Its decode at d0 (8.64 against 8.73) and d8000 (7.76 against 7.78) is
within the control's spread (0.15 and 0.12), and so is its d8000 prefill. Stages 2–6 run with
it. Stage 5 checks it on real sessions.

### Stage 2, fit pass — 2026-10-13 18:19–20:05 ET

Harness `bca01927e027`, cells [`-fit.cells`](2026-10-13-long-tasks-fit.cells), one pass,
b11583, `GGML_OP_OFFLOAD_MIN_BATCH=512`, depths 0, 8,000 and 48,000 plus the turn probe. Raw
data on the host: `/root/glm53-flash/sweep-106-fit-20261013T221937Z/`,
`residency-106-fit.jsonl` and `trace-106-fit.txt`.

| Cell | Fit | Least free with swaps | Least free outside swaps | Outside VRAM | Failed VRAM allocations | Code prefill d8000 / d48000, t/s | Decode, median of six |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: |
| `n46-ub4096` (control) | fits | 3,750 MiB | 9,071 MiB | 0 | 0 | 178.8 / 145.8 | 7.40 |
| `n45-ub4096` | **fails** (rules 1, 2, 3) | **54 MiB** | 5,361 MiB | **1,890 MiB** | **25** | 163.2 / 136.1 | 7.65 |
| `n46-ub2048` | fits | 6,468 MiB | 12,442 MiB | 0 | 0 | 141.0 / 120.0 | 7.43 |
| `n45-ub2048` | fits | 2,251 MiB | 8,265 MiB | 0 | 0 | 140.3 / 120.3 | 7.73 |

- **What happens when a swap does not fit** (`n45-ub4096`): this was untested before.
  - 25 VRAM allocations failed, and 26 buffers of at least 256 MiB were created in GTT.
  - Up to 1,890 MiB stayed outside VRAM, and free VRAM fell to 54 MiB during a swap.
  - d8000 prefill was 9% below the control.
  - Steady free VRAM was 5,361 MiB, above the 3,072 margin. The swap transient, not the
    steady state, set the fit.
- **Micro-batch 2048:**
  - It shrinks the largest swap from 8,066 MiB to 6,493 MiB.
  - It frees 2,146 MiB at load (13,073 against 10,927 MiB) and lets `-ncmoe 45` fit.
  - It costs 21% of d8000 prefill and 18% at 48k.
- **Block 45's experts on the card** decoded 4% faster in this one pass (7.73 against 7.43 at
  micro-batch 2048). The timed pass checks it against the spread.
- **Every cell:** probe and contract clean, no turn failed.
- **Timed pass:** `n46-ub4096` (control), `n46-ub2048` and `n45-ub2048`, three passes
  ([`-placement.cells`](2026-10-13-long-tasks-placement.cells)). `-ncmoe 45` fits at 2048,
  so no 1024 pass is needed.

### Stage 2, timed pass — 2026-10-14 13:00–15:18 ET

Harness `341982751388`, cells [`-placement.cells`](2026-10-13-long-tasks-placement.cells),
three interleaved passes, b11583 (every server command line), `GGML_OP_OFFLOAD_MIN_BATCH=512`,
depths 0 and 8,000 plus the turn probe. Raw data on the host:
`/root/glm53-flash/sweep-106-placement-20261014T170018Z/`, `residency-106-placement.jsonl`
and `trace-106-placement.txt`. Figures are medians of the three passes, with their range.

**Estimated batch time.** This is the stage's rule: the bench's 186 warm turns, with their
37,236 generated tokens at the cell's d8000 decode.

| Cell | Batch, s | Turn prefill, s | Decode, s | Decode d0 / d8000, t/s | d8000 prefill, t/s | 30k prime (cold), s |
| --- | ---: | ---: | ---: | --- | ---: | ---: |
| `n46-ub4096` (control) | 7,591 [7,563–7,632] | 2,810 [2,809–2,819] | 4,782 | 8.60 [8.55–8.83] / 7.79 [7.74–7.83] | 180.1 [180.0–180.2] | 193.7 |
| `n46-ub2048` | 7,668 [7,615–7,682] | 2,915 [2,905–2,938] | 4,753 | 8.88 [8.73–8.92] / 7.83 [7.80–7.96] | 141.4 [141.3–141.5] | 235.2 |
| **`n45-ub2048`** | **7,417 [7,406–7,439]** | 2,906 [2,885–2,930] | **4,511** | **9.17 [9.10–9.19] / 8.26 [8.24–8.26]** | 142.0 [142.0–142.3] | 233.7 |

- **By the rule, `n45-ub2048` has the lowest estimated batch time:** 174 s (2.3%) below the
  control, beyond both spreads.
  - Its decode accounts for all of the difference: 271 s less than the control.
  - Its turn prefill is 96 s more.
- **Block 45 on the card, same micro-batch** (`n45-ub2048` against `n46-ub2048`, identical
  text): decode is 3.2% faster at d0 and 5.4% faster at d8000. The ranges do not overlap.
  Prefill and turn times are the same.
- **Micro-batch 2048, same placement** (`n46-ub2048` against the control):
  - d8000 prefill is 21.5% lower, and the cold 30k prime takes 21% longer.
  - Turn times match up to 1,024 new tokens. At 2,048 they take 19.1 s against 18.7 s.
  - d0 decode, on identical text, is 3% higher. The two ranges overlap.
- **Text:**
  - d0 is identical in every cell and pass.
  - At d8000 the two micro-batch-2048 cells match each other, and all three classes differ
    from the control's. The texts diverge within the first 61–86 characters.
  - Every text is coherent, the same in every pass, and not degenerate.
  - The d8000 decode comparison against the control is therefore on different text.
    Acceptance there is 66.5/49.8/59.7% (code/list/prose) against 62.8/46.4/58.3%.
- **What the rule does not cover:**
  - **Turns past 2,048 new tokens are extrapolated.**
    - 69 warm turns run past 2,048 new tokens, with 134,679 tokens beyond it (up to 8,777).
    - The turn probe stops at 2,048, so these are extrapolated along each cell's 1,024–2,048
      segment.
    - For the control, the estimate on those 69 turns is 2,020 s against the bench's
      measured 2,197 s (8% low).
    - At micro-batch 2048 each of these turns runs at least two micro-batches. That was
      not measured.
  - **Ingestion is not in the estimate.**
    - The bench's 12 ingestion requests prefilled 319,404 tokens cold, at 8k–48k, in
      2,086 s.
    - At the fit pass's micro-batch-2048 prefill rates (1.27× the time at 8k, 1.21× at
      48k), that is about 480 s more.
    - Their 905 s of decode, at `n45-ub2048`'s d8000 rate, would be about 50 s less.
    - That nets about +430 s on ingestion, against −174 s on the agent turns.
- **Fit, over the three passes** (no 48k prompt in this pass):

  | Cell | Least free with swaps | Least free outside swaps | Free after load | Swaps, largest | Outside VRAM | Failed VRAM allocations |
  | --- | ---: | ---: | ---: | --- | ---: | ---: |
  | `n46-ub4096` | 5,559 MiB | 9,789 MiB | 10,927 MiB | 69, 8,066 MiB | 0 | 0 |
  | `n46-ub2048` | 7,264 MiB | 12,632 MiB | 13,073 MiB | 105, 6,493 MiB | 0 | 0 |
  | `n45-ub2048` | 2,816 MiB | 8,455 MiB | 8,897 MiB | 107, 6,493 MiB | 0 | 0 |

- **Every cell and pass:**
  - Probe and contract were clean: nine loads.
  - No request or turn failed, and the cache served the whole 30,023-token context on
    every turn.
  - Prefill drew 173–182 W at 2,359–2,364 MHz, and decode 51–52 W.
  - Junction peaked at 80–82 °C, and the hottest DIMM at 56 °C.

**Stage 2's winner is `n45-ub2048`**, by the rule. The owner kept the rule on 2026-10-14
after seeing what it leaves out. Stages 3–6 run on it, and stage 5's bench measures its
ingestion. **Stage 3's screen:** 12 MTP cells plus `nospec` on this placement, one pass
([`-mtp.cells`](2026-10-13-long-tasks-mtp.cells)).

### Stage 3, screen — 2026-10-14 15:47–19:51 ET

Harness `b1348a477261`, cells [`-mtp.cells`](2026-10-13-long-tasks-mtp.cells), one pass,
b11583 on `n45-ub2048`. Code, list and prose at 8,000 and 48,000 tokens, 640-token cap,
`--cache`, greedy. Raw data on the host: `/root/glm53-flash/sweep-106-mtp-20261014T194736Z/`,
`residency-106-mtp.jsonl` and `trace-106-mtp.txt`.

Ranked by the rule, summed decode time over the six requests:

| Cell | Decode, s | Tokens | Decode rate, t/s | Acceptance | Drafts wasted | Text = control | Text = `nospec` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `n2-p03` | **406.2** | 3,122 | 7.69 | 62.6% | 1,017 | 1/6 | 0/6 |
| `n2-p02` | 406.9 | 3,133 | 7.70 | 61.7% | 1,072 | 4/6 | 0/6 |
| `n2-p0` (control) | 407.8 | 3,163 | **7.76** | 61.7% | 1,082 | — | 0/6 |
| `n2-p05` | 412.5 | 3,119 | 7.56 | 70.7% | 672 | 0/6 | 0/6 |
| `n1-p02` | 430.6 | 3,133 | 7.28 | 76.2% | 422 | 2/6 | 0/6 |
| `n1-p03` | 432.7 | 3,144 | 7.27 | 77.4% | 395 | 0/6 | 0/6 |
| `n1-p0` | 434.5 | 3,168 | 7.29 | 76.3% | 426 | 2/6 | 0/6 |
| `n1-p05` | 435.7 | 3,140 | 7.21 | 81.2% | 301 | 0/6 | 0/6 |
| `n3-p05` | 464.0 | 3,176 | 6.85 | 61.0% | 1,149 | 0/6 | 0/6 |
| `n3-p03` | 494.2 | 3,175 | 6.42 | 49.8% | 1,858 | 0/6 | 0/6 |
| `n3-p0` | 495.7 | 3,207 | 6.47 | 49.5% | 1,948 | 0/6 | 0/6 |
| `n3-p02` | 524.4 | 3,296 | 6.29 | 48.5% | 2,064 | 0/6 | 0/6 |
| `nospec` | 545.3 | 3,248 | 5.96 | — | — | 0/6 | — |

- **n-max 2 is fastest at every p-min.**
  - **The four n-max 2 cells are within 1.6% of each other** in this one pass.
    - p-min 0.5 wastes 38% fewer drafts (672 against 1,082), but decodes 2.6% slower.
  - **n-max 1** is 6–7% slower, with acceptance of 76–81%.
  - **n-max 3** is 14–29% slower.
    - Acceptance falls to 48.5–49.8% at p-min 0–0.3.
    - p-min 0.5 lifts it to 61.0%, and that cell is the fastest at n-max 3.
- **MTP against `nospec`:**
  - The control decodes 30% faster (7.76 against 5.96 t/s), and its summed decode time is
    25% lower.
  - By request, `nospec` decodes 5.64–5.72 t/s at 48k and 6.17–6.28 at 8k. The control
    decodes 6.15–7.80 at 48k and 7.37–9.43 at 8k.
- **Output length moves the rule.**
  - The code and prose replies all reach the 640-token cap.
  - The list replies stop on their own at 200–338 tokens (48k) and 339–407 (8k).
  - `n2-p03` ranks first by time with 41 fewer tokens than the control. The control has the
    highest decode rate.
- **Text:**
  - Every MTP text differs from `nospec`'s in all six prompts. They diverge within the first
    17–972 characters, as batched verification is known to do.
  - Few MTP texts match the control's (table).
  - Every reply is coherent, and none is degenerate. Every list has its 20 items.
- **Fit:** every cell fits.
  - Nothing was outside VRAM, and no VRAM allocation failed.
  - Free after load: n-max 1 9,047 MiB, n-max 2 8,897, n-max 3 8,747, `nospec` 14,716. The MTP
    context takes 5,819 MiB at n-max 2.
  - The least free including swaps was 2,165 MiB (n-max 3) to 5,603 MiB, and 11,584 MiB for
    `nospec`. The largest swap was 6,489–6,497 MiB (6,047 for `nospec`).
- **Every cell:** probe and contract clean, and no request failed.
  - Cold prefill was 120.7 t/s at 48k [120.6–123.3] and 144.3 t/s at 8k [143.2–145.6].
  - Prefill drew 178–181 W, and decode 52–54 W.
  - Junction peaked at 84 °C, and the hottest DIMM reached 56–58 °C.
  - Decode used 26.0 CPU cores for the control and 30.4 for `nospec`.

**Retained cells, by the owner's decision on 2026-10-14:**
- **The cells:** `n2-p0` (control), `n2-p02`, `n2-p03` and `n2-p05`, for two more
  interleaved passes ([`-mtp-retained.cells`](2026-10-13-long-tasks-mtp-retained.cells)).
- **Why `n2-p05` is in:** the control is one of the three lowest, so the plan's rule names
  only three cells. `n2-p05`, fourth and within one pass's noise, is retained as the third
  challenger. That gives the four cells the plan's timing assumed.

## Deviations

- **Stage 0's decode rule named "the six d8000 prompt cells".** d8000 has three. The six are
  the d0 and d8000 cells, as in the configurations record, and that is what was applied.
- **Stage 1's first attempt (13:24–13:45 ET) was stopped after one cell.**
  - **What went wrong:** the turn probe appended each chunk inside the context's user
    message. GLM's linear-attention layers resume only from a context checkpoint, which
    llama-server places at user-message starts and about one micro-batch (~4,100 tokens)
    before a prompt's end.
  - **Effect:** every turn re-prefilled 2,000–4,100 tokens of context before its chunk. The
    cache served 25,927, then 27,976, of the 30,023 context tokens. Every request was then
    above every threshold under test.
  - The probe flagged the cell's first rep (7 uncached requests). Its later reps were wrong
    in the same way.
  - **Fix (`9ae99d3`):** the probe sends each chunk as its own user message, after the
    context and a fixed assistant reply, as an agent session does.
  - **Live check before the rerun (13:50–13:51 ET, 8k context, scratch run):** the cache
    served 8,026 of 8,024 context tokens. A 41-token turn prefilled in 4.45–4.49 s, a
    265-token one in 8.3–8.4 s.
  - The stage restarts from scratch at that commit. The first attempt's data stays on the
    host in `sweep-106-offload-20261013T172410Z/` and is not used.
- **Stage 3's prompts did not all reuse the 48k context**, as the Method expected.
  - The 8k code prompt was served 9 tokens from the cache, so every cell prefilled 8k cold
    as well. GLM resumes only from a context checkpoint, and none sits at 8k inside the 48k
    prompt.
  - The list and prose prompts re-prefilled 2,041–2,047 tokens at each depth. The cache
    resumed about one micro-batch before the shared prefix's end.
  - The screen took 4 h 04 min against about 3.7 h.
  - Decode, which the stage ranks, is not affected, and the cold 8k prefill is an extra
    measurement.

## Conclusion
