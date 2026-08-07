# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of Bash provisioning scripts (with embedded Python) that create and operate
Proxmox LXC containers for a local AI homelab. There is no application to build or test
suite to run — the "product" is the scripts themselves, executed **on the Proxmox host as
root**. macOS is only the authoring/editing environment; the scripts run remotely against
`pct`/`pveam`.

These containers form the system:

- **CT 120** (`pro-v620/`): a *privileged* Ubuntu LXC — the **LLM runtime** — serving
  `Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf` (MoE, 35B total / ~3B active) via Vulkan, exposing an
  OpenAI-compatible API at `0.0.0.0:1234` under the id `qwen3.6-35b-a3b`. The host now has
  **two Radeon Pro V620s** (Navi 21 / gfx1030, 32 GB each): one in the **PCIe-1** (CPU) slot
  `0000:2d:00.0`, one in the **PCIe-3** (chipset) slot `0000:06:00.0`, both cooled by a single
  **NF-F12 iPPC-3000** 120 mm fan in a shared shroud (one `gpu-fan-control@shroud` instance whose
  curve tracks the hotter card). CT 120 is **pinned to GPU 1 alone** (`0000:2d:00.0`): its
  container bind-mounts only that card's `/dev/dri` render node (via the udev-stable `by-path`
  symlink — the reboot-stable way to pin one of two identical cards), so llama.cpp sees a single
  Vulkan device and runs the whole ~26.6 GB model on it. **GPU 2 (`0000:06:00.0`) runs CT 123 `gpu2`**
  (a `llama-swap` server for the autonomous coding loop — see below); it stays amdgpu-bound so the host
  fan/undervolt/watchdog services manage both. Both cards are undervolted −100 mV:
  - `pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh` — llama.cpp's `llama-server`
    (hostname `llamacpp`). This is the current runtime.
  - `pro-v620/create-lxc-llama-swap-gpu2.sh` — **CT 123 `gpu2`** on GPU 2: a `llama-swap` proxy for the
    autonomous coding loop that hot-swaps between a coder model (Qwen3-30B-A3B-Instruct-2507, alias
    `qwen3-instruct-2507`) and a reviewer model (Qwen3-Coder-30B-A3B-Instruct, alias `qwen3-coder-30b-a3b`),
    one resident at a time (OpenAI API `0.0.0.0:8080`, pick model by name).
    Same single-GPU pin idiom (`GPU_PCI_ADDRESS=0000:06:00.0`, by-path, REAL node name) + the loud-guard.
    The loop's dispatcher is serialized (`kanban.max_in_progress: 1`) so swaps fire only at role handoffs.
  - **Prior GPU (`rx-6700-xt/`, kept for reference):** the V620 replaced a Radeon RX 6700 XT
    (12 GiB) that served `Qwen3.5-9B-Q4_K_M.gguf` (id `qwen3.5-9b`) via two interchangeable
    engine scripts — `create-lxc-lmstudio-qwen3.5-9b.sh` (LM Studio `lms`) and
    `create-lxc-llamacpp-qwen3.5-9b.sh` (llama.cpp). The README found llama.cpp better on
    that card, which is why the V620 ships only the llama.cpp script.
- **CT 121 `hermes`** (`hermes/`): an *unprivileged* Debian LXC running NousResearch's
  **Hermes Agent** — the homelab's agent (NOT a model server; it *consumes* CT 120's API,
  see the `ct120-vs-hermes` memory). It auto-discovers CT 120's IP, points Hermes at it via a
  `provider: custom` OpenAI endpoint (no Nous Portal login), and runs a single
  `hermes gateway run` service = messaging gateway + Hermes's own OpenAI-compatible API server
  on `0.0.0.0:8642`. Persistent (`120-139` AI range, starts on boot); full Playwright browser
  tools; installs + runs as root inside the unprivileged LXC. `hermes/create-lxc-hermes-agent.sh`.
