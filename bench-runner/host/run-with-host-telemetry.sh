#!/usr/bin/env bash

set -Eeuo pipefail

# Run on the Proxmox host. Samples the GPU container's telemetry (utilization,
# VRAM, clocks, temps) while a benchmark command runs, then summarizes the
# peaks so you can see the hardware cause behind a latency/throughput result.
#
# The benchmark itself usually runs in the bench-runner LXC, e.g.:
#   ./run-with-host-telemetry.sh pct exec 200 -- bash -lc 'llm-bench-baseline'
#   OUT_DIR=./ctx32k GPU_VMID=120 ./run-with-host-telemetry.sh pct exec 200 -- bash -lc 'llm-bench-concurrency'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SAMPLER="${SCRIPT_DIR}/../scripts/benchmarks/system-sampler.py"
readonly SUMMARIZER="${SCRIPT_DIR}/../scripts/benchmarks/summarize-telemetry.py"

GPU_VMID="${GPU_VMID:-120}"
OUT_DIR="${OUT_DIR:-./host-telemetry}"
TELEMETRY_INTERVAL="${TELEMETRY_INTERVAL:-1}"
HOST_PROCESS_PATTERNS="${HOST_PROCESS_PATTERNS:-lms,LM Studio,llmster}"

readonly REMOTE_SAMPLER="/tmp/bench-system-sampler.py"
readonly REMOTE_OUT="/tmp/bench-host-telemetry.jsonl"
readonly REMOTE_PID="/tmp/bench-host-telemetry.pid"
readonly REMOTE_LOG="/tmp/bench-host-telemetry.log"

usage() {
  cat <<'USAGE'
Sample the GPU container while a benchmark command runs, then summarize peaks.

Run on the Proxmox host as root:
  ./run-with-host-telemetry.sh <command to run while sampling> [args...]

Example:
  ./run-with-host-telemetry.sh pct exec 200 -- bash -lc 'llm-bench-baseline'

Env overrides:
  GPU_VMID=120                Container that owns the GPU.
  OUT_DIR=./host-telemetry    Where to write host-telemetry.jsonl + summary.
  TELEMETRY_INTERVAL=1        Sampler interval (seconds).
  HOST_PROCESS_PATTERNS=...   Comma-separated process names to track RSS for.
USAGE
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

require_root() { [[ ${EUID} -eq 0 ]] || die "run on the Proxmox host as root"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

start_sampler() {
  pct exec "${GPU_VMID}" -- bash -s -- \
    "${REMOTE_SAMPLER}" "${REMOTE_OUT}" "${REMOTE_PID}" "${REMOTE_LOG}" \
    "${TELEMETRY_INTERVAL}" "${HOST_PROCESS_PATTERNS}" <<'REMOTE'
set -Eeuo pipefail
sampler="$1"; out="$2"; pidf="$3"; logf="$4"; interval="$5"; patterns="$6"
rm -f "$out" "$pidf"
nohup python3 "$sampler" --output "$out" --interval "$interval" --process-pattern "$patterns" >"$logf" 2>&1 &
echo $! >"$pidf"
REMOTE
}

stop_sampler() {
  pct exec "${GPU_VMID}" -- bash -s -- "${REMOTE_PID}" <<'REMOTE'
set -Eeuo pipefail
pidf="$1"
if [[ -f "$pidf" ]]; then
  kill "$(cat "$pidf")" 2>/dev/null || true
fi
sleep 1
REMOTE
}

cleanup_remote() {
  pct exec "${GPU_VMID}" -- bash -s -- \
    "${REMOTE_SAMPLER}" "${REMOTE_OUT}" "${REMOTE_PID}" "${REMOTE_LOG}" <<'REMOTE' || true
rm -f "$1" "$2" "$3" "$4"
REMOTE
}

main() {
  if [[ $# -eq 0 || ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    [[ $# -eq 0 ]] && exit 2 || exit 0
  fi

  require_root
  require_command pct
  require_command python3
  [[ -f ${SAMPLER} ]] || die "sampler not found: ${SAMPLER}"
  pct status "${GPU_VMID}" >/dev/null 2>&1 || die "GPU container ${GPU_VMID} not found"

  mkdir -p "${OUT_DIR}"

  log "Pushing sampler into GPU container ${GPU_VMID}"
  pct push "${GPU_VMID}" "${SAMPLER}" "${REMOTE_SAMPLER}"

  log "Starting GPU-host telemetry sampler"
  start_sampler

  local rc=0
  log "Running: $*"
  "$@" || rc=$?

  log "Stopping sampler and pulling telemetry"
  stop_sampler
  pct pull "${GPU_VMID}" "${REMOTE_OUT}" "${OUT_DIR}/host-telemetry.jsonl"
  cleanup_remote

  log "GPU host telemetry summary"
  python3 "${SUMMARIZER}" "${OUT_DIR}/host-telemetry.jsonl" \
    --json-out "${OUT_DIR}/host-telemetry-summary.json"

  printf '\nHost telemetry written to %s\n' "${OUT_DIR}/host-telemetry.jsonl"
  printf 'Benchmark command exit code: %s\n' "${rc}"
  return "${rc}"
}

main "$@"
