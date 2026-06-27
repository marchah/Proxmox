#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

VMID="${VMID:-200}"
LXC_HOSTNAME="${LXC_HOSTNAME:-bench-runner}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-}"
ROOT_STORAGE="${ROOT_STORAGE:-local-lvm}"
ROOT_SIZE_GB="${ROOT_SIZE_GB:-16}"
MEMORY_MB="${MEMORY_MB:-4096}"
SWAP_MB="${SWAP_MB:-1024}"
CORES="${CORES:-2}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
PASSWORD="${PASSWORD:-}"
START_ON_BOOT="${START_ON_BOOT:-0}"
START_AFTER_CREATE="${START_AFTER_CREATE:-1}"
TARGET_LXC_VMID="${TARGET_LXC_VMID:-120}"
TARGET_BASE_URL="${TARGET_BASE_URL:-}"
OPENAI_MODEL="${OPENAI_MODEL:-}"
RESULTS_DIR="${RESULTS_DIR:-/results}"
INSTALL_LLAMA_BENCHY="${INSTALL_LLAMA_BENCHY:-1}"
INSTALL_LM_EVAL="${INSTALL_LM_EVAL:-1}"
# Pin benchmark tools for reproducibility. Override to a different version, or
# set to "latest" to track the newest release (not recommended for repeatable
# runs). Defaults track the versions validated against this suite.
LLAMA_BENCHY_VERSION="${LLAMA_BENCHY_VERSION:-0.3.8}"
LM_EVAL_VERSION="${LM_EVAL_VERSION:-0.4.12}"
BENCH_RAW_BASE="${BENCH_RAW_BASE:-https://raw.githubusercontent.com/marchah/Proxmox/main/bench-runner}"

usage() {
  cat <<'USAGE'
Create a small LXC benchmark runner for the local AI benchmark suite.

Run this script on the Proxmox host as root.

Useful overrides:
  VMID=200 LXC_HOSTNAME=bench-runner ./create-lxc-bench-runner.sh
  TARGET_LXC_VMID=120 ./create-lxc-bench-runner.sh
  TARGET_BASE_URL=http://192.168.50.123:1234/v1 ./create-lxc-bench-runner.sh
  OPENAI_MODEL=served-model-id ./create-lxc-bench-runner.sh
  INSTALL_LM_EVAL=0 ./create-lxc-bench-runner.sh

The script creates an unprivileged Debian LXC and installs wrapper commands:
  llm-bench-suite
  llm-bench-baseline
  llm-bench-concurrency
  llm-bench-soak
  llm-bench-quality
  llm-bench-compare
  llm-bench-env
  llm-bench-sweep
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "run this script as root on the Proxmox host"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

resolve_template() {
  if [[ -n ${TEMPLATE} ]]; then
    return
  fi

  log "Resolving latest Debian 12 LXC template"
  TEMPLATE="$(
    pveam available --section system \
      | awk '/debian-12-standard_[^[:space:]]+_amd64\.tar\.zst/ {print $2}' \
      | sort -V \
      | tail -n 1
  )"

  [[ -n ${TEMPLATE} ]] || die "could not find a Debian 12 LXC template via pveam"
}

template_ref() {
  printf '%s:vztmpl/%s\n' "${TEMPLATE_STORAGE}" "${TEMPLATE}"
}

download_template_if_missing() {
  local template_path="/var/lib/vz/template/cache/${TEMPLATE}"

  if [[ -f ${template_path} ]]; then
    return
  fi

  log "Downloading LXC template ${TEMPLATE}"
  pveam update
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
}

assert_vmid_available() {
  if pct status "${VMID}" >/dev/null 2>&1; then
    die "VMID ${VMID} already exists"
  fi
}

discover_target_base_url() {
  local target_ip

  if [[ -n ${TARGET_BASE_URL} ]]; then
    return
  fi

  if pct status "${TARGET_LXC_VMID}" >/dev/null 2>&1; then
    target_ip="$(pct exec "${TARGET_LXC_VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n ${target_ip} ]]; then
      TARGET_BASE_URL="http://${target_ip}:1234/v1"
      return
    fi
  fi

  TARGET_BASE_URL="http://lmstudio:1234/v1"
}

