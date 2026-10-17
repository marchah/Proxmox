#!/usr/bin/env bash
# Run Strata's own benchmark suite (tools/strata_bench.py, Strata's docs/COMMUNITY_BENCHMARKS.md)
# against CT 123's Strata server for each cell of a CELLS file, round-robin PASSES times with a
# cold start per load: the data for a report in Strata's bench/results format. The cells format,
# the base env check and the restore are strata-sweep.sh's; Strata's suite replaces our probes.
# Runs on the Proxmox HOST as root, from a harness staged with ../push-harness.sh, with CT 123
# already holding every card the cells name.
#
#   cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
#   UNIT=strata-qwen38fn PATTERNS=build-hip/strata ./thermal-guard.sh    # in another shell first
#   CELLS=runs/<record>.cells ../strata/strata-community-bench.sh
#
# Cells: `LABEL KEY=VALUE ...`, with MODEL_* and STRATA_* keys as in strata-sweep.sh. Each load
# runs strata_bench.py with BENCH_ARGS through the server's loopback address inside the
# container, so the tool reads the container's GPUs, CPU and memory. On the first pass,
# needle_bench.py also runs at the NEEDLES lengths (empty skips it), depths 10, 50 and 90.
# OUT_DIR/<label>-r<pass>/ gets the tool's results folder, needles.json, the tools' output, the
# start's engine log and the server's journal; strata-bench-summary.py OUT_DIR sums them up.
set -Eeuo pipefail

VMID="${VMID:-123}"
UNIT="${UNIT:-strata-qwen38fn}"
PORT="${PORT:-1234}"
PASSES="${PASSES:-3}"
BENCH_ARGS="${BENCH_ARGS:---long}"
NEEDLES="${NEEDLES:-32k,60k}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-1800}"
# No load starts while the hottest DIMM is above this; the BMC caps memory bandwidth at 66 °C.
DIMM_START_MAX_C="${DIMM_START_MAX_C:-58}"
# thermal-guard.sh writes this on a trip: no further load starts and the server stays stopped.
TRIP_FILE="${TRIP_FILE:-/root/qwen38-flash-next/THERMAL_TRIP}"
OUT_DIR="${OUT_DIR:-/root/qwen38-flash-next/strata-bench-$(date -u +%Y%m%dT%H%M%SZ)}"
CELLS="${CELLS:-}"

readonly ENVFILE="/etc/${UNIT}.env"
readonly ENGINE_LOG="/var/log/${UNIT}/engine.log"
readonly CONFIG="/var/lib/${UNIT}/config.json"
readonly LOCAL="http://127.0.0.1:${PORT}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }
in_ct() { pct exec "$VMID" -- "$@"; }

set_env_var() {   # KEY VALUE, quoted with json.dumps so the launcher's `source` reads it whole
  in_ct python3 -c '
import json, os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
line = key + "=" + json.dumps(val)
src = open(path).read() if os.path.exists(path) else ""
src, n = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", lambda m: line, src)
if not n:
    src = src.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(src)
' "$ENVFILE" "$1" "$2"
}
unset_env_var() {
  in_ct python3 -c '
import os, re, sys
path, key = sys.argv[1], sys.argv[2]
if os.path.exists(path):
    src = open(path).read()
    open(path, "w").write(re.sub(r"(?m)^" + re.escape(key) + r"=.*\n?", "", src))
' "$ENVFILE" "$1"
}

