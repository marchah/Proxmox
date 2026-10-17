# t1 — Review of the Strata fork plan for DeepSeek-V4.1-Flash

Review date: 2026-10-17. Review only; no engine changes, runs or deployments.

Document under review: `pro-v620/strata/DEEPSEEK-V4.1-PLAN.md` (commit `523b893`, branch
`marchah/strata-fork`).

Companion review: `t1-mimo-v26-pro-fork-review.md`.

## Owner decisions in force

- **Two separate forks.** DeepSeek first: its estimated 15–30 t/s (Q2) and 10–20 t/s (Q4)
  read as the most usable of the candidates. MiMo is second.
- **Model-store space is owner-managed.** No capacity ledger or eviction plan is a
  deliverable.
- **DIMM throttling is not a plan risk.** It appeared only under synthetic stress tests,
  never in real workloads, and the guard/watchdog remains the safety net.

## Verdict

The plan is specific, internally consistent and ready to execute. Its model contract,
artifact arithmetic and baseline numbers match the real sources (details below). The
gaps are additions rather than corrections: a fork-maintenance section, a format × path
kernel-support matrix, a few missing config rows, reuse cautions for PR #1518, explicit
lab integration, CPU tuning, a concurrency target, CI, and a risk table with stop
conditions. Highest value first: items 1, 2 and 5.

Method note: the contract and arithmetic were checked against the pinned sources. The
findings tables' per-file line citations were sampled (core headers re-read), not
exhaustively re-derived.

## Verified against sources

- **Model contract vs the pinned `config.json`** (DeepSeek-V4.1-Flash-1017 revision
  `1bae0e10…`): 40 layers, hidden 5120, vocab 129280; 64 heads of 512, 64 rotary dims,
  q rank 1280, o rank 1024 over 8 groups, window 128; compression ratios 0,0 then
  2×18 then 1×20; KV sources 2/8/14/20; index sources 2/8/14/20/24/28/32/36; candidate
  layer 20, 2048 blocks × 8; 384 experts, top-6, one shared, FFN 2304, sqrt-softplus,
  normalized weights ×1.5; mHC 4 streams, Sinkhorn 20 iters, eps 1e-6, RMS 1e-20,
  SwiGLU limit 10.0; Engram layers 1/14, n-grams to 4, 8 heads, width 256; DSpark
  3 layers, block 5, targets 37/38/39, 128 experts top-3. The 43-entry compression
  array explanation is correct.
- **Artifact arithmetic vs the publisher README** (`antirez/deepseek-v4.1-flash-gguf`
  at `dd8a266f…`): Q2 340.60 GiB / main 151.77 / Engram 188.83; Q4 482.98 / 294.15;
  Q2 = IQ2_XXS gate/up + Q2_K down; Q4 = Q4_K; Engram rows are read from disk, never
  made resident by the reference implementation. Header inventory 80+40+321+110+493+2
  = 1,046 tensors.
- **Baselines vs `pro-v620/qwen38-flash-next/runs/2026-10-16-strata.md`:** 32.8 (one
  card) / 37.3 (two cards) t/s no-MTP; 49.2 / 59.7 with MTP; 1,008 / 1,423 t/s prefill.
- **Estimate math:** selected routed matrices 2.39 GB/token (Q2) and 4.78 GB/token (Q4);
  scaling 37.3 t/s by 1.50/2.39 and 1.50/4.78 gives ≈23.4 and ≈11.7 t/s as stated.
- **Upstream facts:** v0.1.45 = `477ac13` (2026-10-17 06:53 UTC); `geometry.hpp`
  defaults to Flash-Next 2560/48 with compiled kernels; `family_layout.hpp` rejects
  unequal key/value widths and non-periodic attention; `model_family.hpp` already
  switches engines per family (`src/qwen35` precedent); PR #1518 exists at the reviewed
  head `6e326aa`; issue #479 says what the plan says it says.

## Gaps and improvements

### 1. Fork base and maintenance — add a section

The plan says "work inside a fork" but never fixes the base, the branch shape, or how
upstream fixes arrive. Upstream ships weekly (0.1.44.1 → 0.1.45 in a day).

