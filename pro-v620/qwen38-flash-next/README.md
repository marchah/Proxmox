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

## Measured, 2026-09-17 — first run of this architecture on RADV

✅ **It works.** Output is coherent, non-degenerate (8-gram ratio 1.0) and reproducible
across reps at temperature 0. As far as this KB can tell these are the first
Qwen3.8-Flash-Next numbers on a Vulkan/RDNA2 target anywhere — upstream validated CPU and
CUDA only, and the Vulkan hyper-connection ops merged hours before this ran.

🔴 **But it is ~4x slower than the sizing note predicts, and the note's whole method is
why.** At `--n-cpu-moe 20`, ctx 65536, two cards:

| | decode | note's prediction | my prediction |
| --- | ---: | ---: | ---: |
| 2 cards, `-ncmoe 20` | **11.74 t/s** | 51 t/s | 56 t/s |

Both estimates model decode as *active bytes ÷ bandwidth*. The measurement says that is
the wrong model for a hybrid placement — see the utilisation trace below.

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
17 GiB idle. Rule of thumb, now derived automatically by `placement-sweep.sh`:

```
card1_layers = N + (48 - N) / 2      # -ts card1_layers,(48 - card1_layers)
```

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
