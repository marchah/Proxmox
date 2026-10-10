# Qwen3.8-Flash-Next: cold load modes on one card

Plan committed 2026-10-08 · Run 2026-10-09 · Status: done

## Question

llama.cpp b11505's `--load-mode` offers `auto` (mmap), `none`, `dio` (direct I/O),
`mlock` and `mmap+mlock`. Loading cold from the NVMe store at CT 123's production
placement (`-ncmoe 34`, one V620):

- How long does each mode take to reach a healthy `/health`?
- How is the model charged to CT 123's 120 GiB memory limit: anonymous memory or page
  cache?
- Do decode and prefill change after the load?

The 2026-09 study's governor trial is not repeated: `cpu-governor.service` sets
`schedutil`, `capture-env.sh` records it in every run, and the `powersave` result was a
1500 MHz pin rather than a tuning choice.

## What answers it

- Every cell loads, shows no GTT spill and passes the output gate (`SUMMARY.md` flags
  degenerate output and passes that disagree).
- **Load time:** median seconds to a healthy `/health` per mode. A difference counts
  when it is larger than the pass-to-pass spread of both cells.
- **Memory:** the container's total, anonymous and page-cache memory after the load.
- **Speed:** median decode per prompt class at d0 and d8000, and prefill at d8000,
  against `auto`, by the same rule. d0 is the first request after each load.
