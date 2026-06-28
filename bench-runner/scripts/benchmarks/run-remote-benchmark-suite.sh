#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly PROJECT_DIR
readonly REQUESTED_ENV_FILE="/opt/bench-runner/config/.env"
readonly DEFAULT_ENV_FILE="${PROJECT_DIR}/config/.env"
readonly PYTHON_BIN="${PYTHON_BIN:-python3}"

usage() {
  cat <<'EOF'
Usage:
  run-remote-benchmark-suite.sh

Loads env vars from BENCHMARK_ENV_FILE, /opt/bench-runner/config/.env
when present, or bench-runner/config/.env as a fallback.

Required env vars:
  SERVER_HOST      Server hostname or IP.
  USER_NAME        SSH username.
  USER_PASSWORD    SSH password.

Useful optional env vars:
  REMOTE_AI_LAB_DIR      Default: /opt/bench-runner
  BENCHMARK_PROFILE      Default: baseline
  BENCHMARK_RUN_ID       Default: <utc-date>-<profile>
  RUN_LLAMA_BENCHY       Default: true
  BENCHMARK_DESCRIPTION  Stored in REPORT.md

This script uploads benchmark scripts/config, runs benchmarks on the server,
then downloads the resulting run folder from `/results`.
EOF
}

load_env_file() {
  local env_file="${BENCHMARK_ENV_FILE:-}"

  if [[ -z "${env_file}" ]]; then
    if [[ -f "${REQUESTED_ENV_FILE}" ]]; then
      env_file="${REQUESTED_ENV_FILE}"
    else
      env_file="${DEFAULT_ENV_FILE}"
    fi
  fi

  if [[ ! -f "${env_file}" ]]; then
    printf 'Env file not found: %s\n' "${env_file}" >&2
    printf 'Create %s from config/.env.example, or set BENCHMARK_ENV_FILE.\n' \
      "${DEFAULT_ENV_FILE}" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a

  printf 'Loaded benchmark env from %s\n' "${env_file}"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf 'Required env var is missing: %s\n' "${name}" >&2
    exit 1
  fi
}

shell_quote() {
  printf '%q' "$1"
}

ssh_remote() {
  SSHPASS="${USER_PASSWORD}" sshpass -e ssh "${SSH_OPTIONS[@]}" \
    "${USER_NAME}@${SERVER_HOST}" "$@"
}

scp_to_remote() {
  SSHPASS="${USER_PASSWORD}" sshpass -e scp "${SCP_OPTIONS[@]}" "$@"
}

download_run() {
  local remote_run_dir="$1"
  local local_run_dir="$2"

  mkdir -p "${local_run_dir}"

  if command -v rsync >/dev/null 2>&1; then
    SSHPASS="${USER_PASSWORD}" sshpass -e rsync -az --delete \
      -e "ssh ${SSH_OPTION_STRING}" \
      "${USER_NAME}@${SERVER_HOST}:${remote_run_dir}/" \
      "${local_run_dir}/"
  else
    SSHPASS="${USER_PASSWORD}" sshpass -e scp "${SCP_OPTIONS[@]}" -r \
      "${USER_NAME}@${SERVER_HOST}:${remote_run_dir}/." \
      "${local_run_dir}/"
  fi
}

append_remote_export() {
  local script="$1"
  local name="$2"

  if [[ -n "${!name+x}" ]]; then
    printf 'export %s=%q\n' "${name}" "${!name}" >>"${script}"
  fi
}

ENV_OVERRIDE_NAMES=()
ENV_OVERRIDE_VALUES=()
remember_env_override() {
  local name="$1"
  if [[ -n "${!name+x}" ]]; then
    ENV_OVERRIDE_NAMES+=("${name}")
    ENV_OVERRIDE_VALUES+=("${!name}")
  fi
}