hottest_dimm() {
  ipmitool sdr type Temperature 2>/dev/null \
    | awk -F'|' '/DDR4/ && $5 ~ /degrees/ {v = $5; gsub(/[^0-9]/, "", v); if (v + 0 > m) m = v + 0} END {print m + 0}'
}
dimm_cooldown() {
  local t waited=0
  while t="$(hottest_dimm)"; [ "$t" -gt "$DIMM_START_MAX_C" ]; do
    [ "$waited" -gt 0 ] || log "hottest DIMM ${t} °C, above ${DIMM_START_MAX_C} °C: waiting before the next load"
    sleep 30; waited=$((waited + 30))
  done
  [ "$waited" -eq 0 ] || log "hottest DIMM ${t} °C after ${waited}s"
}
vram_mib() { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_vram_used" 2>/dev/null || echo 0) / 1048576 )); }

check_inputs() {
  [ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
  [[ "$UNIT" =~ ^strata-[a-z0-9-]+$ ]] || die "UNIT must name a strata-* unit"
  [[ "$PASSES" =~ ^[1-9][0-9]*$ ]] || die "PASSES must be a positive whole number"
  [[ "$NEEDLES" =~ ^([0-9]+k(,[0-9]+k)*)?$ ]] || die "NEEDLES must be lengths like 32k,60k, or empty"
  [ -n "$CELLS" ] || die "CELLS must name a cells file"
  CELLS="$(readlink -f "$CELLS")"
  [ -f "$CELLS" ] || die "CELLS file ${CELLS} not found"
  cd "$(dirname "$(readlink -f "$0")")"
  [ ! -e "$TRIP_FILE" ] || die "thermal trip recorded in ${TRIP_FILE}; check cooling, then remove it"
  local d="$PWD"
  HARNESS_COMMIT=""
  while [ "$d" != "/" ]; do
    if [ -f "$d/HARNESS_COMMIT" ]; then HARNESS_COMMIT="$(head -1 "$d/HARNESS_COMMIT")"; break; fi
    d="$(dirname "$d")"
  done
  [ -n "$HARNESS_COMMIT" ] || die "no HARNESS_COMMIT: stage with pro-v620/push-harness.sh"
  [ "$(pct status "$VMID" | awk '{print $2}')" = "running" ] || die "CT ${VMID} is not running"
  [ -f "./${UNIT}.env" ] || die "no base env file ./${UNIT}.env"
  in_ct cat "$ENVFILE" | cmp -s - "./${UNIT}.env" \
    || die "${ENVFILE} in CT ${VMID} differs from ${UNIT}.env at ${HARNESS_COMMIT:0:12}; run install.sh from this harness"
  mapfile -t CARDS < <(pct config "$VMID" | grep -oE 'pci-0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]-render' \
                       | sed 's/^pci-//; s/-render$//' | sort -u)
  [ "${#CARDS[@]}" -ge 1 ] || die "no passed-through GPU in CT ${VMID}'s config"
  # shellcheck disable=SC2016  # expands inside the container
  read -r STRATA_HOME STRATA_VENV < <(in_ct bash -c 'set -a; . "$1"; printf "%s %s\n" "$STRATA_HOME" "$STRATA_VENV"' _ "$ENVFILE")
  in_ct test -f "${STRATA_HOME}/tools/strata_bench.py" || die "no tools/strata_bench.py in ${STRATA_HOME}"
}

declare -a CELL_ORDER=()
declare -A CELL=()
read_cells() {
  local parsed kind label key val c
  parsed="$(python3 - "$CELLS" <<'PY'
import re, shlex, sys
seen = set()
for n, line in enumerate(open(sys.argv[1]), 1):
    words = shlex.split(line, comments=True)
    if not words:
        continue
    label = words[0]
    if not re.fullmatch(r"[A-Za-z0-9._+-]+", label) or label in seen:
        sys.exit("CELLS line %d: bad or duplicate label %r" % (n, label))
    seen.add(label)
    print("L\t%s" % label)
    for word in words[1:]:
        key, eq, value = word.partition("=")
        if not eq or not re.fullmatch(r"(MODEL|STRATA)_[A-Z0-9_]+", key) or "\t" in value or "\n" in value:
            sys.exit("CELLS line %d: bad setting %r" % (n, word))
        print("S\t%s\t%s\t%s" % (label, key, value))
PY
)" || die "bad CELLS file ${CELLS}"
  while IFS=$'\t' read -r kind label key val; do
    if [ "$kind" = L ]; then CELL_ORDER+=("$label"); else CELL[$label|$key]="$val"; fi
  done <<<"$parsed"
  [ "${#CELL_ORDER[@]}" -ge 1 ] || die "no cells to run"
  for label in "${CELL_ORDER[@]}"; do
    for c in $(tr ',' ' ' <<<"${CELL[$label|MODEL_GPUS]:-}"); do
      printf '%s\n' "${CARDS[@]}" | grep -qx "$c" || die "cell '${label}': MODEL_GPUS names ${c}; CT ${VMID} binds ${CARDS[*]}"
    done
  done
}

WAS_ACTIVE=""; ENV_BACKUP=""
cleanup() {
  [ -n "$ENV_BACKUP" ] || return 0
  in_ct cp -p "$ENV_BACKUP" "$ENVFILE"
  if [ -e "$TRIP_FILE" ]; then
    in_ct systemctl stop "$UNIT" 2>/dev/null || true
    log "restored ${ENVFILE}; thermal trip in ${TRIP_FILE}, so the service stays stopped"
  elif [ "$WAS_ACTIVE" = "active" ]; then
    in_ct systemctl restart "$UNIT"
    log "restored ${ENVFILE} from ${ENV_BACKUP} and restarted ${UNIT}"
  else
    in_ct systemctl stop "$UNIT" 2>/dev/null || true
    log "restored ${ENVFILE} from ${ENV_BACKUP}; service left stopped, as found"
  fi
}

# Start one cell's server from the base env plus the cell's keys. Sets LOAD_OK, LOAD_S and
# LOG_OFFSET (the engine log's size before this start, so the load keeps only its own lines).
LOAD_OK=false; LOAD_S=0; LOG_OFFSET=0
start_server() {
  local label="$1" key val waited=0 card busy t0
  in_ct systemctl stop "$UNIT" 2>/dev/null || true
  # Wait for the previous engine's VRAM to drain.
  while [ "$waited" -lt 90 ]; do
    busy=false
    for card in "${CARDS[@]}"; do [ "$(vram_mib "$card")" -gt 2000 ] && busy=true; done
    [ "$busy" = "false" ] && break
    sleep 3; waited=$((waited + 3))
  done
  in_ct cp -p "$ENV_BACKUP" "$ENVFILE"
  for key in "${!CELL[@]}"; do
    [ "${key%%|*}" = "$label" ] || continue
    key="${key#*|}"; val="${CELL[$label|$key]}"
    if [[ "$key" == STRATA_* && -z "$val" ]]; then unset_env_var "$key"; else set_env_var "$key" "$val"; fi
  done
  LOG_OFFSET="$(in_ct stat -c %s "$ENGINE_LOG" 2>/dev/null || echo 0)"
  in_ct systemctl start "$UNIT"
  log "waiting for /v1/models (the engine loads its experts into RAM)"
  t0="$(date +%s)"; LOAD_OK=false; LOAD_S=0
  until in_ct curl -fsS --max-time 5 "${LOCAL}/v1/models" 2>/dev/null | grep -q '"id"'; do
    if ! in_ct systemctl is-active --quiet "$UNIT"; then
      log "🔴 ${label}: server exited while loading — load recorded as failed"
      return 0
    fi
    sleep 2
    if [ $(( $(date +%s) - t0 )) -ge "$HEALTH_TIMEOUT" ]; then
      log "🔴 ${label}: not serving after ${HEALTH_TIMEOUT}s — load recorded as failed"
      return 0
    fi
  done
  LOAD_OK=true; LOAD_S=$(( $(date +%s) - t0 ))
  log "serving after ${LOAD_S}s"
}

# One load's measurements: strata_bench.py, then (first pass) needle_bench.py, copied out of
# the container with the start's engine log and the server's journal.
run_load() {
  local label="$1" pass="$2" since="$3" dir ct_dir
  dir="${OUT_DIR}/${label}-r${pass}"
  ct_dir="/root/strata-bench/$(basename "$OUT_DIR")/${label}-r${pass}"
  mkdir -p "$dir"
  in_ct mkdir -p "$ct_dir"
  # shellcheck disable=SC2086  # BENCH_ARGS is a list of the tool's flags
  in_ct "${STRATA_VENV}/bin/python" "${STRATA_HOME}/tools/strata_bench.py" --config "$CONFIG" --url "$LOCAL" \
    $BENCH_ARGS --out "$ct_dir" >"${dir}/strata_bench.out" 2>&1 \
    || log "🔴 ${label}-r${pass}: strata_bench.py exited non-zero (see strata_bench.out)"
  if [ "$pass" -eq 1 ] && [ -n "$NEEDLES" ]; then
    in_ct "${STRATA_VENV}/bin/python" "${STRATA_HOME}/tools/needle_bench.py" --url "$LOCAL" --lengths "$NEEDLES" \
      --depths 10,50,90 --out "${ct_dir}/needles.json" >"${dir}/needle_bench.out" 2>&1 \
      || log "🔴 ${label}-r${pass}: needle_bench.py exited non-zero (see needle_bench.out)"
  fi
  in_ct tar -C "$ct_dir" -cf - . | tar -C "$dir" -xf -
  in_ct tail -c +"$((LOG_OFFSET + 1))" "$ENGINE_LOG" >"${dir}/engine.log" 2>/dev/null || true
  in_ct journalctl -u "$UNIT" --since "@${since}" --no-pager -o cat >"${dir}/server.log" 2>/dev/null || true
  printf '{"label": "%s", "pass": %s, "load_s": %s, "harness": "%s"}\n' "$label" "$pass" "$LOAD_S" \
    "${HARNESS_COMMIT:0:12}" >"${dir}/load.json"
}

main() {
  local pass label since
  check_inputs
  read_cells
  mkdir -p "$OUT_DIR"
  cp "$CELLS" "${OUT_DIR}/cells.txt"
  ENV_BACKUP="${ENVFILE}.pre-bench-$(date -u +%Y%m%dT%H%M%SZ)"
  in_ct cp -p "$ENVFILE" "$ENV_BACKUP"
  WAS_ACTIVE="$(in_ct systemctl is-active "$UNIT" 2>/dev/null || true)"
  trap cleanup EXIT
  log "CT ${VMID}, cards ${CARDS[*]}, harness ${HARNESS_COMMIT:0:12}; ${#CELL_ORDER[@]} cells x ${PASSES} passes; results -> ${OUT_DIR}"
  ../capture-env.sh "$VMID" "$UNIT" >"${OUT_DIR}/environment.json" || die "capture-env.sh failed for CT ${VMID}"
  for pass in $(seq 1 "$PASSES"); do
    for label in "${CELL_ORDER[@]}"; do
      log "=== ${label}-r${pass} ==="
      dimm_cooldown
      [ ! -e "$TRIP_FILE" ] || die "thermal trip recorded in ${TRIP_FILE}; stopping the run"
      since="$(date +%s)"
      start_server "$label"
      if [ "$LOAD_OK" != true ]; then
        mkdir -p "${OUT_DIR}/${label}-r${pass}"
        in_ct journalctl -u "$UNIT" --since "@${since}" --no-pager -o cat >"${OUT_DIR}/${label}-r${pass}/server.log" 2>/dev/null || true
        continue
      fi
      run_load "$label" "$pass" "$since"
    done
  done
  log "run complete — ${OUT_DIR}"
  ./strata-bench-summary.py "$OUT_DIR" | tee "${OUT_DIR}/SUMMARY.md"
}

main "$@"
