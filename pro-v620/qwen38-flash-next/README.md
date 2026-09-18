# `qwen38-flash-next/` — CT 120 serving Qwen3.8-Flash-Next on both V620s

Moves **CT 120** from `qwen3.6-35b-a3b` (one card, fully GPU-resident) to
**Qwen3.8-Flash-Next** (`qwen4exp`, 180B total / 6B active) across **both** Radeon Pro
V620s with the PLE table and a tunable share of the routed experts in system RAM.

This is the first model on this box that does **not** fit in VRAM. It is here because the
EPYC platform has the RAM for it: `UD-Q4_K_XL` is **111.3 GB**, of which ~28.7 GB is a
lookup table that belongs in host memory anyway.

The sizing analysis this implements lives in CognitiveStack
`personal/large-moe-build-shapes.md`. ⚠️ **Several of that note's premises turned out to be
wrong — see [Corrections](#corrections-to-the-sizing-note) before using its numbers to
justify a purchase.**

## The shape

| | |
|---|---|
| Container | **CT 120** `llamacpp`, privileged, 48 cores, **160 GiB** RAM, swap 0 |
| GPUs | **both** — `0000:03:00.0` (GPU 1) + `0000:83:00.0` (GPU 2) |
| Model | `unsloth/Qwen3.8-Flash-Next-GGUF` `UD-Q4_K_XL`, 4 shards, **111.33 GB** |
| Vision | `mmproj-F16.gguf`, 0.90 GB, ~1.1 GiB VRAM |
| Engine | llama.cpp **b11018**, pinned per-model via `LLAMACPP_DIR` |
| API | OpenAI-compatible on `0.0.0.0:1234`, alias `qwen3.8-flash-next` |
| Disk | `/models` grown 180G → **320G** |

⚠️ **CT 123 `gpu2` must stay stopped.** Its `llama-swap` config passes no device
selector, so it would grab whichever card Vulkan enumerates first — possibly one CT 120
is mid-inference on. `./ct120-cutover.sh to-qwen36` is what releases GPU 2.

## 🔴 The reasoning contract is inverted from every other model here

This is the single most dangerous fact in this folder. Read from `chat_template.jinja`:

```jinja
{%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
{%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
    {{- raise_exception('Unexpected reasoning effort ...') }}
```

| value | Qwen3.8-Flash-Next | Qwen3.8-27B (CT 123) |
|---|---|---|
| unset | **`xhigh` — reasons without answering** | `auto` — also runs away |
| `"none"` | 🔴 **template RAISES** | ✅ the documented off switch |
| `"high"` | 🔴 **template RAISES** | ✅ valid |
| `"low"` / `"medium"` | ✅ | ✅ |
| `enable_thinking: false` | ✅ the off switch | ✅ |

**A caller that carries settings over from the CT 123 coder breaks outright**, in both
directions. The serve script therefore sets `--reasoning off` **server-side**, so no
caller can trip either trap, and `placement-probe.py --contract` asserts all of it
(bare chat answers; `"none"` and `"high"` are both rejected) rather than assuming it.

⚠️ `--reasoning-format auto` is separately load-bearing: with thinking off the template
still emits an **empty** `<think>\n\n</think>` pair, and `none` leaves it in `content` —
which silently corrupts every generated file. `auto` siphons it into `reasoning_content`.

## The placement dial

`111.3 GB` does not fit `2 × 32 GB`. Two things come off the GPU, for different reasons:

1. **The PLE n-gram table** — `-ot per_layer_token_embd=CPU`. ~51B of the 180B
   checkpoint, ~28.7 GB at Q4, but it is a **row lookup, not a matmul**: a handful of
   rows per token, so it costs almost nothing in host RAM. This alone takes the GPU-side
   model from 111.3 GB to **~82.6 GB**, and it is why Q4 is reachable at all.
2. **Routed experts, layer by layer** — `--n-cpu-moe N` keeps the experts of the **first
   N** of 48 MoE layers in host RAM, ~1.56 GB of Q4 expert weight each. **This is the
   dial**, and the subject of `placement-sweep.sh`. (`-cmoe` is the all-48 shorthand.)

| `--n-cpu-moe` | VRAM for the model | free for a second model | why you'd pick it |
|---:|---:|---:|---|
| 15 | ~59 GB | ~5 GB | fastest that fits two cards |
| 20 | ~51 GB | ~13 GB | default — room for KV growth |
| 28 | ~39 GB | **~25 GB** | a 27B guest model fits alongside |
| 34 | ~29 GB | ~35 GB | runs on **one** card |
| 48 | ~8 GB | ~56 GB | control: all experts in RAM |

**Why giving VRAM back is cheap here.** Only **1.46 GB/token** of expert weight is read —
10 of 512 experts plus 1 shared, across 48 layers
(`11 × 640 × 2560 × 3 × 48` = 2.60B params at Q4). Experts are read *sparsely*, so the
cost of offloading scales with the **fraction** moved, not the bytes moved. A dense model
of this size would be unusable in the same arrangement.

### About "dynamic" allocation

llama.cpp fixes tensor placement at **model load**; there is no runtime migration between
backends, so a running server cannot shrink to make room and grow back. Two things are
real, and worth not confusing:

- **Concurrency is solvable today.** `llama-swap` v250's solver-based `matrix` DSL
  (upstream #643) expresses "the big model stays resident, guests swap against each
  other" directly — `sets: {shared: "Q & (c | r)"}` with `evict_costs: {Q: 100}`.
- **The reservation is static.** Pick an `--n-cpu-moe` that leaves the hole and pay for
  it whether or not a guest is loaded. Elasticity is possible via two registered
  profiles and `PUT /api/profiles/active`, at one full model reload per flip — probably
  not worth it, which is exactly what the sweep is meant to settle with numbers.

## Usage

All of it runs on the **Proxmox host as root**, from this directory.

```bash
./install.sh --download          # push env/serve/unit into CT 120, start the 112 GB pull
                                 # resumable and idempotent — safe to re-run

# watch it (the unit is transient; ~112 GB, roughly an hour on this link)
pct exec 120 -- bash -lc 'journalctl -u qwen38fn-dl --no-pager -o cat | grep "^2026" | tail'

./ct120-cutover.sh to-qwen38fn   # both cards -> qwen4exp. Restarts CT 120.
./ct120-cutover.sh status
./ct120-cutover.sh to-qwen36     # full rollback, releases GPU 2

# measure. Run the guard in another shell FIRST.
./thermal-guard.sh &
./placement-sweep.sh                                  # default matrix
NCMOE_LIST="20 28" DEPTHS="0,32000" ./placement-sweep.sh
ONE_GPU=true NCMOE_LIST="34 40 48" ./placement-sweep.sh   # is one card faster? see below
```

`placement-sweep.sh` writes `/root/qwen38-flash-next/sweep-<ts>/` with per-config JSON
and a `SUMMARY.md` carrying the decode table, the **VRAM-freed-versus-decode-lost trade**,
the depth curve, and the template-contract result.

## The answer: which configuration to run

All figures at full clock (`schedutil`), b11018, two V620s, measured 2026-09-18.
**`-ncmoe 16` is the floor** — nothing below it fits in any shape at any split.

### ✅ Default — fastest, and it also has the most headroom

```
--n-cpu-moe 16 --tensor-split 30,18 --threads 16 \
  --cache-type-k q8_0 --cache-type-v q8_0 --no-mmproj-offload \
  --ctx-size 131072 --parallel 1
```

| | |
| --- | ---: |
| decode, short prompt | **14.46 t/s** |
| decode, 8k context | **13.37 t/s** |
| prefill, 8k | 77.2 t/s → **104 s to first token** |
| VRAM free | 2297 / 1255 MiB, no spill |

✅ **Verified end-to-end on the live server**, not assembled from separate cells: the split
stage measured this placement at `--ctx-size 65536` (14.17 / 13.45) and this row is the
delivered config at **131072**, re-probed afterwards. Doubling the window is free — d0 is
even marginally higher, and prefill is identical. The contract assertions pass too: bare
chat answers, **no `<think>` leak into `content`**, and **no `reasoning_effort` value a
caller might send breaks the server**, which matters because this template raises on
`"none"` and `"high"` — the exact values CT 123's coder sends.

`q8_0` + projector-on-CPU is free here (identical at d0, +2.9% at depth) and frees 1.6 GiB,
which is what lets `--ctx-size 131072` fit. ⚠️ Safe **only** because the server runs
`--reasoning off`; the coupling is a hard XOR. ⚠️ Image encoding is 3–5× slower with the
projector on CPU — text is unaffected. If vision latency matters, drop `--no-mmproj-offload`
and `--cache-type-*`, accept 14.16 / 13.07 and 1.3 / 1.5 GiB free.

### Leave room for a second model

| `-ncmoe` | split | decode d0 | d8k | prefill d8k | VRAM freed | cost |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 16 | `30,18` | 14.17 | 13.45 | 76.9 | — | — |
| 20 | `32,16` | 13.03 | 12.06 | 63.6 | ~8.7 GiB | −8.0% |
| 28 | `36,12` | ~11.3 | ~10.6 | 47.4 | ~20.9 GiB | −20% |
| 48 | `48,0` | 10.18 | 8.70 | 29.0 | **54.8 GiB, one card entirely** | −28% |

**`-ncmoe 48` is the one to know about**: the whole model runs in **9.4 GiB on a single
card**, leaving the other completely free, for −28% of decode. That is the configuration to
use if CT 123 needs a card back.
⚠️ The 28 and 48 rows were measured at the documented split; expect a few percent better at
the corrected one.

### Concurrency

| want | setting | result |
| --- | --- | --- |
| one interactive caller | `--parallel 1 --ctx-size 131072` | 14.17 t/s, full 128k window |
| batch throughput | `--parallel 4 --ctx-size 131072` | **30.9 t/s aggregate**, 7.7 each, 32k per slot |

**2.30× aggregate at four streams**, and doubling the context budget is free — so never run
`--parallel 4` at `--ctx-size 65536`, which buys nothing and leaves each caller 16k.

### ⛔ What not to do

| | why |
| --- | --- |
| CPU-only (`-ngl 0`) | 6.04 t/s, **−57%** — and pointless, since `-ncmoe 48` frees a whole card at 10.18 |
| `--threads 32` | −4 to −5% solo; 16 is best across every concurrency level |
| the documented `--tensor-split` | ~2 layers off; spills at `-ncmoe` 15/16/20 and costs up to −11% |
| f16 KV at `--ctx-size 131072` | spills at `-ncmoe 16` and costs −21% of decode at depth |
| `-ncmoe` below 16 | does not fit, in any shape, at any split |
| `--load-mode none` | −5%, despite llama.cpp suggesting it at startup |
| `powersave` governor | −30%, and it was the single largest factor found |

### The ceiling, and why

Decode is **~72% fixed per-token overhead** — three independent routes agree: the `-ncmoe`
curve fit and a clock experiment both give ~43 ms, and the concurrency fit gives 53.5 ms of
a 71 ms budget. `GGML_SCHED_DEBUG` then names it: **~30 graph splits per token**, matching the
placement almost exactly (16 CPU-expert layers × 2 crossings + the card boundary + the PLE
lookup) at ~1.1 ms per crossing — 61% of the fixed term.

So the lever is **fewer CPU↔GPU crossings**, not more bandwidth or faster cores. Ruled out
separately: memory bandwidth (4× headroom, DIMMs 9 °C cooler than a real soak), PCIe transfer
(400 KB/token = 16 µs against 1.07 ms measured per crossing), core count (8 ≈ 32 threads),
core clock (57% of the budget is clock-independent), and disk (zero steady-state majflt).
Upstream PR **#27880** attacks exactly this and did not go far enough.

## Measured, 2026-09-18 — at full clock

🔴 **Every number in this file before 2026-09-18 was taken with the CPU governor pinned to
`powersave`, which on `acpi-cpufreq` parks all 64 threads at 1500 MHz against a 3308 MHz
maximum.** That cost ~30% of decode and blew run-to-run spread out to as much as 36%. It
also changed two conclusions' *direction*, not just their magnitude — see below. The
governor is now `schedutil`, made persistent by `cpu-governor.service`, and everything here
is re-measured.

| governor | decode d0 | decode d8k | picked |
| --- | ---: | ---: | --- |
| `performance` | 12.82 | 11.36 | |
| **`schedutil`** | **12.57** | **11.36** | ✅ within 2%, and it idles cheap with no toggle to fail silently |
| `ondemand` | 12.17 | 10.99 | |
| `powersave` | 8.77 | 8.23 | 🔴 the old default |

✅ **The model works on RADV.** Output is coherent, non-degenerate (8-gram ratio 1.0) and
reproducible at d0 across reps at temperature 0. As far as this KB can tell these remain
the first Qwen3.8-Flash-Next numbers on a Vulkan/RDNA2 target anywhere.

⚠️ **Output is NOT bit-reproducible at DEPTH.** Reps at d0 always agree; a d8000 cell
disagrees with itself intermittently, one prompt class at a time, ~3% apart, even at
temperature 0 with `top_k 1`. Hybrid CPU/GPU expert reduction order varies with thread
scheduling and ~5.8k tokens of accumulated state is enough to flip a token. **Consequence:
compare output hashes at d0 only.** Medians at depth are fine; hashes there are not a gate.

### The placement curve, `--threads 32`, ctx 65536, two cards, b11018

| `-ncmoe` | decode d0 | decode d8k | **prefill d8k** | VRAM used | free for a guest | headroom |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 15 | **13.68** | **13.57** | **78.9** | 58089 MiB | 6.3 GiB | 🔴 spilled, 2060 MiB in GTT |
| 20 | 12.69 | 11.53 | 63.6 | 52540 MiB | 11.7 GiB | 🔴 spilled, 101 MiB, 823 MiB free |
| 28 | 11.29 | 10.56 | 47.4 | 40527 MiB | **23.4 GiB** | ok |
| 34 | 10.45 | 9.44 | 38.8 | 31267 MiB | 32.5 GiB | ok |
| 48 | 10.18 | 8.70 | 29.0 | **9443 MiB** | **54.8 GiB** | ok, but single-GPU — see below |

### 🔴 PREFILL is the binding constraint, not decode

The column nobody was watching. Across that curve **prefill falls 63% where decode falls
only 36%**, and in absolute terms prefill is what makes this model feel slow:

| `-ncmoe` | prefill d8k | time to first token on an 8k prompt |
| ---: | ---: | ---: |
| 15 | 78.9 t/s | **101 s** |
| 28 | 47.4 t/s | 169 s |
| 48 | 29.0 t/s | **276 s** |

Decode at 13.7 t/s is perfectly usable. Waiting 1.7–4.6 minutes before the first token is
not. **So there is no single best placement**: long-prompt or agentic work wants `-ncmoe`
as low as fits because prefill dominates, while short-prompt chat can take `-ncmoe 48` for
−2.6% of decode and free 54.8 GiB.

⚠️ **Do not quote the d0 prefill figures** (20–36 t/s). Those prompts are ~30 tokens, so the
number is fixed per-request overhead, not throughput. Only the d8k column means anything.

### What it costs to reserve VRAM for a second model

| move | frees | decode d0 | decode d8k | prefill d8k |
| --- | ---: | ---: | ---: | ---: |
| `-ncmoe 20 → 28` | +11.7 GiB | −11.0% | −8.4% | −25% |
| `-ncmoe 28 → 34` | +9.1 GiB | −7.4% | −10.6% | −18% |
| `-ncmoe 34 → 48` | +21.8 GiB | **−2.6%** | −7.8% | −25% |

**Giving away VRAM is cheap on decode and expensive on prefill.** `-ncmoe 34 → 48` frees
21.8 GiB for −2.6% of decode — which is why "leave room for another model" is a good deal
*if* your prompts are short, and a bad one if they are long.

⚠️ **`-ncmoe 48` is effectively SINGLE-GPU and is not a two-card data point.** With no heavy
layers left the derived split is `48,0`, so card 2 holds nothing. That is the right
placement — splitting the non-expert layers would only add an inter-GPU hop — but it means
the whole model runs in **9.4 GiB on one card**, leaving the *other card entirely free*.
`-ncmoe 34` is the honest two-vs-one comparison point.

### 🔴 Depth hurts MORE the more is offloaded — the inverse of what the downclocked data said

| `-ncmoe` | d0 → d8000 | at 1500 MHz this read |
| ---: | --- | --- |
| 15 | 13.68 → 13.57 (**−0.8%**) | −22% |
| 20 | 12.69 → 11.53 (−9.1%) | −12% |
| 28 | 11.29 → 10.56 (−6.5%) | −9% |
| 34 | 10.45 → 9.44 (−9.7%) | −6% |
| 48 | 10.18 → 8.70 (**−14.5%**) | −5% |

The old table read a clean monotonic "the more that sits on the CPU, the *less* depth hurts"
and that was an artifact of every core being parked at 1500 MHz. At full clock the trend
runs the other way. ⚠️ The `-ncmoe 15` row is the one to distrust: it was spilling 2060 MiB
to GTT, which depresses its d0 and flatters the ratio.

### ✅ q8_0 KV + projector-on-CPU is FREE at a placement that fits

⚠️ **This section previously claimed q8_0 cost ~14% at depth. That was wrong**, and the
error is instructive: it generalised from a pair of cells that were both on the documented
(spilling) `--tensor-split`. Re-measured as a clean pair at a placement that fits —
`-ncmoe 16`, split `30,18`, neither cell spilling, same thread count:

| shape | decode d0 | decode d8k | VRAM free c1 / c2 |
| --- | ---: | ---: | ---: |
| f16 / projector on GPU | 14.16 | 13.07 | 1305 / 1553 MiB |
| **`q8_0` / projector on CPU** | **14.17** | **13.45** | **2881 / 1878 MiB** |
| | +0.1% | **+2.9%** | +1.6 GiB |

Identical at d0 and *marginally faster* at depth, while freeing ~1.6 GiB — which is what
this repo's original note said all along ("marginally faster, unchanged at 2× context").
The −14% belonged to the spilled `-ncmoe 20` configuration, not to the architecture.

🔴 **The lesson is about method, not about KV.** A spilled configuration does not degrade
uniformly: it cost that pair far more at depth than at d0, which looked exactly like a
depth-scaling penalty and was not. **Never characterise a knob using cells that are
spilling — establish a fitting placement first, then vary one thing.** The earlier
comparison also varied two things at once (KV type *and* projector placement), so even its
sign was not attributable; that is still true of the pair above, so the honest claim is
that *the shape* is free, not that q8_0 specifically is.

⚠️ Two reasons to keep this shape deliberate rather than automatic:
- `q8_0` KV is only safe here because the server runs `--reasoning off`. The coupling is a
  hard XOR on this box — `reasoning off + q8_0` **or** `reasoning low/medium + f16`. Mixing
  gives silent empty replies.
- `--no-mmproj-offload` costs 3–5× on **image encoding only** (text is unaffected). If
  vision latency matters, take the f16/projector-on-GPU row and its 1.6 GiB less headroom.

### `--threads` is an inverted U with the peak at 16, not 32

| threads | decode d0 | decode d8k | prefill d8k |
| ---: | ---: | ---: | ---: |
| 8 | 13.13 | 11.87 | 63.8 |
| **16** | **13.19** | **12.11** | 63.7 |
| 32 (the inherited default) | 12.69 | 11.53 | 63.6 |

**32 threads is contention, worth −4 to −5%.** STREAM corroborates it from a completely
different direction: 8 threads saturated the four populated channels at 80.3 GB/s while 32
measured *worse* at 74.8 — the CPU-side expert FFN is bandwidth-bound GEMV, so past
saturation extra threads only fight each other. Prefill is flat across all three, so this is
free. ⚠️ 8 and 16 are within ~2% at n=1; 32 is the clear loser, 16 the likely winner.
### A spill costs DECODE, not prefill — and more at depth

Measured directly, same placement (`-ncmoe 16`, split `30,18`, f16 KV), only the context
budget changed:

| ctx | d0 decode | d8k decode | d8k prefill | headroom |
| ---: | ---: | ---: | ---: | --- |
| 65536 | 14.16 | 13.07 | 77.0 | 1337 / 1553 MiB free, no spill |
| 131072 | 12.92 | 10.34 | **76.7** | 226 / 573 MiB free, 183 MiB GTT |
| | −8.8% | **−20.9%** | **−0.4%** | |

**Prefill is untouched; decode pays, and pays roughly twice as much at depth.** That is the
right shape mechanically: prefill streams weights in large batches, whereas decode at depth
touches the KV cache on every token, so a cache partly in GTT means a host round-trip per
token rather than per batch.

⚠️ **Do not infer a spill's cost from wall-clock time.** A slow-looking cell invites the
story "prefill collapsed", and `prefill_tps_median` is in every probe's JSON to settle it.
This repo's ~12× GTT figure came from a case where the **whole KV** was in GTT at a much
larger over-commit; a marginal 183 MiB spill is a different regime and behaves differently.

✅ **The practical consequence is unchanged, for a better reason:** use `q8_0` for a long
window. It halves the cache (12 KiB/token against f16's 24), so `--ctx-size 131072` fits at
the recommended placement instead of spilling — confirmed by the `--parallel` stage running
131072 at that shape with no spill at all.

### 🔴 MTP speculation: BLOCKED, and the reason is specific

The rebase of llama.cpp PR **#28097** onto b11018 (see `mtp-patches/`) **builds, loads the
target model and serves normally** — the no-speculation control on that exact binary gives
**14.42 d0 / 13.43 d8k** against `b11018-baseline`'s 14.17 / 13.45 at the same placement, so
the build is healthy and if anything marginally faster. But **both drafter GGUFs abort the
moment the MTP graph is constructed**:

```
/root/llama.cpp/ggml/src/ggml.c:2264: GGML_ASSERT(ggml_can_repeat(b, a)) failed
  llama_model_qwen4exp::graph::build_hc_mix(...)
  llama_model_qwen4exp::graph_mtp::graph_mtp(...)
```

**This follows from the conflict resolution, and resolving it the other way does not help.**
b11018 reshaped every hyper-connection gamma from `{hc_dim}` to `{n_embd, hc}` with
`TENSOR_ALLOW_RESHAPE`, and updated its **trunk** graph to match. The resolution kept
b11018's shapes, which is correct — the trunk works, as the control proves. But PR #28097's
**MTP** graph (`graph_mtp` → `build_hc_mix`) predates that reshape and is written against
`{hc_dim}`, so it broadcasts mismatched shapes and aborts. Taking the PR's shapes instead
would merely move the failure into the trunk, which is the path that must work.

**The real fix is to port the PR's MTP graph to b11018's hyper-connection convention** — a
code change to the MTP caller of `build_hc_mix`, not a merge decision. That belongs upstream,
or in a patch written with the hc layout actually in hand; guessing risks producing wrong
*output* rather than a clean crash, which is far worse than no measurement.

⚠️ **The pre-flight that passed was necessary but not sufficient.** Confirming both drafters
carry the metadata the loader's `mtp_only` probe needs (`nextn_predict_layers 1`,
`block_count 49`, arch `qwen4exp`, 32–34 tensors) validated the **loader** path and said
nothing about the **graph** path, which is where this fails. Metadata satisfying a loader
does not establish that the graph built from it is shape-correct.

✅ **Everything is staged for a one-command retry when #28097 rebases**, so this is a re-test
rather than a re-investigation:

| | |
| --- | --- |
| drafters | `mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf` (2.79 GB, 34 tensors) and `-shared-` (1.91 GB, 32) |
| build | `/root/builds/mtp-b11018` on CT 201, 58 MB, `draft-mtp` + `ggml-vulkan` asserted present |
| patches | `mtp-patches/*.patch` — 4 commits, `git am` onto b11018 |
| runner | `./mtp-standalone.sh` with `MTP_SKIP_BUILD=true` |

### Concurrency: 4 streams give 2.3x the throughput, and the context comes free

At the winning placement (`-ncmoe 16`, split `30,18`, `q8_0` KV, projector on CPU). ⚠️ These
figures come from `concurrency-probe.py`, which uses a different prompt set from
`placement-probe.py` — **compare within this table only**, not against the placement numbers.

| `--parallel` | `--threads` | `--ctx-size` | ctx/slot | per-stream t/s | aggregate t/s |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 32 | 65536 | 65536 | 13.22 | 13.22 |
| 1 | 16 | 65536 | 65536 | 14.09 | 14.09 |
| 1 | **8** | 65536 | 65536 | **14.25** | 14.25 |
| 2 | 32 | 65536 | 32768 | 10.23 | 20.46 |
| 2 | **16** | 65536 | 32768 | **11.05** | **22.10** |
| 4 | 32 | 65536 | 16384 | 7.67 | 30.46 |
| 4 | **16** | 65536 | 16384 | 7.73 | **30.88** |
| 4 | 8 | 65536 | 16384 | 7.38 | 29.37 |
| 4 | 32 | **131072** | **32768** | 7.66 | 30.52 |

**Scaling: 1 → 2 streams is 1.55×, 1 → 4 is 2.30×**, at 58% of the solo per-stream rate.
Four concurrent callers is a good trade for batch work and a poor one for a single
interactive user.

✅ **Doubling the total context budget at 4 streams is FREE.** `--ctx-size 131072` gives each
of four slots **32k instead of 16k** for 30.52 vs 30.46 t/s aggregate — identical within
noise. Concurrency and context are not in tension here, because the KV cache is only
12 KiB/token at `q8_0` (24 at f16), so the extra 0.75 GiB fits the winning placement's
headroom. **Do not run `--parallel 4` at `--ctx-size 65536`**: it buys nothing and leaves
each caller a 16k window.

### 🔴 `--threads` inverts with load — do not tune it single-stream

| `--threads` | par 1 | par 2 | par 4 |
| ---: | ---: | ---: | ---: |
| 8 | **14.25** | — | 29.37 |
| **16** | 14.09 | **22.10** | **30.88** |
| 32 | 13.22 | 20.46 | 30.46 |

8 threads wins solo — it already saturates the four populated memory channels, which is what
STREAM predicted — and **loses 4.9% at four streams**, because four concurrent streams
present more parallel work than 8 threads can cover. **16 is the right default**: within 1%
of best solo, best at both 2 and 4 streams.

⚠️ **The general trap: a knob tuned at one concurrency level can be actively wrong at
another, and single-stream benchmarking is the default that hides it.** This bit the
pipeline's own selection logic, which scored `--threads` on single-stream rows and would have
applied 8 to a server of unknown concurrency.

✅ And the effect shrinks as load rises — the 16-vs-32 gap is +6.6% at 1 stream, +8.0% at 2,
**+1.4% at 4**. Once the batch is large enough, fewer threads still saturate bandwidth and
the setting stops mattering.

### What concurrency says about the fixed-overhead floor

Fitting per-token time as **F** (serialisable, amortises across streams) + **V** (real
per-stream work) to the `--threads 32` pair gives **F = 53.5 ms, V = 22.1 ms — 71% fixed**,
which independently corroborates the ~43 ms floor found earlier by two other routes.

⚠️ **But V is not constant, so treat 71% as a floor on the amortisable share rather than an
exact split.** That fit predicts 28.2 t/s at four streams; the measurement is **30.46, 8%
better**. llama.cpp batches concurrent decode, so the per-stream work itself shrinks with
batch size (V falls to ~19.4 ms at four streams). A two-term model is the right shape and
slightly too pessimistic.

### 🔴 `--tensor-split` is REQUIRED with `--n-cpu-moe`, and nothing warns you

The single biggest effect found, and it is a configuration bug rather than a hardware
limit. `--n-cpu-moe N` moves the experts of the **first** N layers to the CPU, so layers
`0..N-1` are light and `N..47` are heavy (~1.56 GB of experts each). llama.cpp's default
split divides 48 layers **evenly by count**, handing card 1 mostly light layers and card 2
mostly heavy ones:

| `-ncmoe 20` | GPU 1 | GPU 2 | decode |
| --- | ---: | ---: | ---: |
| default split | 13.4 GiB, 0.2 GiB GTT | **30.7 GiB, 9.3 GiB GTT** | **6.6 t/s** |
| `--tensor-split 34,14` | 25.1 GiB, 14 MiB GTT | 21.2 GiB, 14 MiB GTT | **11.74 t/s** |

**+78% decode and ~3x prefill, from rebalancing alone.** The cards were never short of
memory *in total* — 53 GiB of demand against 60 GiB of capacity. It was pure
maldistribution, and the symptom was a 9.3 GiB GTT spill on one card while the other sat
17 GiB idle.

#### 🔴 …and the rule of thumb is ~2 layers off, which was hiding a second spill

The rule this file used to give — `card1 = N + (48 - N) / 2` — balances by **weight alone**,
and that is not what fills a card. Measured across three placements, counting GTT as demand
that did not fit:

| `-ncmoe` | split | card 1 | card 2 | total | spare of 65536 | imbalance |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 15 | `31,17` | 34789 | 29506 | 64295 | 1241 | **+5283** |
| 20 | `34,14` | 32046 | 24741 | 56787 | 8749 | **+7305** |
| 28 | `38,10` | 26521 | 18254 | 44775 | 20761 | **+8267** |

The imbalance is not one layer and **it grows with `-ncmoe`**. At ~1500 MiB of expert weight
per layer — derived from the 15→20 pair, against the ~1.56 GB assumed above — one moved
layer shifts the imbalance by ~2× that, so the correction is roughly **−2 layers**:

```
card1_layers = N + (48 - N) / 2 - 2      # -ts card1_layers,(48 - card1_layers)
```

What the weight-only rule misses, all of which lands on the card owning the layer:

- **the KV cache** — 12 of the 48 blocks are full attention (QSA every 4th), and card 1 owns
  more of them than card 2 at every split in the table
- **the vision projector**, +1.11 GiB, which goes to a single device
- per-device compute buffers

⚠️ **This mattered in practice, not just in theory.** At `-ncmoe 15` card 1 sat at
**39 MiB free with 2060 MiB in GTT** while card 2 had 3280 MiB free — and that cell still
posted the *fastest* decode of the sweep (13.68 t/s). A spilled cell reads as "a slow
placement" rather than "a broken one", and the startup loud-guard does not catch it.
**Always read `mem_info_vram_free` and `mem_info_gtt_used` together; "used" looks
unremarkable right up to the cliff.**

#### 🔴 `-ncmoe 15` does not safely fit at all in the production shape

Total demand at 15 is 64295 MiB against 65536 of capacity: **~620 MiB per card even
perfectly balanced**, under the ~1024 MiB where RADV starts spilling. So no split rescues
it with f16 KV and the projector resident. The candidates, computed and then load-checked:

| candidate | total MiB | balanced/card | verdict |
| --- | ---: | ---: | --- |
| `15`, f16, projector GPU | 64295 | 620 | 🔴 spills at any split |
| `14`, q8_0, projector CPU | 63895 | 820 | 🔴 still spills — measured 11.54 t/s |
| `15`, q8_0, projector CPU | 62394 | 1571 | fits, but pays ~14% at depth |
| **`16`, f16, projector GPU** | **62794** | **1371** | fits, no depth penalty, vision stays resident |

The frugal shape does **not** buy a whole placement step: `q8_0` + `--no-mmproj-offload`
saves ~1900 MiB while one layer of experts costs ~1500. So dropping one layer of experts
(`-ncmoe 16`) beats quantising the cache, because it avoids the 14% depth cost entirely.

### ⛔ CPU-only is not worth it — and you do not need it to free a card

The question was whether running this model entirely on the CPU, leaving both V620s for
other services, costs little enough to be worth it. It does not:

| config | decode d0 | decode d8k | prefill d8k | 8k TTFT | VRAM held |
| --- | ---: | ---: | ---: | ---: | ---: |
| `-ncmoe 20`, `--threads 16` | **13.19** | **12.11** | 63.6 | **126 s** | 52540 MiB, both cards |
| `-ncmoe 48` | 10.18 | 8.70 | 29.0 | 276 s | **9443 MiB, ONE card** |
| `-ngl 0` (CPU-only), `--threads 16` | 6.04 | 5.51 | 26.4 | 303 s | 2181 MiB (projector only) |

**−54% against the fastest fitting GPU config, −41% against `-ncmoe 48`.**

But the percentage is not the argument. **`-ncmoe 48` already runs the whole model in 9.4 GiB
on a single card** — the derived split is `48,0`, so the second card holds nothing at all and
is free for another service, with ~23 GiB still spare on the first. So there is never a
reason to reach for CPU-only to free a GPU: `-ncmoe 48` frees one outright and is **69%
faster**.

✅ **Where the GPU actually earns its place is DECODE, not prefill.** CPU-only costs only −9%
of prefill against `-ncmoe 48` (26.4 vs 29.0 t/s), because at `-ncmoe 48` prefill is already
CPU-bound on the experts. The cards' contribution at that placement is almost entirely the
attention and non-expert path during decode, and that is worth +69%.

⚠️ **"Both cards free" is not literally true as measured.** `reset_env` leaves the vision
projector resident, so ~2.1 GiB stays on a card. `--no-mmproj-offload` frees that too, at a
cost to image encoding only (3–5×) and none to text.

### 🔴 Nothing is saturated — this is serialization-bound, not bandwidth-bound

Sampled during a 300-token decode:

```
gpu1=35% gpu2=13%   gpu1=43% gpu2= 2%
gpu1=13% gpu2=26%   gpu1=83% gpu2= 0%
gpu1= 6% gpu2=31%   gpu1=16% gpu2=71%     host CPU 33-43% throughout
```

**The two cards alternate and neither is busy; the CPU is a third idle.** Every token
walks 20 CPU expert layers, then card 1's layers, then card 2's, synchronising at each
handoff — 48 layers of serial dependency with three participants. That is a *latency*
cost, and it is invisible to any `bytes ÷ bandwidth` model. ✅ **This is the finding that
matters for the purchase decision in the sizing note: its arithmetic cannot predict a
hybrid placement, and measured reality is 4x below it.**

### ⚠️ `--load-mode none` is llama.cpp's own advice and it is WRONG here

llama-server prints, at every start, `tensor overrides to CPU are used with mmap enabled -
consider using --load-mode none for better performance`. Measured, same config:

| load mode | decode | GPU 1 GTT |
| --- | ---: | ---: |
| `auto` (mmap) | **11.74 t/s** | 14 MiB |
| `none` | 11.18 t/s (−5%) | **31.6 GiB** |

`none` is marginally slower *and* pulls 31.6 GiB into GTT. Kept on `auto`. ✅ **Treat that
startup hint as a hypothesis, not instruction.**

### ✅ The template trap is real but `--reasoning off` neutralises it

Measured against the running server — and this is the opposite of what reading the
template alone implies:

| client sends | result |
| --- | --- |
| nothing | ✅ `content='OK'` |
| `reasoning_effort: "none"` | ✅ `content='OK'` — **does not raise** |
| `reasoning_effort: "high"` | ✅ `content='OK'` — **does not raise** |
| `"low"` / `"medium"` / `"xhigh"` | ✅ `content='OK'` |

With `--reasoning off` set server-side, llama.cpp does not pass the effort through to the
template, so the values that *would* raise never reach it. `reasoning_content` comes back
`''` and `content` stays clean, confirming `--reasoning-format auto` is siphoning the empty
`<think>` pair correctly. **So a caller carrying settings over from CT 123 cannot break
this server** — the protection works. `placement-probe.py --contract` asserts exactly that
(it originally asserted the reverse, which was wrong).

### Load times, which bound any "elastic reallocation" scheme

| | |
| --- | ---: |
| First load, cold page cache, 111 GB off the SATA 860 EVO | **2 m 38 s** |
| Reload with the file in page cache (160 GiB cap holds it) | **40–46 s** |

So the two-profile elasticity idea costs ~45 s per flip once warm, not the ~4 minutes a
cold load implies. Still far too slow to do per-request; fine at a role handoff.

## ⚠️ Warnings

- 🔴 **Multi-GPU is the *penalised* path for this architecture right now, which inverts
  the "more cards is better" assumption.** llama.cpp
  [#28699](https://github.com/ggml-org/llama.cpp/pull/28699) reports that the QSA
  indexer's pooled summary rows are allocated in a single buffer, so *"on a layer-split
  setup [it] makes every layer but the first read and write its rows over the inter-GPU
  links; measured on an 8-GPU box that costs **2x decode throughput**"*. The per-device
  fix is in that **open draft**.
  [#28623](https://github.com/ggml-org/llama.cpp/pull/28623) — "multi gpu & buffer size
  issues" — was closed by its author as incomplete. **Run `ONE_GPU=true` as a control
  before concluding that two cards help.** That control is the whole reason the flag
  exists.
- ⚠️ **Vulkan is the least-trodden path for `qwen4exp`.** The merge PR (#27742) validated
  CPU and CUDA only, and #28699 explicitly *excluded* three commits from its source fork
  as "Vulkan-specific" and untested. Expect to find things.
- ⚠️ **Decode degrades with context depth**, for the indexer reason above — a cost no
  bandwidth arithmetic models. A short-prompt tok/s figure is **not** this model's
  throughput. The only third-party llama.cpp numbers for this model are **22–28 t/s at
  63k–114k depth** (8-GPU mining rig, Q3_K_XL), so quote depth with every number.
- ⚠️ **Watch GTT, not just VRAM.** Below roughly 1 GiB of headroom RADV spills silently
  and decode collapses ~12x — the startup guard does not catch it. The sweep flags it.
- ⚠️ **Never `CTX=auto` / `--fit on`.** On RADV auto-fit over-commits and puts the KV
  cache in GTT; CT 123 once ran a full day at 2.0 tok/s that way.
- ⚠️ **`MemorySwapMax=0` on the unit is load-bearing.** The PLE table and the CPU-side
  experts must stay resident; paging them back from the SATA 860 EVO turns a bandwidth
  measurement into a disk measurement. `swap` is also 0 on the container.
- ⚠️ **The watchdog service map must point both cards at CT 120** while it holds both.
  `ct120-cutover.sh` does this, because the stock map sends a GPU-2 trip to
  `123:llama-swap` — a **no-op** now that CT 123 is stopped, which would leave the real
  load cooking an overheating card. `to-qwen36` puts the map back.
- ⚠️ **`gpu-ab-bench/thermal-guard.sh` and `sample-gpus.py` are B550-era** and still name
  `0000:2d:00.0` / `0000:06:00.0`. Those paths do not exist here, so the guard's hwmon
  glob never matches, `cat` fails, and `set -e` kills it within a second — it fails
  **silently open**. Use this folder's `thermal-guard.sh` on the EPYC box.
- ⚠️ **The MTP drafter is deliberately not deployed.** Speculation for `qwen4exp` appears
  to live only in an out-of-tree `qwen4exp-spec-mtp` fork, and this KB's own rule is not
  to pay for a drafter with no merged runtime. At 6B active, draft/verify overhead would
  likely dominate anyway.

## Corrections to the sizing note

Found while implementing. All three would mislead a purchase decision.

1. 🔴 **"Exactly one build short — support lands in b10679+" is wrong, but NOT in the
   direction it first appears. The real floor is b11013, and it landed the day this was
   written.** `qwen4exp` is registered as an arch string in b10678
   (`grep -rlx qwen4exp /opt/llamacpp/llama-b10678` hits `libllama.so.0.3.0`) — which is
   exactly the trap. The architecture uses **hyper-connections** (`hc_count: 4`), and:

   | commit | merged | meaning |
   |---|---|---|
   | `qwen4exp: add hc ops` (#28901) | 2026-09-16 | the ops exist at all |
   | `vulkan: support qwen4exp hc ops` (#28988) | **2026-09-17 04:34** | RADV can run them |

   **b11013 is the first build containing #28988; b11010 does not have it** (checked with
   the compare API against the commit). So this model could not have run on this box's
   Vulkan stack at any point before today, and **b10678 is not a rollback target** —
   grepping the arch string on it would have promised a model that cannot execute.
   ✅ **Check that a backend can run an arch, not merely that the arch is registered.**
   *(Method note: `strings` is not installed in CT 120, so `strings … | grep` returns
   empty for every query and reads as "absent". Use `grep -rlx`.)*
2. ⚠️ **The PLE offload regex carries a dead alternative.** The note says
   `-ot "per_layer_token_embd|ngram_embedding=CPU"`. `ngram_embedding` is the
   **safetensors** name; the GGUF tensor is `per_layer_token_embd`
   (`gguf-py/gguf/constants.py:1478`, plus per-layer `blk.N.ple_*`). Harmless, but the
   half that matters is the first one.
3. 🔴 **The note's "N GPUs behave like one card of N× the VRAM at one card's bandwidth"
   is optimistic for this architecture** — see the #28699 finding above. For `qwen4exp`
   on master, a layer split can be actively *worse* than one card. The note's grids
   assume the penalty is zero.

Two more, less load-bearing:

4. The grid method charges the offloaded share the full `(active/total) × size`, which
   over-counts a sparsely-read expert stack. The note flags this as deliberately
   conservative; it means the middle of every grid row understates.
5. `/models` free space in the note's setup checklist was computed against CT 123. CT 120
   needed the growth instead.

## Linting

`shellcheck` for `.sh` and `llamacpp-serve-qwen38fn`; `python3 -m py_compile` for `.py`.
All clean as committed.

## Memory bandwidth and latency — measured 2026-09-17

`./membench.sh` on a quiet host. Re-run verbatim once the remaining four DIMMs land; the point
is that the 4-stick and 8-stick numbers come from an identical harness.

### STREAM, 4 of 8 channels populated (C/D/G/H)

| threads | Copy | Scale | Add | Triad |
| ---: | ---: | ---: | ---: | ---: |
| **8** | **80.3 GB/s** | 51.2 | 56.2 | **56.3** |
| 16 | 77.8 | 50.1 | 54.9 | 55.0 |
| 32 | 74.8 | 49.0 | 54.0 | 54.1 |

🔴 **This settles the open question, and NOT in the direction expected: `stressapptest` was not
understating.** STREAM reports *application* bytes. Triad moves 24 B/iteration in application
terms, but a normal store first reads the line it is about to overwrite (read-for-ownership), so
real DRAM traffic is 32 B/iteration:

| | figure | as DRAM traffic | % of 102.4 GB/s theoretical |
| --- | ---: | ---: | ---: |
| STREAM Triad | 56.3 GB/s app | **75.1 GB/s** (x32/24 RFO) | 73.3% |
| `stressapptest` (acceptance soak) | 76.4 GB/s | 76.4 GB/s | 74.6% |
| **STREAM Copy** | **80.3 GB/s** | **80.3 GB/s** | **78.4%** |

Triad-corrected and `stressapptest` agree within 2%. Copy must be using non-temporal stores —
at 16 B/iteration application bytes, an RFO correction would put it at 120 GB/s, above
theoretical, so the RFO is provably absent. **~80 GB/s / 78.4% of peak is the achievable
ceiling on four channels**, and the old `23.1 GB/s per channel` (90.2% of peak) was simply never
reachable. Honest per-channel figure: **19.1-20.1 GB/s**.

⚠️ **8 threads beat 16 and 32.** Four channels saturate at 8 threads and more only add
contention, so the acceptance soak's 16 threads left nothing on the table (-3%). **At eight
channels this will invert** — the re-run must sweep threads, not reuse 8.

### Idle latency — random pointer chase, 4 GiB working set

| | latency |
| --- | ---: |
| **with huge pages** | **141.36 ns/load** |
| without (4 KiB pages) | 226.95 ns/load |

🔴 **The huge-page flag is worth 38%, so a latency number without it is meaningless.** THP on
this host is `madvise`, not `always`, so the probe must call `madvise(MADV_HUGEPAGE)` itself —
otherwise a random walk misses the TLB on essentially every access and the figure is DRAM latency
*plus* a full page-table walk. The 227 ns first run was exactly that mistake.
⚠️ **141 ns is not attributable.** It is plausible for Rome with fully random access across four
channels (core → IOD → UMC adds ~20-30 ns over monolithic, and every access is a row miss), but
separating any 3DS contribution needs a flat 2Rx4 set on this same harness. Treat it as a
baseline to re-run, not as evidence.

### ✅ Does the 3DS substitution cost latency? Probably not — and refresh likely favours it

The installed modules are Samsung `M393A8K40B22-CAE`, **2S2Rx4 3DS** (SPD `Rank: 4`), against the
advertised flat 2Rx4 `M393A8G40AB2-CWE`. Three mechanisms, per JEDEC JESD79-4:

1. ✅ **The core latency chain is unchanged.** Every die in a 3DS stack is a standard DDR4 die at
   the same speed bin, so CL / tRCD / tRP / tRAS are identical. **3DS does not raise idle latency
   by design.**
2. ✅ **3DS adds `_slr` / `_dlr` (same / different logical rank) timing variants** — `tRRD_dlr`,
   `tFAW_dlr`, `tCCD_L_dlr` — which do not exist on a flat DIMM. These are inter-die activate
   constraints and are generally **more relaxed** than their same-rank equivalents, because rows
   on different dies do not contend for the same bank resources. Net effect on parallelism is
   positive, not negative.
3. 🔴 **Refresh is the real cost, and it INVERTS the concern.** Deriving die density from the
   organisation at 64 GB and x4:

   | part | logical ranks | per rank | **die density** | tRFC / tREFI | **refresh overhead** |
   | --- | ---: | ---: | ---: | --- | ---: |
   | delivered 2S2Rx4 3DS | 4 | 16 GB | **8 Gb** | ~350 ns / 7812.5 ns | **~4.5%** |
   | advertised 2Rx4 flat | 2 | 32 GB | **16 Gb** | ~550 ns / 3906 ns | **~14.1%** |

   **Stacking 8 Gb dies avoids the monolithic-16 Gb refresh penalty that the part actually
   ordered would have carried.** ⚠️ Partly offset because 3DS refreshes per logical rank — four
   instead of two — but each is shorter and a refresh to one rank overlaps with access to
   another.

**So the substitution is not a latency liability and may be a small refresh advantage**, and the
measured 78.4% of theoretical peak is ordinary DDR4 behaviour with no anomaly to explain.
⚠️ **None of this changes the qwen4exp findings**: the sweep already showed bandwidth is not the
constraint (`-ncmoe 48` matches `-ncmoe 34`), and one card beating two has no memory path in it.

### ⛔ The 8-stick test could not run

A/B/E/F are empty — `ipmitool sdr type Temperature` reports `No Reading` on those four channels.
`./membench.sh` is committed so the 8-stick run is one command when the sticks arrive. **Sweep
threads above 8 on that run**, and re-measure latency with the huge-page fix in place.
