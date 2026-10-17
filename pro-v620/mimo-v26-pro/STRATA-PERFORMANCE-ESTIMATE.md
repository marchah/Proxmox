# MiMo on Strata: performance estimate for the two V620s

2026-10-17. These are planning estimates for a completed and tuned MiMo backend, not
measurements of a working Strata/MiMo implementation. The actual implementation sequence
is in [STRATA-REFACTOR-PLAN.md](STRATA-REFACTOR-PLAN.md).

The machine is an EPYC 7532, eight DDR4-3200 channels, 503.6 GiB usable host RAM, and two
30,704 MiB Radeon Pro V620s on CPU-direct PCIe 4 x16 slots. Target Linux/ROCm 10.0/gfx1030
and the AVX2 CPU path. CUDA and other hardware are deferred.

## Planning numbers

Use **approximately 10 output tokens/s for the four-bit target** as the working objective.
An optimized backend with useful expert caching and MTP could plausibly reach the ranges
below. They are conditional engineering targets, not statistical confidence intervals or
minimum guarantees. An initial correct implementation may run slower than llama.cpp.

| Configuration | Decode after short prompts | Decode at about 8k context | Cold prefill around 8k |
| --- | ---: | ---: | ---: |
| Measured llama.cpp b11583, MXFP4, MTP n-max 1 | 6.35 t/s | 5.17 t/s | 28.3 t/s |
| Estimated tuned Strata/MiMo, MXFP4, MTP | 8–12 t/s | 6–10 t/s | 60–120 t/s |
| Estimated tuned Strata/MiMo, smaller mixed Q2_K, MTP | 10–15 t/s | 8–12 t/s | 70–150 t/s |

The smaller-quant and prefill estimates have lower confidence. There is no local Q2_K
runtime baseline yet. A four-bit result around 15–20 t/s is an optimistic outcome requiring
much better cache locality, CPU expert throughput or multi-token weight reuse than assumed
in the central case; it should not be the project commitment. There is no evidence here
supporting an expectation of 50–60 t/s for this MiMo model on these cards.

## Measurements already available on this machine

