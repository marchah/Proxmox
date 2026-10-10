# Qwen3.8-Flash-Next: short-reply decode with `dio` and the MTP head

Plan committed 2026-10-10 · Run 2026-10-10 · Status: done

## Question

The [prefill-slowdown record](2026-10-10-prefill-slowdown.md)'s full batch at `-ncmoe 37`
with `dio` and the MTP head failed the owner's keep rule at two points, both 32-token
replies:
- the input-length sweep's 512-token point: median decode 11.1 t/s against 14.0 (−20.2%);
- llama-benchy's 512-token prompt after 4,096 tokens of context: 11.2 against 13.4 (−16.0%).

Requests within one point decoded at 7.6–14.3 t/s. Is the loss at these points larger
than the spread between repeated runs?

## What answers it

For each configuration and point: the median decode rate of each rep, and the median over
all reps (24 requests per input-length point, 9 llama-benchy runs per point).

- The loss at a point **holds** when `h37`'s median over all reps is lower than `dep`'s by
  more than the rep-to-rep spread (highest minus lowest rep median) of either
  configuration. Otherwise it is within the spread.
- Each result is also read against the keep rule's limit: a median decode more than 10%
  lower.
- Per request: drafted and accepted tokens and the decode time; from the residency
  sampler, VRAM-requested memory outside VRAM, card power and core clock during the
  decode.

This record does not change the prefill-slowdown record's verdict. Whether to deploy is
the owner's decision.

## Configurations

| Cell | Configuration |
| --- | --- |
| `dep` | Deployed: `-ncmoe 34`, `auto` load mode, no head |
| `h37` | The prefill-slowdown record's stage 3: `-ncmoe 37`, `--load-mode dio`, Q4_K_M head at n-max 3 (`--spec-type draft-mtp --model-draft /models/hf/qwen3.8-flash-next/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf --spec-draft-ngl all --spec-draft-n-max 3`) |

Both: CT 123, one 64k slot, q8_0 KV, 16 threads, 4096/1024, projector on CPU, b11505.

- **Left out:** two cards and CPU only (the owner keeps Flash-Next on one card; the question
  is about these two configurations). `dio` at `-ncmoe 37` without the head would separate
  the head from the placement; the owner asked for the two points against the deployed
  configuration.

## Controls

- `dep` is the non-speculative control, the configuration both batches were judged
  against.
- The points run with the batch's own commands and prompts, after a reload, as in the
  batch. Each item also runs the point that preceded it in the batch: the input-length
  sweep's 128-token point, and llama-benchy's 512-token prompt without context.
- Reps interleave as `dep h37 h37 dep dep h37`, so a drift over the run falls on both.

## Method

Code at the plan's commit; the playbook pushes the suite, stops on uncommitted benchmark
code and records the commit and `capture-env.sh`'s capture in each run's `versions.json`.
`LLAMA_BENCHY_PP`, `LLAMA_BENCHY_TG` and `LLAMA_BENCHY_DEPTH`, added with this plan, set
llama-benchy's sizes and keep the rest of its default command line.

```bash
# Host: stage the harness, start the residency sampler for the whole run
./pro-v620/push-harness.sh          # Mac; prints /root/harness/<sha12>
H=/root/harness/<sha12>/pro-v620/qwen38-flash-next
systemd-run --unit=vram-residency --collect /usr/bin/python3 $H/vram-residency-sampler.py \
  --pci 0000:83:00.0 --output /root/qwen38-flash-next/residency-short-reply.jsonl

# Host: the two env files, from the deployed one
pct exec 123 -- cp -p /etc/llamacpp-qwen38fn.env /etc/llamacpp-qwen38fn.env.dep
pct exec 123 -- sh -c 'sed \
  -e "s/^MODEL_CPU_MOE=.*/MODEL_CPU_MOE=\"37\"/" \
  -e "s/^MODEL_LOAD_MODE=.*/MODEL_LOAD_MODE=\"dio\"/" \
  -e "s|^EXTRA_ARGS=.*|EXTRA_ARGS=\"--device Vulkan0 --spec-type draft-mtp --model-draft /models/hf/qwen3.8-flash-next/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf --spec-draft-ngl all --spec-draft-n-max 3\"|" \
  /etc/llamacpp-qwen38fn.env.dep > /etc/llamacpp-qwen38fn.env.h37'

# Per rep, in the order dep h37 h37 dep dep h37
pct exec 123 -- cp /etc/llamacpp-qwen38fn.env.<cell> /etc/llamacpp-qwen38fn.env
pct exec 123 -- systemctl restart llamacpp-qwen38fn
ansible-playbook ansible/benchmark.yml -e @<main checkout>/ansible/secrets.yml -e gpu=2 \
  -e runtime=llamacpp -e allow_dirty=false -e suite=short -e '{"regression_benchmarks": [
    "llm-bench-sweep input-length --points 128 512 --output-tokens 32",
    "RUN_OPENAI_DIRECT=false LLAMA_BENCHY_PP=512 LLAMA_BENCHY_TG=32 LLAMA_BENCHY_DEPTH=\"0 4096\" llm-bench-baseline"]}'

# Host, after the last rep (also if a rep fails)
pct exec 123 -- cp -p /etc/llamacpp-qwen38fn.env.dep /etc/llamacpp-qwen38fn.env
pct exec 123 -- systemctl restart llamacpp-qwen38fn
systemctl stop vram-residency
```

