#!/usr/bin/env bash

set -Eeuo pipefail

# Run on the Proxmox host. Wrap a benchmark command (typically
#   pct exec <bench-vmid> -- bash -lc '<llm-bench-* wrapper>'
# ) so that while it runs we sample telemetry *inside the target model
# container* (CT 120 by default), not the bench-runner.
#
# Why: the bench-runner LXC is unprivileged and sees only its own
# lxcfs-virtualised /proc, so the in-LXC sampler's CPU/RAM/process metrics
# describe the benchmark *client*, not LM Studio. (Its GPU + temperature data
# is still valid, because /sys/class/drm and hwmon are host-real.) To know
# whether the model server was CPU/RAM-bound we must sample the model
# container. We push system-sampler.py into the target, run it there during the
# command (its own /proc reports the server's CPU/RAM, and its PID namespace
# finally matches the `lms`/`LM Studio` process patterns), then merge the
# captured target-telemetry.jsonl into each new /results/<run-id>/ folder so it
# travels with the run and survives the result fetch.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SAMPLER="${SCRIPT_DIR}/../scripts/benchmarks/system-sampler.py"

GPU_VMID="${GPU_VMID:-120}"
BENCH_VMID="${BENCH_VMID:-200}"
TELEMETRY_INTERVAL="${TELEMETRY_INTERVAL:-1}"
TARGET_PROCESS_PATTERNS="${TARGET_PROCESS_PATTERNS:-lms,LM Studio,python}"
RESULTS_DIR="${RESULTS_DIR:-/results}"
BENCH_RUNNER_DIR="${BENCH_RUNNER_DIR:-/opt/bench-runner}"
# When true, fail the wrapper if target telemetry could not be captured (no
# samples). The Ansible batch sets this; manual runs default to false (opt-out).
REQUIRE_TARGET_TELEMETRY="${REQUIRE_TARGET_TELEMETRY:-false}"
readonly SAMPLER_UNIT="bench-target-sampler"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

