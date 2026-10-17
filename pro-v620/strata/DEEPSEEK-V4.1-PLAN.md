# Strata → DeepSeek-V4.1-Flash: fork implementation plan

Plan finalized 2026-10-17. **First of two separate forks: DeepSeek proceeds first;
MiMo is second and its implementation remains deferred.**
This is a plan for **local inference**, using a DeepSeek-only fork of Strata.
Dropping Qwen compatibility simplifies the implementation, but
the work still includes a new model execution path. Keep Strata's useful systems
infrastructure and replace the Qwen mathematics, artifacts, and conversation
format. Avoid building a general multi-model framework as part of this port.

The hardware target is exclusively the existing ROMED8-2T host: EPYC 7532
(Zen 2 / AVX2), approximately 503.6 GiB usable RAM, two V620s (gfx1030) with
30,704 MiB exposed VRAM each, and NVMe model storage. Use the already working
Linux/HIP/ROCm 10.0 environment. Those are recorded values, not a fresh host
inspection. Development and tests run in CT 124 `strata-dev` on GPU 2
([development container plan](../strata-dev/PLAN.md)), whose memory limit fits the Q2
budget below. See the [host fit notes](../mimo-v26-pro/README.md) and
[current Strata installation](README.md).

Scope clarified by the owner on 2026-10-17: start with a small quantization to
remove capacity pressure, aim for approximately 4-bit weights eventually, and
support only this hardware. The first deliverable is text inference on the
pinned Q2 artifact at short context, one request at a time. Then add the text/tool
API, performance tuning, and Q4. All of that works on one V620 before any two-card
work starts. CUDA, other GPU generations, other operating systems, vision, and
DSpark are outside the first release. There is no requirement to implement native
FP4/FP8 GPU arithmetic or a catalog of weight formats.
The Q2 release uses exact full-forward prefill; approximate SWA bounded replay
requires its own later acceptance and cache identity. One 8K slot is the release
target. Two isolated 8K slots are a later qualification target, not a release gate.
Reuse HTTP admission/queueing, but exclude inherited Qwen multi-slot execution
and `--parallel > 1` until DeepSeek state ownership and batching pass dedicated tests.

Initial correctness means agreement with a reference using the **same quantized
weights**. Quantization's loss of model accuracy is accepted for bring-up; a
quality comparison with the original checkpoint is not an implementation gate.
Numerical bugs, wrong routing, missing layers, and state corruption still need
to be caught. No implementation or deployment has been performed during this review.

