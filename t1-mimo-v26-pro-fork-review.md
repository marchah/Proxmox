# t1 — Review of the Strata fork plan for MiMo-V2.6-Pro-RL

Review date: 2026-10-17. Review only; no engine changes, runs or deployments.

Documents under review (commit `523b893`, branch `marchah/strata-fork`):
- `pro-v620/mimo-v26-pro/STRATA-REFACTOR-PLAN.md`
- `pro-v620/mimo-v26-pro/STRATA-PERFORMANCE-ESTIMATE.md`

Companion review: `t1-deepseek-v41-fork-review.md`.

## Sequencing

This is the **second** fork. The owner is building DeepSeek first, since its estimated
15–30 t/s (Q2) / 10–20 t/s (Q4) reads as the most usable of the candidates; MiMo runs
after. Consequences for this plan:

- Do not schedule MiMo implementation work until DeepSeek reaches its Q2 text release
  (gates 1–6) or the owner calls it.
- At start, **re-baseline every pin**: the fork base (Strata release after v0.1.45), the
  llama.cpp reference build (b11583 today), the MXFP4 revision `5f387f52`, the Q2_K
  artifact revision, and the ggml pin. Those pins drift weekly.
- Reuse the DeepSeek fork's maintenance and lab-integration patterns rather than
  re-deriving them; the code stays in a separate fork.

## Owner decisions in force

- Two separate forks; DeepSeek first (usability of the estimated throughput).
- Model-store space is owner-managed; no capacity plan is a deliverable.
- DIMM throttling is not a plan risk: seen only in synthetic stress tests, never in real
  workloads; the guard/watchdog is the safety net.

## Verdict

The strongest of the two plans: the geometry, quant arithmetic and performance model all
survive checking against the published config and the lab's own baseline record. The gaps
are additions, not corrections. Highest value: the explicit fork base, the routing-locality
probe (it tests the central estimate assumption before the caching work exists), the fork
maintenance section, and the lab-integration naming.

Method note: the contract and arithmetic were checked against the pinned sources. The
findings tables' per-file line citations were sampled (core headers re-read), not
exhaustively re-derived.

## Verified against sources

- **Geometry vs the pinned HF `config.json`** (`XiaomiMiMo/MiMo-V2.6-Pro-RL` at
  `b61f2185…`): hidden 6144, 70 layers, SWA 128; global layers 0, 7, 15, 23, 31, 39, 47,
  55, 62, 69; 128 query / 8 KV heads; K width 192, V width 128; partial rotary 0.334
  (64 dims); RoPE 1e7 global / 1e4 SWA; sinks on SWA only (`add_swa_attention_sink_bias`
  true, full false); value scale 0.612; 384 experts top-8, sigmoid + correction bias,
  n_group 1, no shared expert, dense layer 0; fused QKV layout; eps 1e-5; vocab 152576;
  max position 1M. The plan's table is exact.
- **Quant arithmetic** (recomputed): MXFP4 expert 19.125 MiB; pool 494.86 GiB over 69
  layers; selected routed weights 10.31 GiB per token; mixed Q2_K expert 14.25 MiB; pool
  368.72 GiB; selected 7.68 GiB per token.
- **KV arithmetic:** 50 KiB per token over the ten global layers; 1.56 GiB per 32k slot;
  37.5 MiB of SWA ring per slot; ~50 GiB of global F16 KV at 1M.
- **Estimate model:** T0 = 211 ms; h0 = 4.35%; the modest/central/strong scenarios
  recompute to ≈6.6 / ≈9.2 / ≈12.0 t/s, and 15–20 t/s does require ≈60–80% hits at
  1.5x host service and 1.6x MTP — as the document says.
- **Baselines vs `runs/2026-10-15-baseline.md`:** 4.74 / 6.35 t/s short context, 5.17 at
  8k, 28.3 t/s prefill, 6.92 / 7.78 two-stream, 86% / 59% acceptance; CPU-bound decode
  at 22–60 W per card.
- **Upstream facts:** installed v0.1.44.1 vs reviewed `477ac13`; the lab's llama.cpp
  b11583 contains the MiMo, fused-QKV and MTP work; #2457/#884 remain the gfx1030 flags
  to carry.

## Gaps and improvements

### 1. State the fork base commit explicitly

The plan cites the installed 0.1.44.1 and the reviewed upstream `477ac13` but never says
which one the fork starts from. Write it down (today: v0.1.45 / `477ac13`; at start:
whatever release is current, re-qualified). Add the same "qualify the base before
forking" step as the DeepSeek review: yardstick and chat/tool gates on this box with the
project's own GGUF, so a base regression is caught before any fork work.

### 2. Add the early routing-locality probe

The whole estimate rests on 15–40% effective cache hits while only 5–6% of the pool fits
VRAM. That is testable cheaply, before the caching work exists: capture the selected-expert
histogram per layer for a few hundred tokens on code/prose/list prompts — in the official
PyTorch reference, or a bench-only llama.cpp build — and report the top-expert
concentration and the coverage achieved by 25–30 GiB of cache. If the concentration is
not there, step 5's optimization budget should be reconsidered before it is built. Put the
probe at the end of step 1 or the start of step 5, with the decision rule written first.

