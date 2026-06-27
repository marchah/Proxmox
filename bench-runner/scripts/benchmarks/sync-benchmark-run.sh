#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly PROJECT_DIR
readonly LOCAL_ROOT="${BENCHMARK_LOCAL_ROOT:-${PROJECT_DIR}/benchmarks}"
readonly PYTHON_BIN="${PYTHON_BIN:-python3}"

usage() {
  cat <<'EOF'
Usage:
  sync-benchmark-run.sh <ssh-host> <remote-run-dir> [description]

Example:
  ./scripts/benchmarks/sync-benchmark-run.sh \
    ai-server \
    /results/20260619T120000Z-qwen35-9b-q4-baseline \
    "Baseline server run after first setup."

The benchmark run should be executed on the server itself first. This script
only copies the finished run folder back into a local results directory and
generates or refreshes REPORT.md locally.
EOF
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage >&2
  exit 2
fi

readonly SSH_HOST="$1"
readonly REMOTE_RUN_DIR="${2%/}"
readonly DESCRIPTION="${3:-Synced server-side benchmark run.}"
RUN_ID="$(basename -- "${REMOTE_RUN_DIR}")"
readonly RUN_ID
readonly LOCAL_RUN_DIR="${LOCAL_ROOT}/${RUN_ID}"

mkdir -p "${LOCAL_ROOT}"

if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "${SSH_HOST}:${REMOTE_RUN_DIR}/" "${LOCAL_RUN_DIR}/"
else
  mkdir -p "${LOCAL_RUN_DIR}"
  scp -r "${SSH_HOST}:${REMOTE_RUN_DIR}/." "${LOCAL_RUN_DIR}/"
fi

"${PYTHON_BIN}" "${SCRIPT_DIR}/write-benchmark-report.py" \
  "${LOCAL_RUN_DIR}" \
  --description "${DESCRIPTION}"

printf 'Synced benchmark run to %s\n' "${LOCAL_RUN_DIR}"