- **CT 140 `kb-rag`** (`kb-rag/`): an *unprivileged* Debian LXC that indexes the private
  **CognitiveStack** Markdown knowledge base and serves **hybrid search** — FTS5 **BM25**
  (keyword/exact) ⊕ `sqlite-vec` **KNN** (semantic), merged by **Reciprocal Rank Fusion** (k=60)
  — to every agent on the box over one port: **REST *and* MCP-over-HTTP** on `0.0.0.0:8770`
  (`/v1/search`, `/v1/doc`, `/v1/stats`, plus an unauthenticated `/health`; MCP at `/mcp/` —
  trailing slash, `/mcp` 307-redirects — exposing `kb_search`/`kb_get`/`kb_stats`). It sits in the
  `140-159` **databases** range because the durable artifact is a vector+FTS database, even though
  agents are the consumers. Live since 2026-07-04 (PR #14); ~3.6k chunks / ~456 docs as of
  2026-08-07. `kb-rag/create-lxc-kb-rag.sh`; full design rationale in `kb-rag/SPEC.md`.
  - **Markdown-in-git stays the source of truth** — this CT holds only a *derived, rebuildable*
    index, so wiping `/opt/kb-rag/data` + `kb-reindex --full` reconstructs everything. Back up the
    CognitiveStack repo, not this container. If the vector store ever becomes where knowledge
    *lives*, that's a regression.
  - Embeddings are **CPU-only** (`fastembed`/ONNX, `BAAI/bge-small-en-v1.5`, 384-dim) —
    deliberately **no GPU passthrough and no load on CT 120**: embedding one short query is
    milliseconds on CPU and batch indexing is offline. A `kb-reindex.timer` pulls + reindexes every
    10 min, incrementally (only chunks whose `content_hash` changed are re-embedded) and stamps the
    source commit into the index. Corpus selection is glob-driven in `app/index.config.yaml`
    (include `**/*.md`, exclude `personal/**` + nav/meta), not hardcoded — a new topic folder is
    picked up automatically.
  - Security: a **read-only deploy key** for the KB repo is **mandatory** (`DEPLOY_KEY_FILE=`, the
    container can only pull), and every data endpoint is gated by a bearer key auto-generated at
    provision and stored mode-600 in `/etc/kb-rag.env`. Secrets are pushed as mode-600 files and
    the host copies removed (the hermes idiom). **No nft port-forward by default** — reachable only
    inside the `10.10.10.0/24` NAT LAN, by hostname.
  - ⚠️ Changing `EMBED_MODEL`/`EMBED_DIM` later requires `kb-reindex --full` — the stored
    `sqlite-vec` vector dimension must match.
  - ⚠️ **Nothing consumes it yet.** Verified 2026-08-07: CT 121's `/root/.hermes/config.yaml` has
    no `mcp:` block and no `kb-rag`/`8770` reference, so this is a live-but-*unwired* service.
    Registering `http://kb-rag:8770/mcp/` (header `Authorization: Bearer <key>`) on Hermes is the
    step that makes it useful.
  - ⚠️ Its `rootfs` `backup=0` is one of the **silent no-ops** described under Conventions —
    verified 2026-08-07, CT 140's line is a bare `local-lvm:vm-140-disk-0,size=12G` with no
    `backup=`, so this entirely rebuildable container **is** in the weekly vzdump, contrary to what
    `kb-rag/README.md` and `SPEC.md` claim. Low stakes in practice (1.8 GB used: 278 MB venv,
    154 MB index+checkout, 78 MB ONNX cache), but don't believe the "not backed up" comments. To
    actually skip the bulk: `vzdump 140 --exclude-path /opt/kb-rag`.
  - ⚠️ Its `kb-reindex`/`kb-stats` wrappers live in `/usr/local/bin`, so they hit the **`pct exec`
    PATH gotcha**: `pct exec 140 -- kb-stats` fails with `Failed to exec "kb-stats"` (verified
    2026-08-07). Wrap in `bash -lc '…'` — `kb-rag/README.md`'s bare examples do not work.
- **CT 200 `bench-runner`** (`bench-runner/`): an *unprivileged* Debian LXC that benchmarks
  that endpoint. It auto-discovers CT 120's IP at provisioning time. It lives in the
  `200+` test/temporary range because it is disposable — destroy it when done. The suite is
  engine-neutral (it speaks OpenAI `/v1`), so it benchmarks either engine unchanged.
- **VM 300 `docker-host`** (`docker-host/`): a Debian **VM** (the *only* VM here, deliberately)
  running **Docker + Compose + Portainer CE**, which hosts the homelab's small self-contained web
  apps as Compose stacks — currently **MealDeal**
  ([github.com/marchah/mealdeal](https://github.com/marchah/mealdeal), the grocery-deal tracker
  the local AI codes features for), live on `:4000`. Apps here **do not consume a VMID each** —
  they are containers inside this VM, so a new project costs a compose file
  (`docker-host/stacks/<project>/compose.yaml`) plus a Portainer git stack, not a bespoke
  provisioning script. Stack secrets (e.g. `IMAP_PASSWORD`) are **Portainer stack env vars**,
  never in this public repo. ⚠️ **Why a VM when everything else is an LXC:** Proxmox recommends
  Docker in a VM; Docker-in-LXC needs `nesting=1`+`keyctl=1` (often privileged), puts `overlay2`
  on a container filesystem, tends to break after Proxmox kernel bumps, and shares a kernel with
  this host's hand-rolled nftables NAT that Docker also writes rules into. The GPU/LLM containers
  stay native LXCs — they need device passthrough and gain nothing here. MealDeal now **pulls a
  prebuilt image** — `marchah/mealdeal#36` merged 2026-07-27 and its `Publish image` workflow
  publishes `ghcr.io/marchah/mealdeal` on every push to `main` (tags `main` + `sha-<short>`, plus
  semver from `v*`). The package came out **public**, so anonymous pull works and Portainer needs
  no registry credentials — don't trust the old warning that GHCR always defaults to private.
  Redeploys are a ~10 s pull; rollback is pinning a `sha-` tag. ⚠️ The stack sets
  **`pull_policy: always`** deliberately — without it a redeploy can reuse a stale local layer
  cache and silently keep serving the old build even though `main` moved. (Historical note: this stack built
  from git for a while, blamed on an "Actions billing-locked" state that **never existed** —
  verified 2026-07-26, plan `free` with every Actions line item at **$0.00 net**, because
  public-repo minutes are 100% free. The image had simply never been published.) ⚠️ Unlike
  the retired per-app LXC, **Portainer has no health-gated auto-rollback** — a broken deploy stays
  broken until acted on (the compose healthcheck makes it *visible*, not self-healing). See
  `docker-host/README.md`.
  - **Superseded:** `mealdeal/create-lxc-mealdeal.sh` (a native per-app LXC, CT 110) was built
    and verified first, then removed — one bespoke 870-line script per app doesn't scale to a
    fleet of small projects, which was the whole point of the pivot. Its genuinely reusable
    findings are retained below (the `pct exec` PATH gotcha, the `rootfs` `backup=` no-op).

VMIDs `120`/`121`/`122`/`123`/`140`/`200` and hostnames are defaults overridable via env vars (`VMID=`, `LXC_HOSTNAME=`, etc.).

## Common commands

All run on the Proxmox host as root.

```bash
# Provision the ops LLM-runtime container (CT 120) — GPU 1 of two Radeon Pro V620
./pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh # llama.cpp (llama-server), Qwen3.6-35B-A3B MoE
# Autonomous coding loop's GPU-2 model server (CT 123 gpu2) — llama-swap on GPU 2
./pro-v620/create-lxc-llama-swap-gpu2.sh          # Qwen3-Instruct-2507 coder + Qwen3-Coder-30B reviewer, swapped by name (:8080)
# The loop's execution sandbox (CT 122 coder-runner; runs npm/build/tests, needs CT 121's ssh pubkey)
CODER_SSH_PUBKEY="$(pct exec 121 -- cat /root/.ssh/coder-runner.pub)" ./coder-runner/create-lxc-coder-runner.sh
# The loop/orchestrator config that runs INSIDE CT 121 (profiles/skills/plugins/timers) — run from within CT 121
pct exec 121 -- bash -lc 'cd /path/to/Proxmox/hermes/config && ./install.sh'  # see hermes/config/README.md
# The knowledge-base retrieval service (CT 140 kb-rag) — a read-only KB deploy key is REQUIRED
DEPLOY_KEY_FILE=./cognitivestack-deploy ./kb-rag/create-lxc-kb-rag.sh
# Prior GPU (RX 6700 XT) — kept for reference; pick ONE engine (mutually exclusive)
./rx-6700-xt/create-lxc-lmstudio-qwen3.5-9b.sh    # LM Studio (lms)
./rx-6700-xt/create-lxc-llamacpp-qwen3.5-9b.sh    # llama.cpp (llama-server)

# Provision the Docker app-stack host (VM 300): Docker + Compose + Portainer CE.
# Hosts MealDeal and future small projects as compose stacks. Portainer UI on :9443.
./docker-host/create-vm-docker-host.sh
./docker-host/create-vm-docker-host.sh --reinstall-docker   # re-run ONLY the in-guest install
# Operate the app stacks — prefer the Portainer UI (https://192.168.1.93:9443); by CLI:
ssh pve 'ssh -i /root/.ssh/docker-host debian@10.10.10.100'   # into the VM (host holds the key)
#   docker ps
#   docker compose -f /opt/stacks/mealdeal/compose.yaml logs -f
#   docker compose -f /opt/stacks/mealdeal/compose.yaml up -d --build

# Operate the KB retrieval service (CT 140). Same `bash -lc` PATH rule as the bench wrappers.
pct exec 140 -- bash -lc 'kb-stats'            # index commit, embed model, chunk/doc counts
pct exec 140 -- bash -lc 'kb-reindex'          # git pull + incremental reindex now
pct exec 140 -- bash -lc 'kb-reindex --full'   # drop + rebuild (required after an embed-model change)
pct exec 140 -- systemctl status kb-rag        # and: journalctl -u kb-rag / list-timers kb-reindex.timer

# Provision the benchmark runner (CT 200); auto-targets CT 120's API
./bench-runner/create-lxc-bench-runner.sh

# Run benchmarks (wrapper commands installed into the bench-runner LXC)
# Wrap wrapper commands in `bash -lc '…'` — bare `pct exec` PATH omits /usr/local/bin
pct exec 200 -- bash -lc 'llm-bench-baseline'     # single-user repeatable baseline
pct exec 200 -- bash -lc 'llm-bench-concurrency'  # throughput / tail-latency
pct exec 200 -- bash -lc 'llm-bench-soak'         # longer, surfaces thermal/memory pressure
pct exec 200 -- bash -lc 'llm-bench-quality'      # enables lm-eval (GSM8K smoke test)
pct exec 200 -- bash -lc 'llm-bench-env'          # print resolved config
pct exec 200 -- bash -lc 'llm-bench-compare /results/<baseline> /results/<candidate>'

# Override any knob per-run via env
pct exec 200 -- bash -lc 'BENCHMARK_REQUESTS=5 BENCHMARK_CONCURRENCY=2 llm-bench-baseline'
```

Both creation scripts support `--help`/`-h` and a large set of `VAR=value` overrides
(documented in each script's `usage()` and the folder READMEs).

### Linting

Scripts use `set -Eeuo pipefail` and carry `# shellcheck disable=...` directives, so
**shellcheck is the expected linter** for `.sh` files. There is no CI, Makefile, or
automated test harness in the repo.

## Architecture

### Provisioning scripts share one shape

Both `create-lxc-*.sh` scripts follow the same structure: top-of-file `readonly`/env-default
config block → small helper funcs (`die`, `log`, `require_root`, `require_command`) →
a `main()` that runs an explicit ordered pipeline (resolve template → create container →
configure → install → summarize). Heredocs (`<<'CONTAINER_SCRIPT'`) push self-contained
sub-scripts into the container via `pct exec ... bash -s`. Match this idiom when extending.

**GPU/model/engine scripts are intentionally narrow, not generic.** Per the README, each GPU
folder owns its own model/runtime assumptions (GPU runtime flags, context size, VRAM sizing).
A different GPU, model, *or inference engine* should get a *new* script, not a parameterized
mega-launcher — the RX 6700 XT has two sibling scripts (`...-lmstudio-...` and
`...-llamacpp-...`) serving the same model on the same GPU via Vulkan, and the V620 got a
brand-new folder/script (`pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh`) for its larger
32 GB / MoE model rather than a flag on the 6700 XT script.
Both GPUs use Vulkan (mesa RADV) — Navi 22/gfx1031 on the 6700 XT, Navi 21/gfx1030 on the
V620 — the container installs `mesa-vulkan-drivers` and passes through the GPU render node. With
**two V620s** installed, CT 120 bind-mounts **only GPU 1's** render node (by PCI address, via the
`by-path` symlink), so llama.cpp sees one Vulkan device and runs the model on that card while GPU 2
stays idle; plus a pinned model repo/file/SHA-256 in a privileged container. (The V620
model is a single-file unsharded GGUF, so the download/verify path is unchanged; on 32 GB it
defaults to ctx 262144 / `--parallel 2` (the model's ~256k native max, 128k per slot; this
MoE's KV cache is cheap, ~20 KB/token, ~29.8 GiB total at Q5). It was `--parallel 4` (64k/slot),
but qwen3.6's uncapped reasoning could fill a whole 64k slot with `<think>` and return
`finish_reason='length'` with no answer (Hermes "Thinking Budget Exhausted"); 128k/slot leaves
room for reasoning + answer. A single agent needing the whole 256k window uses
`llamacpp-reload 262144 1`; tunable via `llamacpp-reload`.)

Engine differences that matter when extending the llama.cpp script:
- It installs a **pinned prebuilt Vulkan `llama-server` release** (tag + tarball SHA-256 in
  the config block; bump both from the ggml-org/llama.cpp releases page). It extracts to a
  flat `llama-<tag>/` dir and symlinks `/opt/llamacpp/current`. It also installs the
  **libglvnd/EGL stack** (`libglvnd0 libgl1 libglx0 libegl1`) on top of `mesa-vulkan-drivers`
  — without it the Mesa ICD loader can silently report **zero** Vulkan devices in the container.
- LM Studio hot-reloads context/parallel via `lms load`; **llama.cpp sets them as start-time
  flags**, so its container ships a `llamacpp-reload <ctx> <parallel>` helper (rewrites
  `/etc/llamacpp.env` + `systemctl restart`) and a `Type=simple` service running
  `/usr/local/bin/llamacpp-serve`.
- `llama-server --alias <id>` makes `/v1/models` report a stable id (else it reports the
  model file path); that id is what the bench-runner records as `MODEL_IDENTIFIER` (the V620
  serves `qwen3.6-35b-a3b`, the 6700 XT served `qwen3.5-9b`). The bench-runner auto-detects
  it from `/v1/models` at provision time; `ansible/benchmark.yml` and `host/run-context-sweep.sh`
  default `model_key`/`MODEL_KEY` to `qwen3.6-35b-a3b`, and the ansible run re-points an existing
  CT 200's `MODEL_IDENTIFIER` to it each run (so a model swap can't leave preflight stale).

### Dual-mode install (critical gotcha)

`bench-runner/create-lxc-bench-runner.sh` installs the suite into `/opt/bench-runner`
**two different ways** (`install_benchmark_suite`):

1. **Local checkout present** → `copy_local_benchmark_suite` tars up `scripts/`, `config/`,
   and the `*.md` docs and pushes them in.
2. **Run standalone via `wget | bash`** (no checkout) → `download_benchmark_suite` curls
   each file individually from GitHub raw using a **hardcoded file list**.

⚠️ When you add or rename a file under `bench-runner/scripts/` or `bench-runner/config/`,
you MUST also add it to the hardcoded `files=( ... )` array in `download_benchmark_suite`,
or the standalone install path will silently ship an incomplete suite.

`kb-rag/create-lxc-kb-rag.sh` mirrors this idiom for `kb-rag/app/` — same two paths, same trap,
different array name: **`APP_FILES=( ... )`** near the top of the script (alongside
`REPO_RAW_BASE`). Adding or renaming anything under `kb-rag/app/` without updating it ships a
broken service on the standalone path.

### Benchmark orchestration

`bench-runner/scripts/benchmarks/run-ai-benchmark-suite.sh` is the engine. Flow:

1. **Layered config** (process env wins, because every file default uses `: "${VAR:=...}"`
   — including `MODEL_API_URL`/`MODEL_IDENTIFIER`, so a per-run override actually takes
   effect): `config/local-model.env` (written at provisioning: the model's
   `MODEL_API_URL`, the discovered `MODEL_IDENTIFIER`, `RUN_*` toggles) → the profile file
   named by `BENCHMARK_PROFILE` (`config/benchmark-profiles/<name>.env`) → process env.
2. **Preflight** (unless `BENCHMARK_PREFLIGHT=false`): GETs `<MODEL_API_URL>/models` and
   aborts before any work if the endpoint is unreachable (exit-path "unreachable") or
   `MODEL_IDENTIFIER` is not in the served list. This is the loud-failure guard against a
   stale/wrong URL or model id from provisioning time.
3. For each enabled target, `run_with_telemetry` launches `system-sampler.py` in the
   background, runs the benchmark, then records `status.json`.
4. Writes `manifest.json`, `versions.json`, captures before/after `system-logs/`, evaluates
   SLOs (`evaluate-slos.py` against `config/benchmark-slos/default.json`), and renders
   `REPORT.md` + `SLO.md` (`write-benchmark-report.py`).

**Metric scope:** the bench-runner LXC is unprivileged with no GPU passthrough, but
`system-sampler.py` still reads the host's `/sys/class/drm` + hwmon, so it *does* capture
GPU utilization, VRAM, core clocks, and amdgpu/CPU temps (a baseline run recorded 99% GPU
util, 7.24 GiB VRAM, 103 °C junction) — and the GPU/temperature SLO checks in `default.json`
run from here. Caveat: `gpu_busy_percent` is only meaningful under active load and can return
`EBUSY`, so judge GPU-vs-CPU by throughput, not an idle sample. (llama.cpp holds the model in
VRAM, so `mem_info_vram_used` stays high even idle — the pre-allocated weights + KV — unlike
engines that free VRAM between requests.)
Trust the per-run telemetry peaks. `evaluate-slos.py` still skips any check whose data is
genuinely absent. **CPU/RAM/process metrics from the in-LXC sampler are lxcfs-virtualized to
CT 200 — they describe the benchmark *client*, not the model server (llama.cpp on CT 120).** To judge whether the model
server itself was CPU/RAM-bound, the Ansible batch wraps each run with
`host/run-with-target-telemetry.sh`, which samples CT 120 from the host and merges a
`target-telemetry.jsonl` into each `/results/<run-id>/`. Don't cite the in-LXC CPU/RAM numbers
as the server's. After merging, the wrapper re-runs `finalize-run.py` so `REPORT.md`/`SLO.md`
incorporate the server telemetry (a "Model Server Telemetry" report section + a
`model-server-target` SLO check) — the suite generated them in-container *before* the merge,
so regeneration is what makes the data count. The batch sets `REQUIRE_TARGET_TELEMETRY=true`,
so a run that captures no server samples fails (manual `run-with-target-telemetry.sh` runs
default to opt-out).

**`RUN_*` toggles gate each benchmark target**: `RUN_OPENAI_DIRECT`, `RUN_LLAMA_BENCHY`,
`RUN_LM_EVAL`. The runner targets only the LLM runtime's OpenAI endpoint, so it runs
`openai-direct` + `llama-benchy` by default; `lm-eval` runs only in the `quality` profile.
The Hermes, raw `llama-bench`, and vLLM benchmark paths were removed — they couldn't run in
this unprivileged, OpenAI-API-only LXC. The suite's built-in `SCENARIOS` (smoke/short/medium/
long) remain only as a manual `--scenario` fallback; every profile uses the promptset.

The `llm-bench-*` wrappers in `/usr/local/bin` are thin: they `source /etc/bench-runner.env`,
set `BENCHMARK_PROFILE`/`BENCHMARK_RUN_ID`, and exec the suite. They are generated inline by
`configure_benchmark_environment` in the creation script — edit them there, not by hand.

### Bottleneck tooling (the goal is hardware/infra limits, not model quality)

- **`run-sweep.py`** (wrapper `llm-bench-sweep <concurrency|input-length>`): drives
  `benchmark-openai-api.py` across a parameter and writes `curve.json`/`curve.md`. Relies on
  the `--synthetic-input-tokens`/`--synthetic-output-tokens` controlled-workload flags added
  to `benchmark-openai-api.py`. Client-side; finds the saturation knee / TTFT scaling.
- **`summarize-telemetry.py`**: reduces any `telemetry.jsonl` to peak GPU util, VRAM
  ratio, core-clock range (throttle hint), temps, and min free RAM. AMD-DRM and NVIDIA aware.
- **`host/` directory** — Proxmox-host orchestration, **not** shipped into the LXC (the
  local-copy tar and the download list both exclude it; these need `pct`). `run-with-host-
  telemetry.sh` samples a container's GPU during any bench command — largely **redundant**,
  since the in-LXC sampler already records GPU telemetry; keep it only for sampling around a
  non-benchmark command. `run-with-target-telemetry.sh` is the non-redundant counterpart: it
  pushes `system-sampler.py` into the *model* container (CT 120) and runs it there during a
  bench, so CPU/RAM/process metrics reflect the model server, llama.cpp (not the bench-runner
  client); the Ansible batch wraps every run with it and merges `target-telemetry.jsonl` into
  the result. `run-context-sweep.sh` reloads the model at each context length and correlates
  VRAM with TTFT/latency/throughput — still useful, because the per-context reload is the part
  the in-LXC suite can't do. The model-reload path is **llamacpp-only**: `ansible/benchmark.yml`'s
  `runtimes` map carries the `llamacpp` entry (`reload_cmd` + `target_process_patterns` + results
  `label`) and `host/run-context-sweep.sh` calls the container's `llamacpp-reload <ctx> <parallel>`
  (restart, blocks until `/health` is ready). Drive it with `make bench` / `make context-sweep`.
  (The prior RX 6700 XT also had an `lmstudio` runtime; it was removed with that card — the
  `rx-6700-xt/` scripts keep it for reference.)

### Results & data model

Every run writes a self-contained folder `/results/<run-id>/` (run-id defaults to a UTC
timestamp + profile). Output is plain JSON/JSONL/Markdown by design (no Prometheus/Grafana)
so runs diff and archive cleanly. Per-target subdirs hold `telemetry.jsonl`, `stdout.log`,
`stderr.log`, `status.json`, plus benchmark-specific request JSONL/summary JSON. See
`bench-runner/BENCHMARKS.md` for the full telemetry schema and experiment matrix.

### Remote vs in-container execution

- `sync-benchmark-run.sh <ssh-host> <remote-run-dir> [desc]` — copies a finished server-side
  run back to a local checkout and regenerates `REPORT.md` (run benchmarks on the server first).
- `run-remote-benchmark-suite.sh` — uploads suite, runs on a server over SSH, pulls results;
  reads creds from a `config/.env` (gitignored).

## Conventions

- **VMID allocation** (homelab-wide scheme — pick a new script's default `VMID` from the
  matching range):
  - `100-119` — infra / services (currently empty; CT 110 `mealdeal` lived here until the app
    moved into the Docker host — small web apps are now containers on VM 300, not LXCs)
  - `120-139` — AI/LLM containers (CT 120 LLM runtime, hostname `llamacpp`, pinned to GPU 1 of two V620s; the
    prior 6700 XT also offered an `lmstudio` variant. CT 121 `hermes` — the Hermes Agent that
    consumes CT 120's API. CT 122 `coder-runner` — the coding loop's execution sandbox; CT 123 `gpu2` —
    a `llama-swap` server on GPU 2 for the loop (Qwen3-Instruct-2507 coder + Qwen3-Coder-30B reviewer,
    swapped one at a time))
  - `140-159` — databases (CT 140 `kb-rag` — the CognitiveStack hybrid-search API; it lives here
    rather than in the AI range because the durable artifact is a vector+FTS **database**, even
    though its consumers are agents)
  - `200+` — test / temporary (CT 200 `bench-runner` — disposable benchmark LXC)
  - `300+` — **VMs** (VM 300 `docker-host`). The ranges above allocate *containers*; VMs get their
    own range so `pct`/`qm` ids never collide. Apps running as Docker containers on VM 300 do not
    take a VMID at all.
- **Autonomous coding loop / execution isolation (`coder-runner/`, CT 122).** The homelab runs a
  self-driving coder↔reviewer loop on **Hermes kanban** (CT 121): coder/reviewer *profiles* work each task
  in an isolated git worktree/branch, PR-gated (no auto-merge to public `main`). The loop's design rule is
  that **untrusted project code executes only on a separate, generic, disposable LXC — CT 122
  `coder-runner`** (Node + pnpm + git + toolchain, holds no secrets), never inside the Hermes LXC. CT 121 drives
  it over **ssh+rsync** via `checks-on-runner`/`run-on-runner`/`verify-and-commit` helpers (committed under
  `hermes/config/bin/` and deployed into CT 121 by `hermes/config/install.sh`). Key facts learned the hard
  way: Hermes does **not**
  auto-commit managed worktrees and the local model won't reliably run `git`, so commits are made
  deterministically by `verify-and-commit` (checks on CT 122 → commit on the CT 121 host on green); a fix
  task must use `--workspace worktree:<absolute-repo-path>` (plain `worktree`+`--project` fails when created
  from inside a worker); keep worktrees out of the repo tree to avoid `git add -A` swallowing them as
  gitlinks. `coder-runner/create-lxc-coder-runner.sh` provisions CT 122 (once; repo-agnostic — add repos via
  `hermes project`, never a new LXC). See `coder-runner/README.md` and the `autonomous-coding-loop` memory.
  The loop's CT-121-side config (coder/reviewer profiles, the loop helper scripts under `hermes/config/bin/`,
  the `codex-review`/`completion-gate` plugins, the loop's `scope-and-plan`/`review-pr` skills, and the
  `loop-watchdog`/`backlog-tick`/`pr-revise-tick` systemd timers) is committed under **`hermes/config/`**
  (loop/orchestrator only — the box's unrelated KB/homelab automations are not tracked) with an idempotent
  `install.sh` — run it inside CT 121 to (re)deploy. Private Slack channel IDs are parameterized to env vars
  sourced from `/root/.hermes/.env` (see `hermes/config/hermes.env.example`); never commit the real `.env`.
- Keep downloaded model weights and generated results out of git (already covered by
  `.gitignore`: `models/`, `results/`, `artifacts/`, `bench-results*.tgz`, `.env*`).
- Container model storage (`/models`) uses `backup=0` — weights are large and
  re-downloadable; back up container config / service files / small state separately.
- ⚠️ **`backup=` works on MOUNT POINTS only, never on `rootfs`.** PVE rejects it outright
  (`rootfs.backup: property is not defined in schema`) — a container's root disk cannot be
  excluded from `vzdump`. Several scripts here append `backup=0` to the `rootfs` line behind a
  `>/dev/null 2>&1 || true`, so that step is a **silent no-op** (verified on pve-manager 9.2.3);
  don't trust the comment above such a line. Note the defaults are inverted: `rootfs` is always
  backed up, while a mount point defaults to `backup=0` and needs `backup=1` set explicitly. To
  keep a big rootfs out of backups, exclude paths in the backup job instead:
  `vzdump <vmid> --exclude-path /opt/<bulk>`.
- **Backups (`Synology-Backup` NFS, weekly job Sundays 01:00, all guests, keep-last=3).** Two
  traps here, both hit for real on 2026-07-26 after a four-week silent outage:
  - ⚠️ **The Synology allow-lists NFS clients by IP.** The WiFi-NAT cutover moved the host
    `192.168.1.50` → `.93`, so every backup from 2026-07-05 on failed with
    `mount.nfs: access denied by server`. Fixed in DSM (Control Panel → Shared Folder → NFS
    Permissions). It is allow-listed by the **exact IP**, so *another host IP change breaks
    backups again* — prefer a `192.168.1.0/24` rule.
  - ⚠️ **`vzdump` needs `tmpdir: /var/tmp` in `/etc/vzdump.conf`** (set; comment in-file). Its
    temp dir defaults to the *target storage*, and for an **unprivileged** container `tar` runs
    under `lxc-usernsexec` as uid 100000+, which this NAS refuses even though the share reports
    mode 777 (root writes fine). Symptom is a mounted-and-active storage that still fails with
    `Cannot open: Permission denied`. Only small config files go to tmpdir; archives stream
    straight to the NAS. Verified across all four paths — stopped CT, running unprivileged CT
    (snapshot), privileged CT, and QEMU VM.
  - A container **rootfs cannot be excluded** from these backups (see the `backup=` note above),
    but a `backup=0` mount point can — which is why CT 120's `/models` is not in its 3 GB archive.
  - `Synology-Backup` is now the **only** NFS storage. A second one (`Synology`, export
    `/volume1/Plex`) was **removed 2026-07-26**: it declared `content rootdir`, i.e. the Plex
    *media* share registered as a place to put container root disks — unused, and a trap (LXC
    rootfs over NFS is slow and hits the uid-mapping problem above, and it carried no `backup`
    content type). To give a future Plex container its media, **bind-mount the path instead of
    adding a storage**: `pct set <vmid> --mp0 /mnt/pve/<mount>,mp=/media`. That share also held
    **13 GB of vzdump archives from June 2023** (CT 100/101/103, all long gone) in a `dump/` dir
    left over from when it carried `backup` content — **deleted 2026-07-26**, reclaiming 13 GB.
    Both exports live on the same Synology volume, so that space benefits `Synology-Backup` too
    (601 GB → 614 GB free), which matters as keep-last=3 across seven guests accumulates.
  - The Docker host's precious state is its **volumes** (`portainer_data`,
    `mealdeal_mealdeal-data`) — see `docker-host/README.md` for pulling those out separately.
