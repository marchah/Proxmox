# Qwen3.8-Flash-Next on Radeon Pro V620

Qwen3.8-Flash-Next (`qwen4exp`, 180B total / 6B active) uses four `UD-Q4_K_XL`
GGUF shards totaling 111.33 GB. Its PLE table and part of the routed experts stay
in system RAM. The deployment recorded 2026-09-18 is **CT 123 `gpu2`, one V620
at `0000:83:00.0`**, leaving CT 120's Qwen3.6 service on the other card.

## Shipped configurations

| Setting | CT 123: deployed | CT 120: two-card alternative |
| --- | --- | --- |
| Env file | `qwen38fn-gpu2.env` | `qwen38fn.env` |
| Binary tree | `b11018-baseline` (local build) | `llama-b11018` (release tarball) |
| GPUs | one, `0000:83:00.0` | both V620s |
| CPU expert layers | 34 | 16 |
| Tensor split | none | `30,18` |
| Context / parallel | 65536 / 1 | 65536 / 1 |
| Threads | 16 | 16 |
| Batch / ubatch | 4096 / 1024 | 1024 / 256 |
| KV / vision projector | q8_0 / CPU | q8_0 / CPU |
| API / alias | `:1234` / `qwen3.8-flash-next` | same |

Vulkan requires **b11013 or later** for the hyper-connection operations. A
registered `qwen4exp` architecture alone does not establish backend support.
The two b11018 trees report the same commit but have different binaries; use the
same tree on both sides of an A/B comparison.

## Deployment

Run from this directory on the Proxmox host as root. `install.sh` needs an
existing, running container with the `llamacpp` user, the selected binary and
sufficient RAM/disk. It installs the env, launcher and unit; it does not allocate
GPUs, resize the container or start serving. Add `--download` to start/resume the
model and projector download.

For the existing CT 123 deployment:

```bash
VMID=123 ENV_FILE=qwen38fn-gpu2.env ./install.sh --download
pct exec 123 -- journalctl -u qwen38fn-dl --no-pager -n 30
# Once all four shards and the projector are verified:
pct exec 123 -- systemctl restart llamacpp-qwen38fn
pct exec 123 -- systemctl status llamacpp-qwen38fn
curl http://gpu2:1234/v1/models
```

For the two-card CT 120 alternative:

```bash
VMID=120 ./install.sh --download
# After download verification:
./ct120-cutover.sh to-qwen38fn
./ct120-cutover.sh status
./ct120-cutover.sh to-qwen36
```

The cutover restarts CT 120, gives it both cards, stops CT 123 and clears CT 123's
`onboot`. Rollback restores the single-card workloads and CT 123's boot setting.
The watchdog map changes with the owning service. **Never give both containers
the same card**, including through automatic startup after a reboot.

The model service and container keep swap disabled. The CPU expert weights and
PLE table must stay resident. Recorded load times were 2m38s from cold SATA page
cache and 40–46s warm; tensor placement changes require a full reload.

## Response contract

The launcher sets `--reasoning off --reasoning-format auto`. This combination
returns clean content for bare chat and all tested effort values (`none`, `low`,
`medium`, `high`, `xhigh`). The probe's `--contract` mode checks that these requests
succeed and that no `<think>` tags leak into `content`.

With thinking enabled, the template accepts only `low`, `medium` and `xhigh`,
defaulting to `xhigh`. Revalidate clients before enabling it. Keep q8_0 KV paired
with reasoning disabled; local reasoning-enabled trials returned empty answers
with quantized KV. Moving the vision projector to CPU saves about 1.1 GiB VRAM
but costs image-encoding latency; text requests are unaffected.

## Placement

- `-ot per_layer_token_embd=CPU` moves the ~28.7 GB PLE lookup table to RAM.
- `--n-cpu-moe N` moves routed experts from the first N of 48 layers to RAM,
  freeing roughly 1.5 GiB per layer. Attention, shared experts, routers, norms
  and KV remain on GPU.
- `-ncmoe 48` still uses about 9.2 GiB on one card. `-ngl 0` moves the model
  path to CPU; a separate projector can still occupy GPU memory.
- A two-card setup needs an explicit split: CPU-expert layers are much lighter
  than the remaining layers. At batch/ubatch 1024/256, the measured starting
  rule is `card1_layers = N + (48 - N)/2 - 2`, with `48,0` for N=48.
  Recheck placement after changing batch size, context or projector placement.

Measure free VRAM and GTT together after a completion. Aggregate capacity does
not prove each card fits, and the startup guard does not catch spill. New
placements need at least 2048 MiB free on each card or an end-to-end load check
recording the minimum at the intended batch size. Do not use automatic context
fitting on this RADV setup.

## Placement measurements — 2026-09-18

