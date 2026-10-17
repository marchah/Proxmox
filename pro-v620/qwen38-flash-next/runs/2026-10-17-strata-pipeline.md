# Qwen3.8-Flash-Next: pipeline windows and a shorter draft on two cards (Strata)

Plan committed 2026-10-17 · Run — · Status: planned

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

## Deviations

## Conclusion
