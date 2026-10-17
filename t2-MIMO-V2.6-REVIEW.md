# Review: MiMo-V2.6-Pro-RL Strata fork plan

Review date: 2026-10-17. Review of both documents on branch `marchah/strata-fork`, commit
`523b893` ("Strata fork plan"): [STRATA-REFACTOR-PLAN.md](pro-v620/mimo-v26-pro/STRATA-REFACTOR-PLAN.md) and
[STRATA-PERFORMANCE-ESTIMATE.md](pro-v620/mimo-v26-pro/STRATA-PERFORMANCE-ESTIMATE.md). The commit adds documents
only: no engine changes, downloads or runs were made. This record reviews the plans,
records the owner's deferral decision, and lists what a revival should carry.

## Verdict

The analysis is sound — pins resolve, arithmetic reproduces, and the quoted baseline is
reported faithfully — but the resulting outlook is not a project worth taking on this
machine now. The plan's own central case lands MiMo around 9.2 t/s under assumptions the
estimate itself shows are demanding against a 5–6% resident expert capacity and 10.31 GiB
of mandatory routed-expert reads per token, while the same-hardware anchor for DeepSeek's
fork projects roughly twice that floor. The owner deferred the MiMo fork on 2026-10-17:
MiMo does not appear usable with the current server configuration (1 TB-total/42B-active
weights only fit with every spare GiB of both cards and the container limit, as the
baseline record demonstrates).

## Owner decisions recorded with this review (2026-10-17)

- Two forks come from this branch's analysis, not one. The DeepSeek fork proceeds first;
  see [the DeepSeek review](t2-DEEPSEEK-V4.1-REVIEW.md).
- This MiMo fork plan is deferred, retained as the deferral record and revived by a
  re-estimate under the revival conditions at the end of this file.
- Model-store capacity is not a planning item (the owner makes space as needed).
- Development and tests would run in PVE on CT 123 when revived.

## What the review checked

### External anchors

- Upstream `Niko1221/Strata` resolves at reviewed commit `477ac13c…`; v0.1.45 as the
  current release, matching the estimate's "latest upstream numbers checked" section.
