# Proxmox Homelab Scripts

Scripts for creating and operating Proxmox LXCs and VMs. Run provisioning scripts
on the Proxmox host as root; each accepts environment overrides and `--help`.

## Guests

Deployment recorded 2026-09-18:

| ID | Name | Service | Guide |
| --- | --- | --- | --- |
| CT 120 | `llamacpp` | Qwen3.6-35B-A3B on V620 `0000:03:00.0`, API `:1234` | [GPU runtime](pro-v620/README.md) |
| CT 121 | `hermes` | Hermes Agent using CT 120; gateway/API `:8642` | [Hermes](hermes/README.md) |
| CT 123 | `gpu2` | Qwen3.8-Flash-Next on V620 `0000:83:00.0`, API `:1234` | [Flash-Next](pro-v620/qwen38-flash-next/README.md) |
| CT 140 | `kb-rag` | Markdown KB hybrid search, REST + MCP `:8770` | [Retrieval service](kb-rag/README.md) |
| CT 200 | `bench-runner` | Disposable OpenAI-compatible endpoint benchmarks | [Benchmark runner](bench-runner/README.md) |
| VM 300 | `docker-host` | Docker + Compose; MealDeal `:4000`, work-board `:4100`, Project Planner `:4200`, Portainer `:9443` | [Docker host](docker-host/README.md) |

Both V620s have 32 GB VRAM and CPU-direct Gen4 x16 slots on the ROMED8-2T.
Each has a blower driven by [IPMI fan control](pro-v620/gpu-blower-control/README.md),
with [undervolting](pro-v620/undervolt/README.md) and a
[thermal watchdog](pro-v620/gpu-thermal-watchdog/README.md).

## Host storage

| Proxmox storage | Device | Holds |
| --- | --- | --- |
| `local`, `local-lvm` (thin) | Samsung 860 EVO 1 TB, SATA | Host root, templates, guest root disks |
| `models` (thin) | BIWIN NV7400 2 TB, NVMe Gen4 x4 | The shared GGUF store |
| `Synology-Backup` (NFS) | Synology NAS | Weekly vzdump archives |

[`create-models-store.sh`](pro-v620/create-models-store.sh) builds the GGUF store:
an LVM-thin pool on the whole NVMe, one ext4 volume `models/shared` mounted at
`/mnt/models`, and `/mnt/models/store`, which CT 120 and CT 123 both bind at
`/models`. Each GGUF is stored once, and survives `pct destroy`. It is not ZFS: the
ARC would cache the mmapped GGUFs a second time next to the page cache.

- A bind mount blocks `pct snapshot` for both containers. vzdump skips it.
- `llamacpp` is UID 1000 in both containers, so either one can write the store. Don't
  download the same file from both at once.
- The fstab entry uses `nofail`, so a missing NVMe does not stop the host booting:
  `store/` is then absent and both containers refuse to start instead of serving an
  empty `/models`. `nofail` also drops the mount's boot ordering, so the entry adds
  `x-systemd.before=pve-guests.service` to make guest autostart wait for it.
- Proxmox offers `models` as a target for guest disks. Keep them off it: the store
  volume takes nearly the whole pool, so another volume would overcommit it.

`df -h /mnt/models` shows current use.

## Provisioning

From a checkout on the Proxmox host:

```bash
./pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh
./hermes/create-lxc-hermes-agent.sh
DEPLOY_KEY_FILE=./cognitivestack-deploy ./kb-rag/create-lxc-kb-rag.sh
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

## Operations

- [Ansible orchestration](ansible/README.md): `make check`, `make bench`,
  `make context-sweep` from the repo root.
- [Token accounting](hermes/token-usage-collector/README.md): durable CT 120 and
  Hermes provider usage, collected inside CT 121.
- [Idea capture](hermes/idea-capture/README.md): Slack `#ideas` messages saved to the
  Project Planner board by a Hermes plugin on CT 121.
- [Host notifications](host-notifications/README.md): Proxmox events to Slack.
- [Docker stacks](docker-host/stacks/): Compose definitions; secrets are Portainer
  stack environment variables.

Keep downloaded models and generated results out of git. Guest networking and
backup requirements are in [CLAUDE.md](CLAUDE.md#host-networking-and-backups).

## VMID allocation

| Range | Purpose |
| --- | --- |
| 100–119 | Infrastructure/services |
| 120–139 | AI/LLM containers |
| 140–159 | Databases |
| 200–299 | Test/temporary containers |
| 300+ | VMs |

Docker apps share VM 300 and do not consume individual VMIDs.

## Reference recipes

- [RX 6700 XT](rx-6700-xt/README.md): prior GPU, LM Studio and llama.cpp variants.
- [B550 fan control](pro-v620/fan-control/README.md) and
  [GPU A/B harness](pro-v620/gpu-ab-bench/README.md): prior host platform.
- [Coder runner](coder-runner/README.md) and
  [Hermes loop config](hermes/config/README.md): retired on-box coding loop;
  CT 122 was removed and the loop moved to Multica.
- [llama-swap provisioner](pro-v620/create-lxc-llama-swap-gpu2.sh): retired CT 123
  runtime. CT 123 now serves Flash-Next directly.