- `h37`'s env file must differ from `dep`'s in exactly the three lines the stage 3 batch
  changed; this is checked before the first rep.
- Before each rep, a request checks the cell: draft tokens in its `timings` for `h37`, none
  for `dep`.
- `residency-summary.py` cannot window decodes; the per-request decode windows are read
  from the request records (start, first token, end) against the sampler's lines.
- Expected duration: about 12 minutes per rep, 1 h 15 min in all.
- Raw data: `pro-v620/results/llamacpp-gpu2/parallel-1/<run>/` on the Mac, two folders per
  rep; residency samples in `/root/qwen38-flash-next/residency-short-reply.jsonl` on the
  host.

## Safety

- Every guest the run does not use stays shut down: CT 120 `llamacpp`, CT 121 `hermes`,
  CT 140 `kb-rag`, VM 300 `docker-host` and CT 201. CT 123 and CT 200 run for it; each
  rep's playbook shuts CT 200 down at its end. Starting any other guest waits for the
  owner's go-ahead.
- `gpu-thermal-watchdog` stops `llamacpp-qwen38fn` at 102 °C junction or 101 °C memory.
  The longest prompt is 4,608 tokens.
- The deployed env file is restored after the run, also if a rep fails.

## Environment

llama.cpp b11505 (`ff5888f99`, release tarball), Mesa 26.2.4 (kisak-mesa), kernel
`7.0.14-22-pve`, pve-firmware 3.18-7, `schedutil`, 8 × 64 GB DDR4-3200. CT 123 with 24 cores
and 120 GiB holding `0000:83:00.0` (`unique_id` `99b104541144b36c`) at 0 mV and 250 W.

Below is the capture from rep 2, the first `h37` rep, taken at 21:00 UTC; each rep's
llama-benchy item holds its own in `versions.json`. The three `h37` captures are identical
apart from the time, and so are the three `dep` captures. `dep`'s differ from `h37`'s in
the three env lines, the command line (`--n-cpu-moe 34`, no `--load-mode`, no head), the
head's file missing from the model files, and 2,074 MiB free at load instead of 3,270.

<details>
<summary>environment.json</summary>

