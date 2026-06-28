# AI Homelab Benchmarks

This toolkit writes benchmark results as plain JSON/JSONL under
`/results/<run-id>/`. It does not require Prometheus or Grafana. The files are
deliberately simple so they can be diffed, archived, or imported into a
database later.

## What The Bench Runner Captures

Running from the benchmark runner LXC records client-side metrics (latency, TTFT,
throughput) **and** GPU telemetry — utilization, VRAM, core clocks, and
temperatures — because `system-sampler.py` reads the Proxmox host's
`/sys/class/drm` and hwmon even from this unprivileged container. So the GPU and
temperature SLO checks run from here; you do not need to benchmark on the LLM
runtime host to get GPU data.

Caveat: the amdgpu counters are only meaningful under active load — LM Studio frees
VRAM when idle (so `mem_info_vram_used` reads near-zero between requests; a
resident `llama-server` keeps it allocated), and
`gpu_busy_percent` can occasionally return `EBUSY`. Read the per-run telemetry
peaks, and judge whether the model is truly on the GPU by throughput (~50 tok/s on
GPU vs ~5-10 on CPU for this 9B-Q4), not the idle VRAM counter.

Each run also preflights the endpoint and aborts early if `MODEL_API_URL` is
unreachable or `MODEL_IDENTIFIER` is not served (override with
`BENCHMARK_PREFLIGHT=false`).

## What Gets Recorded

Each benchmark target gets its own directory with:

- `telemetry.jsonl` - samples taken **inside the bench-runner LXC** during the
  run. GPU + temperature fields are host-real (sysfs is not virtualized), but
  CPU/RAM/process fields describe the bench-runner *client*, not the model server.
- `stdout.log` and `stderr.log` - raw command output.
- `status.json` - exit code and completion status.
- Benchmark-specific request JSONL and summary JSON.

When a run is launched through the Ansible batch (or wrapped manually with
`host/run-with-target-telemetry.sh`), the run folder also gets:

- `target-telemetry.jsonl` - the same sampler run **inside the model container
  (CT 120)**, so its CPU/RAM/process fields reflect the model server itself
  (LM Studio or `llama-server`). This is the
  authoritative source for "was the server CPU/RAM-bound?". After merging it, the
  wrapper regenerates the run's `REPORT.md` (a "Model Server Telemetry" section)
  and `SLO.md` (a `model-server-target` entry) via `finalize-run.py`, so the
  server-side data actually feeds the report and SLO verdict.

Telemetry includes the best available local data:

- CPU count, load average, `/proc/stat`, CPU frequency, pressure stall info.
- RAM and swap from `/proc/meminfo`.
- Disk and network counters from `/proc`.
- Temperatures from Linux thermal zones and hwmon.
- Optional `sensors -j` output when `lm-sensors` is installed.
- Optional `nvidia-smi` output for NVIDIA GPUs.
- Optional `rocm-smi --json` output for AMD GPUs.

## Quick Start

Run benchmarks from the benchmark runner LXC. The runner targets the configured
OpenAI-compatible endpoint in `MODEL_API_URL`; by default the creation script
sets that to CT `120`'s URL (whichever runtime engine is serving there).

```bash
cd /opt/bench-runner
BENCHMARK_PROFILE=baseline \
./scripts/benchmarks/run-ai-benchmark-suite.sh
```

The default run compares:

- Direct OpenAI-compatible requests to the configured endpoint.
- Optional `llama-benchy` runs against the same endpoint.

Summarize the newest run:

```bash
latest="$(ls -td /results/* | head -1)"
python3 scripts/benchmarks/summarize-benchmark-run.py "$latest"
```

The suite also writes `REPORT.md`, `SLO.md`, `versions.json`, and
`system-logs/` snapshots into the run folder.

If the benchmark was run on a different machine than this repo checkout, sync
the completed server-side run back afterward:

