# Radeon RX 6700 XT

Scripts in this folder target the desktop server with a Radeon RX 6700 XT.

Two **interchangeable LLM runtime** scripts serve the *same* model on this GPU
via Vulkan, differing only in the inference engine. Both default to CT `120`,
expose an OpenAI-compatible API on `0.0.0.0:1234`, and serve the model under the
identifier `qwen3.5-9b`, so the `bench-runner` suite benchmarks either one
unchanged. They are mutually exclusive (only one can use the 12 GiB GPU at a
time, and both claim VMID 120) — destroy the existing CT 120 before creating the
other:

- `create-lxc-lmstudio-qwen3.5-9b.sh` — LM Studio's `lms` CLI (hot model reload).
- `create-lxc-llamacpp-qwen3.5-9b.sh` — llama.cpp's `llama-server` (reload =
  restart, via the `llamacpp-reload` helper).

## Recommendation

**Use llama.cpp (`create-lxc-llamacpp-qwen3.5-9b.sh`) with the default
`--parallel 4`.** On this GPU it matches LM Studio for a single user, nearly
doubles concurrent throughput, and — unlike LM Studio — never corrupts long cold
prompts. (Both are measured below; numbers are `Qwen3.5-9B-Q4_K_M`, 64 k context,
`openai-direct`, distinct/cold prompts.)

| Metric | LM Studio | llama.cpp | Why it matters |
| --- | ---: | ---: | --- |
| Single-stream throughput | 53 tok/s | **56 tok/s** | interactive 1-user speed |
| Concurrent aggregate (4 slots, knee) | ~47 tok/s | **80 tok/s** | multi-client serving |
| Cold-prefill correctness | **garbage ≥ ~6 k tok** (sticky) | correct through 32 k | reliability on long inputs |
| Single-stream TTFT (short prompt) | ~0.2 s | ~0.2 s | first-token latency |

**Settings:**

- **`--parallel 4`** (script default) for any multi-client serving — 4
  continuous-batching slots reach ~80 tok/s aggregate (knee at concurrency 4) vs
  ~42 tok/s *flat* at 1 slot, at no single-user cost (~56 tok/s either way). Each
  slot gets 64 k ÷ 4 ≈ 16 k of context.
- **`--parallel 1`** only for a single very long cold prompt (one slot owns the
  full 64 k context, so 16 k–32 k cold prefills run) or to save VRAM. One slot
  does not batch — concurrency stays ~42 tok/s flat with linearly growing latency.
- Cold prefill costs ~1.4 s per 1 k input tokens (TTFT), the same on both engines
  — it is **GPU-bound** (~99 % util, ~7 GiB / 12 GiB VRAM, junction ≤ ~103 °C, no
  throttling). Keep latency-sensitive one-off prompts short, or reuse a cached
  prefix.