- **Base:** v0.1.45 / `477ac13`, frozen. Do not track `main`.
- **Step 0 — qualify the base on this box before step 1:** run the existing Flash-Next
  qualification (yardstick, chat/tool gates as in the 2026-10-16 record) against
  `477ac13` with UD-Q4_K_XL. The release notes claim byte-identical Flash-Next answers
  vs 0.1.44.1 and faster decode; the lab is still on 0.1.44.1. This de-risks the fork
  base and may be a free upgrade for the deployed engine.
- **Structure:** follow upstream's own grain — new `ModelFamily::DeepSeekV41` plus a
  `src/deepseek/` engine path, the same shape as `src/qwen35` and PR #1518's additive
  `dsv4_ext`. Change `src/core/layer.cpp` / `session.cpp` only where the plumbing truly
  is Qwen-shaped; prefer parameterization and new modules over replacement. Keep a patch
  manifest (touched files, reason) so rebases stay mechanical.
- **Must-take fixes:** carry the lab's known gfx1030 issues (#2457 IQ3_S garbage, #884
  verify hang with `STRATA_HIP_ADAPT_KERNEL_COPY=1`, #1103 wheels) into the fork's docs
  and re-check them on the fork base; define the rebase cadence (e.g., every upstream
  release that touches kernels or HIP) and who runs the gates.
- **Upstreaming:** offer generic parts (family dispatch, session versioning, manifest
  format) upstream to shrink the delta; keep the model engine local.

### 2. Format × path support matrix — add a table

The MiMo review caught that native MMVQ lacks types 10 and 39. This plan should require
the same audit for its own types before step 2 is scheduled:

| Storage type (count) | GGUF read | CPU dot/dequant | HIP on gfx1030 | Scratch vs 5120/2304 | Fallback |
| --- | --- | --- | --- | --- | --- |
| IQ2_XXS (80) | | | | | |
| Q2_K (40) | | | | | |
| Q8_0 (321) | | | | | |
| F16 (110) / F32 (493) | | | | | |
| I8 Engram rows (2) | | | | | |

