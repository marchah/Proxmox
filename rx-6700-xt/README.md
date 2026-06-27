# Radeon RX 6700 XT

Scripts in this folder target the desktop server with a Radeon RX 6700 XT.

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

### LM Studio

> ⚠️ **Correctness cliff — cold prefill above ~6k tokens.** On this GPU (RX 6700 XT,
> Vulkan/RADV) a *cold* prefill (a prompt not served from the prefix cache) starts
> emitting garbage — strings of `?` — once it exceeds ~6–7k tokens (probabilistically),
> and does so reliably by ~8k. It is **not** thermal or VRAM (junction ~95 °C, >14 GiB host RAM free); it is
> numerical instability in the large-prefill compute. Worse, it is **sticky**: once a
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
  workload, with >14 GiB RAM free on CT 120 during inference. Target-side telemetry samples
  the model container itself (not just the bench-runner client), so the limiter is confirmed
  to be GPU compute, not host CPU or memory.
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
- **Correctness cliff at ~7–8k cold prefill** (see the callout) — the real hard limit,
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
  prefill** — not heat or VRAM (confirmed from the model container: GPU ~99%, >14 GiB
  free). Beyond that you'd need a faster/larger GPU or a smaller/faster-quant model, not
  config tuning.

## Requirements

- Proxmox host with `pct` and `pveam`
- Ubuntu 24.04 LXC template available or downloadable
- AMD GPU visible on the Proxmox host as `/dev/dri` (with a `renderD128` render node)
- Network access from the LXC to download LM Studio and the Hugging Face model