These sweep results use **b11018-baseline, `schedutil`, 65536 context and
1024/256 batch/ubatch**. They are not measurements of every shipped binary/batch
combination. `d0` means a short prompt; `d8k` means an approximately 8k-token
prompt. Speeds are tokens/s; VRAM readings were taken after load and a completion.

| `-ncmoe` | split | KV / projector | card 1 | card 2 | total | headroom | decode d0 / d8k |
| ---: | --- | --- | ---: | ---: | ---: | --- | ---: |
| 15 | `29,19` | f16 / GPU | 31094 M | 32715 M | 62.3 G | 🔴 **SPILLED** at every split | — |
| **16** | `30,18` | **q8_0 / CPU** | 29848 M | 30843 M | **59.3 G** | tight (2.9/1.9 G free) | **14.17 / 13.45** |
| 16 | `30,18` | f16 / GPU | 31431 M | 31174 M | 61.1 G | tight (1.3/1.6 G free) | 14.16 / 13.07 |
| 20 | `32,16` | f16 / GPU | 28738 M | 27864 M | 55.3 G | fits (4.0/4.9 G free) | 13.03 / 12.06 |
| 28 | `36,12` | f16 / GPU | 23216 M | 21381 M | 43.6 G | fits (9.6/11.4 G free) | ~11.3 / ~10.6 |

**One card** (`--device Vulkan0`, no split), `q8_0` + projector on CPU:

| `-ncmoe` | VRAM used | free on that card | decode d0 / d8k | prefill 8k |
| ---: | ---: | ---: | ---: | ---: |
| **34** | **31100 M (30.4 G)** | 1668 M | **13.01 / 12.23** | 39.1 |
| 36 | 28097 M (27.4 G) | 4671 M | 12.43 / 11.81 | 37.1 |
| 40 | 22089 M (21.6 G) | 10679 M | 11.40 / 10.94 | 33.7 |
| 48 | **9443 M (9.2 G)** | **23.3 G** | 10.18 / 8.70 | 29.0 |

`-ncmoe 34` is the lowest validated one-card setting. Increasing it trades
throughput for spare VRAM. On two cards, 16 is the supported floor. At 15 with
q8_0 KV and a CPU projector, split `29,19` spilled (3256 / 89 MiB free).
Other splits at 15 remain unvalidated; estimated balanced headroom is about
1571 MiB/card, below the new-placement threshold.

### One versus two cards

Matched at `-ncmoe 34`, one card measured 13.01 / 12.23 t/s at d0/d8k versus
10.76 / 9.85 for two cards; prefill was 39.1 versus 38.9 t/s. This is consistent
with the QSA indexer's inter-GPU transfers described in llama.cpp #28699.
Remeasure after backend changes.

Using the second card for more GPU expert layers (`-ncmoe 16`) on the baseline
build at 131072 context measured 14.46 / 13.37 t/s and 77.2 t/s prefill. Against
one card at 34, this improves decode about 11% and nearly doubles prefill. An 8k
cold prompt took roughly **104s on two cards versus 205s on one** in these sweeps.
The one-card deployment preserves CT 120's faster endpoint for Hermes.

### Verification boundaries

- **CT 123, baseline binary, 4096/1024:** the deployment load check recorded
  28965 MiB used of 30704 MiB, 1739 MiB free, and 241 MiB GTT. The placement-table
  throughput above came from the smaller sweep batch.
- **CT 120, release binary, 1024/256:** this exact shipped combination has not
  had an end-to-end load check. Do not assign the baseline sweep's headroom to it.
- **CT 120, release binary, 4096/1024:** measured minimum free VRAM was
  2922 / 877 MiB, with GTT rising to 306 MiB on one card. That batch is not the
  shipped two-card setting. It measured 173–236 t/s prefill, but the comparison
  also changes the binary, so it does not isolate the batch-size effect.
- `-ncmoe 16`, split `31,17`, batch `4096/1024` is an unvalidated candidate.
  Measure both cards under load before adopting it.

### KV and context

At `-ncmoe 16`, split `30,18`, 65536 context on the baseline build:

| KV / projector | Decode d0 / d8k | Free VRAM, MiB |
| --- | ---: | ---: |
| f16 / GPU | 14.16 / 13.07 | 1305 / 1553 |
| q8_0 / CPU | 14.17 / 13.45 | 2881 / 1878 |

The combined q8_0/CPU-projector configuration saves about 1.6 GiB without a
measured text-speed penalty. This comparison changes two variables; it does not
isolate either effect. The q8_0 KV cache uses about 12 KiB/token versus 24 for f16
across the model's 12 full-attention layers.

Raising context to 131072 with **f16** spilled, reducing d8k decode from 13.07 to
10.34 t/s while prefill stayed near 77 t/s. With **q8_0 and CPU projector**, the
baseline build passed at 131072; that is a measured alternative, while the env
files ship 65536.

### Threads and concurrency

