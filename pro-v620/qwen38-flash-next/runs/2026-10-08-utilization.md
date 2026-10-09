# Qwen3.8-Flash-Next: what each configuration uses, rerun with telemetry

Plan committed 2026-10-08 · Run 2026-10-09 · Status: done

## Question

The [configurations](2026-10-08-configurations.md),
[context depth and KV type](2026-10-08-kv-context.md) and
[`--moe-cache-mib`](2026-10-08-moe-cache.md) runs measured speed but not what limits it.
Rerun their cells with per-phase telemetry:

- **Utilization:** in prefill, decode and, where measured, concurrent streams, how hard
  does each card work (power against its 250 W cap, clocks, busy %) and how many CPU
  cores does the container use? A 60-second sample during a ~119k-token prefill read
  30–180 W and under one CPU core.
- **Reproducibility:** do the reruns reproduce the first runs' decode and prefill?

## What answers it

- Every cell loads, shows no GTT spill and passes the output gate (`SUMMARY.md` flags
  each). The q8_0 128k cell loads under 1 GiB free and is flagged, as in its first run.
- **Utilization:** `SUMMARY.md`'s Utilization table for every cell and phase: median
  busy %, power and sclk per card holding the model, the highest junction temperature,
  and the CPU cores in use.
- **Reproducibility:** each cell's median decode per prompt cell and prefill at d8000
  against its first run. A difference counts when it is larger than the pass-to-pass
  spread of both runs.
- A cell with any DIMM sample at 66 °C is invalid.

## Configurations

| Rerun of | Container | Cells |
| --- | --- | --- |
| Configurations | CT 120, both cards | the seven cells of [`2026-10-08-configurations.cells`](2026-10-08-configurations.cells): two GPUs, one GPU, CPU only and optimized |
| Context depth and KV type | CT 123 | [`2026-10-08-kv-context.cells`](2026-10-08-kv-context.cells): q8_0 and f16 at 64k, q8_0 at 128k |
| `--moe-cache-mib` | CT 123 | `CONFIGS="34 34:auto 40:auto 48:leave12288"` |

The standard configurations included and left out are as in each first run's record.

## Controls

- Each first run is the control for its rerun: same cells, depths, prompt classes,
  container, card and build.
- The harness differs in two ways. A host-side sampler reads sysfs and the container's
  CPU counter once a second. No cell starts while the hottest DIMM is above 58 °C.
- Cells run round-robin, three passes each, as in the first runs.

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

- Each sweep's settings are its first run's: `REPS=3`, `N_PREDICT=256`; for the
  context cells, code prompts only, targets to ~59k tokens and ~119k for the 128k cell;
  for the cache cells, `CACHE_MARGIN_MIB=1024` and `-lv 4`.
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
- Keep clear of the Sunday 01:00 backup window.

## Environment

llama.cpp b11505 (`ff5888f99`, release tarball), Mesa 26.2.4 (kisak-mesa), kernel
`7.0.14-22-pve`, pve-firmware 3.18-7, `schedutil`, 8 × 64 GB DDR4-3200, both V620s at
0 mV and 250 W on PCIe 4.0 x16. CT 123 with 24 cores and 120 GiB on `0000:83:00.0`
(`unique_id` `99b104541144b36c`); CT 120 with 48 cores and 160 GiB on both cards,
`0000:03:00.0` being `150e6a6800f84ebe`. Harness `39babf7`.

The two CT 123 sweeps captured the same environment apart from the time. Against their
first runs, each capture differs only in the free VRAM `--list-devices` read at capture
and in the cards' `unique_id`, which `capture-env.sh` records since the first runs.

<details>
<summary>environment.json, CT 123 (context-depth rerun)</summary>

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
<summary>environment.json, CT 120 (configurations rerun)</summary>

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

Three sweeps, all at harness `39babf7`. Each rerun matched its first run's prompt sizes
and its VRAM, GTT and free VRAM in every pass, and produced the same text as its first
run in every prompt cell. No cell had a DIMM sample at 66 °C and no thermal-guard trip
occurred.

### Context depth and KV type, CT 123

