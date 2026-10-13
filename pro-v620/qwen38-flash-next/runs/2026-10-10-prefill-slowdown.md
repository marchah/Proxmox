# Qwen3.8-Flash-Next: the prefill slowdown with `dio` and the MTP head

Plan committed 2026-10-10 · Run 2026-10-10 · Status: done

## Question

In the [batch with `dio` and the MTP head](2026-10-10-bench.md), prefill fell from
137–305 t/s to 61–91 t/s for 70 minutes. Through that stretch GTT held 1,024 MiB more
than usual, and the card's memory clock read 96 MHz in two thirds of prefill samples.
Earlier, VRAM had peaked 26 MiB short of full.

- **Cause:** was a buffer that llama-server wanted in VRAM evicted to GTT? Or did the
  memory clock drop on its own?
- **Which buffer:** if one was evicted, which one, and when?
- **Placement:** does a placement with more free VRAM avoid the slowdown? If so, does
  that configuration beat the deployed one in the full batch, by the owner's rule from
  the 2026-10-10 batch?

## What answers it

A **slow prefill** is a prompt of at least 1,500 new tokens prefilled below 110 t/s. In
the 2026-10-10 batch the slowest full-speed one ran at 137 t/s, and the fastest slow one
at 91.

`vram-residency-sampler.py` records once a second where llama-server's buffers sit:
- the kernel's per-process counters, including `amd-evicted-vram` (memory that asked
  for VRAM and sits in GTT);
- each buffer of 16 MiB or more that changes placement;
- the card's memory and core clocks, power, busy %, VRAM, GTT and temperatures.

Each request's prefill window is matched to those samples.

- **Eviction is the cause** if, in stages 1 and 2:
  - every slow prefill runs while `amd-evicted-vram` is above zero, or while a buffer
    that started in VRAM sits in GTT;
  - no prefill at 110 t/s or more runs in that state;
  - the 96 MHz memory clock in prefill comes with that state and not without it.
- **The memory clock alone is the cause** if slow prefills with the memory clock at
  96 MHz run with nothing evicted.
- **Which buffer:** the moved buffer's handle, size and the time it moved, matched
  against the buffer sizes llama-server logs at load: model, KV, compute and draft.
  Also the request running at that moment.
- **Placement:** per cell of stage 2, VRAM free at load and after the probe, evicted
  memory, and prefill and decode at ~5.8k tokens. A difference between cells counts when
  it is larger than the pass-to-pass spread of both.
