# `qwen38-flash-next/` — Qwen3.8-Flash-Next (`qwen4exp`) on the V620s

**Qwen3.8-Flash-Next** — `qwen4exp`, 180B total / 6B active, `UD-Q4_K_XL` **111.33 GB** — with
the PLE table and a tunable share of the routed experts in system RAM. The first model on this
box that does **not** fit in VRAM; it is here because the EPYC platform has the RAM for it, and
~28.7 GB of it is a lookup table that belongs in host memory anyway.

## ✅ Where it actually runs, as of 2026-09-18

🔴 **CT 123 `gpu2`, on ONE card (`0000:83:00.0`), at `-ncmoe 34`.** Not CT 120, and not across
both cards. An earlier revision of this file described the two-card CT 120 shape as current and
told you to keep CT 123 stopped — **following that today would stop the server that is actually
serving this model.**

| | current deployment | the two-card alternative |
| --- | --- | --- |
| Container | **CT 123** `gpu2` | CT 120 `llamacpp`, 48 cores, 160 GiB, swap 0 |
| GPUs | **one** — `0000:83:00.0` | both — `0000:03:00.0` + `0000:83:00.0` |
| Placement | `-ncmoe 34`, no split | `-ncmoe 16`, `--tensor-split 30,18` |
| Decode | **13.01 / 12.23** t/s (d0 / 8k) | 14.46 / 13.37 |
| Prefill 8k | 39.1 t/s → **205 s** TTFT | 77.2 t/s → **104 s** TTFT |
| Deploy | `VMID=123 ENV_FILE=qwen38fn-gpu2.env ./install.sh` | `VMID=120 ./install.sh` then `./ct120-cutover.sh to-qwen38fn` |

