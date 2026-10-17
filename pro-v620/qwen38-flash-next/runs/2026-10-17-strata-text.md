# Qwen3.8-Flash-Next: why greedy text changes between starts with pipeline windows (Strata)

Plan committed 2026-10-17 · Run — · Status: planned

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

As in the [pipeline record](2026-10-17-strata-pipeline.md#environment), to be replaced by stage A's
`environment.json`: Strata v0.1.44.1 (`296b59d`) on gfx1030, ROCm 10.0, both V620s at the 250 W
cap and 0 mV.

---

## Results

## Deviations

## Conclusion
