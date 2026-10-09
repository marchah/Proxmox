# Qwen3.8-Flash-Next: context depth and KV type on one card

Plan committed 2026-10-08 · Run 2026-10-08 · Status: done

## Question

At CT 123's production placement (`-ncmoe 34`, one V620) on eight memory channels and
llama.cpp b11505:

- **Depth:** how do decode and prefill change from an empty context to about 59k tokens?
- **KV type:** what does f16 KV cost against q8_0 at a 65536 context, in VRAM, decode and
  prefill? The env files keep reasoning off with q8_0 and name f16 as the type to use
  before enabling it.
- **128k:** does a 131072 context with q8_0 KV run on the card without spill, and what do
  decode and prefill measure at about 119k tokens?

## What answers it

- Every cell loads, shows no GTT spill (no GTT growth during the probe, at least 1 GiB of
  VRAM free after it) and passes the output gate: no degenerate output, and its three
  passes agree per prompt cell (`SUMMARY.md` flags both).
- **Depth:** median code-prompt decode and prefill at each depth, per cell.
- **KV type:** `f16-64k` against `q8-64k` at each depth, and VRAM used after load. A
  difference counts when it is larger than the pass-to-pass spread of both cells.
- **128k:** `q8-128k` runs if it loads and passes the spill check after its ~119k probe.
  Its decode and prefill at ~119k are reported, and its shallower depths against
  `q8-64k` show what the larger allocation costs, by the same rule.
- A cell with any DIMM at 66 °C is reported as capped and left out of the comparisons.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| One GPU | `q8-64k` (production: q8_0, ctx 65536); `f16-64k`; `q8-128k` (q8_0, ctx 131072) |

The cells are in [`2026-10-08-kv-context.cells`](2026-10-08-kv-context.cells).

- **Two GPUs:** left out. CT 123 holds one card; the configurations record measures the
  two-card shapes.
- **CPU only:** left out. Its attention runs on the CPU, a different depth curve from the
  deployed one; the configurations record measures it at d0 and d8000.
- **Optimized (`-ncmoe 48`):** left out. It frees VRAM for a second model, which a larger
  KV would consume.
- **f16 at 131072:** left out. Its KV, about 3 GiB at 24 KiB per token, is 2.25 GiB more
  than the production cell's, and `-ncmoe 34` leaves about 2 GiB free.

## Controls

- `q8-64k` is CT 123's production configuration and the reference for both comparisons.
- Cells run round-robin, three passes each, in one container.

## Method

