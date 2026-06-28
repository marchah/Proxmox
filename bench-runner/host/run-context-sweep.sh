#!/usr/bin/env bash

set -Eeuo pipefail

# Run on the Proxmox host. Sweeps the model's context length: for each length it
# reloads the model in the GPU container, runs a short OpenAI-direct baseline
# from the bench-runner LXC while sampling GPU telemetry, and records VRAM, GPU
# utilization, TTFT, latency, and throughput per context. Context length (KV
# cache) is usually the dominant VRAM/serving bottleneck, so this maps it.
#
# Works for both LLM runtime engines, selected by RUNTIME (default lmstudio):
#   lmstudio — reload via the `lms` CLI (unload/load at the new context).
#   llamacpp — reload via the container's `llamacpp-reload` helper (restart).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

GPU_VMID="${GPU_VMID:-120}"
BENCH_VMID="${BENCH_VMID:-200}"
RUNTIME="${RUNTIME:-lmstudio}"
MODEL_KEY="${MODEL_KEY:-qwen3.5-9b}"
MODEL_GPU_OFFLOAD="${MODEL_GPU_OFFLOAD:-max}"
MODEL_PARALLEL="${MODEL_PARALLEL:-1}"
LMS_USER="${LMS_USER:-lmstudio}"
LMS_BIN="${LMS_BIN:-/home/lmstudio/.lmstudio/bin/lms}"
CONTEXTS="${CONTEXTS:-4096 16384 32768 65536}"
BENCHMARK_REQUESTS="${BENCHMARK_REQUESTS:-5}"
RELOAD_SETTLE_SECONDS="${RELOAD_SETTLE_SECONDS:-8}"
OUT_DIR="${OUT_DIR:-./context-sweep}"

usage() {
  cat <<'USAGE'
Sweep LM Studio context length and record VRAM / TTFT / throughput per step.

Run on the Proxmox host as root:
  ./run-context-sweep.sh

Env overrides:
  GPU_VMID=120 BENCH_VMID=200   Container ids.
  RUNTIME=lmstudio              Engine on the GPU container: lmstudio | llamacpp.
  MODEL_KEY=qwen3.5-9b          Model identifier to (re)load (lmstudio reload + label).
  CONTEXTS="4096 16384 32768 65536"
  BENCHMARK_REQUESTS=5          Requests per context point.
  OUT_DIR=./context-sweep       Output directory.
USAGE
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

require_root() { [[ ${EUID} -eq 0 ]] || die "run on the Proxmox host as root"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# Reload the model at a given context length. Dispatches on RUNTIME: LM Studio
# hot-reloads via `lms load`; llama.cpp sets context/parallel at start, so its
# container ships `llamacpp-reload` (rewrite env + restart, blocks until the
# server is healthy again). Both return only once the model is serving.
reload_model() {
  local context="$1"
  case "${RUNTIME}" in
    llamacpp)
      pct exec "${GPU_VMID}" -- llamacpp-reload "${context}" "${MODEL_PARALLEL}"
      ;;
    lmstudio)
      pct exec "${GPU_VMID}" -- bash -s -- \
        "${LMS_USER}" "${LMS_BIN}" "${MODEL_KEY}" "${context}" \
        "${MODEL_GPU_OFFLOAD}" "${MODEL_PARALLEL}" <<'REMOTE'
set -Eeuo pipefail
user="$1"; lms="$2"; key="$3"; ctx="$4"; gpu="$5"; parallel="$6"
home="/home/${user}"
sudo -u "$user" env HOME="$home" "$lms" unload --all >/dev/null 2>&1 || true
sudo -u "$user" env HOME="$home" "$lms" load "$key" \
  --context-length "$ctx" --gpu "$gpu" --parallel "$parallel" --yes
REMOTE
      ;;
    *)
      die "unknown RUNTIME '${RUNTIME}' (expected lmstudio or llamacpp)"
      ;;
  esac
}