- The [ggml-org MiMo GGUF revision](https://huggingface.co/ggml-org/MiMo-V2.6-Pro-RL-GGUF)
  `5f387f52` cited by the plan is already a local artifact: the
  [baseline record's](pro-v620/mimo-v26-pro/runs/2026-10-15-baseline.md) environment capture lists the seven
  MXFP4 shards whose sizes sum to 554,211,764,704 bytes — the README's 554.21 GB — plus
  both MTP heads. Both fork plans pin the same tokenizer/model
  references; their HF links were not fetched separately in this review and get the same
  step-1 resolve-check rule as every other pin.

### Arithmetic

Recomputed against the plan's stated geometry:

| Claim | Recomputed | Holds |
| --- | --- | --- |
| MXFP4 expert = 20,054,016 bytes = 19.125 MiB; layer 7.17 GiB; pool 494.86 GiB | 3 × 6144 × 2048 × 17/32; × 384; × 69 × 384 | yes |
| Selected routed reads 10.31 GiB/token (MXFP4), 7.68 GiB/token (Q2_K) | 8 × 69 × 19.125 / 14.25 MiB | yes; Q2 cut is 25.5% |
| Q2_K expert 14.25 MiB; pool 368.72 GiB | Q2_K gate/up at 2.25 bpw-average × values + MXFP4 down | yes |
| Global KV 50 KiB/token (F16), SWA rings 37.5 MiB/slot, 1.56 GiB at 32k, ~50 GiB at 1M | 10 layers × 8 heads × (192 + 128) × 2 B; 60 × 128 tokens | yes |
| Sticky fit numbers: 473.3 / 480.5 GiB at `-ncmoe 67/68`; GTT cap 251.8 GiB; 488 GiB limit | baseline record's fit ledger | yes |
| Cache coverage 1,339–1,606 experts = 5–6% of 26,496 at a 25–30 GiB budget | 25–30 GiB ÷ 19.125 MiB | yes |
| Sensitivity model central case ≈ 9.2 t/s at f 0.30, h 0.30, s 1.30, m 1.35 | 1/4.74 formula | yes |
| Flash-Next multipliers 2.70× one card, 3.27× two; two-card MTP gain 21% | 49.2/18.2; 59.7/18.2; 59.7/49.2 | yes, from [the Strata record](pro-v620/qwen38-flash-next/runs/2026-10-16-strata.md) |
| Local MTP factors 1.34 (d0) / 1.14 (d8000) | 6.35/4.74; 5.17/4.54 | yes, from [the baseline](pro-v620/mimo-v26-pro/runs/2026-10-15-baseline.md) |

### Quoted lab data

The baseline numbers (4.74/4.54, 6.35/5.17, 28.3/28.9 prefill, 6.92/7.78 two-stream,
acceptance 86%/59%, the n-max screen's median rule, fit pass 2's anonymous-memory turn)
are quoted faithfully and with the record's own caveats. The placement figures the estimate
uses (`h0 = 3/69`) match the no-spec pick (`-ncmoe 67`, three expert layers on the cards).

## Why the deferral is the right read

- The plan's estimate puts the central four-bit case at ~9.2 t/s and shows 15–20 t/s
  requires 60–80% cache hits against a resident capacity of 5–6% of the pool. Nothing in
  it contradicts the DeepSeek fork's anchored ~23.4 t/s Q2 floor on the same cards.
- The MXFP4 fit consumes the container: 482.9 GiB anonymous RAM against a 488 GiB limit,
  ~7 GiB of host MemFree, both cards held — matching the baseline's own conclusion that it
  holds every GiB of the box.
- The Q2_K development quant helps traffic by only 25.5%, while keeping the unmeasured
  routing-locality question open — the fork's decisive unknown remains unmeasured before a
  new engine exists.

The plan's step-8 exit condition ("if memory-safe caching or optimized compute cannot beat
the same-quant configuration, keep llama.cpp") already anticipated a negative outcome; the
deferral is that condition recognized before the engine is built.

## What a revival should carry from this review

These apply to the plan documents when the fork is taken up again:

1. **A fork-separation line.** State that the MiMo fork is independent of the DeepSeek
   fork, and that the shared switch scripts (`glm53-flash/ct123-test-host.sh`,
   `pro-v620/strata/use-engine.sh`) are parameterized by the DeepSeek fork's step 7 —
   adopt that plumbing rather than a second bespoke extension of the same scripts.
2. **Calibrate the sensitivity model with the local anchors** so its `s`, cache-transfer
   and MTP terms stop being free parameters: the measured 6.8 GiB/s op-offload copy band
   bounds GPU-cache refresh (it capped prefill in the baseline), the 30-core no-spec decode
   profile is the reference for host expert service, and the acceptance-vs-depth curve
   (90/86/79% at d0 → 59% median at d8000) grounds `m`. The estimate labels all four
   scenario rows as assumed; these anchors are already in the repository.
3. **Make step 2 state the MXFP4 shipment explicitly.** The Q2_K development quant keeps
   MXFP4 down projections, so the Q2_K milestone has no value without the MXFP4 expert
   kernels. Finding 4 says this; the step-2 text can be read otherwise.
4. **Keep the Q2_K same-quant llama.cpp baseline measurement** the plan already requires
   (the MXFP4 times are not a same-quant comparison), with the known context-accounting
   rule: Strata's context is per slot, llama.cpp's is shared across slots.
5. **Dev loop in CT 123** (owner decision): fork-specific build root on the container,
   CPU fixtures in-container (AVX2; not the macOS authoring machine), HIP tests only with
   both cards free, memory lifted per the test-host script only for full-model loads.
6. **gfx1030 requalification list**, as on the DeepSeek review: the `STRATA_*` switches,
   #884/#2457/#1103, rocBLAS-only dense GEMMs and the 10 s compute-job timeout, into the
   campaign Safety sections.

## Not carried (owner decision)

- Model-store capacity planning: skipped; space is made when a download needs it. (The Q2_K
  shard set is ~390 GiB on top of the ~560 GB already staged for this model.)

## Revival conditions

Re-estimate and reconsider when one of these changes the deferral's basis:

- the second V620 is replaced or a third card joins (more resident-expert capacity),
- host RAM grows beyond 512 GiB (the 488 GiB container ceiling stops binding),
- an upstream MiMo scheduling policy or a published `deepseek`-style fix targets exactly
  this locality problem (the fork's decisive unknown),
- or DeepSeek's fork finishes and its reference captures (fixtures, dev loop, switch
  plumbing) make the marginal MiMo work smaller.
