# t1 — Reconciliation of the t1 and t2 reviews of the two Strata fork plans

2026-10-17. Working merge document. It joins the two independent review rounds of the
branch `marchah/strata-fork` commit `523b893` into one action list per plan, records the
corrections each round needs, and fixes the sequencing. Where this file and a review file
disagree on framing, this file supersedes.

Reviews reconciled:
- t1 round (this author): `t1-deepseek-v41-fork-review.md`, `t1-mimo-v26-pro-fork-review.md`
- t2 round: `t2-DEEPSEEK-V4.1-REVIEW.md`, `t2-MIMO-V2.6-REVIEW.md`

## Decisions in force

- **Two separate forks.** DeepSeek first (its estimated 15–30 t/s Q2 / 10–20 t/s Q4 is the
  most usable), **MiMo after DeepSeek**. MiMo is sequenced, not shelved: the t2 MiMo
  "revival conditions" become pre-start checks for the second fork.
- Model-store capacity is owner-managed; no ledger or gate. Keep the existing pinned
  download + SHA-256 verification pattern.
- DIMM throttling is not a plan risk (stress-test-only; guard/watchdog remains the safety
  net). Existing benchmark telemetry still samples DIMMs.
- Dev loop pinned to PVE CT 123 (recorded by t2 as an owner decision): fork-specific build
  root, CPU fixtures in-container (AVX2 traits cannot run on the macOS authoring machine),
  HIP tests only with both cards free.

## Verdict on the two rounds

- **t2 is the decision record**: verdict, owner decisions, accepted changes, not-carried
  items, follow-ups. Maintained in that style.
- **t1 is the technical gap list**: contract verification against the pinned configs, the
  format × path kernel audit, maintenance and CI items.
- Neither is a superset. The merged lists below are the actionable set.

## DeepSeek plan — merged changes for `pro-v620/strata/DEEPSEEK-V4.1-PLAN.md`

From t2 (accepted by the owner, land as written):