Baseline build, `-ncmoe 16`, split `30,18`, q8_0 KV and CPU projector.
`concurrency-probe.py` uses a different prompt set from the placement probe;
compare within this table.

| `--parallel` | `--threads` | `--ctx-size` | ctx/slot | per-stream t/s | aggregate t/s |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 32 | 65536 | 65536 | 13.22 | 13.22 |
| 1 | 16 | 65536 | 65536 | 14.09 | 14.09 |
| 1 | **8** | 65536 | 65536 | **14.25** | 14.25 |
| 2 | 32 | 65536 | 32768 | 10.23 | 20.46 |
| 2 | **16** | 65536 | 32768 | **11.05** | **22.10** |
| 4 | 32 | 65536 | 16384 | 7.67 | 30.46 |
| 4 | **16** | 65536 | 16384 | 7.73 | **30.88** |
| 4 | 8 | 65536 | 16384 | 7.38 | 29.37 |
| 4 | 32 | **131072** | **32768** | 7.66 | 30.52 |

Sixteen threads is the shipped compromise: close to eight for a solo request
and better at two/four concurrent streams. Four streams trade individual latency
for aggregate throughput. The 131072-context result was measured at 32 threads;
it does not independently validate every thread/context combination.

### Governor, load mode and CPU-only trials

- `schedutil` measured within 2% of `performance`; `powersave` parked the tested
  CPU at 1500 MHz and cost about 30% decode. Record governor and clocks for A/Bs.
- `--load-mode auto` measured 11.74 t/s and 14 MiB GTT in a matched trial;
  `none` measured 11.18 t/s and 31.6 GiB GTT. The shipped configs use auto.
- CPU-only text inference measured 6.04 / 5.51 t/s at d0/d8k, compared with
  10.18 / 8.70 for one card at `-ncmoe 48`. The CPU-only trial retained its GPU
  projector; use `--no-mmproj-offload` to free that allocation as well.

Device utilization and clock/concurrency trials suggest synchronization overhead
limits this hybrid configuration. A bytes/bandwidth estimate alone substantially
overpredicts its throughput. Output hashes were stable at d0, but occasionally
varied at depth even with greedy sampling; check content quality and use repeated
measurements at depth.

## Benchmark tools

`placement-sweep.sh` writes per-config JSON and `SUMMARY.md` under
`/root/qwen38-flash-next/sweep-<ts>/`. Run the thermal guard in a separate shell
before a manual sweep; the host watchdog only stops systemd services.

```bash
./thermal-guard.sh
```

In the sweep shell, after preparing the intended container/GPU configuration:

```bash
./placement-sweep.sh
NCMOE_LIST="20 28" DEPTHS="0,32000" ./placement-sweep.sh
ONE_GPU=true NCMOE_LIST="34 40 48" ./placement-sweep.sh
```

These experiments restart model servers. Check their container/device settings
before use. The B550 harness in `../gpu-ab-bench/` contains old PCI addresses;
this directory's guard targets the ROMED8-2T.

## MTP experiment

The [MTP patches](mtp-patches/README.md) are experimental and are not deployed.
Rebased onto b11018, the target-only server works, but both draft-head GGUFs
abort in `graph_mtp` → `build_hc_mix` with `GGML_ASSERT(ggml_can_repeat(b, a))`.
The MTP graph needs porting to b11018's `{n_embd, hc}` gamma layout. A successful
build or model load is insufficient validation.

`mtp-standalone.sh` provides the retry harness. Rebuild/revalidate the patched
binary before retrying; `MTP_SKIP_BUILD=true` is only for a compatible existing
build.

## Host memory baseline — 2026-09-17

`membench.sh` measured four populated DDR4-3200 channels (C/D/G/H). Keep that
placement; it was selected and validated for this board. Rerun the same harness,
including its thread sweep, when adding DIMMs.

| Threads | STREAM Copy | Scale | Add | Triad |
| ---: | ---: | ---: | ---: | ---: |
| 8 | 80.3 GB/s | 51.2 | 56.2 | 56.3 |
| 16 | 77.8 | 50.1 | 54.9 | 55.0 |
| 32 | 74.8 | 49.0 | 54.0 | 54.1 |

STREAM reports application bytes. Accounting for read-for-ownership gives
75.1 GB/s for Triad, close to the 76.4 GB/s `stressapptest` result. Copy peaked
at 80.3 GB/s, about 78% of four-channel theoretical bandwidth.

A random pointer chase over 4 GiB measured 141.36 ns/load with huge pages and
226.95 ns with 4 KiB pages. Report page configuration with latency: the latter
includes additional page-table work. These measurements do not isolate DIMM
packaging effects.

## Local validation

```bash
shellcheck -S warning ./*.sh ./llamacpp-serve-qwen38fn
python3 -m py_compile ./*.py
```