### 3. Typed config nits

Add to the strict `mimo2` descriptor: `layernorm_epsilon` 1e-5 (the plan says "plain
RMSNorm" only), `attention_chunk_size` 128 (relevant to prompt chunks and the SWA ring
rollover the plan already calls out), and the padded vocabulary (152576 declared vs the
tokenizer's valid IDs — the plan already requires distinguishing padded rows, so the
number belongs in the table). Everything else in the table matched the config.

### 4. Fork maintenance and upstream tracking

Same structure as the DeepSeek review, but with this fork's own evidence: the plan
already proposes `src/mimo/` modules and uses the Qwen3.6 driver as a donor, which is the
right shape (upstream engines per family; see `model_family.hpp`). Write down: base tag
frozen; a patch manifest; the must-take gfx1030 fixes (#2457, #884's
`STRATA_HIP_ADAPT_KERNEL_COPY=1`, #1103); the rebase cadence; and what could be offered
upstream. Do not inherit Qwen's worker counts — the plan already says this; keep it in
the launcher defaults too.

### 5. Lab integration and acceptance

The test-host script already knows `TEST_MODEL=mimo`, but only for the llama.cpp unit.
Add for the fork:

- a `strata-mimo` unit/env/launcher and extend `glm53-flash/ct123-test-host.sh`'s
  model/engine/unit sets so card ownership, CT 120 autostart, the watchdog map and the
  DRM cgroup rule stay coherent (`use-engine.sh` semantics);
- the sweeps and records: `strata-sweep.sh`/probes, `push-harness.sh`, `capture-env.sh`,
  and a record per TEST-RECORDS.md with environment.json;
- the same rollback guarantee as the plan already states: llama.cpp stays the
  operational reference and restoration target, one command back;
- the bench-runner client fixes already tracked as #112 if the usage test is run, and a
  Hermes-provider check before any deployment decision;
- `--memory-limit-mib` (or equivalent) aligned with CT 123's 488 GiB test limit at every
  launcher configuration.

### 6. Concurrency alignment

The plan gates one then two 32k slots, which is right. Add the decision on whether the
fork reuses v0.1.45's `--parallel`/batching and admission machinery or excludes it.
Upstream's own hybrid-mode numbers (slots cost 4–11% single-stream; concurrent gains
1.0–1.15x) argue for two slots as the target and no further investment until measured.

### 7. CI and the real test subset

A CPU-only GitHub Actions build plus fixture tests for the fork repo, and one documented
CT 123 command for the gfx1030 subset (WMMA, hipBLASLt, `ple_parity`, AVX-512 tests skip
there today). Record the numeric-tolerance registry the plan requires.

### 8. Risk register and the formal kill gate

The plan ends with the right decision rule — keep llama.cpp if caching cannot beat the
same-quant configuration. Promote it, plus the estimate's uncertainties, into a table:
routing locality; gfx1030 Q2_K/MXFP4 expert throughput; MTP acceptance on Q2_K (measured
on MXFP4 only so far); prefill transfer bandwidth; and note item 2's probe resolves the
first one early. Give each a measurement and a fallback.

### 9. Pin refresh at start

Because this fork runs second, its "Reviewed versions" section will be stale by then.
Make the first task a refresh of: fork base, llama.cpp reference (b11583 → current,
re-check that the mimo2 graph and MTP semantics did not change), MXFP4 revision, Q2_K
artifact revision and hash, and the ggml pin. Re-run the baseline measurements if the
reference build changes, since the estimates are anchored to b11583's numbers.

### 10. Keep the estimate's labels when citing it

`STRATA-PERFORMANCE-ESTIMATE.md` is careful to call its numbers conditional engineering
targets. Any test record or README that quotes them should carry the same framing, per
the lab's measurement-labelling convention.

## Settled

- **Storage:** owner-managed; no ledger. Keep the lab's pinned download + SHA-256
  verification pattern (`install.sh --download`, `.verified`).
- **DIMM thermal:** stress-test-only; no plan mitigation. The existing benchmark
  telemetry still samples DIMMs, so an anomaly would show up in the records without new
  gates.

## Suggested plan edits (checklist)

1. State the fork base and add the base-qualification step.
2. Add the routing-locality probe with a pre-declared decision rule.
3. Add `layernorm_epsilon`, `attention_chunk_size`, padded vocab to the descriptor.
4. Add the fork-maintenance section (base, patch manifest, must-take fixes, rebase
   cadence, upstreaming).
5. Add lab integration (test-host/engine switch, records, rollback, client fixes,
   memory limit).
6. Add the concurrency/batching decision.
7. Add CI and the documented CT 123 test subset; tolerance registry.
8. Add the risk table and promote the kill gate.
9. Add a "refresh pins first" note for the deferred start.
10. Cross-reference the estimate's confidence labels wherever the numbers are reused.
