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

### Prefill and decode rates

`output_tokens_per_second` and `aggregate_output_tokens_per_second` divide output
tokens by the whole request or run, so prefill, decode and queueing are mixed into
one number. Each request row also records the two phases separately:

| Field | Meaning |
| --- | --- |
| `prefill_tokens_per_second` | pp: prompt tokens processed per second |
| `decode_tokens_per_second` | tg: generated tokens per second after the first |
| `prefill_tokens`, `prefill_cached_tokens` | tokens prefilled, and prompt tokens served from the slot cache |
| `draft_tokens`, `draft_accepted_tokens` | speculative drafts proposed and accepted (null without speculation) |
| `rate_source` | `server` = llama-server `timings`; `client` = estimate from a stream |
| `timings` | the raw llama-server `timings` object |

The `client` estimate (pp = prompt tokens / TTFT, tg = tokens after the first / time
after the first) includes network and queueing time. Don't compare it with `server` rows.
Summaries carry `prefill_tokens_per_second` / `decode_tokens_per_second` stats
overall and per scenario. Compare pp only between scenarios with the same prompt
length: prefill speeds up with batch size. `REPORT.md`, the sweeps and
`compare-benchmark-runs.py` show the medians.

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

## Prompt Text

The `medium` and `long` scenarios, the sweeps and both workloads below send real text:
this repository's Markdown, then its code, at commit `f7e762c` (`bench_common.py`). The
first run downloads that commit's archive from GitHub, checks the text against pinned
checksums and caches it under `cache/`. Without network access, build it from a checkout:

```bash
git archive --format=tar.gz f7e762c53388be0ba06751dd210aacef3e30b7c5 \
  | python3 scripts/benchmarks/bench_common.py --source -
```

Sweep and ingestion prompts are cut with the server's tokenizer (`/tokenize`), so a given
size is the same token count on any model.

Every `openai-direct` and sweep request starts with its own id (`[<salt>-<n>] `, ~11
tokens), so the prompt cache cannot serve a repeated prompt. Without it, on CT 120
(b11475), the second and third of three identical 32-token requests prefilled 4 tokens
and took 28 from the cache, reading 32–38 tok/s against 125 tok/s cold. The openai
manifest records `cold_requests: true`.

Older runs do not compare with later ones; their openai manifest tells which:

- No `corpus` key: the `medium` and `long` scenarios and the sweeps sent a repeated
  sentence or the word "token".
