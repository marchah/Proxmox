# Proxmox LLM lab

Configuration and measurements for a Proxmox server that runs local LLMs on two AMD Radeon
Pro V620s. Each provisioner creates or configures one container, VM or host service; each
number below comes from a test record in this repo, labelled with its build, hardware and
settings.

## Hardware

| Part | Installed |
| --- | --- |
| Board | ASRock Rack ROMED8-2T: seven PCIe 4.0 x16 slots, all CPU-direct; AST2500 BMC |
| CPU | AMD EPYC 7532, 32 cores / 64 threads |
| Memory | 512 GB DDR4-3200 ECC, 8 × 64 GB 3DS RDIMMs, one per channel |
| GPUs | 2 × Radeon Pro V620 (Navi 21, gfx1030), 32 GB each, on CPU-direct Gen4 x16 slots |
| Cooling | A 9733 blower per V620, driven over IPMI ([gpu-blower-control](pro-v620/gpu-blower-control/README.md)) |
| Storage | Samsung 860 EVO 1 TB SATA (host and guest disks); BIWIN NV7400 2 TB NVMe (the model store) |

The server moved to this board on 2026-09-16. Before that, an MSI MAG B550 Tomahawk Max with a
Ryzen 5 5600 ran a Radeon RX 6700 XT ([rx-6700-xt/](rx-6700-xt/README.md)), and then the two
V620s ([fan-control/](pro-v620/fan-control/README.md), [gpu-ab-bench/](pro-v620/gpu-ab-bench/README.md)).

## What each GPU serves

| Card | Container | Model | Engine |
| --- | --- | --- | --- |
| GPU 1, `0000:03:00.0` | CT 120 `llamacpp` | Qwen3.6-35B-A3B (35B total, 3B active), Unsloth UD-Q5_K_XL with its MTP head | llama.cpp on Vulkan (RADV), 262k context in two slots ([pro-v620/](pro-v620/README.md)) |
| GPU 2, `0000:83:00.0` | CT 125 `ds41-strata`, since 2026-10-31 | DeepSeek-V4.1-Flash-1017, Unsloth UD-Q4_K_XL with the DSpark drafter | Strata's `strata-dsv41` on ROCm 10.1, 256K context ([ds41/](pro-v620/ds41/README.md)) |

From 2026-09-18 GPU 2 served Qwen3.8-Flash-Next (180B total, 6B active) from CT 123, with
part of the experts in system RAM ([qwen38-flash-next/](pro-v620/qwen38-flash-next/README.md)).
CT 123 is stopped while CT 125 holds the card.

### GPU 1: Qwen3.6-35B-A3B

Measured 2026-09-22 on GPU 1 with llama.cpp b11018 Vulkan and the shipped flags (the MTP head
drafting 3 tokens, q8_0 KV, 262k context, two slots), at a −100 mV offset and the `schedutil`
governor. 512 output tokens, medians of 3 interleaved repetitions
([spec-ab/](pro-v620/spec-ab/README.md)):

| Workload | Without MTP (f16 KV) | Shipped |
| --- | ---: | ---: |
| One stream: code / JSON / tool call, t/s | 78 / 79 / 77 | 117 / 136 / 137 |
| One stream: prose, t/s | 78 | 92 |
| One stream at 16k / 48k depth, t/s | 71 / 64 | 99 / 87 |
| Two streams, total t/s: code / JSON / prose | 115 / 115 / 115 | 140 / 159 / 117 |
| Cold prefill at 16k / 48k, t/s | 1,020 / 527 | 1,346 / 917 |

