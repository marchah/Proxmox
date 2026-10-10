# Qwen3.8-Flash-Next: cold load modes on two cards

Plan committed 2026-10-09 · Run 2026-10-09 · Status: done

## Question

On one card at `-ncmoe 34`, `--load-mode none` and `dio` prefilled 3.2–3.3 times as fast
as `auto` with the same decode
([load-modes record](2026-10-08-load-modes.md)). On two cards at `-ncmoe 16`, the
two-card configuration with the fastest decode, `auto` prefilled 90 t/s against 124
on one card ([utilization record](2026-10-08-utilization.md)). Loading cold, in CT 120
holding both V620s:

- Does `none` change two-card prefill, decode, load time and memory as it does on one
  card?
- Under each load mode, how do two cards at `-ncmoe 16` compare with one card at
  `-ncmoe 34`, in the same container and time window?

## What answers it

- Every cell loads, shows no GTT spill and passes the output gate (`SUMMARY.md` flags
  degenerate output and passes that disagree). The spill flag's static GTT threshold
  does not apply to `none`, whose pinned weights RADV counts as GTT; GTT growth during
  the probe still flags it.
- **Load time:** median seconds to a healthy `/health` per cell. A difference counts
  when it is larger than the pass-to-pass spread of both cells.
- **Memory:** the container's total, anonymous and page-cache memory after the load, and
  each card's VRAM and GTT.
- **Speed:** median decode per prompt class at d0 and d8000, and prefill at d8000, of
  each `none` cell against its `auto` cell, and of the two-card cells against the
  one-card cells under the same mode, by the same rule.
