# Qwen3.8-Flash-Next: configurations, context, KV type and MoE cache, with telemetry

Plan committed 2026-10-08 · Run 2026-10-09 · Status: done

## Question

Three sweeps on eight memory channels and llama.cpp b11505, each with per-phase telemetry.

- **Standard configurations,** in CT 120 holding both cards: what does each deliver
  (decode by prompt class and depth, prefill at ~5.8k tokens, VRAM and GTT)?
  - **One card or two at the same placement?** At `-ncmoe 34` and batch 4096/1024, does
    the two-card decode cost from the QSA indexer's per-token transfers (llama.cpp
    #28699, an open draft) persist on eight channels?
  - **Layer or tensor split on two cards?** `-sm tensor` was re-enabled for qwen4exp in
    llama.cpp #28569. At `-ncmoe 16` and batch 1024/256, does it beat the layer split?
- **Context depth and KV type,** in CT 123 at `-ncmoe 34`:
  - How do decode and prefill change from an empty context to about 59k tokens?
  - What does f16 KV cost against q8_0 at a 65536 context, in VRAM, decode and prefill?
    The env files keep reasoning off with q8_0 and name f16 as the type to use before
    enabling it.
  - Does a 131072 context with q8_0 KV run on the card without spill, and what do decode
    and prefill measure at about 119k tokens?