restore_env_overrides() {
  local index name
  for index in "${!ENV_OVERRIDE_NAMES[@]}"; do
    name="${ENV_OVERRIDE_NAMES[${index}]}"
    printf -v "${name}" '%s' "${ENV_OVERRIDE_VALUES[${index}]}"
    # shellcheck disable=SC2163  # exporting the var named by ${name}, assigned just above
    export "${name}"
  done
}

for var_name in \
  BENCHMARK_PROFILE \
  BENCHMARK_RUN_ID \
  BENCHMARK_DESCRIPTION \
  BENCHMARK_RUNS \
  BENCHMARK_REQUESTS \
  BENCHMARK_CONCURRENCY \
  RUN_OPENAI_DIRECT \
  RUN_LLAMA_BENCHY \
  LLAMA_BENCHY_BIN \
  LLAMA_BENCHY_ARGS \
  LLAMA_BENCHY_USE_UVX \
  RUN_LM_EVAL \
  LM_EVAL_ARGS \
  MODEL_API_URL \
  MODEL_IDENTIFIER \
  TELEMETRY_INTERVAL \
  BENCHMARK_PROCESS_PATTERNS; do
  remember_env_override "${var_name}"
done

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

load_env_file
restore_env_overrides

SERVER_HOST="${SERVER_HOST:-${HOST_NAME:-${SERVER_IP:-}}}"
REMOTE_AI_LAB_DIR="${REMOTE_AI_LAB_DIR:-/opt/bench-runner}"
BENCHMARK_PROFILE="${BENCHMARK_PROFILE:-baseline}"
BENCHMARK_RUN_ID="${BENCHMARK_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-${BENCHMARK_PROFILE}}"
BENCHMARK_DESCRIPTION="${BENCHMARK_DESCRIPTION:-Remote server-side benchmark run.}"
RUN_LLAMA_BENCHY="${RUN_LLAMA_BENCHY:-true}"
SSH_PORT="${SSH_PORT:-22}"
SSH_STRICT_HOST_KEY_CHECKING="${SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"
LOCAL_RESULTS_ROOT="${BENCHMARK_LOCAL_ROOT:-${PROJECT_DIR}/benchmarks}"
REMOTE_UPLOAD_ARCHIVE="${REMOTE_UPLOAD_ARCHIVE:-/tmp/ai-lab-benchmark-upload.tar.gz}"

require_env SERVER_HOST
require_env USER_NAME
require_env USER_PASSWORD

if ! command -v sshpass >/dev/null 2>&1; then
  printf 'sshpass is required for password-based SSH automation.\n' >&2
  printf 'Install sshpass locally, or switch to SSH key auth and use sync-benchmark-run.sh.\n' >&2
  exit 1
fi

SSH_OPTIONS=(
  -p "${SSH_PORT}"
  -o "StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}"
  -o UserKnownHostsFile="${HOME}/.ssh/known_hosts"
  -o PubkeyAuthentication=no
  -o PreferredAuthentications=password
)
SCP_OPTIONS=(
  -P "${SSH_PORT}"
  -o "StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}"
  -o UserKnownHostsFile="${HOME}/.ssh/known_hosts"
  -o PubkeyAuthentication=no
  -o PreferredAuthentications=password
)
SSH_OPTION_STRING="-p ${SSH_PORT} -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING} -o UserKnownHostsFile=${HOME}/.ssh/known_hosts -o PubkeyAuthentication=no -o PreferredAuthentications=password"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

upload_archive="${tmp_dir}/ai-lab-benchmark-upload.tar.gz"

printf 'Packaging benchmark scripts and config...\n'
tar -C "${PROJECT_DIR}" -czf "${upload_archive}" \
  scripts/benchmarks \
  config/benchmark-profiles \
  config/benchmark-promptsets \
  config/benchmark-slos \
  README.md \
  FUTURE_IMPROVEMENTS.md \
  BENCHMARKS.md

remote_project_q="$(shell_quote "${REMOTE_AI_LAB_DIR}")"
remote_archive_q="$(shell_quote "${REMOTE_UPLOAD_ARCHIVE}")"