- No `cold_requests` key: each promptset prompt was sent verbatim, and a repeat was
  served from cache when it landed on the slot that held its previous copy. That is
  every repeat at concurrency 1 (baseline, context sweep, GPU 2's single slot), and
  fewer when several copies were in flight at once (the `concurrency` and `soak`
  profiles). Their prefill rates and TTFT are skewed by it.

## Agent Sessions And Document Ingestion

The regression items send prompts of a few hundred tokens. CT 120's real work is long: of
its 3,642 requests from MTP going live on 2026-09-22 to 2026-10-02, 83% reused a cached
prefix (median 32k tokens), and requests that prefilled 8k+ new tokens were 5% of requests
but 43% of all prefill. Two workloads measure that work. The `workloads` profile runs them, and
`make bench` runs that profile after the regression items.

### Agent sessions

`benchmark-agent-session.py` (target `agent-sessions/`) sends scripted sessions. A session
is one conversation that grows turn by turn: each turn adds a tool result and a request,
the model's reply stays in the history, and the prompt cache stays on, so a turn prefills
only the new message. A session ends once its prompt reaches the preset's depth.

| Preset | Shape | Depth |
| --- | --- | ---: |
| `hermes` | A ~9k-token cold start (system prompt and notes), then tool results of ~100 to ~4,000 tokens with replies capped at 20 to 750 tokens, sized to CT 120's Hermes requests (median 564 new prompt tokens and 184 generated; 90th percentile 4,326 new) | 64k |
| `coding` | ~4.7k-token file reads with replies capped at 160 tokens, and a code-writing request capped at 512 every third turn | 124k |

`PRESET:2` runs two sessions at once, each reading a different part of the text. Every
session opens with its own id, so no session or repetition reuses another's cache, in a
slot or in llama-server's host-memory prompt cache. Decoding is greedy. Before sending
anything, the script reads `/props` and refuses (exit 2) a slot layout that cannot hold its
sessions: `coding` needs 128k slots, which CT 120 has at 262144 with `--parallel 2`.
`--depth N` (`BENCHMARK_AGENT_DEPTH`) stops every session at N tokens, for servers with
smaller slots; when a preset does not fit, the refusal names the largest depth that does.
Band rates still compare where depths overlap; session times do not.

`agent-summary.json` has one entry per preset in `runs`:

| Field | Meaning |
| --- | --- |
| `session_wall_seconds` | First request to last reply of a rep (all its sessions), median/min/max over reps |
| `final_depth`, `prefill_tokens_per_rep`, `decode_tokens_per_rep` | How deep the sessions went and the tokens each rep prefilled and generated |
| `first_turn` | The cold first turn's size and rates |
| `bands` | Per depth band (the depth a turn prefills at): turns, tokens, token-weighted prefill and decode rates, draft acceptance |
| `cache_misses` | Warm turns that re-prefilled the history because another client took the slot; left out of `bands` |
| `finish_length` | Replies cut at their cap |

Band rates are all tokens over all time in the band, so a few large prefills are not
outvoted by many small ones. `agent-requests.jsonl` has one row per turn: depth before and
after, `prompt_n`/`cache_n`, rates, draft counts, finish reason and the first 200
characters of the reply.

### Document ingestion

`benchmark-doc-ingest.py` (target `doc-ingest/`) fills the prompt with documents to 8k,
16k, 32k and 48k tokens, with the prompt cache off, and asks for a ~500-token note with
three sections. Depths run interleaved and each rep starts at the next depth. A depth sends
the same text every time, so greedy output should repeat. `ingest-summary.json` has one
entry per depth in `by_depth`: prompt tokens, prefill rate and time (the time to first
token), decode rate, output tokens, draft acceptance, finish reasons, notes with all three
sections (`sections_ok`) and whether every rep returned the same text (`repeatable`). A
request the cache served in part counts as an error (`warm_cache`).

### Running them

```bash
pct exec 200 -- bash -lc 'llm-bench-workloads'
pct exec 200 -- bash -lc 'RUN_DOC_INGEST=false BENCHMARK_AGENT_PRESETS="coding:2" llm-bench-workloads'
```

A CT 200 provisioned before `llm-bench-workloads` existed runs the same with
`RUN_LLAMA_BENCHY=false llm-bench-profile workloads`.

| Variable | Default | Effect |
| --- | --- | --- |
| `RUN_AGENT_SESSIONS` | `true` in `workloads`, else `false` | Run the agent sessions |
| `RUN_DOC_INGEST` | `true` in `workloads`, else `false` | Run the document ingestion |
| `BENCHMARK_AGENT_PRESETS` | `hermes coding` | `PRESET[:SESSIONS]` list |
| `BENCHMARK_AGENT_DEPTH` | `0` | Stop every session at this many tokens; `0` keeps each preset's depth |
| `BENCHMARK_INGEST_DEPTHS` | `8192 16384 32768 49152` | Prompt sizes in tokens |
| `BENCHMARK_RUNS` | `3` | Repetitions of each preset and depth |

From the Mac, `make bench` runs the regression items (baseline, both sweeps, soak), then
reloads the server at its operational slot layout for the workloads. `GPU` picks the card,
through the container that serves it:

| `GPU` | Container | Model | Regression slots | Workload slots | Agent depth | Results |
| --- | --- | --- | --- | --- | --- | --- |
| `1` (default) | CT 120 | Qwen3.6-35B-A3B | 4 × 64k | 2 × 128k | Each preset's | `pro-v620/results/llamacpp/` |
| `2` | CT 123 | Qwen3.8-Flash-Next | 1 × 64k | 1 × 64k | 56k | `pro-v620/results/llamacpp-gpu2/` |

One 64k slot holds neither agent preset's full depth, so GPU 2's sessions stop at 56k.
Before changing anything, the batch checks that the container is serving its model and
has its reload helper. It stops if the two-card cutover is active, or if CT 123 lacks
`llamacpp-qwen38fn-reload`; install that from `pro-v620/qwen38-flash-next/` with
`VMID=123 ENV_FILE=qwen38fn-gpu2.env ./install.sh`.

| Command | Runs |
| --- | --- |
| `make bench` | GPU 1: regression items, agent sessions, document ingestion |
| `make bench GPU=2` | The same on GPU 2 |
| `make bench SUITE=short` | Regression items only |
| `make bench INGEST=false` | Regression items and agent sessions |
| `make bench AGENT=false` | Regression items and document ingestion |

GPU 2 is slow. On 2026-10-02 its model (b11018 baseline build, `-ncmoe 34`, q8_0 KV, one
64k slot) prefilled an 8k cold prompt at 61 tok/s and decoded at 10 tok/s, so a full
batch there runs for hours.

On GPU 1, Hermes keeps using CT 120 during a run. Its requests slow the workloads and can
take a session's slot (counted in `cache_misses`). Keep long runs clear of CT 121's 04:00 ET KB
freshness cron: an entry whose refresh times out while CT 120 is saturated or restarting
is quarantined for 14 days.

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
usually the dominant VRAM bottleneck). CT 120 runs llama.cpp, so it reloads via
the container's `llamacpp-reload` helper:

```bash
CONTEXTS="4096 16384 32768 65536" ./host/run-context-sweep.sh
```

It writes `context-sweep.md` correlating context length with peak VRAM and GPU
utilization (from host telemetry) and TTFT/latency/throughput (from the client).
For CT 123, pass its container, model and helper, or use `make context-sweep GPU=2`:

```bash
GPU_VMID=123 MODEL_KEY=qwen3.8-flash-next RESTORE_CONTEXT=65536 RESTORE_PARALLEL=1 \
  RELOAD_HELPER=/usr/local/bin/llamacpp-qwen38fn-reload ./host/run-context-sweep.sh
```

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
RUN_AGENT_SESSIONS=true
RUN_DOC_INGEST=true
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
