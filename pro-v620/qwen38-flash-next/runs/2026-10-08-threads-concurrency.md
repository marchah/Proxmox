# Qwen3.8-Flash-Next: threads and concurrent streams on one card

Plan committed 2026-10-08 · Run 2026-10-09 · Status: done

## Question

At CT 123's production placement (`-ncmoe 34`, one V620) on eight memory channels and
llama.cpp b11505:

- **Threads:** which `--threads` value (8, 16, 24) gives the best decode at one, two and
  four concurrent streams, and does it change prefill? The CPU-side expert FFN is
  memory-bound, and a thread count tuned at one stream can be wrong at another, so
  threads are measured at each slot count.
- **Slots:** what do two and four streams give per user and in total, and what does
  loading two or four slots cost a single user?

## What answers it

- Every cell loads, shows no GTT spill and passes the output gate (`SUMMARY.md` flags
  degenerate output and passes that disagree). The concurrency probe reports no
  degenerate output, no failed request and at least as many slots as streams.
- **Threads at one stream:** median decode per prompt class at d0 and d8000, and median
  prefill at d8000, for `t8-p1`, `t16-p1` and `t24-p1`.
- **Threads under concurrency:** per-stream and aggregate decode at two and four streams
  for each thread count.
- **Slot cost:** single-stream decode at parallel 2 and 4 against parallel 1, at the same
  thread count.
