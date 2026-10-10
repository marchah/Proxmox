# Qwen3.8-Flash-Next: `dio` and the MTP head together on one card

Plan committed 2026-10-10 · Run 2026-10-10 · Status: done

## Question

Two changes ran faster than CT 123's deployed configuration on `0000:83:00.0`, each
measured alone against it:

- `--load-mode dio` prefilled 3.2–3.3 times as fast at `-ncmoe 34`, with the same decode
  and text ([load-modes record](2026-10-08-load-modes.md)).
- The Q4_K_M MTP head at `--spec-draft-n-max 3`, at `-ncmoe 36` under `auto`, raised
  single-stream decode by 40% (median of six, 14.2 to 19.9 t/s) and lowered prefill by
  6–10%, in CT 120 with two slots ([MTP record](2026-10-09-mtp.md)).

`make bench GPU=2` is the usage test and runs the best configuration found
([TEST-RECORDS.md](../../TEST-RECORDS.md)). Together, in CT 123 at its one slot:

- Does the pair load, fit and pass the output gate?
- Does `dio` keep its prefill gain with the head, and the head its decode gain with `dio`?
- Which configuration does the next `make bench GPU=2` run?

## What answers it

- **Gates,** per cell: it loads; shows no GTT growth during the probe (`dio` holds the
  CPU-resident weights in GTT, which the sweep exempts from its static threshold); keeps
  at least 1 GiB of VRAM free on `83:00.0` after the d8000 request; passes the output
  gate (`SUMMARY.md` flags degenerate output and the template-contract checks); has no
  DIMM sample at 66 °C; and does not trip the thermal guard.
- **Speed:** median decode per prompt class at d0 and d8000 and their median of six, and
  prefill per class at d8000. A difference counts when it is larger than the
  pass-to-pass spread of both cells.
- **Also reported:** draft acceptance, load time, VRAM and GTT, the container's memory,
  and per phase the card's power, clocks and busy % and the CPU cores in use.
- **The batch's configuration,** fixed now:
  - `dio-mtp3` if it passes every gate, its median of six is higher than `dio`'s and
    higher beyond the spread in at least four of the six prompt cells, and its d8000
    prefill is within 10% of `dio`'s in every class. 10% is the prefill the head cost
    under `auto`, about where its decode gain repays that loss on the batch's largest
    prompt (48k tokens in, a 640-token note out).
  - Otherwise `dio`, if it passes every gate.
  - If `dio-mtp3` fails a gate, the record says why, and the owner chooses between `dio`
    and the MTP record's `auto` with the head before the batch is planned.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| One GPU | `auto` (deployed: `-ncmoe 34`), `dio` (`-ncmoe 34`), `dio-mtp3` (`-ncmoe 36`, `dio`, Q4_K_M head at n-max 3) |

The cells are in [`2026-10-10-best-config.cells`](2026-10-10-best-config.cells).

- **Two GPUs:** left out. GPU 1 stays with CT 120 for Hermes (owner, 2026-10-10).
- **CPU only and optimized:** left out. The [utilization
  record](2026-10-08-utilization.md) measured both slower than `-ncmoe 34`, and no
  second model shares GPU 2.
- **`none`:** left out. It matched `dio`'s speed within the spread and loaded 6 s slower.
- **`auto` with the head:** left out. The MTP record measured it; it is only needed if
  `dio-mtp3` fails a gate (see above).
- **Speculative decoding:** the Q4_K_M head is the drafter the MTP record chose on one card
  (Q8_0 decoded within 2% and took 985 MiB more VRAM); n-max 3 had its highest median of
  six. That record found no other drafter llama.cpp loads for this model, and left n-gram
  speculation to a workload that edits text already in the context.

## Controls

- `auto` is CT 123's deployed configuration and the reference; it also repeats the
  load-modes record's `auto` cell.
- `dio` is the reference for the head. It runs at `-ncmoe 34`, so `dio-mtp3` against it
  includes the two extra CPU-resident layers the head needs, as a deployment would.
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
VMID=123 CELLS=runs/2026-10-10-best-config.cells DEPTHS="0,8000" DROP_CACHES=true \
  ./placement-sweep.sh