printf 'Preparing remote directory %s...\n' "${REMOTE_AI_LAB_DIR}"
ssh_remote "mkdir -p ${remote_project_q}/scripts ${remote_project_q}/config ${remote_project_q}/benchmarks"

printf 'Uploading benchmark bundle...\n'
scp_to_remote "${upload_archive}" \
  "${USER_NAME}@${SERVER_HOST}:${REMOTE_UPLOAD_ARCHIVE}"

printf 'Extracting benchmark bundle on server...\n'
ssh_remote "tar -xzf ${remote_archive_q} -C ${remote_project_q} && chmod +x ${remote_project_q}/scripts/benchmarks/*.sh ${remote_project_q}/scripts/benchmarks/*.py"

remote_script="${tmp_dir}/remote-run-benchmarks.sh"
cat >"${remote_script}" <<REMOTE
#!/usr/bin/env bash
set -Eeuo pipefail
cd $(shell_quote "${REMOTE_AI_LAB_DIR}")
export PATH="\$HOME/.local/bin:\$PATH"
export BENCHMARK_OUT_ROOT="/results"
export BENCHMARK_PROFILE=$(shell_quote "${BENCHMARK_PROFILE}")
export BENCHMARK_RUN_ID=$(shell_quote "${BENCHMARK_RUN_ID}")
export BENCHMARK_DESCRIPTION=$(shell_quote "${BENCHMARK_DESCRIPTION}")
export RUN_LLAMA_BENCHY=$(shell_quote "${RUN_LLAMA_BENCHY}")
REMOTE

for var_name in \
  BENCHMARK_RUNS \
  BENCHMARK_REQUESTS \
  BENCHMARK_CONCURRENCY \
  RUN_OPENAI_DIRECT \
  LLAMA_BENCHY_BIN \
  LLAMA_BENCHY_ARGS \
  LLAMA_BENCHY_USE_UVX \
  RUN_LM_EVAL \
  LM_EVAL_ARGS \
  MODEL_API_URL \
  MODEL_IDENTIFIER \
  TELEMETRY_INTERVAL \
  BENCHMARK_PROCESS_PATTERNS; do
  append_remote_export "${remote_script}" "${var_name}"
done

cat >>"${remote_script}" <<'REMOTE'
./scripts/benchmarks/run-ai-benchmark-suite.sh
REMOTE

printf 'Running benchmarks on %s...\n' "${SERVER_HOST}"
# Capture the remote exit code instead of aborting under set -e, so a failed
# benchmark still has its partial results downloaded before we propagate it.
benchmark_status=0
SSHPASS="${USER_PASSWORD}" sshpass -e ssh "${SSH_OPTIONS[@]}" \
  "${USER_NAME}@${SERVER_HOST}" \
  'bash -s' <"${remote_script}" || benchmark_status=$?

remote_run_dir="/results/${BENCHMARK_RUN_ID}"
local_run_dir="${LOCAL_RESULTS_ROOT}/${BENCHMARK_RUN_ID}"

printf 'Downloading results from %s...\n' "${remote_run_dir}"
download_run "${remote_run_dir}" "${local_run_dir}" || \
  printf 'Warning: could not download %s\n' "${remote_run_dir}" >&2

if [[ -f "${local_run_dir}/manifest.json" ]]; then
  "${PYTHON_BIN}" "${SCRIPT_DIR}/write-benchmark-report.py" \
    "${local_run_dir}" \
    --description "${BENCHMARK_DESCRIPTION}" >/dev/null || true
fi

if [[ "${benchmark_status}" -ne 0 ]]; then
  printf 'Remote benchmark exited %s; downloaded partial results to %s\n' \
    "${benchmark_status}" "${local_run_dir}" >&2
else
  printf 'Remote benchmark run complete.\n'
fi
printf 'Local results: %s\n' "${local_run_dir}"
exit "${benchmark_status}"
