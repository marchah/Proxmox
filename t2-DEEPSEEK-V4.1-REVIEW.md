# Review: DeepSeek-V4.1-Flash Strata fork plan

Review date: 2026-10-17. Review of [DEEPSEEK-V4.1-PLAN.md](pro-v620/strata/DEEPSEEK-V4.1-PLAN.md) on branch
`marchah/strata-fork`, commit `523b893` ("Strata fork plan"). That commit adds the plan
document only: no engine changes, downloads or runs were made. This record reviews the
plan itself — its pins, arithmetic, quoted measurements and scope — and records the owner
decisions taken with it.

## Verdict

Approve as the first of the two planned Strata forks. The plan's load-bearing external
anchors resolve, its arithmetic reproduces from first principles, and the lab data it cites
matches the records in this repository. Its scope (the DwarfStar-published Q2 artifact,
same-quant correctness as the bring-up gate, DSpark/vision/long context deferred) is the
right shape for this machine. The gaps below are process-level, not technical: one
unresolved baseline question, lab-integration items to name before the first campaign, and
the inherited gfx1030 workaround inventory.

## Owner decisions recorded with this review (2026-10-17)

- Two forks come from this branch's analysis, not one. DeepSeek first.
- The MiMo fork plan is deferred; see
  [the MiMo review](t2-MIMO-V2.6-REVIEW.md). Its estimates project a lower
  ceiling and floor than this fork's, and its fit leaves too little usable headroom on the
  current server configuration.
- The model-store capacity question is skipped: the owner makes space on `models` as
  needed. A `df -h /mnt/models` before the Q2 download remains cheap practice, not a gate.
- Development and tests run in PVE on CT 123.

## What the review checked

### External anchors

Fetched and confirmed:

- Upstream `Niko1221/Strata` resolves at the reviewed commit `477ac13cbe8e582c20484871ce459d20d82df09d`.
  The repository state matches the plan's description: Qwen3.8-Flash-Next as the shipped
  model, the release page, and a 2,438-commit history at that ref.
- [antirez/deepseek-v4.1-flash-gguf](https://huggingface.co/antirez/deepseek-v4.1-flash-gguf)
  resolves at revision `dd8a266f7145edc19e2334b46e19b6821f221dc7` with exactly the artifacts
  the plan sizes: `DeepSeek-V4.1-Flash-Q2.gguf` at 366 GB (decimal) — the plan's
  340.60 GiB in binary units — and the Q4 as two transport parts of 480 + 38.6 GB, which is
  518.6 GB decimal and matches the plan's 482.98 GiB. A vision GGUF (971 MB) exists and is
  correctly outside the plan's scope. The LICENSE file carries the upstream DeepSeek MIT
  license, as the plan requires.

Not fetched during this review, to be resolve-checked when step 1 freezes the pins: PR
#1518, issue #479, the Lucebox V4.1 guide, `deepseek-recipe`, the `1017` revision, and the
pinned checkpoint/config links. The plan's own header range-read of the Q2 (1,046 tensors;
80 IQ2_XXS, 40 Q2_K, 321 Q8_0, 110 F16, 493 F32, two I8) is the plan's work and stands as
its own step-1 gate; its tensor counts sum to 1,046.

### Arithmetic

Recomputed independently from the model contract the plan states:

| Claim in the plan | Recomputed | Holds |
| --- | --- | --- |
| Selected routed-expert traffic 2.39 GB/token (Q2), 4.78 GB/token (Q4) | 6 experts × 40 layers × 3 × 5120 × 2304 weights × 2.25 / 4.5 bits → 2.389 / 4.777 GB | yes |
| Anchor scaling 37.3 t/s × 1.50 GB ÷ 2.39 → 23.4 t/s (Q2), 11.7 (Q4) | — | yes |
| Q2 sizes 142.38 / 151.77 / 188.83 / 340.60 GiB | 151.77 + 188.83 = 340.60; Q4 experts 284.77 = 2 × 142.38 | yes |
| Engram row 264 bytes = 256 e4m3 values + 8 scales | 256 + 8 | yes |
| 43-entry compression array = 40 backbone entries + 3 draft layers | — | coherent with the stated DSpark contract |

The traffic-based estimates (15–30 t/s Q2, 10–20 t/s Q4) are labelled conditional and stay
so; the anchor above only shows the floor arithmetic is honest, which it is.

### Quoted lab data

All match the records they cite, in
[`qwen38-flash-next/runs/2026-10-16-strata.md`](pro-v620/qwen38-flash-next/runs/2026-10-16-strata.md):

- Stage 7: no-draft 32.8 t/s (one card) / 37.3 t/s (two cards, +13.7% under the 15% rule);
  MTP 49.2 / 59.7 (+51% / +60%).
- Stage 8: llama.cpp 18.2 t/s one-card median decode; prefill 989 / 964 (d8000) and
  1,008 / 1,423 (d32000); first-token 5.9–6.0 s and 16.3–22.9 s.