The [MiMo baseline](runs/2026-10-15-baseline.md#conclusion) used the ggml-org native MXFP4
trunk on both V620s, three interleaved passes, code/prose/list prompts, 256 generated tokens:

| Metric | Without speculation | Q8_0 MTP, n-max 1 |
| --- | ---: | ---: |
| Short-context decode, median over classes | 4.74 t/s | 6.35 t/s |
| Decode at 8k depth, median over classes | 4.54 t/s | 5.17 t/s |
| Prefill at 8k, prose | 28.9 t/s | 28.3 t/s |
| Two concurrent streams, aggregate decode | 6.92 t/s | 7.78 t/s |

No-speculation decode used about 30 CPU cores; card 1 drew 60 W and card 2 22–23 W. MTP
decode drew about 49–50 W and 35 W. At 8k prefill card 1 drew 66–73 W and card 2 was idle
at about 6 W. The expert store read nothing during the qualified runs, and requested VRAM
remained resident. The opportunity is compute scheduling, transfers and kernel efficiency;
the qualified baseline was not suffering ongoing SSD paging. Low power suggests headroom,
but power ratios are not speedup multipliers.

The [Flash-Next Strata comparison](../qwen38-flash-next/runs/2026-10-16-strata.md#conclusion)
is particularly relevant because it used these same cards and CPU:

| Engine / cards | Median decode | Cold prefill d8000 | Cold prefill d32000 |
| --- | ---: | ---: | ---: |
| llama.cpp, one V620 | 18.2 t/s | 358 t/s | 340 t/s |
| Strata v0.1.44.1, one V620 | 49.2 t/s | 989 t/s | 1,008 t/s |
| Strata v0.1.44.1, two V620s | 59.7 t/s | 964 t/s | 1,423 t/s |

All three used Flash-Next UD-Q4_K_XL with their selected MTP settings. The one-card decode
improvement is 2.70x. The 3.27x two-card comparison also changes the GPU allocation; it is
not a pure software multiplier. Two Strata cards beat one Strata card by about 21% with MTP.
These records used workload labels d8000/d32000 whose actual Flash-Next token counts were
about 5.8k/23k; do not equate their literal prompt lengths with the MiMo 8k probe.

## Latest upstream numbers checked

[v0.1.45](https://github.com/Niko1221/Strata/releases/tag/v0.1.45) was published on
2026-10-17 at 06:53 UTC. The fetched source head remains
`477ac13cbe8e582c20484871ce459d20d82df09d`.

Its [Qwen3.6 measurements](https://github.com/Niko1221/Strata/blob/477ac13cbe8e582c20484871ce459d20d82df09d/docs/QWEN36.md)
on one R9700 32 GB, UD-Q4_K_XL, with the main experts resident in VRAM, report:

- Decode without MTP: 117.8 t/s, versus 81.9–82.1 for llama.cpp.
- MTP decode over ten greedy prompts: 183.7 t/s; the documented llama.cpp comparison is
  129 t/s from an earlier run, not the same paired test as the first figure.
- A 4k prompt: 6,220 t/s with chunk 4096, versus llama.cpp's 3,794 with its best tested
  micro-batch. Chunk sizes differ and are part of the comparison.

The latest [Flash-Next quant table](https://github.com/Niko1221/Strata/blob/477ac13cbe8e582c20484871ce459d20d82df09d/docs/QUANTS.md)
still reports UD-Q4_K_XL at 63–64 t/s on a short story, 85–88 on code, 70–72 after a 6k
document and 1,110–1,320 t/s on a 32k prompt, on an R9700 plus EPYC 7452. Those measurements
are attached to that table's older engine setup; they are not new v0.1.45 V620 measurements.

Qwen3.6 is a 35B/3B-active model, and RDNA4 has capabilities absent on gfx1030. Those
headline figures demonstrate optimization potential but are not MiMo forecasts. The local
Flash-Next comparison carries more weight for this hardware.

## Why a speedup is plausible, and why it is smaller than the Flash-Next multiplier

Strata can retain the experts actually used most, run GPU hits alongside CPU misses, group
verification rows to reuse weights, and amortize prefill transfers over larger batches. The
MiMo run's idle GPU capacity and CPU-heavy decode make these reasonable directions.
llama.cpp already has GPU prompt offload, MTP and prefix reuse here; the forecast does not
count those features as wholly new gains.

The biggest difference is cache coverage. On Flash-Next, the two-card Strata test stored
16,220 of 24,576 experts and reported a 97.5% median decode hit rate. MiMo has 26,496 routed
experts, each 19.125 MiB in MXFP4. Its complete pool is 494.86 GiB. After approximately
20.4 GiB of GPU non-expert weights, KV, MTP, scratch and reserves, an illustrative 25–30 GiB
expert budget holds only about 1,339–1,606 experts, roughly 5–6% of that pool. The actual
budget must be measured; hit rate can exceed storage fraction if routing is concentrated.

Before caching, MiMo's selected routed weights total 10.31 GiB per target token. The dense
GPU weights also have to be read/computed. That mandatory work is much larger than
Flash-Next's, so its 97.5% hit rate and 59.7 t/s cannot be carried over.

Applying the local 3.27x gain blindly would predict 20.8 t/s short-context and 17.0 t/s at
8k for MiMo. This is a useful optimistic scenario to test, not the central expectation.
The same local memory bandwidth does not turn into the same effective expert throughput;
measure MiMo's MXFP4 and Q2_K CPU kernels at their actual widths.

## Transparent sensitivity model

The following deliberately simple model starts from measured MiMo no-speculation time,
not from Qwen throughput:

```
T0 = 1 / 4.74 = 211 ms per target token
h0 = 3 / 69 = 4.35%   # three whole expert layers on GPUs in the no-spec baseline
Tnew = T0 × [f + (1-f) × (1-h)/(1-h0) / s]
decode_with_MTP = m / Tnew
```

Here `h` is the fraction of routed expert work served from VRAM, `s` is the improvement
in the remaining host-expert service time (CPU efficiency and scheduling), and `m` is the
net MTP multiplier including draft and verification costs. `f=0.30` is an assumed unchanged
time fraction for dense work, attention, synchronization and other costs. It is not a
measured profile of MiMo. Cache transfer/compute costs are simplified into the scenarios;
the model is not a hardware simulator and does not predict every interaction.

| Scenario | Assumed VRAM hit fraction | Assumed host-service improvement | Assumed net MTP gain | Derived short-context rate |
| --- | ---: | ---: | ---: | ---: |
| Modest improvement | 15% | 1.10x | 1.20x | about 6.6 t/s |
| Central | 30% | 1.30x | 1.35x | about 9.2 t/s |
| Strong | 40% | 1.50x | 1.50x | about 12.0 t/s |

For comparison, local MiMo MTP currently improves decode 1.34x at short context and only
1.14x at 8k; local Flash-Next Strata MTP improved it about 1.60x on two cards. The central
MiMo target therefore assumes better basic execution, with a familiar short-context MTP
gain. It does not require a novel drafter. Its long-context estimate is lower because the
local MTP acceptance and benefit fall with depth.

With the model above, 15–20 t/s would need roughly 60–80% cache hits if host service improves
1.5x and MTP gives 1.6x, or compensating gains elsewhere. That is much more demanding than
the central assumptions given a 5–6% resident capacity. Broad uncertainty remains: a poor
MXFP4 kernel or little locality can leave the fork near or below the current engine.

Prefill's 60–120 t/s target is a rough 2–4x improvement over 28.3 t/s, informed by the
local Flash-Next prefill gains and MiMo's low prefill GPU utilization. It is less constrained
than the decode estimate: actual transfer bandwidth, chunk size, MoE grouping and FP16
compute must be profiled before narrowing it. At that rate a cold 8k prompt takes about
67–133 seconds to read, versus approximately 283 seconds now, excluding other TTFT costs.

## Smaller quant and narrow format support

Use [ggml-org's Q2_K build](https://huggingface.co/ggml-org/MiMo-V2.6-Pro-RL-GGUF) for the
first backend. It is approximately 390 GiB, versus approximately 516 GiB for MXFP4, and
leaves about 98 GiB below CT 123's baseline 488 GiB limit even before offloading weights.
This avoids making exclusive RAM/VRAM ownership the first engineering problem. Bounded
staging is still necessary: registering the whole smaller model with HIP is not the plan.

The converter preserves MXFP4 down projections while making gate/up Q2_K. Calculated from
those layouts, an expert is 14.25 MiB, the pool 368.72 GiB, and selected expert weights
7.68 GiB per target token. This is about 25.5% less expert traffic, not half the traffic.
Including unchanged dense work reduces the expected end-to-end gain; additional cache
coverage can help, while Q2_K dequantization or worse draft acceptance can offset it.
The 10–15 t/s small-quant target reflects that uncertainty and has no local measurement yet.

Keep only Q2_K/MXFP4 expert paths and the actual dense/MTP tensor formats in the manifests.
For the later four-bit target, keep the existing native MXFP4 file. The server already runs
it through software kernels in llama.cpp; a native hardware FP4 instruction is not required.
The 575.4 GiB Q4_K_M variant recorded in this repository is larger than usable RAM plus
both cards and is not the chosen target.

Do not compare the small quant's model accuracy against a larger checkpoint during backend
development. Compare Strata against llama.cpp on the exact same small quant and token IDs
to catch implementation errors. A fast wrong attention mask or router would not validate
the engine. Measure small-quant and four-bit speed separately, with and without MTP, before
replacing these estimates with results.
