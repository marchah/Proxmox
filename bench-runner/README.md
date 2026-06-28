# Benchmark Runner LXC

This folder creates a small disposable LXC for running the local AI benchmark
suite.

The goal is repeatable results across Proxmox changes while keeping benchmark
tooling out of the LLM runtime container (CT 120). The suite targets an
OpenAI-compatible `/v1` endpoint, so it benchmarks either runtime engine
(LM Studio or llama.cpp) without changes.

## What Gets Installed

The script creates an unprivileged Debian LXC and installs the benchmark suite
under:

```text
/opt/bench-runner
```

It includes:

- `scripts/benchmarks/run-ai-benchmark-suite.sh`
- `scripts/benchmarks/benchmark-openai-api.py`
- `scripts/benchmarks/system-sampler.py`
- `scripts/benchmarks/evaluate-slos.py`
- `scripts/benchmarks/write-benchmark-report.py`
- benchmark profiles, promptsets, and SLO config under `config/`
- optional `llama-benchy`
- optional `lm_eval`

The LXC writes results to `/results`.

## Create The Runner

Run on the Proxmox host as `root`:

```bash
./create-lxc-bench-runner.sh
```

Or run directly from GitHub without cloning:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/marchah/Proxmox/main/bench-runner/create-lxc-bench-runner.sh)"
```

Useful overrides:

```bash
VMID=200 LXC_HOSTNAME=bench-runner ./create-lxc-bench-runner.sh
TARGET_LXC_VMID=120 ./create-lxc-bench-runner.sh
TARGET_BASE_URL=http://192.168.50.123:1234/v1 ./create-lxc-bench-runner.sh
OPENAI_MODEL=served-model-id ./create-lxc-bench-runner.sh
INSTALL_LM_EVAL=0 ./create-lxc-bench-runner.sh
```

By default, the script tries to discover CT `120`'s IP and writes the target
OpenAI-compatible API URL to:

```text
/opt/bench-runner/config/local-model.env
```

It also queries `<target-url>/models` and uses the first served model id. Use
`OPENAI_MODEL` only if you need to force a specific model id.

## Benchmark Commands

Run these from the Proxmox host. Wrap each in `bash -lc '…'` so `/usr/local/bin`
(where the wrappers live) is on PATH — bare `pct exec` uses a minimal PATH that
omits it:

```bash
pct exec 200 -- bash -lc 'llm-bench-baseline'
pct exec 200 -- bash -lc 'llm-bench-concurrency'
pct exec 200 -- bash -lc 'llm-bench-soak'
pct exec 200 -- bash -lc 'llm-bench-quality'
```

The wrappers call the benchmark suite with these profiles:

- `baseline`
- `concurrency`
- `soak`
- `quality`

The runner only targets the LLM runtime's OpenAI-compatible endpoint (LM Studio
or llama.cpp). Each profile runs `openai-direct` and `llama-benchy` by default;
the `quality` profile also runs `lm-eval`.

For advanced overrides:

```bash
pct exec 200 -- bash -lc 'BENCHMARK_REQUESTS=5 BENCHMARK_CONCURRENCY=2 llm-bench-baseline'
pct exec 200 -- bash -lc 'RUN_LLAMA_BENCHY=false llm-bench-suite'
pct exec 200 -- bash -lc 'BENCHMARK_PROFILE=baseline BENCHMARK_RUN_ID=manual-test llm-bench-suite'
```

## Bottleneck Sweeps

Find where the hardware stops scaling (not which model is best):

```bash
pct exec 200 -- bash -lc 'llm-bench-sweep concurrency --points 1 2 4 8 16'
pct exec 200 -- bash -lc 'llm-bench-sweep input-length --points 128 512 2048 8192'
```

Each writes `curve.md`/`curve.json`; the concurrency sweep flags the saturation knee.

## Hardware-Bottleneck Tools (Proxmox host)

The suite already records GPU util/VRAM/clocks/temps from inside the LXC (see
Metrics Scope below), so the context sweep is the main host-side tool — it reloads
the model at each context length, which the in-LXC suite can't do. The sweep and
the Ansible batch are **engine-aware** via `RUNTIME` (`lmstudio` | `llamacpp`):
lmstudio reloads via the `lms` CLI, llamacpp via the container's `llamacpp-reload`
helper (restart, waits for `/health`).

```bash
# Sweep context length and correlate VRAM with TTFT/latency/throughput
CONTEXTS="4096 16384 32768 65536" ./host/run-context-sweep.sh                 # lmstudio (default)
RUNTIME=llamacpp CONTEXTS="4096 16384 32768 65536" ./host/run-context-sweep.sh # llama.cpp

# Optional (redundant with the suite's own telemetry): sample a container's GPU
# around any command — handy for non-benchmark commands
./host/run-with-host-telemetry.sh pct exec 200 -- bash -lc 'llm-bench-baseline'
```

See `BENCHMARKS.md` for details.

## Metrics Scope

This runner records request latency, TTFT, and throughput (client side) **and**
GPU telemetry — utilization, VRAM, core clocks, and temperatures — because
`system-sampler.py` reads the Proxmox host's `/sys/class/drm` and hwmon even from
this unprivileged LXC. A baseline run captured 99% GPU util, 7.24 GiB VRAM, and a
103 °C junction temperature, and the GPU/temperature SLO checks ran.

Caveat: the amdgpu counters are only meaningful **under load**. LM Studio frees
VRAM when idle, so `mem_info_vram_used` reads near-zero between requests — don't
read it at idle and conclude the model is on CPU (judge that by throughput);
`gpu_busy_percent` can also return `EBUSY`. Trust the per-run telemetry peaks.

Before each run, the suite preflights the endpoint and aborts with a clear error
if `MODEL_API_URL` is unreachable or `MODEL_IDENTIFIER` is not served. Set
`BENCHMARK_PREFLIGHT=false` to skip (e.g. a server with no `/v1/models` route).

## Results

Each run writes a benchmark run folder under `/results`:

```text
/results/<run-id>/
  REPORT.md
  SLO.md
  manifest.json
  versions.json
  openai-direct/
  llama-benchy/
  slo-report.json
```

Download the results archive to the Proxmox host:

```bash
pct exec 200 -- tar -C /results -czf /tmp/bench-results.tgz .
pct pull 200 /tmp/bench-results.tgz ./bench-results.tgz
```

Compare two runs:

```bash
pct exec 200 -- bash -lc 'llm-bench-compare /results/<baseline-run> /results/<candidate-run>'
```

Inspect the configured environment:

```bash
pct exec 200 -- bash -lc 'llm-bench-env'
```

## Cleanup

Destroy the benchmark runner when finished:

```bash
pct stop 200
pct destroy 200 --purge
```