- **Stage 3**, judged against the [2026-10-09 batch](2026-10-09-bench.md) by the criterion
  in the [2026-10-10 batch's Deviations](2026-10-10-bench.md#deviations), and showing
  whether any slow prefill or eviction occurs.
- A run with any DIMM sample at 66 °C is reported as capped.

## Configurations

| Stage | Cells |
| --- | --- |
| 1. Reproduce | The 2026-10-10 batch's configuration: `-ncmoe 36`, `--load-mode dio`, Q4_K_M head at n-max 3, one 64k slot; the workloads item only (agent sessions and document ingestion) |
| 2. Placement | `h35`, `h36`, `h37`: the same with `-ncmoe` 35, 36 and 37 ([cells](2026-10-10-prefill-slowdown.cells)), three passes, interleaved |
| 3. Full batch | `make bench GPU=2` at the placement chosen by the rule below |

Placement for stage 3, decided by stages 1 and 2:
- **Eviction is the cause, or neither stage shows a slow prefill:** the smallest `-ncmoe`
  above 36 whose stage-2 cell leaves at least 2,048 MiB free after the probe with nothing
  evicted. The README asks for 2,048 MiB; `-ncmoe 36` left 1,822 in the best-configuration
  record.
- **The memory clock alone is the cause:** `-ncmoe 36` with the card's `COMPUTE` power
  profile, which sets an 850 MHz minimum active memory clock. It is set on
  `0000:83:00.0` for the batch and put back to `BOOTUP_DEFAULT` afterwards.

The record behind each setting is the [2026-10-10 batch's](2026-10-10-bench.md#configurations).
One more CPU-resident expert layer costs about 1.8% of decode and 2.3% of prefill
([MTP record](2026-10-09-mtp.md)).

- **One slot, one card:** as in the 2026-10-10 batch (owner, 2026-10-10).
- **Without the head:** left out. `dio` alone leaves 2,076 MiB of VRAM free at load and
  showed no slowdown in the [best-configuration record](2026-10-10-best-config.md). The question is
  about this configuration.

## Controls

- Stage 1 repeats the 2026-10-10 batch's workloads item under the same code, build, card,
  prompts and configuration, so its timings compare with that run's.
- Stage 2's cells differ only in `-ncmoe`.
- Stage 3's reference is the 2026-10-09 batch, the deployed configuration.

## Method

The code is the branch head when each stage starts, staged with
[`push-harness.sh`](../../push-harness.sh); the batch also records its commit.

```bash
# Host: start the residency sampler (one unit per stage; stop it after the stage)
H=/root/harness/<sha12>/pro-v620/qwen38-flash-next
systemd-run --unit=vram-residency --collect /usr/bin/python3 $H/vram-residency-sampler.py \
  --pci 0000:83:00.0 --output /root/qwen38-flash-next/residency-<stage>.jsonl
systemctl stop vram-residency

# Stage 1 (and 3): install the configuration, as in the 2026-10-10 batch's Method, with
# MODEL_CPU_MOE set for the stage; the deployed file is still backed up in CT 123 as
# /etc/llamacpp-qwen38fn.env.pre-bench-20261010
pct exec 123 -- /usr/local/bin/llamacpp-qwen38fn-reload 65536 1
# Mac, repo root, stage 1: the workloads item only
ansible-playbook ansible/benchmark.yml -e @<main checkout>/ansible/secrets.yml -e gpu=2 \
  -e runtime=llamacpp -e allow_dirty=false -e suite=full -e run_agent_sessions=true \
  -e run_doc_ingest=true -e '{"regression_benchmarks": []}'
# Mac, stage 3: the full batch
make bench GPU=2 SECRETS=<main checkout>/ansible/secrets.yml
# Host, after stages 1 and 3: restore the deployed configuration
pct exec 123 -- cp -p /etc/llamacpp-qwen38fn.env.pre-bench-20261010 /etc/llamacpp-qwen38fn.env
pct exec 123 -- systemctl restart llamacpp-qwen38fn

# Stage 2, host
cd $H
VMID=123 ./thermal-guard.sh            # shell 1
VMID=123 CELLS=runs/2026-10-10-prefill-slowdown.cells DEPTHS="0,8000" DROP_CACHES=true \
  ./placement-sweep.sh                 # shell 2
```

- After each load, llama-server's buffer sizes are read from CT 123's journal, to name the
  buffers the sampler lists.
- Stage 1 uses the batch's own items, prompts and reloads; only the regression items are
  left out. The 2026-10-10 batch slowed 20 minutes into the same item.
- Stage 3 keeps the configuration if it meets the criterion, as the owner asked for the
  2026-10-10 batch (2026-10-10). Otherwise the deployed env file is restored.
- Expected duration: stage 1 about 1 to 2 hours, stage 2 about 45 minutes, stage 3 about 3
  to 3.5 hours.
- Raw data:
  - Batch runs: `pro-v620/results/llamacpp-gpu2/parallel-1/<run>/` on the Mac.
  - Sweep: `/root/qwen38-flash-next/sweep-<timestamp>/` on the host.
  - Residency samples: `/root/qwen38-flash-next/residency-<stage>.jsonl` on the host.

## Safety

- Every guest the stages do not use stays shut down: CT 120 `llamacpp`, CT 121 `hermes`,
  CT 140 `kb-rag`, VM 300 `docker-host` and CT 201. CT 200 runs for stages 1 and 3 and is
  shut down by the batch afterwards; stage 2 drops the host page cache, so it runs with
  CT 200 off. Starting any other guest waits for the owner's go-ahead.
- `gpu-thermal-watchdog` stops `llamacpp-qwen38fn` at 102 °C junction or 101 °C memory;
  `thermal-guard.sh` covers stage 2's sweep.
- `h35` may not fit: the [MTP record](2026-10-09-mtp.md) fitted the head at `-ncmoe 36`.
  A cell that does not load, or loads with buffers in GTT, is recorded as such; that is
  the condition stage 2 looks at.
- The sampler only reads sysfs, debugfs and `/proc`.
- Keep clear of the Sunday 01:00 backup window.

## Environment

llama.cpp b11505 (`ff5888f99`, release tarball), Mesa 26.2.4 (kisak-mesa), kernel
`7.0.14-22-pve`, pve-firmware 3.18-7, `schedutil`, 8 × 64 GB DDR4-3200. CT 123 with 24 cores
and 120 GiB holding `0000:83:00.0` (`unique_id` `99b104541144b36c`) at 0 mV and 250 W.

Below is stage 3's capture, taken by the batch at 17:37 UTC before its first item; the
baseline's, soak's and workloads' `versions.json` hold it. Stage 1's capture, at 15:33 UTC
in its run's `versions.json`, differs only in `MODEL_CPU_MOE` and the command line's
`--n-cpu-moe` (36), and in 1,772 MiB free at load instead of 3,273. Stage 2's sweep saved
its own `environment.json`; see Deviations.

<details>
<summary>environment.json</summary>

```json
{
 "captured_at": "2026-10-10T17:37:58Z",
 "cards": [
  {
   "driver": "amdgpu",
   "name": "Advanced Micro Devices, Inc. [AMD/ATI] Navi 21 [Radeon Pro V620]",
   "od_vddgfx_offset": "0mV",
   "pci": "0000:83:00.0",
   "pcie_link": "16.0GT/s, x16 619Mhz",
   "power_cap_w": 250,
   "unique_id": "99b104541144b36c",
   "vbios": "113-D6030500-100",
   "vram_total_mib": 30704
  }
 ],
 "guest": {
  "config": {
   "cores": "24",
   "hostname": "gpu2",
   "memory": "122880",
   "ostype": "ubuntu",
   "swap": "4096"
  },
  "env": {
   "EXTRA_ARGS": "--device Vulkan0 --spec-type draft-mtp --model-draft /models/hf/qwen3.8-flash-next/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf --spec-draft-ngl all --spec-draft-n-max 3",
   "LLAMACPP_DIR": "/opt/llamacpp/llama-b11505",
   "MODEL_ALIAS": "qwen3.8-flash-next",
   "MODEL_BATCH_SIZE": "4096",
   "MODEL_CONTEXT_LENGTH": "65536",
   "MODEL_CPU_MOE": "37",
   "MODEL_EXPECTED_GPUS": "1",
   "MODEL_GPU_LAYERS": "99",
   "MODEL_KV_TYPE": "q8_0",
   "MODEL_LOAD_MODE": "dio",
   "MODEL_MMPROJ": "/models/hf/qwen3.8-flash-next/mmproj-F16.gguf",
   "MODEL_MMPROJ_ON_CPU": "true",
   "MODEL_MOE_CACHE_MIB": "",
   "MODEL_OT_OVERRIDE": "per_layer_token_embd=CPU",
   "MODEL_PARALLEL": "1",
   "MODEL_PATH": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf",
   "MODEL_SERVER_BIND": "0.0.0.0",
   "MODEL_SERVER_PORT": "1234",
   "MODEL_TENSOR_SPLIT": "",
   "MODEL_THREADS": "16",
   "MODEL_UBATCH_SIZE": "1024"
  },
  "env_file": "/etc/llamacpp-qwen38fn.env",
  "guest_kernel": "7.0.14-22-pve",
  "kind": "lxc",
  "llamacpp": {
   "built_with": "built with GNU 11.4.0 for Linux x86_64",
   "devices": "Vulkan0: AMD Radeon Pro V620 (RADV NAVI21) (30704 MiB, 3273 MiB free)",
   "dir": "/opt/llamacpp/llama-b11505",
   "llama_server_sha256": "b8f67ab0ac46efeed0bc84fe84ef51e9eee08a52c5f7fe56375ec89d3f79729c",
   "version": "version: 0.6.0-dev (build 11505, commit ff5888f99)"
  },
  "mesa": "26.2.4~kisak1~n",
  "model_files": [
   {
    "bytes": 10946624,
    "exists": true,
    "path": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf",
    "verified_stamp": true
   },
   {
    "bytes": 49859583136,
    "exists": true,
    "path": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf",
    "verified_stamp": true
   },
   {
    "bytes": 49376141504,
    "exists": true,
    "path": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf",
    "verified_stamp": true
   },
   {
    "bytes": 12087983520,
    "exists": true,
    "path": "/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf",
    "verified_stamp": true
   },
   {
    "bytes": 904004000,
    "exists": true,
    "path": "/models/hf/qwen3.8-flash-next/mmproj-F16.gguf",
    "verified_stamp": true
   },
   {
    "bytes": 2786204800,
    "exists": true,
    "path": "/models/hf/qwen3.8-flash-next/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf",
    "verified_stamp": true
   }
  ],
  "os": "Ubuntu 24.04 LTS",
  "rocm": null,
  "server_cmdline": "/opt/llamacpp/llama-b11505/llama-server --model /models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf --host 0.0.0.0 --port 1234 --alias qwen3.8-flash-next --n-gpu-layers 99 --ctx-size 65536 --parallel 1 --threads 16 --flash-attn on --batch-size 4096 --ubatch-size 1024 --jinja --reasoning off --reasoning-format auto --cache-ram 0 --metrics --override-tensor per_layer_token_embd=CPU --n-cpu-moe 37 --cache-type-k q8_0 --cache-type-v q8_0 --load-mode dio --mmproj /models/hf/qwen3.8-flash-next/mmproj-F16.gguf --no-mmproj-offload --device Vulkan0 --spec-type draft-mtp --model-draft /models/hf/qwen3.8-flash-next/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf --spec-draft-ngl all --spec-draft-n-max 3",
  "unit": "llamacpp-qwen38fn",
  "unit_active": "active",
  "vmid": 123,
  "vulkan_driver": "Mesa 26.2.4 - kisak-mesa PPA"
 },
 "host": {
  "cpu": "AMD EPYC 7532 32-Core Processor",
  "dimms": [
   {
    "configured_speed": "3200 MT/s",
    "locator": "P0 CHANNEL A",
    "part": "M393A8K40B22-CAE",
    "size": "64 GB"
   },
   {
    "configured_speed": "3200 MT/s",
    "locator": "P0 CHANNEL B",
    "part": "M393A8K40B22-CAE",
    "size": "64 GB"
   },
   {
    "configured_speed": "3200 MT/s",
    "locator": "P0 CHANNEL C",
    "part": "M393A8K40B22-CAE",
    "size": "64 GB"
   },
   {
    "configured_speed": "3200 MT/s",
    "locator": "P0 CHANNEL D",
    "part": "M393A8K40B22-CAE",
    "size": "64 GB"
   },
   {
    "configured_speed": "3200 MT/s",
    "locator": "P0 CHANNEL E",
    "part": "M393A8K40B22-CAE",
    "size": "64 GB"
   },
   {
    "configured_speed": "3200 MT/s",
    "locator": "P0 CHANNEL F",
    "part": "M393A8K40B22-CAE",
    "size": "64 GB"
   },
   {
    "configured_speed": "3200 MT/s",
    "locator": "P0 CHANNEL G",
    "part": "M393A8K40B22-CAE",
    "size": "64 GB"
   },
   {
    "configured_speed": "3200 MT/s",
    "locator": "P0 CHANNEL H",
    "part": "M393A8K40B22-CAE",
    "size": "64 GB"
   }
  ],
  "governor": "schedutil",
  "hostname": "proxmox",
  "kernel": "7.0.14-22-pve",
  "mem_gib": 504,
  "pve_firmware": "3.18-7",
  "pve_manager": "9.2.21"
 }
}
```

</details>

---

## Results

### Stage 1: the workloads item at `-ncmoe 36`

The workloads item ran from 15:35 to 16:52 UTC (folder `20261010T153544Z-workloads`,
commit `47d75ab`) and exited 0. All 180 turns completed, with no empty reply and no lost
slot cache, and all 12 documents. The hottest DIMM reached 57 °C, junction 83 °C.

| Preset | Session wall (s) | Decode tokens per rep | 2026-10-10 batch, same configuration | 2026-10-09 batch, deployed |
| --- | --- | --- | --- | --- |
| `hermes` | 627 (575–672) | 5,744 (4,661–6,165) | 768 (405–1,112) | 1,179 (1,162–1,194) |
| `coding` | 418 (405–419) | 3,053 (2,840–3,061) | 988 (448–1,010) | 848 (808–857) |

Document ingestion took 58.8, 87.3, 146.4 and 205.3 s from request to last token at 8k,
16k, 32k and 48k (medians), prefilling at 285–305 t/s. Every note wrote all three
sections, and the three reps of a size wrote the same text. The deployed env file was put
back at 16:54 UTC, before stage 2.

No stretch like the batch's 70 minutes occurred, but individual prefills slowed:

| VRAM-requested memory in GTT for most of the prefill | Agent prefills of 1.5k+ tokens | Prefill (t/s) | Power, median (W) | Busy samples at a 96 MHz memory clock, median |
| --- | ---: | --- | ---: | ---: |
| None | 52 | 170–284, median 244 | 160 | 0% |
| 850 MiB | 12 | 156–214, median 159 | 137 | 0% |
| 1,024 MiB | 2 | 135–136 | 123 | 38% |

- "VRAM-requested memory in GTT" is `amd-requested-vram` minus `drm-resident-vram` from
  llama-server's fdinfo. The kernel's `amd-evicted-vram` read zero throughout.
- Two buffers caused it, each freed and created again within requests:
  - one of 1,001–1,024 MiB;
  - one whose size alternated between 850 MiB and about 185 MiB.
- A buffer created while VRAM could not hold it went to GTT, and one created when VRAM
  had room went to VRAM. At 15:56:28 UTC VRAM held 29,704 of 30,704 MiB, 24 MiB short
  of the 1,024 MiB buffer. When that buffer was created again in VRAM, at 16:02:31,
  power rose from about 75 W to 150 W within a second and the memory clock read
  1,000 MHz.
- The same requests put the 1,024 MiB buffer in GTT in every rep: `hermes` turns 40
  and 43, and turn 13 in reps 2 and 3. Turn 40 (920 new tokens) prefilled at 64–65 t/s,
  against 162 t/s in the batch's first rep and 89–90 t/s with the deployed configuration.
  Turn 13 prefilled at 135–136 t/s, against 214 in rep 1. The batch's first slow turn,
  at 13:38:30 UTC, was also turn 13.

### Stage 2: free VRAM and placement

Sweep `sweep-20261010T165539Z` (harness `a4d006c`), 16:55–17:35 UTC, three interleaved
passes, every load cold:

| Cell | VRAM free at load (MiB) | VRAM free after the probe (MiB) | VRAM-requested memory in GTT during d8000 prefill | Busy prefill samples at 96 MHz | Prefill power, median (W) | VRAM busy in prefill, median | Prefill at d8000 (t/s) | Decode, median of six cells (t/s) |
| --- | ---: | ---: | --- | --- | ---: | ---: | --- | --- |
| `h35` | 772 | 1,832 | 1,518 MiB, every sample | 38–62% | 81 | 1% | 143–146 | 14.4 |
| `h36` | 1,773 | 1,822 | none | 0–6% | 160 | 25% | 343–365 | 18.3 |
| `h37` | 3,274 | 3,324 | none | 0–6% | 160 | 24% | 347–360 | 18.1 |

- Per-pass spreads: d8000 prefill was 352.0–364.3 t/s for `h36` and 359.1–359.7 for
  `h37`; median decode was 18.17–18.28 and 17.86–18.31. The two cells overlap on both.
- The least VRAM free during a d8000 prefill was 770 MiB for `h36` and 3,253 MiB for
  `h37`.
- `h35`'s GTT grew by 1,180 MiB during its probe in every pass, and the sweep flagged the
  row as a possible spill. `h35` decoded 21% slower than `h36`.
- All cells passed the raw-completion output gate. The template contract was checked
  only on `h35` in the first pass; `h36` and `h37` were not checked. The hottest DIMM
  reached 58 °C.

### Stage 3: the full batch at `-ncmoe 37`

By the plan's rule, stage 3 runs `-ncmoe 37`: the smallest placement above 36 whose cell
left at least 2,048 MiB free after the probe with nothing in GTT.

`make bench GPU=2` ran from commit `a4d006c` from 17:37 to 20:17 UTC (2 h 40 min, against
5 h 34 min for the 2026-10-09 batch and 3 h 18 min for the 2026-10-10 batch). `make` exited
0: every item ran to the end, all 427 requests succeeded and every `SLO.md` passes. The
deployed env file was put back at 20:19 UTC and `llamacpp-qwen38fn` restarted; a request
then decoded at 14.3 t/s without draft tokens, with 28,629 MiB of VRAM and 229 MiB of GTT
in use.

| Item | Run folder | UTC | Duration | Requests completed | 2026-10-09 duration |
| --- | --- | --- | ---: | ---: | ---: |
| Baseline | `20261010T174003Z-baseline` | 17:40–17:51 | 12 min | 18/18, llama-benchy exit 0 | 23 min |
| Concurrency sweep | `20261010T175243Z-sweep-concurrency` | 17:52–18:21 | 28 min | 160/160 | 47 min |
| Input-length sweep | `20261010T182208Z-sweep-input-length` | 18:22–18:43 | 22 min | 40/40 | 59 min |
| Soak | `20261010T184443Z-soak` | 18:44–19:02 | 18 min | 18/18, llama-benchy exit 0 | 38 min |
| Workloads | `20261010T190347Z-workloads` | 19:03–20:16 | 1 h 12 min | 179/179 turns, 12/12 documents | 2 h 43 min |

**Against the criterion.** Two of its three conditions held:
- Every item exited 0, no request failed, the hottest DIMM reached 57 °C and the watchdog
  logged nothing.
- `hermes`' median session took 532 s against 1,179, and `coding`'s 388 s against 848,
  with no lost slot cache and no empty reply. Every ingestion size finished sooner, by
  53–61%, and every note wrote all three sections (48k: 3/3 against 0/3).

The third failed at two points. Median decode was 20.2% lower at the input-length sweep's
512-token point (11.1 against 14.0 t/s), and 16.0% lower at llama-benchy's 32 tokens after
4,096 of context and a 512-token prompt (11.2 against 13.4). Every other point decoded
within 10% or faster, and every first token came sooner except `smoke_hello`'s, 7.3% later
(1.3 s against 1.2).

#### Short prompts, one at a time (baseline)

`openai-direct`, median of three, against the 2026-10-09 batch:

| Scenario | Prompt tokens | Output tokens | First token (s) | Decode (t/s) | Draft acceptance |
| --- | ---: | ---: | --- | --- | ---: |
| `smoke_hello` | 30 | 3 | 1.3, was 1.2 | 11.9, was 11.9 | 33% |
| `interactive_metrics` | 44 | 128 | 1.2, was 4.0 | 16.0, was 10.4 | 50% |
| `coding_patch_plan` | 69 | 384 | 1.3, was 5.0 | 18.8, was 13.8 | 66% |
| `hermes_overhead` | 71 | 256 | 1.4, was 5.0 | 16.5, was 13.9 | 54% |
| `config_tradeoffs` | 93 | 256 | 1.5, was 5.5 | 16.9, was 13.1 | 57% |
| `long_context_ops` | 130 | 466, was 512 | 1.7, was 6.2 | 15.7, was 13.6 | 52% |

p95 latency was 30.4 s (43.8 before) and p95 first token 1.8 s (6.2).

llama-benchy, one request at a time, with the context sent uncached before each prompt
(median of three runs):

| Context before prompt | Prompt | First token, 32 / 128 out (s) | Decode, 32 out (t/s) | Decode, 128 out (t/s) |
| ---: | ---: | --- | --- | --- |
| 0 | 512 | 2.4 / 2.5, was 8.0 / 7.8 | 19.0, was 14.0 | 14.4, was 13.9 |
| 0 | 2,048 | 6.4 / 6.2, was 18.3 / 18.4 | 14.5, was 13.6 | 15.4, was 12.6 |
| 4,096 | 512 | 16.0 / 16.1, was 48.3 / 50.0 | 11.2, was 13.4 | 13.2, was 13.1 |
| 4,096 | 2,048 | 18.8 / 18.1, was 56.1 / 55.3 | 12.3, was 13.3 | 12.1, was 12.5 |

#### Queueing and prompt length (sweeps)

Concurrency sweep, prompts of about 512 tokens, 128 output tokens, 32 requests per point:

| Requests in flight | Prefill p50 (t/s) | Decode p50 (t/s) | Latency p50 (s) | First token p50 (s) |
| ---: | --- | --- | --- | --- |
| 1 | 206.8, was 64.7 | 15.4, was 13.9 | 10.8, was 17.2 | 2.5, was 8.0 |
| 2 | 206.8, was 64.5 | 15.9, was 14.1 | 21.0, was 34.2 | 12.9, was 25.1 |
| 4 | 207.3, was 64.5 | 16.9, was 13.9 | 40.3, was 70.5 | 32.8, was 60.2 |
| 8 | 206.5, was 64.5 | 15.7, was 13.7 | 85.0, was 139.7 | 77.1, was 129.9 |
| 16 | 206.2, was 64.6 | 16.3, was 13.9 | 164.5, was 274.5 | 156.7, was 265.5 |

Input-length sweep, one request at a time, 32 output tokens, 8 requests per point:

| Prompt tokens | Prefill p50 (t/s) | Decode p50 (t/s) | First token p50 (s) |
| ---: | --- | --- | --- |
| 128 | 81.5, was 23.3 | 14.9, was 14.0 | 1.7, was 5.9 |
| 512 | 205.9, was 64.4 | 11.1, was 14.0 | 2.5, was 8.1 |
| 2,048 | 312.6, was 110.1 | 16.8, was 14.2 | 6.6, was 18.7 |
| 8,192 | 311.6, was 107.8 | 15.8, was 13.9 | 26.3, was 76.1 |
| 32,768 | 290.5, was 103.7 | 16.2, was 12.9 | 112.9, was 316.3 |

The two points that failed, request by request:
- At the 512-token point, the eight requests decoded at 7.6–14.3 t/s, against 13.5–14.4
  with the deployed configuration and 11.8–15.2 in the 2026-10-10 batch at `-ncmoe 36`.
  Two of them each drafted 39–40 tokens and accepted 17; one decoded its 32 tokens in
  2.2 s, the other in 4.1 s.
- llama-benchy's three runs at 4,096 + 512 → 32 decoded at 7.2, 11.2 and 14.2 t/s, against
  9.8, 13.4 and 13.5.
- In the 2026-10-10 batch at `-ncmoe 36`, the same two points read 14.3 and 12.2 t/s, and
  4,096 + 2,048 → 32 read 11.7 against 13.3 (−11.9%).

Soak, two requests on one slot: per-scenario median decode was 14.0–19.2 t/s (12.6–13.9
before; `smoke_hello` left out), p95 first token 34.0 s (52.1) and p95 latency 63.3 s
(91.0). llama-benchy at two requests in flight decoded each request at 11.9–17.6 t/s
(12.0–14.1), means of three.

#### Agent sessions

All 179 turns completed, no reply was empty, and no turn lost the slot's cache. `hermes`'
second rep reached the 56k stop after 42 turns.

| Preset | Session wall (s) | Final depth | Prefill tokens per rep | Decode tokens per rep | Cold first turn prefill (t/s) | Replies cut at their cap |
| --- | --- | ---: | ---: | --- | --- | --- |
| `hermes` | 532 (436–679), was 1,179 (1,162–1,194) | 57,246 | 54,306 | 4,560 (2,979–7,545), was 5,124 | 276.9 (275.1–277.2), was 92.0 | 19 of 128, was 8 of 129 |
| `coding` | 388 (378–400), was 848 (808–857) | 57,054 | 54,278 | 2,896 (2,852–3,165), was 2,950 | 280.1 (279.9–281.0), was 93.2 | 5 of 51, was 3 of 51 |

| Session | Start (UTC) | Wall (s) | Decode tokens | Warm prefills of 1.5k+ tokens, median (t/s) | Busy samples at a 96 MHz memory clock |
| --- | --- | ---: | ---: | ---: | ---: |
| `hermes` 1 | 19:03 | 436 | 2,979 | 243 | 1 of 254 |
| `coding` 1 | 19:11 | 388 | 2,896 | 236 | 0 of 246 |
| `hermes` 2 | 19:17 | 679 | 7,545 | 245 | 1 of 333 |
| `coding` 2 | 19:28 | 400 | 3,165 | 239 | 0 of 241 |
| `hermes` 3 | 19:35 | 532 | 4,560 | 246 | 0 of 274 |
| `coding` 3 | 19:44 | 378 | 2,852 | 237 | 1 of 234 |

| Preset | Depth band | Turns | Prefill tokens | Prefill (t/s) | Decode tokens | Decode (t/s) | Draft acceptance |
| --- | --- | ---: | ---: | --- | ---: | --- | ---: |
| `hermes` | 0–16k | 16 | 18,327 | 205.5, was 69.0 | 3,450 | 18.2, was 13.1 | 71% |
| `hermes` | 16–32k | 50 | 48,204 | 194.8, was 66.5 | 6,813 | 17.5, was 12.9 | 73% |
| `hermes` | 32–64k | 59 | 62,321 | 187.4, was 67.3 | 4,472 | 16.8, was 12.7 | 70% |
| `coding` | 0–16k | 12 | 43,433 | 265.5, was 94.7 | 1,315 | 18.0, was 12.7 | 69% |
| `coding` | 16–32k | 15 | 38,782 | 234.5, was 86.1 | 3,735 | 18.9, was 13.0 | 79% |
| `coding` | 32–64k | 21 | 66,542 | 223.6, was 84.1 | 3,535 | 18.1, was 12.4 | 76% |

- Session wall time is the median (min–max) of three reps; band rates are all tokens over
  all time in the band, without each session's cold first turn.
- As in the 2026-10-10 batch, the head changes the text, so the replies differ from the
  2026-10-09 batch's and between reps: `hermes`' reps decoded 2,979 to 7,545 tokens.

#### Document ingestion

Cold prompts of repository documents, three reps per size, notes capped at 640 tokens:

| Size | Prompt tokens | Prefill (t/s) | First token (s) | Decode (t/s) | Request to last token (s) | All three sections | Finish | Draft acceptance |
| --- | ---: | --- | --- | --- | --- | --- | --- | ---: |
| 8k | 8,193 | 306.1 (305.7–306.3), was 103.3 | 26.8, was 79.3 | 19.9 (19.7–20.0), was 12.7 | 58.8, was 124.8 | 3/3, was 3/3 | length, was stop | 77% |
| 16k | 16,380 | 300.2 (299.8–300.5), was 103.5 | 54.6, was 158.3 | 18.8 (18.2–19.0), was 13.0 | 88.6, was 205.5 | 3/3, was 3/3 | length, was stop | 76% |
| 32k | 32,768 | 290.7 (290.6–290.9), was 102.4 | 112.7, was 319.8 | 17.5 (17.5–18.0), was 12.8 | 149.1, was 369.3 | 3/3, was 3/3 | length | 70% |
| 48k | 49,155 | 282.9 (282.7–283.3), was 102.1 | 173.8, was 481.5 | 18.7 (17.6–18.7), was 12.5 | 208.2, was 532.5 | 3/3, was 0/3 | length | 81% |

Medians of three, with the range in brackets. Every note reached the 640-token cap, and
the three reps of a size wrote the same text.

#### Card, memory and residency

From CT 123's samples of `0000:83:00.0` and the BMC's:

| Item | Junction max (°C) | Memory max (°C) | Core clock in use, median (MHz) | VRAM max (MiB) | GTT max (MiB) | Busy samples at a 96 MHz memory clock | Hottest DIMM max (°C) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline | 77 | 66 | 2,390 | 28,460 | 58,045 | 0 of 354 | 55 |
| Concurrency sweep | 70 | 60 | 2,390 | 27,466 | 58,044 | 0 of 706 | 56 |
| Input-length sweep | 83 | 70 | 2,380 | 28,830 | 58,045 | 1 of 997 | 57 |
| Soak | 81 | 68 | 2,385 | 29,141 | 58,045 | 0 of 578 | 57 |
| Workloads | 84 | 70 | 2,385 | 29,454 | 58,045 | 6 of 2,617 | 57 |

The residency sampler ran from 17:36 to 20:17 UTC, 9,635 samples with llama-server running:
- No sample had VRAM-requested memory outside VRAM, and `amd-evicted-vram` read zero.
- VRAM peaked at 29,849 MiB (855 MiB free) at 19:08:18 UTC, during `hermes`' first rep.
- The workloads' 77 prefills of 1.5k+ new tokens ran at 221–306 t/s (median 252), with at
  least 1,382 MiB of VRAM free and 0–5% of busy samples at 96 MHz.
- The turns that put the 1,024 MiB buffer in GTT in stage 1 prefilled at full speed: turn
  40 at 221 t/s (64–65 in stage 1), turn 13 at 258–261 (135–214) and turn 43 at 246
  (170–172).
- Per phase in the workloads, median: prefill at 165 W, 2,385 MHz core, 1,000 MHz memory
  (95% of samples), 99% busy and 24% VRAM busy; decode at 58 W, 500 MHz core, 1,000 MHz
  memory (98%), 48% busy and 17% VRAM busy.

## Deviations

- **Sampler fixes between stages:** stage 1 ran the sampler from `47d75ab`. It read sizes
  that fdinfo prints in MiB as KiB, and it listed a buffer that `amdgpu_gem_info` prints as
  `UNKNOWN` (locked by a submission) as a move. `5c636a3` and `a4d006c` fixed both, and
  stages 2 and 3 ran `a4d006c`. `residency-summary.py` corrects stage 1's sizes (a value
  under 1/100 of the card's own reading is taken as MiB).
- **Measure of eviction:** the plan's measures, `amd-evicted-vram` and a buffer moving
  from VRAM to GTT, never registered: the buffers were created in GTT rather than moved
  there. The results use `amd-requested-vram` minus `drm-resident-vram` instead. Per-buffer
  moves are not used, because GEM handles are reused.
- **Slow prefill:** no prefill of 1,500+ new tokens fell below the plan's 110 t/s in any
  stage. Stage 1's affected prefills of that size ran at 135–214 t/s, and the slowest
  affected turn (turn 40, 64–65 t/s) had 920 new tokens. The results group prefills by
  the memory outside VRAM instead. The placement rule picks `-ncmoe 37` under either
  reading: "eviction is the cause" and "neither stage shows a slow prefill" lead to the
  same choice.
- **Naming the buffers:** at the service's log level, CT 123's journal holds no
  per-buffer sizes from load, so the buffers are described by size only. At each exit,
  llama-server warned that its Vulkan0 compute buffer was 1,194.7–1,291.5 MiB against
  1,355.8 MiB expected.
- **Owner's confirmation:** before stage 3, the owner confirmed that `-ncmoe 37` could
  stay if it met the criterion (2026-10-10).
- **Stage 2's environment:** the sweep's `environment.json` was captured before the first
  cell, with the deployed env file installed (`-ncmoe 34`, no load mode, no head). Each
  cell's command line is in the sweep's records.
- **Stage 3's tree:** this record's stage 1 and 2 results were uncommitted while stage 3
  ran; `make bench` checks only the benchmark code.
- **llama-benchy against the criterion:** the criterion reads medians; this record quotes
  llama-benchy's median of three runs, where the 2026-10-10 batch's record quoted the
  mean. By the median, that batch also failed at 4,096 + 2,048 → 32 (11.7 against 13.3
  t/s); its record is corrected.
- **Degenerate output:** the suite counts none. As in the 2026-10-10 batch, output is
  checked through failed requests, empty replies, and whether each ingestion note wrote
  all three sections.

## Conclusion

**Cause.** The slowdown came with memory llama-server had asked to have in VRAM sitting
in GTT. Two buffers that llama-server frees and creates again within requests, one of
1,001–1,024 MiB and one of 850 or about 185 MiB, were created in GTT when VRAM could not
hold them at that moment, and in VRAM when it could. `amd-evicted-vram` stayed at zero.
The 96 MHz memory clock came with that state, not without it:
- in stage 1, prefills with nothing outside VRAM ran at 170–284 t/s with a median 0% of
  busy samples at 96 MHz;
- in stage 1, the memory clock read 1,000 MHz again within a second of the 1,024 MiB
  buffer being created in VRAM;
- in stage 2, `h35` had 1,518 MiB in GTT through every d8000 prefill and 38–62% of busy
  samples at 96 MHz, while `h36` and `h37` had none and 0–6%.

**Placement.** `-ncmoe 37`, with 3,274 MiB free at load, had nothing outside VRAM in
stage 2 or in any of stage 3's 9,635 samples. Its 77 workload prefills of 1.5k+ tokens ran
at 221–306 t/s. Its d8000 prefill and decode overlapped `-ncmoe 36`'s pass-to-pass spread.

**Against the deployed configuration.** Stage 3 fails the criterion's third condition at
two points. Median decode was 20.2% lower at the input-length sweep's 512-token point
(11.1 against 14.0 t/s) and 16.0% lower at llama-benchy's 4,096 + 512 → 32 (11.2 against
13.4). Every other condition held:
- `hermes`' median session took 532 s against 1,179 and `coding`'s 388 s against 848;
- every ingestion size finished 53–61% sooner, with all three sections in every note;
- no request failed and the hottest DIMM reached 57 °C.

The deployed env file was restored.

**Not explained.**
- In the 2026-10-10 batch, the 1,024 MiB buffer stayed in GTT for 70 minutes across
  requests. In stage 1 it returned to VRAM between requests. No stage reproduced the long
  stretch.
- The low decode at the two failing points came with no memory outside VRAM. Two
  requests that drafted 39–40 tokens and accepted 17 took 2.2 s and 4.1 s for 32 tokens.