format_row() {
  local context="$1" openai_summary="$2" host_summary="$3"
  python3 - "${context}" "${openai_summary}" "${host_summary}" <<'PY'
import json
import sys


def load(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def fmt(value):
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


context = sys.argv[1]
openai = load(sys.argv[2])
host = load(sys.argv[3])
latency = openai.get("latency_total_seconds", {})
ttft = openai.get("ttft_seconds", {})
gpu = host.get("gpu", {})
print(
    f"| {context} | {fmt(gpu.get('max_vram_used_mib'))} | {fmt(gpu.get('max_vram_used_ratio'))} | "
    f"{fmt(gpu.get('max_busy_percent'))} | {fmt(ttft.get('p95'))} | {fmt(latency.get('p95'))} | "
    f"{fmt(openai.get('aggregate_output_tokens_per_second'))} |"
)
PY
}

main() {
  if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
  fi

  require_root
  require_command pct
  require_command python3
  pct status "${GPU_VMID}" >/dev/null 2>&1 || die "GPU container ${GPU_VMID} not found"
  pct status "${BENCH_VMID}" >/dev/null 2>&1 || die "bench container ${BENCH_VMID} not found"

  mkdir -p "${OUT_DIR}"
  # Unique per-sweep stamp so re-running never reuses a /results/ctx-<n> id
  # (which would mix stale artifacts from a prior sweep).
  local sweep_stamp sweep_status=0
  sweep_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local report="${OUT_DIR}/context-sweep.md"
  {
    printf '# Context-Length Sweep\n\n'
    # shellcheck disable=SC2016  # backticks are literal markdown; %s are printf args
    printf -- '- Model: `%s` on CT %s, benched from CT %s\n' "${MODEL_KEY}" "${GPU_VMID}" "${BENCH_VMID}"
    printf -- '- Requests per point: %s\n\n' "${BENCHMARK_REQUESTS}"
    printf '| Context | VRAM used (MiB) | VRAM ratio | GPU util %% | TTFT p95 (s) | Latency p95 (s) | tok/s |\n'
    printf '| ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n'
  } >"${report}"

  for context in ${CONTEXTS}; do
    local run_id="ctx-${context}-${sweep_stamp}"
    local point_dir="${OUT_DIR}/${run_id}"
    mkdir -p "${point_dir}"

    log "Reloading ${MODEL_KEY} at context ${context}"
    if ! reload_model "${context}"; then
      printf '| %s | reload failed | | | | | |\n' "${context}" >>"${report}"
      sweep_status=1
      continue
    fi
    sleep "${RELOAD_SETTLE_SECONDS}"

    log "Benchmarking context ${context} with GPU host telemetry"
    if ! GPU_VMID="${GPU_VMID}" OUT_DIR="${point_dir}/host" TELEMETRY_INTERVAL=1 \
      "${SCRIPT_DIR}/run-with-host-telemetry.sh" \
      pct exec "${BENCH_VMID}" -- bash -lc \
        "BENCHMARK_RUN_ID='${run_id}' RUN_LLAMA_BENCHY=false BENCHMARK_REQUESTS='${BENCHMARK_REQUESTS}' BENCHMARK_DESCRIPTION='Context sweep ${context}' llm-bench-baseline"; then
      log "benchmark for context ${context} returned non-zero"
      sweep_status=1
    fi

    if ! pct pull "${BENCH_VMID}" \
      "/results/${run_id}/openai-direct/openai-direct-summary.json" \
      "${point_dir}/openai-direct-summary.json" 2>/dev/null; then
      log "no summary retrieved for context ${context}"
      sweep_status=1
    fi

    format_row "${context}" \
      "${point_dir}/openai-direct-summary.json" \
      "${point_dir}/host/host-telemetry-summary.json" >>"${report}"
  done

  log "Done"
  printf 'Context sweep report: %s\n' "${report}"
  cat "${report}"
  # Report is complete; surface any reload/benchmark failure as the exit code.
  return "${sweep_status}"
}

main "$@"
