# Strata → MiMo-V2.6-Pro-RL: fork implementation plan

Plan finalized 2026-10-17. **Second, separate fork after DeepSeek; implementation deferred.**
Completing DeepSeek does not automatically start MiMo. The owner must reopen it, with the
pre-start checks below completed before backend implementation.
This remains a source review and implementation plan; no engine changes, model runs or
service changes were made.

When resumed, make a MiMo-only fork of Strata, reuse its serving and CPU/GPU scheduling
infrastructure, and replace the model execution path. Dropping Qwen compatibility simplifies
the build and removes substantial model-specific state, but this remains a new model backend,
not a configuration change. Establish correct execution on a smaller quant, then optimize it
and qualify the intended four-bit model.

The owner confirmed the initial scope: this server only, smaller quantization for development,
and approximately four-bit weights as the eventual target. Use Linux, ROCm 10.0, the EPYC
7532's AVX2 CPU path, and two Radeon Pro V620s (gfx1030) in CT 123, with 503.6 GiB host RAM.
Start with ggml-org's approximately 390 GiB Q2_K build. Its gate/up experts are Q2_K and its
down experts remain MXFP4. The existing approximately 516 GiB MXFP4 build is the four-bit
target: MXFP4 already stores four-bit values, with block scales. Do not substitute the much
larger Q4_K_M build merely because its filename says Q4.

Implement only the tensor formats in those two manifests and the selected Q8_0 MTP sidecar;
the expected initial set is Q2_K, MXFP4, Q8_0 and F32, finalized by the inventory. No general
quantization catalog, native HF FP8 loader, NVFP4, IQ formats or other checkpoint support is
required. Quantization's effect on model quality is outside this development phase; execution
must still match a reference using the same quant. Deliver text and tools first. Images,
audio, video, DFlash, other operating systems and CUDA are later work. Keep a small device
boundary where useful for future CUDA, without implementing or testing it now. The model's
native 1M context is metadata, not the initial operating target.

## Reviewed versions and references

These are historical review pins, not moving defaults. At implementation start, resolve
and freeze a qualified Strata release/commit, ggml, ROCm/compiler inputs, llama.cpp's
`mimo2` graph and MTP semantics, model/tokenizer assets, the MXFP4 revision, Q2_K shard set
and Q8_0 MTP sidecar with SHA-256 hashes. A newer release is a candidate, not a requirement
or automatic upgrade. Re-run baselines when the reference build or artifacts change.

