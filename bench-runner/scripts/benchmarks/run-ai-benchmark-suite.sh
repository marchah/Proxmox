#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly PROJECT_DIR
readonly CONFIG_FILE="${PROJECT_DIR}/config/local-model.env"
readonly PYTHON_BIN="${PYTHON_BIN:-python3}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

if [[ -n "${BENCHMARK_PROFILE:-}" ]]; then
  profile_path="${BENCHMARK_PROFILE}"
  if [[ "${profile_path}" != */* ]]; then
    profile_path="${PROJECT_DIR}/config/benchmark-profiles/${profile_path}.env"
  fi
  if [[ ! -f "${profile_path}" ]]; then
    printf 'Benchmark profile not found: %s\n' "${profile_path}" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${profile_path}"
fi

readonly OUT_ROOT="${BENCHMARK_OUT_ROOT:-/results}"
readonly RUN_ID="${BENCHMARK_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
# RUN_ID becomes a path component and BENCHMARK_OVERWRITE rm -rf's RUN_DIR, so it
# must be a simple name — reject slashes / ".." to prevent path traversal.
if [[ ! "${RUN_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  printf 'Invalid BENCHMARK_RUN_ID %q: use a simple name ([A-Za-z0-9._-], no slashes or "..").\n' "${RUN_ID}" >&2
  exit 1
fi
readonly RUN_DIR="${OUT_ROOT}/${RUN_ID}"
readonly TELEMETRY_INTERVAL="${TELEMETRY_INTERVAL:-1}"

# Overall suite status. Benchmarks run inside a set +e guard so reports are
# always written even when a target fails, so we record failure here and
# propagate it as the suite's exit code at the very end.
overall_status=0

MODEL_API_URL="${MODEL_API_URL:-http://127.0.0.1:1234/v1}"
MODEL_IDENTIFIER="${MODEL_IDENTIFIER:-local-model}"
BENCHMARK_PROCESS_PATTERNS="${BENCHMARK_PROCESS_PATTERNS:-lms,LM Studio,llama-server,python,llama-benchy,lm_eval}"
BENCHMARK_RUNS="${BENCHMARK_RUNS:-3}"
export MODEL_API_URL MODEL_IDENTIFIER
export BENCHMARK_PROFILE BENCHMARK_PROMPTSET BENCHMARK_SCENARIOS
export BENCHMARK_RUNS BENCHMARK_REQUESTS BENCHMARK_CONCURRENCY BENCHMARK_SLO_FILE
export BENCHMARK_PROCESS_PATTERNS RUN_OPENAI_DIRECT RUN_LLAMA_BENCHY RUN_LM_EVAL
export BENCHMARK_DESCRIPTION

# Fail loudly before doing any work if the model endpoint is unreachable or the
# configured model id is not actually served. Set BENCHMARK_PREFLIGHT=false to skip.
if [[ "${RUN_OPENAI_DIRECT:-true}" == "true" && "${BENCHMARK_PREFLIGHT:-true}" == "true" ]]; then
  preflight_status=0
  "${PYTHON_BIN}" - "${MODEL_API_URL}" "${MODEL_IDENTIFIER}" <<'PY' || preflight_status=$?
import json
import sys
import urllib.error
import urllib.request

base_url = sys.argv[1].rstrip("/")
model = sys.argv[2]
models_url = f"{base_url}/models"
try:
    with urllib.request.urlopen(models_url, timeout=15) as response:
        payload = json.loads(response.read().decode("utf-8"))
except (urllib.error.URLError, TimeoutError, ValueError) as exc:
    sys.stderr.write(f"Preflight: cannot reach model API at {models_url}: {exc}\n")
    sys.exit(2)

served = [item.get("id") for item in payload.get("data", []) if item.get("id")]
if not served:
    sys.stderr.write(f"Preflight: {models_url} returned no served models.\n")
    sys.exit(3)
if model not in served:
    sys.stderr.write(f"Preflight: model '{model}' is not served. Available: {', '.join(served)}\n")
    sys.exit(3)
sys.stderr.write(f"Preflight OK: model '{model}' is served at {base_url}\n")
PY

  if [[ "${preflight_status}" -eq 2 ]]; then
    printf 'Aborting: model API at %s is unreachable. Start the LLM runtime (CT 120) or set MODEL_API_URL.\n' "${MODEL_API_URL}" >&2
    printf 'Set BENCHMARK_PREFLIGHT=false to skip this check.\n' >&2
    exit 1
  elif [[ "${preflight_status}" -eq 3 ]]; then
    printf 'Aborting: model "%s" is not served by %s (see preflight output above).\n' "${MODEL_IDENTIFIER}" "${MODEL_API_URL}" >&2
    printf 'Fix MODEL_IDENTIFIER (or local-model.env), or set BENCHMARK_PREFLIGHT=false to skip.\n' >&2
    exit 1
  fi
fi

# A reused run id must not inherit stale artifacts (e.g. a previous run's
# llama-benchy/ dir would reappear in the regenerated report). Reject a
# non-empty run dir unless BENCHMARK_OVERWRITE=true is set to clear it.
if [[ -d "${RUN_DIR}" && -n "$(ls -A "${RUN_DIR}" 2>/dev/null)" ]]; then
  if [[ "${BENCHMARK_OVERWRITE:-false}" == "true" ]]; then
    printf 'Run dir %s exists; BENCHMARK_OVERWRITE=true — clearing it.\n' "${RUN_DIR}" >&2
    rm -rf -- "${RUN_DIR:?}"
  else
    printf 'Run dir already exists and is non-empty: %s\n' "${RUN_DIR}" >&2
    printf 'Use a fresh BENCHMARK_RUN_ID, or set BENCHMARK_OVERWRITE=true to clear it.\n' >&2
    exit 1
  fi
fi
mkdir -p "${RUN_DIR}"

resolve_project_path() {
  local value="$1"
  if [[ -z "${value}" || "${value}" = /* ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s\n' "${PROJECT_DIR}/${value}"
  fi
}

capture_logs() {
  local phase="$1"
  "${SCRIPT_DIR}/capture-system-logs.sh" "${RUN_DIR}" "${phase}" || true
}

capture_versions() {
  "${PYTHON_BIN}" "${SCRIPT_DIR}/collect-version-info.py" \
    --output "${RUN_DIR}/versions.json" \
    --project-dir "${PROJECT_DIR}" || true
}

write_manifest() {
  "${PYTHON_BIN}" - "$RUN_DIR" <<'PY'
import json
import os
import platform
import sys
from datetime import datetime, timezone
from pathlib import Path

run_dir = Path(sys.argv[1])
manifest = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "run_dir": str(run_dir),
    "host": {
        "hostname": platform.node(),
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "processor": platform.processor(),
    },
    "env": {
        key: os.environ.get(key)
        for key in [
            "MODEL_API_URL",
            "MODEL_IDENTIFIER",
            "BENCHMARK_PROFILE",
            "BENCHMARK_PROMPTSET",
            "BENCHMARK_RUNS",
            "BENCHMARK_SCENARIOS",
            "BENCHMARK_REQUESTS",
            "BENCHMARK_CONCURRENCY",
            "BENCHMARK_SLO_FILE",
            "BENCHMARK_PROCESS_PATTERNS",
            "RUN_OPENAI_DIRECT",
            "RUN_LLAMA_BENCHY",
            "RUN_LM_EVAL",
            "BENCHMARK_DESCRIPTION",
        ]
    },
}
(run_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
}

run_with_telemetry() {
  local label="$1"
  shift

  local target_dir="${RUN_DIR}/${label}"
  mkdir -p "${target_dir}"
  printf 'Running %s...\n' "${label}"

  printf '%s\n' "$*" >"${target_dir}/command.txt"

  process_args=()
  IFS=',' read -r -a process_patterns <<<"${BENCHMARK_PROCESS_PATTERNS}"
  for process_pattern in "${process_patterns[@]}"; do
    [[ -n "${process_pattern}" ]] && process_args+=(--process-pattern "${process_pattern}")
  done

  "${PYTHON_BIN}" "${SCRIPT_DIR}/system-sampler.py" \
    --output "${target_dir}/telemetry.jsonl" \
    --interval "${TELEMETRY_INTERVAL}" \
    "${process_args[@]}" &
  local sampler_pid=$!

  set +e
  "$@" >"${target_dir}/stdout.log" 2>"${target_dir}/stderr.log"
  local command_status=$?
  set -e

  kill "${sampler_pid}" >/dev/null 2>&1 || true
  wait "${sampler_pid}" >/dev/null 2>&1 || true

  "${PYTHON_BIN}" - "$target_dir" "$command_status" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

target = Path(sys.argv[1])
status = int(sys.argv[2])
(target / "status.json").write_text(
    json.dumps(
        {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "exit_code": status,
            "ok": status == 0,
        },
        indent=2,
        sort_keys=True,
    )
    + "\n"
)
PY

  if [[ "${command_status}" -ne 0 ]]; then
    overall_status=1
    printf '%s failed with exit code %s. See %s/stderr.log\n' \
      "${label}" "${command_status}" "${target_dir}" >&2
  fi
}

scenario_args=()
if [[ -n "${BENCHMARK_PROMPTSET:-}" ]]; then
  scenario_args+=(--promptset "$(resolve_project_path "${BENCHMARK_PROMPTSET}")")
else
  IFS=',' read -r -a scenario_names <<<"${BENCHMARK_SCENARIOS:-smoke,short,medium}"
  for scenario in "${scenario_names[@]}"; do
    [[ -n "${scenario}" ]] && scenario_args+=(--scenario "${scenario}")
  done
fi

write_manifest
capture_logs before
capture_versions

if [[ "${RUN_OPENAI_DIRECT:-true}" == "true" ]]; then
  run_with_telemetry "openai-direct" \
    "${PYTHON_BIN}" "${SCRIPT_DIR}/benchmark-openai-api.py" \
    --base-url "${MODEL_API_URL}" \
    --model "${MODEL_IDENTIFIER}" \
    --label direct \
    --output-dir "${RUN_DIR}/openai-direct" \
    --requests "${BENCHMARK_REQUESTS:-3}" \
    --concurrency "${BENCHMARK_CONCURRENCY:-1}" \
    "${scenario_args[@]}"
fi

if [[ "${RUN_LLAMA_BENCHY:-false}" == "true" ]]; then
  if [[ -n "${LLAMA_BENCHY_BIN:-}" ]]; then
    llama_benchy_command=("${LLAMA_BENCHY_BIN}")
  elif command -v llama-benchy >/dev/null 2>&1; then
    llama_benchy_command=(llama-benchy)
  elif [[ "${LLAMA_BENCHY_USE_UVX:-false}" == "true" ]] && command -v uvx >/dev/null 2>&1; then
    llama_benchy_command=(uvx llama-benchy)
  else
    printf 'RUN_LLAMA_BENCHY=true requires llama-benchy on PATH, LLAMA_BENCHY_BIN, or LLAMA_BENCHY_USE_UVX=true with uvx.\n' >&2
    overall_status=1
    llama_benchy_command=()
  fi
  if [[ "${#llama_benchy_command[@]}" -gt 0 ]]; then
    if [[ -n "${LLAMA_BENCHY_ARGS:-}" ]]; then
      # shellcheck disable=SC2206
      llama_benchy_args=(${LLAMA_BENCHY_ARGS})
    else
      llama_benchy_args=(
        --base-url "${MODEL_API_URL}"
        --model "${MODEL_IDENTIFIER}"
        --concurrency "${LLAMA_BENCHY_CONCURRENCY:-${BENCHMARK_CONCURRENCY:-1}}"
        --pp 512 2048
        --tg 32 128
        --depth 0 4096
        --runs "${BENCHMARK_RUNS}"
        --no-warmup
        --no-adapt-prompt
        --latency-mode generation
        --format json
        --save-result "${RUN_DIR}/llama-benchy/llama-benchy-results.json"
      )
    fi
    run_with_telemetry "llama-benchy" "${llama_benchy_command[@]}" "${llama_benchy_args[@]}"
  fi
fi

if [[ "${RUN_LM_EVAL:-false}" == "true" ]]; then
  if ! command -v lm_eval >/dev/null 2>&1; then
    printf 'RUN_LM_EVAL=true requires lm_eval on PATH.\n' >&2
    overall_status=1
  else
    if [[ -n "${LM_EVAL_ARGS:-}" ]]; then
      # shellcheck disable=SC2206
      lm_eval_args=(${LM_EVAL_ARGS})
    else
      lm_eval_chat_url="${MODEL_API_URL%/}/chat/completions"
      lm_eval_args=(
        run
        --model local-chat-completions
        --model_args "model=${MODEL_IDENTIFIER},base_url=${lm_eval_chat_url},tokenizer_backend=None"
        --tasks gsm8k
        --limit 20
        --apply_chat_template
        --output_path "${RUN_DIR}/lm-eval/lm-eval-results"
      )
    fi
    run_with_telemetry "lm-eval" lm_eval "${lm_eval_args[@]}"
  fi
fi

capture_logs after
capture_versions

if [[ -n "${BENCHMARK_SLO_FILE:-}" ]]; then
  slo_file="$(resolve_project_path "${BENCHMARK_SLO_FILE}")"
  if [[ -f "${slo_file}" ]]; then
    set +e
    "${PYTHON_BIN}" "${SCRIPT_DIR}/evaluate-slos.py" "${RUN_DIR}" --slo-file "${slo_file}" \
      >"${RUN_DIR}/slo-evaluation.stdout.log" \
      2>"${RUN_DIR}/slo-evaluation.stderr.log"
    slo_status=$?
    set -e
    printf '{"exit_code":%s,"ok":%s}\n' "${slo_status}" "$([[ "${slo_status}" -eq 0 ]] && printf true || printf false)" \
      >"${RUN_DIR}/slo-evaluation.status.json"
    if [[ "${slo_status}" -ne 0 ]]; then
      overall_status=1
    fi
  else
    printf 'BENCHMARK_SLO_FILE does not exist: %s\n' "${slo_file}" >&2
    overall_status=1
  fi
fi

if [[ "${BENCHMARK_WRITE_REPORT:-true}" == "true" ]]; then
  # REPORT.md is a promised artifact: a failed render is a run failure.
  if ! "${PYTHON_BIN}" "${SCRIPT_DIR}/write-benchmark-report.py" \
    "${RUN_DIR}" \
    --description "${BENCHMARK_DESCRIPTION:-Server-side benchmark run.}"; then
    overall_status=1
    printf 'Report generation failed for %s\n' "${RUN_DIR}" >&2
  fi
fi

printf 'Benchmark run written to %s\n' "${RUN_DIR}"

if [[ "${overall_status}" -ne 0 ]]; then
  printf 'Benchmark suite finished with failures (see status.json / SLO.md above).\n' >&2
fi
exit "${overall_status}"