create_container() {
  local ostemplate
  local rootfs
  local net0
  local -a create_args

  ostemplate="$(template_ref)"
  rootfs="${ROOT_STORAGE}:${ROOT_SIZE_GB}"
  net0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},type=veth"

  log "Creating benchmark LXC ${VMID} (${LXC_HOSTNAME})"

  create_args=(
    "${VMID}"
    "${ostemplate}"
    --hostname "${LXC_HOSTNAME}"
    --cores "${CORES}"
    --memory "${MEMORY_MB}"
    --swap "${SWAP_MB}"
    --rootfs "${rootfs}"
    --net0 "${net0}"
    --features "nesting=1,keyctl=1"
    --unprivileged 1
    --onboot "${START_ON_BOOT}"
    --ostype debian
  )

  if [[ -n ${PASSWORD} ]]; then
    create_args+=(--password "${PASSWORD}")
  fi

  pct create "${create_args[@]}"
}

start_container() {
  if [[ ${START_AFTER_CREATE} == 1 ]]; then
    log "Starting LXC ${VMID}"
    pct start "${VMID}"
  fi
}

wait_for_container() {
  log "Waiting for container startup"
  for _ in {1..60}; do
    if pct exec "${VMID}" -- test -d /run/systemd/system >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done

  die "container did not become ready in time"
}

run_in_container() {
  pct exec "${VMID}" -- "$@"
}

install_base_packages() {
  log "Installing benchmark runtime packages"

  run_in_container bash -lc "apt-get update"
  run_in_container bash -lc "DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git jq lm-sensors pciutils procps python3 python3-venv sudo tar"
  run_in_container bash -lc "useradd --create-home --shell /bin/bash bench || true"
  run_in_container bash -lc "install -d -o bench -g bench /opt/bench-runner '${RESULTS_DIR}'"
}

write_build_info() {
  # Record the source commit so the deployed copy (which has no .git) can still
  # report provenance via collect-version-info.py. Best effort: skip if the
  # source dir is not a git checkout.
  local commit dirty
  commit="$(git -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || true)"
  [[ -n ${commit} ]] || return 0
  if [[ -n "$(git -C "${SCRIPT_DIR}" status --short 2>/dev/null || true)" ]]; then
    dirty=true
  else
    dirty=false
  fi
  cat >"${SCRIPT_DIR}/config/build-info.json" <<EOF
{
  "git_commit": "${commit}",
  "git_dirty": ${dirty},
  "source": "create-lxc-bench-runner.sh"
}
EOF
}

copy_local_benchmark_suite() {
  local bundle="/tmp/bench-runner-suite.$$.tgz"

  log "Copying local benchmark suite into LXC"
  write_build_info
  tar -C "${SCRIPT_DIR}" -czf "${bundle}" \
    scripts \
    config \
    BENCHMARKS.md \
    FUTURE_IMPROVEMENTS.md \
    README.md

  pct push "${VMID}" "${bundle}" /tmp/bench-runner-suite.tgz
  run_in_container bash -lc "tar -xzf /tmp/bench-runner-suite.tgz -C /opt/bench-runner && rm -f /tmp/bench-runner-suite.tgz && chown -R bench:bench /opt/bench-runner"

  rm -f -- "${bundle}"
}