```json
{
 "captured_at": "2026-10-10T21:00:19Z",
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
   "devices": "Vulkan0: AMD Radeon Pro V620 (RADV NAVI21) (30704 MiB, 3270 MiB free)",
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

The six reps ran from 20:48 to 21:44 UTC (56 minutes) with the code at `05ca985`. Every
playbook exited 0, all 96 input-length requests succeeded, llama-benchy exited 0 in every
rep and every `SLO.md` passes. The hottest DIMM reached 53 °C and the watchdog logged
nothing.

| Rep | Cell | UTC | Input-length folder | llama-benchy folder | Check request: drafts, decode (t/s) |
| ---: | --- | --- | --- | --- | --- |
| 1 | `dep` | 20:48–20:58 | `20261010T205112Z-sweep-input-length` | `20261010T205425Z-baseline` | 0, 14.1 |
| 2 | `h37` | 20:58–21:07 | `20261010T210224Z-sweep-input-length` | `20261010T210436Z-baseline` | 51, 16.6 |
| 3 | `h37` | 21:07–21:16 | `20261010T211107Z-sweep-input-length` | `20261010T211319Z-baseline` | 51, 16.6 |
| 4 | `dep` | 21:16–21:26 | `20261010T211833Z-sweep-input-length` | `20261010T212141Z-baseline` | 0, 13.9 |
| 5 | `dep` | 21:26–21:36 | `20261010T212827Z-sweep-input-length` | `20261010T213135Z-baseline` | 0, 14.0 |
| 6 | `h37` | 21:36–21:44 | `20261010T213947Z-sweep-input-length` | `20261010T214201Z-baseline` | 51, 16.6 |

After each check request, `dep` had 28,629 MiB of VRAM and 229 MiB of GTT in use, and
`h37` 27,433 MiB and 58,042 MiB. The deployed env file was put back at 21:44 UTC and
`llamacpp-qwen38fn` restarted.

### Decode

Median decode of each rep, in rep order, and the median over all of a configuration's
requests (24 per input-length point) or runs (9 per llama-benchy point). The spread is the
highest rep median minus the lowest.

| Point | Cell | Rep medians (t/s) | Median over all (t/s) | Range (t/s) | Spread (t/s) | First token, median (s) |
| --- | --- | --- | ---: | --- | ---: | ---: |
| Input length 128 → 32 | `dep` | 13.19, 13.33, 13.32 | 13.29 | 6.0–14.2 | 0.14 | 5.93 |
| | `h37` | 14.92, 16.73, 15.05 | 15.34 | 10.7–18.7 | 1.81 | 1.72 |
| Input length 512 → 32 | `dep` | 13.93, 13.82, 13.87 | 13.86 | 12.2–14.4 | 0.11 | 8.11 |
| | `h37` | 13.06, 12.30, 11.62 | 12.35 | 10.7–15.0 | 1.44 | 2.51 |
| llama-benchy 0 + 512 → 32 | `dep` | 13.08, 13.68, 13.75 | 13.46 | 9.7–14.2 | 0.68 | 7.86 |
| | `h37` | 16.48, 16.46, 14.65 | 16.46 | 10.3–20.4 | 1.83 | 2.40 |
| llama-benchy 4,096 + 512 → 32 | `dep` | 13.57, 13.38, 13.35 | 13.38 | 12.5–13.6 | 0.21 | 49.40 |
| | `h37` | 12.46, 13.16, 14.95 | 13.16 | 11.2–16.5 | 2.49 | 14.39 |

| Point | `h37` against `dep` | Larger than both spreads | More than 10% lower | Prefill-slowdown record, stage 3 |
| --- | --- | --- | --- | --- |
| Input length 512 → 32 | −1.51 t/s (−10.9%) | yes, by 0.07 t/s over `h37`'s 1.44 | yes | 11.1 against 14.0 (−20.2%) |
| llama-benchy 4,096 + 512 → 32 | −0.22 t/s (−1.6%) | no | no | 11.2 against 13.4 (−16.0%) |
| Input length 128 → 32 | +2.05 t/s (+15.5%) | | no | 14.9 against 14.0 |
| llama-benchy 0 + 512 → 32 | +3.01 t/s (+22.3%) | | no | 19.0 against 14.0 |

At the 512-token point, every `h37` rep median (11.62–13.06) was below every `dep` rep
median (13.82–13.93). At 4,096 + 512, `h37`'s rep medians (12.46–14.95) fell on both sides
of `dep`'s (13.35–13.57).

### Drafts, request by request

`h37`'s 32-token replies, all three reps; acceptance is accepted over drafted tokens:

| Point | Accepted of 32, median (range) | Drafted | Acceptance |
| --- | --- | --- | ---: |
| Input length 128 | 18 (16–20) | 31–42 | 49% |
| Input length 512 | 14 (12–18) | 38–56 | 32% |

At the 512-token point, decode rose with the accepted tokens:

| Accepted | Requests | Drafted | Decode (t/s) | Decode time (ms) |
| ---: | ---: | --- | --- | --- |
| 12 | 2 | 54–56 | 10.7–11.1 | 2,799–2,894 |
| 13 | 1 | 54 | 11.3 | 2,732 |
| 14 | 10 | 47–51 | 11.4–12.4 | 2,498–2,720 |
| 15 | 2 | 44 | 12.5–13.2 | 2,357–2,487 |
| 16 | 5 | 41–43 | 13.0–13.6 | 2,282–2,392 |
| 17 | 3 | 39–40 | 14.2–14.7 | 2,114–2,180 |
| 18 | 1 | 38 | 15.0 | 2,060 |

`dep`'s 24 requests at that point took 2,153–2,536 ms for their 32 tokens (median 2,236),
and `h37`'s 2,060–2,894 (median 2,510). Every request at that point sent the same
1,919-character text after its own request id, at temperature 0; replies differed between
requests in both configurations.

The slowest requests of either configuration were at the 128-token point: `dep` at 6.0
(rep 1) and 9.4 t/s (rep 5), `h37` at 10.7 (rep 2, 19 tokens accepted).

### Card, memory and residency

The residency sampler ran from 20:48 to 21:44 UTC, 3,354 samples with llama-server
running:

| Rep | Cell | Samples | VRAM-requested memory outside VRAM, max (MiB) | `amd-evicted-vram` (MiB) | Least VRAM free (MiB) | Junction max (°C) | Memory max (°C) | Busy samples at 96 MHz memory clock | Hottest DIMM max (°C) |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `dep` | 594 | 0 | 0 | 1,666 | 66 | 54 | 0 of 190 | 52 |
| 2 | `h37` | 520 | 0 | 0 | 1,852 | 74 | 58 | 1 of 105 | 52 |
| 3 | `h37` | 527 | 0 | 0 | 2,816 | 69 | 56 | 1 of 119 | 52 |
| 4 | `dep` | 592 | 0 | 0 | 1,641 | 65 | 54 | 0 of 179 | 53 |
| 5 | `dep` | 600 | 0 | 0 | 1,640 | 66 | 54 | 0 of 190 | 52 |
| 6 | `h37` | 517 | 0 | 0 | 2,076 | 73 | 56 | 0 of 116 | 52 |

During the decode of the 48 requests at the 512-token point (from first token to last):
- no sample had memory outside VRAM;
- power was 45–65 W for `dep` (median 60) and 48–79 W for `h37` (median 58);
- the core clock read 500 MHz in 63% of `dep`'s samples and 78% of `h37`'s;
- the memory clock read 1,000 MHz in every sample but one (456 MHz, `dep`, rep 5).

## Deviations

- **Attempt 1:** the run first started at 20:36 UTC. Its first rep (`dep`) measured both
  items, but the llama-benchy item's SLO evaluation failed with "no benchmark summaries
  found to evaluate": llama-benchy writes no summary file, and without `openai-direct`
  the item had none. The playbook failed and the driver restored the deployed env file
  at 20:46 UTC. `05ca985` makes the evaluator count a tool's `status.json` by its exit
  code. All six reps then ran from that commit. Attempt 1's folders
  (`20261010T203917Z-sweep-input-length`, `20261010T204224Z-baseline`) and samples
  (`residency-short-reply-attempt1.jsonl`) are not used.
- **Code:** the plan's commit is `a45136e`; the run used `05ca985`, which changes only
  the evaluator. The playbook records the commit in each llama-benchy item's
  `versions.json`.
- **Per-request detail:** llama-benchy records a decode rate per run, but no draft counts
  and no request times. Drafts, decode time and residency per request are from the
  input-length sweep only.
- **Duration:** 56 minutes against the expected 1 h 15 min.

## Conclusion

**512-token prompts, 32-token replies: the loss holds.** `h37` decoded at a median 12.35
t/s against `dep`'s 13.86 over three reps each (−10.9%). The difference, 1.51 t/s, is
larger than `dep`'s rep-to-rep spread (0.11) and `h37`'s (1.44), the latter by 0.07 t/s,
and every `h37` rep median was below every `dep` rep median. It is beyond the keep rule's
10% limit. Stage 3 of the prefill-slowdown record measured −20.2% at this point.

**4,096 tokens of context and a 512-token prompt, 32-token replies: within the spread.**
`h37` decoded at 13.16 t/s against 13.38 (−1.6%), with rep medians on both sides of
`dep`'s. Stage 3's −16.0% at this point did not repeat.

At the two preceding points, `h37` decoded 15.5% (128-token prompts) and 22.3% (512-token
prompts through llama-benchy) faster. First tokens came 3.2–3.5 times sooner at every
point.

At the 512-token point, `h37`'s decode rose with the tokens the head accepted, from
10.7–11.1 t/s at 12 of 32 to 15.0 at 18; it accepted a median 14 there and 18 at the
128-token point. No decode had memory outside VRAM, and the memory clock stayed at
1,000 MHz.

The prefill-slowdown record's verdict is unchanged. Whether to deploy is the owner's
decision.

**Not explained.** In stage 3, one 32-token reply that accepted 17 tokens took 4.1 s, and
one llama-benchy run at 4,096 + 512 decoded at 7.2 t/s. In this run, the longest `h37`
decode of 32 tokens took 2.9 s, and the slowest `h37` llama-benchy run at 4,096 + 512
decoded at 11.2 t/s.
