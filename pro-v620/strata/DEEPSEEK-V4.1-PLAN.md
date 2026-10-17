# Strata → DeepSeek-V4.1-Flash: review and implementation plan

Reviewed 2026-10-17. This is a plan for **local inference**, using a DeepSeek-only
fork of Strata. Dropping Qwen compatibility simplifies the implementation, but
the work still includes a new model execution path. Keep Strata's useful systems
infrastructure and replace the Qwen mathematics, artifacts, and conversation
format. Avoid building a general multi-model framework as part of this port.

The hardware target is exclusively the existing ROMED8-2T host: EPYC 7532
(Zen 2 / AVX2), approximately 503.6 GiB usable RAM, two V620s (gfx1030) with
30,704 MiB exposed VRAM each, and NVMe model storage. Use the already working
Linux/HIP/ROCm 10.0 environment. Those are recorded values, not a fresh host
inspection. CT 123's current 120 GiB limit must be increased for these tests.
See the [host fit notes](../mimo-v26-pro/README.md) and
[current Strata installation](README.md).

Scope clarified by the owner on 2026-10-17: start with a small quantization to
remove capacity pressure, aim for approximately 4-bit weights eventually, and
support only this hardware. The first deliverable is text inference on the
pinned Q2 artifact at short context, one request at a time. Then add the text/tool
API, performance tuning, and Q4. CUDA, other GPU generations, other operating
systems, vision, and DSpark are outside the first release. There is no requirement
to implement native FP4/FP8 GPU arithmetic or a catalog of weight formats.

Initial correctness means agreement with a reference using the **same quantized
weights**. Quantization's loss of model accuracy is accepted for bring-up; a
quality comparison with the original checkpoint is not an implementation gate.
Numerical bugs, wrong routing, missing layers, and state corruption still need
to be caught. No implementation or deployment has been performed during this review.

