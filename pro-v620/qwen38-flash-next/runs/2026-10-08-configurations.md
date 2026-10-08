# Qwen3.8-Flash-Next: the standard configurations on eight channels

Plan committed 2026-10-08 · Run 2026-10-08 · Status: done

## Question

On eight memory channels and llama.cpp b11505, what does each standard configuration
deliver: decode by prompt class and depth, prefill at 8k, VRAM and GTT? The 2026-09
answers were measured on four channels and b11018 and have been deleted. Two narrower
questions ride along:

- **One card or two at the same placement?** At `-ncmoe 34` and batch 4096/1024, does
  the two-card decode cost from the QSA indexer's per-token transfers
  (llama.cpp #28699, still an open draft) persist on eight channels?
- **Layer or tensor split on two cards?** `-sm tensor` was re-enabled for qwen4exp in
  llama.cpp #28569. At `-ncmoe 16` and batch 1024/256, does it beat the layer split?

## What answers it

- Every cell loads, shows no GTT spill, and passes the output gate: no degenerate
  output, and its three passes agree per prompt cell (`SUMMARY.md` flags both).
- For each configuration: median decode per prompt class at d0 and d8000, median
  prefill at d8000, VRAM used and free per card, load time.
- **One vs two cards:** `2gpu-34` against `1gpu-34`. A difference counts when it is larger
  than the pass-to-pass spread of both cells.
- **Split mode:** `2gpu-16-tensor` against `2gpu-16`, by the same rule.
- A cell with any DIMM at 66 °C is reported as capped and left out of the comparisons.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| Two GPUs | `2gpu-16` (the shipped two-card config, split `30,18`, 1024/256); `2gpu-16-tensor` (`-sm tensor`, 1024/256); `2gpu-34` (split `39,9`, 4096/1024, matched to `1gpu-34`) |
| One GPU | `1gpu-34` (CT 123's production placement, 4096/1024); `1gpu-40` |
| CPU only | `cpu` (`--device none`, `-ngl 0`, 4096/1024) |
| Optimized | `1gpu-48`: every expert in RAM, leaving about 23 GB of VRAM for a second model |

The cells are in [`2026-10-08-configurations.cells`](2026-10-08-configurations.cells).

## Controls

- `1gpu-34` is the reference: the production placement, also measured as the
  `--moe-cache-mib` record's control on the same build.
- `2gpu-16` is the reference for the split-mode question.
- Cells run round-robin, three passes each, in one container, so every configuration
  sees the same build, stack and time window.

## Method

Harness: `placement-sweep.sh` at the commit that adds this record, staged with
[`push-harness.sh`](../../push-harness.sh). The sweep's method rules are in its header
and in [Benchmark tools](../README.md#benchmark-tools).

```bash
# Host: CT 120 takes both cards (CT 123 stopped first; the cutover stops it anyway)
pct shutdown 123 && pct start 120
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
VMID=120 ./install.sh && ./ct120-cutover.sh to-qwen38fn
# Shell 1
VMID=120 ./thermal-guard.sh
# Shell 2
VMID=120 CELLS=runs/2026-10-08-configurations.cells DEPTHS="0,8000" ./placement-sweep.sh
```

- Sweep defaults: `REPS=3`, `N_PREDICT=256`, prompt classes code, list and prose;
  ctx 65536, parallel 1, 16 threads, q8_0 KV, projector on the CPU.
- Each cell's batch comes from its mode: two cards 1024/256 (the shape the split rule
  was found at), one card and CPU 4096/1024; `2gpu-34` overrides to 4096/1024 to match
  `1gpu-34`.
- One-GPU cells run on `Vulkan0`, `0000:03:00.0`, in a two-card container; the sweep reads
  VRAM from the card each cell loaded onto. CT 123 serves from the other card; the two
  have not been compared on this board.
- Expected duration: about 3–3.5 hours, the CPU-only cell being the slowest.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`.

## Safety

- Every other guest stays shut down: CT 121 `hermes`, CT 140 `kb-rag`, VM 300
  `docker-host`, and CT 123, which must not hold GPU 2 while CT 120 does. CT 200 and
  CT 201 are already stopped. The cutover clears CT 123's `onboot`.
- After the run, `./ct120-cutover.sh to-qwen36` gives GPU 2 back and restores CT 123's
  `onboot`; it also starts CT 120's Qwen3.6 server, so CT 120 is then shut down again for
  the following one-card tests. No guest is restarted without the owner's go-ahead.
- `thermal-guard.sh` runs with `VMID=120` and watches both cards. On a trip it writes
  `/root/qwen38-flash-next/THERMAL_TRIP`; the sweep then starts no further cell.
- The cutover gives CT 120 48 cores and 160 GiB, enough for the CPU-only cell's
  ~104 GiB of weights.
- DIMM airflow stays as in the 2026-10-08 soak; the sweep records the hottest DIMM.
- Keep clear of the Sunday 01:00 backup window.

## Environment

llama.cpp b11505 (`ff5888f99`, release tarball), Mesa 26.2.4 (kisak-mesa), kernel
`7.0.14-22-pve`, pve-firmware 3.18-7, `schedutil`, 8 × 64 GB DDR4-3200, both V620s at
0 mV and 250 W on PCIe 4.0 x16, CT 120 with 48 cores and 160 GiB. Harness `15d61d6`.
`environment.json` as captured at the start of the run, with the pre-flight `2gpu-16`
server still loaded:

<details>
<summary>environment.json</summary>

```json
{
 "captured_at": "2026-10-08T20:24:14Z",
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
   "devices": "Vulkan0: AMD Radeon Pro V620 (RADV NAVI21) (30704 MiB, 5365 MiB free)\n  Vulkan1: AMD Radeon Pro V620 (RADV NAVI21) (30704 MiB, 2651 MiB free)"
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

Raw data: `/root/qwen38-flash-next/sweep-20261008T202409Z/`. Twenty-one cells, three
round-robin passes of seven configurations, 2 h 21 min. d0 prompts were 21–31 tokens;
d8000 prompts were 5,783–5,793 tokens.

**Decode**, median of three passes, t/s:

| Cell | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `2gpu-16` | 15.0 | 15.3 | 15.3 | 14.9 | 15.0 | 15.0 |
| `2gpu-16-tensor` | 8.5 | 8.6 | 8.6 | 8.4 | 8.3 | 8.3 |
| `2gpu-34` | 11.5 | 11.7 | 11.6 | 11.3 | 11.2 | 11.2 |
| `1gpu-34` | 14.1 | 14.3 | 15.0 | 14.2 | 14.6 | 14.1 |
| `1gpu-40` | 12.9 | 13.0 | 12.7 | 12.8 | 12.7 | 12.7 |
| `1gpu-48` | 11.4 | 11.2 | 11.4 | 10.8 | 10.7 | 10.7 |
| `cpu` | 9.1 | 8.7 | 8.5 | 7.8 | 8.0 | 7.7 |

The largest pass-to-pass spread within one prompt cell was 0.18–0.25 t/s for the
two-card cells, 0.47 for `1gpu-48`, 0.83 for `1gpu-34` and `cpu`, and 1.28 for `1gpu-40`
(d8000 list, 12.31–13.59).

**Prefill at d8000**, median per prompt class, t/s, and the time to first token for a
~5,790-token prompt at the median of the three classes:

| Cell | code | list | prose | Time to first token |
| --- | ---: | ---: | ---: | ---: |
| `2gpu-16` | 89.3 | 90.1 | 90.5 | 64 s |
| `2gpu-16-tensor` | 137.4 | 138.1 | 144.8 | 42 s |
| `2gpu-34` | 121.7 | 123.5 | 123.3 | 47 s |
| `1gpu-34` | 123.1 | 123.7 | 123.7 | 47 s |
| `1gpu-40` | 105.6 | 106.4 | 106.9 | 54 s |
| `1gpu-48` | 91.7 | 92.0 | 92.4 | 63 s |
| `cpu` | 31.6 | 32.9 | 31.7 | 183 s |

`SUMMARY.md`'s prefill column pools the nine values of a cell instead, which reads 139.9
for `2gpu-16-tensor` and 32.7 for `cpu`.

**Memory and load**, identical in all three passes:

| Cell | VRAM used, MiB | VRAM free, MiB | GTT on the first card, before → after probe | Load |
| --- | --- | --- | --- | ---: |
| `2gpu-16` | 27,822 + 28,685 | 2,882 + 2,019 | 69 → 97 MiB | 25 s |
| `2gpu-16-tensor` | 28,231 + 28,081 | 2,473 + 2,623 | 112 → 115 MiB | 35 s |
| `2gpu-34` | 14,625 + 14,703 | 16,079 + 16,001 | 226 → 300 MiB | 15 s |
| `1gpu-34` | 28,627 | 2,077 | 226 → 263 MiB | 15 s |
| `1gpu-40` | 19,621 | 11,083 | 226 → 264 MiB | 15 s |
| `1gpu-48` | 7,114 | 23,590 | 226 → 264 MiB | 10 s |
| `cpu` | 16 + 16 | 30,688 + 30,688 | 14 → 14 MiB | 55 s |

One-card rows are the card the cell loaded onto, `0000:03:00.0`; the other card held
16 MiB. The second card's GTT stayed at 14–18 MiB. No cell was flagged for spill.

**Output gate:** no degenerate output, and every cell produced identical text in all
three passes of every prompt. `2gpu-34`'s text matched `1gpu-34`'s in all six prompt
cells; `1gpu-40` differed from `1gpu-34` in three, `2gpu-16` and `1gpu-48` in five, and
`2gpu-16-tensor` and `cpu` in all six. All seven template-contract checks passed, with no
`<think>` in content.

**Thermals:** hottest DIMM 50–53 °C in the GPU cells and 57 °C in `cpu`; no sample at
66 °C. A separate watcher polled the DIMMs every 10 s from the end of the first pass and
never read 62 °C. No thermal-guard trip.

`1gpu-34` ran here in CT 120 on `0000:03:00.0` with 48 cores; the `--moe-cache-mib`
record's control, the same placement in CT 123 on `0000:83:00.0` with 24 cores, measured
12.7–13.7 t/s on the same build. This run does not separate the container, card and core
count.

## Deviations

- The guard and the sweep ran as systemd transient units (`qwen38-thermal-guard`,
  `qwen38-configurations-sweep`) instead of two interactive shells, with the plan's
  scripts and arguments.
- Before the run, `2gpu-16-tensor`, `2gpu-34` and `cpu` were each loaded once by hand to
  check that they fit and answer. None of that data is used.
- About five minutes into `2gpu-16`'s first pass, a validation test of the next harness
  version reached `capture-env.sh` against CT 120 for under 5 s before a timeout killed
  it. That script runs `llama-server --version`, `--list-devices` and `vulkaninfo` in the
  container; the test did not touch the server or its env file. That pass's decode,
  14.82–15.44 t/s, lies within the other two passes' range.
- Harness `15d61d6` is on the branch of PR #98, not on `main`.

## Conclusion

- **Every cell** loaded, showed no spill and passed the output gate. No cell was
  DIMM-capped.
- **One card or two at `-ncmoe 34`, batch 4096/1024:** two cards decoded slower in every
  prompt cell, by 18–23% (11.2–11.7 against 14.1–15.0 t/s), more than either cell's
  spread. Prefill was equal within the spread for list and prose prompts and 1.1% lower
  for code (121.7 against 123.1 t/s). Both produced identical text. The two-card decode
  cost persists on eight channels.
- **Layer or tensor split at `-ncmoe 16`, batch 1024/256:** `-sm tensor` decoded 43–44%
  slower in every prompt cell (8.3–8.6 against 14.9–15.3 t/s) and prefilled 53–60% faster
  (137–145 against 89–91 t/s), each by more than either cell's spread. It loaded in 35 s
  against 25 s, with the same total VRAM within 0.2 GiB.
- **The standard configurations,** by median decode: `2gpu-16` (14.9–15.3 t/s, 4.8 GiB
  free across both cards) ahead of `1gpu-34` (14.1–15.0, the other card free) in five of
  six prompt cells by more than the spread, then `1gpu-40` (12.7–13.0), `2gpu-34`,
  `1gpu-48` (10.7–11.4, 23.0 GiB free on its card) and `cpu` (7.7–9.1). Prefill
  at d8000 is highest for `2gpu-16-tensor` (138 t/s), then the two `-ncmoe 34` cells
  (123), and lowest for `cpu` (32, 183 s to the first token of a ~5.8k-token prompt).