- **Notifications go to Slack, not just root's mailbox.** The four-week backup outage was silent
  because Proxmox's builtin `mail-to-root` target delivers to a local mailbox nobody reads. A
  `slack` webhook endpoint + `slack-all` matcher now forward **every** notification to Slack
  *alongside* mail-to-root. Provisioned by `host-notifications/setup-slack-notifications.sh`
  (re-run it to rotate the URL). The webhook URL path is stored as a Proxmox notification
  **secret** — the API returns only its name, never the value, so it stays out of
  `notifications.cfg` and out of `pvesh get` output.
- The GPUs are driven via **Vulkan** (mesa RADV). The host now runs **two Radeon Pro V620s**
  (Navi 21/gfx1030); the prior RX 6700 XT (Navi 22/gfx1031) is kept only for reference. The
  container installs the Vulkan userspace (`mesa-vulkan-drivers libvulkan1 vulkan-tools`) and
  passes through **only GPU 1's** render node (bind-mounted by PCI address via the `by-path`
  symlink), so llama.cpp offloads all layers (`-ngl 99`) onto that single card; verify with
  `vulkaninfo` / `llama-server --list-devices` (exactly one device) and a non-trivial
  `mem_info_vram_used` on GPU 1 (read by PCI address — `cardN` is not stable) with GPU 2
  near-idle. The bind's dest node name is resolved at provision, so a host DRM renumber (only
  on a GPU add/remove or kernel change) needs GPU 1's mount re-resolved in place (rewrite the
  two entries + restart the CT — see the README "Recovering after a DRM renumber" recipe; a
  plain re-run is rejected while the CT exists). The `llamacpp-serve` guard turns the
  otherwise-silent CPU fallback into a loud startup failure.