Full per-engine data and methodology are in [Benchmarks](#benchmarks) below.

## LM Studio Qwen3.5 9B LXC

`create-lxc-lmstudio-qwen3.5-9b.sh` creates an Ubuntu LXC intended to run LM
Studio's `lms` CLI in headless/server mode with the RX 6700 XT passed through.

This script is deliberately narrow:

- GPU: Radeon RX 6700 XT
- GPU runtime: Vulkan (mesa RADV)
- Repository: `unsloth/Qwen3.5-9B-GGUF`
- File: `Qwen3.5-9B-Q4_K_M.gguf`
- Identifier: `qwen3.5-9b`
- Context length: `64000`
- GPU offload: `max`
- API bind: `0.0.0.0:1234`
- Model storage: `/models`

Run it on the Proxmox host as `root`:

```bash
./create-lxc-lmstudio-qwen3.5-9b.sh
```

Useful Proxmox/container overrides:

```bash
VMID=120 LXC_HOSTNAME=lmstudio ./create-lxc-lmstudio-qwen3.5-9b.sh
MODELS_SIZE_GB=500 MEMORY_MB=24576 CORES=8 ./create-lxc-lmstudio-qwen3.5-9b.sh
PASSWORD='temporary-root-password' ./create-lxc-lmstudio-qwen3.5-9b.sh
```

The script creates:

- a privileged Ubuntu LXC
- a local `/models` mount on `local-lvm` with backup disabled
- `/dev/dri` passthrough (the Vulkan render node) for AMD GPU access
- the Vulkan userspace (`mesa-vulkan-drivers`) so LM Studio offloads to the GPU
- a `lmstudio` user inside the container
- a systemd service named `lmstudio.service`

Check the service inside the LXC:

```bash
pct exec 120 -- systemctl status lmstudio.service
pct exec 120 -- journalctl -u lmstudio.service -n 100 --no-pager
```

Check the OpenAI-compatible endpoint:

```bash
curl http://<container-ip>:1234/v1/models
```

## llama.cpp Qwen3.5 9B LXC

`create-lxc-llamacpp-qwen3.5-9b.sh` creates the same kind of Ubuntu LXC but runs
**llama.cpp's `llama-server`** (a pinned prebuilt Vulkan release) instead of LM
Studio. It serves the identical model and exposes the same OpenAI-compatible API,
so it is a drop-in alternative engine for benchmarking.

This script is deliberately narrow:

- GPU: Radeon RX 6700 XT
- GPU runtime: Vulkan (mesa RADV)
- Engine: llama.cpp `llama-server`, prebuilt Vulkan x64 release (pinned by tag +
  SHA-256 in the script — bump both from the [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases))
- Repository: `unsloth/Qwen3.5-9B-GGUF`
- File: `Qwen3.5-9B-Q4_K_M.gguf`
- Identifier (`--alias`): `qwen3.5-9b`
- Context length: `64000` (`--ctx-size`)
- GPU offload: `--n-gpu-layers 99` (all layers)
- Parallel slots: `--parallel 4` (continuous batching, on by default)
- API bind: `0.0.0.0:1234`
- Model storage: `/models`

Run it on the Proxmox host as `root` (destroy the existing CT 120 first if it is
the LM Studio container):

```bash
./create-lxc-llamacpp-qwen3.5-9b.sh
```

The script creates a privileged Ubuntu LXC with the same `/models` mount and
`/dev/dri` passthrough as the LM Studio one, plus the Vulkan userspace and the
**libglvnd/EGL stack** (`libglvnd0 libgl1 libglx0 libegl1`) — without the latter
the Mesa ICD loader can silently report zero Vulkan devices inside the container.
It installs:

- a `llamacpp` user and a `llamacpp.service` systemd unit (`Type=simple`, runs
  `llama-server` in the foreground)
- `/etc/llamacpp.env` holding the tunable start flags (context length, parallel)
- `/usr/local/bin/llamacpp-serve` (the service entrypoint) and
  `/usr/local/bin/llamacpp-reload`

Unlike LM Studio's `lms load`, llama-server sets context length and parallel
slots at process start, so changing them means restarting the server. Use the
helper rather than editing by hand:

```bash
pct exec 120 -- llamacpp-reload <context-length> <parallel>   # e.g. 32768 4
```

Check the service and endpoint:

```bash
pct exec 120 -- systemctl status llamacpp.service
pct exec 120 -- journalctl -u llamacpp.service -n 100 --no-pager   # shows the chosen Vulkan device
curl http://<container-ip>:1234/v1/models                          # id == qwen3.5-9b
```

## Storage

The container stores model files under `/models`, backed by local Proxmox
storage. The mount has `backup=0` because model weights are large and
re-downloadable. Back up container configuration, service files, prompts, and
small application state separately.

## AMD GPU (Vulkan)

The RX 6700 XT is driven through **Vulkan** (mesa RADV). The script installs the
Vulkan userspace (`mesa-vulkan-drivers libvulkan1 vulkan-tools`) in the container
and passes through `/dev/dri`; LM Studio then offloads the model to the GPU with
`--gpu max`. Confirm the GPU is visible to Vulkan:

```bash
pct exec 120 -- vulkaninfo --summary
```

You should see `AMD Radeon RX 6700 XT` under the `radv` driver, and the model
resident in VRAM once it loads (check with `cat /sys/class/drm/card0/device/mem_info_vram_used`).

## Benchmarks

Two engines, same GPU/model, measured the same way (`make bench RUNTIME=<engine>
PARALLEL=<n>`, `openai-direct` target, distinct/cold prompts). Headline: on this
GPU llama.cpp matches LM Studio single-stream (~56 vs ~53 tok/s), scales **higher**
under concurrency (~80 vs ~47 tok/s aggregate at 4 slots), and — notably — **does
not reproduce the LM Studio cold-prefill correctness cliff**: every cold prefill
up to 32 k tokens returned valid output (8/8), where LM Studio corrupts output
above ~6 k. See the [Recommendation](#recommendation) for the short version.

### llama.cpp

llama.cpp `llama-server` (build `b9828`, Vulkan), 64 k total context, full GPU
offload (`-ngl 99`). Measured from the `bench-runner` LXC via `openai-direct`,
distinct (cold) synthetic prompts. `--reasoning-format none`, so the model's
`<think>` tokens count as normal output (Qwen3.5 is a reasoning model).

#### `--parallel 4` (recommended)

4 continuous-batching slots, so each slot gets 64 k ÷ 4 ≈ 16 128 tokens of context.

**Single stream (baseline):** 55.97 tok/s, TTFT 0.13 s p50 / 0.20 s p95, GPU ~99 %
util, 7.05 GiB VRAM (of 12), junction 87 °C — all SLOs pass.

**Concurrency scaling** (cold, ~512-token prompt, 128 output, 32 requests/point):

| Concurrency | OK | Aggregate tok/s | p95 latency | p50 TTFT |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 32/32 | 42.2 | 3.0 s | 0.80 s |
| 2 | 32/32 | 63.1 | 4.1 s | 1.54 s |
| 4 | 32/32 | **80.0** | 6.5 s | 3.05 s |
| 8 | 32/32 | 79.8 | 12.8 s | 9.46 s |
| 16 | 32/32 | 79.8 | 25.7 s | 22.27 s |

Saturation knee at concurrency 4 (~80 tok/s); past it throughput is flat while
tail latency doubles each step. Every point was 32/32 OK. Markedly higher than
LM Studio's cold aggregate (~42–47 tok/s) for the same workload.

**Prefill / TTFT vs input length** (cold, concurrency 1, 32 output, 8 req/point):

| Input tokens | OK | Cold TTFT p95 | Notes |
| ---: | ---: | ---: | --- |
| 128 | 8/8 | 0.35 s | |
| 512 | 8/8 | 0.80 s | |
| 2,048 | 8/8 | 2.71 s | |
| 8,192 | 8/8 | 11.58 s | **valid output — no cliff** |
| 32,768 | 0/8 | — | exceeds the 16 128-token per-slot context (64 k ÷ 4) |

Cold prefill scales ~linearly (~1.4 s per 1 k tokens). 8 k cold prefill stays
coherent (8/8) — no cliff. The 32 768 point is a hard rejection (input > per-slot
context), **not** corruption; for >16 k single prompts use `--parallel 1` below.

**Soak** (concurrency 2): 18/18 OK, 81.7 tok/s, coherent; junction peaked ~96 °C,
no clock throttling.

#### `--parallel 1`

Single slot owns the full 64 k context — directly comparable to the LM Studio
`--parallel 1` data below, and able to run cold prefills up to 64 k.

**Single stream (baseline):** 55.82 tok/s, TTFT 0.20 s p95, GPU ~99 % util,
6.93 GiB VRAM, junction 97 °C.

**Concurrency scaling** (cold, ~512-token prompt, 128 output, 32 requests/point):

| Concurrency | OK | Aggregate tok/s | p95 latency | p50 TTFT |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 32/32 | 42.1 | 3.0 s | 0.80 s |
| 2 | 32/32 | 42.2 | 6.1 s | 3.82 s |
| 4 | 32/32 | 42.1 | 12.2 s | 9.92 s |
| 8 | 32/32 | 42.1 | 24.3 s | 22.08 s |
| 16 | 32/32 | 42.0 | 48.7 s | 46.44 s |

One slot **serializes**: aggregate throughput is pinned at the single-stream rate
(~42 tok/s) while latency/TTFT grow linearly — no batching gain (cf. `--parallel 4`
reaching ~80). Still higher than LM Studio's ~33 tok/s flat.

**Prefill / TTFT vs input length** (cold, concurrency 1, 32 output, 8 req/point):

| Input tokens | OK | Cold TTFT p95 | Notes |
| ---: | ---: | ---: | --- |
| 128 | 8/8 | 0.35 s | |
| 512 | 8/8 | 0.80 s | |
| 2,048 | 8/8 | 2.64 s | |
| 8,192 | 8/8 | 11.60 s | valid — LM Studio emits garbage here |
| 32,768 | 8/8 | 138.0 s | **valid — slow but correct (no cliff)** |

This is the key correctness result: with the full 64 k context available, llama.cpp
served **every** cold prefill up to 32 k correctly (8/8), including the sizes where
LM Studio reliably produces sticky garbage (≥6 k). Throughput at 32 k is tiny
(~0.23 tok/s — prefill-bound, 138 s TTFT) but the output is coherent.

**Soak** (concurrency 2): 18/18 OK, 55.94 tok/s, coherent; junction peaked
~103 °C (below the 105 °C warn line), no throttling.

#### Conclusions

- **Correctness: no cold-prefill cliff.** llama.cpp `b9828` served valid output for
  every tested cold prefill (to 32 k at 1 slot, to 16 k per slot at 4 slots). The
  LM Studio ≥6 k garbage cliff did **not** reproduce — the single biggest reason to
  prefer llama.cpp on this GPU.
- **Single-user speed is a wash** (~56 tok/s, TTFT ~0.2 s) and independent of
  `--parallel`.
- **Concurrency needs `--parallel 4`.** 4 slots batch to ~80 tok/s aggregate (knee
  at c4); 1 slot serializes at ~42 tok/s flat. Single-user cost of 4 slots is nil,
  so the script defaults to 4 — drop to 1 only for >16 k single prompts or to save
  VRAM.
- **GPU-bound**: ~99 % GPU util, ~7 GiB / 12 GiB VRAM, model-container CPU ≤ ~30 %.
  The ceiling is GPU compute and cold-prefill cost (~1.4 s/1 k tokens), not heat or
  memory. Thermals fine (junction ≤ 103 °C, no throttling).

> **Methodology note.** Numbers above are the `openai-direct` target, which counts
> tokens from the server's exact `usage.completion_tokens` — treat it as the
> source of truth. The suite's `llama-benchy` target also runs (the suite passes
> `--skip-coherence`, since a reasoning model's `<think>`-prefixed reply trips
> llama-benchy's "capital of France → Paris" gate). Its tok/s reads ~10 % high
> (≈62 vs 56) because it counts output with a gpt2 approximation: the served GGUF
> exposes no transformers-loadable tokenizer, so `--tokenizer` falls back. Set
> `LLAMA_BENCHY_TOKENIZER=<hf-repo-with-a-real-tokenizer>` for exact counts.

### LM Studio

> ⚠️ **Correctness cliff — cold prefill above ~6k tokens.** On this GPU (RX 6700 XT,
> Vulkan/RADV) a *cold* prefill (a prompt not served from the prefix cache) starts
> emitting garbage — strings of `?` — once it exceeds ~6–7k tokens (probabilistically),
> and does so reliably by ~8k. It is **not** thermal or VRAM (junction ~95 °C, >14 GiB host RAM free); it looks
> like runtime numerical instability in the large-prefill compute. Worse, it is **sticky**: once a
> request trips it, the model serves garbage to *every* later request (even "Hello") until
> the model is reloaded. Bisection (reload + one cold prefill per size):
>
> | Cold prefill | Garbage |
> | ---: | ---: |
> | ~6,656 tok | 0/4 |
> | ~7,168 tok | 1/4 |
> | ~7,680 tok | 2/4 |
> | ~8,192 tok | 4/4 |
>
> (That table is reload-before-each-probe; a back-to-back input-length sweep with no reload
> between sizes saw ~6,144 fail too, so treat ~6k as the practical ceiling.) Prefix-cached
> prompts of the same length are fine (the cache skips the cold compute), which is why
> earlier cached runs missed it. Keep one-off prompts under ~4k tokens to stay clear, lean
> on prefix caching for longer stable contexts, and reload the model if output turns to
> `?`. Any benchmark number below for ≥6k cold input is therefore **invalid (garbage)**.

#### `--parallel 1`

Measured from the `bench-runner` LXC against this container's endpoint. Setup:
RX 6700 XT (12 GiB) via Vulkan, Ryzen 5 5600, `Qwen3.5-9B-Q4_K_M`, 64k context,
`--parallel 1`. Throughput is the reliable GPU signal — the amdgpu VRAM counter
reads ~0 when idle, so don't judge GPU use by it.

All numbers below are from `make bench PARALLEL=1` with **distinct (uncached) prompts**.

**Single stream (baseline):** 53.0 tok/s, TTFT 0.21 s p50 / 0.38 s p95, GPU ~99% util
(real promptset prompts, concurrency 1).

**Concurrency scaling** (cold, 512-token prompt, 128 output, 32 requests/point):

| Concurrency | Aggregate tok/s | p95 latency | p50 TTFT |
| ---: | ---: | ---: | ---: |
| 1 | 33.8 | 3.6 s | 1.4 s |
| 2 | 33.1 | 7.3 s | 4.6 s |
| 4 | 32.6 | 14.5 s | 11.0 s |
| 8 | 33.0 | 27.8 s | 23.8 s |
| 16 | 33.2 | 53.9 s | 50.4 s |

With a single slot, concurrent requests **serialize**: aggregate throughput stays pinned at
the cold single-stream rate (~33 tok/s for this 512-in/128-out workload) while latency and
TTFT grow linearly with concurrency. No batching gain at one slot — see `--parallel 4` for
that. (The ~33 is below the 53 tok/s baseline because each request pays a cold ~512-token
prefill of ~1.4 s, which the longer-output baseline amortizes.)

**Prefill / TTFT vs input length** (cold, distinct prompts; concurrency 1):

| Input tokens | Cold TTFT |
| ---: | --- |
| 512 | ~1.3 s |
| 2,048 | ~4.5 s |
| 4,096 | ~8.8 s |
| ≥6,144 | **garbage output — correctness cliff** |

Cold prefill scales ~linearly (~2 s per 1k tokens) up to the cliff; this run's 6,144 point
came back all `?`. Prefix-cached repeats are sub-second.

**Soak** (~6 min, concurrency 2): 52.9 tok/s (serialized — single slot), coherent output;
junction peaked ~95–103 °C, clocks held, no thermal throttling.

**Observations**

- **GPU-bound, confirmed from the model container**: ~99% GPU utilization on every
  workload, while the model container's CPU peaks at only ~10% and >14 GiB RAM stays free.
  Target-side telemetry samples the model container itself (not just the bench-runner
  client) and the report now derives its CPU utilization, so the limiter is confirmed to be
  GPU compute, not host CPU or memory.
- VRAM use is ~7.2 GiB of 12 GiB during inference, freed when idle.
- **One slot = serial service**: concurrent clients queue rather than batch, so aggregate
  throughput never exceeds the cold single-stream rate (~33 tok/s) and tail latency climbs
  linearly (c16 p95 ~54 s, TTFT ~50 s). Concurrency pays off only with more slots.
- **Prefill dominates at long context** — cold TTFT climbs ~linearly (~2 s/1k tokens) up to
  the correctness cliff (~6k cold tokens), beyond which output is garbage, not just slow.
- **Thermals are fine**: junction peaked ~95–103 °C under sustained load, below the
  105 °C warn line, with no clock throttling.

#### `--parallel 4`

Same setup, model reloaded with `--parallel 4` (4 continuous-batching slots). The numbers
below are from `make bench` with **distinct (uncached) prompts per request** — the suite
now adds a unique nonce to each synthetic request, so these are honest *cold* figures.
Earlier runs reused one identical prompt, so every request after the first was a
prefix-cache hit; that inflated aggregate throughput to ~90 tok/s and hid the cold cost.

**Single stream (baseline):** ~53 tok/s, TTFT 0.20 s p50 / 0.36 s p95, GPU ~99% util.

**Concurrency scaling** (cold, 512-token prompt, 128 output, 32 requests/point):

| Concurrency | Aggregate tok/s | p95 latency | p50 TTFT |
| ---: | ---: | ---: | ---: |
| 1 | 33.0 | 3.7 s | 1.4 s |
| 2 | 40.0 | 7.3 s | 1.6 s |
| 4 | 41.7 | 11.3 s | 4.0 s |
| 8 | 44.8 | 22.4 s | 12.4 s |
| 16 | **47.1** | 45.5 s | 33.2 s |

With distinct prompts every request pays a cold ~512-token prefill (~1.4 s), so batching
gains are modest — aggregate rises gently to ~47 tok/s by c16, not the ~90 the cache-warm
workload showed. The honest ceiling depends on prompt reuse: ~47 tok/s for all-distinct
prompts, up to ~90 tok/s when requests share a long cached prefix (e.g. a fixed system
prompt).

**Prefill / TTFT vs input length** (cold, concurrency 1):

| Input tokens | Cold TTFT | Notes |
| ---: | ---: | --- |
| 512 | ~1.4 s | |
| 2,048 | ~4.5 s | |
| ~6,656 | ~14 s | last reliably-coherent cold size |
| 8,192 | — | **garbage output — correctness cliff** |
| 32,768 | — | **garbage output** |

Cold prefill scales ~linearly (~2 s per 1k tokens) up to the cliff. Prefix-cached repeats
are sub-second.

**Soak:** not reported for this run — the soak ran after the input-length sweep tripped the
cliff, so the model was already serving garbage and its throughput is meaningless. (Earlier
cache-warm soak: ~73 tok/s at concurrency 2, junction ~102 °C, no throttling.)

**Observations**

- **Prefix caching dominates throughput.** Cold distinct-prompt aggregate peaks ~47 tok/s
  (c16); cache-warm identical prompts reach ~90. Quote the one that matches your traffic.
- **Single user is snappy only when cached**: at concurrency 1 with a cached/short prompt,
  ~53 tok/s and ~0.2 s TTFT; a cold 512-token prefill instead costs ~1.4 s TTFT.
- **Modest batching gain on cold load**: 33 → 47 tok/s from c1 to c16, with tail latency
  climbing steeply (c16 p95 ~46 s) — past c≈4 you buy little throughput for a lot of
  latency.
- **Correctness cliff at ~6–8k cold prefill** (see the callout) — the real hard limit,
  ahead of any throughput tuning.
- Thermals fine: junction ~95–102 °C under load, no clock throttling.

#### Conclusions

- **Cold prefill is capped at ~4k tokens.** The correctness cliff above (~6–8k cold tokens
  → garbage, sticky until reload) is the hard limit on this GPU — design around it: keep
  one-off prompts under ~4k, or rely on prefix caching for longer stable contexts.
- **Throughput depends on prompt reuse.** All-distinct (cold) prompts top out ~47 tok/s
  aggregate at high concurrency; requests sharing a cached prefix reach ~90. Quote the
  figure that matches your traffic, not the cache-warm best case alone.
- **Use `--parallel 4` for any concurrent serving.** A single slot serializes requests;
  four slots batch. Single-user cost is nil (concurrency 1 is the same either way), so the
  provisioning script defaults to `--parallel 4` — drop to 1 only for strictly single-user
  or VRAM-tight setups.
- **Interactive single user → concurrency 1**: ~53 tok/s, TTFT ~0.2 s on a cached/short
  prompt (a cold 512-token prefill adds ~1.4 s).
- The practical ceiling is **GPU compute** (~53 tok/s single-stream) and **large cold
  prefill** — not heat or VRAM (confirmed from the model container: GPU ~99%, CPU only
  ~10%, >14 GiB free). Beyond that you'd need a faster/larger GPU or a smaller/faster-quant
  model, not config tuning.

## Requirements

- Proxmox host with `pct` and `pveam`
- Ubuntu 24.04 LXC template available or downloadable
- AMD GPU visible on the Proxmox host as `/dev/dri` (with a `renderD128` render node)
- Network access from the LXC to download the inference engine (LM Studio or the
  llama.cpp release) and the Hugging Face model
