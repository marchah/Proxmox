# Radeon Pro V620

The ROMED8-2T host has two Radeon Pro V620s (Navi 21 / gfx1030, 32 GB each),
both on CPU-direct Gen4 x16 slots. Deployment recorded 2026-09-18:

| PCI address | Container | Runtime |
| --- | --- | --- |
| `0000:03:00.0` | CT 120 `llamacpp` | Qwen3.6-35B-A3B, `llamacpp.service`, API `:1234` |
| `0000:83:00.0` | CT 123 `gpu2` | [Qwen3.8-Flash-Next](qwen38-flash-next/README.md), `llamacpp-qwen38fn.service`, API `:1234` |

Each card has a 9733 blower controlled by [gpu-blower-control](gpu-blower-control/README.md)
over IPMI: FAN5 cools `03:00.0`, FAN4 cools `83:00.0`. Both use the
[−100 mV undervolt](undervolt/README.md). The
[thermal watchdog](gpu-thermal-watchdog/README.md) stops the owning service at
102 °C junction / 101 °C memory and leaves it stopped until the cooling fault is resolved.

`create-lxc-llama-swap-gpu2.sh` is a reference recipe for the retired CT 123
runtime. Its model config needs explicit device selection before reuse alongside
another GPU container. The [B550 fan controller](fan-control/README.md) targets
the prior motherboard.

## CT 120 provisioning

`create-lxc-llamacpp-qwen3.6-35b-a3b.sh` creates a privileged Ubuntu 24.04 LXC
with a pinned llama.cpp Vulkan release and a checksum-verified model.

| Setting | Shipped value |
| --- | --- |
| Engine | llama.cpp `b11018`, prebuilt Vulkan x64 |
| Model | `unsloth/Qwen3.6-35B-A3B-GGUF`, `Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf` |
| Alias | `qwen3.6-35b-a3b` |
| GPU | `0000:03:00.0`, all layers offloaded |
| Context / parallel slots | `262144` / `2` (131072 tokens per slot) |
| Attention / batch / ubatch | `on` / `4096` / `1024` |
| Reasoning / format | `off` / `auto` |
| API | `0.0.0.0:1234` |
| Container RAM / model storage | 16384 MB / `/models` mount, `backup=0` |

This MoE has 35B total parameters and about 3B active per token. Its ~26.6 GB
weights fit one card. At the 256k context ceiling, a recorded load used about
29.8 GiB of 30704 MiB exposed VRAM, leaving little transient headroom. Check
free VRAM and GTT after changing context, batches or the binary.

Run from this directory on the Proxmox host as root, using an unused VMID:

```bash
./create-lxc-llamacpp-qwen3.6-35b-a3b.sh
# Example resource overrides:
VMID=124 MODELS_SIZE_GB=200 MEMORY_MB=24576 CORES=8 ./create-lxc-llamacpp-qwen3.6-35b-a3b.sh
```

A VMID override does not allocate a free GPU; set `GPU_PCI_ADDRESS` to a card
with no competing workload. The script installs `/etc/llamacpp.env`,
`llamacpp.service`, and `/usr/local/bin/llamacpp-{serve,wait-health,reload}`.
Release tags and checksums are pinned in the script and must be updated together.

## Context and concurrency

Per-slot context is total context divided by parallel slots. `llamacpp-reload`
rewrites context/parallel settings, restarts the service and waits for `/health`:

```bash
pct exec 120 -- bash -lc 'llamacpp-reload 262144 2'   # shipped: 128k per slot
pct exec 120 -- bash -lc 'llamacpp-reload 262144 4'   # 64k per slot; benchmark for the workload
pct exec 120 -- bash -lc 'llamacpp-reload 262144 1'   # one 256k slot
```

The two-slot setting remains the verified production default. Four slots need
fresh validation with the current build and reasoning disabled. Longer *used*
contexts slow decode and cold prefill; increasing the ceiling alone does not
represent a throughput improvement.

## Response content

The generated serve script uses `--jinja` for tool calling and
`--reasoning off --reasoning-format auto` for clean answer content. Both reasoning
flags are required: `off` disables thinking, while `auto` removes the template's
empty `<think>` block from `content`. Using `--reasoning-format none` leaves those
tags in generated files. These flags survive `llamacpp-reload`, which changes only
context and parallelism.

`--cache-ram 0` disables the prompt cache after corrupted cached state caused
repeated garbage output on b10152. Revalidate cached follow-up requests before
re-enabling it. Hermes' custom provider uses this endpoint and inherits its
server settings.

## Operate and verify

```bash
pct exec 120 -- systemctl status llamacpp.service
pct exec 120 -- journalctl -u llamacpp.service -n 100 --no-pager
pct exec 120 -- vulkaninfo --summary   # exactly one V620 using RADV
curl http://llamacpp:1234/v1/models
cat /sys/bus/pci/devices/0000:03:00.0/mem_info_vram_used
cat /sys/bus/pci/devices/0000:03:00.0/mem_info_gtt_used
```

The container includes Mesa Vulkan and libglvnd/EGL libraries. Passthrough binds
only the selected GPU's DRM nodes, and the serve guard rejects missing RADV devices.

`--metrics` exposes prompt/completion token counters at `/metrics`. They reset
on restart; [the CT 121 collector](../hermes/token-usage-collector/README.md)
accumulates deltas for monthly reports. CT 123's endpoint is not in the configured
source list.

### Recovering after a DRM renumber

A hardware or kernel change can renumber DRM nodes. The source bind uses a
PCI-stable path, but the destination name was resolved at provisioning. Repair
CT 120's entries on the host, then restart:

```bash
conf=/etc/pve/lxc/120.conf
rn=$(basename "$(readlink -f /dev/dri/by-path/pci-0000:03:00.0-render)")   # current renderD*
cn=$(basename "$(readlink -f /dev/dri/by-path/pci-0000:03:00.0-card)")     # current card*
sed -i -E "s#(-render dev/dri/)renderD[0-9]+#\1${rn}#; s#(-card dev/dri/)card[0-9]+#\1${cn}#" "$conf"
pct stop 120 && pct start 120
pct exec 120 -- /usr/local/bin/llamacpp-wait-health   # blocks until serving (guard passes)
```

## Benchmarks

Run endpoint benchmarks from the repo root with `make bench`; see
[Ansible](../ansible/README.md) for runtime/context defaults. Results land in
`pro-v620/results/llamacpp/parallel-<n>/`.

The measurements below use Qwen3.6-35B-A3B Q5, llama.cpp **b9835**, Vulkan,
**64k total context and four slots**, on the prior B550 platform. They document
the original tuning; remeasure capacity on the current host/build. The baseline
single-stream run measured 83.1 tok/s and 0.27 s p95 TTFT; the soak at concurrency
two sustained 106.7 tok/s with no errors.

**Concurrency** (cold ~512-in / 128-out, 32 req/point):

| Concurrency | OK | Aggregate tok/s | p95 latency | p95 TTFT |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 32/32 | 64.6 | 2.2 s | 0.70 s |
| 2 | 32/32 | 95.7 | 2.7 s | 0.88 s |
| 4 | 32/32 | **127.9** | 4.1 s | 1.67 s |
| 8 | 32/32 | 127.9 | 8.0 s | 5.67 s |
| 16 | 32/32 | 126.8 | 16.3 s | 13.85 s |

Saturation knee at concurrency 4 (~128 tok/s aggregate); past it throughput is
flat while tail latency grows linearly.

**Prefill / TTFT vs input length** (cold, concurrency 1, 32 output):

| Input tokens | OK | Aggregate tok/s | p95 TTFT | Notes |
| ---: | ---: | ---: | ---: | --- |
| 128 | 8/8 | 50.0 | 0.30 s | |
| 512 | 8/8 | 38.3 | 0.48 s | |
| 2,048 | 8/8 | 19.5 | 1.35 s | |
| 8,192 | 8/8 | 5.4 | 5.56 s | prefill-bound |
| 32,768 | 0/8 | — | — | exceeds the 16k per-slot context (64k ÷ 4) |

The 32,768 point is a hard rejection (input > per-slot context at `--parallel 4`),
**not** corruption — drop to `--parallel 1` for single prompts beyond 16k.

**Soak** (~6 min, concurrency 2): 106.7 tok/s sustained, 0 errors, coherent.

(The tables above are the initial run; the tuned `--flash-attn on --batch-size 4096
--ubatch-size 1024` flags — now the serve default — add ~3% on top, see below.)

### Tuning (flash attention + batch size)

An `off` / `on` / `on+batch` sweep (baseline + concurrency + prefill, `--parallel 4`)
selected the serve defaults. Aggregate tok/s:

| Concurrency | `-fa off` | `-fa on` | `-fa on` + `-ub 1024 -b 4096` |
| ---: | ---: | ---: | ---: |
| 1 | 58.4 | 66.0 | 67.4 |
| 2 | 80.2 | 96.0 | 97.2 |
| 4 | 101.8 | 128.4 | **132.7** |
| 8 | 99.5 | 126.6 | 130.9 |

- **Flash attention** is the big lever: **+26% at c4** vs off, plus +4.5% single-stream,
  ~−40% TTFT, and −0.5 GiB VRAM. (`-fa`'s default `auto` already enables it on this
  model/backend; we pin `on` for determinism.)
- **`-ub 1024 -b 4096`** adds the last ~3% at the knee (and +2–7% on 512–2048 prefills)
  for negligible VRAM.
- Trade-off: on a single >8k **cold** prefill, FA is marginally slower (8192-token TTFT
  ~5.0 s → ~5.5 s) — irrelevant for the concurrent/agent serving this card does.



### Multi-agent capacity (4 × 32k)

Tested 4 concurrent requests, each ~30k **cold** input + 512 output, at `131072/4`:
**8/8 succeeded, 0 errors, 23.2 GiB VRAM** — four 32k contexts coexist with ~9 GiB
to spare. Two performance realities:

- **Decode slows with context length.** At ~30k context, ~6 tok/s **per agent**
  (~23 tok/s aggregate) vs ~33 tok/s/agent at 512 tokens — attention over a large
  KV cache, ×4 slots. The aggregate is a shared ceiling; more agents ⇒ proportionally
  slower each.
- **Cold prefill is the pain point.** Four simultaneous *fresh* 30k prompts take
  **70–150 s to first token**. **Prefix caching** (automatic per slot) is essential:
  on follow-up turns it re-prefills only the new tokens, turning that into seconds.

## Backend and power

Vulkan/RADV is the supported backend. A 2026-06-29 comparison on b9835 found
ROCm 7.2 in a passthrough VM decoded 7–14% slower than Vulkan at matched 64k
context. The same ROCm userspace failed model loading in the tested LXC/host
kernel combination. Those results are version-specific.

The V620 power cap is firmware-locked at 250 W and its OverDrive interface has
no clock-ceiling control. The supported power adjustment is a GFX voltage offset;
see [undervolt/README.md](undervolt/README.md) for installation and measured power
savings. After a driver rebind or reset, reapply the offset with
`systemctl restart gpu-undervolt` and verify `pp_od_clk_voltage`.

## Requirements

- Proxmox host with `pct`, `pveam`, and an available Ubuntu 24.04 template.
- An amdgpu-bound V620 with `/dev/dri/by-path` entries.
- Network access for the pinned llama.cpp release and ~27 GB model download.