| # | Change | Note |
| --- | --- | --- |
| D1 | Fork topology line in the header | DeepSeek-only fork, first; MiMo separate, after |
| D2 | Resolve the llama.cpp baseline question in step 1 | Does llama.cpp support `deepseek41`/Engram? If yes, measure a same-quant baseline (Strata context is per slot, llama.cpp's shared). If no, reframe the decision gate as fixture-qualified correctness + the owner's usable threshold; current deployment stays the restore target |
| D3 | Name the CT 123 test setup now, value the limit later | `TEST_MODEL`/`TEST_ENGINE` entry in `glm53-flash/ct123-test-host.sh`: unit, `Conflicts=`, watchdog map, `TEST_MEMORY_MIB`, host-margin rule; the number comes from step 1's ledger |
| D4 | Parameterize `use-engine.sh` and `ct123-test-host.sh` once | Engine root and unit as variables, so the MiMo fork reuses the plumbing |
| D5 | Inherited gfx1030 requalification list | `STRATA_HIP_ADAPT_KERNEL_COPY` (#884), `STRATA_HIP_PROMPT_F16`/`STRATA_SH_STREAM`, `STRATA_MMQ_KQ`, #2457, #1103, rocBLAS-only dense GEMMs, 10 s compute-job timeout; samplers/guard into the campaign Safety section |
| D6 | Pin the dev loop to CT 123 | Per the decision in force above |
| D7 | Q2-release compatibility statement | Exact full-forward prefill only; SWA bounded replay is approximate and a separate acceptance with cache-identity implications |
| D8 | Repo bookkeeping in step 7 | Root README inventory and CLAUDE.md "Where to look" when a service is installed |

From t1 (add to the same change list):

| # | Change | Note |
| --- | --- | --- |
| D9 | Fork base and maintenance section | Freeze v0.1.45 / `477ac13`; qualify the base on this box first (yardstick + chat/tool gates on Flash-Next, which is still on 0.1.44.1); follow the per-family engine pattern (`src/deepseek/` + `ModelFamily`, as `src/qwen35` and PR #1518's additive layout); patch manifest; rebase cadence; must-take fixes; upstreaming of generic parts |
| D10 | Format × path support matrix | IQ2_XXS, Q2_K, Q8_0, F16, F32, Engram I8: GGUF read / CPU / HIP on gfx1030 / scratch vs 5120·2304 / fallback. Gate step 2 on it |
| D11 | Config table additions | RoPE (`rope_theta` 10000, `compress_rope_theta` 160000, YaRN factor 16 above 65536), `num_key_value_heads` 1, `swiglu_limit` 10.0, Sinkhorn 20/eps 1e-6, DSpark ids (noise 128799, Markov 256), Engram table sizes/pad id |
| D12 | PR #1518 reuse cautions | CUDA-only/untested on HIP, older V4, `dq_traits.hpp` link gap, chunk ≥ 2 GPU prefill parity failure unresolved; its additive layout is the pattern to follow |
| D13 | Engram strategy note | Q2 RAM-resident is a deliberate deviation from the publisher's SSD row-streaming policy; early row-read benchmark de-risks Q4 |
| D14 | CPU worker tuning | Threads/affinity/cpuset measured on this 7532, not inherited from Qwen |
| D15 | Concurrency target and batching decision | State the eventual slot target; decide reuse vs exclusion of v0.1.45 `--parallel`/admission machinery |
| D16 | CI and tolerance registry | CPU-only build + fixture tests on GitHub Actions; documented CT 123 gfx1030 test subset; where numeric tolerances live |

## MiMo plan — merged start checklist for `pro-v620/mimo-v26-pro/`

From t2 ("what a revival should carry", now pre-start checks):

| # | Change | Note |
| --- | --- | --- |
| M1 | Fork-separation line; adopt DeepSeek's parameterized scripts | No second bespoke extension of the same switch scripts |
| M2 | Calibrate the sensitivity model with local anchors | 6.8 GiB/s op-offload copy band bounds cache refresh; 30-core no-spec profile is the host-service reference; acceptance curve 90/86/79% d0 → 59% d8000 grounds `m` |
| M3 | Step 2 states the MXFP4 shipment explicitly | The Q2_K development quant keeps MXFP4 down projections, so the Q2_K milestone needs the MXFP4 kernels |
| M4 | Keep the Q2_K same-quant llama.cpp baseline | MXFP4 times are not a same-quant comparison; context-per-slot rule |
| M5 | Dev loop in CT 123 | As the decision in force |
| M6 | gfx1030 requalification list | As D5 |

From t1 (add to the start checklist):

| # | Change | Note |
| --- | --- | --- |
| M7 | Routing-locality probe first | Instrument the official reference (or a bench-only llama.cpp build) for a few hundred tokens per prompt class; report selected-expert concentration and coverage for a 25–30 GiB cache against a pre-declared decision rule. This is the fork's decisive unknown and is measurable before any engine work |
| M8 | Re-baseline all pins at start | Fork release (post-v0.1.45), llama.cpp reference (b11583 today), MXFP4 revision `5f387f52`, Q2_K artifact revision, ggml pin; qualify the base on gfx1030 |
| M9 | Fork maintenance section | As D9, with the Qwen3.6 driver as donor |
| M10 | Descriptor nits | `layernorm_epsilon` 1e-5, `attention_chunk_size` 128, padded vocab 152576 |
| M11 | Lab integration naming | `strata-mimo` unit/env/launcher, test-host extension, sweeps, records, rollback to llama.cpp, `--memory-limit-mib` aligned with the CT limit |
| M12 | Concurrency alignment | Two 32k slots target; same batching decision as D15 |
| M13 | CI, test subset, tolerance registry | As D16 |
| M14 | Risk table and the formal kill gate | Promote the plan's step-8 exit condition; include MTP acceptance on Q2_K (unmeasured so far) |

## Corrections to apply to the t2 files before they are cited

1. **DeepSeek "Stage 8" bullet mixes attributions.** The prefill figures (989/964 at
   d8000, 1,008/1,423 at d32000) and first-token times (5.9–6.0 / 16.3–22.9 s) are
   Strata's; llama.cpp's prefill in that record is 358/340. "Stage 7: … MTP 49.2 / 59.7
   (+51% / +60%)" — 49.2/59.7 are stage 8 values; stage 7's are 49.4/59.8, and the
   +51%/+60% gains are stage 7's.
2. **"Roughly twice that floor"** — 23.4 vs 9.2 is ≈2.5×, and it compares a traffic-only
   anchor (DeepSeek) with a full sensitivity model (MiMo). The direction is robust; the
   precision is not.
3. **MiMo deferral rationale** — lead with the throughput ceiling (central ≈9.2 t/s vs
   DeepSeek's Q2 floor), not RAM fit: the Q2_K development quant was chosen to remove fit
   pressure (~98 GiB headroom).
4. **Minor rounding** — Q2 "366 GB decimal = 340.60 GiB" is within HF display rounding
   (≈340.9 GiB); don't quote it as exact.

## Corrections to apply to the t1 files

1. **DeepSeek rollback/decision wording** — t1's "keep llama.cpp as the operational
   reference" carried the MiMo assumption into DeepSeek; t2's D2 is the correct treatment
   (llama.cpp may not run `deepseek41`).
2. **MiMo sequencing framing** — t1's "second fork" sections stay valid; the ruling is
   "after DeepSeek", so the t2 revival conditions apply as pre-start checks.

## What both rounds agree on (no action)

- Contracts and arithmetic reproduce; quoted lab data matches the records.
- gfx1030 requalification, lab integration, and the storage skip.
- The plans' scope (same-quant correctness as the bring-up gate; vision, CUDA, long
  context deferred) is right for this machine.