- **V620 host-side GPU services live under `pro-v620/` and run on the Proxmox host (NOT in the
  LXC)**, each with an idempotent `install.sh` + systemd unit + `.env`. `pro-v620/fan-control/`
  runs one `gpu-fan-control@<instance>` per **cooler** (out-of-tree `nct6687`) — currently a
  single **`@shroud`→pwm3** driving one NF-F12 iPPC-3000 120 mm fan in a shared shroud that cools
  **both** cards (curve tracks the hotter card; a required sensor missing on either forces 100%).
  Prior per-GPU env files (`@blower`→pwm2, `@arctic`→pwm4 for 2× Arctic S4028-6K) are kept in-repo
  for reference. Each instance pins its GPU(s) by PCI address and is driven off the card temp(s);
  `pro-v620/undervolt/` applies a persistent GFX **voltage offset** to **every** V620
  (both at −100 mV). The V620's board power
  is **firmware-locked at 250 W** (`power1_cap` write of any other value → `-EINVAL`) and
  OverDrive exposes no clock-ceiling knob, so an undervolt is the only power/thermal lever
  (−100 mV ≈ −18 % power / −8 °C peak junction at flat throughput). The undervolt installer also
  enables OverDrive via `/etc/modprobe.d/amdgpu-overdrive.conf` (needs a reboot to take effect).