```

- `DROP_CACHES=true`: before every load the sweep stops the server and drops the host
  page cache, as in the load-modes record, so every load is cold and `auto`'s page cache
  is not held beside a `dio` cell's pinned weights.
- Sweep defaults: `REPS=3`, `N_PREDICT=256`, prompt classes code, list and prose (d8000 is
  ~5.8k tokens); ctx 65536, parallel 1, 16 threads, q8_0 KV, batch 4096/1024, projector
  on the CPU. The sweep restores CT 123's env file and service when it ends.
- Expected duration: about 1 hour.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`.

## Safety

- The sweep starts no cell while the hottest DIMM is above 58 °C (`DIMM_START_MAX_C`).
  A cell with any DIMM sample at 66 °C ran at a third of the memory bandwidth and is
  invalid.
- Every other guest stays shut down: CT 120 `llamacpp`, CT 121 `hermes`, CT 140 `kb-rag`,
  VM 300 `docker-host`, CT 200 and CT 201. Dropping the page cache is host-wide, so this
  run needs them off. Starting them again waits for the owner's go-ahead.
- `dio` pins 52.8 GB at `-ncmoe 34`, and CT 123 held 79.2 GiB; at `-ncmoe 36` two more
  layers' experts, about 3 GiB, stay in RAM, within CT 123's 120 GiB. A load the
  container cannot hold is recorded as a failed cell.
- `thermal-guard.sh` runs with `VMID=123`; on a trip the sweep starts no further cell.

## Environment

llama.cpp b11505 (`ff5888f99`, release tarball), Mesa 26.2.4 (kisak-mesa), kernel
`7.0.14-22-pve`, pve-firmware 3.18-7, `schedutil`, 8 × 64 GB DDR4-3200. CT 123 with
24 cores and 120 GiB holding `0000:83:00.0` (`unique_id` `99b104541144b36c`) at 0 mV and
250 W on PCIe 4.0 x16. Harness `38fbdcc`. `environment.json` as captured at the start of
the run, with the deployed server loaded:

<details>
<summary>environment.json</summary>