- **Utilization:** per phase, the card's power, clocks and busy %, and the CPU cores in
  use (`SUMMARY.md`'s Utilization table), to show what limits each cell.
- A difference counts when it is larger than the pass-to-pass spread of both cells.
- A cell with any DIMM at 66 °C is reported as capped and left out of the comparisons.

## Configurations

| Standard configuration | Cells |
| --- | --- |
| One GPU | threads 8, 16 and 24 × parallel 1, 2 and 4 at CT 123's production placement (nine cells) |

The cells are in [`2026-10-08-threads-concurrency.cells`](2026-10-08-threads-concurrency.cells).

- **Two GPUs:** left out. Threads and slots act on the CPU side, which is the same with
  either card count at a given `-ncmoe`; CT 123 holds one card.
- **CPU only and optimized (`-ncmoe 48`):** left out. Both move more of the model onto the
  CPU, so their best thread count can differ from this one; each gets its own sweep if
  the configurations record makes it a candidate.
- CT 123 has 24 cores, so 24 threads is its ceiling.

## Controls

- `t16-p1` is CT 123's production configuration and the reference.
- Cells run round-robin, three passes each, in one container. Each cell loads at its own
  `--parallel`, so no concurrency figure comes from a server loaded at a different slot
  count.

## Method

Harness: `placement-sweep.sh` and `concurrency-probe.py` at the branch head when the run
starts (its commit is in the run's `manifest.json`), staged with
[`push-harness.sh`](../../push-harness.sh). The sweep's method rules are in its header
and in [Benchmark tools](../README.md#benchmark-tools).

```bash
# Host; CT 123 holds 0000:83:00.0
cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
# Shell 1
VMID=123 ./thermal-guard.sh
# Shell 2
VMID=123 CELLS=runs/2026-10-08-threads-concurrency.cells DEPTHS="0,8000" ./placement-sweep.sh
```

- Each cell runs the placement probe (one request at a time, all three prompt classes, at
  d0 and d8000, ~5.8k tokens), then, where it sets `STREAMS`, `concurrency-probe.py` with
  that many simultaneous streams at d0, each a different prompt with prompt caching off.
- ctx 65536 is shared by the slots: 32768 per slot at parallel 2, 16384 at parallel 4.
- Sweep defaults: `REPS=3`, `N_PREDICT=256`, q8_0 KV, batch 4096/1024, projector on the
  CPU.
- Expected duration: about 2.5 hours.
- Raw data: `/root/qwen38-flash-next/sweep-<timestamp>/`, with each concurrency run in
  `<cell>-r<pass>.concurrency.json`.

## Safety

- The sweep starts no cell while the hottest DIMM is above 58 °C (`DIMM_START_MAX_C`),
  so one cell's heat does not carry into the next. A cell with any DIMM sample at
  66 °C ran at a third of the memory bandwidth and is invalid.
- Every other guest stays shut down: CT 120 `llamacpp`, CT 121 `hermes`, CT 140 `kb-rag`,
  VM 300 `docker-host`, CT 200 and CT 201. Starting them again waits for the owner's
  go-ahead.
- `thermal-guard.sh` runs with `VMID=123`; on a trip the sweep starts no further cell.
- The sweep records the hottest DIMM per cell; a capped cell is left out.
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
 "captured_at": "2026-10-09T02:23:10Z",
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

Raw data: `/root/qwen38-flash-next/sweep-20261009T022306Z/`. Twenty-seven cells, three
round-robin passes of nine configurations, 3 h 55 min. d0 prompts were 21–31 tokens,
d8000 prompts 5,783–5,793.

**Single-stream decode**, median of three passes, t/s (the placement probe sends one
request at a time, also in the two- and four-slot cells):

| Cell | d0 code | d0 list | d0 prose | d8000 code | d8000 list | d8000 prose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `t8-p1` | 12.4 | 12.5 | 12.7 | 12.1 | 12.9 | 12.6 |
| `t16-p1` | 13.8 | 14.2 | 13.1 | 12.3 | 13.8 | 13.7 |
| `t24-p1` | 3.2 | 2.1 | 2.0 | 6.7 | 2.4 | 3.3 |
| `t8-p2` | 12.2 | 12.8 | 13.1 | 12.2 | 12.0 | 12.4 |
| `t16-p2` | 13.6 | 14.4 | 13.8 | 10.6 | 11.6 | 13.3 |
| `t24-p2` | 3.4 | 3.3 | 2.3 | 2.2 | 1.8 | 2.5 |
| `t8-p4` | 12.3 | 13.0 | 12.5 | 12.9 | 12.4 | 12.7 |
| `t16-p4` | 13.2 | 12.8 | 13.8 | 12.6 | 12.9 | 12.7 |
| `t24-p4` | 2.7 | 1.6 | 2.0 | 2.8 | 2.7 | 2.2 |

Pass-to-pass spread within a prompt cell reached 1.8 t/s at 8 threads, 5.2 at 16 and 5.5
at 24.

**Prefill at d8000**, median per prompt class: 119.5–124.0 t/s in every cell.

**Concurrent streams**, median of three passes (range), t/s:

| Cell | Per stream | Aggregate | Wall aggregate |
| --- | ---: | ---: | ---: |
| `t8-p2` | 8.6 (8.5–8.8) | 17.3 (16.9–17.6) | 16.1 |
| `t16-p2` | 8.7 (6.3–9.1) | 17.4 (12.6–18.1) | 16.4 |
| `t24-p2` | 2.8 (2.3–3.4) | 5.7 (4.6–6.8) | 5.5 |
| `t8-p4` | 5.9 (5.9–6.0) | 23.6 (23.5–23.8) | 20.7 |
| `t16-p4` | 6.8 (6.7–6.8) | 27.0 (26.7–27.0) | 23.4 |
| `t24-p4` | 3.6 (1.9–5.2) | 14.5 (7.7–20.8) | 13.4 |

`t8-p2` and `t24-p2` are over their two passes that completed both streams; see the
output gate.

**Memory:** 28,627 MiB of VRAM used (2,077 MiB free) at one and two slots, 29,501 MiB
(1,203 MiB free) at four. No cell was flagged for spill. Loads took 16–18 s.

**Output gate:** no degenerate output from the placement probe, and every cell produced
identical text in all three passes of every single-stream prompt. The concurrency probe
failed its gate twice, both at two slots: in `t8-p2`'s first pass and `t24-p2`'s second,
the second stream's prompt (22 tokens) returned after one token with empty content while
the first stream completed. That prompt completed all 256 tokens in the other seven
two-stream runs and all nine four-stream runs. Under concurrency the generated text also
varied between passes at temperature 0: up to four distinct outputs per stream across
nine runs. All seven template-contract checks passed.

**Thermals:** hottest DIMM 53–54 °C; no sample at 66 °C. No thermal-guard trip.

**Utilization**, median of 1 s samples across passes:

| Threads | Phase | Card power | sclk | GPU busy % | VRAM busy % | CPU cores in use |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 8 | prefill | 58–60 W | 528–558 MHz | 48–50 | 4 | 0.9 |
| 8 | decode | 57–58 W | 586–616 MHz | 57 | 28–29 | 6.6 |
| 8 | streams | 53 W | 499–505 MHz | 41–49 | 15–21 | 6.5–6.7 |
| 16 | prefill | 59 W | 539–544 MHz | 49–50 | 3–4 | 0.9 |
| 16 | decode | 61–62 W | 677–707 MHz | 61 | 31–33 | 13.4 |
| 16 | streams | 54–57 W | 501 MHz | 46–50 | 18–21 | 13.4–13.5 |
| 24 | prefill | 57–59 W | 547–555 MHz | 49–51 | 4 | 0.9 |
| 24 | decode | 28–29 W | 50–57 MHz | 7–9 | 7–8 | 22.5–22.6 |
| 24 | streams | 29–35 W | 68–499 MHz | 9–21 | 9–16 | 21.2–22.5 |

Ranges span the one-, two- and four-slot cells. The card stayed near a quarter of its
250 W cap in every phase.

## Deviations

- The sweep ran from a host queue (`qwen38-queue`, a systemd transient unit) right after
  the context-depth run, under the thermal guard started for that run (`VMID=123`), with
  the plan's cells, depths and harness. Its log went to `threads-concurrency-sweep.log`.
- Harness `39babf7` is on the branch of PR #98, not on `main`; it adds the per-phase
  utilization sampling the plan names.
- The run took 3 h 55 min against the plan's 2.5 hours: at 24 threads each 256-token
  request took about 100 s.

## Conclusion

- **Every cell** loaded with no spill, and every single-stream request passed the output
  gate. No cell was DIMM-capped. Two of the 18 concurrency runs failed the gate: one
  prompt returned empty at two slots (see Results).
- **Threads at one stream:** 16 threads decoded faster than 8 in all six prompt cells
  (+0.2 to +1.7 t/s), by more than both cells' spread in two of them (d0 code +1.5, d8000
  list +0.9). 24 threads, every CPU of the container, decoded 46–85% slower than 16 in
  every prompt cell (2.0–6.7 against 12.3–14.2 t/s), with the CPU at 22.5 cores and the
  card at 29 W. Prefill was the same within 4.5 t/s at every thread count, with the CPU at
  0.9 cores.
- **Threads under concurrency:** at four streams, 16 threads gave 27.0 t/s aggregate and
  6.8 per stream against 8 threads' 23.6 and 5.9, by more than both cells' spread. At two
  streams, 8 and 16 threads were within the spread (17.3 and 17.4 aggregate). 24 threads
  gave 5.7 and 14.5 aggregate at two and four streams.
- **Slot cost:** at 16 threads, single-stream decode at two and four slots differed from
  one slot by less than the spread in every prompt cell. At 8 threads, one prompt cell of
  six (d8000 list, −0.9 t/s at two slots) exceeded it. Four slots used 874 MiB more VRAM.
- **Utilization:** decode used about one CPU core per thread up to 16 threads while the
  card drew 57–62 W; prefill used under one core at 57–60 W. The card ran near a quarter
  of its power cap throughout.