Raw data: `/root/qwen38-flash-next/sweep-20261009T070127Z/`. Nine cells, three
round-robin passes of three configurations, 3 h 31 min. Code prompts measured 31, 5,793,
31,808, 59,285 and 119,270 tokens, as in the first run.

**Utilization**, median of the 1 s samples across the three passes; prefill is the
deep requests' prompt time and decode their generation:

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
of 631 at 200 W. The first run's read-only monitor, over part of that run, read 80 W, 3%
and 22% in prefill and 60 W, 0% in decode.

**Decode**, code prompts, median of three passes (range), t/s:

| Cell | Run | d0 | ~5.8k | ~31.8k | ~59.3k | ~119.3k |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `q8-64k` | first | 13.5 (11.5–13.7) | 12.1 (12.1–12.7) | 12.9 (11.5–13.2) | 12.6 (11.3–12.9) | — |
| | rerun | 12.3 (11.8–13.5) | 12.1 (12.0–12.9) | 12.9 (12.7–13.0) | 12.5 (11.3–12.8) | — |
| `f16-64k` | first | 12.7 (11.4–12.9) | 13.3 (11.9–14.0) | 13.4 (13.2–13.4) | 12.1 (10.8–13.0) | — |
| | rerun | 12.7 (12.1–14.1) | 13.7 (12.4–13.9) | 13.6 (12.0–13.7) | 12.8 (11.4–13.4) | — |
| `q8-128k` | first | 13.8 (13.6–14.0) | 12.9 (12.6–13.5) | 13.3 (10.6–13.8) | 11.4 (9.9–13.1) | 11.9 (11.3–12.7) |
| | rerun | 11.6 (10.8–13.7) | 11.3 (11.2–11.5) | 11.8 (7.0–13.4) | 12.8 (12.1–13.1) | 10.0 (9.8–12.1) |

One prompt cell of fourteen moved by more than both runs' spread: `q8-128k` at ~5.8k,
12.9 → 11.3 t/s. `q8-128k`'s rerun median was also lower at d0, ~31.8k and ~119.3k,
within the spread.

**Prefill**, code prompts, median of three passes (range), t/s:

| Cell | Run | ~5.8k | ~31.8k | ~59.3k | ~119.3k |
| --- | --- | ---: | ---: | ---: | ---: |
| `q8-64k` | first | 121.7 (121.6–122.7) | 123.2 (123.1–123.5) | 120.6 (120.5–121.0) | — |
| | rerun | 122.4 (121.2–122.6) | 124.0 (123.9–124.1) | 121.2 (121.1–121.7) | — |
| `f16-64k` | first | 117.4 (115.5–117.9) | 119.8 (119.7–120.3) | 110.8 (110.7–111.0) | — |
| | rerun | 118.7 (117.6–118.9) | 120.0 (119.8–120.3) | 111.1 (111.0–111.1) | — |
| `q8-128k` | first | 104.2 (103.8–105.0) | 111.7 (111.3–112.0) | 97.8 (95.1–102.5) | 95.4 (89.1–95.9) |
| | rerun | 104.6 (103.2–105.0) | 111.5 (111.5–112.2) | 102.7 (102.3–103.0) | 93.2 (89.8–95.7) |

Rerun medians were within 1.1% of the first run's, except `q8-128k` at ~59.3k (+5.0%) and
~119.3k (−2.3%), both within the spread. Three prompt cells whose spreads were 0.6 t/s
or less moved by more than that, 0.3–0.7%: `q8-64k` at ~31.8k and ~59.3k, `f16-64k` at
~59.3k.

**Memory:** every pass's VRAM, GTT and free VRAM equalled the first run's, including
`q8-128k`'s spill flag: 932 MiB free at load, and during the probe VRAM use fell 196 MiB
while GTT rose 528 MiB. Loads took 16–18 s.

**Output gate:** no degenerate output; all seven template-contract checks passed.

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