Known constraints to check against the source: the MMVQ supported-type list, the CPU
path that rejects activations wider than 2560 (the plan's own P0 row), `native_expert`
scratch caps, no WMMA and no hipBLASLt kernels on gfx1030 (dense prompt GEMMs use
rocBLAS). Exit: every type has a named working path and a bounded fallback
(dequantize + BLAS), or the artifact is re-quantized.

### 3. Config table — add the missing rows

From the fetched config, add to the typed `DeepSeekV41Config`:

- RoPE: `rope_theta` 10000, `compress_rope_theta` 160000, YaRN factor 16 with
  `original_max_position_embeddings` 65536 (only above 64k), max position 1M.
- `num_key_value_heads` 1 (single compressed KV head), `attention_bias` false.
- `swiglu_limit` 10.0; `hc_eps` 1e-6; `hc_sinkhorn_iters` 20.
- DSpark: noise token id 128799, Markov rank 256.
- Engram: table sizes (two ~384M-row tables, 264 B/row → 188.83 GiB), `engram_pad_token_id`
  2, compressed vocab 99092.

These are exactly the values a silent divergence would hide in.

### 4. PR #1518 reuse — add the cautions

The plan correctly refuses to merge it as the implementation. Add what the PR's own
discussion reports, so a reuse attempt does not repeat them: CUDA-only and untested on
HIP/Linux; targets the older V4 / IQ1_M; `dq_traits.hpp` scalar helpers are declared but
never defined (a real link failure on some toolchains); the GPU batched-prefill parity
test fails at chunk ≥ 2 (≈0.26 logit delta, unresolved). Its prefill design (chunked
prefill, ring-buffer snapshotting, strict summation order) is still the best reading
material before step 4.

### 5. Lab integration and acceptance — name the tooling

Step 7 is where deployment is mentioned, but the test path should be explicit earlier:

- Extend `glm53-flash/ct123-test-host.sh` for the fork (its `TEST_MODEL`/`TEST_ENGINE`
  and `TEST_UNITS` currently cover only glm53f/mimo llama.cpp units and Maya), so card
  ownership, CT 120 autostart, the watchdog map and the DRM cgroup stay coherent.
- Reuse `strata/use-engine.sh` semantics for switching and restore; keep llama.cpp as
  the operational reference and one-command rollback target (the MiMo plan says this;
  this plan should too).
- Records per `pro-v620/TEST-RECORDS.md`: plan committed before the run, results
  appended, `push-harness.sh` + `capture-env.sh`, environment.json, telemetry.
- End-to-end: the bench-runner usage workloads need the cold-request/token-counting
  changes already tracked as #112; check Hermes' provider against the fork's endpoint.
- Startup: align the engine's `--memory-limit-mib` with the CT limit at each test
  configuration (the Strata install pins 118784 MiB today; the DeepSeek Q2 tests will
  run CT 123 at 488 GiB via the test-host script).

### 6. CPU worker tuning — mirror the MiMo note

The plan says nothing about worker count or affinity. CT 123 gets 48 CPUs on this 7532
(24 physical cores; CPU n and n+32 share one; see `ct123-test-host.sh`), and the lab
measured STREAM peaking near 16 threads. Set the starting worker count from a
measurement, do not inherit Qwen's, and pin/exclude CPUs per the cpuset discipline.

### 7. Concurrency target — state it

The initial scope (one request, 4K–8K) is fine. Add the eventual service target
(one or two slots) and say whether the fork reuses v0.1.45's `--parallel`/batching and
admission/checkpoint machinery or excludes it. Upstream's own measurements: in hybrid
mode a lone request runs 4–11% slower with extra slots and concurrent gains are only
1.0–1.15x, so this is a deliberate choice, not a default. DeepSeek's shared KV/index
state may make slot batching different again.

### 8. CI and the real test subset

- A GitHub Actions job for the CPU-only build plus fixture/oracle tests, run on every
  change; the fork cannot rely on manual discipline alone.
- One documented CT 123 command for the gfx1030 subset (WMMA, hipBLASLt, `ple_parity`
  and AVX-512 tests skip there today); include the new scratch paths and the
  memory-sanitizer runs the plan already calls for.
- Record where numeric tolerances live and how they were derived (reference
  repeatability, CPU-vs-GPU reference delta) — the plan requires declared tolerances
  but not a registry.

### 9. Risk register and stop conditions — add a table

The plan lists uncertainties in prose. Turn them into: unknown → measurement that
resolves it → fallback → stop condition. At minimum: gfx1030 expert throughput at
5120×2304; host bandwidth and CPU/GPU overlap; GPU cache hit rate; cross-card shared
attention state; Engram random-read latency. Mirror the MiMo plan's clear kill
condition: if the fork cannot beat same-quant llama.cpp on the intended workload,
keep llama.cpp and document it.

### 10. Engram strategy — state the deviation

The publisher's reference (DwarfStar) never makes the Engram table resident and
recommends SSD streaming; this plan deliberately keeps it in RAM for Q2. State that
tradeoff explicitly, and schedule an early row-read benchmark so Q4's SSD-backed cache
is not first exercised at the end of the project. Keep `engram_pad_token_id` and the
compressed-vocab mapping in the manifest identity.

### 11. Campaign record requirements

Per TEST-RECORDS: the standard arms are two GPUs, one GPU and CPU-only (say why any is
left out — CPU-only likely is), and the drafter rule — DSpark exists for this model, so
the record must say why it is deferred and quote the no-draft control. Note the
initial arms: start one card, add the two-card encoder/decoder split as the plan
already proposes.

## Settled

- **Storage:** owner-managed; no ledger. Keep the lab's existing pinned download +
  SHA-256 verification pattern (`install.sh --download`, `.verified`) — correctness,
  not capacity.
- **DIMM thermal:** stress-test-only; no plan mitigation. The existing benchmark
  telemetry still samples DIMMs, so anything unusual will be visible in the records
  without new gates.

## Suggested plan edits (checklist)

1. Add "Fork base and maintenance" section (v0.1.45 frozen, step 0 qualification,
   family-engine structure, must-take fixes, rebase cadence).
2. Add format × path support matrix; gate step 2 on it.
3. Extend the model contract with RoPE/YaRN, KV heads, SwiGLU limit, Sinkhorn params,
   DSpark ids, Engram table sizes.
4. Add PR #1518 reuse cautions.
5. Add "Lab integration" with named tools, rollback, record and client requirements.
6. Add CPU worker/affinity note.
7. State the concurrency target and the batching decision.
8. Add CI job + documented CT 123 test subset + tolerance registry pointer.
9. Add risk/stops table.
10. State the Engram RAM/SSD deviation and the early row-read test.
11. Note standard arms and drafter rationale for the first record.
