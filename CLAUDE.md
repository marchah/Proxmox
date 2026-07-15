# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of Bash provisioning scripts (with embedded Python) that create and operate
Proxmox LXC containers for a local AI homelab. There is no application to build or test
suite to run — the "product" is the scripts themselves, executed **on the Proxmox host as
root**. macOS is only the authoring/editing environment; the scripts run remotely against
`pct`/`pveam`.

Three containers form the system:

- **CT 120** (`pro-v620/`): a *privileged* Ubuntu LXC — the **LLM runtime** — serving
  `Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf` (MoE, 35B total / ~3B active) via Vulkan, exposing an
  OpenAI-compatible API at `0.0.0.0:1234` under the id `qwen3.6-35b-a3b`. The host now has
  **two Radeon Pro V620s** (Navi 21 / gfx1030, 32 GB each): one in the **PCIe-1** (CPU) slot
  `0000:2d:00.0`, one in the **PCIe-3** (chipset) slot `0000:06:00.0`, both cooled by a single
  **NF-F12 iPPC-3000** 120 mm fan in a shared shroud (one `gpu-fan-control@shroud` instance whose
  curve tracks the hotter card). CT 120 is **pinned to GPU 1 alone** (`0000:2d:00.0`): its
  container bind-mounts only that card's `/dev/dri` render node (via the udev-stable `by-path`
  symlink — the reboot-stable way to pin one of two identical cards), so llama.cpp sees a single
  Vulkan device and runs the whole ~26.6 GB model on it. **GPU 2 (`0000:06:00.0`) is left idle/free**
  for a future second service; it stays amdgpu-bound so the host fan/undervolt/watchdog services
  still manage both. Both cards are undervolted −100 mV:
  - `pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh` — llama.cpp's `llama-server`
    (hostname `llamacpp`). This is the current runtime.
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
- **CT 200 `bench-runner`** (`bench-runner/`): an *unprivileged* Debian LXC that benchmarks
  that endpoint. It auto-discovers CT 120's IP at provisioning time. It lives in the
  `200+` test/temporary range because it is disposable — destroy it when done. The suite is
  engine-neutral (it speaks OpenAI `/v1`), so it benchmarks either engine unchanged.

VMIDs `120`/`121`/`200` and hostnames are defaults overridable via env vars (`VMID=`, `LXC_HOSTNAME=`, etc.).

## Common commands

All run on the Proxmox host as root.

```bash
# Provision the GPU LLM-runtime container (CT 120) — GPU: GPU 1 of two Radeon Pro V620 (GPU 2 left idle)
./pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh # llama.cpp (llama-server), Qwen3.6-35B-A3B MoE
# Prior GPU (RX 6700 XT) — kept for reference; pick ONE engine (mutually exclusive)
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
defaults to ctx 262144 / `--parallel 4` (the model's ~256k native max, 64k per slot; this
MoE's KV cache is cheap, ~20 KB/token, ~29.8 GiB total at Q5). A single agent needing the whole
256k window uses `llamacpp-reload 262144 1`; tunable via `llamacpp-reload`.)

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
  - `100-119` — infra / services
  - `120-139` — AI/LLM containers (CT 120 LLM runtime, hostname `llamacpp`, pinned to GPU 1 of two V620s, GPU 2 idle; the
    prior 6700 XT also offered an `lmstudio` variant. CT 121 `hermes` — the Hermes Agent that
    consumes CT 120's API. CT 122 `coder-runner` — the autonomous coding loop's execution sandbox)
  - `140-159` — databases
  - `200+` — test / temporary (CT 200 `bench-runner` — disposable benchmark LXC)
- **Autonomous coding loop / execution isolation (`coder-runner/`, CT 122).** The homelab runs a
  self-driving coder↔reviewer loop on **Hermes kanban** (CT 121): coder/reviewer *profiles* work each task
  in an isolated git worktree/branch, PR-gated (no auto-merge to public `main`). The loop's design rule is
  that **untrusted project code executes only on a separate, generic, disposable LXC — CT 122
  `coder-runner`** (Node + git + toolchain, holds no secrets), never inside the Hermes LXC. CT 121 drives
  it over **ssh+rsync** via `checks-on-runner`/`run-on-runner`/`verify-and-commit` helpers (installed into
  the coder/reviewer profiles, not this repo). Key facts learned the hard way: Hermes does **not**
  auto-commit managed worktrees and the local model won't reliably run `git`, so commits are made
  deterministically by `verify-and-commit` (checks on CT 122 → commit on the CT 121 host on green); a fix
  task must use `--workspace worktree:<absolute-repo-path>` (plain `worktree`+`--project` fails when created
  from inside a worker); keep worktrees out of the repo tree to avoid `git add -A` swallowing them as
  gitlinks. `coder-runner/create-lxc-coder-runner.sh` provisions CT 122 (once; repo-agnostic — add repos via
  `hermes project`, never a new LXC). See `coder-runner/README.md` and the `autonomous-coding-loop` memory.
- Keep downloaded model weights and generated results out of git (already covered by
  `.gitignore`: `models/`, `results/`, `artifacts/`, `bench-results*.tgz`, `.env*`).
- Container model storage (`/models`) uses `backup=0` — weights are large and
  re-downloadable; back up container config / service files / small state separately.
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