| Config | Run | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose | Prefill |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `34`, no cache | first | 13.4 | 12.7 | 13.6 | 13.5 | 13.6 | 13.7 | 122.9 |
| | rerun | 13.8 | 11.9 | 14.4 | 12.2 | 12.7 | 13.7 | 123.2 |
| `34:auto` | first | 4.3 | 4.2 | 4.4 | 4.5 | 4.2 | 4.3 | 112.9 |
| | rerun | 4.3 | 4.2 | 4.2 | 4.5 | 4.2 | 4.2 | 113.2 |
| `40:auto` | first | 7.2 | 9.3 | 7.2 | 7.5 | 9.0 | 6.9 | 104.6 |
| | rerun | 7.1 | 9.0 | 7.3 | 7.5 | 8.9 | 6.8 | 103.5 |
| `48:leave12288` | first | 6.0 | 9.4 | 6.2 | 6.4 | 7.5 | 5.9 | 96.8 |
| | rerun | 6.2 | 9.3 | 6.3 | 6.4 | 7.4 | 5.9 | 96.5 |

Two prompt cells of 24 moved by more than both runs' spread: the control at d8000 code,
13.5 → 12.2 t/s (passes 13.3–13.6 against 11.8–12.5), and `48:leave12288` at d0 code,
6.0 → 6.2 (5.99–6.16 against 6.19–6.24). The control's third pass decoded 8.4–10.5 t/s
in four of its six prompt cells, so its rerun passes ranged 8.4–14.5 t/s against
12.0–14.7 in the first run. One prefill prompt class moved by more than its spread:
the control's list prompts, 122.9 → 124.1 t/s (+1.0%).

**Memory and cache:** every pass's VRAM, GTT, free VRAM and cache size equalled the first
run's, and so did the decode hit rates: 34.9%, 78.8% and 78.8%. No cell was flagged for
spill. Loads took 10–19 s.

**Output gate:** no degenerate output; all seven template-contract checks passed.

**Thermals:** hottest DIMM 53–54 °C.

### Configurations, CT 120

Raw data: `/root/qwen38-flash-next/sweep-20261009T120655Z/`. Twenty-one cells, three
round-robin passes of seven configurations, 2 h 18 min. d0 prompts were 21–31 tokens and
d8000 prompts 5,783–5,793, as in the first run. The one-card cells loaded onto
`0000:03:00.0` again.

**Utilization**, as above; two-card cells list `03:00.0` / `83:00.0`:

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

| Cell | Run | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `2gpu-16` | first | 15.0 | 15.3 | 15.3 | 14.9 | 15.0 | 15.0 |
| | rerun | 15.3 | 15.3 | 15.3 | 15.1 | 15.1 | 15.0 |
| `2gpu-16-tensor` | first | 8.5 | 8.6 | 8.6 | 8.4 | 8.3 | 8.3 |
| | rerun | 8.6 | 8.5 | 8.6 | 8.4 | 8.4 | 8.4 |
| `2gpu-34` | first | 11.5 | 11.7 | 11.6 | 11.3 | 11.2 | 11.2 |
| | rerun | 11.7 | 11.8 | 11.7 | 11.3 | 11.2 | 11.2 |
| `1gpu-34` | first | 14.1 | 14.3 | 15.0 | 14.2 | 14.6 | 14.1 |
| | rerun | 14.9 | 14.7 | 14.6 | 14.2 | 14.3 | 14.5 |
| `1gpu-40` | first | 12.9 | 13.0 | 12.7 | 12.8 | 12.7 | 12.7 |
| | rerun | 13.1 | 13.2 | 13.0 | 12.7 | 12.7 | 12.4 |
| `1gpu-48` | first | 11.4 | 11.2 | 11.4 | 10.8 | 10.7 | 10.7 |
| | rerun | 11.5 | 11.4 | 11.2 | 10.8 | 10.9 | 10.8 |
| `cpu` | first | 9.1 | 8.7 | 8.5 | 7.8 | 8.0 | 7.7 |
| | rerun | 9.0 | 8.8 | 8.7 | 8.0 | 7.9 | 8.0 |

Two prompt cells of 42 moved by more than both runs' spread, both `2gpu-16` code prompts:
d0 15.0 → 15.3 t/s and d8000 14.9 → 15.1.

