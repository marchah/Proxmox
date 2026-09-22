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
| Model | `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`, `Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf` (MTP head kept) |
| Alias | `qwen3.6-35b-a3b` |
| GPU | `0000:03:00.0`, all layers offloaded |
| Context / parallel slots | `262144` / `2` (131072 tokens per slot) |
| Attention / batch / ubatch | `on` / `4096` / `1024` |
| KV cache | `q8_0` K and V |
| Speculative decoding | `--spec-type draft-mtp --spec-draft-n-max 3` (the model's own MTP head) |
| Reasoning / format | `off` / `auto` |
| API | `0.0.0.0:1234` |
| Container RAM / model storage | 16384 MB / `/models` mount, `backup=0` |

This MoE has 35B total parameters and about 3B active per token. Its ~27.2 GB
weights, including the MTP head, fit one card. At the 256k context ceiling, a
recorded load used about 30.0 GiB of 30704 MiB exposed VRAM plus ~650 MiB GTT after
a request, leaving little transient headroom. With f16 KV the same load spills
~2 GiB to GTT and decodes slower than without speculation. Check free VRAM and GTT
after changing context, KV type, batches or the binary.

The MTP head and q8_0 KV measured +49–77% single-stream decode on code, JSON and
tool calls, +17% on prose, +35–39% at 16k–48k depth, and +2–38% combined across
two concurrent streams. The A/B, its controls and the rejected arms (draft length 4,
DFlash) are in [spec-ab/](spec-ab/README.md).

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

Current serving numbers are from the 2026-09-22 A/B in [spec-ab/](spec-ab/README.md):
b11018, the shipped flags (MTP head, q8_0 KV, 262k context, two slots), −100 mV,
`schedutil`, 512 output tokens, medians of 3 interleaved repetitions.

| Workload | Without MTP (f16 KV) | Shipped |
| --- | ---: | ---: |
| One stream: code / JSON / tool call, t/s | 78 / 79 / 77 | 117 / 136 / 137 |
| One stream: prose, t/s | 78 | 92 |
| One stream at 16k / 48k depth, t/s | 71 / 64 | 99 / 87 |
| Two streams, total t/s: code / JSON / prose | 115 / 115 / 115 | 140 / 159 / 117 |
| Cold prefill at 16k / 48k, t/s | 1,020 / 527 | 1,346 / 917 |

Gains are largest on predictable output (code, JSON, tool calls) and smallest on
free prose. Four slots and concurrency above two have not been measured on this
configuration.

### Flash attention and batch size

The `-fa on -b 4096 -ub 1024` defaults were chosen on the prior B550 platform
(b9835, 64k context, four slots). Flash attention added 26% aggregate throughput at
concurrency 4, 4.5% single-stream, cut TTFT by about 40% and saved 0.5 GiB of VRAM.
`-ub 1024 -b 4096` added about 3% at the saturation knee and 2–7% on 512–2,048-token
prefills. `llama-bench` cannot use `-b 4096` on this card (RADV out of memory); the
server can.

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
