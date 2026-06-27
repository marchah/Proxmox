# Proxmox Homelab Scripts

Utilities for creating and operating local Proxmox LXCs and VMs.

## Layout

- `rx-6700-xt/`: scripts and notes for the Radeon RX 6700 XT.
- `bench-runner/`: disposable LXC for OpenAI-compatible LLM benchmarks.

Each GPU folder should own its own model/runtime assumptions. LLM containers tend
to need GPU-specific environment variables, memory sizing, context settings, and
runtime flags, so the scripts are intentionally explicit instead of trying to be
a universal model launcher.

## VMID Convention

Containers are allocated VMIDs by role:

| Range   | Purpose           |
| ------- | ----------------- |
| 100-119 | Infra / services  |
| 120-139 | AI/LLM containers |
| 140-159 | Databases         |
| 200+    | Test / temporary  |

Current containers: CT `120` (`lmstudio`, AI/LLM) and CT `200` (`bench-runner`,
disposable). Each creation script defaults its `VMID` to the matching range and
accepts a `VMID=` override.

## Current Scripts

### Benchmark Runner LXC

Creates a small unprivileged Debian LXC that runs the
benchmark suite against the LM Studio OpenAI-compatible API.

See [bench-runner/README.md](bench-runner/README.md).

Run it directly on the Proxmox host without cloning the repo:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/marchah/Proxmox/main/bench-runner/create-lxc-bench-runner.sh)"
```

### RX 6700 XT LM Studio LXC

Creates a privileged Ubuntu LXC for:

- GPU: Radeon RX 6700 XT
- Runtime: LM Studio's `lms` CLI in headless/server mode
- Model: `unsloth/Qwen3.5-9B-GGUF`
- File: `Qwen3.5-9B-Q4_K_M.gguf`

See [rx-6700-xt/README.md](rx-6700-xt/README.md).

Run it directly on the Proxmox host without cloning the repo:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/marchah/Proxmox/main/rx-6700-xt/create-lxc-lmstudio-qwen3.5-9b.sh)"
```

## Notes

- Run scripts on the Proxmox host as `root`.
- Review each GPU folder README before running its scripts.
- Keep downloaded model files and generated benchmark results out of git.