- **MoE expert cache,** in CT 123: does `--moe-cache-mib` (#29887) run on RADV, and at
  equal VRAM headroom, does spending VRAM on cached experts decode faster than spending
  it on whole expert layers? What does each configuration cost in prefill?
- **Utilization,** in every cell: in prefill and decode, how hard does each card work
  (power against its 250 W cap, clocks, busy %), and how many CPU cores does the
  container use?

## What answers it

- **Gates,** per cell: it loads, shows no GTT spill and passes the output gate: no
  degenerate output, and its three passes agree per prompt cell (`SUMMARY.md` flags
  both). A cell with any DIMM sample at 66 °C is reported as capped and left out of the
  comparisons.
- **Comparisons:** median decode per prompt cell and median prefill per prompt class. A
  difference counts when it is larger than the pass-to-pass spread of both cells.
  - One or two cards: `2gpu-34` against `1gpu-34`. Split mode: `2gpu-16-tensor` against
    `2gpu-16`.
  - KV type: `f16-64k` against `q8-64k` at each depth, and VRAM after load.
  - 128k: `q8-128k` runs if it loads and passes the spill check after its ~119k probe (no
    GTT growth, at least 1 GiB of VRAM free). Its shallower depths against `q8-64k` show
    what the larger allocation costs.
  - MoE cache: every cache cell logs the cache's size line and a decode (`ubatch <= 8`)
    hit rate. A cache configuration is faster if its median decode, at d0 and d8000, beats
    the no-cache control's by more than the control's own spread. Its text is not
    compared with the control's: a cached layer's decode matmuls run on the GPU instead
    of the CPU, so greedy text can legitimately differ. The optimized cache cell keeps at
    least 12 GiB of VRAM free after its probe.
- **Utilization:** `SUMMARY.md`'s Utilization table for every cell and phase: median
  busy %, power and sclk per card holding the model, the highest junction temperature,
  and the CPU cores in use.

## Configurations

| Sweep | Container | Standard configuration | Cells |
| --- | --- | --- | --- |
| Configurations | CT 120, both cards | Two GPUs | `2gpu-16` (the shipped two-card config, split `30,18`, 1024/256); `2gpu-16-tensor` (`-sm tensor`, 1024/256); `2gpu-34` (split `39,9`, 4096/1024, matched to `1gpu-34`) |
| | | One GPU | `1gpu-34` (CT 123's placement, 4096/1024); `1gpu-40` |
| | | CPU only | `cpu` (`--device none`, `-ngl 0`, 4096/1024) |
| | | Optimized | `1gpu-48`: every expert in RAM, leaving about 23 GB of VRAM for a second model |
| Context depth and KV type | CT 123 | One GPU | `q8-64k` (deployed: q8_0, ctx 65536); `f16-64k`; `q8-128k` (q8_0, ctx 131072) |
| MoE cache | CT 123 | One GPU | `34`, no cache (deployed); `34:auto` and `40:auto`, VRAM spent on cached experts instead of whole expert layers |
| | | Optimized | `48:leave12288`: every expert in RAM, with a cache that leaves 12 GiB of VRAM for a second model; also about the largest cache RADV holds at `-ncmoe 48` |

The cells are in [`2026-10-08-configurations.cells`](2026-10-08-configurations.cells) and
[`2026-10-08-kv-context.cells`](2026-10-08-kv-context.cells); the cache sweep sets them with
`CONFIGS`.

- **Context depth and KV type:** two GPUs, CPU only and optimized are left out. CT 123
  holds one card, the configurations sweep measures the other shapes at d0 and d8000, and
  the optimized placement frees VRAM that a larger KV would consume. f16 at 131072 is
  left out too: its KV, about 3 GiB at 24 KiB per token, is 2.25 GiB more than the
  deployed cell's, and `-ncmoe 34` leaves about 2 GiB free.
- **MoE cache:** `48:auto` is left out: it sizes a ~22.5 GB cache, which RADV cannot
  allocate (see Method). Two GPUs: the cache refuses to run on more than one device. CPU
  only: the cache needs a GPU.

## Controls

- `1gpu-34` is the reference for the configurations and `2gpu-16` for the split mode.
  `q8-64k` and `34` without a cache are CT 123's deployed configuration and the
  references for their sweeps.
- A host-side sampler reads each card's sysfs and the container's CPU counter once a
  second. No cell starts while the hottest DIMM is above 58 °C.
- Cells run round-robin, three passes each, in one container per sweep. An `auto` cache
  is sized once per placement and reused in every pass.

## Method

Harness: `placement-sweep.sh` at the branch head when the queue starts (its commit is in
each run's `manifest.json`), staged with [`push-harness.sh`](../../push-harness.sh). A
queue on the host runs these after the cold-load-modes run:

```bash
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
# CT 123, with the VMID=123 thermal guard already running
VMID=123 CELLS=runs/2026-10-08-kv-context.cells DEPTHS="0,8000,44000,82000" \
  PROBE_CLASSES=code ./placement-sweep.sh
VMID=123 CONFIGS="34 34:auto 40:auto 48:leave12288" DEPTHS="0,8000" ./placement-sweep.sh
# CT 120 takes both cards; the guard moves to VMID=120
pct shutdown 123 && pct start 120
VMID=120 ./install.sh && ./ct120-cutover.sh to-qwen38fn
VMID=120 ./thermal-guard.sh
VMID=120 CELLS=runs/2026-10-08-configurations.cells DEPTHS="0,8000" ./placement-sweep.sh
./ct120-cutover.sh to-qwen36 && pct shutdown 120
```

- `REPS=3`, `N_PREDICT=256`, prompt classes code, list and prose. The context sweep uses
  code prompts only: each class at depth costs its own full prefill.
- Depth targets: the probe's filler gives about 0.72 as many prompt tokens as the target,
  so 8000, 44000, 82000 and 165000 give about 5.8k, 31.8k, 59.3k and 119.3k tokens. The
  summary prints the measured sizes.
- Each cell's batch comes from its mode: two cards 1024/256 (the shape the split rule was
  found at), one card and CPU 4096/1024; `2gpu-34` overrides to 4096/1024 to match
  `1gpu-34`. ctx 65536 except `q8-128k`, parallel 1, 16 threads, q8_0 KV except
  `f16-64k`, projector on the CPU.
- The configurations sweep's one-GPU cells run on `Vulkan0`, `0000:03:00.0`, in the
  two-card container; the sweep reads VRAM from the card each cell loaded onto. CT 123's
  sweeps run on `0000:83:00.0`.
- Cache sizing: `auto` starts the placement without a cache, runs one code prompt at d8000
  through the probe, then sets the cache to the lower of the free VRAM right after load
  and after that prompt, minus `CACHE_MARGIN_MIB=1024`. `leave12288` uses the same
  measurement and leaves 12,288 MiB instead. The cache sweep runs every cell at `-lv 4`,
  the level at which this build logs the cache's size and hit rate. GTT growth over
  256 MiB after the probe flags a spill.
- RADV limits one allocation to 4 GiB (`maxMemoryAllocationSize`), and the cache keeps
  each expert tensor type in one buffer. At `-ncmoe 48` a 13,000 MiB cache needs a
  4.46 GiB buffer and fails, and 11,302 MiB loads, so `48:leave12288` (11,297 MiB) is
  within about 3% of the largest cache this card holds there. With llama-server's
  default fit check, an unallocatable cache aborts on a scheduler assertion
  (`ggml-backend.cpp:1084`) instead of a clean error.
- **Telemetry:** once a second, each card's busy %, VRAM-controller busy %, sclk, power
  and junction temperature, and the container's CPU time. The probe records each
  request's start and its prompt and generation times, which place each sample in
  prefill or decode.
- Expected duration: about 3.5 hours for the context cells, 1.5 for the cache cells and
  2.5 for the configurations, plus the cutovers: about 7.5 hours.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`, one per sweep.

## Safety

- Every other guest stays shut down. CT 123 is shut down before the cutover, and the
  cutover clears its `onboot`; `to-qwen36` restores it and gives GPU 2 back. CT 120 is
  shut down at the end. Starting any guest again waits for the owner's go-ahead.
- `thermal-guard.sh` watches the cards of the container under test. On a trip it writes
  `/root/qwen38-flash-next/THERMAL_TRIP`, and the queue starts nothing further.
- The sweep starts no cell while the hottest DIMM is above 58 °C.
- At `-ncmoe 48` about 104 GB (97 GiB) of weights stay in host RAM, within CT 123's
  120 GiB. The cutover gives CT 120 48 cores and 160 GiB, enough for the CPU-only cell.
- Keep clear of the Sunday 01:00 backup window.

## Environment

llama.cpp b11505 (`ff5888f99`, release tarball), Mesa 26.2.4 (kisak-mesa), kernel
`7.0.14-22-pve`, pve-firmware 3.18-7, `schedutil`, 8 × 64 GB DDR4-3200, both V620s at
0 mV and 250 W on PCIe 4.0 x16. CT 123 with 24 cores and 120 GiB on `0000:83:00.0`
(`unique_id` `99b104541144b36c`); CT 120 with 48 cores and 160 GiB on both cards,
`0000:03:00.0` being `150e6a6800f84ebe`. Harness `39babf7`.

The two CT 123 sweeps captured the same environment apart from the time.

<details>
<summary>environment.json, CT 123 (context-depth sweep)</summary>

```json
{
 "captured_at": "2026-10-09T07:01:31Z",
 "host": {
  "hostname": "proxmox",
  "kernel": "7.0.14-22-pve",
  "pve_manager": "9.2.21",
  "pve_firmware": "3.18-7",
  "cpu": "AMD EPYC 7532 32-Core Processor",
  "governor": "schedutil",
  "mem_gib": 504,
  "dimms": [
   {
    "locator": "P0 CHANNEL A",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL B",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL C",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL D",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL E",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL F",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL G",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL H",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   }
  ]
 },
 "guest": {
  "unit": "llamacpp-qwen38fn",
  "env_file": "/etc/llamacpp-qwen38fn.env",
  "env": {
   "LLAMACPP_DIR": "/opt/llamacpp/llama-b11505",
   "MODEL_PATH": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf",
   "MODEL_ALIAS": "qwen3.8-flash-next",
   "MODEL_MMPROJ": "/models/hf/qwen3.8-flash-next/mmproj-F16.gguf",
   "MODEL_SERVER_BIND": "0.0.0.0",
   "MODEL_SERVER_PORT": "1234",
   "MODEL_GPU_LAYERS": "99",
   "MODEL_OT_OVERRIDE": "per_layer_token_embd=CPU",
   "MODEL_CPU_MOE": "34",
   "MODEL_MOE_CACHE_MIB": "",
   "MODEL_CONTEXT_LENGTH": "65536",
   "MODEL_PARALLEL": "1",
   "MODEL_THREADS": "16",
   "MODEL_EXPECTED_GPUS": "1",
   "MODEL_TENSOR_SPLIT": "",
   "MODEL_LOAD_MODE": "",
   "EXTRA_ARGS": "--device Vulkan0",
   "MODEL_BATCH_SIZE": "4096",
   "MODEL_UBATCH_SIZE": "1024",
   "MODEL_KV_TYPE": "q8_0",
   "MODEL_MMPROJ_ON_CPU": "true"
  },
  "unit_active": "active",
  "server_cmdline": "/opt/llamacpp/llama-b11505/llama-server --model /models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf --host 0.0.0.0 --port 1234 --alias qwen3.8-flash-next --n-gpu-layers 99 --ctx-size 65536 --parallel 1 --threads 16 --flash-attn on --batch-size 4096 --ubatch-size 1024 --jinja --reasoning off --reasoning-format auto --cache-ram 0 --metrics --override-tensor per_layer_token_embd=CPU --n-cpu-moe 34 --cache-type-k q8_0 --cache-type-v q8_0 --mmproj /models/hf/qwen3.8-flash-next/mmproj-F16.gguf --no-mmproj-offload --device Vulkan0",
  "llamacpp": {
   "dir": "/opt/llamacpp/llama-b11505",
   "version": "version: 0.6.0-dev (build 11505, commit ff5888f99)",
   "built_with": "built with GNU 11.4.0 for Linux x86_64",
   "llama_server_sha256": "b8f67ab0ac46efeed0bc84fe84ef51e9eee08a52c5f7fe56375ec89d3f79729c",
   "devices": "Vulkan0: AMD Radeon Pro V620 (RADV NAVI21) (30704 MiB, 30686 MiB free)"
  },
  "os": "Ubuntu 24.04 LTS",
  "guest_kernel": "7.0.14-22-pve",
  "mesa": "26.2.4~kisak1~n",
  "vulkan_driver": "Mesa 26.2.4 - kisak-mesa PPA",
  "rocm": null,
  "model_files": [
   {
    "path": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf",
    "exists": true,
    "bytes": 10946624,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf",
    "exists": true,
    "bytes": 49859583136,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf",
    "exists": true,
    "bytes": 49376141504,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf",
    "exists": true,
    "bytes": 12087983520,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/qwen3.8-flash-next/mmproj-F16.gguf",
    "exists": true,
    "bytes": 904004000,
    "verified_stamp": true
   }
  ],
  "vmid": 123,
  "kind": "lxc",
  "config": {
   "cores": "24",
   "hostname": "gpu2",
   "memory": "122880",
   "ostype": "ubuntu",
   "swap": "4096"
  }
 },
 "cards": [
  {
   "pci": "0000:83:00.0",
   "name": "Advanced Micro Devices, Inc. [AMD/ATI] Navi 21 [Radeon Pro V620]",
   "driver": "amdgpu",
   "unique_id": "99b104541144b36c",
   "vbios": "113-D6030500-100",
   "vram_total_mib": 30704,
   "od_vddgfx_offset": "0mV",
   "power_cap_w": 250,
   "pcie_link": "16.0GT/s, x16 619Mhz"
  }
 ]
}
```

</details>

<details>
<summary>environment.json, CT 120 (configurations sweep)</summary>

```json
{
 "captured_at": "2026-10-09T12:06:59Z",
 "host": {
  "hostname": "proxmox",
  "kernel": "7.0.14-22-pve",
  "pve_manager": "9.2.21",
  "pve_firmware": "3.18-7",
  "cpu": "AMD EPYC 7532 32-Core Processor",
  "governor": "schedutil",
  "mem_gib": 504,
  "dimms": [
   {
    "locator": "P0 CHANNEL A",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL B",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL C",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL D",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL E",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL F",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL G",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   },
   {
    "locator": "P0 CHANNEL H",
    "size": "64 GB",
    "part": "M393A8K40B22-CAE",
    "configured_speed": "3200 MT/s"
   }
  ]
 },
 "guest": {
  "unit": "llamacpp-qwen38fn",
  "env_file": "/etc/llamacpp-qwen38fn.env",
  "env": {
   "LLAMACPP_DIR": "/opt/llamacpp/llama-b11505",
   "MODEL_PATH": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf",
   "MODEL_ALIAS": "qwen3.8-flash-next",
   "MODEL_MMPROJ": "/models/hf/qwen3.8-flash-next/mmproj-F16.gguf",
   "MODEL_SERVER_BIND": "0.0.0.0",
   "MODEL_SERVER_PORT": "1234",
   "MODEL_GPU_LAYERS": "99",
   "MODEL_OT_OVERRIDE": "per_layer_token_embd=CPU",
   "MODEL_CPU_MOE": "16",
   "MODEL_CONTEXT_LENGTH": "65536",
   "MODEL_PARALLEL": "1",
   "MODEL_THREADS": "16",
   "MODEL_EXPECTED_GPUS": "2",
   "MODEL_TENSOR_SPLIT": "30,18",
   "MODEL_BATCH_SIZE": "1024",
   "MODEL_UBATCH_SIZE": "256",
   "MODEL_KV_TYPE": "q8_0",
   "MODEL_MMPROJ_ON_CPU": "true",
   "MODEL_LOAD_MODE": "",
   "EXTRA_ARGS": ""
  },
  "unit_active": "active",
  "server_cmdline": "/opt/llamacpp/llama-b11505/llama-server --model /models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf --host 0.0.0.0 --port 1234 --alias qwen3.8-flash-next --n-gpu-layers 99 --ctx-size 65536 --parallel 1 --threads 16 --flash-attn on --batch-size 1024 --ubatch-size 256 --jinja --reasoning off --reasoning-format auto --cache-ram 0 --metrics --override-tensor per_layer_token_embd=CPU --n-cpu-moe 16 --tensor-split 30,18 --cache-type-k q8_0 --cache-type-v q8_0 --mmproj /models/hf/qwen3.8-flash-next/mmproj-F16.gguf --no-mmproj-offload",
  "llamacpp": {
   "dir": "/opt/llamacpp/llama-b11505",
   "version": "version: 0.6.0-dev (build 11505, commit ff5888f99)",
   "built_with": "built with GNU 11.4.0 for Linux x86_64",
   "llama_server_sha256": "b8f67ab0ac46efeed0bc84fe84ef51e9eee08a52c5f7fe56375ec89d3f79729c",
   "devices": "Vulkan0: AMD Radeon Pro V620 (RADV NAVI21) (30704 MiB, 2881 MiB free)\n  Vulkan1: AMD Radeon Pro V620 (RADV NAVI21) (30704 MiB, 2018 MiB free)"
  },
  "os": "Ubuntu 24.04 LTS",
  "guest_kernel": "7.0.14-22-pve",
  "mesa": "26.2.4~kisak1~n",
  "vulkan_driver": "Mesa 26.2.4 - kisak-mesa PPA",
  "rocm": null,
  "model_files": [
   {
    "path": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf",
    "exists": true,
    "bytes": 10946624,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf",
    "exists": true,
    "bytes": 49859583136,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf",
    "exists": true,
    "bytes": 49376141504,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf",
    "exists": true,
    "bytes": 12087983520,
    "verified_stamp": true
   },
   {
    "path": "/models/hf/qwen3.8-flash-next/mmproj-F16.gguf",
    "exists": true,
    "bytes": 904004000,
    "verified_stamp": true
   }
  ],
  "vmid": 120,
  "kind": "lxc",
  "config": {
   "cores": "48",
   "hostname": "llamacpp",
   "memory": "163840",
   "ostype": "ubuntu",
   "swap": "0"
  }
 },
 "cards": [
  {
   "pci": "0000:03:00.0",
   "name": "Advanced Micro Devices, Inc. [AMD/ATI] Navi 21 [Radeon Pro V620]",
   "driver": "amdgpu",
   "unique_id": "150e6a6800f84ebe",
   "vbios": "113-D6030500-100",
   "vram_total_mib": 30704,
   "od_vddgfx_offset": "0mV",
   "power_cap_w": 250,
   "pcie_link": "16.0GT/s, x16 619Mhz"
  },
  {
   "pci": "0000:83:00.0",
   "name": "Advanced Micro Devices, Inc. [AMD/ATI] Navi 21 [Radeon Pro V620]",
   "driver": "amdgpu",
   "unique_id": "99b104541144b36c",
   "vbios": "113-D6030500-100",
   "vram_total_mib": 30704,
   "od_vddgfx_offset": "0mV",
   "power_cap_w": 250,
   "pcie_link": "16.0GT/s, x16 619Mhz"
  }
 ]
}
```

</details>

---

## Results

Three sweeps, all at harness `39babf7`. Every cell loaded, and its three passes produced
identical text in every prompt cell. No cell had a DIMM sample at 66 °C and the thermal
guard never tripped.

### Configurations, CT 120

Raw data: `/root/qwen38-flash-next/sweep-20261009T120655Z/`. Twenty-one cells, three
round-robin passes of seven configurations, 2 h 18 min. d0 prompts were 21–31 tokens and
d8000 prompts 5,783–5,793. The one-card cells loaded onto `0000:03:00.0`.

**Utilization**, median of the 1 s samples across the three passes; prefill is the d8000
requests' prompt time and decode their generation. Two-card cells list `03:00.0` /
`83:00.0`:

| Cell | Phase | Power, W | sclk, MHz | Busy % | VRAM busy % | Max junction, °C | CPU cores |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `2gpu-16` | prefill | 50 / 21 | 507 / 0 | 50 / 0 | 4 / 0 | 69 / 62 | 0.9 |
| | decode | 51 / 43 | 507 / 116 | 53 / 7 | 23 / 5 | 53 / 46 | 8.8 |
| `2gpu-16-tensor` | prefill | 33 / 31 | 66 / 248 | 10 / 14 | 3 / 6 | 62 / 59 | 8.6 |
| | decode | 47 / 44 | 501 / 499 | 52 / 50 | 17 / 16 | 53 / 50 | 7.5 |
| `2gpu-34` | prefill | 61 / 7 | 541 / 0 | 52 / 0 | 4 / 0 | 67 / 59 | 0.9 |
| | decode | 50 / 32 | 501 / 67 | 57 / 4 | 25 / 3 | 53 / 45 | 12.3 |
| `1gpu-34` | prefill | 62 | 554 | 50 | 4 | 71 | 0.9 |
| | decode | 66 | 829 | 61 | 37 | 57 | 13.4 |
| `1gpu-40` | prefill | 62 | 554 | 50 | 4 | 71 | 0.9 |
| | decode | 57 | 545 | 61 | 29 | 56 | 14.5 |
| `1gpu-48` | prefill | 61 | 555 | 49 | 4 | 61 | 0.9 |
| | decode | 53 | 500 | 61 | 27 | 55 | 15.6 |
| `cpu` | prefill | — | — | — | — | — | 14.5 |
| | decode | — | — | — | — | — | 16.0 |

In layer-split prefill, `83:00.0` had its clock up in 71 of `2gpu-16`'s 549 prefill
seconds and 11 of `2gpu-34`'s 399, averaging 144 W and 129 W in those seconds;
`03:00.0` worked through all of them. No configuration's median power in either phase
exceeded 66 W of the 250 W cap.

**Decode**, median of three passes, t/s:

| Cell | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `2gpu-16` | 15.3 | 15.3 | 15.3 | 15.1 | 15.1 | 15.0 |
| `2gpu-16-tensor` | 8.6 | 8.5 | 8.6 | 8.4 | 8.4 | 8.4 |
| `2gpu-34` | 11.7 | 11.8 | 11.7 | 11.3 | 11.2 | 11.2 |
| `1gpu-34` | 14.9 | 14.7 | 14.6 | 14.2 | 14.3 | 14.5 |
| `1gpu-40` | 13.1 | 13.2 | 13.0 | 12.7 | 12.7 | 12.4 |
| `1gpu-48` | 11.5 | 11.4 | 11.2 | 10.8 | 10.9 | 10.8 |
| `cpu` | 9.0 | 8.8 | 8.7 | 8.0 | 7.9 | 8.0 |

The largest pass-to-pass spread within one prompt cell was 0.25–0.28 t/s for the
`-ncmoe 16` cells, 0.40–0.48 for `2gpu-34`, `1gpu-48` and `cpu`, 0.95 for `1gpu-34` and
0.99 for `1gpu-40` (d0 list, 12.78–13.76).

**Prefill at d8000**, median per prompt class, t/s, and the time to first token for a
~5,790-token prompt at the median of the three classes:

| Cell | code | list | prose | Time to first token |
| --- | ---: | ---: | ---: | ---: |
| `2gpu-16` | 90.0 | 90.5 | 90.4 | 64 s |
| `2gpu-16-tensor` | 138.7 | 132.6 | 138.2 | 42 s |
| `2gpu-34` | 122.3 | 123.6 | 124.3 | 47 s |
| `1gpu-34` | 123.9 | 124.3 | 124.5 | 47 s |
| `1gpu-40` | 105.8 | 106.2 | 107.2 | 55 s |
| `1gpu-48` | 91.3 | 92.0 | 91.9 | 63 s |
| `cpu` | 31.9 | 35.7 | 34.1 | 170 s |

The `2gpu-16-tensor` and `cpu` passes spread by up to 11.8 and 5.3 t/s within a prompt
class; every other cell's stayed under 3 t/s.

**Memory and load**, VRAM and GTT identical in all three passes:

| Cell | VRAM used, MiB | VRAM free, MiB | GTT on `03:00.0`, before → after probe | Load, median |
| --- | --- | --- | --- | ---: |
| `2gpu-16` | 27,822 + 28,685 | 2,882 + 2,019 | 69 → 97 MiB | 28 s |
| `2gpu-16-tensor` | 28,231 + 28,081 | 2,473 + 2,623 | 112 → 115 MiB | 37 s |
| `2gpu-34` | 14,625 + 14,703 | 16,079 + 16,001 | 226 → 300 MiB | 18 s |
| `1gpu-34` | 28,627 | 2,077 | 226 → 263 MiB | 17 s |
| `1gpu-40` | 19,621 | 11,083 | 226 → 264 MiB | 13 s |
| `1gpu-48` | 7,114 | 23,590 | 226 → 264 MiB | 9 s |
| `cpu` | 16 + 16 | 30,688 + 30,688 | 14 → 14 MiB | 62 s |

One-card rows are `0000:03:00.0`; the other card held 16 MiB. GTT on `83:00.0` stayed at
14–18 MiB. No cell was flagged for spill. After each card load CT 120 was charged a
median 1.7–1.8 GiB, 0.5 GiB of it page cache; after the CPU-only load, 44.2 GiB, 43.5 GiB
of it anonymous.

**Output gate:** no degenerate output; all seven template-contract checks passed.
`2gpu-34`'s text matched `1gpu-34`'s in all six prompt cells; `1gpu-40` differed from
`1gpu-34` in three, `2gpu-16` and `1gpu-48` in five, and `2gpu-16-tensor` and `cpu` in all
six.

**Thermals:** hottest DIMM 51–54 °C in the GPU cells and 57 °C in `cpu`.

`1gpu-34` ran here in CT 120 on `0000:03:00.0` with 48 cores. The same placement in
CT 123 on `0000:83:00.0` with 24 cores, the cache sweep's control below, decoded 11.9–14.4
t/s. The [card comparison](../../runs/2026-10-08-card-ab.md) compares the two cards.

### Context depth and KV type, CT 123

Raw data: `/root/qwen38-flash-next/sweep-20261009T070127Z/`. Nine cells, three
round-robin passes of three configurations, 3 h 31 min. Code prompts measured 31, 5,793,
31,808, 59,285 and 119,270 tokens.

**Utilization**, as above; prefill is the deep requests' prompt time:

| Cell | Phase | Power, W | sclk, MHz | Busy % | VRAM busy % | Max junction, °C | CPU cores |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `q8-64k` | prefill | 64 | 567 | 52 | 4 | 71 | 0.9 |
| | decode | 62 | 645 | 61 | 30 | 69 | 13.4 |
| `f16-64k` | prefill | 64 | 608 | 55 | 4 | 71 | 0.9 |
| | decode | 62 | 746 | 61 | 35 | 55 | 13.3 |
| `q8-128k` | prefill | 67 | 760 | 62 | 3 | 71 | 0.8 |
| | decode | 62 | 691 | 62 | 31 | 64 | 13.4 |

Pooled over every pass of the three cells, prefill averaged 80 W, with 3% of its seconds
at 200 W or more and 23% with sclk at 2 GHz or more; decode averaged 60 W, with one second
of 631 at 200 W.

**Decode**, code prompts, median of three passes (range), t/s:

| Cell | d0 | ~5.8k | ~31.8k | ~59.3k | ~119.3k |
| --- | ---: | ---: | ---: | ---: | ---: |
| `q8-64k` | 12.3 (11.8–13.5) | 12.1 (12.0–12.9) | 12.9 (12.7–13.0) | 12.5 (11.3–12.8) | — |
| `f16-64k` | 12.7 (12.1–14.1) | 13.7 (12.4–13.9) | 13.6 (12.0–13.7) | 12.8 (11.4–13.4) | — |
| `q8-128k` | 11.6 (10.8–13.7) | 11.3 (11.2–11.5) | 11.8 (7.0–13.4) | 12.8 (12.1–13.1) | 10.0 (9.8–12.1) |

**Prefill**, code prompts, median of three passes (range), t/s:

| Cell | ~5.8k | ~31.8k | ~59.3k | ~119.3k |
| --- | ---: | ---: | ---: | ---: |
| `q8-64k` | 122.4 (121.2–122.6) | 124.0 (123.9–124.1) | 121.2 (121.1–121.7) | — |
| `f16-64k` | 118.7 (117.6–118.9) | 120.0 (119.8–120.3) | 111.1 (111.0–111.1) | — |
| `q8-128k` | 104.6 (103.2–105.0) | 111.5 (111.5–112.2) | 102.7 (102.3–103.0) | 93.2 (89.8–95.7) |

The ~119k-token prompt took about 21 minutes to its first token.

**Memory**, identical in all three passes:

| Cell | VRAM used, load / after probe, MiB | VRAM free, load / after probe, MiB | GTT, load → after probe |
| --- | --- | --- | --- |
| `q8-64k` | 28,627 / 28,772 | 2,077 / 1,932 | 226 → 319 MiB |
| `f16-64k` | 29,527 / 29,671 | 1,177 / 1,033 | 226 → 304 MiB |
| `q8-128k` | 29,772 / 29,576 | 932 / 1,128 | 387 → 915 MiB |

`q8-128k` was flagged for spill in every pass. It loaded with 932 MiB free, and during
its probe its VRAM use fell 196 MiB while its GTT rose 528 MiB: allocations moved to
system memory. Loads took 16–18 s.

**Output gate:** no degenerate output; all seven template-contract checks passed.
`q8-128k`'s text matched `q8-64k`'s at all four shared depths; `f16-64k`'s differed at
three.

**Thermals:** hottest DIMM 54–57 °C.

### `--moe-cache-mib`, CT 123

Raw data: `/root/qwen38-flash-next/sweep-20261009T103318Z/`. Twelve cells, three
round-robin passes of four configurations, 1 h 30 min. d8000 prompts were 5,783–5,793
tokens.

**Utilization**, as above:

| Config | Phase | Power, W | sclk, MHz | Busy % | VRAM busy % | Max junction, °C | CPU cores |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `34`, no cache | prefill | 58 | 547 | 50 | 4 | 69 | 0.9 |
| | decode | 61 | 647 | 60 | 31 | 52 | 13.4 |
| `34:auto` | prefill | 60 | 603 | 58 | 4 | 68 | 0.9 |
| | decode | 45 | 501 | 53 | 10 | 52 | 2.8 |
| `40:auto` | prefill | 61 | 605 | 55 | 4 | 66 | 0.9 |
| | decode | 50 | 508 | 63 | 22 | 52 | 2.5 |
| `48:leave12288` | prefill | 60 | 559 | 51 | 5 | 55 | 0.9 |
| | decode | 48 | 500 | 62 | 19 | 51 | 2.3 |

With a cache, decode drew 45–50 W on the card and kept 2.3–2.8 cores busy, against 61 W
and 13.4 cores without one.

**Decode**, median of three passes, t/s, and **prefill** at d8000, median of the nine
requests:

| Config | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose | Prefill |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `34`, no cache (control) | 13.8 | 11.9 | 14.4 | 12.2 | 12.7 | 13.7 | 123.2 |
| `34:auto`, 1,009 MiB | 4.3 | 4.2 | 4.2 | 4.5 | 4.2 | 4.2 | 113.2 |
| `40:auto`, 10,052 MiB | 7.1 | 9.0 | 7.3 | 7.5 | 8.9 | 6.8 | 103.5 |
| `48:leave12288`, 11,297 MiB | 6.2 | 9.3 | 6.3 | 6.4 | 7.4 | 5.9 | 96.5 |

The control's third pass decoded 8.4–10.5 t/s in four of its six prompt cells, so its
passes ranged 8.4–14.5 t/s, up to 5.9 t/s apart within a prompt cell. The fastest pass
of any cache configuration was 9.4 t/s.

**Memory and cache**, identical in all three passes:

| Config | Host experts cached | Free VRAM at load / after probe | GTT before → after probe | Decode hit rate | Uploaded per cell |
| --- | --- | --- | --- | ---: | ---: |
| `34` | — | 2,077 / 2,155 MiB | 226 → 263 MiB | — | — |
| `34:auto` | 1.9% of 51,950 MiB; one layer uncached | 1,067 / 1,337 MiB | 229 → 478 MiB | 34.9% | 963 GiB |
| `40:auto` | 16.5% of 60,950 MiB | 1,027 / 1,097 MiB | 230 → 257 MiB | 78.8% | 384 GiB |
| `48:leave12288` | 15.4% of 73,450 MiB | 12,288 / 12,362 MiB | 230 → 255 MiB | 78.8% | 463 GiB |

"Uploaded" is the decode-path (`ubatch <= 8`) upload total for one cell, which decodes
1,536 tokens: about 640, 256 and 309 MiB per token. `34:auto`'s GTT grew 249 MiB while its
free VRAM rose 270 MiB, so it reads as the cache's upload staging, not a spill; no cell
was flagged. Loads took 10–19 s.

**Output gate:** no degenerate output; all seven template-contract checks passed. The
cache configurations' text differed from the control's in 17 of 18 prompt cells.

**Thermals:** hottest DIMM 53–54 °C.

## Deviations

- The three sweeps ran from the host queue (`qwen38-queue`) after the cold-load-modes
  run, with the plan's cells, depths and harness. The CT 123 sweeps ran under the guard
  started for an earlier context-depth run, from harness `57336e5`; its
  `thermal-guard.sh` is identical to `39babf7`'s.
- From about 03:05 to 06:15 ET, during the context-depth sweep, the Wi-Fi bridge that
  links the server to the house network stopped forwarding until it was power-cycled.
  The host stayed up. The sweep runs on the host and reaches CT 123 over the host's
  bridge, and its 1 s card samples and ~13 s DIMM samples have no gap over that window.
- At the cutover, the queue's start of the CT 120 guard failed: `systemd-run` does not
  resolve a relative executable against `--working-directory`. The queue stopped before
  the configurations sweep, leaving CT 120 idle on both cards with the host's
  `gpu-thermal-watchdog` mapped to it. One minute later a resume script with the queue's
  remaining steps and the guard's absolute path started the guard, then the sweep.
- Harness `39babf7` is on the branch of PR #98, not on `main`.
- The plan reran three sweeps from 2026-10-08 that had no telemetry. On 2026-10-10 the
  owner had those first runs' records and raw data deleted as duplicates. This record
  took over their questions, left-out configurations and method notes, and dropped its
  comparison with them.

## Conclusion

- **Every cell** loaded and passed the output gate. Only `q8-128k` was flagged for
  spill. No cell was DIMM-capped (hottest 51–57 °C), and the guard never tripped.
- **One card or two at `-ncmoe 34`, batch 4096/1024:** two cards decoded slower in every
  prompt cell, by 20–23% (11.2–11.8 against 14.2–14.9 t/s), more than either cell's
  spread. Prefill was equal within the spread (122.3–124.3 against 123.9–124.5 t/s), and
  both produced identical text. The two-card decode cost persists on eight channels.
- **Layer or tensor split at `-ncmoe 16`, batch 1024/256:** `-sm tensor` decoded 44% slower
  in every prompt cell (8.4–8.6 against 15.0–15.3 t/s) and prefilled 47–54% faster (133–139
  against 90.0–90.5 t/s), each by more than either cell's spread. It loaded in 37 s against 28 s,
  with the same total VRAM within 0.2 GiB.
- **The standard configurations,** by median decode: `2gpu-16` (15.0–15.3 t/s, 4.8 GiB
  free across both cards) ahead of `1gpu-34` (14.2–14.9, the other card free) in five of
  six prompt cells by more than the spread, then `1gpu-40` (12.4–13.2), `2gpu-34`
  (11.2–11.8), `1gpu-48` (10.8–11.5, 23.0 GiB free on its card) and `cpu` (7.9–9.0).
  Prefill at d8000 is highest for `2gpu-16-tensor` (133–139 t/s, 42 s to the first token
  of a ~5.8k-token prompt), then the two `-ncmoe 34` cells (122–125, 47 s), and lowest for
  `cpu` (32–36, 170 s).
- **Depth:** at the deployed settings, prefill held at 121–124 t/s from ~5.8k to ~59.3k
  tokens. Decode medians were 12.1–12.9 t/s, with no change across depth larger than the
  pass-to-pass spread.
- **KV type:** f16 used 900 MiB more VRAM and prefilled 3.0%, 3.2% and 8.4% slower than
  q8_0 at ~5.8k, ~31.8k and ~59.3k tokens, each by more than both cells' spread. Its
  decode was 13% faster at ~5.8k (13.7 against 12.1 t/s), beyond the spread, and within
  the spread at the other depths.
- **128k:** it does not run without spill at `-ncmoe 34`. It loaded with 932 MiB free,
  moved allocations to GTT during its probe, and prefilled 15%, 10% and 15% slower than
  `q8-64k` at the shared depths, each by more than the spread. Its decode at those depths
  differed by less than the spread. At ~119k tokens it decoded 10.0 t/s and prefilled
  93.2 t/s, about 21 minutes to the first token.
- **MoE cache, it runs:** yes, on RADV with Mesa 26.2.4. Every cache cell allocated its
  cache, logged a decode hit rate, showed no spill and passed the output gate. RADV's
  4 GiB per-allocation limit caps the cache at `-ncmoe 48` between 11,302 MiB, which
  loaded, and 13,000 MiB, which did not, well under the free VRAM; an unallocatable cache
  aborts llama-server's default fit check.
- **MoE cache, it is faster:** no. No cache configuration beat the control in any prompt
  cell. Their medians of six were 4.2, 7.4 and 6.3 t/s against 13.2 (−68%, −44%, −52%),
  slower by more than the control's spread in all six prompt cells for `34:auto` and in
  five for the others; at d0 list both fell within the control's spread. Prefill at d8000
  fell 8%, 16% and 22%. `48:leave12288` kept 12.1 GiB free after its probe, against the
  control's 2.1 GiB.
- **One card**, at every placement: prefill ran the card at a median 58–67 W and
  547–760 MHz with under one CPU core in use, reaching 200 W in 0–5% of its seconds.
  Decode drew 53–66 W with 13.3–15.6 cores in use. With a MoE cache, decode drew
  45–50 W with 2.3–2.8 cores.
- **Two cards, layer split:** in prefill, `03:00.0`, which holds the layers whose experts
  are on the CPU, worked every second at a median 50–61 W; `83:00.0` worked in 3–13% of
  them. In decode at `-ncmoe 16` the cards drew 51 and 43 W with 8.8 cores in use.
- **Two cards, tensor split:** prefill drew 33 and 31 W with 8.6 cores in use, decode 47
  and 44 W with 7.5.
- **CPU only:** 14.5 cores in prefill and 16.0 in decode.
- No configuration's median card power exceeded 66 W of the 250 W cap in any phase.