The cards now run at stock voltage ([below](#findings)), and CT 120 runs b12239.

### GPU 2

DeepSeek-V4.1-Flash's measurements live with the gfx1030 build of Strata's engine, in
[marchah/strata-v620](https://github.com/marchah/strata-v620) (private).

Qwen3.8-Flash-Next on GPU 2, 2026-10-16: Strata v0.1.44.1 decoded 49.2 t/s and read a
23k-token prompt at 1,008 t/s, against 18.2 and 340 for CT 123's llama.cpp configuration.
That was chat mode with 256-token replies, `--spec 5` and `STRATA_MMQ_KQ=1`. With both cards
in a layer split, Strata decoded 59.7 t/s and read the prompt at 1,423 t/s
([record](pro-v620/qwen38-flash-next/runs/2026-10-16-strata.md#stage-8-against-llamacpp)).

### The earlier RX 6700 XT

Qwen3.5-9B Q4_K_M on llama.cpp b9828 Vulkan, 64k context in four slots: 56 t/s for one
stream and about 80 t/s total at four concurrent streams. LM Studio on the same card managed
53 and about 47, and returned garbage on cold prompts past about 6k tokens
([rx-6700-xt/](rx-6700-xt/README.md#benchmarks)).

## Findings

- **An undervolt can corrupt results silently.** At −100 mV, repeated perplexity runs on both
  V620s disagreed with each other under prefill load, with no sign from the kernel or the
  output; every run at 0 mV was bit-identical (2026-10-01, llama.cpp b11018 Vulkan,
  Qwen3.6-35B-A3B on wikitext-2). −100 mV had passed a full load batch without a GPU fault.
  Both cards run at stock voltage; qualify any offset with repeated perplexity runs
  ([undervolt/](pro-v620/undervolt/README.md)).
- **Vulkan or ROCm depends on the workload.** On llama.cpp b11018, in a passthrough VM with
  `amdgpu-dkms` 7.1.3, ROCm 10.0 decoded Qwen3.6-35B-A3B 12–17% slower than Vulkan but
  prefilled up to 23% faster at 32k (2026-10-01). A dense coder, Qwen3.8-27B UD-Q4_K_XL with
  its MTP head in one 128k slot, finished a 126k-token coding-agent session 24% sooner on
  ROCm, 12.8 against 16.9 min (2026-10-02): a coding agent prefills far more than it
  generates ([rocm-ab/](pro-v620/rocm-ab/README.md)).
- **Memory bandwidth depends on DIMM cooling.** STREAM Copy reaches 152.7 GB/s on all eight
  channels, 75% of the theoretical 204.8 GB/s, and drops to a third when a DIMM reaches 66 °C
  ([memory bandwidth](pro-v620/qwen38-flash-next/README.md#host-memory-bandwidth--2026-10-08)).
- **The two cards are not interchangeable for measurements.** Under `llama-bench` (b11505,
  Mesa 26.2.4, 2026-10-08), GPU 2 ran Qwen3.6-35B-A3B 3.4–4.8% slower in prefill and 1.1–1.3%
  slower in decode, at about 115 MHz lower sclk with the same limits
  ([record](pro-v620/runs/2026-10-08-card-ab.md)).

## How it is measured

- **Endpoint benchmarks** run from a disposable container, CT 200
  ([bench-runner/](bench-runner/README.md)), against any OpenAI-compatible `/v1` endpoint:
  regression items, plus agent-session and document-ingestion workloads on real repository
  text. `make bench` drives them through [Ansible](ansible/README.md) and writes
  `REPORT.md` and `SLO.md`; [BENCHMARKS.md](bench-runner/BENCHMARKS.md) has the workloads and
  schemas.
- **Each test campaign gets a record**, committed as a plan before the run and completed
  after it ([TEST-RECORDS.md](pro-v620/TEST-RECORDS.md)). The code runs pinned to a commit, and
  the environment (build and checksum, backend, kernel, firmware, card identity, power,
  DIMMs, the server's command line) is captured, not typed.
- **Comparisons are interleaved**, with at least three repetitions, matched model hashes,
  binary, prompts, depth and power settings, and every guest the test does not use shut down.
  Output correctness is checked alongside speed, a speculative-decoding test includes a
  control without it, and each phase reports power, clocks and CPU use.

## Component guides

| Guide | Covers |
| --- | --- |
| [pro-v620/](pro-v620/README.md) | The V620s: passthrough, CT 120's provisioner and settings, recovery after a DRM renumber |
| [qwen38-flash-next/](pro-v620/qwen38-flash-next/README.md) | Qwen3.8-Flash-Next: CPU/GPU placement, CT 123, the two-card alternative, memory bandwidth |
| [strata/](pro-v620/strata/README.md) | The Strata engine on HIP (ROCm 10.0) beside llama.cpp in CT 123 |
| [ds41/](pro-v620/ds41/README.md) | CT 125 and CT 126: DeepSeek-V4.1-Flash on Strata's engine and on llama.cpp, and moving GPU 2 between containers |
| [glm53-flash/](pro-v620/glm53-flash/README.md), [maya/](pro-v620/maya/README.md), [mimo-v26-pro/](pro-v620/mimo-v26-pro/README.md) | GLM-5.3-Flash and MiMo-V2.6-Pro-RL: tested, not deployed |
| [spec-ab/](pro-v620/spec-ab/README.md) | Speculative decoding on CT 120: MTP, draft length, DFlash |
| [rocm-ab/](pro-v620/rocm-ab/README.md) | Vulkan against ROCm in a passthrough VM |
| [undervolt/](pro-v620/undervolt/README.md), [gpu-blower-control/](pro-v620/gpu-blower-control/README.md), [gpu-thermal-watchdog/](pro-v620/gpu-thermal-watchdog/README.md) | Power, fans, and the watchdog that stops a service at 102 °C junction / 101 °C memory |
| [bench-runner/](bench-runner/README.md), [ansible/](ansible/README.md) | The benchmark suite and its orchestration |
| [docker-host/](docker-host/README.md) | A Debian VM with Docker, Compose and Portainer |
| [host-notifications/](host-notifications/README.md) | Proxmox notifications to Slack |
| [rx-6700-xt/](rx-6700-xt/README.md), [fan-control/](pro-v620/fan-control/README.md), [gpu-ab-bench/](pro-v620/gpu-ab-bench/README.md) | The earlier B550 platform |

## Guests

| ID | Name | Service | Guide |
| --- | --- | --- | --- |
| CT 120 | `llamacpp` | Qwen3.6-35B-A3B on GPU 1, API `:1234` | [pro-v620/](pro-v620/README.md) |
| CT 123 | `gpu2` | Qwen3.8-Flash-Next on GPU 2, API `:1234`; stopped while CT 125 or CT 126 holds the card | [qwen38-flash-next/](pro-v620/qwen38-flash-next/README.md) |
| CT 125 | `ds41-strata` | DeepSeek-V4.1-Flash on upstream Strata's engine (`strata-dsv41`), API `:1234` | [ds41/](pro-v620/ds41/README.md) |
| CT 126 | `ds41-llama` | DeepSeek-V4.1-Flash on llama.cpp, the comparison engine; started only for a run | [ds41/](pro-v620/ds41/README.md) |
| CT 200 | `bench-runner` | Disposable OpenAI-compatible endpoint benchmarks | [bench-runner/](bench-runner/README.md) |

| VMID range | Purpose |
| --- | --- |
| 100–119 | Infrastructure/services |
| 120–139 | AI/LLM containers |
| 140–159 | Databases |
| 200–299 | Test/temporary containers |
| 300+ | VMs |

## Host storage

| Proxmox storage | Device | Holds |
| --- | --- | --- |
| `local`, `local-lvm` (thin) | Samsung 860 EVO 1 TB, SATA | Host root, templates, guest root disks |
| `models` (thin) | BIWIN NV7400 2 TB, NVMe Gen4 x4 | The shared GGUF store |
| `Synology-Backup` (NFS) | A NAS share | Weekly vzdump archives |

The GGUF store is an LVM-thin pool on the whole NVMe holding one ext4 volume,
`models/shared`, sized to the whole pool and mounted at `/mnt/models`. CT 120 and
CT 123 both bind `/mnt/models/store` (owned by UID 1000) at `/models`; the unprivileged
CT 125 and CT 126 bind it read-only. Each GGUF is
stored once, and survives `pct destroy`. It is not ZFS: the ARC would cache the
mmapped GGUFs a second time next to the page cache. Its `/etc/fstab` entry:

```text
/dev/models/shared /mnt/models ext4 defaults,noatime,nofail,x-systemd.before=pve-guests.service 0 2
```

- A bind mount blocks `pct snapshot` for both containers. vzdump skips it.
- `llamacpp` is UID 1000 in both containers, so either one can write the store. Don't
  download the same file from both at once.
- The fstab entry uses `nofail`, so a missing NVMe does not stop the host booting:
  `store/` is then absent and both containers refuse to start instead of serving an
  empty `/models`. `nofail` also drops the mount's boot ordering, so the entry adds
  `x-systemd.before=pve-guests.service` to make guest autostart wait for it.
- Proxmox offers `models` as a target for guest disks. Keep them off it: the store
  volume takes the whole pool, so another volume would overcommit it.

`df -h /mnt/models` shows current use.

## Provisioning

Run provisioning scripts on the Proxmox host as root; each accepts environment overrides
and `--help`. From a checkout on the host:

```bash
./pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh
./bench-runner/create-lxc-bench-runner.sh
./docker-host/create-vm-docker-host.sh
```

Flash-Next installs into an existing container; use its
[deployment guide](pro-v620/qwen38-flash-next/README.md#deployment).
GPU folders own their model/runtime assumptions, including passthrough, memory
sizing and flags. Read the component guide before provisioning.

Provisioners also support running directly from GitHub, for example:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/marchah/Proxmox/main/bench-runner/create-lxc-bench-runner.sh)"
```

`make check`, `make bench` and `make context-sweep` run from the repo root
([Ansible](ansible/README.md)). Keep downloaded models and generated results out of git.
