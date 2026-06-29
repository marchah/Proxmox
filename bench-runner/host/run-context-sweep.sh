#!/usr/bin/env bash

set -Eeuo pipefail

# Run on the Proxmox host. Sweeps the model's context length: for each length it
# reloads the model in the GPU container, runs a short OpenAI-direct baseline
# from the bench-runner LXC while sampling GPU telemetry, and records VRAM, GPU
# utilization, TTFT, latency, and throughput per context. Context length (KV
# cache) is usually the dominant VRAM/serving bottleneck, so this maps it.
#
# CT 120 runs llama.cpp; each context reload uses the container's `llamacpp-reload`
# helper (rewrite env + restart, blocks until the server is healthy again).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

GPU_VMID="${GPU_VMID:-120}"
BENCH_VMID="${BENCH_VMID:-200}"
MODEL_KEY="${MODEL_KEY:-qwen3.6-35b-a3b}"
MODEL_PARALLEL="${MODEL_PARALLEL:-1}"
# Operational default to restore CT 120 to when the sweep is done. The sweep walks
# CT 120 through small per-point contexts; an EXIT trap reloads it back to this so a
# direct run (or an aborted/interrupted one) never leaves the model at a tiny context.
RESTORE_CONTEXT="${RESTORE_CONTEXT:-262144}"
RESTORE_PARALLEL="${RESTORE_PARALLEL:-4}"
CONTEXTS="${CONTEXTS:-4096 16384 32768 65536}"
BENCHMARK_REQUESTS="${BENCHMARK_REQUESTS:-5}"
RELOAD_SETTLE_SECONDS="${RELOAD_SETTLE_SECONDS:-8}"
OUT_DIR="${OUT_DIR:-./context-sweep}"

usage() {
  cat <<'USAGE'
Sweep the model's context length and record VRAM / TTFT / throughput per step.
CT 120 runs llama.cpp; reloads use the container's `llamacpp-reload` helper.

Run on the Proxmox host as root:
  ./run-context-sweep.sh

Env overrides:
  GPU_VMID=120 BENCH_VMID=200   Container ids.
  MODEL_KEY=qwen3.6-35b-a3b     Model identifier (results label).
  MODEL_PARALLEL=1              Parallel slots used at each reload.
  RESTORE_CONTEXT=262144        Context to restore CT 120 to when the sweep ends.
  RESTORE_PARALLEL=4            Parallel slots to restore CT 120 to when the sweep ends.
  CONTEXTS="4096 16384 32768 65536"
  BENCHMARK_REQUESTS=5          Requests per context point.
  OUT_DIR=./context-sweep       Output directory.
USAGE
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

require_root() { [[ ${EUID} -eq 0 ]] || die "run on the Proxmox host as root"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# Reload the model at a given context length. llama.cpp sets context/parallel at
# start, so its container ships `llamacpp-reload` (rewrite env + restart, blocks
# until the server is healthy again); it returns only once the model is serving.
# Absolute path: the Ubuntu container's PATH omits /usr/local/bin even for a login
# shell, so neither bare `pct exec` nor `bash -lc` would find it.
reload_model() {
  local context="$1"
  pct exec "${GPU_VMID}" -- /usr/local/bin/llamacpp-reload "${context}" "${MODEL_PARALLEL}"
}

# Restore CT 120 to the operational default context/parallel. Registered as an EXIT
# trap so the sweep never leaves the model at its last (small) sweep context — on
# success, error, or interrupt. Re-raises the original exit code so a failed sweep
# stays failed; and if the restore itself fails, forces a nonzero exit (CT 120 is
# left at the wrong context) so a passing sweep can't mask a botched restore.
restore_ct120() {
  local rc=$?
  trap - EXIT INT TERM
  log "Restoring CT ${GPU_VMID} to context ${RESTORE_CONTEXT} / ${RESTORE_PARALLEL} slots"
  if ! pct exec "${GPU_VMID}" -- /usr/local/bin/llamacpp-reload "${RESTORE_CONTEXT}" "${RESTORE_PARALLEL}"; then
    log "WARNING: failed to restore CT ${GPU_VMID}; reload it manually (llamacpp-reload ${RESTORE_CONTEXT} ${RESTORE_PARALLEL})"
    [[ ${rc} -eq 0 ]] && rc=1
  fi
  exit "${rc}"
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

  # CT 120's current IP, so each bench points CT 200 at the live endpoint per-run.
  # This overrides any stale MODEL_API_URL/MODEL_IDENTIFIER baked into CT 200 (e.g.
  # left over from an earlier model), so preflight matches what's actually served.
  local gpu_ip
  gpu_ip="$(pct exec "${GPU_VMID}" -- hostname -I | awk '{print $1}')"
  [[ -n ${gpu_ip} ]] || die "could not determine CT ${GPU_VMID} IP address"

  # Always restore CT 120 to the operational default on exit (success, error, or
  # interrupt); the sweep otherwise leaves it at the last small context. The EXIT
  # trap is the single restore path; INT/TERM just translate to the conventional
  # nonzero code and fall through to it — registering restore_ct120 on the signals
  # directly would run it with $?==0 and exit 0, masking an interrupt as success.
  trap restore_ct120 EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

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
    # Override MODEL_API_URL/MODEL_IDENTIFIER per-run so a standalone sweep targets
    # CT 120's live endpoint even if CT 200's baked-in config is stale (process env
    # wins over the suite's `: "${VAR:=...}"` defaults). No BENCHMARK_RUN_ID: the
    # llm-bench-* wrappers force their own timestamped id, so we detect the folder
    # they actually create (below) instead of passing a name they would ignore.
    local bench_ok=1
    if ! GPU_VMID="${GPU_VMID}" OUT_DIR="${point_dir}/host" TELEMETRY_INTERVAL=1 \
      "${SCRIPT_DIR}/run-with-host-telemetry.sh" \
      pct exec "${BENCH_VMID}" -- bash -lc \
        "MODEL_API_URL='http://${gpu_ip}:1234/v1' MODEL_IDENTIFIER='${MODEL_KEY}' RUN_LLAMA_BENCHY=false BENCHMARK_REQUESTS='${BENCHMARK_REQUESTS}' BENCHMARK_DESCRIPTION='Context sweep ${context}' llm-bench-baseline"; then
      log "benchmark for context ${context} returned non-zero"
      sweep_status=1
      bench_ok=0
    fi

    # Pull from the newest /results entry the run just created (the wrapper's forced
    # id is unpredictable). Only when the bench succeeded, so a failed point never
    # pulls a previous run's summary and reports it as this context's result.
    if [[ ${bench_ok} -eq 1 ]]; then
      local actual_run
      actual_run="$(pct exec "${BENCH_VMID}" -- bash -lc 'ls -1dt /results/*/ 2>/dev/null | head -1')"
      actual_run="${actual_run%/}"
      if [[ -z ${actual_run} ]] || ! pct pull "${BENCH_VMID}" \
        "${actual_run}/openai-direct/openai-direct-summary.json" \
        "${point_dir}/openai-direct-summary.json" 2>/dev/null; then
        log "no summary retrieved for context ${context}"
        sweep_status=1
      fi
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