Harness: `placement-sweep.sh` at the branch head when the run starts (its commit is in
the run's `manifest.json`), staged with [`push-harness.sh`](../../push-harness.sh). The
sweep's method rules are in its header and in [Benchmark
tools](../README.md#benchmark-tools).

```bash
# Host, after the configurations run has given GPU 2 back to CT 123
pct start 123
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
VMID=123 ENV_FILE=qwen38fn-gpu2.env ./install.sh
# Shell 1
VMID=123 ./thermal-guard.sh
# Shell 2
VMID=123 CELLS=runs/2026-10-08-kv-context.cells DEPTHS="0,8000,44000,82000" \
  PROBE_CLASSES=code ./placement-sweep.sh
```

- Depth targets: the probe's filler tokenizes at about 5.5 characters per token, so a
  target yields ~0.72 as many prompt tokens (d8000 measured 5,787 on 2026-10-08).
  Targets 8000, 44000, 82000 and 165000 give about 5.8k, 31.8k, 59.3k and 119.4k
  tokens; the summary prints the measured sizes. d8000 matches the configurations
  record's depth.
- Code prompts only (`PROBE_CLASSES=code`): each prompt class at depth costs its own full
  prefill, and three classes would triple the run. Decode is quoted for code prompts.
- Sweep defaults: `REPS=3`, `N_PREDICT=256`, parallel 1, 16 threads, batch 4096/1024,
  projector on the CPU.
- Expected duration: about 4 hours, an estimate since prefill at depth has not been
  measured on eight channels: ~18 minutes per pass for each 64k cell, ~45 for the 128k
  cell.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`.

## Safety

- The sweep starts no cell while the hottest DIMM is above 58 °C (`DIMM_START_MAX_C`),
  so one cell's heat does not carry into the next. A cell with any DIMM sample at
  66 °C ran at a third of the memory bandwidth and is invalid.
- Every other guest stays shut down: CT 120 `llamacpp` (shut down again after the
  configurations run's rollback restarts it), CT 121 `hermes`, CT 140 `kb-rag`, VM 300
  `docker-host`, CT 200 and CT 201. Starting them again waits for the owner's go-ahead.
- `thermal-guard.sh` runs with `VMID=123`. The deepest prefills hold the card and the CPU
  under load for tens of minutes. On a trip it writes
  `/root/qwen38-flash-next/THERMAL_TRIP`; the sweep then starts no further cell.
- Those prefills also stream the CPU-side experts from RAM throughout; the sweep records
  the hottest DIMM, and a capped cell is left out.
- Keep clear of the Sunday 01:00 backup window.

## Environment

llama.cpp b11505 (`ff5888f99`, release tarball), Mesa 26.2.4 (kisak-mesa), kernel
`7.0.14-22-pve`, pve-firmware 3.18-7, `schedutil`, 8 × 64 GB DDR4-3200, the V620 at
`0000:83:00.0` at 0 mV and 250 W on PCIe 4.0 x16, CT 123 with 24 cores and 120 GiB.
Harness `57336e5`. `environment.json` as captured at the start of the run:

<details>
<summary>environment.json</summary>

```json
{
 "captured_at": "2026-10-08T22:50:34Z",
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
   "devices": "Vulkan0: AMD Radeon Pro V620 (RADV NAVI21) (30704 MiB, 2076 MiB free)"
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

Raw data: `/root/qwen38-flash-next/sweep-20261008T225030Z/`. Nine cells, three
round-robin passes of three configurations, 3 h 32 min. Code prompts measured 31, 5,793,
31,808, 59,285 and 119,270 tokens at the targets 0, 8000, 44000, 82000 and 165000.

**Decode**, code prompts, median of three passes (range), t/s:

| Cell | d0 | ~5.8k | ~31.8k | ~59.3k | ~119.3k |
| --- | ---: | ---: | ---: | ---: | ---: |
| `q8-64k` | 13.5 (11.5–13.7) | 12.1 (12.1–12.7) | 12.9 (11.5–13.2) | 12.6 (11.3–12.9) | — |
| `f16-64k` | 12.7 (11.4–12.9) | 13.3 (11.9–14.0) | 13.4 (13.2–13.4) | 12.1 (10.8–13.0) | — |
| `q8-128k` | 13.8 (13.6–14.0) | 12.9 (12.6–13.5) | 13.3 (10.6–13.8) | 11.4 (9.9–13.1) | 11.9 (11.3–12.7) |

Within one prompt cell, decode varied by up to 3.3 t/s between passes; no pass was
consistently low.

**Prefill**, code prompts, median of three passes (range), t/s:

| Cell | ~5.8k | ~31.8k | ~59.3k | ~119.3k |
| --- | ---: | ---: | ---: | ---: |
| `q8-64k` | 121.7 (121.6–122.7) | 123.2 (123.1–123.5) | 120.6 (120.5–121.0) | — |
| `f16-64k` | 117.4 (115.5–117.9) | 119.8 (119.7–120.3) | 110.8 (110.7–111.0) | — |
| `q8-128k` | 104.2 (103.8–105.0) | 111.7 (111.3–112.0) | 97.8 (95.1–102.5) | 95.4 (89.1–95.9) |

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

**Output gate:** no degenerate output, and every cell produced identical text in all
three passes of every prompt. All seven template-contract checks passed, with no
`<think>` in content.

**Thermals:** hottest DIMM 53–57 °C; no sample at 66 °C. A watcher polling every 10 s
never read 62 °C. No thermal-guard trip.

**Utilization**, from a read-only monitor added during the run (see Deviations): every
request of the third pass and the last of the second, all three cells pooled.

| Phase | Seconds sampled | Mean power | Seconds at ≥ 200 W | Seconds with sclk ≥ 2 GHz | Median busy % | Median VRAM busy % | CPU cores in use |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Prefill | 3,585 | 80 W | 3% | 22% | 51–62 | 4 | 0.8–0.9 |
| Decode | 248 | 60 W | 0% | 0% | 61–62 | 30–34 | 13.3–13.4 |

The card averaged about a third of its 250 W cap in prefill, reaching the cap only in
short bursts, and a quarter in decode. Busy % read 51–62 at those powers. In decode the
container kept about 13 cores busy, near its 16 threads; in prefill, under one.

## Deviations

- The guard and the sweep ran as systemd transient units (`qwen38-thermal-guard`,
  `qwen38-kv-context-sweep`) instead of two interactive shells, with the plan's scripts
  and arguments; the sweep's log went to `kv-context-sweep.log`.
- Utilization was not in the plan or the harness. From the last cell of the second pass,
  a host-side monitor read the card's sysfs counters, CT 123's CPU counter and the
  probe's row files once a second, changing nothing. Each request's phases were placed
  from the time its row appeared (±1 s) and its own wall, prefill and decode figures. A
  one-minute manual sample of the same counters was taken during `q8-128k`'s second
  pass.
- Harness `57336e5` is on the branch of PR #98, not on `main`.

## Conclusion

- **Every cell** loaded and passed the output gate. `q8-64k` and `f16-64k` showed no
  spill. No cell was DIMM-capped.
- **Depth:** at the production settings, prefill held at 120.6–123.2 t/s from ~5.8k to
  ~59.3k tokens. Decode medians were 12.1–13.5 t/s with no change across depth larger
  than the pass-to-pass spread.
- **KV type:** f16 used 900 MiB more VRAM and prefilled 3.5%, 2.8% and 8.1% slower than
  q8_0 at ~5.8k, ~31.8k and ~59.3k tokens, each by more than both cells' spread. Its
  decode differed from q8_0's by less than the spread at every depth.
- **128k:** it does not run without spill at `-ncmoe 34`. It loaded under 1 GiB free,
  moved allocations to GTT during its probe, and prefilled 14%, 9% and 19% slower than
  `q8-64k` at the shared depths, each by more than the spread. Its decode at those depths
  differed by less than the spread. At ~119k tokens it decoded 11.9 t/s and prefilled
  95.4 t/s, about 21 minutes to the first token.
