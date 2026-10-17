# t2 — Reconciliation of the two fork-plan review sets

Review date: 2026-10-17. This record reconciles the two independent reviews of the Strata
fork plans (branch `marchah/strata-fork`, commit `523b893`, "Strata fork plan"):

- `t1-deepseek-v41-fork-review.md` / `t1-mimo-v26-pro-fork-review.md` — first reviewer.
- `t2-DEEPSEEK-V4.1-REVIEW.md` / `t2-MIMO-V2.6-REVIEW.md` — second reviewer.

It is the authoritative record where the sets disagree. The `t1-` files are kept as the
first reviewer wrote them; their corrections are carried here. The two merged amendment
lists at the end are the single checklist that lands as plan-doc edits, superseding both
sets' "accepted changes" lists.

The owner answered the two open conflicts on 2026-10-17 (both recorded below: MiMo's
status, and the DIMM-thermal decision).

## Owner decisions, reconciled (2026-10-17)

These supersede the decision blocks in all four review files where they differ.

- **Two separate forks, DeepSeek first.** No disagreement between the sets.
- **MiMo is the second fork, and its implementation is deferred.** Both earlier captures
  were each half-right: t1 recorded the sequencing ("MiMo is second", work starts after
  the DeepSeek fork's Q2 text release) but missed the deferral; t2 recorded the deferral
  ("doesn't seem usable with the current server configuration") but framed it as an
  open-ended hold. The owner's resolution: *it's a second fork but the MiMo fork is also
  deferred.* Consequence: the MiMo plan stays a deferral record with revival conditions;
  sequencing (after DeepSeek) and the pin-refresh-at-start rule from t1 both stand, and
  nothing is scheduled until the owner calls it.
- **Model-store capacity is owner-managed.** Both sets already agree: no capacity ledger
  or eviction plan is a deliverable; keep the lab's pinned-download + SHA-256
  verification pattern (`install.sh --download`, `.verified`).
- **DIMM throttling is not a plan risk — adopted as-is.** Owner decision: accept t1's
  wording exactly — it appeared only under synthetic stress tests, never in real
  workloads; the guard/watchdog remains the safety net; no plan mitigation and no new
  gates. The existing benchmark telemetry still samples DIMMs, so anomalies remain
  visible in the records.
- **Development and tests run in PVE on CT 123** (this session's decision, in both t2
  reviews).

## Verification coverage

What each record verified, and what the reconciliation pass checked:

| Claim class | t1 | t2 | Reconciliation pass |
| --- | --- | --- | --- |
| External anchor resolution (upstream commit `477ac13…`, antirez repo at `dd8a266…`, artifact sizes 340.60 / 482.98 GiB) | noted | fetched and confirmed | confirmed |
| Artifact arithmetic | asserted results ("checked against pinned sources") | full independent recomputation, both plans | agrees with t2 |
| Quoted lab records (`2026-10-16-strata.md`, `2026-10-15-baseline.md`) | spot-checked | all figures checked | agreed |
| DeepSeek `config.json` constants (revision `1bae0e10…`) | fetched: RoPE 10000 / compress 160000, YaRN 16 @ 65536, single compressed KV head, `swiglu_limit` 10.0, `hc_eps` 1e-6, Sinkhorn 20 iters, mHC 4, noise token 128799, Markov rank 256, two ~384M-row Engram tables (= 188.8 GiB, matches the plan's 188.83), pad id 2, compressed vocab 99092 | not fetched | re-fetched: every constant confirmed, including exact key names |
| MiMo `config.json` constants (revision `b61f2185…`) | fetched: eps 1e-5, `attention_chunk_size` 128, vocab 152576 padded, partial rotary 0.334 (= 64 dims at head width 192), `add_swa_attention_sink_bias` true / full false, value scale 0.612, dense layer 0, no shared expert | not fetched | re-fetched: all confirmed; the plan's table is exact |
| PR #1518 internals | quoted from the discussion: CUDA-only work, untested on HIP/Linux; targets V4 / IQ1_M; `dq_traits.hpp` helpers declared but never defined (real link failure); GPU batched-prefill parity fails at chunk ≥ 2 (≈ 0.26 logit delta) | not fetched | confirmed in the thread — and found the PR moved after the plan was written: force-pushed to `bd6fc62` on 2026-10-17 with a reworked batched-prefill implementation; the reviewed head `6e326aa` is stale |
| Publisher README (Engram strategy) | quoted: DwarfStar "reads the needed rows directly from disk; it never makes the whole table resident", recommends SSD streaming | repo existence, sizes, license only | quote confirmed |
| Upstream core headers (`geometry.hpp`, `family_layout.hpp`, `model_family.hpp`) | sampled re-read, findings consistent with the plan's P0 table | plan's own findings only | not re-verified here; nothing between the sets conflicts |
| Upstream hybrid slot costs | paraphrased inexact | not covered | `QWEN36.md`'s hybrid table: a lone request runs −3.5% to −12% with extra slots; together-gains 0.99–1.15x |
| CT 123 SMT topology | **wrong** (see corrections) | not covered | corrected from `ct123-test-host.sh` and the baseline record |

Net: no factual disagreement between the sets on plan content. Both approve the DeepSeek
fork as written; t1 called the MiMo plan "the strongest of the two" while agreeing with
t2's deferral outcome. Their differences are coverage gaps on each side, three correctable
t1 slips, and the decision-record drift resolved above.

## Corrections carried into the merged lists

1. **CT 123 SMT topology (fixes t1's "48 CPUs on 24 physical cores").** Per
   `glm53-flash/ct123-test-host.sh`, the 7532 is a **32-core** CPU where "CPU n and
   n+32 share one"; without `TEST_CPUSET`, Proxmox hands the container a random 48-of-64
   set that "can leave physical cores out: one start covered 30". The baseline record ran
   32 pinned threads one per core on 29.9–30.0 busy cores. t1's "24" evidently mixed the
   test cpuset with the deployed 24-vCPU configuration (which per `strata/README.md` sits
   on 21 cores, STREAM peaking at 16 threads). The recommendation t1 attached to it stands
   unchanged: measure the starting worker count on this box; do not inherit Qwen's tuning.
2. **Batch-cost citation (tightens t1's "4–11% slower / 1.0–1.15x").** Upstream's own
   hybrid table is the citation to use: a lone request runs ~3.5–12% slower with extra
   slots, and concurrent together-gains are 0.99–1.15x. Conclusion unchanged — the
   concurrency target is a deliberate choice, not a default.
3. **Test memory (prefers t2's mechanism over t1's pre-commit).** t1 wrote "the DeepSeek
   Q2 tests will run CT 123 at 488 GiB"; the plan text instead derives
   `TEST_MEMORY_MIB` from step 1's allocation ledger (provisional process budget
   384–416 GiB) and aligns the engine's `--memory-limit-mib` (118784 MiB today) with
   whatever the ledger yields. 488 GiB is an admissible provisioned limit, not a plan
   constant.
4. **PR #1518 is moving.** Add to the reuse cautions: re-check the PR head when step 1
   freezes pins; the reviewed head `6e326aa` was superseded on 2026-10-17.

## Merged amendment list — DeepSeek-V4.1-Flash

To land as edits to [pro-v620/strata/DEEPSEEK-V4.1-PLAN.md](pro-v620/strata/DEEPSEEK-V4.1-PLAN.md).
Tags show provenance: [t1-n] its item n, [t2-n] the second set's accepted change n,
[recon] a reconciliation addition.

1. **Header: fork topology and frozen base.** State the 2026-10-17 decision — a
   DeepSeek-only fork, separate from the deferred MiMo fork, first in sequence — and fix
   the base at v0.1.45 / `477ac13`, never tracking `main`. [t2-1 + t1-1]
2. **Fork-maintenance section.** Upstream's grain: new `ModelFamily::DeepSeekV41` plus a
   `src/deepseek/` engine path (the `src/qwen35` shape); prefer parameterization over
   replacement in `layer.cpp`/`session.cpp`; keep a patch manifest (touched files +
   reason); define the rebase cadence and who runs the gates; offer generic parts
   (family dispatch, session versioning, manifest format) upstream. [t1-1]
3. **Step 0 — qualify the base on this box.** Run the existing Flash-Next qualification
   (yardstick, chat/tool gates as in the 2026-10-16 record) against `477ac13` with
   UD-Q4_K_XL before forking; de-risks the base and may be a free upgrade for the
   deployed engine (0.1.44.1 → 0.1.45). [t1-1]
4. **Step 1: resolve the llama.cpp baseline question, and the stop rule with it.** Check
   whether llama.cpp supports `deepseek41` and the Engram row representation here; if
   yes, measure the same-quant baseline with the known context-accounting rule (Strata's
   context is per slot; llama.cpp's is shared); if no, say so and mirror the MiMo plan's
   kill condition — fixture-qualified correctness plus the owner's usable threshold
   decide the benchmark gate, with the deployed Flash-Next/llama.cpp services as the
   untouched restore target. [t2-2 + t1-9]
5. **Gate step 2 on a per-storage-type format × path matrix.** For IQ2_XXS (80), Q2_K
   (40), Q8_0 (321), F16/F32 (110/493) and I8 Engram rows (2): GGUF read, CPU
   dot/dequant, HIP on gfx1030, scratch fit vs 5120×2304, fallback. Known constraints to
   check: the MMVQ supported-type list, the CPU path that rejects activations wider than
   2560, `native_expert` scratch caps, no WMMA/hipBLASLt on gfx1030 (rocBLAS dense
   GEMMs). Exit: every type has a named working path and a bounded fallback
   (dequantize + BLAS), or the artifact is re-quantized. [t1-2]
6. **Config table: add the missing rows** (all verified against the fetched config):
   `rope_theta` 10000 / `compress_rope_theta` 160000, YaRN 16 @ 65536 above 64k, max
   position 1M; `num_key_value_heads` 1 (single compressed KV head); `attention_bias`
   false; `swiglu_limit` 10.0; `hc_eps` 1e-6; `hc_sinkhorn_iters` 20; DSpark noise token
   128799 and Markov rank 256; Engram tables ~384M rows × 2 (264 B/row → 188.83 GiB),
   `engram_pad_token_id` 2, compressed vocab 99092. [t1-3]
7. **PR #1518 reuse cautions + freshness check.** CUDA-only, untested on HIP/Linux;
   targets the older V4 / IQ1_M; `dq_traits.hpp` declared-but-never-defined link
   failure; prefill parity fails at chunk ≥ 2 (≈ 0.26 logit delta). Its prefill design
   (chunked prefill, ring-buffer snapshotting, strict summation order) is the reading
   material before step 4. Re-check the head at step 1 — it moved after this plan was
   written (see correction 4). [t1-4 + recon]
8. **CT 123 test setup: name the mechanics now, value from the ledger later.** A
   `TEST_MODEL`/`TEST_ENGINE` entry in `glm53-flash/ct123-test-host.sh` for the fork's
   service (unit name, `Conflicts=` list, watchdog map, DRM cgroup, `TEST_MEMORY_MIB`,
   and a host-margin rule like the MiMo record's minimum-MemFree), limit derived from
   step 1's ledger, and the engine's `--memory-limit-mib` aligned with the CT limit at
   every test configuration. [t2-3 + t1-5, per correction 3]
9. **Parameterize the shared switch scripts once** (`use-engine.sh`, `ct123-test-host.sh`):
   engine root and unit name as variables inside the fork's step 7, so the deferred MiMo
   fork reuses the plumbing. [t2-4 + t1-5]
10. **Carry the inherited gfx1030 inventory** into the campaign Safety section with a
    requalification list: `STRATA_HIP_ADAPT_KERNEL_COPY` (#884 verify hang),
    `STRATA_HIP_PROMPT_F16`/`STRATA_SH_STREAM` (+9.7% decode, +79–91% prefill),
    `STRATA_MMQ_KQ`, #2457's RDNA2 output-corruption class, #1103's ROCm pin, hipBLASLt
    shipping no gfx1030 kernels, and `pro-v620/amdgpu-lockup-timeout.sh`'s 10 s
    compute-job timeout — plus the thermal guard, residency samplers,
    `vram-release-trace` and `capture-env`. [t2-5; t1-1's must-take list folds in]
11. **Dev loop pinned to CT 123 (owner decision).** Builds under a fork-specific root
    (e.g. `/opt/strata-ds41/`, excludable as rebuildable bulk by the weekly backup); CPU
    fixtures in-container (AVX2 cannot run on the macOS authoring machine); HIP tests
    only while neither card serves a model. [t2-6]
12. **CI and the real test subset.** A GitHub Actions job for the CPU-only build plus
    fixture/oracle tests on every change; one documented CT 123 command for the gfx1030
    subset (WMMA, hipBLASLt, `ple_parity`, AVX-512 skips there; include the new scratch
    paths and memory-sanitizer runs); and a numeric-tolerance registry (where tolerances
    live, how they were derived). [t1-8]
13. **CPU worker tuning — with the corrected topology.** The plan says nothing about
    worker count or affinity. The test configuration spans the host's 32 physical cores
    (pairs n/n+32; ~30+ cores available when pinned deliberately; the baseline's 32
    threads ran on 29.9–30.0 busy cores), while the deployed 24-vCPU config shows STREAM
    peaking at 16 threads. Set the starting worker count from a measurement; do not
    inherit Qwen's; pin CPUs per the cpuset discipline in `ct123-test-host.sh`. [t1-6,
    corrected — see correction 1]
14. **Concurrency target: state it.** Initial scope one request at 4K–8K. Add the
    eventual service target (one or two slots) and whether the fork reuses v0.1.45's
    `--parallel`/batching and admission machinery or excludes it — a deliberate choice,
    not a default (upstream's hybrid table: lone ~3.5–12% slower, together-gains
    0.99–1.15x). DeepSeek's shared KV/index state may make slot batching differ again.
    [t1-7, per correction 2]
15. **Engram strategy: state the deviation + schedule the early benchmark.** The
    publisher's reference never makes the Engram table resident and recommends SSD
    streaming; this plan deliberately keeps it in RAM for Q2. State that tradeoff, and
    benchmark row-read latency early so Q4's SSD-backed option is not first exercised at
    project's end. Keep `engram_pad_token_id` and the compressed-vocab mapping in the
    manifest identity. [t1-10]
16. **Q2-release compatibility statement.** The initial release runs exact
    full-forward prefill only; SWA bounded replay (optional step 8) is approximate per
    the technical report, and its acceptance is a separate decision with cache-identity
    implications. [t2-7]
17. **Repo bookkeeping in step 7.** Updating the root README inventory and CLAUDE.md
    "Where to look" when a service is installed is this repository's convention; name it
    in the packaging step. [t2-8]
18. **Campaign record requirements.** Per TEST-RECORDS: standard arms are two GPUs /
    one GPU / CPU-only, with any omission explained (CPU-only likely is); the drafter
    rule — DSpark exists for this model, so the record must say why it is deferred and
    quote the no-draft control; start with one card and add the two-card split as the
    plan proposes. [t1-11]
19. **Risk register with stop conditions.** Turn the prose uncertainties into
    unknown → measurement → fallback → stop condition: gfx1030 expert throughput at
    5120×2304; host bandwidth and CPU/GPU overlap; GPU cache hit rate; cross-card shared
    attention state; Engram random-read latency. The kill condition itself is item 4.
    [t1-9]

## Merged amendment list — MiMo-V2.6-Pro-RL

To land as edits to
[pro-v620/mimo-v26-pro/STRATA-REFACTOR-PLAN.md](pro-v620/mimo-v26-pro/STRATA-REFACTOR-PLAN.md)
(and the performance estimate where noted), under the reconciled status: **second fork
in sequence, implementation deferred.**

1. **Status line in the plan header.** Second fork (after the DeepSeek fork's sequence),
   implementation deferred on 2026-10-17; revived only on the owner's call or the
   revival conditions in [t2-MIMO-V2.6-REVIEW.md](t2-MIMO-V2.6-REVIEW.md); this
   reconciliation file is the decision record. [recon — resolves the t1/t2 drift]
2. **Pin refresh as the first task on revival.** The "Reviewed versions" section will be
   stale: re-baseline the fork base (post-v0.1.45), the llama.cpp reference build
   (b11583 → current; re-check the mimo2 graph and MTP semantics), MXFP4 revision
   `5f387f52`, the Q2_K artifact revision + hash, and the ggml pin; re-run baseline
   measurements if the reference build changed, since the estimates anchor to b11583's
   numbers. [t1-9]
3. **Base qualification at start.** Yardstick and chat/tool gates on this box with the
   project's own GGUF before any fork work, catching base regressions early. [t1-1]
4. **Fork-maintenance section.** Base tag frozen; patch manifest; must-take gfx1030
   fixes (#2457, #884's `STRATA_HIP_ADAPT_KERNEL_COPY=1`, #1103); rebase cadence; what
   could be offered upstream (the `src/mimo/` + Qwen3.6-donor shape matches upstream's
   per-family engines); do not inherit Qwen's worker defaults in the launcher. [t1-4]
5. **Early routing-locality probe, with the decision rule written first.** The estimate
   rests on 15–40% effective cache hits while only 5–6% of the pool fits VRAM — testable
   cheaply before the caching work exists: capture the selected-expert histogram per
   layer for a few hundred tokens on code/prose/list prompts (official PyTorch reference
   or a bench-only llama.cpp build), report top-expert concentration and the coverage
   that 25–30 GiB of cache achieves. If the concentration is not there, reconsider
   step 5's optimization budget before it is built. Place at the end of step 1 or the
   start of step 5. [t1-2 — the strongest single addition in either set]
6. **Calibrate the sensitivity model with the local anchors** so `s`, cache-transfer and
   MTP terms stop being free parameters: the measured 6.8 GiB/s op-offload copy band
   bounds GPU-cache refresh, the 30-core no-spec decode profile is the reference for
   host expert service, and the acceptance-vs-depth curve (90/86/79% at d0 → 59% median
   at d8000) grounds `m`. [t2-2]
7. **Make step 2 state the MXFP4 shipment explicitly.** The Q2_K development quant keeps
   MXFP4 down projections, so the Q2_K milestone has no value without the MXFP4 expert
   kernels; the step-2 text can otherwise be read as if it could ship alone. [t2-3]
8. **Typed descriptor nits** (config-verified): `layernorm_epsilon` 1e-5 (the plan says
   "plain RMSNorm" only), `attention_chunk_size` 128 (prompt chunks and the SWA ring
   rollover the plan already calls out), and the padded vocabulary 152576 in the table.
   [t1-3]
9. **Keep the Q2_K same-quant llama.cpp baseline measurement** the plan already requires
   (the MXFP4 times are not a same-quant comparison), with the known context-accounting
   rule: Strata's context is per slot; llama.cpp's is shared. [t2-4]
10. **Lab integration.** A `strata-mimo` unit/env/launcher; extend
    `glm53-flash/ct123-test-host.sh`'s model/engine/unit sets so card ownership, CT 120
    autostart, the watchdog map and the DRM cgroup stay coherent (`use-engine.sh`
    semantics, adopted from the DeepSeek fork's step 7 rather than a second bespoke
    extension); `strata-sweep.sh`/probes, `push-harness.sh`, `capture-env.sh`, records
    per TEST-RECORDS with environment.json; the rollback guarantee (llama.cpp stays the
    operational reference, one command back); the bench-runner client fixes tracked as
    #112 if the usage test runs, and a Hermes-provider check before any deployment
    decision; `--memory-limit-mib` aligned with the CT limit at every launcher
    configuration. [t1-5 + t2-1]
11. **Concurrency decision.** Gate one then two 32k slots (already right); add whether
    the fork reuses v0.1.45's `--parallel`/batching admission machinery or excludes it —
    upstream's hybrid table (lone ~3.5–12% slower, together-gains 0.99–1.15x) argues two
    slots as the target and no further investment until measured. [t1-6, per correction 2]
12. **CI and the real test subset.** CPU-only GitHub Actions build plus fixture tests for
    the fork repo; one documented CT 123 command for the gfx1030 subset; record the
    numeric-tolerance registry. [t1-7]
13. **Dev loop in CT 123** (owner decision): fork-specific build root on the container;
    CPU fixtures in-container (AVX2, not the macOS authoring machine); HIP tests only
    with both cards free; memory lifted only for full-model loads. [t2-5]
14. **gfx1030 requalification list** as on the DeepSeek review: the `STRATA_*` switches,
    #884/#2457/#1103, rocBLAS-only dense GEMMs, the 10 s compute-job timeout — into the
    campaign Safety sections. [t2-6]
15. **Risk register + promoted kill gate.** Table: routing locality (item 5's probe
    resolves it early), gfx1030 Q2_K/MXFP4 expert throughput, MTP acceptance on Q2_K
    (measured on MXFP4 only so far), prefill transfer bandwidth — each with a
    measurement and a fallback; promote the existing end rule (keep llama.cpp if caching
    cannot beat the same-quant configuration) into it explicitly. [t1-8]
16. **Citation convention for the estimate.** `STRATA-PERFORMANCE-ESTIMATE.md` labels
    its numbers conditional engineering targets; any record or README quoting them
    carries the same framing. [t1-10]

## What each set contributes that the other lacks

- **t1-only:** step-0 base qualification; the routing-locality probe; the per-type
  format × path matrix; PR #1518 failure specifics; the Engram deviation statement;
  config-table rows (all since verified); CI design; campaign-arm and drafter rules;
  the patch-manifest/rebase-cadence maintenance section; the checklist-per-review
  format that makes edits landable.
- **t2-only:** the full arithmetic recomputation tables (both plans, every figure);
  the decision-record discipline (decision blocks date-stamped, deferral documented,
  revival conditions enumerated); the ledger-derived test-memory mechanism; the fork-topology header line; the DeepSeek repo-bookkeeping and SWA-release items; the
  script-parameterization rule tied to the MiMo fork's future reuse.
- **Reconciliation pass only:** the PR #1518 force-push observation; the SMT-topology
  correction; the exact hybrid slot-cost table; the resolved MiMo status (second AND
  deferred) and the DIMM decision adopted as-is.

## After the facts are in: what to consult which file for

- **Arithmetic proof** — the t2 reviews (recomputation tables; both plans' figures hold).
- **Upstream/config code-level verification** — the t1 reviews (configs, PR internals,
  publisher guidance), now confirmed by this reconciliation.
- **Decisions and the landing checklist** — this file. When the plan-doc edits are
  applied, they should cite this reconciliation for the MiMo status line and the DIMM
  decision.
