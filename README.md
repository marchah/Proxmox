# Proxmox Homelab Scripts

Utilities for creating and operating local Proxmox LXCs and VMs.

## Layout

- `pro-v620/`: scripts and notes for the **Radeon Pro V620** (current GPU — the host now has **two**).
- `rx-6700-xt/`: scripts and notes for the Radeon RX 6700 XT (prior GPU — the
  V620 replaced it; kept for reference).
- `bench-runner/`: disposable LXC for OpenAI-compatible LLM benchmarks.
- `hermes/`: persistent LXC running NousResearch's Hermes Agent (the agent that
  consumes the LLM runtime's API).
- `coder-runner/`: disposable execution sandbox for the autonomous coding loop.
- `kb-rag/`: knowledge-base retrieval service (hybrid search over the Markdown KB).
- `docker-host/`: the app-stack host — a Debian **VM** with Docker + Compose + Portainer,
  where the small self-contained web apps (MealDeal, and future projects) run as Compose
  stacks. Includes their compose files under `docker-host/stacks/`.
- `host-net/`: host-side networking that runs on the Proxmox host itself (not in an
  LXC). `host-net/wifi-nat/` turns the host into a WiFi-uplink NAT gateway so it can
  run with no ethernet.
- `host-notifications/`: routes Proxmox notifications (backup failures and friends) to
  Slack, because the builtin target delivers to a local mailbox nobody reads.

Each GPU folder should own its own model/runtime assumptions. LLM containers tend
to need GPU-specific environment variables, memory sizing, context settings, and
runtime flags, so the scripts are intentionally explicit instead of trying to be
a universal model launcher.

## VMID Convention

Containers are allocated VMIDs by role:

| Range   | Purpose                        |
| ------- | ------------------------------ |
| 100-119 | Infra / services               |
| 120-139 | AI/LLM containers              |
| 140-159 | Databases                      |
| 200+    | Test / temporary               |
| 300+    | **VMs** (own range, see below) |

The first four ranges allocate **containers**; VMs get `300+` so `pct` and `qm` ids never
collide. Apps that run as Docker containers on the Docker host don't take a VMID at all.

Current guests:

| ID | Name | What |
| --- | --- | --- |
| VM `300` | `docker-host` | Docker + Compose + **Portainer** — hosts the small web apps as stacks (MealDeal on `:4000`, Portainer UI on `:9443`) |
| `120` | `llamacpp` | The AI/LLM runtime — pinned to **GPU 1** of two Radeon Pro V620s |
| `121` | `hermes` | Hermes Agent; consumes CT 120's API and drives the coding loop |
| `122` | `coder-runner` | Disposable execution sandbox for the coding loop (no secrets) |
| `123` | `gpu2` | `llama-swap` model server on **GPU 2** (several models, swapped by name) |
| `140` | `kb-rag` | Knowledge-base search API (REST + MCP) over the Markdown KB |
| `200` | `bench-runner` | Disposable benchmark LXC |

Each creation script defaults its `VMID` to the matching range and accepts a `VMID=` override.

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

- GPU: **two Radeon Pro V620s** (32 GB each — replaced the 12 GiB RX 6700 XT), one in
  PCIe-1 (`0000:2d:00.0`) and one in PCIe-3 (`0000:06:00.0`). The ~26.6 GB model fits one
  card, so **CT 120 is pinned to GPU 1 alone**, and **GPU 2 runs CT 123 `gpu2`** (a
  `llama-swap` server). Each card has its **own 9733 blower**, both driven through a
  SATA-powered PWM hub on the PUMP FAN header (one curve tracking the hotter card), and both
  undervolted −100 mV. Both cards saturated at once measure 62/73 °C at 51% fan.
  See [`pro-v620/README.md`](pro-v620/README.md).
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

### Docker App-Stack Host (VM 300)

Creates a Debian **VM** running Docker + Compose + **Portainer CE** — the home for the homelab's
small self-contained web apps, which run as Compose stacks rather than one LXC each. First
tenant: [MealDeal](https://github.com/marchah/mealdeal), a self-hosted grocery-deal tracker whose
deal extraction runs against CT 120 (no cloud API key). See
[docker-host/README.md](docker-host/README.md).

```bash
./docker-host/create-vm-docker-host.sh   # pinned Debian cloud image, Docker, Compose, Portainer
```

Then open `https://192.168.1.93:9443`, create the Portainer admin user, and add a project as a
**git stack** (Repository URL = this repo, compose path =
`docker-host/stacks/<project>/compose.yaml`) with secrets as stack env vars. Portainer can
auto-redeploy on a new commit via polling or a webhook.

**This is the only VM in the repo, on purpose.** Proxmox recommends Docker in a VM, and
Docker-in-LXC needs `nesting=1` + `keyctl=1` (often privileged), stacks `overlay2` on a container
filesystem, tends to break after Proxmox kernel bumps, and shares a kernel with this host's
hand-rolled nftables NAT that Docker also writes rules into. The GPU/LLM containers stay native
LXCs — they need device passthrough and gain nothing from Docker.

> A per-app native LXC (`mealdeal/create-lxc-mealdeal.sh`, CT 110) was built and verified first,
> then retired: one bespoke ~870-line script per app doesn't scale to a fleet of small projects.
> Its reusable findings are recorded in CLAUDE.md.

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