usage() {
  cat <<'USAGE'
Wrap a benchmark command with target-container (model server) telemetry.

Run on the Proxmox host as root:
  GPU_VMID=120 BENCH_VMID=200 \
    ./run-with-target-telemetry.sh -- pct exec 200 -- bash -lc 'llm-bench-baseline'

Env overrides:
  GPU_VMID=120                   Target (model) container to sample.
  BENCH_VMID=200                 Bench-runner container that owns /results.
  TELEMETRY_INTERVAL=1           Seconds between target samples.
  TARGET_PROCESS_PATTERNS=...    Comma-separated process patterns to sample.
  REQUIRE_TARGET_TELEMETRY=false Fail the wrapper if no target samples captured.
USAGE
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi
# Allow callers to write `... -- pct exec ...` for readability.
[[ ${1:-} == "--" ]] && shift
[[ $# -gt 0 ]] || die "no command given (usage: run-with-target-telemetry.sh -- <command...>)"

command -v pct >/dev/null 2>&1 || die "pct not found (run on the Proxmox host)"

sampler_running=0
telemetry_captured=0
finalize_status=0

list_results() {
  pct exec "${BENCH_VMID}" -- bash -lc "ls -1 ${RESULTS_DIR} 2>/dev/null || true"
}

start_target_sampler() {
  if [[ ! -f "${SAMPLER}" ]]; then
    log "sampler not found at ${SAMPLER}; skipping target telemetry"
    return 1
  fi
  if ! pct status "${GPU_VMID}" >/dev/null 2>&1; then
    log "target container ${GPU_VMID} not found; skipping target telemetry"
    return 1
  fi
  if ! pct exec "${GPU_VMID}" -- bash -lc 'command -v python3 >/dev/null 2>&1 && command -v systemd-run >/dev/null 2>&1'; then
    log "python3 + systemd-run required in CT ${GPU_VMID}; skipping target telemetry"
    return 1
  fi

  local pattern_args="" pattern
  local patterns=()
  IFS=',' read -r -a patterns <<<"${TARGET_PROCESS_PATTERNS}"
  for pattern in "${patterns[@]}"; do
    [[ -n ${pattern} ]] && pattern_args+=" --process-pattern '${pattern}'"
  done

  pct push "${GPU_VMID}" "${SAMPLER}" /tmp/system-sampler.py >/dev/null
  # A process backgrounded via `pct exec` is torn down the moment the attach
  # returns, so run the sampler as a transient systemd unit inside the target.
  # It survives until we `systemctl stop` it; the sampler flushes every line and
  # exits cleanly on SIGTERM.
  pct exec "${GPU_VMID}" -- bash -lc "
    systemctl stop ${SAMPLER_UNIT} >/dev/null 2>&1 || true
    systemctl reset-failed ${SAMPLER_UNIT} >/dev/null 2>&1 || true
    rm -f /tmp/target-telemetry.jsonl
    systemd-run --unit=${SAMPLER_UNIT} --collect \
      python3 /tmp/system-sampler.py \
      --output /tmp/target-telemetry.jsonl \
      --interval ${TELEMETRY_INTERVAL}${pattern_args}
  "
  sampler_running=1
  log "Sampling CT ${GPU_VMID} (model server) telemetry"
  return 0
}

stop_target_sampler() {
  [[ ${sampler_running} -eq 1 ]] || return 0
  pct exec "${GPU_VMID}" -- bash -lc "
    systemctl stop ${SAMPLER_UNIT} >/dev/null 2>&1 || true
    systemctl reset-failed ${SAMPLER_UNIT} >/dev/null 2>&1 || true
  " >/dev/null 2>&1 || true
  sampler_running=0
}

merge_target_telemetry() {
  local before_file="$1" after_file="$2"
  local tmp_local="/tmp/target-telemetry.${BENCH_VMID}.$$.jsonl"

  if ! pct pull "${GPU_VMID}" /tmp/target-telemetry.jsonl "${tmp_local}" >/dev/null 2>&1; then
    log "no target telemetry captured (sampler did not run)"
    return 0
  fi
  if [[ ! -s "${tmp_local}" ]]; then
    log "target telemetry is empty (sampler captured 0 samples)"
    rm -f -- "${tmp_local}"
    return 0
  fi
  telemetry_captured=1

  local new_run merged=0
  while IFS= read -r new_run; do
    [[ -n ${new_run} ]] || continue
    pct exec "${BENCH_VMID}" -- bash -lc "mkdir -p ${RESULTS_DIR}/${new_run}" || continue
    if pct push "${BENCH_VMID}" "${tmp_local}" "${RESULTS_DIR}/${new_run}/target-telemetry.jsonl" >/dev/null 2>&1; then
      merged=1
      log "Merged target telemetry into ${RESULTS_DIR}/${new_run}/"
      # Regenerate SLO/report so they reflect the merged target telemetry
      # (the suite wrote them before this merge). No-ops on non-suite runs.
      if ! pct exec "${BENCH_VMID}" -- bash -lc "cd '${BENCH_RUNNER_DIR}' && python3 scripts/benchmarks/finalize-run.py '${RESULTS_DIR}/${new_run}'"; then
        finalize_status=1
        log "finalize-run reported an SLO failure for ${new_run}"
      fi
    fi
  done < <(comm -13 "${before_file}" "${after_file}")

  [[ ${merged} -eq 1 ]] || log "no new run folder found to attach target telemetry to"
  rm -f -- "${tmp_local}"
}

main() {
  local before_file after_file
  before_file="$(mktemp)"
  after_file="$(mktemp)"
  # shellcheck disable=SC2064  # expand paths now so cleanup works after locals vanish
  trap "stop_target_sampler; rm -f -- '${before_file}' '${after_file}'" EXIT

  list_results | sort >"${before_file}"
  start_target_sampler || true

  local status=0
  "$@" || status=$?

  stop_target_sampler
  list_results | sort >"${after_file}"
  merge_target_telemetry "${before_file}" "${after_file}"

  if [[ "${REQUIRE_TARGET_TELEMETRY}" == "true" && ${telemetry_captured} -eq 0 ]]; then
    log "REQUIRE_TARGET_TELEMETRY=true but no model-server telemetry was captured"
    [[ ${status} -eq 0 ]] && status=1
  fi
  # A target-telemetry-induced SLO breach (surfaced only after the merge) should
  # fail a run that the benchmark itself reported as ok.
  if [[ ${status} -eq 0 && ${finalize_status} -ne 0 ]]; then
    status="${finalize_status}"
  fi

  return "${status}"
}

main "$@"
