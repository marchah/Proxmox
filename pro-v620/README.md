# Radeon Pro V620

Scripts in this folder target the desktop server's **Radeon Pro V620** (Navi 21 /
gfx1030, RDNA 2, **32 GB** GDDR6, 72 CUs). The V620 **replaces the RX 6700 XT** —
the [`rx-6700-xt/`](../rx-6700-xt/) folder is kept as the prior-GPU reference.

With ~2.7× the VRAM of the 6700 XT (32 GB vs 12 GB), this card serves a much
larger model. There is a single runtime script here (no LM Studio sibling —
llama.cpp is the chosen engine, per the 6700 XT comparison):

- `create-lxc-llamacpp-qwen3.6-35b-a3b.sh` — llama.cpp's `llama-server` (reload =
  restart, via the `llamacpp-reload` helper). Defaults to CT `120`, exposes an
  OpenAI-compatible API on `0.0.0.0:1234`, serves the model under the identifier
  `qwen3.6-35b-a3b`.

## Model choice: Qwen3.6-35B-A3B (MoE)

`unsloth/Qwen3.6-35B-A3B-GGUF`, `Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf` (~26.6 GB, a
single unsharded file). This is a **Mixture-of-Experts** model: 35B total
parameters but only **~3B active per token**, so it generates far faster than a
dense 27B/32B at comparable quality — the best capability-per-second on this card.
The intended consumer is an **agent** (tool-calling loops, where per-step latency
compounds), which is exactly where the MoE's speed pays off.

It fits 32 GB at Q5 (~26.6 GB weights) with ~5 GB left for the KV cache. The dense
alternatives that also fit (`Qwen3.5-27B`, `Qwen3-32B`) are documented in the repo
history if you want to trade speed for a dense model — each would be its own
script, not a flag on this one (per the repo's "one GPU/model/engine per script"
convention).

## llama.cpp Qwen3.6-35B-A3B LXC

`create-lxc-llamacpp-qwen3.6-35b-a3b.sh` creates a privileged Ubuntu LXC running
**llama.cpp's `llama-server`** (a pinned prebuilt Vulkan release) with the V620
passed through.

This script is deliberately narrow:

- GPU: Radeon Pro V620 (Navi 21 / gfx1030)
- GPU runtime: Vulkan (mesa RADV)
- Engine: llama.cpp `llama-server`, prebuilt Vulkan x64 release (pinned by tag +
  SHA-256 in the script — bump both from the [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases))
- Repository: `unsloth/Qwen3.6-35B-A3B-GGUF`
- File: `Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf` (MoE, single file)
- Identifier (`--alias`): `qwen3.6-35b-a3b`
- Context length: `262144` (`--ctx-size`; the model's ~256k native max, 64k per slot at `--parallel 4` — KV cache is cheap on this MoE)
- GPU offload: `--n-gpu-layers 99` (all layers, including MoE experts)
- Parallel slots: `--parallel 4` (continuous batching, on by default)
- Attention / batch: `--flash-attn on --batch-size 4096 --ubatch-size 1024` (tuned — see Benchmarks → Tuning)
- Tool calling: `--jinja` — uses the model's chat template so OpenAI `tool_calls` parse correctly (**required for agents**; without it llama-server won't emit tool calls)
- API bind: `0.0.0.0:1234`
- Model storage: `/models`

Run it on the Proxmox host as `root` (destroy any existing CT 120 first):

```bash
./create-lxc-llamacpp-qwen3.6-35b-a3b.sh
```

Useful Proxmox/container overrides:

```bash
VMID=120 LXC_HOSTNAME=llamacpp ./create-lxc-llamacpp-qwen3.6-35b-a3b.sh
MODELS_SIZE_GB=200 MEMORY_MB=24576 CORES=8 ./create-lxc-llamacpp-qwen3.6-35b-a3b.sh
PASSWORD='temporary-root-password' ./create-lxc-llamacpp-qwen3.6-35b-a3b.sh
```

(The model is fully offloaded to VRAM, so the container RAM limit defaults to a
modest `16384` MB — fine on this 31 GiB host. Bump it only if you switch to
`--no-mmap`.)

