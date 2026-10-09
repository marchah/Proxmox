# Qwen3.8-Flash-Next on Radeon Pro V620

Qwen3.8-Flash-Next (`qwen4exp`, 180B total / 6B active) uses four `UD-Q4_K_XL`
GGUF shards totaling 111.33 GB. Its PLE table and part of the routed experts stay
in system RAM. The deployment recorded 2026-09-18 is **CT 123 `gpu2`, one V620
at `0000:83:00.0`**, leaving CT 120's Qwen3.6 service on the other card.

## Shipped configurations

| Setting | CT 123: deployed | CT 120: two-card alternative |
| --- | --- | --- |
| Env file | `qwen38fn-gpu2.env` | `qwen38fn.env` |
| Binary tree | `llama-b11505` (release tarball) | `llama-b11505` (release tarball) |
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
Measurements live in the [test records](#test-records), each with its build and
hardware.

## Deployment

Run from this directory on the Proxmox host as root. `install.sh` needs an
existing, running container with the `llamacpp` user, the selected binary and
sufficient RAM/disk. It installs the env, launcher, reload helper and unit; it does
not allocate GPUs, resize the container or start serving. Add `--download` to
start/resume the model and projector download. Re-running it rewrites those files
from this directory; the running server picks them up at its next restart.

For the existing CT 123 deployment:

```bash
VMID=123 ENV_FILE=qwen38fn-gpu2.env ./install.sh --download
pct exec 123 -- journalctl -u qwen38fn-dl --no-pager -n 30
# Once all four shards and the projector are verified:
pct exec 123 -- systemctl restart llamacpp-qwen38fn
pct exec 123 -- systemctl status llamacpp-qwen38fn
curl http://gpu2:1234/v1/models
# Restart at another context/slot layout and wait until it serves; the benchmark
# batch uses this (`make bench GPU=2`):
pct exec 123 -- /usr/local/bin/llamacpp-qwen38fn-reload 65536 1
```

For the two-card CT 120 alternative, CT 120 serves the GGUFs CT 123 already verified,
since both containers bind the same [model store](../../README.md#host-storage). Add
`--download` only if the store lacks them, and never while CT 123's download runs:

```bash
VMID=120 ./install.sh
./ct120-cutover.sh to-qwen38fn
./ct120-cutover.sh status
./ct120-cutover.sh to-qwen36
```

The cutover restarts CT 120, gives it both cards, stops CT 123 and clears CT 123's
`onboot`. Rollback restores the single-card workloads and CT 123's boot setting.
The watchdog map changes with the owning service. **Never give both containers
the same card**, including through automatic startup after a reboot.

The cutover does not touch Hermes. CT 121's `/root/.hermes/config.yaml` names the
served model in `model.default` and the five `auxiliary.*.model` pins. Set all six
to the new alias in both directions, then restart `hermes`. llama-server ignores the
request's `model` field, so a stale id still gets answers. It only shows up as the
wrong model name in session and usage records.

The model service and container keep swap disabled. The CPU expert weights and
PLE table must stay resident. Tensor placement changes require a full reload, which
took 10–35 s on the cards and 55 s CPU-only from the NVMe store's page cache in the
2026-10-08 sweeps.

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
- `-ncmoe 48` still uses about 7.0 GiB on one card (b11505, q8_0 KV, projector on
  CPU). `-ngl 0` moves the model path to CPU; a separate projector can still occupy
  GPU memory.
- KV cache: the model has 12 full-attention layers, so q8_0 KV costs about
  12 KiB/token against 24 for f16.
- A two-card setup needs an explicit split: CPU-expert layers are much lighter
  than the remaining layers. At batch/ubatch 1024/256, the starting rule found on
  b11018 is `card1_layers = N + (48 - N)/2 - 2`, with `48,0` for N=48. On b11505
  it held without spill at N=16 (`30,18`, 1024/256) and N=34 (`39,9`, 4096/1024)
  ([configurations record](runs/2026-10-08-configurations.md)). Recheck placement
  after changing build, batch size, context or projector placement.

Measure free VRAM and GTT together after a completion. Aggregate capacity does
not prove each card fits, and the startup guard does not catch spill. New
placements need at least 2048 MiB free on each card or an end-to-end load check
recording the minimum at the intended batch size. Do not use automatic context
fitting on this RADV setup.

## Test records

Plans and results of each test campaign, per [TEST-RECORDS.md](../TEST-RECORDS.md).

| Date | Build | Backend | Record | Status |
| --- | --- | --- | --- | --- |
| 2026-10-08 | b11505 | Vulkan, Mesa 26.2.4 | [`--moe-cache-mib` on one V620](runs/2026-10-08-moe-cache.md) | done |
| 2026-10-08 | b11505 | Vulkan, Mesa 26.2.4 | [Standard configurations on eight channels](runs/2026-10-08-configurations.md) | done |
| 2026-10-08 | b11505 | Vulkan, Mesa 26.2.4 | [Context depth and KV type on one card](runs/2026-10-08-kv-context.md) | done |
| 2026-10-08 | b11505 | Vulkan, Mesa 26.2.4 | [Threads and concurrent streams on one card](runs/2026-10-08-threads-concurrency.md) | done |
| 2026-10-08 | b11505 | Vulkan, Mesa 26.2.4 | [Cold load modes on one card](runs/2026-10-08-load-modes.md) | planned |
| 2026-10-08 | b11505 | Vulkan, Mesa 26.2.4 | [What each configuration uses, rerun with telemetry](runs/2026-10-08-utilization.md) | planned |
| 2026-10-08 | b11505 | Vulkan, Mesa 26.2.4 | [The two cards compared, with `-ncmoe 34` on each](../runs/2026-10-08-card-ab.md) | planned |

## Benchmark tools

Stage this directory on the host with [`../push-harness.sh`](../push-harness.sh) and
run it from `/root/harness/<sha12>/pro-v620/qwen38-flash-next/`; the sweep refuses an
unstaged copy unless `UNPINNED=true`. `placement-sweep.sh` writes per-config JSON,
`environment.json` and `SUMMARY.md` under `/root/qwen38-flash-next/sweep-<ts>/`. It
reads VRAM from the cards in the container's config, records each cell's server
command line, load time, container memory, hottest DIMM, and per-phase GPU and CPU use
(prefill, decode, concurrent streams), and on exit restores the container's env file and
restarts the service if it was running.

Run the thermal guard in a separate shell first; the host watchdog only stops systemd
services. `VMID=<ct>` limits it to that container's cards and acts only inside that
container. On a trip it writes `/root/qwen38-flash-next/THERMAL_TRIP`: the sweep then
starts no further cell, leaves the server stopped, and refuses to start until the file
is removed after cooling is checked.

```bash
VMID=123 ./thermal-guard.sh
```

In the sweep shell, after preparing the intended container/GPU configuration, pass a
cells file: one cell per line, a label then `KEY=value` settings. The script's header
lists the keys: device mode (`2gpu`, `1gpu`, `cpu`), CPU expert layers, cache, split
mode, batch, threads, KV type, context, slots, load mode and extra arguments, plus a
cell's own `DEPTHS`, `STREAMS`, which adds a `concurrency-probe.py` run with that many
streams, and `DEVICE`, the card a one-GPU cell runs on. `CONFIGS`, a list of `NCMOE[:CACHE]` entries, is the short form.

```bash
VMID=123 CELLS=runs/2026-10-08-threads-concurrency.cells DEPTHS="0,8000" ./placement-sweep.sh
VMID=123 CONFIGS="34 40 48" ./placement-sweep.sh
```

`PROBE_CLASSES` limits the prompt classes, and `DROP_CACHES=true` drops the host page
cache before every load, for cold loads. A depth is the probe's target: its filler gives
about 0.72 prompt tokens per unit (d8000 is ~5.8k tokens), and `SUMMARY.md` prints the
measured sizes. Every cell is checked before the first load; a cell that fails to load
is recorded and the sweep moves on. No cell starts while the hottest DIMM is above
`DIMM_START_MAX_C` (58 °C), and a cell with a DIMM sample at 66 °C, where the BMC caps
memory bandwidth to a third, is flagged invalid in `SUMMARY.md`.

These experiments restart model servers. Check their container/device settings
before use. The B550 harness in `../gpu-ab-bench/` contains old PCI addresses;
this directory's guard targets the ROMED8-2T.

## MoE expert cache

`--moe-cache-mib N` (llama.cpp #29887, in b11505) keeps an LRU cache of the
experts `--n-cpu-moe` leaves in RAM on the GPU, uploads only misses, and runs
those layers' expert matmuls on the GPU. It serves batches of up to 32 tokens,
so decode; prefill keeps the CPU path. Upstream measured 1.57–2.20× decode on
Qwen3.8-Flash-Next Q4_0 with CUDA, the largest gain with every expert on the CPU
and an 18.6 GB cache. On one V620 it runs, but every cache configuration measured
decoded slower than `-ncmoe 34` without one, at 4.3–7.3 against 13.6 t/s
([2026-10-08 record](runs/2026-10-08-moe-cache.md)). The serve script passes
`MODEL_MOE_CACHE_MIB`; the shipped configs leave it empty.

`placement-sweep.sh` measures it through `CONFIGS`, a list of `NCMOE[:CACHE]`
entries; the [2026-10-08 record](runs/2026-10-08-moe-cache.md) holds the run.

- `auto` starts the placement without a cache, runs one code prompt at the deepest
  probed depth through the probe, and sizes the cache to the lower of the free VRAM
  right after load and after that prompt, minus `CACHE_MARGIN_MIB` (default 1024). At
  `-ncmoe 34` those read 2,076 and 2,154 MiB, and the probe's other prompts change
  neither; a synthetic 3k request read 2,229 and oversized the cache. Each cell also
  reads VRAM and GTT after its probe and is flagged as a possible spill if GTT grew by
  more than 256 MiB.
- `leaveM` uses the same measurement and leaves M MiB free instead, e.g. room for a
  second model: `48:leave12288`.
- RADV limits one allocation to 4 GiB, and the cache keeps each expert tensor type
  in one buffer, so the cache is capped well below free VRAM: at `-ncmoe 48` about
  11.3 GB loads and 13 GB does not. An unallocatable cache aborts at load on a
  scheduler assertion under llama-server's default fit check, and with `--fit off`
  fails with `failed to allocate the MoE cache buffers`.
- Each extra CPU layer frees ~1.56 GB for the cache, so `34`, `40` and `48`
  compare the same VRAM spent on whole layers or on cached experts.
- The cache's size and hit-rate lines are library INFO, which this build logs only
  at `-lv 4`; a sweep with a cache sets it for every cell. The hit rate is logged
  when the server stops, which the sweep does after each cell.
- A cache needs a one-card container; the sweep refuses otherwise.
- At `-ncmoe 48` about 104 GB (97 GiB) of weights stay in host RAM, PLE included,
  against CT 123's 120 GiB memory limit.
- The rows read with the DIMM column: the CPU-side layers depend on memory
  bandwidth, which the BMC caps at 66 °C.

## MTP experiment

Upstream merged a qwen4exp MTP graph in llama.cpp #29761, included in b11475. Whether
b11505 loads unsloth's separate qwen4exp heads is untested. Unsloth's `MTP/README.md`
predates #29761 and says stock builds cannot use them, but on 2026-10-06 unsloth copied
the self-contained `mtp-Qwen3.8-Flash-Next-Q8_0.gguf` to the repo root for `llama.cpp -hf`.
The `shared-` heads borrow the main model's embedding and output tensors.

`qwen38fn-download.sh` fetches the self-contained Q8_0 and Q4_K_M heads, re-exported
upstream on 2026-10-05, and the 2026-09-01 `shared-Q4_K_M` head. That re-export changed
only the self-contained heads; the UD-Q4_K_XL shards are unchanged. MTP is not deployed.

The [MTP patches](mtp-patches/README.md) and `mtp-standalone.sh` are the earlier
b11018 attempt, which aborted in `graph_mtp` → `build_hc_mix` with
`GGML_ASSERT(ggml_can_repeat(b, a))`.

## Host memory bandwidth — 2026-10-08

`membench.sh` on all eight DDR4-3200 channels: 8 × 64 GB `M393A8K40B22-CAE` 3DS
RDIMMs, kernel `7.0.14-22-pve`, `schedutil` governor, guests running but idle. BIOS:
NPS1, memory interleaving Auto, APBDIS Auto, DF C-states enabled. STREAM 5.10, built
with `gcc -O3 -march=native -fopenmp` and three 8 GB arrays, reports the best of 20
passes.

| Threads | Copy | Scale | Add | Triad |
| ---: | ---: | ---: | ---: | ---: |
| 8 | 151.0 GB/s | 96.3 | 107.5 | 107.5 |
| 16 | 152.7 | 97.3 | 106.4 | 106.6 |
| 32 | 148.6 | 95.4 | 104.3 | 104.4 |
| 64 | 141.9 | 94.1 | 103.6 | 103.6 |

Copy peaks at 75% of the 204.8 GB/s
theoretical bandwidth. STREAM reports application bytes; counting
read-for-ownership, Triad moves about 143 GB/s. Untested settings that can add
bandwidth: NPS4, APBDIS 1 with SOC P-state P0, DF C-states disabled, and a STREAM
build with non-temporal stores, which removes the read-for-ownership traffic.

A random pointer chase with huge pages measured 116.45 ns/load over 256 MiB and
123.86 ns over 4 GiB. Report page configuration with latency: 4 KiB pages add
page-table walks.

### DIMM thermal throttle

When the hottest DIMM reads 66 °C on the BMC (`TEMP_CPU1_DDR4A`–`H`), memory
bandwidth drops to about a third: STREAM Copy 52.7 GB/s, Triad 38 GB/s. It stays
there until the hottest DIMM cools to about 62–63 °C, and idle latency rises from
116 to 128 ns meanwhile. The BMC firmware names this event "DIMM throttling
(bandwidth capping)", asserted on the DIMMs' `EVENT_L` line. BIOS setup exposes no
trip point, and the OS cannot read or change it: after boot no device answers at
the DIMM sensor or SPD addresses on any host SMBus port, because the BMC owns that
bus. Nothing is logged: the SEL, EDAC and the kernel log stay silent.

[`membench-sustained.sh`](membench-sustained.sh) reruns the 16-thread STREAM
back to back and logs every pass beside the DIMM temperatures and each guest's
CPU time. Under the BMC's previous fan curve, 70% duty at 65 °C, it throttled
after three minutes. FAN1–FAN3 at full speed hold the DIMMs at 64–65 °C under the
same load, so the BMC curve (open-loop table 1, driven by the CPU and all eight
DIMM sensors) now reaches 100% at 58 °C:

| °C | 30 | 40 | 45 | 50 | 55 | 58 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| FAN1–FAN3 duty | 30% | 35% | 45% | 60% | 80% | 100% |

With that curve, an hour of back-to-back passes (2026-10-08 07:11–08:12, guests
idle, case top open from 07:29) ran 172 of 175 passes at full speed, Copy ~151 GB/s
and Triad ~105.5 GB/s. At 08:05 DIMM F reached 66 °C just after CT 120 served a
request, and three passes, about two minutes, ran capped at 53 GB/s. ⚠️ At full fan
speed the hottest DIMM settles at 64–65 °C, so the curve alone does not prevent the
cap under sustained full-bandwidth load; more margin needs airflow aimed at the DIMMs.
Read DIMM temperatures alongside any CPU-offload throughput measurement.

## Local validation

```bash
shellcheck -S warning ./*.sh ./llamacpp-serve-qwen38fn ./llamacpp-qwen38fn-reload
python3 -m py_compile ./*.py
```