**Sources and reproducibility.** The reviewed Strata main commit is
[`477ac13cbe8e582c20484871ce459d20d82df09d`](https://github.com/Niko1221/Strata/tree/477ac13cbe8e582c20484871ce459d20d82df09d).
This is also the commit behind the latest
[v0.1.45 release](https://github.com/Niko1221/Strata/releases/tag/v0.1.45), published
2026-10-17. The lab measurements below used v0.1.44.1. Choose the reviewed commit
as the development baseline and pin its dependencies too.

The initial weight target is
[antirez/deepseek-v4.1-flash-gguf](https://huggingface.co/antirez/deepseek-v4.1-flash-gguf/tree/dd8a266f7145edc19e2334b46e19b6821f221dc7)
at revision `dd8a266f7145edc19e2334b46e19b6821f221dc7`, specifically
`DeepSeek-V4.1-Flash-Q2.gguf`. The source model revision recorded in its header is
`df42c109f1defefcbfcedbe7d905718a12266e40`. Its matching Q4 uses the same architecture
and dense precision, adding Q4_K routed experts. These artifacts were published
for DwarfStar; we must implement their loader contract in the fork rather than
assume Strata already loads them.

The newly released
[`DeepSeek-V4.1-Flash-1017`](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/tree/1bae0e1088993b9b82de08f59de5be5a34e42170)
at revision `1bae0e1088993b9b82de08f59de5be5a34e42170` is a later weight refresh
candidate once a matching supported quant is available or converted. Do not label
the initial quant as 1017.
The original V4.1 release was inspected at
[`314113f8a7dadb388215396ba5fbee2c610a04d6`](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash/tree/314113f8a7dadb388215396ba5fbee2c610a04d6).
Their configs, all 48 safetensors headers, and the inspected model/kernel/Engram
and prompt-encoding Python files are identical. Their weight contents were not
downloaded or compared. Model revision and tensor hashes must remain part of every
artifact and cache identity.

The official
[model code](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/blob/1bae0e1088993b9b82de08f59de5be5a34e42170/inference/model.py),
[quantization kernels](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/blob/1bae0e1088993b9b82de08f59de5be5a34e42170/inference/kernel.py),
[Engram hashing](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/blob/1bae0e1088993b9b82de08f59de5be5a34e42170/inference/engram.py),
and [encoding reference](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/blob/1bae0e1088993b9b82de08f59de5be5a34e42170/encoding/README.md)
are the semantic references. The minimal implementation is a reference, not an
optimized production backend; its self-test uses uninitialized weights and is
not a numerical correctness oracle by itself.

**Review findings.** These are porting constraints, rather than bugs in Strata's
intended Qwen implementation. Paths below are relative to the reviewed upstream.

| Priority | Evidence in Strata | Consequence for this port |
| --- | --- | --- |
| P0 | `include/strata/core/geometry.hpp:23`, `include/strata/core/family_layout.hpp`, `src/core/layout.cpp:52` | Geometry defaults and layout checks describe Qwen's 48-layer GDN/QSA graph. Replace this contract; changing dimensions alone cannot implement DeepSeek. |
| P0 | `src/core/layer.cpp`, `src/core/verify.cpp`, `src/prefill/prefill.cpp` | Decode, verification, and prefill contain separate model-specific execution logic. All three require attention; a working single-token path is insufficient. |
| P0 | `src/kernels/cuda/router_top10.cu`, `native_router.cu:236`, `src/core/expert_source.cpp:3646` | The router uses Qwen semantics, optimized routes support selected Qwen expert counts, and a CPU path rejects activations wider than 2560. Audit CPU and GPU dispatch, not just the model loader. |
| P0 | `include/strata/kernels/ngram.hpp`, `src/ngram/ple_reader.cpp`, `src/kernels/cuda/ple.cu` | PLE's token mapping, table layout, history, and projection are not DeepSeek Engram. Reuse file I/O primitives, replace the lookup and computation. |
| P0 | `tools/strata_tokenizer.py:58`, `serve/frontend.py:40`, `serve/server.py:752`, `src/program/generate.cpp:691` | Qwen tokenizer rules, Jinja rendering, effort mapping, and EOS IDs remain in multiple layers. DeepSeek needs a different codec and stop contract. |
| P1 | `include/strata/core/session.hpp`, `src/core/conversation_*.cpp`, `include/strata/plan/plan.hpp` | Session state and memory accounting assume per-QSA KV, GDN recurrence, and PLE history. Shared DeepSeek state requires new ownership, snapshots, and budget calculations. |
| P1 | `src/core/mtp.cpp`, `tools/mtp_fetch.py`, `tools/mtp_pack.py` | Qwen MTP cannot consume DSpark's draft layers. Disable it until a separate DSpark implementation is validated. |
| P1 | `setup.py`, `data/expert-profile.bin`, `serve/images.py`, `tools/vision/` | Downloads, memory recommendations, expert profiles, image processing, and launch defaults must be replaced or recalibrated. |

The limited Qwen3.6 family support does not solve these gaps: its validation and
execution still assume related Qwen architectures. A new general-purpose family
dispatch layer would add work without removing DeepSeek's kernel requirements.

There is already an open
[DeepSeek V4 Flash port, PR #1518](https://github.com/Niko1221/Strata/pull/1518),
reviewed at `6e326aab2f9679d34be36020fd1a8d7021c8ccce`. It adds a separate
`dsv4_ext` engine targeting the older V4 model. Its README describes 43 layers and
256 experts, unlike V4.1. Evaluate its dequantization utilities, tiny fixtures,
and serving protocol for reuse. Its test reports do not establish V4.1 or HIP
correctness; do not merge it as if it supplies this implementation. The upstream
maintainer also explains the model-specific scope in
[issue #479](https://github.com/Niko1221/Strata/issues/479).

**Model contract.** Record the following in a typed `DeepSeekV41Config` and an
explicit per-layer plan, validated against checkpoint metadata. Do not retain
`is_qsa_layer()` or infer layer behavior from an interval.

| Component | Required behavior |
| --- | --- |
| Backbone | 40 layers; hidden width 5120; vocabulary 129280; 20 encoder and 20 decoder layers. |
| Attention | 64 heads of width 512; 64 rotary dimensions; query rank 1280; grouped output rank 1024 across 8 groups; local window 128. |
| CSA2 | Backbone compression ratios: layers 0–1: 0; 2–19: 2; 20–39: 1. Global KV sources at 2, 8, 14, 20; index sources at 2, 8, 14, 20, 24, 28, 32, 36. |
| Index selection | 32 index heads of width 128; top 512 positions; decoder candidate source at layer 20 with 2048 blocks of 8 positions. |
| MoE | 384 routed experts, 6 selected, one shared expert; FFN width 2304; square-root-softplus scores, correction bias for selection, normalized unbiased weights scaled by 1.5. |
| Residual and activation | Four mHC streams; single-pass mixing with Sinkhorn; RMS epsilon 1e-20; model-specific SwiGLU clamps. |
| Engram | Layers 1 and 14; compressed tokenizer vocabulary; n-grams through length 4; 8 heads per n-gram size, rows of width 256. |
| DSpark | Three draft layers, block size 5, target layers 37/38/39, 128 draft experts and top-3 routing. |

Source: the pinned
[checkpoint configuration](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/blob/1bae0e1088993b9b82de08f59de5be5a34e42170/config.json).
The official configuration's compression array has 43 entries because it includes
the three draft layers; the selected GGUF records the 40 backbone entries. Accept
the pinned artifact's explicit contract and do not execute draft layers as backbone.

**Memory feasibility and the first artifact.** Strata's execution strategy is
appropriate for this machine: dense weights and hot experts in VRAM, the rest
of the experts in RAM, CPU computation overlapping GPU computation. The complete
model does not need to fit in the approximately 60 GiB of exposed VRAM. With a
small quant, capacity can be kept out of the critical path of initial development.

The published DwarfStar artifacts have the following sizes. Main weights exclude
Engram; routed experts are included in main weights. Sizes are storage values,
not measured process peaks.

| Artifact | Routed experts | Main weights | Engram | Complete language file |
| --- | ---: | ---: | ---: | ---: |
| Q2: IQ2_XXS gate/up + Q2_K down | 142.38 GiB | 151.77 GiB | 188.83 GiB | 340.60 GiB |
| Q4: Q4_K for all routed experts | 284.77 GiB | 294.15 GiB | 188.83 GiB | 482.98 GiB |

Main/file sizes and recipes are from the
[publisher](https://huggingface.co/antirez/deepseek-v4.1-flash-gguf/blob/dd8a266f7145edc19e2334b46e19b6821f221dc7/README.md).
Expert sizes are calculated from 40 × 384 × 3 × 5120 × 2304 weights and the
formats' block sizes (Q2 average 2.25 bits/weight; Q4_K 4.5 bits/weight).

An HTTP range read of the Q2 header confirmed `general.architecture=deepseek41`,
1,046 tensors, and exactly these storage types: 80 IQ2_XXS, 40 Q2_K, 321 Q8_0,
110 F16, 493 F32, and two I8 tensors containing opaque Engram rows. The header
ends at byte 5,828,351 and declares 16,384-byte alignment. It includes the
compressed token map, hash primes and multipliers, and an embedded model config.
The Engram encoding is `e4m3_e8m0_32_row264`: each 264-byte row contains 256 FP8
values and eight scales. These bytes need a row decoder, not an FP8 GEMM backend.

For Q2 bring-up, keep both routed experts and Engram in RAM. Use a provisional
384–416 GiB process budget with bounded scratch and no second full-file copy.
Place dense weights and hot experts on the GPU. The approximately 142 GiB expert
arena is below the recorded approximately 252 GiB amdgpu GTT ceiling, so the
existing pinned-arena approach is worth trying first; keep Engram outside GPU
registration and measure the actual pinning budget. The GPU remains a cache.

For Q4, retain all experts in RAM and use an SSD-backed Engram row cache initially.
The approximately 285 GiB expert store exceeds that recorded GTT ceiling; use
ordinary resident RAM plus bounded pinned transfer buffers, or a capped registered
subset. Account for duplicated GPU cache entries. Engram row prefetch can overlap
the backbone because the row IDs depend on input tokens. Compare RAM-resident
Engram later if the full allocation ledger leaves adequate headroom.

The original official checkpoint's 475.24 GiB was independently verified from
all 48 safetensors headers, but loading that representation is not a prerequisite.
Read the chosen GGUF directly through a validated index where possible; avoid
repacking a second full copy just to change tensor names. Initial tests use 4K–8K
context, one sequence, no drafter and no vision. A small quant reduces capacity
pressure; it does not mean the entire model fits in VRAM.

**Measured Strata speed and a DeepSeek planning estimate.** The most relevant
measurements are the lab's 2026-10-16 runs on these exact cards, v0.1.44.1,
Qwen3.8-Flash-Next UD-Q4_K_XL, greedy, 256 output tokens, three passes:

| Configuration | One V620 | Two V620s, layer split |
| --- | ---: | ---: |
| Decode, no MTP (stage 7 control) | 32.8 t/s | 37.3 t/s |
| Decode, MTP (stage 8) | 49.2 t/s | 59.7 t/s |
| Cold prefill, approximately 23K tokens, MTP loaded | 1,008 t/s | 1,423 t/s |

Source: [the lab record](../qwen38-flash-next/runs/2026-10-16-strata.md).
The two-card code cases reached 70.0–71.2 t/s with MTP; that is a workload-specific
result, not the overall median.

Upstream's current [quant benchmark](https://github.com/Niko1221/Strata/blob/477ac13cbe8e582c20484871ce459d20d82df09d/docs/QUANTS.md)
reports Qwen UD-Q4_K_XL at 63–64 t/s story and 85–88 t/s code on one R9700,
with MTP and all experts in RAM. A
[gfx1030 community run](https://github.com/Niko1221/Strata/blob/477ac13cbe8e582c20484871ce459d20d82df09d/bench/results/2026-10-09-community-2x-rx-6900xt-0.1.41/README.md)
reports 75.7–82.3 t/s on two RX 6900 XTs with IQ3_S and tuned MTP/pipelining.
These are different quantizations and workloads. The 0.1.45 release's large
117.8/183.7 t/s single-request figures concern Qwen3.6-35B-A3B on an R9700,
not Flash-Next or DeepSeek; they are not a V620 upgrade forecast.

For a tuned port on **both V620s**, one request, short-to-medium context, all
experts resident in RAM, the working estimate is **15–30 t/s for Q2** and
**10–20 t/s for Q4**, excluding DSpark. Confidence is low; these are engineering
planning ranges, not measured results, guarantees, or lower bounds. The first
correct implementation can be substantially slower. DSpark may improve them
later, but its benefit is not included or assumed to equal Qwen MTP's gain.

The arithmetic behind the estimate is deliberately simple and inspectable.
Upstream reports about 1.50 GB of routed-expert bytes per token for the Qwen
Q4 artifact. DeepSeek's selected routed matrices are about 2.39 GB/token in Q2
or 4.78 GB/token in Q4. Scaling the lab's 37.3 t/s no-draft result by just this
traffic gives approximately 23.4 and 11.7 t/s. That is an anchor, not a performance
model: dense projections, sparse attention, CPU dequantization, GPU cache hit
rates, routing skew, and overlap differ. In particular, a much larger total expert
pool reduces the fraction that fits in the GPU cache. STREAM's approximately
153 GB/s copy result is not directly the expert kernel's effective bandwidth.

There is also an existing HIP V4.1 implementation worth inspecting for reusable
operators and tests: [Lucebox's V4.1 guide](https://github.com/Luce-Org/lucebox/blob/main/server/docs/DS41.md).
It reports 31.0–48.7 t/s decode with a low-bit quant and DSpark on an R9700 plus
a 192 GB Ryzen AI Max+ PRO 495, with all experts resident. Its hardware, placement,
and bounded-replay policy differ from ours, and gfx1030 is not established by
that report. This supports feasibility, not a transferable throughput claim.
Audit those components before writing equivalent kernels from scratch; it does
not require changing the chosen Strata-based scheduling design.

**Implementation sequence and acceptance gates.** Each item is a separate
reviewable change or small series. Work inside a fork; the user's permission to
drop Qwen supersedes upstream's policy of preserving Qwen defaults. Keep license
notices for reused Strata, ggml, and DeepSeek code.

1. **Freeze references and build numerical fixtures.** Pin the source, checkpoint,
   tokenizer, codec, and compiler/runtime inputs. Add a metadata-only inspector
   that emits the tensor inventory and RAM/VRAM/storage ledger. Build small,
   deterministic reference fixtures with initialized weights for each component,
   using the official Python implementation as the mathematical specification
   and dequantizing the selected GGUF's exact blocks for the test oracle. Use
   small CPU references where the official Triton kernels require other hardware.
   Inspect the existing DwarfStar and Lucebox V4.1 operators and fixtures for
   reusable work, with their licenses retained. Compare implementations of the
   same quant and activation policy; do not require Q2 to match original-checkpoint
   logits or to meet a perplexity/benchmark accuracy threshold.

   Gate: all expected tensors, dtypes, dimensions, scale layouts, and layer
   dependencies accounted for; fixture provenance recorded; target allocations
   fit the proposed hardware budget. This is the first implementation task.

2. **Load the selected Q2 artifact.** Replace the Qwen
   geometry/layout entry points with `DeepSeekV41Config`, `LayerPlan`, and
   explicit `TensorSpec` records. Add a versioned index/manifest containing
   original names, shapes, encoding, offsets, hashes, and model/tokenizer
   revisions. Support this artifact's `deepseek41.*` metadata dialect and tensor
   names. Read the packed GGUF tensors directly, reusing existing IQ2_XXS/Q2_K
   and Q8_0 readers and kernels where valid. Add only the missing dimension and
   model-specific operations. Engram's two opaque I8 tensors need the declared
   row decoder; read the provided hash tables and verify them against reference
   hash fixtures. Honor the declared file alignment.

   Supported initial storage types are exactly IQ2_XXS, Q2_K, Q8_0, F16, F32,
   and the declared Engram row encoding. Q4_K is the next rung. An offline
   converter can later produce these formats from 1017 weights; direct
   safetensors inference, native MXFP4/NVFP4 compute, and other quant formats
   are not required. Keep draft/vision artifacts out of the initial loader.

   Adapt `src/core/weights.cpp`, `expert_source.cpp`, and `expert_cache.cpp` around
   byte spans and explicit layouts. Keep CPU worker queues, direct-file I/O,
   transfer buffers, and cache machinery where their assumptions remain valid.
   Reject Qwen packs and unsupported encodings explicitly.

   Gate: selected real Q2 tensor blocks decode against the reference; complete
   manifests reject missing, overlapping, truncated, mismatched, or foreign
   artifacts; loading has a bounded peak-memory footprint without a duplicate
   mapping/page-cache copy consuming the available headroom.

3. **Implement a correct single-token backbone.** Replace the model-specific
   contents of `src/core/layer.cpp` and `session.cpp`, supported by focused new
   `src/deepseek/` and `include/strata/deepseek/` modules. Implement mHC mixing
   and its carried pre-mix, latent attention projections, compressor, shared
   KV/index state, hierarchical selection, attention sinks, rotary transforms
   and inverse output rotation, grouped output projection, routing, shared
   expert, clamped routed experts, and Engram injection. Match reference ordering
   and precision boundaries, especially routing-weight placement around the
   expert down projection. Define one activation and KV policy shared with the
   quantized reference. Begin with F16/BF16 storage and explicit model-required
   rounding where applicable; physically packed FP4 KV is a later optimization.

   Provide CPU and HIP expert paths for width 5120/FFN 2304. For gfx1030, start
   with supported AVX2/HIP dequantization and FP16/FP32 operations; no
   native FP4/FP8 matrix instruction is assumed. Use bounded dequantization
   scratch for Q2, not persistent BF16 copies of all experts. Validate fused kernels
   only after the unfused operators pass. Keep graph capture and speculation off.

   Gate: operator traces, selected expert IDs, index selections, state updates,
   and full logits agree with the same-quant oracle under documented numerical
   tolerances. Run a short real-model greedy CLI completion with finite logits.
   Linguistic quality can be poor at this stage; apparent fluency is also not
   evidence that the computation is correct.

4. **Add exact chunked prefill and hardware scheduling.** Rebuild
   `src/prefill/prefill.cpp` around the same layer contract as decode. Handle
   compressor partial groups and SWA ring boundaries explicitly. First run all
   40 layers for every prompt token, matching the reference's full-forward path.
   Batch tokens by expert and reuse each fetched expert across its token group.
   Add bounded overlap between CPU misses, GPU cache hits, Engram reads, and DMA.
   Replace Qwen expert profiles and route-tail skipping with conservative
   defaults; collect a new profile from DeepSeek workloads.

   Start with one V620. Add a two-card layer split only with explicit transfer
   and ownership of shared KV/index dependencies. A split at the encoder/decoder
   boundary is a candidate, not an assumed optimum; arbitrary Qwen layer splits
   can strand CSA2 consumers on the wrong device. Expert-helper placement is an
   alternative to benchmark once single-card correctness is established.

   Gate: chunk sizes 1, 2, 3 and larger blocks agree with token-by-token execution,
   including odd compressor boundaries and positions 127/128/129. Benchmark
   short, 4K, and 8K prompts with cold/warm storage and CPU/GPU placement
   controls. Extend to 16K/64K only in later context qualification. Record
   prefill, decode, TTFT, expert hit rates, DMA/SSD bytes, RAM,
   requested/resident VRAM, and DIMM/GPU temperatures. Set performance targets
   from these measurements, not from Strata's Qwen throughput.

5. **Replace conversation encoding and expose the text API.** Preserve the HTTP
   lifecycle, authentication, queues, cancellation, monitoring, and engine IPC.
   Introduce one DeepSeek codec boundary replacing `ChatTemplate`, Qwen-specific
   `OutputParser` behavior, and the handwritten Qwen tokenizer. Prefer the
   official [deepseek-recipe](https://github.com/deepseek-ai/deepseek-recipe/tree/8cadfede7063c896b944e7bae05daa3549ae97ea)
   Python bindings for prompt/token encoding and streaming protocol conversion;
   compare its output with the checkpoint's standalone encoding tests. Pin the
   dependency/build and verify its packaging in the target Linux container.

   Update `serve/frontend.py`, `server.py`, `responses.py`, tokenizer extraction,
   and `src/program/generate.cpp`. Load BOS/EOS/PAD from the artifact; remove
   Qwen stop IDs and model-name fallbacks. Support chat/thinking mode and effort
   integers 1–100 with the reference aliases, rather than Qwen's `xhigh` mapping.
   Preserve the model's DSML tool format and reasoning retention rules across
   tool calls. Validate literal special-token handling separately from framework
   control tokens. Preserve mid-conversation system messages.

   Use temperature 1.0 and top-p 1.0, permitted by the original V4.1 model card,
   as generation defaults; remove inherited Qwen top-k/min-p defaults. Greedy remains the validation
   configuration. Begin with a validated 8K service limit, not the checkpoint's
   advertised 1M maximum. Unsupported image and constrained-generation requests
   must fail clearly until implemented; recipe does not itself enforce JSON
   Schema or tool `strict` constraints.

   Gate: Chat Completions, Messages, and Responses streaming/non-streaming tests;
   tool calls and tool results over multiple turns; stop/cancel/length handling;
   UTF-8 and DSML delimiters split across chunks; correct token usage; no reasoning
   or protocol markers leaking into answer content. Test with a fake engine
   before running the same cases against real weights.

6. **Implement exact session reuse.**
   Replace `SessionState`, `conversation_snapshot.cpp`, `conversation_state.cpp`,
   and associated size/restore checks with owned source KV/index buffers,
   per-layer SWA rings, compressor partial state, Engram token history, and
   explicit positions. Keep scratch selection/candidate state request-local;
   never copy the reference implementation's process-global mutable attention
   object into a concurrent server. Version the cache format and bind it to
   model, tokenizer, quantization, and execution-mode fingerprints.

   Validate full-state save/restore, prefix reuse, cancellation, rollback,
   cache eviction, and interleaved sessions at the initial 8K limit. Account for
   main KV, indexer K, SWA, staging, and activations separately: the model's
   890-byte/token packed global-KV figure is not total service memory and does
   not describe the initial unpacked implementation.

   Gate: cold execution and exact restored execution agree; one session cannot
   affect another; eviction and cancellation leave bounded allocations. Longer
   context and packed KV are optional subsequent work, not Q2 release gates.

7. **Qualify Q2, add Q4_K, and package for this host.** Record single-card and
   two-card Q2 results before changing quantization. Add the matching Q4 artifact's
   Q4_K expert path, keeping its dense tensor precision and Engram contract.
   Validate Q4 against its own dequantized reference; Q4 need not produce Q2's
   output. Support the publisher's split-file distribution without requiring an
   extra full concatenated copy. Q4 expert residency must use ordinary RAM with
   bounded pinned transfers or a capped registered subset; it cannot assume the
   whole expert arena fits under the observed GTT limit. Start with SSD-backed
   Engram and measure its cache behavior.

   Replace installer model menus with the two pinned artifacts and a simple
   host configuration. Update checksums, flags, memory recommendations, help,
   and model/API metadata. Remove unbuilt Qwen GDN/QSA/PLE/MTP paths and obsolete
   tests once replacement coverage exists.
   Keep applicable infrastructure tests. Build and validate only Linux/HIP
   gfx1030 and Zen 2 AVX2; fail explicitly for unsupported backends and formats.
   CUDA, Metal, other AMD targets, and native FP4/FP8 GEMMs are not release work.

   For homelab deployment, create a separate launcher/env/unit and model artifact
   directory. Integrate the existing GPU ownership, thermal watchdog, and engine
   switch procedures when deployment is actually requested. Qualify service
   restart, model readiness, shutdown/cancellation, RAM limits, and recovery.
   Gate: publish reproducible Q2/Q4 prefill, decode, TTFT, memory and cache results
   on this host, with model/quant/context/draft status explicit. Qualify the Q2
   text release after gates 1–6 and its packaging checks; Q4 follows after the
   same checks pass with its new loader, kernels, and memory policy.

8. **Optional work after the measured Q2/Q4 text service.** Prioritize these from
   observed bottlenecks rather than treating them as prerequisites:

   - Physically packed main KV (E2M1 with E4M3 scales per 16 channels), preserving
     values already emulated by the correctness path. Compare packed/unpacked
     representations at their quantization boundary. Raise context through
     measured 16K/64K and then 128K/256K before attempting 1M.
   - Encoder/decoder SWA bounded replay. The
     [technical report, §3.2.2](https://arxiv.org/html/2609.19969v1#S3.SS2.SSS2)
     explicitly describes it as approximate: replaying 128 tokens does not
     recreate a full decoder prefill exactly. Preserve global KV, include replay
     policy in cache identity, and compare against the exact control. This
     optimization introduces a separate accuracy/performance tradeoff; accepting
     Q2 quantization loss does not automatically validate replay errors.
   - DSpark. Replace Qwen's MTP pack/fetch path, draft state, and verification.
     Implement three draft layers, captured hidden states, noise positions,
     Markov/confidence heads, scheduling, and rollback. The reference supplies
     `forward_spec`, not a complete speculative generation loop. Greedy output
     must match the non-speculative control under the same numerical policy;
     exact sampled speculation additionally needs a correct acceptance algorithm
     and distribution tests. Enable only if measured latency improves.
   - Vision. Add DeepSeek-ViT, its aligner, image-span embeddings and token
     expansion, visual routing bias, and Engram history boundaries. Include
     image content/preprocessing in prefix identities and verify against the
     reference before accepting image requests.
   - Other hardware, including CUDA. Add a backend only when there is a concrete
     target and a way to validate it. Do not maintain untested compatibility now.

The principal uncertainties are gfx1030 expert throughput at the larger matrix
sizes, effective CPU bandwidth and GPU cache hit rate, cross-card shared attention
state, and Q4's Engram random-read latency. Q2's published 340.60 GiB file makes
the existing 512 GB host a credible development target without model-capacity
experiments dominating bring-up. Its process peak and speed still need measurement.
Strata's hybrid scheduling is the part to retain; the model execution graph must
be ported. The next task is the pinned Q2 tensor ledger and same-quant component
oracle, followed by one real DeepSeek block on AVX2/HIP and then full-model decode.
