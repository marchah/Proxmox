# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of Bash provisioning scripts (with embedded Python) that create and operate
Proxmox LXC containers for a local AI homelab. There is no application to build or test
suite to run — the "product" is the scripts themselves, executed **on the Proxmox host as
root**. macOS is only the authoring/editing environment; the scripts run remotely against
`pct`/`pveam`.

Two containers form the system:

- **CT 120** (`rx-6700-xt/`): a *privileged* Ubuntu LXC — the **LLM runtime** — serving
  `Qwen3.5-9B-Q4_K_M.gguf` on a Radeon RX 6700 XT via Vulkan, exposing an OpenAI-compatible
  API at `0.0.0.0:1234`. Two **interchangeable engine scripts** target this slot; both
  default to VMID 120 and serve the model under the id `qwen3.5-9b`, so they are mutually
  exclusive — run one at a time (only one can use the GPU):
  - `create-lxc-lmstudio-qwen3.5-9b.sh` — LM Studio's `lms` CLI (hostname `lmstudio`).
  - `create-lxc-llamacpp-qwen3.5-9b.sh` — llama.cpp's `llama-server` (hostname `llamacpp`).
- **CT 200 `bench-runner`** (`bench-runner/`): an *unprivileged* Debian LXC that benchmarks
  that endpoint. It auto-discovers CT 120's IP at provisioning time. It lives in the
  `200+` test/temporary range because it is disposable — destroy it when done. The suite is
  engine-neutral (it speaks OpenAI `/v1`), so it benchmarks either engine unchanged.

VMIDs `120`/`200` and hostnames are defaults overridable via env vars (`VMID=`, `LXC_HOSTNAME=`, etc.).

## Common commands

All run on the Proxmox host as root.

```bash
# Provision the GPU LLM-runtime container (CT 120) — pick ONE engine (mutually exclusive)
./rx-6700-xt/create-lxc-lmstudio-qwen3.5-9b.sh    # LM Studio (lms)
./rx-6700-xt/create-lxc-llamacpp-qwen3.5-9b.sh    # llama.cpp (llama-server)

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
mega-launcher — the RX 6700 XT already has two sibling scripts (`...-lmstudio-...` and
`...-llamacpp-...`) serving the same model on the same GPU via Vulkan.
For the RX 6700 XT this means Vulkan (mesa RADV) — the container installs `mesa-vulkan-drivers`
and passes through `/dev/dri` (render node `renderD128`) — plus a pinned model repo/file/SHA-256
in a privileged container.

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
- `llama-server --alias qwen3.5-9b` makes `/v1/models` report a stable id (else it reports the
  model file path); that id is what the bench-runner records as `MODEL_IDENTIFIER`.

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

### Benchmark orchestration

`bench-runner/scripts/benchmarks/run-ai-benchmark-suite.sh` is the engine. Flow:

1. **Layered config** (process env wins, because every file default uses `: "${VAR:=...}"`
   — including `MODEL_API_URL`/`MODEL_IDENTIFIER`, so a per-run override actually takes
   effect): `config/local-model.env` (written at provisioning: the LM Studio
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
run from here. Caveat: the amdgpu counters are only meaningful under active load — LM Studio
frees VRAM when idle (so `mem_info_vram_used` reads ~0 between requests; don't read it idle
and conclude "CPU" — judge that by throughput), and `gpu_busy_percent` can return `EBUSY`.
Trust the per-run telemetry peaks. `evaluate-slos.py` still skips any check whose data is
genuinely absent. **CPU/RAM/process metrics from the in-LXC sampler are lxcfs-virtualized to
CT 200 — they describe the benchmark *client*, not LM Studio.** To judge whether the model
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
  bench, so CPU/RAM/process metrics reflect LM Studio (not the bench-runner client); the
  Ansible batch wraps every run with it and merges `target-telemetry.jsonl` into the result.
  `run-context-sweep.sh` reloads LM Studio at each context length and
  correlates VRAM with TTFT/latency/throughput — still useful, because the per-context reload
  is the part the in-LXC suite can't do. **Caveat: the model-reload paths — `run-context-
  sweep.sh` and the Ansible batch's per-item reload (`ansible/benchmark.yml` `model_reload_cmd`,
  `ansible/benchmark_item.yml`) — are LM-Studio-specific (they shell out to the `lms` CLI).**
  The in-LXC suite and telemetry are engine-neutral; only these host reload hooks assume LM
  Studio. For a llama.cpp CT 120, reload with `llamacpp-reload <ctx> <parallel>` instead (they
  have not been generalized — minimal scope).

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
  - `100-119` — infra / services
  - `120-139` — AI/LLM containers (CT 120 LLM runtime: `lmstudio` or `llamacpp`)
  - `140-159` — databases
  - `200+` — test / temporary (CT 200 `bench-runner` — disposable benchmark LXC)
- Keep downloaded model weights and generated results out of git (already covered by
  `.gitignore`: `models/`, `results/`, `artifacts/`, `bench-results*.tgz`, `.env*`).
- Container model storage (`/models`) uses `backup=0` — weights are large and
  re-downloadable; back up container config / service files / small state separately.
- The RX 6700 XT is driven via **Vulkan** (mesa RADV): the container installs the Vulkan
  userspace (`mesa-vulkan-drivers libvulkan1 vulkan-tools`) and passes through `/dev/dri`
  (render node `renderD128`). The engine offloads all layers to the GPU (LM Studio
  `--gpu max`, llama.cpp `-ngl 99`); verify with `vulkaninfo` and a non-trivial
  `mem_info_vram_used`.