- **Utilization:** per phase, each card's power, clocks and busy %, and the CPU cores in
  use (`SUMMARY.md`'s Utilization table), to show what limits each cell.
- A cell with any DIMM sample at 66 °C is invalid.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| Two GPUs | `2gpu-16-auto` (the two-card configuration in `qwen38fn.env`), `2gpu-16-none` |
| One GPU | `1gpu-34-auto` (CT 123's production placement), `1gpu-34-none`, on `0000:83:00.0` |

The cells are in [`2026-10-09-load-modes-two-cards.cells`](2026-10-09-load-modes-two-cards.cells).

- **The one-card cells** repeat the load-modes record's comparison in this container, so
  the one- and two-card results share a container, card and time window.
- **CPU only:** left out. The load mode decides how the CPU-resident weights are held
  for the cards to read; with no card, there is no transfer to change.
- **Optimized (`-ncmoe 48`) and the other two-card shapes:** left out. The question is
  about the two configurations a deployment would choose between.
- **`dio`:** left out. It matched `none` on one card in load time, memory and speed.

## Controls

- Each `auto` cell is the control for the `none` cell of the same shape.
- Cells run round-robin, three passes each, in one container, every load cold.

## Method

Harness: `placement-sweep.sh` at the branch head when the run starts (its commit is in
the run's `manifest.json`), staged with [`push-harness.sh`](../../push-harness.sh). The
sweep's method rules are in its header and in [Benchmark
tools](../README.md#benchmark-tools). It runs after the
[card comparison](../../runs/2026-10-08-card-ab.md), with CT 120 still holding both cards.

```bash
# Host; CT 120 holds both cards after ct120-cutover.sh to-qwen38fn; CT 123 stopped
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
# Shell 1
VMID=120 ./thermal-guard.sh
# Shell 2
VMID=120 CELLS=runs/2026-10-09-load-modes-two-cards.cells DEPTHS="0,8000" \
  DROP_CACHES=true ./placement-sweep.sh
```

- `DROP_CACHES=true`: before every load the sweep stops the server and drops the host
  page cache, so each load reads the 111 GB from the NVMe store.
- `DEVICE=Vulkan1` is `0000:83:00.0` if the card comparison maps it so; otherwise the
  cells file changes before the run. Each cell's JSON records the card it loaded onto.
- Sweep defaults: `REPS=3`, `N_PREDICT=256`, prompt classes code, list and prose (d8000 is
  ~5.8k tokens); ctx 65536, parallel 1, 16 threads, q8_0 KV, projector on the CPU. Two
  cards use batch 1024/256 and the split rule's `--tensor-split 30,18`; one card uses
  4096/1024.
- Expected duration: about 1.25 hours.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`.

## Safety

- Every other guest stays shut down: CT 121 `hermes`, CT 123 `gpu2` (it must stay stopped
  while CT 120 holds its card), CT 140 `kb-rag`, VM 300 `docker-host`, CT 200 and CT 201.
  Dropping the page cache is host-wide, so this run needs them off. Starting them again
  waits for the owner's go-ahead.
- On one card, `none` held the CPU-resident weights in 52.8 GB of pinned host memory and
  CT 123 was charged 79.7 GiB. Two cards at `-ncmoe 16` keep fewer weights on the host.
  Both fit CT 120's 160 GiB.
- The sweep starts no cell while the hottest DIMM is above 58 °C.
- `thermal-guard.sh` runs with `VMID=120` and watches both cards; on a trip the sweep
  starts no further cell.
- Keep clear of the Sunday 01:00 backup window.

## Environment

llama.cpp b11505 (`ff5888f99`, release tarball), Mesa 26.2.4 (kisak-mesa), kernel
`7.0.14-22-pve`, pve-firmware 3.18-7, `schedutil`, 8 × 64 GB DDR4-3200. CT 120 with
48 cores and 160 GiB holding both V620s on PCIe 4.0 x16, each at 0 mV and 250 W:
`0000:03:00.0` (`unique_id` `150e6a6800f84ebe`) and `0000:83:00.0` (`99b104541144b36c`).
Harness `973da4f`. The capture matches the [card comparison](../../runs/2026-10-08-card-ab.md)'s
Flash-Next capture, 41 minutes earlier, apart from the time and the free VRAM.

<details>
<summary>environment.json</summary>

```json
{
 "captured_at": "2026-10-09T15:09:56Z",
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
   "devices": "Vulkan0: AMD Radeon Pro V620 (RADV NAVI21) (30704 MiB, 30686 MiB free)\n  Vulkan1: AMD Radeon Pro V620 (RADV NAVI21) (30704 MiB, 30686 MiB free)"
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

Raw data: `/root/qwen38-flash-next/sweep-20261009T150952Z/`, harness `973da4f`. Twelve
loads, three round-robin passes of four cells, 1 h 6 min. Every load was cold: the sweep
dropped the host page cache before each, leaving 168–187 MiB cached. d8000 prompts
measured 5,787 tokens (median). The one-card cells loaded onto `0000:83:00.0` in every
pass.

**Load and memory**, the same within 2 s and 0.1 GiB across passes:

| Cell | Cold load to `/health` | VRAM used, `03:00.0` / `83:00.0` | GTT after load, `03:00.0` / `83:00.0` | Container memory: total (anonymous / page cache and pinned) |
| --- | ---: | ---: | ---: | --- |
| `2gpu-16-auto` | 44–46 s | 27,822 / 28,685 MiB | 69 / 15 MiB | 62.5 GiB (1.1 / 61.2) |
| `2gpu-16-none` | 67–69 s | 27,823 / 28,689 MiB | 25,413 / 15 MiB | 79.7 GiB (1.7 / 77.9) |
| `1gpu-34-auto` | 33–35 s | 16 / 28,627 MiB | 226 / 15 MiB | 62.5 GiB (1.1 / 61.2) |
| `1gpu-34-none` | 77 s | 16 / 28,628 MiB | 52,821 / 15 MiB | 79.7 GiB (1.7 / 77.9) |

Under `none`, the GTT that held the CPU-resident weights was charged to `03:00.0`
(`Vulkan0`) in both shapes, including the one-card cell whose model ran on `83:00.0`. It
grew at most 10 MiB during the probe; the other GTT readings rose at most 36 MiB. No cell
was flagged for spill.

**Prefill** at d8000, median of three passes (range), t/s:

| Cell | code | list | prose |
| --- | ---: | ---: | ---: |
| `2gpu-16-auto` | 87.1 (87.1–87.6) | 90.3 (89.9–90.4) | 90.2 (89.8–90.3) |
| `2gpu-16-none` | 276.3 (276.2–276.3) | 276.6 (276.2–276.8) | 276.7 (276.6–276.9) |
| `1gpu-34-auto` | 118.7 (118.5–119.5) | 123.1 (122.5–123.6) | 121.8 (121.4–123.3) |
| `1gpu-34-none` | 119.5 (118.8–119.6) | 120.5 (119.7–121.1) | 120.5 (119.7–121.0) |

- **Two cards:** `none` prefilled 3.06–3.17 times as fast as `auto` in all three
  prompts, beyond the spread.
- **One card:** `none` matched `auto` within the spread for code and prose, and was 2.1%
  slower for list, beyond the spread. In the [load-modes record](2026-10-08-load-modes.md),
  in CT 123 where `83:00.0` is the only device, `none` prefilled 394–397 t/s at this
  placement.

**Decode**, median of three passes (range), t/s:

| Cell | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `2gpu-16-auto` | 12.7 (12.6–12.9) | 15.0 (15.0–15.2) | 14.7 (14.6–14.8) | 14.8 (14.8–14.8) | 14.9 (14.6–14.9) | 14.8 (14.8–15.0) |
| `2gpu-16-none` | 15.3 (15.3–15.4) | 15.4 (15.2–15.4) | 15.2 (15.2–15.4) | 14.9 (14.9–14.9) | 15.0 (14.9–15.0) | 15.0 (14.9–15.1) |
| `1gpu-34-auto` | 11.3 (11.2–11.4) | 13.8 (13.7–14.0) | 13.3 (13.2–13.6) | 13.2 (13.0–13.6) | 13.3 (13.2–13.5) | 13.3 (13.2–13.5) |
| `1gpu-34-none` | 14.3 (14.0–14.5) | 14.3 (14.0–14.6) | 14.7 (14.0–14.8) | 13.5 (13.2–13.7) | 13.4 (13.2–13.5) | 13.4 (13.0–13.8) |

- **d0 code**, the first request after each load: `none` decoded faster than `auto` by
  2.6 t/s on two cards and 3.0 on one, beyond the spread. `auto`'s d0 code was its
  slowest prompt on both shapes; the load-modes record showed the same at one card
  (11.2 t/s).
- **The other prompts:** `none` was 0.1–1.4 t/s faster. On two cards this was beyond
  the spread at d0 list (+0.4), d0 prose (+0.5) and d8000 code (+0.1, where both spreads
  were under 0.1); on one card at d0 prose (+1.4).
- **Two cards against one**, under each mode: two cards decoded 1.2–1.6 t/s faster
  under `auto` and 0.5–1.6 faster under `none`, beyond the spread in every prompt but
  `none`'s d0 prose. Two cards prefilled 0.73–0.74 times as fast as one under `auto` and
  2.3 times as fast under `none`.

**Utilization**, median of the 1 s samples across the three passes; two-card cells list
`03:00.0` / `83:00.0`:

| Cell | Phase | Power, W | sclk, MHz | Busy % | VRAM busy % | Max junction, °C | CPU cores |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `2gpu-16-auto` | prefill | 50 / 23 | 503 / 0 | 49 / 0 | 4 / 0 | 69 / 63 | 0.9 |
| | decode | 51 / 43 | 513 / 488 | 49 / 18 | 23 / 16 | 53 / 47 | 8.8 |
| `2gpu-16-none` | prefill | 133 / 94 | 2475 / 0 | 97 / 0 | 22 / 0 | 75 / 66 | 0.6 |
| | decode | 52 / 45 | 513 / 200 | 52 / 12 | 24 / 10 | 60 / 50 | 8.8 |
| `1gpu-34-auto` | prefill | 58 | 559 | 50 | 4 | 67 | 0.9 |
| | decode | 59 | 617 | 60 | 30 | 53 | 13.3 |
| `1gpu-34-none` | prefill | 59 | 532 | 51 | 4 | 68 | 0.9 |
| | decode | 61 | 678 | 61 | 34 | 53 | 13.3 |

In prefill under `none`, `03:00.0` ran at 2,475 MHz and 133 W on two cards. On one card,
`83:00.0` stayed at 532 MHz and 59 W, as under `auto`.

**Output gate:**
- Each cell produced the same text in all three passes of every prompt.
- `none` produced the same text as `auto` in all six prompts on both shapes.
- No degenerate output, and all seven template-contract checks passed.

**Thermals:** hottest DIMM 53–54 °C. No thermal-guard trip.

## Deviations

None.

## Conclusion

- **Two cards at `-ncmoe 16`:** `none` prefilled about 3.1 times as fast as `auto`
  (276 against 87–90 t/s at ~5.8k tokens), close to the 3.2–3.3 times measured on one
  card in CT 123. Load took 68 s against 45 s. The container held 79.7 GiB against 62.5 GiB,
  with 25,413 MiB of GTT on `03:00.0`.
- **Decode under `none`:** on two cards it was 15.2–15.4 t/s at d0 and 14.9–15.0 at
  d8000, and its first request after a load was not slower. Under `auto`, the first
  request decoded 12.7 t/s.
- **One card in a container that holds both cards:** `none` on `83:00.0` (`Vulkan1`)
  gave no prefill gain. Its pinned weights were charged to `03:00.0`, and `83:00.0` did
  not rise above 59 W in prefill. This does not apply to CT 123, whose only device is
  `83:00.0` and where `none` prefilled 394–397 t/s.
- **Two cards against one** in this container: two cards decoded faster under both
  modes. Two cards prefilled 27% slower under `auto` and 2.3 times as fast under `none`,
  against a one-card `none` that got no gain here.
