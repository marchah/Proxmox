# Strata → MiMo-V2.6-Pro-RL

Review date: 2026-10-17. This is a source review and implementation plan; no engine changes,
model runs or service changes were made.

Recommendation: make a MiMo-only fork of Strata, reuse its serving and CPU/GPU scheduling
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

- [Strata source](https://github.com/Niko1221/Strata/tree/477ac13cbe8e582c20484871ce459d20d82df09d),
  commit `477ac13cbe8e582c20484871ce459d20d82df09d`, dated 2026-10-16. This is newer than
  this lab's installed `v0.1.44.1` / `296b59d2f73c8f04a805df29c2fa97655adace78`.
- [Latest release v0.1.45](https://github.com/Niko1221/Strata/releases/tag/v0.1.45),
  published 2026-10-17 at 06:53 UTC, checked during the follow-up review. Performance
  evidence and conditional estimates are in [STRATA-PERFORMANCE-ESTIMATE.md](STRATA-PERFORMANCE-ESTIMATE.md).
- Strata's ggml pin is `3cf03257f219afbe7334045ff7c6a06ac68c627d`, in both `setup.py`
  and `CMakeLists.txt`.
- [MiMo configuration](https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Pro-RL/blob/b61f21852680ee02a29e946e18cf8697f4844061/config.json),
  [reference model implementation](https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Pro-RL/blob/b61f21852680ee02a29e946e18cf8697f4844061/modeling_mimo_v2.py),
  [tokenizer](https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Pro-RL/blob/b61f21852680ee02a29e946e18cf8697f4844061/tokenizer.json)
  and [chat template](https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Pro-RL/blob/b61f21852680ee02a29e946e18cf8697f4844061/chat_template.jinja).
- [ggml-org GGUF revision](https://huggingface.co/ggml-org/MiMo-V2.6-Pro-RL-GGUF/tree/5f387f5260fc110678396a3076a140c469b41eaa),
  already used by this lab for MXFP4. Inventory and pin this revision's smaller Q2_K shard
  set first; later use the seven MXFP4 trunk shards, whose first shard is metadata-only.
- [llama.cpp b11583 MiMo graph](https://github.com/ggml-org/llama.cpp/blob/b11583/src/models/mimo2.cpp)
  is the execution reference for these GGUFs. Use b11583 initially for comparability with
  the [existing measurements](runs/2026-10-15-baseline.md); record the resolved commit and
  binary hash when preparing the implementation fixtures.

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

**7. The measured Strata gains justify the project, with a smaller expected gain on MiMo.**

This server's Flash-Next tests measured 49.2 t/s on one V620 and 59.7 t/s on two with
Strata, versus 18.2 t/s with llama.cpp on one. That is a strong positive result, although
the two-card ratio also changes the hardware allocation. MiMo's current llama.cpp baseline
is 6.35 t/s after short prompts and 5.17 t/s at 8k depth with MTP. Its GPU utilization and
CPU-heavy decode make overlap, cache placement, grouped verification and prefill worthwhile
optimization targets.

Without cache hits, the eight selected experts across 69 layers account for about 10.31 GiB
of routed weight reads per decode token, calculated from their stored format. A few tens
of GiB of GPU expert storage hold only a small fraction of the 494.9 GiB pool. Routing
locality may give better hit rates than that fraction, but it must be measured on MiMo.
Regenerate profiles; `data/expert-profile.bin` is a Qwen profile.

Use roughly 10 t/s as the four-bit single-stream planning target after optimization and MTP:
8–12 t/s at short context and 6–10 t/s at 8k depth. For the smaller mixed Q2_K build, use
10–15 and 8–12 t/s respectively as tentative targets. These are conditional engineering
estimates, not benchmark results or guaranteed lower bounds. See the
[estimate and its assumptions](STRATA-PERFORMANCE-ESTIMATE.md) before treating any figure
as a commitment. Initial correct builds can be slower than llama.cpp.

## Implementation sequence

Each numbered item is a separate reviewable change, potentially split further for kernels.
The acceptance checks below belong to implementation; they were not executed in this review.

1. **Define the smaller MiMo artifact and its reference baseline.** Add a strict `mimo2`
   descriptor, a Q2_K shard/tensor inventory and a dry-run placement report. Read the complete
   pinned shard set, including any metadata-only shard; validate required names, dimensions, dtypes,
   offsets, hashes, the explicit attention pattern and dense-versus-MoE layers. Distinguish
   padded embedding/output vocabulary rows from valid tokenizer IDs. Make all size
   arithmetic checked 64-bit. Build small layer/expert fixtures without materializing
   whole tensors in Python. Record reference token IDs, layer outputs, routed IDs/weights
   and logits from the same Q2_K GGUF with b11583. Measure its own no-speculation and MTP
   baseline; the existing MXFP4 times are not a same-quant comparison. **Exit:** a byte-complete
   inventory, bounded anonymous-RAM loading with ample headroom, and reproducible reference
   outputs. Quant-vs-original model accuracy/perplexity is not a development acceptance gate.

2. **Implement MiMo primitives and a reference layer runner.** Add plain RMSNorm/residual,
   dense SwiGLU for layer 0, sigmoid/bias routing, Q2_K/MXFP4 CPU execution and straightforward
   HIP paths for those two formats. For correctness first, bounded dequantization plus BLAS is acceptable on
   GPU; never expand all experts to FP16. Add global and SWA attention with sinks, unequal
   K/V widths, per-layer RoPE and the attention scale. Fix worker scratch allocation.
   **Exit:** fixtures covering layer 0, an SWA MoE layer and a global MoE layer agree with
   the reference within a predeclared numeric tolerance; identical controlled router inputs
   produce the reference selections/weights. Include SWA positions 127/128/129 and repeated
   wraps, nonzero sink/bias values and large or near-tied router scores.

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
   cross-session isolation and two-slot operation pass. Reject unsupported media explicitly.

5. **Add caching and faster prefill with unchanged model math.** Reuse bounded expert-cache
   storage and the CPU pool, pin only transfer buffers, overlap GPU hits with CPU misses,
   and generate MiMo routing profiles. Preserve the memory reserve under cache promotion
   and prompt execution. Replace whole-layer transfers with expert/tile groups, then add
   native Q2_K/MXFP4 decode and grouped prompt kernels as measured
   bottlenecks require. Tune CPU thread count and placement on this EPYC rather than carrying
   over Qwen's worker count. **Exit:** output-quality checks still pass, memory is bounded,
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
   launcher/env/unit files in this Proxmox repository, and extend the existing test-host
   switch to coordinate both GPUs, CT 120, unit conflicts and the thermal watchdog map.
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

The decision after the smaller-quant backend is correct is whether MiMo's measured routing locality
and overlap can improve the actual workloads. The estimates in the companion note depend on
unmeasured MiMo cache hits and kernel efficiency. If memory-safe caching or optimized compute cannot beat the same-quant
configuration on the intended workload, keep llama.cpp as the deployed engine and document
the result before investing in additional speculative or multimodal paths.