The script creates a privileged Ubuntu LXC with a `/models` mount (backup
disabled) and `/dev/dri` passthrough, plus the Vulkan userspace and the
**libglvnd/EGL stack** (`libglvnd0 libgl1 libglx0 libegl1`) — without the latter
the Mesa ICD loader can silently report zero Vulkan devices inside the container.
It installs:

- a `llamacpp` user and a `llamacpp.service` systemd unit (`Type=simple`, runs
  `llama-server` in the foreground)
- `/etc/llamacpp.env` holding the tunable start flags (context length, parallel)
- `/usr/local/bin/llamacpp-serve` (the service entrypoint), `llamacpp-wait-health`,
  and `llamacpp-reload`

### Context length and parallel slots

llama-server sets context length and parallel slots at process start, so changing
them means restarting the server. Use the helper (it rewrites `/etc/llamacpp.env`
and blocks until `/health` is ready):

```bash
pct exec 120 -- llamacpp-reload <context-length> <parallel>
```

The `262144` / `--parallel 4` default is the model's **~256k native maximum**,
split across 4 continuous-batching slots (**64k each**). This MoE's KV cache is
cheap (~20 KB/token), so even 256k fits the V620 at Q5 ~29.8 GiB used of ~30 GiB
usable (the card exposes 30704 MiB, not a full 32) — only ~0.2 GiB real margin,
stress-verified (a 4-concurrent prefill held) but with no safety buffer. A larger
`--ctx-size` does not slow shorter requests (attention is
over actual length), so this ceiling is free for normal traffic — but *using*
large contexts decodes slower (see [Multi-agent capacity](#multi-agent-capacity-4--32k)).

**Per-slot context = total ÷ parallel.** Switch modes live for the workload:

```bash
# Daytime — ~4 concurrent agents, 64k each (the default):
pct exec 120 -- llamacpp-reload 262144 4
# Overnight — ONE agent needs the full 256k window (single slot, no concurrency):
pct exec 120 -- llamacpp-reload 262144 1
```

(If you ever need more context than VRAM allows, KV-cache quantization is the
lever: add `--cache-type-k q8_0 --cache-type-v q8_0` to `llamacpp-serve` to
roughly halve KV memory. Not needed at these sizes.)

Check the service and endpoint:

```bash
pct exec 120 -- systemctl status llamacpp.service
pct exec 120 -- journalctl -u llamacpp.service -n 100 --no-pager   # shows the chosen Vulkan device
curl http://<container-ip>:1234/v1/models                          # id == qwen3.6-35b-a3b
```

### Reasoning / thinking (important for agents)

Qwen3.6 "medium" models (including this MoE) have **thinking ON by default**. The
service runs with `--reasoning-format none`, which keeps the model's `<think>`
block **inline** in the OpenAI `content` stream (rather than splitting it into
`reasoning_content`). That is what the benchmark suite wants (it counts every
token and measures true TTFT).

For an **agent**, decide how your client handles reasoning:

- If the agent framework can parse/strip `<think>…</think>` (or you want the model
  to plan), leave it as-is.
- If the framework expects a clean tool-call response and **won't** strip
  reasoning, disable thinking — add
  `--chat-template-kwargs '{"enable_thinking": false}'` to `llamacpp-serve`
  (`/usr/local/bin/llamacpp-serve` in the container, and the heredoc in this
  script). A client can still re-enable it per request with
  `{"chat_template_kwargs": {"enable_thinking": true}}`.

## Storage

The container stores model files under `/models`, backed by local Proxmox storage
(`local-lvm`). The mount has `backup=0` because model weights are large and
re-downloadable. Back up container configuration, service files, and small
application state separately.

## AMD GPU (Vulkan)

The V620 (Navi 21 / gfx1030) is driven through **Vulkan** (mesa RADV). The script
installs the Vulkan userspace (`mesa-vulkan-drivers libvulkan1 vulkan-tools`) plus
the libglvnd/EGL stack, passes through `/dev/dri`, and pins the RADV ICD
(`VK_ICD_FILENAMES`) so the engine can't fall back to the llvmpipe software
device. llama-server offloads all layers with `--n-gpu-layers 99`. Confirm the GPU
is visible to Vulkan and resident in VRAM:

```bash
pct exec 120 -- vulkaninfo --summary                                # expect a V620 under the radv driver
cat /sys/class/drm/card0/device/mem_info_vram_used                  # ~30 GB while serving a request
```

### Why Vulkan and not ROCm/HIP?

ROCm was tested (the llama.cpp `b9835` ROCm-7.2 prebuilt) and **does not work inside an
LXC on this host** (it *does* work in a passthrough VM — see below). The runtime
installed cleanly and the GPU enumerated correctly
(`llama-server --list-devices` → `ROCm0: AMD Radeon Pro V620`; KFD reports
`gfx_target_version 100300` = gfx1030), but **model load aborts** on the first
host→VRAM copy:

```
ROCm error: an illegal memory access was encountered
  in function ggml_backend_cuda_buffer_set_tensor … hipMemcpyAsync(… hipMemcpyHostToDevice)
```

It failed identically with `HSA_OVERRIDE_GFX_VERSION=10.3.0`, `GGML_CUDA_NO_PINNED=1`,
and `--no-mmap`. Root cause: a mismatch between **ROCm 7.2's HIP/HSA userspace** and
the host's **in-kernel amdgpu 3.64.0 (Proxmox `7.0.12-1-pve`)** — the device
enumerates via topology, but the VRAM memory ABI doesn't match, so every `hipMemcpy`
faults.

The LXC blocker is the *shared host kernel*: an LXC can't run a different amdgpu than
the host's, so the userspace/kernel ABIs can't be matched. RDNA 2 also has no matrix
cores (no WMMA), so even a working ROCm wouldn't be expected to beat the tuned Vulkan
path — a proof-of-concept confirmed exactly that.

#### ROCm in a passthrough VM (PoC, 2026-06-29) — works, but slower than Vulkan

A VM with the V620 passed through (`vfio-pci` → `qm set <id> --hostpci0 0000:2d:00.0,pcie=1`,
q35 + OVMF) runs its **own** kernel, so a matched `amdgpu-dkms` + ROCm stack can be
installed and the `hipMemcpy` fault disappears. Verified end-to-end: the host→device→host
roundtrip that aborts in the LXC returns `OK`, `rocminfo` shows `gfx1030` with a ~30 GiB
pool, and `llama-server` (ROCm build) serves the model.

**Record the exact versions** — a newer ROCm or a newer llama.cpp ROCm backend may close
the gap, so re-run the A/B before assuming Vulkan still wins:

| Component | Version (working VM) |
| --- | --- |
| Host | Proxmox VE 9.2.3, kernel `7.0.12-1-pve`, in-kernel amdgpu uAPI `3.64.0` |
| Guest OS | Ubuntu 24.04 (noble), kernel `6.8.0-124-generic` |
| amdgpu-dkms | `6.16.13` (via `amdgpu-install_7.2.70200-1`, `--usecase=rocm`) |
| ROCm | `7.2` (`repo.radeon.com/amdgpu-install/7.2/ubuntu/noble`) |
| llama.cpp | `b9835` — `llama-b9835-bin-ubuntu-rocm-7.2-x64` prebuilt |
| GPU | Radeon Pro V620, Navi 21 / gfx1030 |

A/B vs Vulkan at the **same** context (65536) and llama.cpp build (`b9835`), measured
from CT 200 via `openai-direct`:

| metric | Vulkan (RADV, LXC) | ROCm (VM) |
| --- | --- | --- |
| p1 per-req tok/s | 78.6 | 67.8 (**−14 %**) |
| p1 TTFT p95 (s) | 0.28 | 0.19 (faster) |
| p4 aggregate tok/s | 145.5 | 134.9 (**−7 %**) |
| p4 per-req median tok/s | 38.0 | 34.4 |
| p4 TTFT p95 (s) | 0.59 | 0.79 (slower) |

ROCm decodes ~7–14 % slower (only single-stream prefill/TTFT was faster); on RDNA 2 the
tuned RADV path wins. The VM also costs more to operate: the card is **exclusive** to the
VM (`vfio-pci` claims it, so the LXC can't use it at the same time), guest RAM is pinned
(no lxcfs sharing, ballooning off), there is no host-side fan control while the card is
passed through, and a cold load takes ~7–9 min (slow VM disk read of the 25 GB GGUF +
first-run ROCm kernel JIT).

**Conclusion: Vulkan (RADV) is the supported backend here.** The VM/ROCm path is proven
and reproducible if ever needed (a ROCm-only feature, or a future ROCm/llama.cpp release
that closes the gap).

Reproduction gotchas (if retried in a VM):
- A minimal Ubuntu **cloud image lacks the DRM stack**, so `amdgpu-dkms` won't load
  (`Unknown symbol drm_dp_mst_*`). Install `linux-modules-extra-$(uname -r)` (provides
  `drm_display_helper`) **before** `amdgpu-install`.
- Create the EFI disk with `pre-enrolled-keys=0` (Secure Boot off) so the unsigned
  amdgpu-dkms module loads.
- Serve with `--jinja --reasoning-format none` (as the LXC does) or this thinking model
  emits into `reasoning_content`, leaving `content` empty (benchmarks report `invalid_output`).
- Fully reversible with **no persistent host change and no reboot**: stop `gpu-fan-control`,
  `gpu-undervolt`, and the LXC; runtime-rebind the card to `vfio-pci`; run the VM; then
  `qm destroy` it and rebind `amdgpu` (`reset_method=bus` resets the card cleanly). A host
  reboot is the guaranteed fallback (CT 120 is `onboot=1`; `gpu-undervolt` re-applies at boot).
- **Re-apply the undervolt after rebinding `amdgpu`.** The rebind resets the card's OverDrive
  state, but `gpu-undervolt` is a `RemainAfterExit` oneshot — it still reads "active" while
  the hardware has silently reverted to stock voltage, so it will **not** re-apply on its own.
  Once `amdgpu` is back: `systemctl restart gpu-undervolt` and verify with
  `cat /sys/class/drm/card*/device/pp_od_clk_voltage` (expect the configured `OD_VDDGFX_OFFSET`).
- For a future *LXC* retry instead, ROCm also needs `/dev/kfd` passed in (cgroup char
  major 236 + an `lxc.mount.entry`) on top of `/dev/dri` — but the shared-kernel ABI
  mismatch is the real blocker, which is why the VM is the path that works.

## Benchmarks

Run the suite from the repo root with `make bench` (the defaults are now
`RUNTIME=llamacpp`, `model_key=qwen3.6-35b-a3b`, `model_context=262144`, so no
overrides are needed). Results land in `pro-v620/results/llamacpp/parallel-<n>/`.

The throughput/prefill tables below were measured at 64k context (`--parallel 4`);
the default is now 256k, but decode/throughput at a given *used* context length is
unchanged by the larger ceiling. `Qwen3.6-35B-A3B-UD-Q5_K_XL`, llama.cpp `b9835`
(Vulkan), measured from CT 200 via `openai-direct` with distinct/cold prompts.
**All SLOs passed.**

- **Single-stream baseline:** 83.1 tok/s, TTFT 0.27 s p95.

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

Net default: **~132 tok/s aggregate (+30% vs FA-off), 83 tok/s single-stream, ~0.13 s TTFT.**

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

Guidance: treat the per-slot ceiling as a **ceiling, not the operating point** —
trim agent history (≈4–8k keeps decode ~20–30 tok/s/agent), cap output/reasoning
length, and reuse a stable prefix per agent so the slot cache hits. Speculative
decoding (`--model-draft`) does **not** help this profile: it targets single-stream
decode, not prefill, and its benefit shrinks under concurrency and at large context.

**Overnight long-context mode (`262144/1`)** is verified healthy — one slot owns
the full **256k** window (25.9 GiB VRAM). A *cold* 256k prefill takes several
minutes, so this suits a single long-running agent that grows its context
incrementally (each turn prefix-cached, only new tokens prefilled), not repeated
cold 256k loads. Switch with `llamacpp-reload 262144 1`, and back to `262144 4`
for daytime concurrency.

### Model bake-off — round 1: Qwen3.5 Q4 vs Q5 vs Hermes 4.3 36B

A/B at a matched config (ctx 32k, `--parallel 4`, flash-attn on, `--jinja`) with a
small tool-calling eval (tool selection among several, argument + unit extraction,
parallel calls, and abstaining when no tool fits):

| Model | Quant | VRAM | Single-stream | Concurrency-4 agg | Tool-calling |
| --- | --- | ---: | ---: | ---: | ---: |
| **Qwen3.5-35B-A3B** (current) | Q4_K_XL | 21.2 GiB | **83 tok/s** | **193 tok/s** | 8/8 |
| Qwen3.5-35B-A3B | Q5_K_XL | 25.1 GiB | 80 tok/s | 186 tok/s | 8/8 |
| Hermes 4.3 36B (dense, Seed-OSS) | Q5_K_M | 29.8 GiB | 16 tok/s | 54 tok/s | 8/8 |

- **Tool calling: all three tie 8/8** — each selects the right tool, extracts args
  (incl. "5 minutes" → 300 s), does parallel calls, and abstains when no tool fits.
  The eval confirms competence but is too easy to *rank* the top; separating them
  would need a harder multi-turn / ambiguous / arg-repair set.
- **Speed: the MoE wins ~5×.** Hermes is dense 36B (all params/token) vs the MoE's
  ~3B active — decisive for concurrent agents.
- **VRAM / context: the MoE wins.** Hermes is already 29.8 GiB at *32k*, so it can't
  reach the long-context modes the MoE's cheap KV enables.
- **Q4 vs Q5:** Q5 costs ~4% speed + ~4 GiB VRAM for lower quant error with identical
  tool behaviour.

Within the 3.5 generation Q4 was the pick (fastest, most headroom). **Round 2 below
superseded this** — Qwen3.6 is the newer generation, so the V620 now runs
**Qwen3.6-35B-A3B Q5** by default. The 3.5 Q4/Q5 and Hermes GGUFs are kept under
`/models/hf` for ad-hoc use (to switch, edit `MODEL_PATH` in `/etc/llamacpp.env` and
restart). *(These tok/s are light-prompt/decode-heavy — compare models with them, not
as capacity figures; the cold-prompt numbers above are the realistic capacity.)*

### Model bake-off — round 2: Qwen3.5 vs Qwen3.6 (chosen default)

Same harness. Qwen3.6 is the newer-gen successor (same MoE shape; improved tool
calling, coding, vision):

| Model | Quant | VRAM (32k) | Single-stream | Concurrency-4 agg | Tool-calling |
| --- | --- | ---: | ---: | ---: | ---: |
| Qwen3.5-35B-A3B | Q4_K_XL | 21.2 GiB | 83.2 tok/s | 193.4 tok/s | 8/8 |
| Qwen3.6-35B-A3B | Q4_K_XL | 21.4 GiB | 82.8 tok/s | **195.7 tok/s** | 8/8 |
| **Qwen3.6-35B-A3B (default)** | Q5_K_XL | 25.3 GiB | 79.1 tok/s | 185.0 tok/s | 8/8 |

- **3.6 ≈ 3.5 on speed/VRAM** — a free generational upgrade.
- **Tool calling: all 8/8** once given enough tokens. Note 3.6 reasons *more* before a
  tool call (~600–960 `<think>` tokens here), so a tight `max_tokens` can truncate the
  call — give headroom, or disable thinking for instant (~55–80 tok) clean calls.
- **Q5 chosen as the default** for slightly better quality (~5% slower). At the 262144
  ceiling Q5 sits at **~29.8 GiB of ~30 GiB usable (30704 MiB) — only ~0.2 GiB real
  margin** (stress-verified, no safety buffer), keeping the 256k window always available.

### GPU thermals (Radeon Pro V620, passively cooled via the `gpu-fan-control` Pump Fan)

Sampled on the host every 12 s across the whole batch:

| State | Junction | Edge | Mem | Power | SCLK | Fan (pwm2 / RPM) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Idle | 39 °C | 33 °C | 34 °C | 8 W | 0 | 22% / 1176 |
| Sustained load (soak/prefill) | **83 °C** | 72 °C | 70 °C | ~250 W | 2280–2505 MHz | ~90% / ~4100 |
| Peak observed | 84 °C | 73 °C | 70 °C | 252 W | — | 93% / 4285 |

- The `gpu-fan-control` service ramps the Pump Fan (`pwm2`) 22% → ~90% as junction
  rises; it recovers to ~46 °C within ~1 min of load ending.
- **No thermal throttling:** SCLK held 2280–2505 MHz throughout (above the V620's
  ~2200 MHz nominal). Junction peaked 84 °C — far below the 105 °C warn / 110 °C
  fail SLO lines. Continuous-batching concurrency actually ran *cooler* (~68 °C,
  ~210 W) than single-stream decode with large prefills (~83 °C, ~250 W bursts).

> **Headline:** the V620 serves a 35B-parameter MoE *faster* than the RX 6700 XT
> served the 9B dense model (single-stream ~83 vs ~56 tok/s; concurrent aggregate
> ~128 vs ~80 tok/s) — the MoE's ~3B active params per token plus the V620's extra
> bandwidth/compute. Compare full detail against [`../rx-6700-xt/README.md`](../rx-6700-xt/README.md#benchmarks).

> **Cold-prefill caveat.** The RX 6700 XT (Navi 22 / gfx1031) exhibited a
> RADV/Vulkan **cold-prefill garbage** bug above ~6–8k tokens (see
> [`../rx-6700-xt/UPSTREAM-cold-prefill-garbage.md`](../rx-6700-xt/UPSTREAM-cold-prefill-garbage.md)).
> That is a different chip; the V620 is Navi 21 / gfx1030 and the pinned llama.cpp
> release is newer. The bug may not apply here — **verify cold-prefill correctness
> at high context before trusting long prompts** (an input-length sweep with
> distinct/uncached prompts is the quickest check).

### Power limiting — not possible; undervolt instead (`undervolt/`)

The V620's board power is **firmware-locked at 250 W**: `power1_cap` reports
`min == max == default == 250000000` µW and any other write is rejected
(`amdgpu: New power limit (220) is out of range [250,250]`). Enabling AMD
OverDrive (`amdgpu.ppfeaturemask` bit `0x4000`) does **not** unlock the cap, and
the OverDrive table exposes **no clock-ceiling knob** either (`OD_RANGE` is empty
— no `OD_SCLK`/`OD_MCLK`). The DPM table only offers 500 or 2570 MHz (nothing
between), so clock-step masking is useless too. **A sub-250 W cap is not
achievable in software on this card.**

The one working lever is a **GFX voltage offset** (`OD_VDDGFX_OFFSET`, exposed
once OverDrive is on). A negative offset lowers voltage at the same clocks. A/B
across the full benchmark batch (`make bench PARALLEL=4`, with host-side power
sampling since the in-LXC suite cannot read AMD watts), **0 mV vs −100 mV**:

| Under load | 0 mV | −100 mV | Δ |
| --- | ---: | ---: | ---: |
| Avg board power | 196 W | 160 W | **−18%** |
| Peak power | 252 W | 247 W | −5 W |
| Junction avg | 71 °C | 64 °C | **−7 °C** |
| Junction peak | 83 °C | 75 °C | **−8 °C** |
| Core clock (avg) | 2300 MHz | 2304 MHz | ≈ same |

Throughput was unchanged in the decode / single-user / soak regime (±0.3%) and
**+0.6–1.1%** in the cap-saturated concurrency sweep (peak 122.7 → 123.7 tok/s).
−100 mV was fully stable (16-way concurrency, 32k-token prefills, soak — zero GPU
faults). Decode draws only ~96–128 W single-stream (well under the cap), so it is
*not* power-limited — that is why undervolting cuts power there instead of raising
clocks. Net: **~8 °C cooler peaks and ~18% less power, for free.**

Made persistent by the [`undervolt/`](undervolt/) service (enables OverDrive via
`/etc/modprobe.d` + applies the offset at boot). See
[`undervolt/README.md`](undervolt/README.md).

## Requirements

- Proxmox host with `pct` and `pveam`
- Ubuntu 24.04 LXC template available or downloadable
- Radeon Pro V620 visible on the Proxmox host as `/dev/dri` (with a `renderD128`
  render node)
- Network access from the LXC to download the llama.cpp release and the Hugging
  Face model (~27 GB)