- [Strata source](https://github.com/Niko1221/Strata/tree/477ac13cbe8e582c20484871ce459d20d82df09d),
  commit `477ac13cbe8e582c20484871ce459d20d82df09d`, dated 2026-10-16. This is newer than
  this lab's installed `v0.1.44.1` / `296b59d2f73c8f04a805df29c2fa97655adace78`.
- [Reviewed release v0.1.45](https://github.com/Niko1221/Strata/releases/tag/v0.1.45),
  published 2026-10-17 at 06:53 UTC, checked during the follow-up review. Performance
  evidence and conditional estimates are included below.
- Strata's ggml pin is `3cf03257f219afbe7334045ff7c6a06ac68c627d`, in both `setup.py`
  and `CMakeLists.txt`.
- [MiMo configuration](https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Pro-RL/blob/b61f21852680ee02a29e946e18cf8697f4844061/config.json),
  [reference model implementation](https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Pro-RL/blob/b61f21852680ee02a29e946e18cf8697f4844061/modeling_mimo_v2.py),
  [tokenizer](https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Pro-RL/blob/b61f21852680ee02a29e946e18cf8697f4844061/tokenizer.json)
  and [chat template](https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Pro-RL/blob/b61f21852680ee02a29e946e18cf8697f4844061/chat_template.jinja).
- [ggml-org GGUF revision](https://huggingface.co/ggml-org/MiMo-V2.6-Pro-RL-GGUF/tree/5f387f5260fc110678396a3076a140c469b41eaa),
  already used by this lab for MXFP4. Confirm whether the smaller Q2_K shard set is present
  at this revision; otherwise pin its own revision explicitly. Inventory it first; later
  use the seven MXFP4 trunk shards, whose first shard is metadata-only.
- [llama.cpp b11583 MiMo graph](https://github.com/ggml-org/llama.cpp/blob/b11583/src/models/mimo2.cpp)
  is the reviewed execution reference for these GGUFs. Preserve b11583 as the historical
  comparison for the [existing measurements](runs/2026-10-15-baseline.md); record the resolved commit and
  binary hash when preparing the implementation fixtures.

## Deferral and pre-start checks

The central four-bit estimate is about 9.2 t/s with unmeasured locality/host-service gains;
cold 8K prefill is still estimated at roughly 67–133 seconds. Throughput and latency drive
the deferral. The approximately 390 GiB Q2_K artifact already removes much of the development
fit pressure (about 98 GiB below the prior CT limit before runtime allocations); MXFP4's
near-capacity fit is a separate later constraint. Neither estimate is a floor or ceiling.

Reconsider after DeepSeek supplies reusable fixtures/plumbing, improved upstream MiMo
scheduling, or changed GPU/host-memory capacity. These are reasons to re-estimate, not
automatic restart conditions. On the owner's decision to resume, refresh the pins, qualify
the base, measure the same-quant baseline and run the routing probe below before committing
to the cache implementation. Model-store capacity remains owner-managed; retain pinned
downloads and SHA-256 verification, without an eviction/capacity-planning deliverable.

## Fork maintenance and development

Freeze the selected base; do not follow `main`. Use the existing family dispatch with a
MiMo family entry and `src/mimo/` modules, with the Qwen3.6 driver as a donor. Keep shared
changes narrow and record base/dependency pins, touched upstream files and reasons in
`docs/FORK-PATCHES.md` in the fork. The implementer reviews each upstream release touching
HIP, kernels, memory or serving and every release candidate; port relevant correctness and
security fixes promptly. Rebase only as a separate qualified change with CPU, gfx1030 and
service gates rerun. Offer generic loader/session/dispatch improvements upstream. Reuse
DeepSeek's maintenance and lab tooling, while keeping the model backend in its own fork.

Build under `/opt/strata-mimo/` in CT 123; run AVX2 fixtures there, not on the macOS authoring
machine. HIP tests require both cards free of serving processes. Lift the CT memory limit
only for full-model work, based on the new peak ledger; the 488 GiB baseline is a reference,
not permission to omit runtime/host reserves. Never inherit Qwen's worker count: use the
actual 32-core / 64-thread topology, explicit `TEST_CPUSET` (siblings n/n+32), and a measured
worker/affinity sweep. The baseline's 32 pinned workers used about 30 cores.

Add an AVX2 x86-64 CPU-only GitHub Actions build and small deterministic fixtures on every
change. Provide a documented `tools/mimo/validate-gfx1030.sh` entry point for CT 123 with
device checks, required operator/loader/prefill/session/MTP fixtures and guarded scratch
tests; use address/undefined-behavior sanitizers on CPU scratch paths. Document inherited
WMMA/hipBLASLt/AVX-512 skips and remove PLE tests with PLE. Required MiMo tests cannot
silently skip. Store fixture provenance, reference repeatability, CPU/GPU deltas and
predeclared metric/tolerance values in `tests/mimo/tolerances.json` and its README. These
are proposed fork files; no CI or hardware validation was run for this documentation change.

## Findings that determine the design

**1. Both existing model paths reject MiMo's geometry.**

[ModelGeometry](https://github.com/Niko1221/Strata/blob/477ac13cbe8e582c20484871ce459d20d82df09d/include/strata/core/geometry.hpp)
defaults to Flash-Next's 2,560-wide, 48-layer model. The
[family layout](https://github.com/Niko1221/Strata/blob/477ac13cbe8e582c20484871ce459d20d82df09d/include/strata/core/family_layout.hpp)
requires equal key/value head widths, a periodic GDN/attention split, and shared-expert
tensors. Many kernels additionally compile dimensions into their implementation.

| Property | Flash-Next path | MiMo target |
| --- | --- | --- |
| Hidden width / trunk layers | 2,560 / 48 | 6,144 / 70 |
| MiMo descriptor constants | Model-specific | `layernorm_epsilon=1e-5`; `attention_chunk_size=128`; padded vocabulary 152576, distinct from valid tokenizer IDs |
| Attention | 36 GDN layers + 12 QSA layers | 60 sliding-window + 10 global layers |
| Global layer indices | Periodic QSA selection | 0, 7, 15, 23, 31, 39, 47, 55, 62, 69 |
| Query / KV heads | 24 / 2 | 128 / 8 |
| Key / value head width | 256 / 256 | 192 / 128 |
| Residual path | Hyper-connections | Ordinary pre-norm residual additions |
| FFN | MoE plus shared expert on every layer | Dense layer 0; routed MoE on layers 1–69; no shared expert |
| Experts / selected / expert width | 512 / 10 / 640 | 384 / 8 / 2,048 |
| Routing | Softmax | Sigmoid, correction bias for selection, normalized selected scores |

The newer [Qwen3.6 driver](https://github.com/Niko1221/Strata/blob/477ac13cbe8e582c20484871ce459d20d82df09d/src/qwen35/q36_engine.cu)
already has plain residual layers, direct GGUF loading, the server protocol and a CPU/GPU
expert split. It is a useful donor. Its GDN, 256-wide attention, shared expert, single-GPU
placement and all-experts-in-RAM assumptions still need replacing. Do not copy its entire
driver and treat the remaining work as changing constants.

**2. Attention needs an exact implementation, including the less visible operations.**

MiMo needs fused QKV unpacking with unequal K/V widths, 64 rotated dimensions, per-layer
RoPE bases (global 10,000,000; SWA 10,000), causal sliding-window masking, learned attention
sinks on SWA layers and the 0.612 attention-value/output scale. The sink contributes to the
softmax denominator without contributing a value vector. It is not a retained prefix token.

Replace QSA/indexer and GDN paths with explicit global/SWA layer descriptors. Match the
GGUF graph's tensor layout and operations, checking against Xiaomi's reference where needed.
Use separate key and value strides throughout allocation, attention, session copying and
speculative verification. A ring containing 128 tokens needs additional handling for prompt
chunks and draft rollback so new writes cannot destroy keys still needed by earlier queries.

**3. MiMo routing cannot use Strata's existing top-k router.**

The [native router](https://github.com/Niko1221/Strata/blob/477ac13cbe8e582c20484871ce459d20d82df09d/src/kernels/cuda/native_router.cu)
supports only `(512, 10)` and `(256, 8)` with softmax semantics. For MiMo, compute FP32 router
logits from the loaded router weights; apply sigmoid; select eight experts using score plus
`ffn_exp_probs_b.bias`; gather the original sigmoid scores and normalize those. The correction
bias must not enter the final mixture weights. The configured group count is one and the
routed scaling factor resolves to one. Define deterministic tie handling against the chosen
GGUF reference. Keep all eight contributions; disable route-tail skipping and resident-biased
substitution.

**4. Recognizing MXFP4 in a GGUF header does not provide GPU execution.**

The reader understands type 39 and its 17-byte/32-value blocks, but
[native GPU MMVQ](https://github.com/Niko1221/Strata/blob/477ac13cbe8e582c20484871ce459d20d82df09d/src/kernels/cuda/native_mmvq.cu#L2790)
does not support that type. Native MXFP4 expert decode and prompt multiplication need a
working path on gfx1030. MXFP4 and NVFP4 have different layouts and scaling; the existing
NVFP4 implementation is not a format alias. The chosen smaller quant also needs a Q2_K
gate/up path: type 10 is absent from the same native GPU MMVQ support list. Reuse the pinned
ggml CPU traits and implement bounded HIP paths for these two formats only.

The pinned [ggml CPU traits](https://github.com/ggml-org/llama.cpp/blob/3cf03257f219afbe7334045ff7c6a06ac68c627d/ggml/src/ggml-cpu/ggml-cpu.c#L287)
already include `ggml_vec_dot_mxfp4_q8_0`, providing a CPU starting point. However,
`native_expert.hpp` caps quantized activation scratch at 4,096/1,024 bytes, while MiMo needs
6,528/2,176 bytes with Q8_0 activations (Q2_K gate/up instead needs 7,008 bytes of Q8_K
activation scratch). `expert.hpp` and `pool.hpp` also contain 640-wide FFN
and 2,560-wide activation arrays. Resize or allocate all worker scratch from geometry, not
just the two byte limits. Use the CPU's supported ISA; this host does not require an AVX-512
implementation to get started.

**5. Use the smaller quant to separate engine development from four-bit memory fit.**

The approximately 390 GiB Q2_K build has approximately 368.7 GiB of routed experts. At
the baseline CT limit of 488 GiB, it leaves about 98 GiB even if all model weights were
held in RAM, before runtime allocations; dense weights on the GPUs free additional RAM.
Start with all CPU experts in ordinary anonymous RAM and a duplicate adaptive GPU cache.
Retain explicit limits, but defer exclusive ownership and near-capacity loading work until
the four-bit milestone. This smaller model still exceeds the observed GTT pinning budget,
so only bounded staging and activation/result buffers should be HIP-pinned.

For the later four-bit milestone, the stored MXFP4 geometry is:

```
one expert = 3 × 6144 × 2048 × 17/32 = 20,054,016 bytes = 19.125 MiB
all routed experts = 69 × 384 × 19.125 MiB = 494.859 GiB
one complete expert layer = 7.172 GiB
```

The lab's full trunk is about 516.2 GiB, of which 21.3 GiB is non-expert weights. Retaining
every expert in RAM and duplicating a subset in VRAM cannot fit CT 123's 488 GiB limit.
Pinning nearly 495 GiB also exceeds the approximately 251.8 GiB amdgpu GTT limit observed
in the llama.cpp tests. HIP registration behavior must be measured separately; do not assume
that changing APIs removes the budget problem.

The Qwen3.6 driver tries `cudaHostAlloc` for every expert, then falls back to `malloc`, while
keeping GPU copies. The main path has a more useful starting point:
`FileExpertSource::pin_cache_complement` excludes GPU-owned experts and supports bounded
staging/direct reads. Its interfaces and policy need adaptation; neither existing path is
ready for MiMo unchanged.

When moving to MXFP4, use two explicit ownership classes initially:

- A fixed set of experts lives only on its owning GPU. Start with three complete expert
  layers, following the no-speculation fit record: about 473.3 GiB of remaining experts in
  RAM and 41.9 GiB of weights on the two cards, with the embedding in RAM.
- The remaining experts live in anonymous, unregistered RAM. A later adaptive GPU cache
  may duplicate these within the remaining VRAM budget. Fixed GPU-owned experts cannot be
  evicted or lent to prefill buffers.

This avoids needing a moving, exclusive RAM/GPU cache in the first implementation. Later,
profile-selected permanent experts can replace whole permanent layers at startup. A fully
exclusive adaptive cache would need bounded GPU-to-RAM eviction before replacement; it is
not required initially.

Load in bounded chunks, release source page-cache pages or use the existing direct-read
facilities, and avoid a second full model copy. Account for peak startup memory, not just
steady state. Keep only staging and activation/result buffers HIP-pinned. Do not inherit
Qwen3.6's two full expert-layer staging buffers: those alone would consume about 14.3 GiB
for MiMo. Stage groups of experts or matrix tiles within an explicit budget instead.

At F16, the ten global layers require 50 KiB of KV per context token; the 60 SWA rings need
37.5 MiB per slot before padding and chunk/verification scratch. One 32k slot therefore has
about 1.56 GiB of global KV; two have about 3.13 GiB. Plan with the engine's actual storage
types, dense tensor conversions, per-device workspaces, staging, allocator overhead and
reserves. Full FP32 copies double those KV costs. Begin with one 32k slot, then qualify two
32k slots and a single 64k slot. A 1M slot would consume about 50 GiB of global F16 KV alone.

The service target is **two 32K slots**, following one-slot qualification. Reuse HTTP
admission, queueing and slot limits; port the donor's batching hooks behind MiMo-specific
state/attention implementations, with `--parallel=1` until two-slot correctness passes.
Do not advertise arbitrary slot counts. Measure the cost to a lone request and the benefit
to two simultaneous requests before choosing the default; upstream Qwen hybrid results
do not predict MiMo's batching gain.

**6. The tokenizer also changes; the XML tool-call parser is largely reusable.**

`tools/strata_tokenizer.py` accepts a pre-tokenizer name but always compiles `QWEN35_PATTERN`.
MiMo's published tokenizer has NFC normalization and a different regex, including different
handling of combining marks. Load pinned model tokenizer assets, validate token IDs against
the GGUF tokenizer/reference, and explicitly resolve any normalization difference between
the HF and GGUF implementations before using a tokenizer for both. Do not infer correctness
from round trips or from the familiar ChatML delimiters.

MiMo's template uses the same `<tool_call><function=...><parameter=...>` structure, so much
of `serve/frontend.py` can remain. It needs model-specific fixtures, assistant
`reasoning_content` preservation, tool-result histories and streaming-boundary checks.
Cover dictionary/string arguments and custom tool bodies; the current parameter-only parser
must not silently turn a non-parameter payload into an empty arguments object.
The template reads `enable_thinking`, not `reasoning_effort`: map `none` to false and other
accepted effort values to true, document that the levels are equivalent, and remove
Qwen-specific reasoning-budget/rescue behavior. Set the published temperature 1.0 / top-p
0.95 defaults without inheriting Qwen's top-k or min-p filtering. Derive stop IDs from the
model metadata. Keep request-level sampling overrides.

## Performance evidence and conditional estimate

Use approximately 10 output tokens/s as the four-bit single-stream planning objective
after optimization and MTP. These are conditional engineering targets, not measurements
of a working Strata/MiMo backend, statistical confidence intervals or minimum guarantees.
An initial correct build can be slower than llama.cpp. Keep this framing in any README or
campaign quoting these figures.

| Configuration | Decode after short prompts | Decode at about 8K context | Cold prefill around 8K |
| --- | ---: | ---: | ---: |
| Measured llama.cpp b11583, MXFP4, MTP n-max 1 | 6.35 t/s | 5.17 t/s | 28.3 t/s |
| Estimated tuned Strata/MiMo, MXFP4, MTP | 8–12 t/s | 6–10 t/s | 60–120 t/s |
| Estimated tuned Strata/MiMo, mixed Q2_K, MTP | 10–15 t/s | 8–12 t/s | 70–150 t/s |

Q2_K and prefill estimates have lower confidence; no local Q2_K baseline exists yet.
Four-bit decode at 15–20 t/s requires substantially better locality, CPU service or
multi-token reuse than the central assumptions. There is no basis here for expecting
50–60 t/s. DeepSeek's separate 23.4 t/s Q2 traffic anchor is not a guaranteed floor or a
same-model comparison with MiMo's four-bit scenario.

### Local and upstream evidence

The [MiMo baseline](runs/2026-10-15-baseline.md#conclusion) used both V620s, the MXFP4
trunk, three interleaved passes and 256 generated tokens on code/prose/list prompts.
Its no-speculation/MTP comparison is reproduced in the validation section below.
No-speculation decode used 29.9–30.0 busy CPU cores, with card 1 drawing 60 W and card 2
22–23 W. MTP decode drew about 49–50 W and 35 W. At 8K prefill card 1 drew 66–73 W and
card 2 was idle at about 6 W. Qualified runs had no expert-store reads or VRAM spill.
Low GPU power motivates scheduling and kernel work; it is not a speedup multiplier.

The same-host [Flash-Next comparison](../qwen38-flash-next/runs/2026-10-16-strata.md#conclusion),
stage 8, used UD-Q4_K_XL with each engine's selected MTP settings:

| Engine / cards | Median decode | Cold prefill d8000 | Cold prefill d32000 |
| --- | ---: | ---: | ---: |
| llama.cpp, one V620 | 18.2 t/s | 358 t/s | 340 t/s |
| Strata v0.1.44.1, one V620 | 49.2 t/s | 989 t/s | 1,008 t/s |
| Strata v0.1.44.1, two V620s | 59.7 t/s | 964 t/s | 1,423 t/s |

The one-card decode gain is 2.70x; the two-card comparison is 3.27x but also changes
hardware allocation. Two Strata cards improve on one by about 21%. The workload labels
d8000/d32000 represent about 5.8K/23K actual Flash-Next tokens, not literal MiMo depths.
Stage 7's separate confirming MTP rates were 49.4/59.8 t/s; do not mix those stages.

At the reviewed v0.1.45 pin, the upstream
[Qwen3.6 results](https://github.com/Niko1221/Strata/blob/477ac13cbe8e582c20484871ce459d20d82df09d/docs/QWEN36.md)
on an R9700 with main experts in VRAM report 117.8 t/s without MTP, 183.7 with MTP,
and 6,220 t/s on a 4K prompt. The respective llama.cpp comparisons are 81.9–82.1,
129 from an earlier run, and 3,794 with a different micro-batch. The pinned
[Flash-Next quant table](https://github.com/Niko1221/Strata/blob/477ac13cbe8e582c20484871ce459d20d82df09d/docs/QUANTS.md)
reports 63–64 t/s story, 85–88 code, 70–72 after a 6K document, and 1,110–1,320 prefill
on a 32K prompt, on an R9700/EPYC 7452 with that table's older engine setup.
These are different models, hardware and placements, not MiMo or V620 forecasts.
Upstream hybrid slot costs also vary by card; require the local concurrency tests.

### Cache capacity and quantization

Strata can overlap GPU cache hits with CPU misses, group verification rows and amortize
prefill transfers. llama.cpp already provides GPU prompt offload, MTP and prefix reuse;
do not count those as wholly new benefits. Regenerate routing profiles rather than using
Qwen's `data/expert-profile.bin`.

Flash-Next's two-card test held 16,220 of 24,576 experts and reported a 97.5% median
decode hit rate. MiMo's 26,496 MXFP4 experts occupy 494.86 GiB. After approximately
20.4 GiB of GPU non-expert weights, plus KV, MTP, scratch and reserves, an illustrative
25–30 GiB total expert budget holds about 1,339–1,606 experts, only 5–6% of the pool.
This budget includes permanent GPU-owned experts: three full layers use 21.52 GiB,
leaving 3.48–8.48 GiB for duplicate adaptive entries. Recalculate per card and configuration;
MTP or a second slot can reduce the budget. Routing concentration can raise hit rate above
capacity fraction, but only a held-out trace can establish that.

Eight selected experts across 69 layers represent 10.31 GiB of MXFP4 routed reads per
token before cache hits. Dense work is additional. Applying Flash-Next's 3.27x gain blindly
would predict 20.8 t/s short-context and 17.0 at 8K; that is an optimistic scenario, not
the central expectation. Measure MiMo kernels at their actual widths.

The mixed Q2_K expert is 14.25 MiB, its pool 368.72 GiB and selected reads 7.68 GiB/token:
about 25.5% less traffic, not half. Unchanged dense work reduces the end-to-end benefit;
more cache coverage helps, while dequantization cost or lower MTP acceptance can offset it.
The 10–15 t/s Q2_K target has no local measurement. Keep the existing MXFP4 file for the
four-bit target; the 575.4 GiB Q4_K_M alternative exceeds usable RAM plus both cards.

### Sensitivity model and calibration

Start from measured MiMo no-speculation time, not Qwen throughput:

```
T0 = 1 / 4.74 = 0.211 seconds per target token
h0 = 3 / 69 = 4.35%   # three whole expert layers on GPUs in the no-spec baseline
Tnew = T0 × [f + (1-f) × (1-h)/(1-h0) / s]
decode_with_MTP = m / Tnew
```

`h` is the fraction of routed work served from VRAM; `s` improves remaining host-expert
service time; `m` is net MTP gain including draft/verification costs. `f=0.30` is an
assumed unchanged fraction for dense work, attention, synchronization and other costs,
not a measured profile. Cache costs are not independently measured in these scenarios.

| Scenario | Assumed VRAM work fraction | Assumed host-service improvement | Assumed net MTP gain | Derived short-context rate |
| --- | ---: | ---: | ---: | ---: |
| Modest | 15% | 1.10x | 1.20x | about 6.6 t/s |
| Central | 30% | 1.30x | 1.35x | about 9.2 t/s |
| Strong | 40% | 1.50x | 1.50x | about 12.0 t/s |

Local MiMo MTP gains are 1.34x at short context and 1.14x at 8K; two-card Flash-Next
gained about 1.60x in its control comparison. The central case assumes improved target
execution with a familiar short-context MTP gain; acceptance falls with depth.

| Term | Local anchor | Required calibration |
| --- | --- | --- |
| Host service `s` | No-spec decode 4.74 t/s, 29.9–30.0 busy cores, 32 pinned workers | Same-width MXFP4/Q2_K kernels and critical-path CPU/transfer time; neither STREAM nor idle GPU power determines `s` |
| Cache refresh | Four op-offload copies of about 473–481 GiB in 279–289 s, effective 6.8 GiB/s | Bounded HIP copies under actual load, cache churn and prefill bytes |
| MTP `m` | d0 acceptance code/prose/list 90/86/79%; d8000 60/59/55%, median 59%; net gain 1.34x / 1.14x | Draft/verify cost, changed placement and acceptance by quant/depth; acceptance itself is not a speed multiplier |
| VRAM work `h` | No local routing trace; `h0=3/69` is whole-layer placement | Held-out causal cache replay within per-card budgets, including permanent experts and promotion cost |

The 6.8 GiB/s is an effective Vulkan op-offload rate including pipeline costs, not a
proven HIP DMA ceiling. Use it as an initial conservative scenario, then replace it with
measurements. Expose residual costs beyond those already represented in `f` and `s`:

```
Tcalibrated = Tnew + incremental_unhidden_refresh_and_GPU_service_time
refresh_service_time = promoted_bytes / measured_copy_service_rate
decode_with_MTP = measured_net_MTP_gain / Tcalibrated
```

For illustration, 256 MiB of extra promotion/token at 6.8 GiB/s costs 36.8 ms if none
overlaps. Added to the central 146.4 ms, it lowers 9.2 t/s to about 7.4 with the same
assumed 1.35x MTP gain. Charge only measured unhidden critical-path time; do not count
copies twice or assume full overlap. Do not combine a no-MTP cache budget with an MTP
multiplier unless the drafter/verification workspace fits too.

Step 1's routing probe must support at least 30% held-out effective hits and calibrated
host/transfer costs before retaining the central scenario. Otherwise withdraw it and
re-estimate before investing in caching. Q2_K needs its own baseline, route trace and
acceptance; MXFP4 does not establish Q2_K's target. None of this fork calibration has run.
In this model, 15–20 t/s needs roughly 60–80% cache hits at 1.5x host service and 1.6x
MTP, or compensating gains elsewhere—demanding against 5–6% resident capacity.

Prefill's 60–120 t/s target is a rough 2–4x improvement over 28.3, informed by the local
Flash-Next gains and MiMo's low prefill utilization. Transfer bandwidth, chunk size,
expert grouping and FP16 compute need profiling. This implies about 67–133 seconds for
a cold 8K prompt versus about 283 seconds now, excluding other first-token costs.

## Implementation sequence

Each numbered item is a separate reviewable change, potentially split further for kernels.
The acceptance checks below belong to implementation; they were not executed in this review.

0. **Refresh pins and qualify the base when the owner resumes MiMo.** Build the selected
   frozen Strata base separately from the deployed installation. Run Flash-Next UD-Q4_K_XL
   yardstick and chat/tool gates on the same card/settings as its reference record. Upstream
   Strata cannot qualify MiMo weights before this backend exists; the MiMo llama.cpp baseline
   belongs to step 1. **Exit:** base correctness passes, performance/memory differences are
   explained, and the restore path is intact. Reuse a recorded DeepSeek base qualification
   only if commit, dependencies, hardware and settings are unchanged.

1. **Define the smaller MiMo artifact and its reference baseline.** Add a strict `mimo2`
   descriptor, a Q2_K shard/tensor inventory and a dry-run placement report. Read the complete
   pinned shard set, including any metadata-only shard; validate required names, dimensions, dtypes,
   offsets, hashes, the explicit attention pattern and dense-versus-MoE layers. Distinguish
   padded embedding/output vocabulary rows from valid tokenizer IDs. Make all size
   arithmetic checked 64-bit. Build small layer/expert fixtures without materializing
   whole tensors in Python. Record reference token IDs, layer outputs, routed IDs/weights
   and logits from the same Q2_K GGUF with the frozen llama.cpp reference. Measure its own
   no-speculation and MTP baseline; the existing MXFP4 times are not a same-quant comparison. **Exit:** a byte-complete
   inventory, bounded anonymous-RAM loading with ample headroom, and reproducible reference
   outputs. Quant-vs-original model accuracy/perplexity is not a development acceptance gate.

   **Routing-locality probe before step 2.** Use a bench-only instrumented llama.cpp build
   on this same quant to capture per-layer selected expert IDs/weights for a few hundred
   generated tokens per code/prose/list prompt at short and 8K depth. Separate prefill and
   decode traces. Build profiles on training prompts and evaluate held-out prompts; a
   histogram fitted to its own evaluation trace is only an optimistic upper bound.
   Replay static and causal adaptive cache policies at the ledger-derived budget (show
   25/30 GiB sensitivity), including fixed GPU-owned experts, per-card capacity and cache
   refresh bytes. Report byte/work-weighted hits, not just distinct-expert counts, for
   Q2_K and eventually MXFP4 separately.

   Predeclare this screening rule in the campaign: the central forecast requires at least
   30% held-out effective hits within the total expert budget and a calibrated service-time
   estimate that improves on same-quant llama.cpp beyond its repeatability spread. Below
   that, withdraw the central forecast and re-estimate; continue the cache work only with
   a documented alternative supported by kernel/transfer measurements and the owner's
   usable latency target. If none remains, keep implementation deferred. Meeting the rule
   permits implementation; it is not a measured engine speedup. Historical MXFP4 acceptance
   cannot stand in for Q2_K's unmeasured MTP gain.

2. **Implement MiMo primitives and a reference layer runner.** Add plain RMSNorm/residual,
   dense SwiGLU for layer 0, sigmoid/bias routing, Q2_K/MXFP4 CPU execution and straightforward
   HIP paths for those two formats. For correctness first, bounded dequantization plus BLAS is acceptable on
   GPU; never expand all experts to FP16. Add global and SWA attention with sinks, unequal
   K/V widths, per-layer RoPE and the attention scale. Fix worker scratch allocation.
   **Exit:** fixtures covering layer 0, an SWA MoE layer and a global MoE layer agree with
   the reference within a predeclared numeric tolerance; identical controlled router inputs
   produce the reference selections/weights. Include SWA positions 127/128/129 and repeated
   wraps, nonzero sink/bias values and large or near-tied router scores.
   Both Q2_K gate/up **and MXFP4 down** CPU/HIP paths must ship in this milestone;
   MXFP4 execution cannot wait for step 7. Audit the manifest's dense/MTP formats too,
   with a named bounded path and fixture for each.

3. **Run the smaller-quant trunk on both cards, without speculation.** Implement an explicit
   layer split with each layer's attention/KV and cached experts on its assigned card, plus
   CPU workers for RAM experts. Validate peer copies and provide bounded host staging when
   HIP peer access is unavailable. Start eager, one slot, small prompt chunks, F16 KV and
   fixed placement. All experts can retain their RAM copies for this development quant.
   Implement cancellation and explicit context overflow. **Exit:** teacher-forced
   full-vocabulary logits and per-layer comparisons on identical
   input IDs. Compare against llama.cpp with speculation off, not its MTP result.

4. **Connect serving and sessions.** Load MiMo tokenizer/template assets, implement the
   thinking mapping and defaults, and connect the existing `READY/GEN/T/DONE` protocol.
   Retain OpenAI Chat Completions, Responses and Anthropic adapters. Introduce a versioned
   MiMo session format keyed by model/tensor/tokenizer identity, context and KV dtype.
   Save global KV lengths plus SWA ring data, absolute positions and cursors; remove GDN
   state, QSA indexes, PLE history and hyper-connection state. Reject old caches. Initially
   recompute prefixes that cannot be restored safely. **Exit:** streaming/non-streaming text
   and tools, thinking on/off, Unicode, stop handling, cancel/reuse, prefix hit/miss,
   cross-session isolation pass first at one 32K slot, then two 32K slots with admission
   and memory limits checked. Reject unsupported media explicitly.

5. **Add caching and faster prefill with unchanged model math.** Reuse bounded expert-cache
   storage and the CPU pool, pin only transfer buffers, overlap GPU hits with CPU misses,
   and use step 1's held-out routing profiles/decision. Preserve the memory reserve under
   cache promotion and prompt execution. Replace whole-layer transfers with expert/tile groups, then add
   native Q2_K/MXFP4 decode and grouped prompt kernels as measured
   bottlenecks require. Tune CPU thread count and placement on this EPYC rather than carrying
   over Qwen's worker count. **Exit:** same-quant numerical checks still pass, memory is bounded,
   warm expert-store reads are absent, and interleaved benchmarks demonstrate the benefit
   of each optimization. Record cache hit rate, host read volume, PCIe traffic and prefill
   stalls alongside tokens/s.

6. **Add MiMo MTP as an optional optimization.** Use the already downloaded MiMo Q8_0 MTP
   GGUF, with its own tensor manifest, three appended blocks and nextn norm/projection/head
   rules. Do not call Qwen's `mtp_fetch.py`, `mtp_pack.py` or `mtp_rt.py`. Treat Xiaomi's
   separate DFlash directory as another implementation, deferred here. Begin with one
   proposal per verification, consistent with the lab's best llama.cpp result. Re-plan
   VRAM when enabling MTP. Use measured acceptance on the smaller target quant; its acceptance
   may differ from MXFP4. Preserve accepted-prefix KV and restore overwritten SWA entries on a
   rejection. **Exit:** zero/partial/full acceptance, EOS, cancellation, ring-wrap rejection
   and two-slot behavior pass. Greedy verification matches the same fixed-placement target
   without speculation; sampled verification must preserve the target distribution.

7. **Qualify the four-bit target.** Load the existing MXFP4 model with the already implemented
   MXFP4 kernels. Inventory it separately and replace duplicate-all ownership with the
   permanent GPU-owned subset described above. Measure peak load memory, prefill, cache
   updates and MTP under the near-capacity placement. Reuse the numerical fixtures and
   compare against the measured MXFP4 llama.cpp configuration. Keep Q2_K as the fast
   development/test artifact and report the two formats separately.

8. **Package the MiMo fork and qualify it on CT 123.** Replace the executable entry point,
   installer catalog, model name, startup checks and docs. The initial supported build is
   HIP/gfx1030; remove unsupported backends from this fork's advertised support/build matrix.
   Pin the fork and ggml commits and record all model hashes. Add separate `strata-mimo`
   launcher/env/unit files in this Proxmox repository, adopting DeepSeek's parameterized
   test-host/engine switch (see lab integration below), not a second bespoke switch.
   Keep llama.cpp available as the operational reference and restoration target. Deployment
   is a later implementation action, not part of this planning change.

The first useful end-to-end milestone is steps 1–4 on Q2_K: correct text/tool serving on the
actual hardware. Step 5 determines the basic speed advantage. MTP is optional for that first
milestone but important for a fair best-configuration comparison; four-bit fit is step 7.

## File map

Paths in this table are relative to the upstream Strata fork, except the last row. New paths
are proposed interfaces, not files already implemented.

| Area | Existing code to reuse or replace | Planned result |
| --- | --- | --- |
| Model metadata | `include/strata/artifact/{model_family,gguf_reader,gguf_split}.hpp`, `include/strata/core/{geometry,family_layout}.hpp` | Strict `mimo2` descriptor; independent K/V dimensions; layer arrays; dense/MoE classification |
| Execution | `src/program/generate.cpp`, `src/core/{layer,verify,session}.cpp`, `src/qwen35/` | Small entry point and focused `src/mimo/{model,engine,attention,router,kv_cache,session,mtp}` modules |
| CPU experts | `include/strata/kernels/cpu/{expert,native_expert,pool}.hpp`, `src/kernels/cpu/{native_expert,pool}.cpp` | MiMo-sized scratch and Q2_K/MXFP4 dispatch using pinned ggml traits on AVX2 |
| GPU experts | `src/kernels/cuda/native_mmvq.cu`, `src/kernels/cuda/native_moe.cu`, `src/prefill/` | Q2_K/MXFP4 HIP kernels or bounded dequant/BLAS reference path; exact top-8 combine |
| Placement / I/O | `src/core/{expert_source,expert_cache,peer_experts,remote_experts}.cpp`, `include/strata/plan/plan.hpp`, `src/platform/` | Anonymous RAM experts, bounded staging and duplicate cache for Q2_K; exclusive permanent subset later for MXFP4 |
| Serving | `serve/{server,frontend,responses,runconfig}.py`, `tools/strata_tokenizer.py` | MiMo tokenizer/template/defaults and versioned session capabilities; preserve HTTP adapters |
| Diagnostics | `tools/qwen35/{parity,kl,compare_dumps}.py`, `tools/quant_quality.py`, existing HIP tests | `tools/mimo/` reference capture/comparison and MiMo fixtures, without Qwen dimensions or stop IDs |
| Build / setup | `CMakeLists.txt`, `setup.py`, `tools/strata_inspect.py`, `tools/strata_mcp.py`, web settings/docs | MiMo-only catalog, explicit capabilities, pinned artifacts and measured requirements |
| Lab integration | `pro-v620/mimo-v26-pro/`, `pro-v620/strata/`, `pro-v620/glm53-flash/ct123-test-host.sh` | Separate MiMo Strata service and reusable existing probes/telemetry/restore procedure |

Keep portable platform code, GGUF parsing, applicable matrix operations, CPU worker mechanics,
the server adapters and telemetry. Remove Qwen GDN, QSA/indexer, PLE n-grams,
hyper-connections, shared-expert execution, Qwen MTP packaging, Qwen catalogs and their
model-specific tests from the active build. Preserve licenses and attribution. Keep generic
HTTP/security/cancellation tests and replace architecture-specific fixtures. Qwen output
identity is deliberately not an acceptance requirement for this fork.

## Lab integration and campaign safety

Before the first full-model fork run, adopt the parameterized plumbing from DeepSeek's
plan: `../strata/use-engine.sh` and `../glm53-flash/ct123-test-host.sh`, with engine root and
unit passed explicitly. Extend the existing `TEST_MODEL=mimo` for `TEST_ENGINE=strata`,
root `/opt/strata-mimo/`, unit/env `strata-mimo` and launcher `strata-serve-mimo`.
Update `TEST_UNITS`, all relevant `Conflicts=` lists, readiness/device checks, `/dev/kfd`,
DRM cgroups, both GPU owners, CT 120 autostart and the watchdog map together. Preserve
llama.cpp as the same-quant reference and provide a one-command engine return within the
MiMo test setup; the full campaign restore returns the saved Flash-Next configuration.

Derive `TEST_MEMORY_MIB` from peak startup/prefill/slot/cache allocations plus a container
reserve and host margin. Keep the engine's `--memory-limit-mib` below that CT limit by the
declared reserve on every launcher configuration. Commit numerical CT runtime-reserve and
host minimum-MemFree thresholds before loading full weights; MemAvailable alone can count
resident experts as reclaimable. Reject swap, unexpected expert-store reads, VRAM spill
and breached reserves. Prove the MXFP4 ownership plan again with MTP/two slots; the
no-speculation three-layer fit is not evidence that adding the drafter fits unchanged.

Carry the [inherited gfx1030 constraints](../strata/README.md#known-gfx1030-issues-upstream)
into every campaign's Safety section: #884 and `STRATA_HIP_ADAPT_KERNEL_COPY=1`,
`STRATA_HIP_PROMPT_F16`, `STRATA_MMQ_KQ`, #2457's corruption regression class, and #1103's
ROCm runtime issue. Requalify each switch against the new path; `STRATA_SH_STREAM` is
inapplicable to MiMo's absent shared expert and must not survive as a claimed optimization.
Use rocBLAS for dense GEMMs; gfx1030 has no usable WMMA/hipBLASLt path here. Record the
ROCm 10.0 pin, the 10 s timeout from `../amdgpu-lockup-timeout.sh`, the ROMED8-2T thermal
guard, watchdog mapping, residency samplers and `vram-release-trace.sh`. The owner's DIMM
decision adds no new risk gate or mitigation; retain existing guards and DIMM telemetry.

Use adapted `strata-sweep.sh`/probes, `push-harness.sh`, `capture-env.sh`, `environment.json`
and [TEST-RECORDS.md](../TEST-RECORDS.md). Explain excluded standard arms per quant: Q2_K
may fit one-card/CPU-only controls even though the MXFP4 record excluded them. Include
MTP/no-MTP controls, acceptance and one/two-stream comparisons when the drafter is enabled;
document the deferred DFlash path. Check cold-request/token-counting fixes tracked in
[#112](https://github.com/marchah/Proxmox/issues/112) before usage workloads, and qualify
the Hermes provider before a deployment decision. Other guests stay off until the owner
asks to restart them. Finish installation docs, root README inventory and CLAUDE.md's
"Where to look" when a service is installed, not as a claim of deployment in this plan.

## Validation and performance decision

Use the same quant, model hashes and tokenized prompts across engines. Numerical implementation
correctness remains required; measuring the small quant's accuracy loss against original or
larger weights is explicitly deferred. First capture repeatability
and the CPU/GPU numeric differences of the reference on selected fixtures, then declare
tolerances before evaluating the new path. Compare full-vocabulary teacher-forced KL,
per-layer error, router selections and greedy divergence margins; plausible prose alone
does not qualify a backend. Require exact IDs for tokenizer tests and exact internal results
for optimizations claimed to preserve arithmetic. Avoid insisting on byte-identical free
generation across different backend reductions.

Exercise prompt chunk boundaries and SWA wraps; short and 8k-depth inputs; 32k/64k capacity;
prefix restore and branching; two concurrent conversations; tools and reasoning; model reload;
and MTP separately. Start with scratch tests under memory sanitizers and small device
fixtures before loading the full model. All completed features need HIP/gfx1030 validation;
run syntax/build checks for other backends only if the fork continues shipping them.

Existing comparison points, from [the baseline record](runs/2026-10-15-baseline.md#conclusion),
llama.cpp b11583, both V620s, identical MXFP4 trunk, median of three passes:

| Measurement | No speculation | Q8_0 MTP, n-max 1 |
| --- | ---: | ---: |
| Short-prompt decode, median over code/prose/list | 4.74 tok/s | 6.35 tok/s |
| Decode at 8k depth, median over code/prose/list | 4.54 tok/s | 5.17 tok/s |
| Prefill at 8k depth, prose | 28.9 tok/s | 28.3 tok/s |
| Two-stream aggregate decode | 6.92 tok/s | 7.78 tok/s |

Re-run the reference interleaved with the fork, at least three repetitions, and report
prefill/TTFT, decode, end-to-end latency and two-stream throughput separately. Match context
per slot: Strata's context setting is per slot; llama.cpp's total is shared across slots.
Include no-speculation controls and report each engine's best qualified placement separately
from controlled-placement kernel comparisons. Collect requested/resident VRAM, GTT, RAM,
swap, expert-store reads, temperatures and engine faults with the existing harnesses. Follow
[TEST-RECORDS.md](../TEST-RECORDS.md) when scheduling those runs.

The decision after the smaller-quant backend is correct is whether MiMo's measured routing
locality and overlap improve the intended workload. Commit its primary metric and usable
decode/TTFT thresholds before the performance campaign. Require improvement beyond the
observed repeatability spread in at least three interleaved same-quant passes, with
numerical correctness and memory gates passing. Compare no-speculation controls first,
then each engine's best qualified MTP configuration. If bounded caching/compute tuning
cannot beat that reference, retain llama.cpp as the operational reference, document the
result and stop further optimization/speculative/multimodal investment. This is a future
measurement gate, not a test already failed by the estimate. Deployment remains a separate
decision; no MiMo service is currently deployed. Apply the same decision independently to
MXFP4. When citing this plan's estimates, preserve their conditional-target framing.

| Unknown | Measurement | Fallback | Stop / scope limit |
| --- | --- | --- | --- |
| Routing concentration and cache churn | Step-1 held-out route replay, 25/30 GiB sensitivity, per-card hit/refresh bytes | Static placement or a measured CPU-service improvement | Withdraw the central forecast below its screening assumptions; defer implementation without a supported useful alternative |
| Q2_K/MXFP4 throughput at MiMo widths | Real-block AVX2/HIP decode and grouped-prompt tests, geometry-sized scratch | Bounded dequantization + BLAS | No Q2_K milestone without working MXFP4 down projections; stop optimization if the final same-quant gate fails |
| Prefill transfer/overlap | Actual copy service time, chunk size, expert reuse and TTFT | Smaller expert/tile groups, CPU prefill | No speed claim from the 6.8 GiB/s reference alone; stop at the declared TTFT gate |
| Q2_K MTP acceptance | Same-quant acceptance by class/depth, draft/verify cost, rejected SWA writes | No speculation | MTP is optional; disable if latency regresses or verification differs |
| MXFP4 startup and service fit | Peak RAM/VRAM, fixed ownership, bounded staging, MTP and two-slot ledger | Retain Q2_K, reduce slots or keep no-MTP | Defer four-bit release if reserves fail; never evict permanent GPU-owned experts without a valid RAM copy |
| Session and two-card correctness | One/two-slot state isolation, chunk/wrap tests, peer-copy fixtures | Single slot and bounded host transfers | Block the affected capability until parity passes |