- **A last-resort GPU over-temp watchdog lives under `pro-v620/gpu-thermal-watchdog/`** (also
  host-side, NOT in an LXC; same idempotent `install.sh` + systemd unit + `.env` idiom, but no
  kernel module — it only *reads* amdgpu hwmon). It watches junction/mem on both V620s and, if
  either crosses a trip temp (default **102 °C** junction / 101 °C mem — deliberately **above**
  the 100 °C hardware throttle, **below** the 105 °C emergency reset), gracefully stops the LLM
  server (`pct exec 120 -- systemctl stop llamacpp`) so the card cools before the hardware has to
  reset it (a MODE1 reset corrupts the running inference). Failure philosophy is the **opposite**
  of the fan controller's: stopping the model is disruptive, so a missing sensor is logged and
  skipped rather than treated as over-temp (the 105 °C hardware emergency is the final backstop).
  It never fires in the split (normal) config (~59 °C) — only a sustained **solo full-load** on
  one card reaches these temps (which pushes a single card's cooling to its limit).
- **Non-GPU host networking lives under `host-net/`** (also host-side, NOT in an LXC).
  `host-net/wifi-nat/` lets the host run with **no ethernet**: onboard WiFi (`wlo1`) becomes the
  routed WAN and `vmbr0` becomes an internal NAT'd LAN (`10.10.10.0/24`) the LXCs sit behind
  (dnsmasq DHCP/DNS + nftables masquerade/port-forwards, reservations `.120`→CT120 / `.121`→CT121).
  Same idempotent-`install.sh` + `.env` idiom, but **staged/transactional** because it re-points
  the host's own uplink: `stage → --test-wifi → --cutover → --confirm`, with an armed auto-rollback
  (a full, verified teardown) as the safety net and `--revert` to undo. Containers keep `ip=dhcp`
  (no per-CT change) — they just get `10.10.10.x` and are reached from the LAN via the host's WiFi
  IP + the DNAT port-forwards. Consumers that hard-code a container's IP (e.g. Hermes's
  `model.base_url`, the bench-runner's `MODEL_API_URL`) must use the dnsmasq name / be re-pointed
  after the cutover changes CT 120's address.