**Why one card won.** At *matched* placement one card beats two by **20.9% at d0 / 24.2% at 8k**
with prefill tied — llama.cpp [#28699](https://github.com/ggml-org/llama.cpp/pull/28699)'s QSA
indexer crossing, **+16.1 ms/token per extra card boundary**. The second card is worth +11%
decode and +97% prefill, and costs a whole card that CT 120 uses for `qwen3.6-35b-a3b` (~5x
faster, and what the Hermes agent actually talks to). Re-test two cards if #28699's per-device
fix lands.

| | |
|---|---|
| Model | `unsloth/Qwen3.8-Flash-Next-GGUF` `UD-Q4_K_XL`, 4 shards, **111.33 GB** |
| Vision | `mmproj-F16.gguf`, 0.90 GB, ~1.1 GiB VRAM (on CPU in both shipped configs) |
| Engine | llama.cpp **b11018** — ⚠️ **b11013 is a hard floor**, see [the build floor](#corrections-to-the-sizing-note) |
| API | OpenAI-compatible on `0.0.0.0:1234`, alias `qwen3.8-flash-next` |
| Disk | CT 120 `/models` 320G · CT 123 `/models` 236G, ⚠️ **88% full, 27G free** — it holds this 111 GB model plus six retained llama-swap GGUFs |

⚠️ **The two containers must never hold the same card.** `ct120-cutover.sh to-qwen38fn` stops
CT 123 *and* clears its `onboot`, because a stopped container with `onboot: 1` comes straight
back onto the card after a host reboot. `to-qwen36` restores it.

The sizing analysis this implements lives in CognitiveStack
`personal/large-moe-build-shapes.md`. ⚠️ **Several of that note's premises turned out to be
wrong — see [Corrections](#corrections-to-the-sizing-note) before using its numbers to
justify a purchase.** Purchasing and DIMM discussion belongs there, not here.

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
(bare chat answers, and `"none"`/`"high"` are *harmless*) rather than assuming it.
🔴 **An earlier revision of this line said the probe asserts those two values are REJECTED.
It asserts the opposite, and the difference is the whole point of the server flag**: with
`--reasoning off` set, llama.cpp never hands the effort through to the template, so all five
levels return HTTP 200 with clean content. The probe fails if a level comes back non-200 or
empty — i.e. if the shield has regressed — not if it is accepted.

⚠️ `--reasoning-format auto` is separately load-bearing: with thinking off the template
still emits an **empty** `<think>\n\n</think>` pair, and `none` leaves it in `content` —
which silently corrupts every generated file. `auto` siphons it into `reasoning_content`.

## The placement dial — what each `--n-cpu-moe` actually does

`111.3 GB` does not fit `2 × 32 GB`. Two things come off the GPU, for different reasons:

1. **The PLE n-gram table** — `-ot per_layer_token_embd=CPU`, **always on, not a dial.**
   ~51B of the 180B checkpoint, ~28.7 GB at Q4, but it is a **row lookup, not a matmul**:
   a handful of rows per token, so it costs almost nothing in host RAM. This alone takes
   the GPU-side model from 111.3 GB to **~82.6 GB**, and it is why Q4 is reachable at all.
2. **Routed experts, layer by layer** — `--n-cpu-moe N` keeps the routed experts of the
   **first N** of the 48 layers in host RAM, ~1.5 GiB of Q4 expert weight each.
   **This is the dial.** (`-cmoe` is the all-48 shorthand.)

### What stays on the GPU, at every setting

`--n-cpu-moe` moves **only the routed experts**. Everything else is resident regardless of
N — which is what `-ncmoe 48` leaves behind, and why 48 is not "nothing on the GPU":

| always on the GPU | read per token |
| --- | --- |
| **attention for all 48 layers** — 12 Qwen Sparse Attention + 36 Gated DeltaNet | in full |
| the per-layer **shared** expert and the router | in full |
| norms, hyper-connection tensors, `output` | in full |
| the KV cache (12 full-attention layers only — 24 KiB/token f16, 12 at `q8_0`) | grows with ctx |

So **`-ncmoe 48` = attention + the dense path on the GPU (9.4 GiB), all routed experts in
RAM.** That is the floor of GPU residency for this model, not an "off" switch.

### ✅ Why the experts are the right thing to move, and attention is not

| | share of the model | read per token |
| --- | ---: | ---: |
| routed experts | ~61% | **2.0%** — only topk 10 of 512 fire |
| shared expert + router | 0.2% | 100% |
| attention | — | 100% |

61% of the weights account for only ~1.2 GiB of reads per token, because each token routes
to 10 of 512 experts. Attention and the dense path are read *in full* every token.

⚠️ **Measured, not assumed:** moving whole **layers** (attention included) to CPU cost
**−42%**, against **−28%** for moving only the experts at the same VRAM saving. Same memory
freed, very different penalty — which is why `--n-cpu-moe` exists as a separate flag from
`-ot`, and why a dense model of this size would be unusable in the same arrangement.

### Every setting tested, with measured VRAM

Two cards, the **corrected** split (`N + (48−N)/2 − 2`), ctx 65536. VRAM is **used**, read
after a load plus one completion so lazily-allocated buffers are included:

| `-ncmoe` | split | KV / projector | card 1 | card 2 | total | headroom | decode d0 / d8k |
| ---: | --- | --- | ---: | ---: | ---: | --- | ---: |
| 15 | `29,19` | f16 / GPU | 31094 M | 32715 M | 62.3 G | 🔴 **SPILLED** at every split | — |
| **16** | `30,18` | **q8_0 / CPU** | 29848 M | 30843 M | **59.3 G** | tight (2.9/1.9 G free) | **14.17 / 13.45** |
| 16 | `30,18` | f16 / GPU | 31431 M | 31174 M | 61.1 G | tight (1.3/1.6 G free) | 14.16 / 13.07 |
| 20 | `32,16` | f16 / GPU | 28738 M | 27864 M | 55.3 G | fits (4.0/4.9 G free) | 13.03 / 12.06 |
| 28 | `36,12` | f16 / GPU | 23216 M | 21381 M | 43.6 G | fits (9.6/11.4 G free) | ~11.3 / ~10.6 |

**One card** (`--device Vulkan0`, no split), `q8_0` + projector on CPU:

| `-ncmoe` | VRAM used | free on that card | decode d0 / d8k | prefill 8k |
| ---: | ---: | ---: | ---: | ---: |
| **34** | **31100 M (30.4 G)** | 1668 M | **13.01 / 12.23** | 39.1 |
| 36 | 28097 M (27.4 G) | 4671 M | 12.43 / 11.81 | 37.1 |
| 40 | 22089 M (21.6 G) | 10679 M | 11.40 / 10.94 | 33.7 |
| 48 | **9443 M (9.2 G)** | **23.3 G** | 10.18 / 8.70 | 29.0 |

✅ **Expert weight is ~1.5 GiB per layer and the figure is stable**, which is what makes the
dial predictable: measured 1502 MiB/layer over 34→36, 1502 over 36→40 and 1581 over 40→48,
averaging **1547 MiB**. Every VRAM prediction made from that average during the sweep landed
within ~120 MiB of the measurement, across four different shapes. ⚠️ Read the figures from
one consistent moment — a reading taken mid-cell versus after it differs by ~2 GiB of
transient compute buffer, which is enough to invent a non-uniformity that is not there.

🔴 **`-ncmoe 16` is the floor in practice.** ⚠️ **This paragraph used to say 15 "cannot fit in
any shape at any split", on a demand of "64.2 GiB against 64 GiB" — both wrong.** 64295 MiB is
**62.79 GiB**, which does *not* exceed the 64 GiB of total capacity, and that figure is for the
**f16 / projector-GPU** shape specifically. What is actually established:

- `15` **f16 / projector GPU**: 64295 MiB, ~620 MiB/card balanced — spills at any split.
- `15` **q8_0 / projector CPU**: 62394 MiB, ~1571 MiB/card balanced — *above* the ~1024 MiB RADV
  floor, so not excluded by capacity. Measured at split **`29,19`: SPILLED**, 3256 / **89 MiB**
  free — starved by maldistribution. **That split is excluded by measurement; other splits are
  unvalidated.**
- ✅ **The operative rule is a headroom POLICY, not a capacity proof** — but stated carefully,
  because the blunt version was wrong. 🔴 **An earlier revision of this bullet claimed a global
  "≥2048 MiB free on every card", which rejects the configurations this very file ships**: the
  two-card default's minimum is 1878 MiB, the one-card default's 1739, and the 131072-context
  row 1255. A universal rule invented in the paragraph that needed it is not a policy.
  The rule that actually applies:
  - **A NEW or UNVALIDATED placement needs ≥2048 MiB free on every card** to be adopted without
    an end-to-end load check. 15's best balanced *estimate* of 1571 MiB/card does not clear it.
  - **An existing placement below that is acceptable only with a measured minimum**, recorded
    here, per card, at its shipped batch size. The three exceptions above are exactly that, and
    the `4096/1024` run is what a config looks like when it fails: 877 MiB and GTT off its floor.
  - ⚠️ **Estimated-balanced is not measured-minimum.** Conflating them is what shipped the
    marginal default in the first place.
  See [the `-ncmoe 15` closure](#--ncmoe-15--closed-by-policy-not-by-physics).

🔴 **`-ncmoe 34` is the floor for one card**, at 30.4 GiB of 32. Below that a single card
cannot hold it; above it you are trading decode for headroom at ~0.29 t/s per layer.

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
**`-ncmoe 16` is the floor** — below it, only `15` + q8_0 + projector-CPU is even arithmetically
close, and it fails the ≥2048 MiB/card rule **for a new or unvalidated placement** (and spilled
at the one split measured). ⚠️ That rule does not apply retroactively — several shipped
configurations sit below it with a measured per-card minimum instead. See [the closure](#--ncmoe-15--closed-by-policy-not-by-physics).

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

### Leave room for a second model — and the one-card option is better than it looks

Two ways to free capacity, and they are not the same thing:

**(a) Keep both cards, move experts to RAM** — frees VRAM on both:

| `-ncmoe` | split | decode d0 | d8k | prefill 8k | VRAM freed | cost |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 16 | `30,18` | 14.17 | 13.45 | 76.9 | — | — |
| 20 | `32,16` | 13.03 | 12.06 | 63.6 | ~8.9 GiB | −8.0% |
| 28 | `36,12` | ~11.3 | ~10.6 | 47.4 | ~20.6 GiB | −20% |

**(b) Give a whole card back** — run on one card with `--device Vulkan0`:

| `-ncmoe` | VRAM on the one card | decode d0 | d8k | prefill 8k | cost vs 2-card best |
| ---: | ---: | ---: | ---: | ---: | ---: |
| **34** | 30.4 G (1.7 G free) | **13.01** | **12.23** | 39.1 | **−10%** |
| 36 | 27.4 G (4.6 G free) | 12.43 | 11.81 | 37.1 | −14% |
| 40 | 21.6 G (10.4 G free) | 11.40 | 10.94 | 33.7 | −21% |
| 48 | **9.2 G (23.3 G free)** | 10.18 | 8.70 | 29.0 | −30% |

🔴 **`-ncmoe 34` on one card is the right way to hand CT 123 a card back** — 13.01 t/s, only
−10% off the two-card best, with card 2 completely idle. An earlier version of this file
recommended `-ncmoe 48` for that; at 10.18 t/s it is 28% slower than necessary. Pick 48 only
when you also want ~23 GiB spare *on the remaining card*.

⚠️ **Decode and prefill do not agree on which option to take.** Giving a card back costs
−10% of decode but **−49% of prefill** (77.2 → 39.1 t/s, i.e. 8k time-to-first-token 104 s →
205 s). If your prompts are long, keep both cards; if they are short, one card is nearly free.

### 🔴 The second card is a DECODE PENALTY and a PREFILL WIN

Measured as a matched pair — same placement, same shape, same thread count, only the device
count differs:

| `-ncmoe 34`, `q8_0`/projCPU | decode d0 | decode d8k | prefill 8k |
| --- | ---: | ---: | ---: |
| **one card** | **13.01** | **12.23** | 39.1 |
| two cards (`34,14`) | 10.76 | 9.85 | 38.9 |
| | **+20.9%** | **+24.2%** | +0.5% |

**One card is 21–24% faster at the same placement, and prefill is identical.** That
asymmetry is the signature of a fixed per-token cost, the same shape as this repo's PCIe
decode-tax finding: prefill batches thousands of tokens per submission so the per-layer
crossing amortises away, while decode pays it on every token. It is exactly what llama.cpp
**#28699** describes — the QSA indexer shipping pooled rows across the inter-GPU link every
layer — and the per-device fix there is still an open draft.

So what the second card is worth, net:

| | decode d0 | prefill 8k |
| --- | ---: | ---: |
| 2 cards @ `-ncmoe 16` | 14.46 | 77.2 |
| 1 card @ `-ncmoe 34` | 13.01 | 39.1 |
| **gain from card 2** | **+11%** | **+97%** |

It gives with one hand and takes with the other: 18 more expert layers resident, minus a
~21% inter-GPU decode tax. **Prefill pays no tax, so that is where the second card earns its
place** — it halves time-to-first-token. ✅ If #28699's per-device fix lands, the two-card
configuration should recover most of that 21%, and this table should be re-measured.

⚠️ This is why `CLAUDE.md` says to run a one-GPU control before concluding two cards help.
That advice was right; it now has a number.

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
| `--threads 32` | −4 to −5% solo; 16 is best at 2+ streams (8 edges it ~1% solo, then loses 4.9% at 4) |
| the documented `--tensor-split` | ~2 layers off; spills at `-ncmoe` 15/16/20 and costs up to −11% |
| f16 KV at `--ctx-size 131072` | spills at `-ncmoe 16` and costs −21% of decode at depth |
| `-ncmoe` below 16 | fails the ≥2048 MiB/card rule for a NEW placement; `15`+q8_0+projCPU spilled at the one split measured |
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

### `--threads`: 32 is contention — but do NOT conclude a winner from these rows

| threads | decode d0 | decode d8k | prefill d8k |
| ---: | ---: | ---: | ---: |
| 8 | 13.13 | 11.87 | 63.8 |
| **16** | **13.19** | **12.11** | 63.7 |
| 32 (the inherited default) | 12.69 | 11.53 | 63.6 |

**32 threads is contention, worth −4 to −5%.** STREAM corroborates it from a completely
different direction: 8 threads saturated the four populated channels at 80.3 GB/s while 32
measured *worse* at 74.8 — the CPU-side expert FFN is bandwidth-bound GEMV, so past
saturation extra threads only fight each other. Prefill is flat across all three, so this is
free.

🔴 **What survives here is only "32 is contention". The 8-vs-16 question cannot be settled
single-stream, and this table is single-stream** — the two are within 0.5% at n=1, which an
earlier revision of this section read as "an inverted U with the peak at 16". Measured across
concurrency, **8 actually wins solo and loses 4.9% at four streams**; see
[`--threads` inverts with load](#---threads-inverts-with-load--do-not-tune-it-single-stream),
which is the section to trust. 16 is the right default, for a reason this table cannot see.
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
| `15`, q8_0, projector CPU | 62394 | 1571 | 🔴 **measured at `29,19`: SPILLED** (3256 / 89 MiB) |
| **`16`, q8_0, projector CPU** | **60691** ✅measured | **2422** | ✅ **14.17 / 13.45 — the best cell** |
| `16`, f16, projector GPU | 62794 computed / 62605 measured | 1371 | 14.16 / 13.07; vision stays resident |

🔴 **This table's verdicts were written against the retracted "q8_0 costs ~14% at depth"
figure and they came out backwards.** With the clean pair measured at one placement that
fits (see [that retraction](#-q8_0-kv--projector-on-cpu-is-free-at-a-placement-that-fits)),
`q8_0` + projector-on-CPU is **better on both axes at once**: +2.9% decode at depth
(13.45 vs 13.07) *and* 1.6 GiB more headroom (59.3 vs 61.1 GiB of demand). It is what the
deployed config runs. Take the f16 / projector-on-GPU row only if **image-encoding latency**
matters, which is the one thing it actually buys.

### 🔴 `-ncmoe 15` — closed by POLICY, not by physics

⚠️ **Two wrong things were said about 15 in a row, in opposite directions.** First it was
excluded as "cannot fit in any shape at any split" (a unit error: 62.79 GiB, not 64.2, and only
the f16 shape was measured). Then the q8_0 retraction was used to call it an "untested candidate"
that "nobody re-tested" — also wrong, because the saved results contain a load-check of it.
What the record actually supports:

- **Measured**: `15` + q8_0 + projector-CPU at split **`29,19` SPILLED**, 3256 / **89 MiB** free.
  Card 2 was starved by maldistribution. That split is dead.
- **Not established**: that *every* split at 15 fails. A perfect rebalance of the ~1500 MiB
  between those cards would be roughly 1756 / 1589 MiB, and discrete layers may make it
  unattainable — it has to be measured, not derived.
- **The projected gain is ~2%**: one expert layer is ~1.52 ms on a ~69 ms token → ~14.8 t/s.
- **Larger batch and 15 are mutually exclusive.** `4096/1024` costs ~1000 MiB on the heavy card;
  a hypothetical perfect rebalance would leave ~1071 MiB/card, **47 MiB above the ~1024 floor**.
  Not impossible — just far too marginal to run, and the larger batch is worth **2-3× prefill**,
  which is the binding constraint.

✅ **Closure**: at `-ncmoe 15`, q8_0 KV and CPU projector, split `29,19` was measured and failed
the headroom check. Other splits remain unvalidated. Further testing is **deprioritized**: the
projected decode gain is ~2%, the estimated balanced headroom of 1571 MiB/card fails this
folder's **≥2048 MiB/card rule for a new or unvalidated placement**, and larger-batch configurations at `-ncmoe 16`
offer the more promising prefill improvement. **Not a supported production configuration** — and
that is a headroom-policy decision, not a claim that the model cannot fit.

⚠️ **The frugal shape still does not buy a whole placement step**, but the reason is the policy,
not the arithmetic: `q8_0` + `--no-mmproj-offload` saves ~1900 MiB while one layer of experts
costs ~1500, so trading the cache shape for a layer nets ~400 MiB — which does not lift 15's
~1571 MiB/card to the ≥2048 MiB the policy requires.

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
hybrid placement, and measured reality is ~5x below it.**

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
  `ct120-cutover.sh` does this. ⚠️ **The "stock map sends GPU 2 to `123:llama-swap`" warning
  here is now historical** — both the committed default and the live map name
  `123:llamacpp-qwen38fn`, fixed 2026-09-18 after llama-swap was removed. The hazard it
  describes is real and general: **a map naming a unit that is not running makes a trip a
  no-op**, leaving the real load on an overheating card. `to-qwen36` puts the map back.
- ⚠️ **`gpu-ab-bench/thermal-guard.sh` and `sample-gpus.py` are B550-era** and still name
  `0000:2d:00.0` / `0000:06:00.0`. Those paths do not exist here, so the guard's hwmon
  glob never matches, `cat` fails, and `set -e` kills it within a second — it fails
  **silently open**. Use this folder's `thermal-guard.sh` on the EPYC box.
- ⚠️ **The MTP drafter is deliberately not deployed.** Speculation for `qwen4exp` appears
  to live only in an out-of-tree `qwen4exp-spec-mtp` fork, and this KB's own rule is not
  to pay for a drafter with no merged runtime. At 6B active, draft/verify overhead would
  likely dominate anyway.

## ✅ End-to-end verification of the shipped two-card default — 2026-09-18

Every throughput number above came from `placement-sweep.sh`, which pins **batch/ubatch
1024/256**. The launcher defaults to **4096/1024**, and neither env file said so — so the shipped
default ran at 4x the batch of the run that validated it. A code review flagged that as a
verification gap. It was real. The exact `install.sh` two-card default was loaded end-to-end on
CT 120 (CT 123 stopped, thermal guard armed, reverted afterwards):

```
--threads 16 --batch-size 4096 --ubatch-size 1024 --n-cpu-moe 16 --tensor-split 30,18 --cache-type-k q8_0
healthy after 111 s
```

| batch/ubatch | min free card1 / card2 | max GTT card1 / card2 | decode d8k | prefill d8k |
| --- | ---: | ---: | ---: | ---: |
| 1024/256 (the sweep) | 2881 / 1878 MiB | no spill | 13.37 | 77.2 |
| **4096/1024 (launcher default)** | 2922 / **877 MiB** 🔴 | **306** / 18 MiB 🔴 | 12.65-12.79 | **173-236** |

🔴 **The default was marginal.** Card 2 fell to **877 MiB free, under the ~1024 MiB RADV spill
floor**, and card 1's GTT rose to **306 MiB against a ~70 MiB idle floor**. So the bigger compute
buffers cost roughly a gigabyte on the card holding the heavy layers. The env now pins
**1024/256** — the combination actually measured with this split — rather than shipping the
marginal one.

✅ **The finding worth keeping: the right `--tensor-split` is BATCH-SIZE DEPENDENT.** The compute
buffer scales with batch and lands on whichever card holds the heavy layers, so batch size and
split are coupled knobs, not independent ones. That is also *why* the `− 2` correction exists:
it was derived at 1024/256. At 4096/1024 this placement wants roughly **`31,17`** — one heavy
layer moved off card 2, ~1.5 GiB — and that is **untested**.

⚠️ **And 4096/1024 is 2-3x faster at prefill** (173-236 vs 77.2 t/s), which is the binding
constraint for this model. So the tempting configuration is `-ncmoe 16` + `31,17` + `4096/1024`.
**Test it before shipping it** — verify both cards' free VRAM *and* GTT, not throughput. Shipping
an unverified marginal config is the mistake this file already made once.

⚠️ Ignore the d0 prefill figures from that run (4.4-12.8 t/s): those prompts are ~30 tokens, so
the number is fixed per-request overhead, not throughput. Only the d8k column means anything.

✅ The template contract held throughout: `bare_chat ok=True`, no `<think>` leakage.

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
⚠️ **Not "all clean" — that claim was wrong.** `shellcheck -S warning` (0.11.0) reports
**10 × SC2034** across `mtp-standalone.sh` and `stage-harness.sh`: fixture variables consumed
by stage bodies pulled in with `eval`, which shellcheck cannot see. They are false positives,
not ten defects, and are now silenced with file-scoped directives carrying that reason, so the
command is clean. ✅ **Verify with the exact command**, because a loop over
`git diff --name-only` after committing iterates an empty list and prints nothing — which is
how the false claim was produced:

```sh
git ls-files '*.sh' | xargs shellcheck -S warning
```

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

Condensed: the full JEDEC derivation is purchasing analysis, not a finding about this model, and
belongs in CognitiveStack `personal/hardware.md` / `large-moe-build-shapes.md`. The conclusions:

- The installed modules are Samsung `M393A8K40B22-CAE`, **2S2Rx4 3DS** (SPD `Rank: 4`), against
  the advertised flat 2Rx4 `M393A8G40AB2-CWE`.
- ✅ **No latency liability by design** — every die in a 3DS stack is a standard DDR4 die at the
  same speed bin, so CL/tRCD/tRP/tRAS are identical; and the `_slr`/`_dlr` inter-die variants it
  adds are *more* relaxed than their same-rank equivalents.
- 🔴 **Refresh inverts the concern**: stacking 8 Gb dies carries ~4.5% refresh overhead against
  ~14.1% for the monolithic 16 Gb dies the advertised part would have used. The measured 78.4% of
  theoretical peak is ordinary DDR4 behaviour with nothing anomalous to explain.
- ⚠️ **None of this changes the qwen4exp findings.** The sweep already showed bandwidth is not
  the constraint, and one card beating two has no memory path in it. This sentence used to cite
  "`-ncmoe 48` matches `-ncmoe 34`" as its evidence; it does not — the matched one-card rows are
  **10.18 vs 13.01 t/s**, that apparent tie compared a one-card `48` against a *two-card* `34`
  and was a downclocked-governor artifact. Withdrawn; the argument stands on the
  alternating-device and flat-DIMM evidence instead.

### ⛔ The 8-stick test could not run

A/B/E/F are empty — `ipmitool sdr type Temperature` reports `No Reading` on those four channels.
`./membench.sh` is committed so the 8-stick run is one command when the sticks arrive. **Sweep
threads above 8 on that run**, and re-measure latency with the huge-page fix in place.