**Sources and reproducibility.** The reviewed Strata main commit is
[`477ac13cbe8e582c20484871ce459d20d82df09d`](https://github.com/Niko1221/Strata/tree/477ac13cbe8e582c20484871ce459d20d82df09d).
This is also the commit behind the reviewed
[v0.1.45 release](https://github.com/Niko1221/Strata/releases/tag/v0.1.45), published
2026-10-17. The lab measurements below used v0.1.44.1. Choose the reviewed commit
as the frozen development baseline; do not track `main`. Pin its dependencies too,
including ggml `3cf03257f219afbe7334045ff7c6a06ac68c627d`.

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
originally reviewed at `6e326aab2f9679d34be36020fd1a8d7021c8ccce`. It adds a separate
`dsv4_ext` engine targeting the older V4 model. Its README describes 43 layers and
256 experts, unlike V4.1. Evaluate its dequantization utilities, tiny fixtures,
and serving protocol for reuse. The PR author reports Ubuntu/CUDA testing; a
separate Windows/CUDA report at `6f9382f` found missing `dq_traits.hpp` scalar
definitions and about 0.26 logit error for GPU prefill chunks of two or more.
Those are historical failures to regression-test, not verified defects in every
later head. The API resolved the head to `bd6fc62a377acb06fc5fb1d800262a4e6731a935`
on 2026-10-17; re-check and pin any reused code at step 1. Its
chunking, ring snapshots and summation order merit inspection before step 4.
No cited report establishes V4.1, HIP or multi-GPU correctness; do not merge it
as if it supplies this implementation. The upstream
maintainer also explains the model-specific scope in
[issue #479](https://github.com/Niko1221/Strata/issues/479).

**Model contract.** Record the following in a typed `DeepSeekV41Config` and an
explicit per-layer plan, validated against checkpoint metadata. Do not retain
`is_qsa_layer()` or infer layer behavior from an interval.

| Component | Required behavior |
| --- | --- |
| Backbone | 40 layers; hidden width 5120; vocabulary 129280; 20 encoder and 20 decoder layers. |
| Attention | 64 query heads of width 512; one compressed KV head; no attention bias; 64 rotary dimensions; query rank 1280; grouped output rank 1024 across 8 groups; local window 128. |
| RoPE / YaRN | `rope_theta=10000`, `compress_rope_theta=160000`; YaRN factor 16, original context 65536, beta-fast 32 / beta-slow 1; maximum position 1048576. Apply the reference's per-layer frequency policy, including at short context. |
| CSA2 | Backbone compression ratios: layers 0–1: 0; 2–19: 2; 20–39: 1. Global KV sources at 2, 8, 14, 20; index sources at 2, 8, 14, 20, 24, 28, 32, 36. |
| Index selection | 32 index heads of width 128; top 512 positions; decoder candidate source at layer 20 with 2048 blocks of 8 positions. |
| MoE | 384 routed experts, 6 selected, one shared expert; FFN width 2304; square-root-softplus scores, correction bias for selection, normalized unbiased weights scaled by 1.5. |
| Residual and activation | Four mHC streams; single-pass mixing with 20 Sinkhorn iterations and `hc_eps=1e-6`; RMS epsilon 1e-20; `swiglu_limit=10.0` (up clamped both ways, gate above only), including the shared expert. |
| Engram | Layers 1 and 14; compressed vocab 99092, pad ID 2; n-grams through length 4; 8 heads per n-gram size, width 256. Table rows 384006168 / 384016682, each 264 bytes, totaling 188.83 GiB. |
| DSpark (deferred) | Three draft layers, block size 5, target layers 37/38/39, 128 draft experts and top-3 routing; noise token ID 128799; Markov rank 256. |

Source: the pinned
[checkpoint configuration](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/blob/1bae0e1088993b9b82de08f59de5be5a34e42170/config.json).
The official configuration's compression array has 43 entries because it includes
the three draft layers; the selected GGUF records the 40 backbone entries. Accept
the pinned artifact's explicit contract and do not execute draft layers as backbone.

The pinned [attention implementation](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/blob/1bae0e1088993b9b82de08f59de5be5a34e42170/inference/model.py)
applies YaRN when the compressed-attention path has a nonzero original context;
pure SWA layers disable it. The value 65536 is a frequency-construction parameter,
not a token-position switch. Test both paths below 8K as well as at later context
boundaries; postponing all YaRN work until long-context qualification is incorrect.

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
Keeping Engram resident deliberately differs from DwarfStar's SSD row-streaming
policy: it spends RAM to simplify early execution. Benchmark token-derived row
reads on the local NVMe in step 1 (cold/warm latency, bytes and bounded prefetch),
so Q4's SSD-backed policy is tested before the final milestone.
Place dense weights and hot experts on the GPU. The approximately 142 GiB expert
arena is below the recorded approximately 252 GiB amdgpu GTT ceiling, so the
existing pinned-arena approach is worth trying first; keep Engram outside GPU
registration and measure the actual pinning budget. The GPU remains a cache.

For Q4, retain all experts in RAM and read Engram rows from the NVMe through a
bounded row cache. Q4 cannot also keep Engram resident: its routed experts and
Engram alone are 284.77 + 188.83 = 473.6 GiB, against approximately 503.6 GiB of
host RAM, before dense weights, KV, scratch, runtime and a host reserve.
The approximately 285 GiB expert store exceeds that recorded GTT ceiling; use
ordinary resident RAM plus bounded pinned transfer buffers, or a capped registered
subset. Account for duplicated GPU cache entries. Engram row prefetch can overlap
the backbone because the row IDs depend on input tokens.

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

**Fork maintenance and validation.** Use `ModelFamily::DeepSeekV41` and focused
`src/deepseek/` modules, following upstream's per-family engine pattern. Adapt
shared plumbing at narrow boundaries instead of rewriting shared files wholesale.
Qwen support is not a product requirement; retain it only as needed to qualify the
base/donor, then remove unused model paths after replacement coverage exists.
Maintain `docs/FORK-PATCHES.md` in the fork with its base/dependency pins, changed
upstream files and reasons. The implementer checks each upstream release touching
HIP, kernels, memory or serving, and before each release candidate; port relevant
correctness/security fixes promptly. Change the frozen base only in a separate
reviewable update that reruns CPU, gfx1030 and service gates. Offer generic loader,
session-versioning and dispatch fixes upstream without coupling the two model forks.

The fork is a private repository under the owner's account. An OpenCode agent writes,
builds and tests it in CT 124 under `/opt/strata-ds41/`, on GPU 2 with no serving
process on the card. Add an x86-64 AVX2 CPU-only GitHub Actions build and small
deterministic fixtures on every pull request, without full model downloads; a private
repository has limited Actions minutes. In the fork, provide one documented
`tools/deepseek/validate-gfx1030.sh` entry point for CT 124: device enumeration,
required operator/loader/prefill/session fixtures and scratch-boundary checks.
Run CPU scratch tests under supported address/undefined-behavior sanitizers and
device fixtures with guard checks. List inherited WMMA/hipBLASLt/AVX-512 skips;
PLE fixtures are removed with PLE, not substituted for Engram tests. No required
DeepSeek test may silently skip. Record reference revision, seed, activation policy,
error metric and predeclared tolerance in `tests/deepseek/tolerances.json` with a
README explaining reference repeatability and CPU/GPU deltas. These are proposed
fork deliverables, not existing commands or tests in this repository.

**Lab integration and campaign safety.** `../strata-dev/strata-dev-host.sh` moves
the cards: `dev` gives GPU 2 to CT 124 with Flash-Next stopped, `two-card` adds GPU 1
with CT 120 stopped, and `restore` returns both. It changes passthrough, `/dev/kfd`,
DRM cgroups, autostart and the watchdog map together. Steps 0–7 run on GPU 2 alone,
for Q2 and then Q4; two-card work waits for step 8, which keeps whole-host runs to
one-card measurements and that step. The owner decides when each is due. Step 7
packages the qualified engine for CT 123 as unit/env
`strata-ds41` with launcher `strata-serve-ds41`, extending `use-engine.sh` with an
engine root and unit. Size CT 124's memory limit from step 1's peak allocation ledger
plus container overhead, keeping the running guests' limits and a host reserve within
host RAM; 488 GiB is not a fixed DeepSeek requirement. Set `--memory-limit-mib`
below the CT limit by the declared container reserve; the existing 118784 MiB
launcher default is inappropriate.
Before a full load, fix the host minimum-MemFree and CT runtime-reserve thresholds
in the campaign record. Reject a configuration with swap, expert paging, VRAM
spill, or a breached reserve; do not count resident file-backed experts as free
just because MemAvailable includes reclaimable pages.

The EPYC has 32 physical cores / 64 threads (siblings n/n+32). A random 48-CPU
set can omit physical cores; use explicit `TEST_CPUSET` and measure worker count
and affinity with the actual expert widths. The MiMo baseline used about 30 busy
cores with 32 pinned workers; Flash-Next's smaller allocation peaked near 16 in
STREAM. Neither is a DeepSeek worker default.

Each campaign's Safety section must requalify the inherited
[gfx1030 constraints](README.md#known-gfx1030-issues-upstream):
`STRATA_HIP_ADAPT_KERNEL_COPY=1` for #884, `STRATA_HIP_PROMPT_F16`,
`STRATA_SH_STREAM` where shared experts apply, `STRATA_MMQ_KQ`, #2457's corruption
regression class and #1103's ROCm runtime issue. Preserve the ROCm 10.0 pin until
qualified; dense GEMMs use rocBLAS, not unavailable gfx1030 WMMA/hipBLASLt paths.
Do not assume Qwen switches retain either meaning or speed gains in the new engine.
Record the 10 s setting from `../amdgpu-lockup-timeout.sh`, the ROMED8-2T thermal
guard, watchdog ownership, `vram-residency-sampler.py`, `vram-release-trace.sh`,
and `capture-env.sh`. DIMM risk analysis/new thermal gates are excluded by the
recorded owner decision; retain existing guard behavior and DIMM telemetry.

Use [TEST-RECORDS.md](../TEST-RECORDS.md), committed plans, `push-harness.sh`,
`environment.json`, and adapted `strata-sweep.sh`/probes. Campaigns before step 8
use GPU 2 alone; record why CPU-only or resource-saving arms are omitted if not useful.
DSpark exists but is deferred until its own implementation; quote no-draft controls
and explain that exclusion. Revalidate cold requests/token counting tracked by
[#112](https://github.com/marchah/Proxmox/issues/112) before usage benchmarks, and
check the Hermes provider against the endpoint before a deployment decision.
`strata-dev-host.sh restore` returns the saved Flash-Next engine, device ownership,
limits and watchdog map; DeepSeek need not run in llama.cpp for that restore to work.
Other guests stay off after a campaign until the owner asks to start them.
Model-store capacity remains owner-managed; retain pinned downloads and SHA-256
verification (`.verified`), without a storage-capacity planning gate.

**Storage format × execution path audit.** Step 1 fills in exact source symbols,
fixture IDs and peak scratch for this matrix; these are required paths, not claims
that upstream already implements them. Audit GGUF reading, CPU dot traits and HIP
decode **and** prompt paths separately, including CPU activation-width rejection,
`native_expert`/worker-array caps and MMVQ dispatch.

| Storage type (Q2 count) | GGUF contract | CPU path to qualify | gfx1030 path to qualify | Scratch / bounded fallback |
| --- | --- | --- | --- | --- |
| IQ2_XXS (80) | Gate/up block reader | Pinned ggml dot/dequant at width 5120 | Decode and grouped prompt dispatch | Geometry-sized activation buffers; tile dequant + BLAS |
| Q2_K (40) | Down block reader | Pinned ggml dot/dequant at width 2304 | Decode and grouped prompt dispatch | Audit 5120×2304 matrices in both orientations; tile dequant + BLAS |
| Q8_0 (321) | Dense/shared/output blocks | ggml dot/dequant at actual tensor shapes | MMVQ and prompt GEMM | Bound dense conversions; tile dequant + rocBLAS |
| F16 (110), F32 (493) | Typed spans and shapes | Typed operators / reference BLAS | HIP operators / rocBLAS | Ledger covers actual dimensions; unfused bounded reference path |
| I8 Engram (2) | Opaque row264 bytes, not signed-int8 weights | e4m3/e8m0 row decode | Upload decoded rows; native row decode optional | Bounded row batches outside expert pinning; CPU decode fallback |

Enter step 2 with every path and fallback assigned; complete it only after real
block decode and the bounded reference execution paths pass. Native fast kernels
can follow in steps 3–4. Missing support is implementation work, not permission to
silently re-quantize the selected artifact or claim all six types already work.

**Implementation sequence and acceptance gates.** Each item is a separate
reviewable change or small series. Work inside a fork; the user's permission to
drop Qwen supersedes upstream's policy of preserving Qwen defaults. Keep license
notices for reused Strata, ggml, and DeepSeek code.

0. **Qualify the frozen base before porting.** Build v0.1.45 / `477ac13` in CT
   124, separately from CT 123's installed v0.1.44.1. Run the existing Flash-Next
   UD-Q4_K_XL yardstick and chat/tool gates from the 2026-10-16 record on the same
   card/configuration.
   Gate: no correctness regression, and any speed/memory change explained. Keep
   the installed service as the restore target; this is not an automatic upgrade.

1. **Freeze references and build numerical fixtures.** Pin the source, checkpoint,
   tokenizer, codec, and compiler/runtime inputs. Add a metadata-only inspector
   that emits the tensor inventory and peak RAM/VRAM/pinned-memory ledger. Build small,
   deterministic reference fixtures with initialized weights for each component,
   using the official Python implementation as the mathematical specification
   and dequantizing the selected GGUF's exact blocks for the test oracle. Use
   small CPU references where the official Triton kernels require other hardware.
   Inspect the existing DwarfStar and Lucebox V4.1 operators and fixtures for
   reusable work, with their licenses retained. Compare implementations of the
   same quant and activation policy; do not require Q2 to match original-checkpoint
   logits or to meet a perplexity/benchmark accuracy threshold.

   Resolve llama.cpp support for this exact `deepseek41` metadata and Engram
   encoding at a pinned commit. If supported, capture same-quant no-draft
   correctness and performance baselines, matching context per slot (Strata is
   per slot; llama.cpp's total is shared). If unsupported, record that outcome;
   retain independent initialized same-quant fixtures and a bounded CPU oracle
   for selected real-model layer traces/logits. Do not infer that the fork is the
   only possible runtime. Inspect/pin DwarfStar and Lucebox reuse candidates and
   complete the format/path audit and early Engram row-read experiment.

   Gate: all expected tensors, dtypes, dimensions, scale layouts, and layer
   dependencies accounted for; fixture provenance recorded; target allocations
   fit the proposed hardware budget; for each component, a recorded decision to
   port Lucebox's HIP V4.1 operators or DwarfStar's, or to write it, with the reason. The campaign must record a numerical usable
   decode/TTFT threshold agreed with the owner before performance qualification
   if no same-quant engine baseline exists; the 15–30 t/s forecast is not that
   threshold. This does not block metadata/fixture development now.

2. **Load the selected Q2 artifact.** Replace the Qwen
   geometry/layout entry points with `DeepSeekV41Config`, `LayerPlan`, and
   explicit `TensorSpec` records. Add a versioned index/manifest containing
   original names, shapes, encoding, offsets, hashes, and model/tokenizer
   revisions, including Engram pad ID and compressed-vocabulary/hash identities.
   Support this artifact's `deepseek41.*` metadata dialect and tensor
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

3. **Implement a correct single-token backbone.** Route the model-specific
   execution through narrow hooks in `src/core/layer.cpp` and `session.cpp`, with new
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
   and full logits agree with the independent same-quant oracle under documented numerical
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

   Run on one V620 (GPU 2). Two-card placement waits for step 8.

   Gate: chunk sizes 1, 2, 3 and larger blocks agree with token-by-token execution,
   including odd compressor boundaries and positions 127/128/129. Benchmark
   short, 4K, and 8K prompts with cold/warm storage and CPU/GPU placement
   controls. Extend to 16K/64K only in later context qualification. Record
   prefill, decode, TTFT, expert hit rates, DMA/SSD bytes, RAM,
   requested/resident VRAM, and DIMM/GPU temperatures. Evaluate performance
   against the predeclared decision below; use these measurements
   to select optimizations, not to move the acceptance threshold after the run.

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
   Add family-specific state behind `SessionState`, `conversation_snapshot.cpp`,
   `conversation_state.cpp`, and associated size/restore checks: owned source
   KV/index buffers, per-layer SWA rings, compressor partial state, Engram token history, and
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

7. **Qualify Q2, add Q4_K, and package for this host.** Everything in this step
   runs on GPU 2 alone. Record Q2 results before changing quantization. Add the
   matching Q4 artifact's
   Q4_K expert path, keeping its dense tensor precision and Engram contract.
   Validate Q4 against its own dequantized reference; Q4 need not produce Q2's
   output. The publisher's Q4 files are binary transport parts of one GGUF, not
   standalone GGUF shards. Provide a validated virtual byte-span reader across
   parts (including cross-part reads and whole-file identity) or an in-place
   verified join; avoid retaining a second complete copy. Q4 expert residency must
   use ordinary RAM with bounded pinned transfers or a capped registered subset; it cannot assume the
   whole expert arena fits under the observed GTT limit. Start with SSD-backed
   Engram and measure its cache behavior.

   Replace installer model menus with the two pinned artifacts and a simple
   host configuration. Update checksums, flags, memory recommendations, help,
   and model/API metadata. Remove unbuilt Qwen GDN/QSA/PLE/MTP paths and obsolete
   tests once replacement coverage exists.
   Keep applicable infrastructure tests. Build and validate only Linux/HIP
   gfx1030 and Zen 2 AVX2; fail explicitly for unsupported backends and formats.
   CUDA, Metal, other AMD targets, and native FP4/FP8 GEMMs are not release work.

   Finish the `strata-ds41` launcher/env/unit and model artifact directory, using
   the shared test/switch plumbing established before full-model tests. Update
   the root README inventory and CLAUDE.md's "Where to look" when the service is
   installed. Qualify service
   restart, model readiness, shutdown/cancellation, RAM limits, and recovery.
   Gate: publish reproducible one-card Q2/Q4 prefill, decode, TTFT, memory and
   cache results on this host, with model/quant/context/draft status explicit.
   Qualify the Q2 text release after gates 1–6 and its packaging checks; Q4
   follows after the same checks pass with its new loader, kernels, and memory
   policy.

8. **Add the second card.** Start only after Q2 and Q4 pass every one-card gate
   above; the owner sets up these runs, which stop CT 120. Add a two-card layer
   split only with explicit transfer and ownership of shared KV/index
   dependencies. A split at the encoder/decoder boundary is a candidate, not an
   assumed optimum; arbitrary Qwen layer splits can strand CSA2 consumers on the
   wrong device. Expert-helper placement is an alternative to benchmark.

   Gate: two-card traces and logits agree with the one-card path under the same
   tolerances, with no state divergence or unbounded duplication. Measure each
   quant against its own one-card result, interleaved, and keep two cards only
   where they improve on one.

9. **Optional work after the measured Q2/Q4 text service.** Prioritize these from
   observed bottlenecks rather than treating them as prerequisites:

   - Two 8K slots. Reuse upstream admission and batch scheduling only after the
     DeepSeek adapter passes interleaved-session, cancellation and shared-state
     ownership tests. Compare lone-request latency with aggregate throughput;
     keep one slot as the default unless the measured workload benefits.
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

**Performance decision and risk register.** Correctness gates always apply.
With a runnable same-quant llama.cpp baseline, retain the fork as a serving
candidate only if at least three interleaved passes show an improvement beyond
the observed spread on the predeclared primary workload, while meeting its
TTFT/memory limits. Without that baseline, judge the fixture-qualified fork
against the owner's predeclared usable decode/TTFT thresholds. A cross-model
Flash-Next comparison and the 23.4 t/s traffic anchor cannot substitute for either
gate. If a gate fails after the bounded optimization campaign, retain the existing
deployment and document the result before funding optional features. Qualify Q2
and Q4 independently; failing Q4 does not invalidate a qualified Q2 release.

| Unknown | Measurement | Fallback | Stop / scope limit |
| --- | --- | --- | --- |
| Format support and 5120×2304 expert throughput | Step-1 path audit; AVX2/HIP real-block fixtures and microbenchmarks | Bounded tile dequantization + BLAS | No full-model milestone without correct, bounded paths; no promotion if final workload gate fails |
| Host service time, affinity and overlap | Worker/cpuset sweep, per-phase CPU time, transfer stalls | Smaller worker pool and conservative serialized scheduling | Reject configurations that breach reserves; stop tuning at the campaign's decision gate |
| Expert cache locality | Per-layer route traces, held-out hit rate, CPU bytes and cache-refresh bytes | Static measured placement, CPU misses | Do not budget gains from unmeasured hits; drop adaptations whose total latency regresses |
| Shared attention across cards | Source/consumer ownership traces and one-card/two-card parity | One card or bounded host transfers | No two-card release with state divergence or unbounded duplication |
| Engram row latency / Q4 fit | Early cold/warm NVMe probe; peak RAM and pinned-memory ledger | Bounded prefetch/cache, capped registration, retain Q2 | Defer Q4 if its memory or workload gate fails; intentional Engram reads are distinct from expert paging |
| Numerical or session divergence | Independent layer/logit fixtures, chunk parity, save/restore and cancellation | Unfused exact path and cold recomputation | Block the affected milestone; fluent output cannot waive it |

The next work is base qualification followed by the pinned Q2 tensor ledger,
path audit and same-quant component oracle. Full-model performance remains an
implementation measurement, not a result established by this plan.