download_benchmark_suite() {
  log "Downloading benchmark suite from ${BENCH_RAW_BASE}"

  pct exec "${VMID}" -- bash -s -- "${BENCH_RAW_BASE%/}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

RAW_BASE="$1"
files=(
  "BENCHMARKS.md"
  "FUTURE_IMPROVEMENTS.md"
  "README.md"
  "config/benchmark-profiles/baseline.env"
  "config/benchmark-profiles/concurrency.env"
  "config/benchmark-profiles/quality.env"
  "config/benchmark-profiles/soak.env"
  "config/benchmark-promptsets/homelab-core.jsonl"
  "config/benchmark-slos/default.json"
  "scripts/benchmarks/benchmark-openai-api.py"
  "scripts/benchmarks/capture-system-logs.sh"
  "scripts/benchmarks/collect-version-info.py"
  "scripts/benchmarks/compare-benchmark-runs.py"
  "scripts/benchmarks/evaluate-slos.py"
  "scripts/benchmarks/finalize-run.py"
  "scripts/benchmarks/run-ai-benchmark-suite.sh"
  "scripts/benchmarks/run-remote-benchmark-suite.sh"
  "scripts/benchmarks/run-sweep.py"
  "scripts/benchmarks/summarize-benchmark-run.py"
  "scripts/benchmarks/summarize-telemetry.py"
  "scripts/benchmarks/sync-benchmark-run.sh"
  "scripts/benchmarks/system-sampler.py"
  "scripts/benchmarks/write-benchmark-report.py"
)

for file in "${files[@]}"; do
  install -d "/opt/bench-runner/$(dirname "${file}")"
  curl --fail --show-error --silent --location \
    --output "/opt/bench-runner/${file}" \
    "${RAW_BASE}/${file}"
done

chmod +x /opt/bench-runner/scripts/benchmarks/*.sh /opt/bench-runner/scripts/benchmarks/*.py
chown -R bench:bench /opt/bench-runner
CONTAINER_SCRIPT
}

install_benchmark_suite() {
  if [[ -f "${SCRIPT_DIR}/scripts/benchmarks/run-ai-benchmark-suite.sh" ]]; then
    copy_local_benchmark_suite
  else
    download_benchmark_suite
  fi
}

install_optional_tools() {
  log "Installing optional benchmark tools"

  pct exec "${VMID}" -- bash -s -- \
    "${INSTALL_LLAMA_BENCHY}" \
    "${INSTALL_LM_EVAL}" \
    "${LLAMA_BENCHY_VERSION}" \
    "${LM_EVAL_VERSION}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

INSTALL_LLAMA_BENCHY="$1"
INSTALL_LM_EVAL="$2"
LLAMA_BENCHY_VERSION="$3"
LM_EVAL_VERSION="$4"

# Build a uv install spec: a bare version pins it; "latest" tracks newest.
if [[ "${LLAMA_BENCHY_VERSION}" == "latest" ]]; then
  LLAMA_BENCHY_SPEC="llama-benchy@latest"
else
  LLAMA_BENCHY_SPEC="llama-benchy==${LLAMA_BENCHY_VERSION}"
fi
if [[ "${LM_EVAL_VERSION}" == "latest" ]]; then
  LM_EVAL_SPEC="lm_eval[api]"
else
  LM_EVAL_SPEC="lm_eval[api]==${LM_EVAL_VERSION}"
fi

install -d /home/bench/.local/bin /home/bench/.local/share
chown -R bench:bench /home/bench/.local

if [[ ! -x /home/bench/.local/bin/uv ]]; then
  sudo -u bench bash -lc '
    installer="$(mktemp)"
    curl --fail --show-error --silent --location \
      --output "${installer}" \
      https://astral.sh/uv/install.sh
    sh -n "${installer}"
    sh "${installer}"
    rm -f "${installer}"
  '
fi

if [[ ${INSTALL_LLAMA_BENCHY} == 1 ]]; then
  sudo -u bench bash -lc "export PATH=\"\$HOME/.local/bin:\$PATH\"; uv tool install --force \"${LLAMA_BENCHY_SPEC}\""
  ln -sfn /home/bench/.local/bin/llama-benchy /usr/local/bin/llama-benchy
fi

if [[ ${INSTALL_LM_EVAL} == 1 ]]; then
  sudo -u bench bash -lc "export PATH=\"\$HOME/.local/bin:\$PATH\"; uv tool install --force \"${LM_EVAL_SPEC}\""
  ln -sfn /home/bench/.local/bin/lm_eval /usr/local/bin/lm_eval
fi

ln -sfn /home/bench/.local/bin/uv /usr/local/bin/uv
ln -sfn /home/bench/.local/bin/uvx /usr/local/bin/uvx
CONTAINER_SCRIPT
}

configure_benchmark_environment() {
  log "Configuring benchmark environment"

  pct exec "${VMID}" -- bash -s -- \
    "${TARGET_BASE_URL}" \
    "${OPENAI_MODEL}" \
    "${RESULTS_DIR}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

TARGET_BASE_URL="$1"
MODEL_IDENTIFIER="$2"
RESULTS_DIR="$3"

if [[ -z ${MODEL_IDENTIFIER} ]]; then
  MODEL_IDENTIFIER="$(
    python3 - "${TARGET_BASE_URL}" <<'PY' || true
import json
import sys
import urllib.request

base_url = sys.argv[1].rstrip("/")
with urllib.request.urlopen(f"{base_url}/models", timeout=15) as response:
    payload = json.loads(response.read().decode("utf-8"))
for item in payload.get("data", []):
    model_id = item.get("id")
    if model_id:
        print(model_id)
        break
PY
  )"
fi

if [[ -z ${MODEL_IDENTIFIER} ]]; then
  MODEL_IDENTIFIER="local-model"
  cat >&2 <<WARN

============================================================
WARNING: could not reach ${TARGET_BASE_URL}/models, or no model
is currently served there. MODEL_IDENTIFIER defaulted to
"local-model" and benchmarks will FAIL until this is fixed.

Fix one of:
  - Start the LM Studio container, load a model, then edit
    /opt/bench-runner/config/local-model.env (MODEL_IDENTIFIER=).
  - Re-create this LXC with OPENAI_MODEL=<served-model-id>.
  - Re-create this LXC with TARGET_BASE_URL=http://<ip>:1234/v1.
============================================================

WARN
fi

# Every value uses ':=' so it stays overridable at run time, e.g.
#   MODEL_API_URL=http://other:1234/v1 llm-bench-baseline
cat >/opt/bench-runner/config/local-model.env <<EOF
: "\${MODEL_API_URL:=${TARGET_BASE_URL}}"
: "\${MODEL_IDENTIFIER:=${MODEL_IDENTIFIER}}"
: "\${RUN_LLAMA_BENCHY:=true}"
: "\${RUN_LM_EVAL:=false}"
: "\${LLAMA_BENCHY_USE_UVX:=false}"
: "\${BENCHMARK_OUT_ROOT:=${RESULTS_DIR}}"
: "\${BENCHMARK_PROCESS_PATTERNS:=lms,LM Studio,python,llama-benchy,lm_eval}"
EOF

cat >/etc/bench-runner.env <<EOF
BENCH_RUNNER_DIR=/opt/bench-runner
: "\${MODEL_API_URL:=${TARGET_BASE_URL}}"
: "\${MODEL_IDENTIFIER:=${MODEL_IDENTIFIER}}"
: "\${BENCHMARK_OUT_ROOT:=${RESULTS_DIR}}"
EOF
# This file may later be appended with secrets (e.g. HF_TOKEN), so keep it
# readable only by root.
chmod 600 /etc/bench-runner.env

cat >/usr/local/bin/llm-bench-suite <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
set -a
source /etc/bench-runner.env
set +a
cd "${BENCH_RUNNER_DIR}"
exec ./scripts/benchmarks/run-ai-benchmark-suite.sh "$@"
SH

cat >/usr/local/bin/llm-bench-profile <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
profile="${1:?usage: llm-bench-profile <profile> [description...]}"
shift || true
description="${*:-Proxmox benchmark runner profile: ${profile}}"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-${profile}"
set -a
source /etc/bench-runner.env
set +a
cd "${BENCH_RUNNER_DIR}"
BENCHMARK_PROFILE="${profile}" \
BENCHMARK_RUN_ID="${run_id}" \
BENCHMARK_DESCRIPTION="${description}" \
RUN_LLAMA_BENCHY="${RUN_LLAMA_BENCHY:-true}" \
RUN_LM_EVAL="${RUN_LM_EVAL:-false}" \
exec ./scripts/benchmarks/run-ai-benchmark-suite.sh
SH

cat >/usr/local/bin/llm-bench-baseline <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
exec llm-bench-profile baseline "$@"
SH

cat >/usr/local/bin/llm-bench-concurrency <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
exec llm-bench-profile concurrency "$@"
SH

cat >/usr/local/bin/llm-bench-soak <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
exec llm-bench-profile soak "$@"
SH

cat >/usr/local/bin/llm-bench-quality <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
RUN_LM_EVAL=true exec llm-bench-profile quality "$@"
SH

cat >/usr/local/bin/llm-bench-compare <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $# -ne 2 ]]; then
  printf 'usage: llm-bench-compare <baseline-run-dir> <candidate-run-dir>\n' >&2
  exit 1
fi
set -a
source /etc/bench-runner.env
set +a
exec python3 "${BENCH_RUNNER_DIR}/scripts/benchmarks/compare-benchmark-runs.py" "$1" "$2" --output "$2/COMPARE.md"
SH

cat >/usr/local/bin/llm-bench-env <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
# Mask the value of any secret-looking variable (TOKEN/KEY/SECRET/PASSWORD) so
# this diagnostic never prints credentials such as HF_TOKEN.
sed -E 's/^([[:alnum:]_]*(TOKEN|KEY|SECRET|PASSWORD|PASS)[[:alnum:]_]*=).*/\1<redacted>/I' /etc/bench-runner.env
printf '\n'
cat /opt/bench-runner/config/local-model.env
SH

cat >/usr/local/bin/llm-bench-sweep <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
mode="${1:?usage: llm-bench-sweep <concurrency|input-length> [run-sweep.py args...]}"
shift || true
set -a
source /etc/bench-runner.env
set +a
run_id="$(date -u +%Y%m%dT%H%M%SZ)-sweep-${mode}"
exec python3 "${BENCH_RUNNER_DIR}/scripts/benchmarks/run-sweep.py" \
  --mode "${mode}" \
  --output-dir "${BENCHMARK_OUT_ROOT:-/results}/${run_id}" \
  "$@"
SH

chmod 755 \
  /usr/local/bin/llm-bench-suite \
  /usr/local/bin/llm-bench-profile \
  /usr/local/bin/llm-bench-baseline \
  /usr/local/bin/llm-bench-concurrency \
  /usr/local/bin/llm-bench-soak \
  /usr/local/bin/llm-bench-quality \
  /usr/local/bin/llm-bench-compare \
  /usr/local/bin/llm-bench-env \
  /usr/local/bin/llm-bench-sweep

chmod +x /opt/bench-runner/scripts/benchmarks/*.sh /opt/bench-runner/scripts/benchmarks/*.py
chown -R bench:bench /opt/bench-runner "${RESULTS_DIR}"
CONTAINER_SCRIPT
}

print_summary() {
  local ip
  local model_identifier
  ip="$(pct exec "${VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  # shellcheck disable=SC2016  # ${MODEL_IDENTIFIER} must expand inside the container
  model_identifier="$(pct exec "${VMID}" -- bash -lc 'source /etc/bench-runner.env && printf "%s" "${MODEL_IDENTIFIER}"' 2>/dev/null || true)"

  log "Done"
  printf 'Benchmark LXC: %s (%s)\n' "${VMID}" "${LXC_HOSTNAME}"
  if [[ -n ${ip} ]]; then
    printf 'Runner IP: %s\n' "${ip}"
  fi
  printf 'Target API: %s\n' "${TARGET_BASE_URL}"
  printf 'Model identifier: %s\n' "${model_identifier:-unknown}"
  printf '\nRun benchmarks from the Proxmox host:\n'
  printf "  pct exec %s -- bash -lc 'llm-bench-baseline'\n" "${VMID}"
  printf "  pct exec %s -- bash -lc 'llm-bench-concurrency'\n" "${VMID}"
  printf "  pct exec %s -- bash -lc 'llm-bench-soak'\n" "${VMID}"
  printf "  pct exec %s -- bash -lc 'llm-bench-quality'\n" "${VMID}"
}

main() {
  if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
    usage
    exit 0
  fi

  require_root
  require_command pct
  require_command pveam
  require_command tar
  assert_vmid_available
  resolve_template
  download_template_if_missing
  discover_target_base_url
  create_container
  start_container
  wait_for_container
  install_base_packages
  install_benchmark_suite
  install_optional_tools
  configure_benchmark_environment
  print_summary
}

main "$@"
