# DeepSeek-V4.1-Flash on GPU 2

Since 2026-10-31 GPU 2 (`0000:83:00.0`) serves DeepSeek-V4.1-Flash-1017 from CT 125
`ds41-strata`. Flash-Next's CT 123 is stopped. The engine is upstream
[Strata](https://github.com/Niko1221/Strata)'s `strata-dsv41` with the gfx1030 patches of
the private fork [marchah/strata-v620](https://github.com/marchah/strata-v620). That
repository holds the builds, the serving settings, the measurements and the host scripts
for runs: [docs/V620-BASELINE.md](https://github.com/marchah/strata-v620/blob/main/docs/V620-BASELINE.md)
and [tools/v620](https://github.com/marchah/strata-v620/tree/main/tools/v620). This
directory creates the containers.

## Containers

| CT | Hostname | Runs | onboot |
| --- | --- | --- | --- |
| 125 | `ds41-strata` | `strata-deepseek.service`: Strata's server (`serve/server.py`) with `strata-dsv41`, UD-Q4_K_XL with the DSpark drafter and the vision tower, 256K context, OpenAI-compatible API on `:1234`, no API key | 1 |
| 126 | `ds41-llama` | llama.cpp, the comparison; started only for a run, in CT 125's place | 0 |

Both are unprivileged Ubuntu 24.04 containers with ROCm 10.0.0-4 for gfx1030 and the user
`agent`, reached by SSH key only. They share one CPU set, whole cores 8-31 with both
threads (`lxc.cgroup2.cpuset.cpus: 8-31,40-63`), and one memory limit (466,487 MiB, no
swap, memlock unlimited), so their numbers compare. Mounts:

- `/models`: the shared GGUF store, read-only;
- `/models-dev`: `/mnt/models/store/dev`, writable, for packs and run directories;
- `/owner-telemetry`: the host tmpfs `/mnt/ds41-telemetry`, read-only, which the run gate
  writes.

They hold no GitHub credentials: engine commits come in as `git bundle`s (strata-v620's
`tools/v620/build-tree.sh`) and results go out through `/models-dev`. CT 125's server
config lives on CT 125 only, in `/home/agent/strata-serve/deepseek41.json`; strata-v620's
baseline, "Serving on one V620 (CT 125)", records how it was set up.

## Creating them

On the Proxmox host as root:

```bash
./create-lxc-ds41-engine.sh strata   # CT 125
./create-lxc-ds41-engine.sh llama    # CT 126
```

The script creates the container, or reconfigures an existing one in place:

- the template, ROCm, build tools, the `agent` user and key-only sshd;
- the CPU set, memory limit and mounts;
- GPU 2's `/dev/kfd`, render and card nodes at their real names, with GPU 1's DRM nodes
  denied (see below);
- the thermal watchdog's GPU 2 entry, set to the whole container.

It ends by checking that ROCm lists exactly one gfx1030. It refuses while another running
container is on GPU 2. The agent's keys are copied from the other DeepSeek container; on a
host where neither runs, pass `AGENT_SSH_PUBKEY`. Engine builds and CT 125's service
follow from strata-v620 (`tools/v620/build-strata.sh`, `build-tree.sh`, `serving.env`).

An unprivileged container's device cgroup allows every device that no rule denies, and
KFD reports every GPU whose render node the cgroup allows. With GPU 1 in that list ROCm 10
fails (`Failed to set mem policy for GPU`) and finds no device, so both containers deny
GPU 1's render and card minors.

## Who holds GPU 2

- Only one of CT 123, CT 125 and CT 126 runs on GPU 2. All three configs name the card;
  CT 123 and CT 126 have `onboot: 0`, so a host reboot starts only CT 125.
- The watchdog maps GPU 2 to the whole running container (`0000:83:00.0=125:@container`):
  a trip stops CT 125's service and any measurement run together.
- strata-v620's `tools/v620/host/` scripts, run on pve as `/root/ds41-211-<name>`:
  - `host-switch-gpu2.sh 125 126` (or `126 125`) moves the card and the watchdog entry;
  - `host-to-125-2gpu.sh` gives CT 125 GPU 1 as well, with CT 120 stopped, and
    `host-restore.sh` gives it back;
  - `gate.sh` gates every full-model run.
- `../strata/use-engine.sh`, `../glm53-flash/ct123-test-host.sh` and
  `../qwen38-flash-next/ct120-cutover.sh` refuse to change cards while CT 125 or CT 126
  passes a V620 through.

To give GPU 2 back to Flash-Next:

1. Stop CT 125 and CT 126.
2. Remove their GPU entries: `pct set <id> --delete dev0,dev1,dev2` for each.
3. Set CT 125's `onboot` to 0 and CT 123's to 1.
4. Start CT 123, then run `../strata/use-engine.sh llamacpp` (or `strata`), which sets the
   unit and the watchdog map.

## Model files

In the store (`/mnt/models/store/hf/`, `/models/hf/` in the containers), with the download
scripts in strata-v620's `tools/v620/host/` (each checks size and SHA-256):

| Directory | File | Use |
| --- | --- | --- |
| `deepseek-v4.1-flash-1017-ud-q4_k_xl` | Unsloth UD-Q4_K_XL, with the vision tower (`mmproj-BF16.gguf`) | served |
| `deepseek-v4.1-flash-1017-dspark` | the DSpark drafter, Q8_0 | served |
| `deepseek-v4.1-flash-1017-ud-iq1_s` | Unsloth UD-IQ1_S, the smallest file both engines read | quick checks |
| `deepseek-v4.1-flash-1017-ista-iq2_xs` | ISTA-DASLab IQ2_XS, 2.25 bpw | comparison |

`strata-dsv41` loads a pack that `tools/dsv41/pack_gguf.py` builds from these files. The
packs sit under `/models-dev/211-upstream-spike/`.
