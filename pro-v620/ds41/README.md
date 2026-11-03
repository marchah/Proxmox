# DeepSeek-V4.1-Flash containers (CT 125, CT 126)

Two unprivileged LXCs run DeepSeek-V4.1-Flash-1017 engines on GPU 2 (`0000:83:00.0`). One
of them holds the card at a time, and Flash-Next on CT 123 is stopped meanwhile. Since
2026-10-31 CT 125 serves the model. Its engine is upstream
[Strata](https://github.com/Niko1221/Strata)'s `strata-dsv41` with the gfx1030 patches of the
private fork [marchah/strata-v620](https://github.com/marchah/strata-v620). That repository
holds the builds, the serving settings, the measurements and the host scripts for runs:
`docs/V620-BASELINE.md` and `tools/v620/`. This directory creates the containers and moves
GPU 2 between them and CT 123.

The containers were created on 2026-10-27 to compare upstream Strata's engine with
llama.cpp on the same file (strata-ds41 #211). The strata-ds41 fork and its development
container, CT 124, were retired on 2026-11-02.

| CT | Hostname | Runs | Guest firewall |
| --- | --- | --- | --- |
| 125 | `ds41-strata` | `strata-deepseek.service`: Strata's server (`serve/server.py`) with `strata-dsv41`, UD-Q4_K_XL with the DSpark drafter and the vision tower, 256K context, OpenAI-compatible API on `:1234`, no API key | None: it serves the LAN |
| 126 | `ds41-llama` | llama.cpp, the comparison engine; started only for a run | SSH in from the LAN; out, DNS to the router and the internet |

The guest rules apply only while the datacenter firewall is on, and it stays off.

## Create

On the Proxmox host, as root:

```bash
./create-lxc-ds41-engine.sh strata   # CT 125
./create-lxc-ds41-engine.sh llama    # CT 126
./ds41-host.sh take 125              # GPU 2, its memory and autostart
```

| Setting | Value |
| --- | --- |
| Template | The newest build of Ubuntu 24.04's standard template (`UBUNTU_RELEASE`) |
| ROCm | The newest `amdrocm-core-dev<series>-gfx1030` in AMD's repository, from the path for the container's Ubuntu release; under `/opt/rocm/core-<series>`, on every login's paths. A re-run keeps the newest series a container has; a newer series installs beside it by hand (`apt-get install amdrocm-core-dev<series>-gfx1030`). |
| CPUs | `lxc.cgroup2.cpuset.cpus: 8-31,40-63` (cores 8-31 and their SMT siblings), `cores: 48`, the same set in both. Strata's engine pins one thread per physical core. CT 120 and CT 121 keep cores 0-7: Proxmox's balancer moves `cores` guests off the CPUs of a running container with its own cpuset. |
| Memory | 64 GiB without GPU 2; `take` raises it (see below); swap 0 |
| Disk | 100 GB on `local-lvm` |
| Mounts | `/models` (the model store, read-only), `/models-dev` (`/mnt/models/store/dev`, writable), `/owner-telemetry` (`/mnt/ds41-telemetry`, read-only) |
| Limits | `lxc.prlimit.memlock: unlimited`: both engines page-lock host memory |
| User | `agent`, passwordless sudo inside the container, groups `video` and `render`; key-only SSH with the other container's authorized keys plus `AGENT_SSH_PUBKEY`. No GitHub credentials: results come back through `/models-dev`. |
| MAC | `BC:24:11:C0:DE:` and the VMID's last two digits (`:25`, `:26`), reserved on the router |

`/mnt/ds41-telemetry` is a host tmpfs, where a start gate publishes host telemetry to the
container. The provisioner refuses to run without it; `/etc/fstab` holds:

```
tmpfs /mnt/ds41-telemetry tmpfs size=64m,mode=0755,nosuid,nodev,noexec,x-systemd.before=pve-guests.service 0 0
```

`dpkg -l 'amdrocm-core-dev*'` in a container shows its ROCm series. CT 125 and CT 126 have 10.1.0-3
beside 10.0.0-4, both held, and both run 10.1: their profiles and `/opt/rocm/*` alternatives name
`/opt/rocm/core-10.1`, CT 125 since 2026-11-02 (with its service unit and engine build) and CT 126 since
2026-11-03 (with a llama.cpp build for 10.1). `rocm-smi` and the profiler tools come only with 10.0 and stay on
it. strata-v620's baseline, "ROCm 10.1", has the measurements; its builds carry their series as `DT_RPATH`,
because the two series share sonames, and a 10.0 build without one needs
`LD_LIBRARY_PATH=/opt/rocm/core-10.0/lib` to run on 10.0.

Engine builds and CT 125's service come from strata-v620 (`tools/v620/build-strata.sh`,
`build-llama.sh`, `build-tree.sh`, `serving.env`). Without GitHub credentials, engine commits
come in as `git bundle`s (`build-tree.sh`). CT 125's server config lives in CT 125 only, in
`/home/agent/strata-serve/deepseek41.json`; strata-v620's baseline, "Serving on one V620
(CT 125, from 2026-10-31)", records how it was set up.

## GPU 2: `ds41-host.sh`

```bash
./ds41-host.sh take <125|126>   # GPU 2 to that container
./ds41-host.sh restore          # both off the card; CT 123 started on GPU 2
./ds41-host.sh status
```

`take` stops CT 123 and turns its autostart off, and releases the other DeepSeek container:
stopped, autostart off, 64 GiB, no GPU entries. It maps GPU 2 to `<ct>:@container` in the
thermal watchdog, then passes `/dev/kfd` and GPU 2's render and card nodes into the
container at their real names, denies GPU 1's DRM nodes in its device cgroup, sets its memory
and autostart, and checks that ROCm lists exactly one GPU. A container that already holds the
card keeps running. The released container can be started by hand for CPU work.

Without the deny rules, KFD reports GPU 1 as well, and ROCm 10 fails with `Failed to set mem
policy for GPU` ([Strata README](../strata/README.md)).

Both directions keep the lab's invariants, across a host reboot too: no two containers own a
card, only the card's owner starts at boot, and the watchdog maps each card to the workload
on it. CT 123's onboot and the watchdog map from before the first `take` live in
`/root/ds41/`, and `restore` puts them back. `take` refuses while CT 120 holds GPU 2 or a
DeepSeek container holds GPU 1. `use-engine.sh`, `ct123-test-host.sh` and `ct120-cutover.sh`
refuse to change the cards while CT 125 or CT 126 holds one.

`ds41-host-test.sh` runs `ds41-host.sh` against a mocked host.

strata-v620's `tools/v620/host/` scripts run on pve from `/root`, the `host-*.sh` ones as
`/root/ds41-211-host-*.sh`:

- `host-to-125-2gpu.sh` gives CT 125 GPU 1 as well, with CT 120 stopped, and maps both
  cards to `125:@container`. `take` refuses while CT 125 holds GPU 1.
- `host-restore.sh` ends a two-card run: GPU 2 only for CT 125, GPU 1 back to CT 120, which
  it starts. It also writes GPU 1's deny rules into CT 126, which does no harm.
- `ds41-211-gate.sh` gates every full-model run: the other DeepSeek container stopped, the
  target holding GPU 2, the watchdog mapping GPU 2 to it, and the host memory reserves.

### Memory

`take` sets the container's limit to what the other running guests leave, after a 16 GiB
host reserve: 474,679 MiB with CT 120 (16 GiB) and CT 121 (8 GiB) running, as on
2026-11-02. Keep an engine's own memory limit below the container's.

## Model files

In the store (`/mnt/models/store/hf/`, `/models/hf/` in the containers), with the download
scripts in strata-v620's `tools/v620/host/` (each checks size and SHA-256):

| Directory | File | Use |
| --- | --- | --- |
| `deepseek-v4.1-flash-1017-ud-q4_k_xl` | Unsloth UD-Q4_K_XL, with the vision tower (`mmproj-BF16.gguf`) | served |
| `deepseek-v4.1-flash-1017-dspark` | the DSpark drafter, Q8_0 | served |
| `deepseek-v4.1-flash-1017-ud-iq1_s` | Unsloth UD-IQ1_S, the smallest file both engines read | quick checks |
| `deepseek-v4.1-flash-1017-ista-iq2_xs` | ISTA-DASLab IQ2_XS, 2.25 bpw | comparison |

`strata-dsv41` loads a pack that upstream's `tools/dsv41/pack_gguf.py` builds from these
files. The packs sit under `/models-dev/211-upstream-spike/`.

## Thermal safety

The watchdog stops a service with `pct exec <VMID> -- systemctl stop <unit>`, and the
engines' runs are not services. A map entry `<VMID>:@container` stops the whole container
with `pct stop` instead; an already-stopped container counts as stopped. While CT 125 holds
the card the map is `0000:03:00.0=120:llamacpp,0000:83:00.0=125:@container`. As for any trip,
check cooling before starting the container again.
