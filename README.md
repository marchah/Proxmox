# Proxmox Homelab Scripts

Utilities for creating and operating local Proxmox LXCs and VMs.

## Layout

- `pro-v620/`: scripts and notes for the **Radeon Pro V620** (current GPU — the host now has **two**).
- `rx-6700-xt/`: scripts and notes for the Radeon RX 6700 XT (prior GPU — the
  V620 replaced it; kept for reference).
- `bench-runner/`: disposable LXC for OpenAI-compatible LLM benchmarks.
- `hermes/`: persistent LXC running NousResearch's Hermes Agent (the agent that
  consumes the LLM runtime's API).
- `host-net/`: host-side networking that runs on the Proxmox host itself (not in an
  LXC). `host-net/wifi-nat/` turns the host into a WiFi-uplink NAT gateway so it can
  run with no ethernet.

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

Current containers: CT `120` (the AI/LLM runtime — now on **two Radeon Pro V620s**,
model split across both; provisioned by `pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh`), CT `121`
(`hermes`, the Hermes Agent that consumes CT 120's API) and CT `200`
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

### Pro V620 LLM Runtime LXC (current)

Creates a privileged Ubuntu LXC serving a high-parameter Qwen model on the
**Radeon Pro V620** (Navi 21 / gfx1030, 32 GB) via **Vulkan**:

- GPU: **two Radeon Pro V620s** (32 GB each — replaced the 12 GiB RX 6700 XT). One
  in the PCIe-1 slot (blower-cooled), one in PCIe-3 (2× Arctic S4028-6K); llama.cpp
  splits the model across both. Both undervolted −100 mV, each with its own fan curve.
- Model: `unsloth/Qwen3.6-35B-A3B-GGUF` / `Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf`
  (MoE, 35B total / ~3B active — fast, fits 32 GB at Q5)
- Engine: `create-lxc-llamacpp-qwen3.6-35b-a3b.sh` — llama.cpp's `llama-server`

Defaults to CT `120`, serves an OpenAI-compatible API on `0.0.0.0:1234` under the
id `qwen3.6-35b-a3b`. Chosen for agent use (MoE keeps per-step latency low). See
[pro-v620/README.md](pro-v620/README.md) for benchmarks, the model bake-off, and tuning.

Run directly on the Proxmox host without cloning the repo:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/marchah/Proxmox/main/pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh)"
```

### Hermes Agent LXC

Creates a persistent **unprivileged Debian LXC** running [NousResearch's Hermes
Agent](https://hermes-agent.nousresearch.com/) — the homelab's agent, pointed at the CT 120
runtime's OpenAI-compatible API (no Nous Portal login). A single `hermes gateway run` service
serves both the messaging gateway and Hermes's own OpenAI-compatible API server on
`0.0.0.0:8642`. Defaults to CT `121`, full browser tools, starts on boot. See
[hermes/README.md](hermes/README.md).

Run directly on the Proxmox host without cloning the repo:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/marchah/Proxmox/main/hermes/create-lxc-hermes-agent.sh)"
```

### Host WiFi-NAT Gateway (runs on the host, not in an LXC)

`host-net/wifi-nat/install.sh` lets the Proxmox host run with **no ethernet**: the
onboard WiFi (`wlo1`) becomes the routed WAN and `vmbr0` becomes an internal NAT'd LAN
(`10.10.10.0/24`) that the LXCs sit behind (dnsmasq DHCP/DNS + nftables masquerade +
port-forwards). It's staged and reversible, with an auto-rollback guarding the risky
cutover. See [host-net/wifi-nat/README.md](host-net/wifi-nat/README.md).

### RX 6700 XT LLM Runtime LXC (prior GPU)

> The V620 above replaced this card. These scripts are kept for reference.

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