- The ×2.70 / ×3.27 headline ratios and their non-overlapping ranges.

The plan correctly carries the repo's measurement caveats: stage 8 is single-stream,
MTP-acceptance at two slots is unmeasured, and the d8000/d32000 workload labels do not
equate to literal prompt lengths.

## Gaps and committed changes

The owner accepted the following improvements, to land as plan-doc edits:

1. **Fork topology line in the plan header.** State the 2026-10-17 decision: a DeepSeek-only
   fork, separate from the deferred MiMo fork, first in sequence. This stops later readers
   inferring a combined engine and pins the branch's intent to the review date.

2. **Resolve the llama.cpp baseline question at step 1.** The plan compares every milestone
   against a same-quant oracle, but never states whether llama.cpp supports `deepseek41`
   and the Engram row representation on this box. The antirez artifacts target DwarfStar
   and Metal, so it is currently unknown. Fold into step 1 ("Freeze references"): check
   llama.cpp `deepseek41`/Engram support and, if present, measure a same-quant baseline —
   adopting the known context rule for such comparisons (Strata's context is per slot;
   llama.cpp's is shared across slots). If absent, say so in the plan and mirror the MiMo
   plan's deploy/stop rule: since the fork would be the only runtime for this quant, its
   benchmark decision gate becomes fixture-qualified correctness plus the owner's usable
   threshold, with the deployed Flash-Next/llama.cpp services untouched as the restore
   target.

3. **Name the CT 123 test setup now, value it from the ledger later.** "Current 120 GiB
   limit must be increased" needs a mechanism: a `TEST_MODEL`/`TEST_ENGINE` entry in
   `glm53-flash/ct123-test-host.sh` for the fork's service (unit name, `Conflicts=` list,
   watchdog map, `TEST_MEMORY_MIB`, and a host-margin rule like the MiMo record's
   minimum-MemFree), with the actual limit derived from step 1's allocation ledger instead
   of pre-committed in the plan. The provisional 384–416 GiB process budget bounds where
   that number can land.

4. **Parameterize the shared switch scripts once.** `use-engine.sh` is hard-pinned to the
   v0.1.44.1 install path and `ct123-test-host.sh` enumerates models and engines. Change
   both to take the engine root and unit name as variables inside the fork's step 7, so the
   deferred MiMo fork reuses the same plumbing instead of duplicating it.

5. **Carry the inherited gfx1030 inventory.** The plan cites "existing harnesses" and
   inherits the ROCm 10.0 environment, but never lists what this lab needed before on
   gfx1030 and what the fork's new kernels must requalify: `STRATA_HIP_ADAPT_KERNEL_COPY`
   (#884 verify hang), `STRATA_HIP_PROMPT_F16`/`STRATA_SH_STREAM` (+9.7% decode, +79–91%
   prefill on Flash-Next), `STRATA_MMQ_KQ`, #2457's RDNA2 output-corruption class, #1103's
   ROCm pin, hipBLASLt shipping no gfx1030 kernels (rocBLAS dense GEMMs), and
   `pro-v620/amdgpu-lockup-timeout.sh`'s 10 s compute-job timeout. Add an "inherited
   gfx1030 switches to requalify" list and put the timeout, thermal guard, residency
   samplers, `vram-release-trace` and `capture-env` into the campaign Safety section.

6. **Pin the dev loop to CT 123 (owner decision).** Builds under a fork-specific root
   (e.g. `/opt/strata-ds41/`), which the weekly backup may exclude as rebuildable bulk;
   CPU fixtures run in-container, since the AVX2 CPU traits cannot run on the macOS
   authoring machine; HIP tests run only when neither card is serving a model, as
   [pro-v620/strata/README.md](pro-v620/strata/README.md) already prescribes for its own
   validation.

7. **Q2-release compatibility statement.** Record explicitly that the initial release runs
   exact full-forward prefill only; SWA bounded replay (optional step 8) is approximate per
   the technical report and its acceptance is a separate decision with cache identity
   implications — the plan's optional section already covers the risk, the release statement
   makes it visible.

8. **Repo bookkeeping in step 7.** Updating the root README inventory and CLAUDE.md
   "Where to look" when a service is installed is this repository's convention; name it in
   the packaging step so it is not improvised.

## Not carried (owner decisions)

- A model-store capacity plan and `df` gate: skipped. Space will be made when the Q2
  artifact is downloaded.
- The estimate-calibration work identified for the MiMo review applies to MiMo's document,
  not this one; this plan's anchors already come from same-hardware measurements.

## Follow-ups at implementation start

- Resolve-check the unverified links listed above when pins freeze (step 1).
- Commit the step-1 campaign record (tensor ledger + oracle fixtures) as its own
  [TEST-RECORDS.md](pro-v620/TEST-RECORDS.md) entry before any run, per house rules.
- Land the accepted changes 1–8 as edits to [DEEPSEEK-V4.1-PLAN.md](pro-v620/strata/DEEPSEEK-V4.1-PLAN.md).
