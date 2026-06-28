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

Current containers: CT `120` (the AI/LLM runtime — provisioned by one of two
interchangeable engine scripts, LM Studio or llama.cpp) and CT `200`
(`bench-runner`, disposable). Each creation script defaults its `VMID` to the
matching range and accepts a `VMID=` override.

## Current Scripts

### Benchmark Runner LXC

Creates a small unprivileged Debian LXC that runs the benchmark suite against a
local LLM runtime's OpenAI-compatible API (LM Studio or llama.cpp — both expose
the same `/v1` endpoint, so the suite treats them identically).

See [bench-runner/README.md](bench-runner/README.md).

Run it directly on the Proxmox host without cloning the repo:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/marchah/Proxmox/main/bench-runner/create-lxc-bench-runner.sh)"
```

### RX 6700 XT LLM Runtime LXC

Creates a privileged Ubuntu LXC serving the same model on the RX 6700 XT via
**Vulkan**, with a choice of inference engine:

- GPU: Radeon RX 6700 XT
- Model: `unsloth/Qwen3.5-9B-GGUF` / `Qwen3.5-9B-Q4_K_M.gguf`
- Engine — pick one script:
  - `create-lxc-lmstudio-qwen3.5-9b.sh` — LM Studio's `lms` CLI
  - `create-lxc-llamacpp-qwen3.5-9b.sh` — llama.cpp's `llama-server`

Both default to CT `120` and serve an OpenAI-compatible API on `0.0.0.0:1234`,
so they are **mutually exclusive** — run one at a time (only one can use the
12 GiB GPU). See [rx-6700-xt/README.md](rx-6700-xt/README.md).

**Recommended: llama.cpp with `--parallel 4`** (the script default). For
`Qwen3.5-9B-Q4_K_M` at 64 k context on this GPU:

| Metric | LM Studio | **llama.cpp** |
| --- | ---: | ---: |
| Single-stream | 53 tok/s | **56 tok/s** |
| Concurrent aggregate (4 slots) | ~47 tok/s | **80 tok/s** |
| Cold prefill ≥ 6 k tokens | **garbage** | correct (to 32 k) |

Single-user speed is a wash (~56 tok/s, ~0.2 s first token), but llama.cpp roughly
doubles concurrent throughput and — unlike LM Studio — never corrupts long cold
prompts. Both are GPU-bound (~99 % util, ~7 GiB / 12 GiB VRAM). Full data and
methodology: [rx-6700-xt/README.md#recommendation](rx-6700-xt/README.md#recommendation).

Run directly on the Proxmox host without cloning the repo:

```bash
# LM Studio
bash -c "$(wget -qLO - https://raw.githubusercontent.com/marchah/Proxmox/main/rx-6700-xt/create-lxc-lmstudio-qwen3.5-9b.sh)"
# llama.cpp
bash -c "$(wget -qLO - https://raw.githubusercontent.com/marchah/Proxmox/main/rx-6700-xt/create-lxc-llamacpp-qwen3.5-9b.sh)"
```

## Notes

- Run scripts on the Proxmox host as `root`.
- Review each GPU folder README before running its scripts.
- Keep downloaded model files and generated benchmark results out of git.