- **Utilization:** per phase, the card's power, clocks and busy %, and the CPU cores in
  use (`SUMMARY.md`'s Utilization table), to show what limits each cell.
- A cell with any DIMM at 66 °C is reported as capped and left out of the comparisons.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| One GPU | `auto` (production), `none`, `dio`, each loaded cold at the production placement |

The cells are in [`2026-10-08-load-modes.cells`](2026-10-08-load-modes.cells).

- **Two GPUs, CPU only and optimized:** left out. Every configuration reads the same four
  shards; only the split between VRAM and RAM differs, so one configuration answers the
  question.
- **`mlock` and `mmap+mlock`:** left out. The unit runs with systemd's default 8 MiB
  `LimitMEMLOCK`, so both would fall back to unlocked memory without a unit change, and
  the container's own limit is about 63 GiB. Locking matters under memory pressure,
  which a run with every other guest shut down cannot create.

## Controls

- `auto` is CT 123's production load mode and the reference.
- Cells run round-robin, three passes each, in one container.

## Method

Harness: `placement-sweep.sh` at the branch head when the run starts (its commit is in
the run's `manifest.json`), staged with [`push-harness.sh`](../../push-harness.sh). The
sweep's method rules are in its header and in [Benchmark
tools](../README.md#benchmark-tools).

```bash
# Host; CT 123 holds 0000:83:00.0
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
# Shell 1
VMID=123 ./thermal-guard.sh
# Shell 2
VMID=123 CELLS=runs/2026-10-08-load-modes.cells DEPTHS="0,8000" DROP_CACHES=true \
  ./placement-sweep.sh
```

- `DROP_CACHES=true`: before every load the sweep stops the server and drops the host
  page cache, so each load reads the 111 GB from the NVMe store (`BIWIN NV7400 2TB`,
  ext4 on LVM). With the cache dropped, CT 123 is the first reader, so the page cache is
  charged to it.
- Load time is wall-clock from the service restart to the first healthy `/health`, polled
  every second.
- Sweep defaults: `REPS=3`, `N_PREDICT=256`, prompt classes code, list and prose (d8000 is
  ~5.8k tokens); ctx 65536, parallel 1, 16 threads, q8_0 KV, batch 4096/1024, projector
  on the CPU.
- Expected duration: about 1 hour.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`.

## Safety

- The sweep starts no cell while the hottest DIMM is above 58 °C (`DIMM_START_MAX_C`),
  so one cell's heat does not carry into the next. A cell with any DIMM sample at
  66 °C ran at a third of the memory bandwidth and is invalid.
- Every other guest stays shut down: CT 120 `llamacpp`, CT 121 `hermes`, CT 140 `kb-rag`,
  VM 300 `docker-host`, CT 200 and CT 201. Dropping the page cache is host-wide, so this
  run needs them off. Starting them again waits for the owner's go-ahead.
- `none` and `dio` copy the CPU-resident weights into anonymous memory: about 80 GB at
  `-ncmoe 34` (111 GB of shards less ~28 GB on the card), within CT 123's 120 GiB. A load the container cannot hold is recorded
  as a failed cell.
- `thermal-guard.sh` runs with `VMID=123`; on a trip the sweep starts no further cell.
- Keep clear of the Sunday 01:00 backup window.

## Environment

llama.cpp b11505 (`ff5888f99`, release tarball), Mesa 26.2.4 (kisak-mesa), kernel
`7.0.14-22-pve`, pve-firmware 3.18-7, `schedutil`, 8 × 64 GB DDR4-3200, the V620 at
`0000:83:00.0` (`unique_id` `99b104541144b36c`) at 0 mV and 250 W on PCIe 4.0 x16, CT 123
with 24 cores and 120 GiB. Harness `39babf7`. `environment.json` as captured at the start
of the run:

<details>
<summary>environment.json</summary>

```json
{
 "captured_at": "2026-10-09T06:18:36Z",
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

---

## Results

Raw data: `/root/qwen38-flash-next/sweep-20261009T061832Z/`. Nine cells, three
round-robin passes of three load modes, 43 min, every load cold: the sweep dropped the
host page cache before each, leaving 169–229 MiB cached. d8000 prompts were 5,783–5,793
tokens.

**Load and memory**, identical within 1 s and 0.2 GiB across passes:

| Mode | Cold load to `/health` | GTT after load | Container memory after load: total (anonymous / page cache and pinned) |
| --- | ---: | ---: | --- |
| `auto` | 33–34 s | 226 MiB | 62.5 GiB (1.1 / 61.2) |
| `none` | 69–70 s | 52,821 MiB | 79.7 GiB (1.7 / 77.9) |
| `dio` | 64 s | 52,821 MiB | 79.2 GiB (1.1 / 77.9) |

VRAM use was the same in every mode: 28,627–28,628 MiB, 2,076–2,077 MiB free.

**Prefill at d8000**, median of three passes (range), t/s:

| Mode | code | list | prose | Time to first token, ~5.8k tokens |
| --- | ---: | ---: | ---: | ---: |
| `auto` | 119.7 (119.3–120.3) | 122.8 (122.7–124.0) | 123.3 (123.0–123.6) | 47 s |
| `none` | 393.8 (388.3–395.0) | 396.3 (396.0–397.1) | 396.7 (395.7–397.4) | 15 s |
| `dio` | 391.1 (390.0–391.1) | 394.0 (389.6–394.1) | 392.9 (370.0–394.6) | 15 s |

**Decode**, median of three passes, t/s:

| Mode | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `auto` | 11.2 | 13.6 | 12.1 | 13.1 | 11.6 | 13.0 |
| `none` | 12.1 | 12.6 | 12.4 | 13.0 | 12.0 | 12.7 |
| `dio` | 13.0 | 13.6 | 13.3 | 13.3 | 13.5 | 12.3 |

Pass-to-pass spread within a prompt cell reached 3.5 t/s.

**Output gate:** no degenerate output; every cell produced identical text in all three
passes of every prompt, and `none` and `dio` produced the same text as `auto` in all six
prompt cells. All seven template-contract checks passed.

**Spill check:** the sweep flagged `none` and `dio` in every pass, because GTT exceeded
1.5 GiB. That GTT held the CPU-resident weights: 52,821 MiB at load against the 51,950
MiB of host experts the [utilization record](2026-10-08-utilization.md)'s cache sweep logged at this placement, and it grew
5 MiB during the probe while VRAM use matched `auto`. The sweep now exempts these two
modes from the static GTT threshold and keeps the growth check.

**Thermals:** hottest DIMM 54 °C; no sample at 66 °C. No thermal-guard trip.

**Utilization**, median of 1 s samples across passes:

| Mode | Phase | Card power | sclk | GPU busy % | VRAM busy % | Highest junction | CPU cores in use |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `auto` | prefill | 60 W | 540 MHz | 54 | 4 | 67 °C | 0.9 |
| `auto` | decode | 60 W | 608 MHz | 59 | 28 | 53 °C | 13.4 |
| `none` | prefill | 162 W | 2,360 MHz | 98 | 25 | 74 °C | 0.5 |
| `none` | decode | 61 W | 592 MHz | 60 | 29 | 58 °C | 13.4 |
| `dio` | prefill | 160 W | 2,359 MHz | 98 | 26 | 74 °C | 0.5 |
| `dio` | decode | 61 W | 621 MHz | 60 | 31 | 58 °C | 13.4 |

## Deviations

- The sweep ran from the host queue (`qwen38-queue`) right after the threads run, under
  the thermal guard started for the context-depth run (`VMID=123`), with the plan's cells,
  depths and harness. Its log went to `load-modes-sweep.log`.
- Harness `39babf7` is on the branch of PR #98, not on `main`; it adds the per-phase
  utilization sampling the plan names.

## Conclusion

- **Every cell** loaded and passed the output gate; `none` and `dio` produced the same
  text as `auto`. The spill flags on `none` and `dio` were the static GTT threshold
  reading the pinned weights, not spill. No cell was DIMM-capped.
- **Load time:** a cold `auto` load reached `/health` in 33–34 s, `dio` in 64 s and `none`
  in 69–70 s.
- **Memory:** `auto` left the weights in page cache, 62.5 GiB charged to CT 123.
  `none` and `dio` held them in pinned host memory that RADV counts as GTT, 52.8 GB of
  it, with 79.2–79.7 GiB charged to the container.
- **Speed:** `none` and `dio` prefilled 3.2–3.3 times as fast as `auto` at ~5.8k tokens
  (391–397 against 120–123 t/s), each prompt class by far more than the spread: about
  15 s to the first token against 47 s. In prefill the card ran at 98% busy, 160 W and
  2.36 GHz, against 60 W and 540 MHz under `auto`. Decode differed from `auto` by less
  than the spread in every prompt cell.