```json
{
 "captured_at": "2026-10-10T10:58:35Z",
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

Raw data: `/root/qwen38-flash-next/sweep-20261010T105830Z/`. Nine cells, three
round-robin passes of three configurations, 40 min, every load cold. d0 prompts were
21–31 tokens and d8000 prompts 5,783–5,793. Every cell loaded onto `0000:83:00.0`.

**Decode**, median of three passes (range), t/s:

| Cell | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose | Median of six |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `auto` | 11.1 (9.9–11.2) | 12.3 (12.1–13.7) | 13.2 (12.5–13.2) | 13.2 (13.0–13.4) | 13.3 (13.3–13.3) | 13.1 (11.8–13.8) | 13.1 |
| `dio` | 13.8 (13.7–14.2) | 13.8 (12.6–13.8) | 14.1 (13.6–14.2) | 13.6 (13.2–13.7) | 13.4 (13.4–13.8) | 12.8 (12.4–13.4) | 13.7 |
| `dio-mtp3` | 19.4 (18.1–20.0) | 16.5 (16.4–16.7) | 19.6 (19.2–19.7) | 20.9 (20.3–21.0) | 16.3 (16.0–16.3) | 17.4 (16.4–17.5) | 18.4 |

- `dio-mtp3` decoded faster than `dio` in all six prompt cells beyond both cells'
  spread, by 19–54% (median of six +34%), and faster than `auto` by 22–75%.
- `dio` against `auto`: faster beyond the spread at d0 code (+25%) and d0 prose (+7%),
  within the spread in the other four cells.
- Draft acceptance of `dio-mtp3`, median per prompt cell: 69.4%, 51.9% and 67.5% at d0
  (code, list, prose), 76.3%, 52.7% and 58.1% at d8000. The list prompts accepted least
  and gained least.

**Prefill at d8000**, median per prompt class (range), t/s, and the time to first token
for a ~5,790-token prompt at the median of the three classes:

| Cell | code | list | prose | Time to first token |
| --- | ---: | ---: | ---: | ---: |
| `auto` | 119.2 (117.9–119.2) | 122.8 (121.8–123.2) | 123.5 (123.4–123.6) | 47 s |
| `dio` | 393.2 (393.1–393.5) | 393.6 (389.2–394.4) | 394.5 (393.8–394.9) | 15 s |
| `dio-mtp3` | 351.6 (350.1–352.6) | 364.3 (343.5–364.3) | 364.7 (352.7–365.6) | 16 s |

- `dio` prefilled 3.2–3.3 times as fast as `auto` in every class.
- `dio-mtp3` prefilled 10.6% (code), 7.4% (list) and 7.6% (prose) slower than `dio`,
  each beyond both cells' spread.

**Memory and load**, identical in all three passes except where a range is given:

| Cell | VRAM used / free at load, MiB | VRAM free after probe | GTT, load → after probe | CT 123 memory after load: total (anonymous / page cache and pinned) | Cold load |
| --- | --- | ---: | --- | --- | ---: |
| `auto` | 28,627 / 2,077 | 2,155 MiB | 226 → 263 MiB | 62.5 GiB (1.1 / 61.2) | 33–34 s |
| `dio` | 28,628 / 2,076 | 2,168 MiB | 52,821 → 52,826 MiB | 79.2 GiB (1.1 / 77.9) | 65–66 s |
| `dio-mtp3` | 28,931 / 1,773 | 1,822 MiB | 56,377 → 56,544 MiB | 82.0 GiB (1.2 / 80.5) | 69 s |

No cell was flagged for spill. `dio-mtp3`'s GTT grew 167 MiB during the probe while its
free VRAM rose 49 MiB; the sweep flags growth over 256 MiB. The MTP record's head cells
grew GTT by the same 162–168 MiB under `auto`.

**Utilization**, median of the 1 s samples across the three passes:

| Cell | Phase | Power, W | sclk, MHz | Busy % | VRAM busy % | Max junction, °C | CPU cores |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `auto` | prefill | 59 | 532 | 51 | 4 | 68 | 0.9 |
| | decode | 59 | 607 | 60 | 29 | 52 | 13.3 |
| `dio` | prefill | 159 | 2,364 | 98 | 25 | 73 | 0.5 |
| | decode | 61 | 676 | 61 | 33 | 58 | 13.4 |
| `dio-mtp3` | prefill | 159 | 2,362 | 98 | 26 | 75 | 0.5 |
| | decode | 59 | 502 | 48 | 17 | 58 | 12.8 |

**Output gate:** no degenerate output, and every cell produced identical text in all
three passes of every prompt. `dio`'s text matched `auto`'s in all six prompt cells;
`dio-mtp3`'s differed in all six. All seven template-contract checks passed. Every
request stopped at the 256-token limit.

**Thermals:** hottest DIMM 50–54 °C; no sample at 66 °C. No thermal-guard trip.

## Deviations

- The guard and the sweep ran as systemd transient units (`qwen38-guard-bestcfg`,
  `qwen38-sweep-bestcfg`) instead of two interactive shells, with the plan's scripts and
  arguments.
- The plan's gate "no GTT growth during the probe" was applied as the sweep's growth
  check, which flags growth over 256 MiB: every cell's GTT grew during its probe
  (`auto` 37 MiB, `dio` 5, `dio-mtp3` 167).
- On 2026-10-10, while this ran, the configurations record this plan cites was deleted
  as a duplicate of its rerun; the plan's link now points to the
  [utilization record](2026-10-08-utilization.md), which holds that rerun.

## Conclusion

- **Gates:** all three cells loaded, kept at least 1 GiB of VRAM free after the d8000
  request (`dio-mtp3` 1,822 MiB), passed the sweep's spill check and the output gate,
  and ran with no DIMM sample at 66 °C and no guard trip.
- **Speed:** `dio-mtp3` decoded fastest in every prompt cell (median of six 18.4 t/s
  against 13.7 for `dio` and 13.1 for `auto`) and prefilled 351.6–364.7 t/s at ~5.8k
  tokens, against 393.2–394.5 for `dio` and 119.2–123.5 for `auto`. `dio` kept its
  3.2–3.3× prefill with the head; the head kept a decode gain over `dio` of 19–54% by
  prompt.
- **The batch's configuration, by the plan's rule:** `dio`. `dio-mtp3` passed every
  gate and the decode criterion (beyond the spread in six of six prompt cells), but its
  prefill was more than 10% below `dio`'s in one class: code, by 10.6% (list 7.4%,
  prose 7.6%).