**Prefill at d8000**, median per prompt class, t/s, and the time to first token for a
~5,790-token prompt at the median of the three classes:

| Cell | Run | code | list | prose | Time to first token |
| --- | --- | ---: | ---: | ---: | ---: |
| `2gpu-16` | first | 89.3 | 90.1 | 90.5 | 64 s |
| | rerun | 90.0 | 90.5 | 90.4 | 64 s |
| `2gpu-16-tensor` | first | 137.4 | 138.1 | 144.8 | 42 s |
| | rerun | 138.7 | 132.6 | 138.2 | 42 s |
| `2gpu-34` | first | 121.7 | 123.5 | 123.3 | 47 s |
| | rerun | 122.3 | 123.6 | 124.3 | 47 s |
| `1gpu-34` | first | 123.1 | 123.7 | 123.7 | 47 s |
| | rerun | 123.9 | 124.3 | 124.5 | 47 s |
| `1gpu-40` | first | 105.6 | 106.4 | 106.9 | 54 s |
| | rerun | 105.8 | 106.2 | 107.2 | 55 s |
| `1gpu-48` | first | 91.7 | 92.0 | 92.4 | 63 s |
| | rerun | 91.3 | 92.0 | 91.9 | 63 s |
| `cpu` | first | 31.6 | 32.9 | 31.7 | 183 s |
| | rerun | 31.9 | 35.7 | 34.1 | 170 s |

One prompt class moved by more than its spread: `2gpu-16` code, 89.3 → 90.0 t/s. The
`2gpu-16-tensor` and `cpu` differences lie within their spreads, which reached 12 and
6 t/s.

**Memory:** every pass's per-card VRAM and GTT equalled the first run's; no cell was
flagged for spill. Loads took 9–63 s. After each card load CT 120 was charged 1.7–1.8 GiB,
0.5 GiB of it page cache; after the CPU-only load, 44.2 GiB, 43.5 GiB of it anonymous.

**Output gate:** no degenerate output; all seven template-contract checks passed.

**Thermals:** hottest DIMM 51–54 °C in the GPU cells and 57 °C in `cpu`.

## Deviations

- The three sweeps ran from the host queue (`qwen38-queue`) after the cold-load-modes
  run, with the plan's cells, depths and harness. The CT 123 sweeps ran under the guard
  started for the first context-depth run, from harness `57336e5`; its `thermal-guard.sh`
  is identical to `39babf7`'s.
- From about 03:05 to 06:15 ET, during the context-depth rerun, the Wi-Fi bridge that
  links the server to the house network stopped forwarding until it was power-cycled.
  The host stayed up. The sweep runs on the host and reaches CT 123 over the host's
  bridge, and its 1 s card samples and ~13 s DIMM samples have no gap over that window.
- At the cutover, the queue's start of the CT 120 guard failed: `systemd-run` does not
  resolve a relative executable against `--working-directory`. The queue stopped before
  the configurations rerun, leaving CT 120 idle on both cards with the host's
  `gpu-thermal-watchdog` mapped to it. One minute later a resume script with the queue's
  remaining steps and the guard's absolute path started the guard, then the sweep.
- Harness `39babf7` is on the branch of PR #98, not on `main`.

## Conclusion

- **Every cell** of the three sweeps loaded and passed the output gate, and produced the
  same text as its first run in all 80 prompt cells. VRAM, GTT and free VRAM matched the
  first runs in every pass, including `q8-128k`'s spill. No cell had a DIMM sample at
  66 °C (hottest 51–57 °C), and the guard never tripped.
- **Reproducibility:** decode moved by more than both runs' spread in 5 of 80 prompt
  cells: `q8-128k` at ~5.8k (12.9 → 11.3 t/s), the cache run's control at d8000 code
  (13.5 → 12.2), `48:leave12288` at d0 code (6.0 → 6.2) and `2gpu-16`'s code prompts
  (15.0 → 15.3, 14.9 → 15.1). Prefill moved by more than its spread in five prompt cells,
  by 0.3–1.0%; elsewhere it stayed within the spread.
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
