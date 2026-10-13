# GLM-5.3-Flash: tuning one 64k slot for long tasks

Plan committed 2026-10-13 · Run not started · Status: planned

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

The batch's stack: llama.cpp b11505 (`ff5888f99`), Vulkan with Mesa 26.2.4 RADV, kernel
7.0.14-22-pve, both V620s at stock 0 mV and 250 W. b11583 (`988015788`, asset SHA-256
`2c331fa6fc87…`) is added for stage 0. Each sweep saves `capture-env.sh`'s output as
`environment.json`, and the record pastes it when the stage runs.

---

## Results

## Deviations

## Conclusion
