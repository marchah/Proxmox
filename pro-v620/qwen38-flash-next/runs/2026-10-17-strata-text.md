# Qwen3.8-Flash-Next: why greedy text changes between starts with pipeline windows (Strata)

Plan committed 2026-10-17 · Run 2026-10-17 · Status: running

## Question

In the [pipeline-windows record](2026-10-17-strata-pipeline.md), Strata on two V620s decoded
12–14% faster with `--pipeline-windows 2`. The same greedy request, however, gave a different
text after each server start: 3 to 9 different texts per row over ten starts. Without pipeline
windows, `--spec 5` repeated its text exactly.

This record asks what makes the text change:
- Is it the timing-dependent choices that Strata already documents as changing greedy output?
- Or does the pipeline itself produce different tokens?
- Is it reproducible when those choices are frozen, and does it then match the same engine
  without guessed windows?

**What Strata documents** (`docs/DETAILS.md` at `296b59d`):
- **Rounding by group size (#152).** The CPU computes an expert for one token with ggml's dot
  product, and for several tokens with Strata's multi-token kernels. The two round slightly
  differently. How many tokens share an expert depends on the drafts in a verify window.
  `STRATA_IQ_MT_MIN=1` uses the multi-token kernels for every group.
- **State that carries across requests (#410):**
  - the adaptive tier moves experts between RAM and VRAM, and the GPU and the CPU round an
    expert differently;
  - the PCIe share computes some missed experts on the GPU instead of the CPU;
  - the prompt cache resumes a repeated prompt.

  For byte-identical repeats, Strata adds `--prompt-cache 0 --adapt-swaps 0 --pcie-frac 0`.
- **Pipeline windows** (`docs/MULTI_GPU.md`):
  - the tokens are the serial loop's "up to CPU rounding";
  - with `STRATA_IQ_MT_MIN=1 --pcie-frac 0 --adapt-every 0`, the greedy output is bit-identical
    to the serial loop's, given the same expert caches;
  - upstream checked that on four RX 7900 XTs, not on gfx1030.

A serial run already repeats its text in this harness, because each start sends the same
requests in the same order. With pipeline windows, a guessed window may be started or skipped
depending on the timing between the two cards. That can change the window groupings, or when an
adaptive swap lands. This is a hypothesis; this record tests it.

## What answers it

`text-repeat.py` reads each cell's greedy texts by their `content_sha`, for the nine probe rows
(three depths × three prompt classes).
- **Repeats:** the cell gives the same text in all three passes on 9 of 9 rows, as `s5` did in
  the pipeline record's stage B.
- **Matches:** two cells that both repeat give the same text on 9 of 9 rows.

| `pw2-frozen` | `pw2-frozen` against `pw2-frozen-noguess` | Reading |
| --- | --- | --- |
| repeats | matches | Guessed windows compute the same tokens as the windows run one at a time on the same caches. The text changes because of one or more of the frozen choices; stage B names which. |
| repeats | differs | It is reproducible, but a held guess gives different tokens than the window run without guessing. That is a pipeline numerics difference, for an upstream issue. |
| varies | — | The frozen choices are not the whole cause. If `pw2-frozen-noguess` repeats, the guessed-window path is the source; if it also varies, something else in the pipeline is. Either way, an upstream issue with the data. |

**Also reported:**
- whether `serial` and `serial-frozen` repeat (expected: 9 of 9);
- whether `serial-frozen` matches `pw2-frozen-noguess`. This is not decisive: pipeline windows
  keep VRAM out of the expert caches, so the two hold different caches.
- each cell's decode, acceptance and expert-cache hit rate: the speed cost of freezing.

Every cell must also pass the harness gates:
- chat contract and tool calls;
- no empty, degenerate or cut-off row;
- 0 MiB outside VRAM;
- no stall, `#267` hang or engine restart;
- in each pipeline-windows cell, the log line that the pipeline is on.

## Configurations

- **Two GPUs only:** the question is about pipeline windows, which need a layer split.
- **Every cell** is the pipeline record's soaked `s4p7-pw2`, or the same without pipeline
  windows:
  - the split21 layer split, `STRATA_MMQ_KQ=1`, `--suffix-draft 0`;
  - `--spec 4 --spec-min-p 0.7`;
  - the rest of `strata-qwen38fn.env`.
- **"frozen"** adds `STRATA_IQ_MT_MIN=1`, `--prompt-cache 0`, `--adapt-swaps 0` and
  `--pcie-frac 0`. These are #410's switches plus #152's. With `--adapt-swaps 0`, the expert cache
  keeps what the profile loads at start.
- **"noguess"** keeps pipeline windows and their VRAM layout but never starts a guessed window.
  It sets `STRATA_PIPELINE_THETA=2`: a guessed window starts only when its estimated chance of
  being kept is at least θ, and the default is 0.2. The engine reads this variable only with
  `STRATA_PIPELINE_DEBUG=1`.
- **Left out:**
  - one GPU, CPU only and an optimized configuration: they are not the question;
  - `--spec 5`: its serial repeatability is already measured.

## Controls

- `pw2` is the soaked cell. The pipeline record measured it varying, with 0 or 1 of 9 rows
  repeated.
- `serial` is its twin without pipeline windows. It shows that this draft setting repeats
  without the pipeline.

## Method

- **Harness:** the commit that adds this plan, staged with `../push-harness.sh`. It adds
  [`text-repeat.py`](../../strata/text-repeat.py), which prints, per cell, the rows with one text
  in every pass and the number of different texts per row; `--against CELL` also prints the rows
  each cell shares with that cell. `test_strata_cell.py` covers it, and each of three mutations
  fails a test. On the pipeline record's stage B and C data it reproduces the record's counts.
- **Run**, from `/root/harness/<sha12>/pro-v620/qwen38-flash-next/`, as in the pipeline record:

```bash
../strata/use-engine.sh strata-two-card
UNIT=strata-qwen38fn PATTERNS=build-hip/strata ./thermal-guard.sh   # separate shell; VMID unset, so both cards
for pci in 0000:83:00.0 0000:03:00.0; do
  systemd-run --unit="vram-residency-${pci:5:2}" --collect /usr/bin/python3 "$PWD/vram-residency-sampler.py" \
    --pci "$pci" --comm strata --output "/root/qwen38-flash-next/strata-text-${pci:5:2}-residency.jsonl"
done
CELLS=runs/2026-10-17-strata-text-1-freeze.cells ../strata/strata-sweep.sh       # stage A, PASSES=3
../strata/text-repeat.py /root/qwen38-flash-next/strata-sweep-<ts> --against pw2-frozen-noguess
../strata/use-engine.sh strata
```

- **Stage A:** the five cells of `2026-10-17-strata-text-1-freeze.cells`, three interleaved
  passes, every load cold. About 50 minutes: the pipeline record took about 3.3 minutes per load,
  and the frozen cells may decode slower.
- **Stage B, only if `pw2-frozen` repeats:** which switch is enough on its own. `pw2` runs with
  each one alone, three passes:
  - `pw2-mtmin`: `STRATA_IQ_MT_MIN=1`;
  - `pw2-noswap`: `--adapt-swaps 0`;
  - `pw2-nopcie`: `--pcie-frac 0`.

  The cells file is committed before it runs. About 30 minutes. If no single switch restores
  repeats, the record says so, and pairs are not run. `--prompt-cache 0` stays out of stage B:
  the probe's cold rows already skip the prompt cache (`"strata_checkpoint": false`).
- **Probes:** as in the pipeline record. Chat mode, `code`, `list` and `prose`, greedy (temperature
  0, top-k 1), 256 tokens, depths 0, 8000 and 32000. Each load gets one excluded warm-up request.
- **Raw data:** `/root/qwen38-flash-next/strata-sweep-<ts>/` on the host.

## Safety

- **Other guests:** CT 120 `llamacpp`, CT 121 `hermes`, CT 140 `kb-rag`, CT 200 `bench-runner`,
  CT 201 `llamacpp-builder` and VM 300 `docker-host` have been stopped since the pipeline record,
  checked on 2026-10-17 at 09:14 ET. They stay stopped and wait for the owner.
- **Two-card switch:** `use-engine.sh strata-two-card` attaches GPU 1 to CT 123, saves and turns
  off CT 120's autostart, and maps both cards to `strata-qwen38fn` in the watchdog.
- **Thermal:** `thermal-guard.sh` watches both cards. A trip stops the run.
- **Debug switch:** `STRATA_PIPELINE_DEBUG=1` is set only in the `noguess` cell. It makes the
  engine read its `STRATA_PIPELINE_*` test variables, and only θ is set.
- **End state:** `use-engine.sh strata` returns CT 123 to GPU 2 alone, serving the unchanged env
  file.

## Environment

From stage A's `environment.json` (`capture-env.sh`, 2026-10-17 13:27 UTC):
- Host: Proxmox VE 9.2.21, kernel 7.0.14-22-pve, firmware 3.18-7; EPYC 7532 with 8 × 64 GB
  DDR4-3200 (M393A8K40B22-CAE), one per channel; `schedutil` governor.
- GPU 1: V620 `0000:03:00.0`, `unique_id` 150e6a6800f84ebe. GPU 2: V620 `0000:83:00.0`,
  `unique_id` 99b104541144b36c. Both: VBIOS 113-D6030500-100, 30,704 MiB, 250 W cap, 0 mV
  offset, PCIe 16 GT/s x16.
- CT 123: Ubuntu 24.04, 24 cores, 122,880 MiB memory, 4 GiB swap.
- Strata: v0.1.44.1 (`296b59d`) with ggml from llama.cpp `3cf0325`; engine SHA-256
  `3a97b4b0…0de2`. ROCm `amdrocm-core-dev10.0-gfx1030` 10.0.0-4, HIP runtime
  `libamdhip64.so.7.15.26333`. Two V620s, gfx1030, 30.0 GiB each, wave32.
- Model: the four UD-Q4_K_XL shards, each with its SHA-256 stamp verified; the MTP draft layer
  at `/models/strata/mtp/rt`.
- Engine switches from the env file: `STRATA_HIP_PROMPT_F16=1`, `STRATA_SH_STREAM=1`,
  `STRATA_HIP_ADAPT_KERNEL_COPY=1`, `STRATA_ROUTE_TAIL_SKIP=0`.

---

## Results

### Stage A: freezing and guessed windows

Run 2026-10-17 09:27–10:13 ET, harness `8c1f733`, three interleaved passes of the five cells,
in CT 123 holding both cards; raw data in `/root/qwen38-flash-next/strata-sweep-20261017T132745Z/`.
Texts are from `text-repeat.py --against pw2-frozen-noguess`. Decode is the median of the passes'
medians across the nine class-and-depth rows, with the passes' range in brackets.

| Cell | Pipeline windows | Frozen | Rows with one text in all passes | Same text as `pw2-frozen-noguess` | Decode, t/s | Acceptance | Decode hit rate | Prefill d8000 / d32000 |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pw2` | 2 | no | 1 of 9 | 0 of 9 | 67.5 (66.8–67.9) | 79.1% | 97.6% | 969 / 1,431 |
| `serial` | off | no | 9 of 9 | 1 of 9 | 60.2 (60.1–60.2) | 79.7% | 97.8% | 959 / 1,415 |
| `pw2-frozen` | 2 | yes | **9 of 9** | **9 of 9** | **70.8 (70.6–70.9)** | 79.9% | 89.4% | 969 / 1,432 |
| `serial-frozen` | off | yes | 9 of 9 | 0 of 9 | 58.4 (58.3–58.4) | 79.2% | 89.8% | 960 / 1,414 |
| `pw2-frozen-noguess` | 2, no guessed windows | yes | 9 of 9 | | 64.8 (64.6–64.9) | 81.5% | 89.2% | 969 / 1,432 |

**The reading is the plan's first row:** `pw2-frozen` repeats, and matches
`pw2-frozen-noguess` on all nine rows.
- Guessed windows give the same tokens as the same windows run without guessing, on the same
  caches. The pipeline's own computation does not change the text.
- What changes it is one or more of the frozen choices. Stage B applies and names which.
- `pw2` gave three different texts on 8 of its 9 rows.
- Without pipeline windows, the text repeats frozen or not.
- `serial-frozen` matches `pw2-frozen-noguess` on 0 rows. As the plan noted, this is not
  decisive: pipeline windows leave 143 fewer expert slots (15,796 against 15,939), so the two run
  on different caches.

**Speed:**
- **Freezing with pipeline windows** decodes 4.9% faster: 70.8 against 67.5 t/s, with the
  ranges clear of each other.
- **Freezing without them** decodes 3.0% slower: 58.4 against 60.2.
- **The expert cache:** the frozen cells keep the experts the profile loads at start. Their
  decode hit rate is 89.2–89.8%, against 97.6–97.8%, and no expert is read over PCIe (1.2–1.3%
  unfrozen).
- **Guessed windows** are worth 9.3%: `pw2-frozen` decodes 70.8 t/s, against 64.8 for
  `pw2-frozen-noguess`.
- **Pass to pass:** pipeline-windows cells varied 1.1 t/s unfrozen and 0.3 t/s frozen.
- **Prefill:** pipeline-windows cells read 1.0–1.3% faster than serial ones at both depths.
  Freezing does not change it. First token at d32000 took 16.1–16.4 s in every cell.

**The cards in decode**, GPU 1 (the second stage) / GPU 2:

| Cell | Busy % | Power, W |
| --- | ---: | ---: |
| `pw2` | 90 / 86 | 174 / 147 |
| `serial` | 56 / 41 | 129 / 103 |
| `pw2-frozen` | 88 / 80 | 177 / 148 |
| `serial-frozen` | 54 / 38 | 129 / 101 |
| `pw2-frozen-noguess` | 92 / 40 | 160 / 102 |

**The engine read θ.** No log line prints θ or the pipeline's window counts; those print only
with decode timing on. In the source, a guessed window starts only when `B.p_on >= theta`
(`src/program/generate.cpp:12324`, `:12359`). With suffix drafts off, `p_on` starts at 1 and is
multiplied only by draft probabilities (`:12306`–`:12318`, `:12059`), so θ = 2 starts none. The measurements show it took effect:
- decode fell from 70.8 to 64.8 t/s;
- GPU 2, the first stage, fell from 80% to 40% busy in decode.

**Hang.** There were no `#267` lines, engine restarts, stalls or fallbacks to the serial loop in
the nine pipeline-windows loads: 153 requests, 17 per load. With the pipeline record that makes
765 requests across 45 starts, which rules out a per-request hang rate above about 0.4%, at 95%.

**Checks:**
- Each pipeline-windows load's log shows the pipeline on, with 272 MiB of CUDA0 kept out of the
  expert cache. No serial load shows it.
- Chat contract and tool calls: 15 of 15 loads.
- Rows: of 135, none empty, degenerate or cut off. Twenty-two ended on end-of-sequence at
  239–254 tokens, all `list`: at d0 in every cell, and at d32000 in the three frozen cells.
- Memory: 0 MiB outside VRAM on either card, at load and after the probe. The samplers saw no
  gap between requested and resident VRAM in 2,509 samples on GPU 2 and 2,507 on GPU 1. Another
  29 and 30 samples had only one counter and are left out.
- Thermal: the hottest DIMM read 53 °C; the hottest junction 85 °C, in prefill. There was no
  thermal trip.
- Drift: `pw2` decodes 67.5 t/s, inside the pipeline record's soak range (64.8–70.3).

## Deviations

## Conclusion