```bash
./scripts/benchmarks/sync-benchmark-run.sh \
  <ssh-host> \
  /results/<run-id> \
  "Baseline run: current hardware, model, and runtime configuration."
```

## Direct API Only

```bash
cd /opt/bench-runner
source /etc/bench-runner.env
python3 scripts/benchmarks/benchmark-openai-api.py \
  --base-url "$MODEL_API_URL" \
  --model "$MODEL_IDENTIFIER" \
  --label direct \
  --output-dir /results/manual-direct \
  --scenario smoke \
  --scenario short \
  --scenario medium \
  --requests 5 \
  --concurrency 1
```

## Profiles, Promptsets, SLOs, And Comparison

- Profiles: `config/benchmark-profiles/*.env`.
- Default promptset: `config/benchmark-promptsets/homelab-core.jsonl`.
- Default SLO thresholds: `config/benchmark-slos/default.json`.
- Run comparison: `scripts/benchmarks/compare-benchmark-runs.py`.

Example:

```bash
BENCHMARK_PROFILE=concurrency \
BENCHMARK_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-qwen35-9b-q4-concurrency4" \
./scripts/benchmarks/run-ai-benchmark-suite.sh

python3 scripts/benchmarks/compare-benchmark-runs.py \
  /results/<baseline-run> \
  /results/<candidate-run> \
  --output /results/<candidate-run>/COMPARE.md
```

Use higher concurrency to find throughput limits:

```bash
source /etc/bench-runner.env
python3 scripts/benchmarks/benchmark-openai-api.py \
  --base-url "$MODEL_API_URL" \
  --model "$MODEL_IDENTIFIER" \
  --label direct-c4 \
  --output-dir /results/manual-direct-c4 \
  --scenario medium \
  --requests 16 \
  --concurrency 4
```

## Optional llama-benchy Benchmark

`llama-benchy` benchmarks OpenAI-compatible `/v1/chat/completions` endpoints in
a llama-bench-like style. It measures prompt processing and token generation at
different context depths and supports repeated runs, concurrency, and JSON
output.

The default invocation includes `--no-warmup --no-adapt-prompt` because some
OpenAI-compatible prompt templates reject the warmup request shape used by
`llama-benchy` 0.3.x.

If it is installed on the server:

```bash
cd /opt/bench-runner
RUN_LLAMA_BENCHY=true \
BENCHMARK_PROFILE=baseline \
./scripts/benchmarks/run-ai-benchmark-suite.sh
```

If `uvx` is available and network access is acceptable on the server:

```bash
RUN_LLAMA_BENCHY=true \
LLAMA_BENCHY_USE_UVX=true \
BENCHMARK_PROFILE=baseline \
./scripts/benchmarks/run-ai-benchmark-suite.sh
```

Override the matrix:

```bash
source /etc/bench-runner.env
RUN_LLAMA_BENCHY=true \
LLAMA_BENCHY_ARGS="--base-url $MODEL_API_URL --model $MODEL_IDENTIFIER --pp 512 2048 4096 --tg 32 128 --depth 0 4096 8192 --runs 3 --no-warmup --no-adapt-prompt --latency-mode generation --format json --save-result /results/llama-benchy-results.json" \
./scripts/benchmarks/run-ai-benchmark-suite.sh
```

## Hardware Bottleneck Sweeps

These find *where* the hardware stops scaling, not which model is best. Both are
client-side and run from the bench-runner LXC.

Concurrency sweep — find the throughput saturation knee and where tail latency
blows up:

```bash
pct exec 200 -- bash -lc 'llm-bench-sweep concurrency --points 1 2 4 8 16 --requests 16'
```

Input-length (prefill / TTFT) sweep — map how TTFT scales with prompt size:

```bash
pct exec 200 -- bash -lc 'llm-bench-sweep input-length --points 128 512 2048 8192 32768 --output-tokens 32'
```

Each writes `curve.json` + `curve.md` (and a per-point breakdown) under a new
`/results/<run-id>-sweep-*/` folder. The concurrency curve also flags the knee.

