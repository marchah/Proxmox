# Qwen3.8-Flash-Next: pipeline windows and a shorter draft on two cards (Strata)

Plan committed 2026-10-17 · Run 2026-10-17 · Status: running

## Question

Does Strata decode faster on the two V620s with `--pipeline-windows 2` and a shorter, stricter
draft (`--spec 3 --spec-min-p 0.7`) than with the
[Strata record](2026-10-16-strata.md)'s two-card best, `--spec 5` without pipeline windows? And
does it run without the verify hang that Strata
[#2245](https://github.com/Niko1221/Strata/issues/2245) reports on two V620s?

**Where the setting comes from.** Strata's
[community report from two RX 6900 XTs](https://github.com/Niko1221/Strata/blob/296b59d/bench/results/2026-10-09-community-2x-rx-6900xt-0.1.41/README.md)
uses gfx1030, the V620's chip, with 16 GB per card. It ran Strata 0.1.41 plus three open
gfx103x pull requests and a modified ggml. On its layer split:
- These three flags together took decode from 64.7 / 68.8 / 68.3 to 77.2 / 82.3 / 75.7 t/s at 4K /
  32K / 128K prompt tokens (+19 / +20 / +11%). Draft acceptance rose from 68% to 83%, and prompt
  speed did not change.
- Each change alone was neutral or slower there:
  - `--pipeline-windows 2` with the default draft: +1–6%;
  - `--spec 3 --spec-min-p 0.7` without it: flat to −3%;
  - a 16-point grid of `--spec` and `--spec-min-p` without pipeline windows: best at 4 / 0.5.
- With pipeline windows, the same greedy request gave different text after each server start, in
  12 of 12 pairs.

The Strata record never ran it: its stage 7 split logs have no pipeline-windows line.

**What the option does** (Strata `docs/MULTI_GPU.md` and `src/program/generate.cpp` at
`296b59d`):
- On a layer split, the first card starts the next verify window while the last card still
  verifies the current one. It guesses that the current window is accepted whole, and puts its
  state back when the guess is wrong.
- It runs only on a layer split, with the draft layer, and without `--batch` slots or helper
  caches. Otherwise the engine logs `--pipeline-windows 2 is off: <reason>`.
- Its cost is 160 MiB of each card's expert cache, plus copies of the first card's recurrent state.
- On gfx1030 it stays off unless asked for; it is on by default only on gfx12. The draft layer
  stays on the last card unless `STRATA_MTP_STAGE0=1` moves it to the first. That option is new
  in 0.1.44. On two R9700s, pipeline windows with the draft layer on the first card decoded
  code 21% faster than the serial loop. Neither the 6900 XT report nor #2245 had this option.

**The hang (#2245, open).** The report comes from another owner of two V620s, on Strata 0.1.43.1,
with this exact setting.
- About 30% of runs end with `verify: the window never finished … (#267)`.
- It was bisected to `6126f8d`, a gfx103x attention kernel for the draft layer. Our build,
  `296b59d`, is 961 commits past it, and its source does not mention #2245.
- Three changes ran clean in that report:
  - `STRATA_ATTN_LANECELL=1`, with decode within ±1.4%;
  - `GPU_MAX_HW_QUEUES=2`, 116 of 116 requests, with the speed cost unmeasured;
  - `--pipeline-windows 1`.
- On a hang the server ends the engine and that request fails; the next request restarts the
  engine (`serve/server.py`, `FATAL_PREFIXES`).

## What answers it

1. **Speed.** The measure is median decode across the nine prompt-class-and-depth rows, over three
   interleaved passes. A pipeline-windows cell counts as faster if:
   - its median beats `s5` by more than 2%, and
   - its passes' range does not overlap `s5`'s.

   Decode per class, prefill at d8000 and d32000, and first-token time are reported beside it.
2. **Which change does it.** The screen's `s3p7` (the draft change alone) and `s5-pw2` (pipeline
   windows alone) are compared against `s5`. This shows whether the gain needs both, as in the
   6900 XT report.
3. **Stability.** A pipeline-windows cell passes only with zero `#267` lines, engine restarts,
   stalls and failed requests; `strata-cell.py` counts the first three as engine faults.
   - The record gives the requests and engine starts across every pipeline-windows load.
   - About 100 requests without a hang rule out a per-request hang rate above about 3% (at 95%).
     That would catch #2245's gfx1030 rate, but not a rate below 1 in 100.
4. **The setting must actually run.** Each pipeline-windows cell's engine log must show
   `--pipeline-windows 2: two verifiers per stage`. A cell whose log says it is off is invalid.
5. **Correctness.**
   - Gates: the chat contract and tool calls pass on every load, with no empty, degenerate or
     cut-off rows.
   - Reported, not a gate: whether each cell's greedy text is identical across its passes and to
     `s5`'s. Pipeline windows keep VRAM out of the expert cache, so a few experts run on the CPU
     and round differently (`docs/MULTI_GPU.md`).
6. **Memory.** 0 MiB outside VRAM on each card. The cache slots per card show the pipeline's
   reserve and which card holds the draft layer.

## Configurations

- **Two GPUs only.** Every cell is stage 8's `strata-best-2`: the split21 layer split
  (`MODEL_LAYER_SPLIT=auto`), with GPU 2 (`0000:83:00.0`) first holding layers 0–23 and GPU 1
  the rest. It also keeps `STRATA_MMQ_KQ=1`, `--suffix-draft 0` and the rest of
  `strata-qwen38fn.env`. Only the draft settings in each cell's name change.
- **One GPU: left out.** Pipeline windows need a layer split. The draft change alone runs on the
  split as `s3p7`.
- **CPU only and an optimized configuration: left out.** The question is a decode-loop setting
  on the split.
- **Speculative decoding.** Strata loads one drafter for this model, its MTP draft layer.
  - The screen includes a no-draft control.
  - With pipeline windows at `--spec-min-p 0.7`, it scans `--spec` 2, 3 and 4. If 4 is the
    fastest, 5 and 6 are added before stage B, in a cells file committed before they run.
  - `--spec 5 --spec-min-p 0.5` with pipeline windows is screened as well.
- **Two concurrent streams: left out.** Pipeline windows turn off with `--batch` slots. The
  served configuration has one slot, so two streams queue behind each other with or without them.

The record never measured any of these cells. `s3p7-pw2-st0` adds the draft layer's placement
to the 6900 XT setting.

## Controls

- `s5` is stage 8's `strata-best-2` (59.7 t/s; 59.8 in stage 7). It is the reference, and it
  checks drift against those records.
- `nodraft` is the split without the draft layer (37.3 t/s in stage 7).

## Method

- **Harness:** the commit that adds this plan, staged with `../push-harness.sh`. In it,
  `strata-cell.py` also counts these as stalls:
  - a verify window that never finished (`#267`);
  - the server restarting a dead engine.

  It also keeps the engine's `--pipeline-windows` lines (on, off and why, or serial).
  `test_strata_cell.py` covers both, and each new pattern fails its test when removed.
- **Run**, from `/root/harness/<sha12>/pro-v620/qwen38-flash-next/`, as stage 7 ran:

```bash
../strata/use-engine.sh strata-two-card
UNIT=strata-qwen38fn PATTERNS=build-hip/strata ./thermal-guard.sh   # separate shell; VMID unset, so both cards
for pci in 0000:83:00.0 0000:03:00.0; do
  systemd-run --unit="vram-residency-${pci:5:2}" --collect /usr/bin/python3 "$PWD/vram-residency-sampler.py" \
    --pci "$pci" --comm strata --output "/root/qwen38-flash-next/strata-pipeline-${pci:5:2}-residency.jsonl"
done
PASSES=1 CELLS=runs/2026-10-17-strata-pipeline-1-screen.cells ../strata/strata-sweep.sh   # stage A
CELLS=runs/2026-10-17-strata-pipeline-2-confirm.cells ../strata/strata-sweep.sh           # stage B, PASSES=3
../strata/use-engine.sh strata
```

- **Stage A, screen:** the eight cells of `2026-10-17-strata-pipeline-1-screen.cells`, one pass,
  with and without pipeline windows alternating. About 25 minutes: stage 7's scan took 3 minutes
  per load.
- **If a pipeline-windows cell hangs:**
  - That cell fails.
  - `2026-10-17-strata-pipeline-1b-lanecell.cells` reruns the failed cells with
    `STRATA_ATTN_LANECELL=1`, #2245's workaround on V620s. It is committed before it runs.
  - If those hang as well, the record states that pipeline windows do not run reliably on this
    build, and stage B confirms only cells without them.
  - `GPU_MAX_HW_QUEUES=2` is left out: it is not a `STRATA_*` key, so the launcher does not pass
    it to the engine.
- **Stage B, confirm:** three interleaved passes of `s5`, the fastest pipeline-windows cell that
  passed, and any other cell more than 2% over `s5` in the screen. The cells file is written from
  the screen and committed before it runs. If `st0` and the best `--spec` come from different
  cells, the confirm cell combines them, a combination the screen did not measure. About 30
  minutes.
- **Stage C, soak:** only if a pipeline-windows cell is faster in stage B. That cell runs alone at
  `PASSES=10`, ten cold starts with about 16 requests each, in about 30 minutes. Its requests add
  to the hang count.
- **Probes:** as in the Strata record. Chat mode, prompt classes `code`, `list` and `prose`, 256
  tokens each, greedy, depths 0, 8000 and 32000 (d8000 is about 5.8k tokens, d32000 about 23k).
  Each load gets one excluded warm-up request.
- **Duration:** about an hour, or an hour and a half with stage C.
- **Raw data:** `/root/qwen38-flash-next/strata-sweep-<ts>/` on the host.

## Safety

- **Other guests:** CT 120 `llamacpp`, CT 121 `hermes`, CT 140 `kb-rag`, CT 200 `bench-runner`,
  CT 201 `llamacpp-builder` and VM 300 `docker-host` were stopped when checked on 2026-10-17 at
  06:18 ET. They stay stopped and wait for the owner to restart them.
- **Two-card switch:** `use-engine.sh strata-two-card` attaches GPU 1 to CT 123, allows its DRM
  minors, saves and turns off CT 120's autostart, and maps both cards to `strata-qwen38fn` in the
  watchdog. CT 120 stays stopped.
- **Thermal:** `thermal-guard.sh` watches both cards. A trip stops the run, and cooling is checked
  before anything restarts.
- **A hang** stops the request, and the server restarts the engine inside the unit. If a card does
  not come back (the next load fails), the run stops; the host is not rebooted without the owner.
- **End state:** `use-engine.sh strata` returns CT 123 to GPU 2 alone, serving the unchanged env
  file (`--spec 4`, no `STRATA_MMQ_KQ`), the configuration the owner kept. CT 120's autostart is
  given back.

## Environment

As in the [Strata record](2026-10-16-strata.md#environment), to be replaced by stage A's
`environment.json`:
- Strata v0.1.44.1 (`296b59d`), with ggml from llama.cpp `3cf0325`, built for gfx1030.
- ROCm 10.0 (HIP runtime 7.15), on both V620s at the 250 W cap and 0 mV offset.
- The UD-Q4_K_XL shards and the MTP draft layer at `/models/strata/mtp/rt`.

---

## Results

### Stage A: screen

Run 2026-10-17 06:33–06:59 ET, harness `e46a65f`, one pass, in CT 123 holding both cards; raw
data in `/root/qwen38-flash-next/strata-sweep-20261017T103338Z/`. Decode is the median across the
nine class-and-depth rows, and acceptance is the median of the same nine rows.

| Cell | Pipeline windows | Draft | Decode, t/s | vs `s5` | Acceptance | Prefill d8000 / d32000 |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| `nodraft` | off | none | 37.3 | −37.5% | | 1,011 / 1,510 |
| `s5` | off | 5, min-p 0.5 | 59.7 | | 64.0% | 970 / 1,425 |
| `s3p7` | off | 3, min-p 0.7 | 57.6 | −3.5% | 84.8% | 954 / 1,396 |
| `s5-pw2` | 2 | 5, min-p 0.5 | 62.6 | +4.9% | 62.7% | 968 / 1,427 |
| `s2p7-pw2` | 2 | 2, min-p 0.7 | 67.3 | +12.7% | 86.1% | 963 / 1,425 |
| `s3p7-pw2` | 2 | 3, min-p 0.7 | **67.7** | +13.4% | 80.1% | 969 / 1,431 |
| `s4p7-pw2` | 2 | 4, min-p 0.7 | 65.5 | +9.7% | 79.7% | 965 / 1,424 |
| `s3p7-pw2-st0` | 2, draft layer on the first card | 3, min-p 0.7 | 62.3 | +4.4% | 78.9% | 959 / 1,375 |

**The gain needs both changes, as in the 6900 XT report.**
- Together, pipeline windows and the shorter draft decode 13.4% faster than `s5`.
- Pipeline windows alone add 4.9%. The shorter draft alone loses 3.5%, though its acceptance
  rises from 64.0% to 84.8%.
- On code, `s3p7-pw2` decodes 70.2 / 73.9 / 77.1 t/s at d0 / d8000 / d32000, against 62.8 /
  70.0 / 71.1 for `s5`.
- Prefill is unchanged (−0.2% and +0.4%).

**Draft length with pipeline windows**, at min-p 0.7: 67.3, 67.7 and 65.5 t/s at 2, 3 and 4. The
peak is at 3, so the plan's extension to 5 and 6 does not apply.

**The draft layer on the first card** (`STRATA_MTP_STAGE0=1`) is slower than on the last card:
62.3 against 67.7 t/s. It also reads a 23k-token prompt 3.6% slower.

**The cards in decode**, GPU 1 (the second stage) / GPU 2:

| Cell | Busy % | Power, W | sclk, MHz |
| --- | ---: | ---: | ---: |
| `s5` | 49 / 30 | 133 / 106 | 1,857 / 1,122 |
| `s3p7-pw2` | 95 / 92 | 177 / 148 | 2,394 / 2,081 |
| `s3p7-pw2-st0` | 75 / 97 | 132 / 179 | 1,945 / 2,316 |

With pipeline windows, GPU 2 goes from 30% to 92% busy in decode, and GPU 1 from 49% to 95%.

**Expert cache.** Pipeline windows kept 272 MiB of the first card's VRAM out of its cache, more
than the 160 MiB the documentation gives:
- The first card fell from 8,227 slots to 8,139, and the second from 7,712 to 7,657 (15,939 →
  15,796 in total).
- With `st0`, the draft layer's slots moved to the first card: 7,775 + 7,930.
- The decode hit rate stayed at 97.3–97.8% in every cell.

**Hang.** There were no `#267` lines, engine restarts or stalls in the five pipeline-windows loads:
85 requests across 5 engine starts, 17 per load. No request fell back to the serial loop. The
`STRATA_ATTN_LANECELL=1` rerun therefore does not apply.

**Checks:**
- Each pipeline-windows log shows `--pipeline-windows 2: two verifiers per stage, 2 stages overlap
  across windows (decode too; …)`.
- Chat contract and tool calls: 8 of 8 loads. Rows: none flagged.
- Memory: 0 MiB outside VRAM on either card, at load and after the probe. The samplers saw no
  gap between requested and resident VRAM in 1,439 samples per card; 14 more per card had only
  one counter and are left out.
- Thermal: the hottest DIMM read 55 °C; the hottest junction 85 °C, in prefill. There was no
  thermal trip.
- Drift: `s5` decodes 59.7 t/s, as in stage 8, and `nodraft` 37.3, as in stage 7.
- Greedy text:
  - It differs between draft settings even without pipeline windows: `s3p7` matches `s5` on 2 of
    9 rows, and `nodraft` on 1.
  - So matching `s5`'s text cannot single out pipeline windows: `s3p7-pw2` matches it on 1 row.
  - Stage B's three passes show whether each cell repeats its own text across starts.

### Stage B: confirming passes

Run 2026-10-17 07:04–07:55 ET, harness `aa7cc22`, three interleaved passes of the six cells the
plan's rule took from the screen (`2026-10-17-strata-pipeline-2-confirm.cells`); raw data in
`/root/qwen38-flash-next/strata-sweep-20261017T110427Z/`. Decode is the median of the passes'
medians across the nine class-and-depth rows, with the passes' range in brackets.

| Cell | Decode, t/s | vs `s5` | Acceptance | Prefill d8000 | Prefill d32000 | First token d32000 | Rows with the same text in all passes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `s5` | 59.6 (59.5–59.6) | | 64.0% | 961 (955–970) | 1,420 (1,415–1,428) | 16.3 s | 9 of 9 |
| `s5-pw2` | 65.1 (62.3–65.7) | +9.2% | 61.8% | 965 (954–970) | 1,424 (1,420–1,431) | 16.2 s | 0 of 9 |
| `s2p7-pw2` | 67.8 (65.0–67.8) | +13.8% | 85.5% | 966 (957–967) | 1,425 (1,421–1,432) | 16.2 s | 0 of 9 |
| `s3p7-pw2` | 66.9 (66.9–68.4) | +12.2% | 80.2% | 967 (964–969) | 1,424 (1,422–1,430) | 16.2 s | 0 of 9 |
| `s4p7-pw2` | **68.1 (65.7–69.5)** | +14.3% | 77.5% | 965 (962–972) | 1,426 (1,423–1,429) | 16.2 s | 1 of 9 |
| `s3p7-pw2-st0` | 60.7 (60.4–64.7) | +1.8% | 80.2% | 959 (958–964) | 1,377 (1,373–1,381) | 16.8 s | 0 of 9 |

**Against the rule** (more than 2% over `s5`, with no overlap between the ranges):
- **Faster:** `s4p7-pw2`, `s2p7-pw2`, `s3p7-pw2` and `s5-pw2`. Their slowest passes, 62.3–66.9
  t/s, all beat `s5`'s fastest, 59.6.
- **Not faster:** `s3p7-pw2-st0`. Its median is only 1.8% above `s5`.

**No order among `--spec` 2, 3 and 4 at min-p 0.7.** Their ranges overlap: 65.0–67.8, 66.9–68.4
and 65.7–69.5. The screen's leader, `s3p7-pw2`, has the lowest median of the three here.
- Pipeline-windows cells vary 1.5–4.3 t/s between passes; `s5` varies 0.1.
- With pipeline windows, `--spec 5 --spec-min-p 0.5` gains 9.2%, against 12–14% for the stricter
  draft.
- Prefill is unchanged, except with the draft layer on the first card: 3% slower at d32000.

**Greedy text changes between server starts with pipeline windows.**
- `s5` gave the same text in all three passes on 9 of 9 rows.
- Every pipeline-windows cell did so on 0 or 1 rows, with two or three different texts per row.
  The summary flags these cells `reps disagree` and leaves them out of its trade table.
- The 6900 XT report saw the same thing.
- As the plan set, this is reported, not a gate. What causes it was not tested.

**Hang.** There were no `#267` lines, engine restarts or stalls in the 15 pipeline-windows loads:
255 requests across 15 engine starts. Over stages A and B that makes 340 requests across 20
starts. That rules out a per-request hang rate above about 0.9%, at 95%.

**The cards in decode**, GPU 1 / GPU 2:

| Cell | Busy % | Power, W |
| --- | ---: | ---: |
| `s5` | 59 / 40 | 140 / 108 |
| `s3p7-pw2` | 93 / 76 | 182 / 154 |
| `s4p7-pw2` | 91 / 86 | 176 / 154 |
| `s3p7-pw2-st0` | 53 / 97 | 131 / 180 |

**Checks:**
- Each pipeline-windows load's log shows the pipeline on.
- Chat contract and tool calls: 18 of 18 loads.
- Rows: of 162, none empty, degenerate or cut off. Fourteen ended on end-of-sequence at 241–254
  tokens, all `list` at d0, including all three of `s5`'s.
- Memory: 0 MiB outside VRAM on either card, at load and after the probe. The samplers saw no
  gap in 2,763 samples per card; 34 more per card had only one counter.
- Thermal: the hottest DIMM read 56 °C; the hottest junction 87 °C, in prefill. There was no
  thermal trip.

### Stage B2: the draft layer on the first card at `--spec 4`

This stage was added at the owner's request (see Deviations). Run 2026-10-17 08:21–08:40 ET,
harness `2dcdaea`, three interleaved passes; raw data in
`/root/qwen38-flash-next/strata-sweep-20261017T122133Z/`.

| Cell | Decode, t/s | Passes | Acceptance | Prefill d8000 | Prefill d32000 | First token d32000 |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| `s4p7-pw2` | **65.8 (65.7–68.4)** | 68.4, 65.8, 65.7 | 77.2% | 969 | 1,432 | 16.1 s |
| `s4p7-pw2-st0` | 64.0 (61.6–64.3) | 64.0, 64.3, 61.6 | 78.4% | 963 | 1,383 | 16.7 s |

- **Not better:** `s4p7-pw2-st0` decodes 2.7% slower than `s4p7-pw2`, so stage C soaks
  `s4p7-pw2`. This matches the result at `--spec 3` in stages A and B.
- **Prefill:** with the draft layer on the first card, a 23k-token prompt reads 3.4% slower.
- **Between sessions:** `s4p7-pw2`'s median here, 65.8, lies inside its stage B range (65.7–69.5).
- **The cards in decode**, GPU 1 / GPU 2:
  - `s4p7-pw2`: 91 / 85% busy, 172 / 150 W.
  - `s4p7-pw2-st0`: 56 / 97% busy, 125 / 177 W. With the draft layer on GPU 2, GPU 2 carries the
    load and GPU 1 idles about half the time.
- **Cache:** the draft layer's slots moved to the first card, 8,139 + 7,657 → 7,775 + 7,930.

**Checks:**
- Pipeline windows were on in all six loads.
- No `#267` line, engine restart or stall in 102 requests: 51 per cell, over 6 starts.
- Chat contract and tool calls: 6 of 6 loads.
- 0 MiB outside VRAM.
- Greedy text was the same in all three passes on 0 of 9 rows for `s4p7-pw2`, and on 1 of 9 for
  `s4p7-pw2-st0`.
- No thermal trip.

## Deviations

- Stage B took 51 minutes, not the plan's estimate of about 30. The plan's rule picked six cells
  rather than the two or three the estimate assumed. The owner chose the full rule over trimming
  it to `s5`, `s3p7-pw2` and `s2p7-pw2`.
- **Stage B2, added at the owner's request after stage B.**
  - **What runs:** `s4p7-pw2`, stage B's fastest cell, against the same cell with the draft
    layer on the first card (`s4p7-pw2-st0`). Three interleaved passes,
    `2026-10-17-strata-pipeline-2b-st0.cells`, about 20 minutes.
  - **Decision:** `s4p7-pw2-st0` becomes stage C's cell only if it is better by stage B's rule:
    a median more than 2% above `s4p7-pw2`'s, with no overlap between the ranges. Otherwise
    stage C soaks `s4p7-pw2`.
  - **Why it is worth one run:** the screen and stage B measured the draft layer's placement only
    at `--spec 3`.

## Conclusion
