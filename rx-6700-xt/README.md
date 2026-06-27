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

#### `--parallel 1`

Measured from the `bench-runner` LXC against this container's endpoint. Setup:
RX 6700 XT (12 GiB) via Vulkan, Ryzen 5 5600, `Qwen3.5-9B-Q4_K_M`, 64k context,
`--parallel 1`. Throughput is the reliable GPU signal — the amdgpu VRAM counter
reads ~0 when idle, so don't judge GPU use by it.

**Single stream (baseline):** 53.0 tok/s, TTFT 0.21 s mean / 0.37 s p95, GPU at 99% util.

**Concurrency scaling** (512-token prompt, 128 output, 32 requests/point):

| Concurrency | Aggregate tok/s | p95 latency | p50 TTFT |
| ---: | ---: | ---: | ---: |
| 1 | 52.4 | 2.4 s | 0.13 s |
| 2 | 53.3 | 4.8 s | 2.5 s |
| 4 | 53.3 | 9.6 s | 7.3 s |
| 8 | 53.3 | 19.2 s | 16.9 s |
| 16 | 53.3 | 38.4 s | 36.1 s |

With a single slot, concurrent requests **serialize**: aggregate throughput stays
pinned at the single-stream rate (~53 tok/s) while latency and TTFT grow linearly with
concurrency. There is no batching gain at one slot — see `--parallel 4` below for that.

**Prefill / TTFT vs input length** (cold, uncached first request; concurrency 1):

| Input tokens | Cold TTFT |
| ---: | ---: |
| 512 | ~1.1 s |
| 2,048 | ~4.2 s |
| 8,192 | ~15 s |
| 32,768 | ~152 s |

Repeated prompts hit LM Studio's prefix cache → sub-second TTFT.

**Soak** (~6 min, concurrency 2): 52.8 tok/s (serialized — single slot); junction
peaked 101–103 °C, clocks held, no thermal throttling.

**Observations**

- **GPU-bound**: 99% GPU utilization on every workload (GPU telemetry is
  host-real even from the bench-runner). CPU/RAM headroom on the model
  container is now captured via target-side telemetry
  (`host/run-with-target-telemetry.sh`); earlier runs only sampled the
  bench-runner client, so treat their "CPU/RAM not limiting" note as
  unconfirmed until a run with `target-telemetry.jsonl` says so.
- VRAM use is ~7.2 GiB of 12 GiB during inference, freed when idle.
- **One slot = serial service**: concurrent clients queue rather than batch, so
  aggregate throughput never exceeds the single-stream ~53 tok/s and tail latency
  climbs linearly (c16 → 38 s, TTFT → 36 s). Concurrency pays off only with more slots.
- **Prefill dominates at long context**: cold time-to-first-token scales
  super-linearly with prompt size (8k ≈ 15 s, 32k ≈ 152 s).
- **Thermals are fine**: junction peaked ~101–103 °C under sustained load, below the
  105 °C warn line, with no clock throttling.

#### `--parallel 4`

Same setup, model reloaded with `--parallel 4` (4 continuous-batching slots).

**Concurrency scaling** (512-token prompt, 128 output, 32 requests/point):

| Concurrency | Aggregate tok/s | p95 latency | p50 TTFT |
| ---: | ---: | ---: | ---: |
| 1 | 51.7 | 1.8 s | 0.13 s |
| 2 | 77.3 | 3.2 s | 0.18 s |
| 4 | **92.3** | 7.4 s | 0.51 s |
| 8 | 90.2 | 11.1 s | 6.3 s |
| 16 | 91.5 | 21.9 s | 13.7 s |

**Prefill / TTFT:** identical to `--parallel 1` (8k ≈ 15 s, 32k ≈ 152 s) — prefill is
per-request and parallel-independent.

**Soak** (concurrency 2): 73.4 tok/s, junction peaked 102 °C, clocks held, no throttle.

**Observations**

- **Batching scales throughput**: aggregate climbs to ~92 tok/s at concurrency 4 — vs
  the flat ~53 tok/s a single slot delivers, a ~1.75× gain for concurrent load.
- **Single-user latency is unchanged**: at concurrency 1 it's the same ~52 tok/s,
  ~0.13 s TTFT as `--parallel 1`, so the extra slots cost nothing for one user.
- **Better tail latency under load** than one slot (c16 p95 21.9 s vs 38.4 s; TTFT
  13.7 s vs 36.1 s) — requests batch instead of queueing end-to-end.
- **Saturation knee at c≈4**: throughput plateaus past it (~90 tok/s) while latency
  keeps climbing — don't push beyond.
- Prefill and thermals unchanged — prefill is per-request and parallel-independent;
  junction peaked ~102 °C, no clock throttling.

#### Conclusions

- **Use `--parallel 4` for any concurrent serving.** A single slot serializes requests,
  capping aggregate throughput at the single-stream rate (~53 tok/s); four slots batch
  and scale to ~90 tok/s. Single-user latency is identical (~52 tok/s, TTFT ~0.13 s at
  concurrency 1), so the extra slots cost nothing for one user. `--parallel 1` only makes
  sense for strictly single-user or VRAM-constrained setups. (The provisioning script
  now defaults to `--parallel 4`; drop it to 1 only for strictly single-user or
  VRAM-tight setups.)
- **Interactive single user → concurrency 1**: ~52 tok/s, TTFT ~0.13–0.21 s (snappy), at
  either `--parallel` setting.
- **Max useful throughput → concurrency ~4 with `--parallel 4`**: ~90 tok/s at acceptable
  latency (p95 ~7 s, TTFT < 1 s). Don't push past c=4 — throughput plateaus, latency climbs.
- **Keep fresh prompts modest** (≤ 2–4k tokens) for fast first-token; long one-off
  prompts are expensive (8k ≈ 15 s, 32k ≈ 152 s prefill). Lean on prefix caching for
  long, stable contexts.
- The practical ceiling is **GPU compute** (~52 tok/s single-stream, ~90 aggregate with
  batching) and **long-context prefill** — not heat or VRAM. Serving concurrency helps
  only up to the slot count; beyond that you'd need a faster/larger GPU or a
  smaller/faster-quant model, not config tuning.

## Requirements

- Proxmox host with `pct` and `pveam`
- Ubuntu 24.04 LXC template available or downloadable
- AMD GPU visible on the Proxmox host as `/dev/dri` (with a `renderD128` render node)
- Network access from the LXC to download LM Studio and the Hugging Face model