A sweep only shows the *symptom* (latency/throughput). To capture the hardware
*cause* during a sweep, wrap it with the GPU-host telemetry tool below.

## GPU-Host Telemetry And Context Sweep

The bench-runner LXC cannot see the GPU. These two scripts run **on the Proxmox
host** (from a repo checkout, not inside the LXC) and coordinate the GPU
container (CT 120) with the bench-runner (CT 200).

Sample the GPU container (utilization, VRAM, core clock, temps) while any
benchmark runs, then summarize the peaks:

```bash
./host/run-with-host-telemetry.sh pct exec 200 -- bash -lc 'llm-bench-baseline'
# or wrap a sweep:
./host/run-with-host-telemetry.sh pct exec 200 -- bash -lc 'llm-bench-sweep concurrency'
```

It prints whether the GPU saturated (util %), how close VRAM got to full, and
the core-clock range (a drop under sustained load points at thermal/power
throttling). `summarize-telemetry.py` does the same for any saved
`telemetry.jsonl`.

To capture the model server's **CPU/RAM/process** load (the part the in-LXC
sampler gets wrong, because it sees only the bench-runner client), wrap a run
with `run-with-target-telemetry.sh` instead. It samples CT 120 from the host and
merges a `target-telemetry.jsonl` into each new `/results/<run-id>/`:

```bash
GPU_VMID=120 BENCH_VMID=200 \
  ./host/run-with-target-telemetry.sh -- pct exec 200 -- bash -lc 'llm-bench-baseline'
```

The Ansible batch (`make bench`) wraps every benchmark with this automatically.

Context-length / VRAM sweep — reload the model at each context length and
measure VRAM, TTFT, latency, and throughput per step (context/KV cache is
usually the dominant VRAM bottleneck). Engine-aware via `RUNTIME` (`lmstudio`
reloads via the `lms` CLI; `llamacpp` via the container's `llamacpp-reload`
helper):

```bash
CONTEXTS="4096 16384 32768 65536" ./host/run-context-sweep.sh                 # lmstudio
RUNTIME=llamacpp CONTEXTS="4096 16384 32768 65536" ./host/run-context-sweep.sh # llama.cpp
```

It writes `context-sweep.md` correlating context length with peak VRAM and GPU
utilization (from host telemetry) and TTFT/latency/throughput (from the client).

## Suggested Experiment Matrix

Change one variable per run:

- Model: same prompt set, different model.
- Quantization: same model family, different GGUF quant.
- Context: 4k, 16k, 32k, 64k.
- Concurrency: 1, 2, 4, 8.
- GPU settings: power limit, clocks, fan curve, layer offload.
- Runtime: any OpenAI-compatible server (LM Studio, llama.cpp server, vLLM, Ollama).

Useful environment variables:

```bash
BENCHMARK_SCENARIOS=smoke,short,medium,long
BENCHMARK_RUNS=3
BENCHMARK_REQUESTS=3
BENCHMARK_CONCURRENCY=1
TELEMETRY_INTERVAL=1
MODEL_API_URL=http://<runtime-lxc-ip>:1234/v1
MODEL_IDENTIFIER=<served-model-id>
BENCHMARK_RUN_ID=baseline
```

## Extra Things Worth Logging

If your machine supports them, add these over time:

- Wall power from a smart plug or UPS: watts, watt-hours, joules/request.
- Ambient room temperature.
- Fan RPM and fan curve.
- GPU throttle reason.
- PCIe link width and generation.
- VRAM memory clock and memory temperature.
- SSD/NVMe temperature and SMART wear percentage.
- Kernel logs for OOM kills, GPU resets, ECC errors, and thermal throttling.
- Model file SHA-256 and runtime commit/version.
- Exact driver, ROCm/CUDA, kernel, BIOS, and power-limit settings.

The boring metadata is what makes a six-month-old benchmark still useful.
