#!/usr/bin/env bash
# Sweep Strata server configurations for Qwen3.8-Flash-Next in CT 123, or Project Maya's for
# GLM-5.3-Flash (UNIT=maya-glm53f), and report, per cell, decode and prefill by prompt class
# and context depth, with the engine's expert cache, VRAM residency, card and CPU use and the
# hottest DIMM. The Strata counterpart of
# ../qwen38-flash-next/placement-sweep.sh: the same probes in chat mode, telemetry, gates and
# summary. Runs on the Proxmox HOST as root, from a harness staged with ../push-harness.sh.
#
#   cd /root/harness/<sha12>/pro-v620/qwen38-flash-next
#   VMID=123 ./thermal-guard.sh                                    # in another shell first
#   CELLS=runs/<record>.cells ../strata/strata-sweep.sh
#
# A CELLS file holds one cell per line, `LABEL KEY=VALUE ...` with shell-quoted values, run in
# file order (# starts a comment). Keys:
#   MODEL_* / STRATA_*  any key of /etc/<UNIT>.env, written over the env file the
#                  sweep found. An empty STRATA_* value removes that switch, so the engine
#                  never sees it; an empty MODEL_* value is written empty (an empty
#                  MODEL_MTP runs without the draft layer).
#   STREAMS        also run concurrency-probe.py with this many concurrent streams
#   DEPTHS         this cell's probe depths, replacing DEPTHS
#   CT_MEMORY_MIB  CT 123's memory limit for this cell (pct set -memory, live), set back after
#
# Cells run round-robin, PASSES times, every load cold (a fresh engine; the host page cache
# stays). Each load gets one excluded warm-up request, then the probes: Strata's first fresh
# prompt after a start reads slower than the ones after it.
#
# The env file the sweep starts from must equal BASE_ENV at the harness commit (strata-qwen38fn.env
# here, or ../maya/maya-glm53f.env; BASE_ENV_CHECK=false skips that), so a record's base settings
# are in git.
set -Eeuo pipefail

VMID="${VMID:-123}"
UNIT="${UNIT:-strata-qwen38fn}"
PORT="${PORT:-1234}"
PASSES="${PASSES:-3}"
REPS="${REPS:-1}"
N_PREDICT="${N_PREDICT:-256}"
CONC_REPS="${CONC_REPS:-3}"
# Probe depth targets; the filler gives about 0.72 prompt tokens per unit (d8000 is ~5.8k).
DEPTHS="${DEPTHS:-0,8000,32000}"
PROBE_CLASSES="${PROBE_CLASSES:-}"
# Both engines honour the caller's effort: the ones that think may reason. Strata takes
# none/low/medium/high; Maya takes GLM's none/low/high/max.
case "$UNIT" in
  maya-*) ENGINE=maya; EFFORTS="${EFFORTS:-none,low,high,max}"; THINKING_EFFORTS="${THINKING_EFFORTS:-low,high,max}" ;;
  *)      ENGINE=strata; EFFORTS="${EFFORTS:-none,low,medium,high}"; THINKING_EFFORTS="${THINKING_EFFORTS:-low,medium,high}" ;;
esac
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-1800}"
# No cell starts while the hottest DIMM is above this; the BMC caps memory bandwidth at 66 °C.
DIMM_START_MAX_C="${DIMM_START_MAX_C:-58}"
UNPINNED="${UNPINNED:-false}"
BASE_ENV_CHECK="${BASE_ENV_CHECK:-true}"
RESTORE="${RESTORE:-true}"
# thermal-guard.sh writes this on a trip: no further cell starts and the server stays stopped.
TRIP_FILE="${TRIP_FILE:-/root/qwen38-flash-next/THERMAL_TRIP}"
case "$ENGINE" in
  maya) OUT_DIR="${OUT_DIR:-/root/glm53-flash/maya-sweep-$(date -u +%Y%m%dT%H%M%SZ)}" ;;
  *)    OUT_DIR="${OUT_DIR:-/root/qwen38-flash-next/strata-sweep-$(date -u +%Y%m%dT%H%M%SZ)}" ;;
esac
CELLS="${CELLS:-}"

readonly ENVFILE="/etc/${UNIT}.env"
readonly ENGINE_LOG="/var/log/${UNIT}/engine.log"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }
in_ct() { pct exec "$VMID" -- "$@"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
[[ "$UNIT" =~ ^(strata|maya)-[a-z0-9-]+$ ]] || die "UNIT must name a strata-* or maya-* unit"
for v in PASSES REPS N_PREDICT CONC_REPS DIMM_START_MAX_C; do
  [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die "${v} must be a positive whole number"
done
[ -n "$CELLS" ] || die "CELLS must name a cells file"
CELLS="$(readlink -f "$CELLS")"
[ -f "$CELLS" ] || die "CELLS file ${CELLS} not found"
cd "$(dirname "$(readlink -f "$0")")"
case "$ENGINE" in
  maya) BASE_ENV="${BASE_ENV:-../maya/${UNIT}.env}" ;;
  *)    BASE_ENV="${BASE_ENV:-./${UNIT}.env}" ;;
esac
PROBES=../qwen38-flash-next
for f in "$PROBES/placement-probe.py" "$PROBES/concurrency-probe.py" "$PROBES/summarize-sweep.py" \
         ./strata-summary.py ./strata-cell.py ../capture-env.sh; do
  [ -x "$f" ] || die "${f} not found or not executable"
done
[ ! -e "$TRIP_FILE" ] || die "thermal trip recorded in ${TRIP_FILE}; check cooling, then remove it"

HARNESS_COMMIT=""
d="$PWD"
while [ "$d" != "/" ]; do
  if [ -f "$d/HARNESS_COMMIT" ]; then HARNESS_COMMIT="$(head -1 "$d/HARNESS_COMMIT")"; break; fi
  d="$(dirname "$d")"
done
if [ -z "$HARNESS_COMMIT" ]; then
  [ "$UNPINNED" = "true" ] || die "no HARNESS_COMMIT: stage with pro-v620/push-harness.sh, or set UNPINNED=true for a run no record will cite"
  HARNESS_COMMIT="unpinned"
fi

[ "$(pct status "$VMID" | awk '{print $2}')" = "running" ] || die "CT ${VMID} is not running"
in_ct test -f "/etc/systemd/system/${UNIT}.service" || die "CT ${VMID} has no ${UNIT}; run install.sh"
if [ "$BASE_ENV_CHECK" = "true" ]; then
  [ -f "$BASE_ENV" ] || die "no base env file ${BASE_ENV}"
  in_ct cat "$ENVFILE" | cmp -s - "$BASE_ENV" \
    || die "${ENVFILE} in CT ${VMID} differs from ${BASE_ENV} at ${HARNESS_COMMIT:0:12}; run install.sh from this harness, or BASE_ENV_CHECK=false"
fi
mapfile -t CARDS < <(pct config "$VMID" | grep -oE 'pci-0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]-render' \
                     | sed 's/^pci-//; s/-render$//' | sort -u)
[ "${#CARDS[@]}" -ge 1 ] || die "no passed-through GPU in CT ${VMID}'s config"
mkdir -p "$OUT_DIR"
cp "$CELLS" "${OUT_DIR}/cells.txt"

# ---- cells ---------------------------------------------------------------------------
declare -a CELL_ORDER=()
declare -A CELL=()
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
        ok = re.fullmatch(r"(MODEL|STRATA)_[A-Z0-9_]+", key) or key in ("STREAMS", "DEPTHS", "CT_MEMORY_MIB")
        if not eq or not ok or "\t" in value or "\n" in value:
            sys.exit("CELLS line %d: bad setting %r" % (n, word))
        print("S\t%s\t%s\t%s" % (label, key, value))
PY
)" || die "bad CELLS file ${CELLS}"
while IFS=$'\t' read -r kind label key val; do
  if [ "$kind" = L ]; then CELL_ORDER+=("$label"); else CELL[$label|$key]="$val"; fi
done <<<"$parsed"
[ "${#CELL_ORDER[@]}" -ge 1 ] || die "no cells to run"

for label in "${CELL_ORDER[@]}"; do
  bad() { die "cell '${label}': $*"; }
  for key in STREAMS CT_MEMORY_MIB; do
    v="${CELL[$label|$key]:-}"
    [ -z "$v" ] || [[ "$v" =~ ^[1-9][0-9]*$ ]] || bad "${key} must be a positive number"
  done
  v="${CELL[$label|DEPTHS]:-}"
  [ -z "$v" ] || [[ "$v" =~ ^[0-9]+(,[0-9]+)*$ ]] || bad "DEPTHS must be comma-separated numbers"
  # A cell may only name cards the container binds.
  for c in $(tr ',' ' ' <<<"${CELL[$label|MODEL_GPUS]:-}"); do
    printf '%s\n' "${CARDS[@]}" | grep -qx "$c" || bad "MODEL_GPUS names ${c}; CT ${VMID} binds ${CARDS[*]}"
  done
done

CT_IP="$(in_ct hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$CT_IP" ] || die "could not resolve CT ${VMID}'s IP"
BASE="http://${CT_IP}:${PORT}"
log "CT ${VMID} at ${BASE}, cards ${CARDS[*]}, harness ${HARNESS_COMMIT:0:12}; ${#CELL_ORDER[@]} cells x ${PASSES} passes; results -> ${OUT_DIR}"

../capture-env.sh "$VMID" "$UNIT" >"${OUT_DIR}/environment.json" || die "capture-env.sh failed for CT ${VMID}"

vram_mib()       { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_vram_used"  2>/dev/null || echo 0) / 1048576 )); }
vram_total_mib() { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_vram_total" 2>/dev/null || echo 0) / 1048576 )); }
gtt_mib()        { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_gtt_used"   2>/dev/null || echo 0) / 1048576 )); }
ct_mem() {
  local cg="/sys/fs/cgroup/lxc/${VMID}"
  if [ ! -r "${cg}/memory.current" ]; then echo "0 0 0"; return; fi
  awk -v cur="$(cat "${cg}/memory.current")" '$1 == "anon" { a = $2 } $1 == "file" { f = $2 }
    END { printf "%d %d %d\n", cur / 1048576, a / 1048576, f / 1048576 }' "${cg}/memory.stat"
}
# The engine's own memory per card from the kernel's per-client counters, as JSON:
# {pci: {requested, resident, evicted}} in MiB. Requested minus resident is memory the engine
# asked to have in VRAM that sits elsewhere: the spill check, since Strata fills VRAM on
# purpose and a free-VRAM threshold would flag every cell. A counter the kernel did not print
# is left out, so strata-cell.py sees a missing reading, never a zero.
residency() {
  python3 - "${CARDS[@]}" <<'PY'
import glob, json, re, sys
cards = set(sys.argv[1:])
# The kernel prints each size in the largest unit that divides it evenly: a resident size
# that is a whole number of MiB reads `29741 MiB`, not KiB.
UNIT_KIB = {"": 1 / 1024, "KiB": 1, "MiB": 1024, "GiB": 1024 * 1024}
out, kib, seen = {}, {}, set()
for f in glob.glob("/proc/[0-9]*/fdinfo/*"):
    pid = f.split("/")[2]
    try:
        if open("/proc/%s/comm" % pid).read().strip() != "strata":
            continue
        text = open(f).read()
    except OSError:
        continue
    pdev = re.search(r"drm-pdev:\s*(\S+)", text)
    cid = re.search(r"drm-client-id:\s*(\d+)", text)
    if not pdev or pdev.group(1) not in cards or not cid or (pid, cid.group(1)) in seen:
        continue
    seen.add((pid, cid.group(1)))
    r = kib.setdefault(pdev.group(1), {})
    for key, name in (("requested", "amd-requested-vram"), ("resident", "drm-resident-vram"),
                      ("evicted", "amd-evicted-vram")):
        m = re.search(r"^%s:\s*(\d+)[ \t]*([KMG]iB)?[ \t]*$" % name, text, re.M)
        if m:
            r[key] = r.get(key, 0) + int(m.group(1)) * UNIT_KIB[m.group(2) or ""]
for pci, r in kib.items():
    out[pci] = {key: int(v) // 1024 for key, v in r.items()}
print(json.dumps(out))
PY
}

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

ENV_BACKUP="${ENVFILE}.pre-sweep-$(date -u +%Y%m%dT%H%M%SZ)"
in_ct cp -p "$ENVFILE" "$ENV_BACKUP"
WAS_ACTIVE="$(in_ct systemctl is-active "$UNIT" 2>/dev/null || true)"
CT_MEMORY_BEFORE="$(pct config "$VMID" | awk -F': ' '$1 == "memory" {print $2}')"
DIMM_PID=""; GPU_PID=""
cleanup() {
  [ -n "$DIMM_PID" ] && kill "$DIMM_PID" 2>/dev/null
  [ -n "$GPU_PID" ] && kill "$GPU_PID" 2>/dev/null
  [ "$(pct config "$VMID" | awk -F': ' '$1 == "memory" {print $2}')" = "$CT_MEMORY_BEFORE" ] \
    || pct set "$VMID" -memory "$CT_MEMORY_BEFORE" || true
  if [ "$RESTORE" = "true" ]; then
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
  fi
}
trap cleanup EXIT

hottest_dimm() {
  ipmitool sdr type Temperature 2>/dev/null \
    | awk -F'|' '/DDR4/ && $5 ~ /degrees/ {v = $5; gsub(/[^0-9]/, "", v); if (v + 0 > m) m = v + 0} END {print m + 0}'
}
dimm_sampler() {
  while :; do printf '%s\t%s\n' "$(date +%s)" "$(hottest_dimm)"; sleep 10; done
}
# Each second, per card: GPU busy %, VRAM-controller busy %, sclk MHz, power W, junction °C,
# plus the container's cumulative CPU time in µs (placement-sweep.sh's format).
gpu_sampler() {
  local card h cpu
  while :; do
    cpu="$(awk '/^usage_usec/ {print $2}' "/sys/fs/cgroup/lxc/${VMID}/cpu.stat" 2>/dev/null || echo 0)"
    for card in "${CARDS[@]}"; do
      h=""; for h in "/sys/bus/pci/devices/${card}"/hwmon/hwmon*; do break; done
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s.%N)" "$card" \
        "$(cat "/sys/bus/pci/devices/${card}/gpu_busy_percent" 2>/dev/null || echo -1)" \
        "$(cat "/sys/bus/pci/devices/${card}/mem_busy_percent" 2>/dev/null || echo -1)" \
        "$(( $(cat "$h/freq1_input" 2>/dev/null || echo 0) / 1000000 ))" \
        "$(( $(cat "$h/power1_average" 2>/dev/null || echo 0) / 1000000 ))" \
        "$(( $(cat "$h/temp2_input" 2>/dev/null || echo 0) / 1000 ))" "${cpu:-0}"
    done
    sleep 1
  done
}
dimm_cooldown() {
  local t waited=0
  while t="$(hottest_dimm)"; [ "$t" -gt "$DIMM_START_MAX_C" ]; do
    [ "$waited" -gt 0 ] || log "hottest DIMM ${t} °C, above ${DIMM_START_MAX_C} °C: waiting before the next cell"
    sleep 30; waited=$((waited + 30))
  done
  [ "$waited" -eq 0 ] || log "hottest DIMM ${t} °C after ${waited}s"
}

cell_json() {
  local label="$1" key args=()
  for key in "${!CELL[@]}"; do
    [ "${key%%|*}" = "$label" ] && args+=("${key#*|}" "${CELL[$key]}")
  done
  python3 -c 'import json, sys; a = sys.argv[1:]; print(json.dumps(dict(sorted(zip(a[::2], a[1::2])))))' "${args[@]}"
}
cells_json="$(for label in "${CELL_ORDER[@]}"; do printf '%s\t%s\n' "$label" "$(cell_json "$label")"; done \
  | python3 -c 'import json, sys; print(json.dumps([{"label": l.split("\t")[0], "settings": json.loads(l.split("\t")[1])} for l in sys.stdin.read().splitlines()]))')"

python3 - "${OUT_DIR}/manifest.json" "$HARNESS_COMMIT" "$VMID" "${CARDS[*]}" "$UNIT" "$PASSES" "$REPS" \
  "$N_PREDICT" "$CONC_REPS" "$DEPTHS" "$PROBE_CLASSES" "$EFFORTS" "$THINKING_EFFORTS" \
  "$DIMM_START_MAX_C" "$CELLS" "$cells_json" "${OUT_DIR}/environment.json" <<'PY'
import datetime, json, os, sys
(path, commit, vmid, cards, unit, passes, reps, n_predict, conc_reps, depths, classes, efforts,
 thinking, dimm_max, cells_file, cells, env_path) = sys.argv[1:18]
env = json.load(open(env_path))["guest"]
s = env.get("strata") or env.get("maya") or {}
json.dump({
    "when": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "harness_commit": commit, "vmid": int(vmid), "cards": cards, "unit": unit,
    "model": env["env"].get("MODEL_ALIAS"),
    "engine": "%s %s (%s)" % ("Maya" if env.get("maya") else "Strata", s.get("release"),
                              (s.get("built_commit") or "?")[:7]),
    "probe_chat": True, "ctx": env["env"].get("MODEL_CONTEXT_LENGTH"),
    "parallel": env["env"].get("MODEL_PARALLEL"), "reps": int(passes), "probe_reps": int(reps),
    "n_predict": int(n_predict), "conc_reps": int(conc_reps), "depths": depths,
    "probe_classes": classes, "contract_efforts": efforts, "thinking_efforts": thinking,
    "dimm_start_max_c": int(dimm_max), "cells_file": cells_file, "cells": json.loads(cells),
    "host_ram_gib": round(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30),
}, open(path, "w"), indent=1)
PY

# Start one cell's server from the base env plus the cell's keys. Sets LOAD_OK, LOAD_S,
# LOG_OFFSET (the engine log's size before this start, so the cell reads only its own lines)
# and ACTIVE_GPUS (the cell's MODEL_GPUS).
LOAD_OK=false; LOAD_S=0; LOG_OFFSET=0; ACTIVE_GPUS=""
start_server() {
  local label="$1" key val waited=0 card busy t0
  [ ! -e "$TRIP_FILE" ] || die "thermal trip recorded in ${TRIP_FILE}; stopping the sweep"
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
    case "$key" in
      STREAMS | DEPTHS | CT_MEMORY_MIB) ;;
      STRATA_*) if [ -z "$val" ]; then unset_env_var "$key"; else set_env_var "$key" "$val"; fi ;;
      *) set_env_var "$key" "$val" ;;
    esac
  done
  val="${CELL[$label|CT_MEMORY_MIB]:-$CT_MEMORY_BEFORE}"
  if [ "$(pct config "$VMID" | awk -F': ' '$1 == "memory" {print $2}')" != "$val" ]; then
    pct set "$VMID" -memory "$val"
    log "CT ${VMID} memory -> ${val} MiB"
  fi
  # The cards this cell runs on: strata-cell.py expects a residency reading for each.
  # shellcheck disable=SC2016  # expands inside the container
  ACTIVE_GPUS="$(in_ct bash -c 'set -a; . "$1"; printf %s "${MODEL_GPUS:-}"' _ "$ENVFILE")"
  LOG_OFFSET="$(in_ct stat -c %s "$ENGINE_LOG" 2>/dev/null || echo 0)"
  in_ct systemctl start "$UNIT"
  log "waiting for /v1/models (the engine loads its experts into RAM)"
  t0="$(date +%s)"; LOAD_OK=false; LOAD_S=0
  until curl -fsS --max-time 5 "${BASE}/v1/models" 2>/dev/null | grep -q '"id"'; do
    if ! in_ct systemctl is-active --quiet "$UNIT"; then
      log "🔴 ${label}: server exited while loading — cell recorded as failed"
      return 0
    fi
    sleep 1
    if [ $(( $(date +%s) - t0 )) -ge "$HEALTH_TIMEOUT" ]; then
      log "🔴 ${label}: not serving after ${HEALTH_TIMEOUT}s — cell recorded as failed"
      return 0
    fi
  done
  LOAD_OK=true; LOAD_S=$(( $(date +%s) - t0 ))
  log "serving after ${LOAD_S}s"
}

for pass in $(seq 1 "$PASSES"); do
  for label in "${CELL_ORDER[@]}"; do
    tag="${label}-r${pass}"
    log "=== ${tag} $(cell_json "$label") ==="
    dimm_cooldown
    cell_start="$(date +%s)"
    start_server "$label"
    if [ "$LOAD_OK" != true ]; then
      in_ct journalctl -u "$UNIT" --since "@${cell_start}" --no-pager -o cat >"${OUT_DIR}/${tag}.load.log" 2>/dev/null || true
      in_ct tail -c +"$((LOG_OFFSET + 1))" "$ENGINE_LOG" >"${OUT_DIR}/${tag}.engine.log" 2>/dev/null || true
      python3 - "${OUT_DIR}/${tag}.json" "$label" "$(cell_json "$label")" <<'PYFAIL'
import json, sys
path, label, settings = sys.argv[1:4]
json.dump({"error": "load failed", "placement": {"label": label, "cell": json.loads(settings),
           "load_failed": True}}, open(path, "w"), indent=1)
PYFAIL
      continue
    fi

    # The warm-up request, left out of every number.
    curl -fsS --max-time 600 "${BASE}/v1/chat/completions" -H 'Content-Type: application/json' \
      -d '{"messages":[{"role":"user","content":"Name three prime numbers."}],"max_tokens":32,"temperature":0,"strata_checkpoint":false}' \
      >/dev/null 2>&1 || log "warm-up request failed for ${tag}"

    c_used=(); c_gtt=(); c_total=()
    for card in "${CARDS[@]}"; do
      c_used+=("$(vram_mib "$card")"); c_gtt+=("$(gtt_mib "$card")"); c_total+=("$(vram_total_mib "$card")")
    done
    res_load="$(residency)"
    mem="$(ct_mem)"
    log "VRAM ${c_used[*]} MiB of ${c_total[*]} | GTT ${c_gtt[*]} MiB | engine ${res_load} | CT memory ${mem}"

    depths="${CELL[$label|DEPTHS]:-$DEPTHS}"
    probe_args=( "$BASE" --chat --reps "$REPS" --n-predict "$N_PREDICT" --depths "$depths"
                 --contract --efforts "$EFFORTS" --thinking-efforts "$THINKING_EFFORTS" --tool-check )
    [ -n "$PROBE_CLASSES" ] && probe_args+=( --classes "$PROBE_CLASSES" )
    dimm_sampler >"${OUT_DIR}/${tag}.dimm.tsv" 2>/dev/null &
    DIMM_PID=$!
    gpu_sampler >"${OUT_DIR}/${tag}.gpu.tsv" 2>/dev/null &
    GPU_PID=$!
    "$PROBES/placement-probe.py" "${probe_args[@]}" \
      >"${OUT_DIR}/${tag}.json" 2>"${OUT_DIR}/${tag}.rows.jsonl" \
      || log "probe FAILED for ${tag} (row kept, marked)"
    streams="${CELL[$label|STREAMS]:-}"
    conc_span=""
    if [ -n "$streams" ]; then
      conc_span="$(date +%s.%N)"
      "$PROBES/concurrency-probe.py" "$BASE" "$streams" --reps "$CONC_REPS" --n-predict "$N_PREDICT" --chat \
        >"${OUT_DIR}/${tag}.concurrency.json" 2>"${OUT_DIR}/${tag}.concurrency.log" \
        || log "concurrency probe FAILED for ${tag}"
      conc_span="${conc_span} $(date +%s.%N)"
    fi
    kill "$DIMM_PID" "$GPU_PID" 2>/dev/null || true
    wait "$DIMM_PID" "$GPU_PID" 2>/dev/null || true
    DIMM_PID=""; GPU_PID=""

    p_used=(); p_gtt=()
    for card in "${CARDS[@]}"; do p_used+=("$(vram_mib "$card")"); p_gtt+=("$(gtt_mib "$card")"); done
    res_probe="$(residency)"
    log "after the probe: VRAM ${p_used[*]} MiB | GTT ${p_gtt[*]} MiB | engine ${res_probe}"
    in_ct tail -c +"$((LOG_OFFSET + 1))" "$ENGINE_LOG" >"${OUT_DIR}/${tag}.engine.log" 2>/dev/null || true
    in_ct journalctl -u "$UNIT" --since "@${cell_start}" --no-pager -o cat >"${OUT_DIR}/${tag}.server.log" 2>/dev/null || true
    # shellcheck disable=SC2016  # expands inside the container
    cmdline="$(in_ct bash -c 'p=$(pgrep -o -x strata) && tr "\0" " " <"/proc/${p}/cmdline"' 2>/dev/null || true)"
    in_ct systemctl stop "$UNIT" 2>/dev/null || true

    cards_csv="$(printf '%s\n' "${CARDS[@]}" | paste -sd, -)"
    ./strata-cell.py "${OUT_DIR}/${tag}.json" "$label" "$(cell_json "$label")" "$LOAD_S" "$cards_csv" \
      "${c_used[*]}" "${c_gtt[*]}" "${c_total[*]}" "${p_used[*]}" "${p_gtt[*]}" "$res_load" "$res_probe" \
      "$mem" "$cmdline" "${OUT_DIR}/${tag}.dimm.tsv" "${OUT_DIR}/${tag}.gpu.tsv" "${OUT_DIR}/${tag}.rows.jsonl" \
      "${OUT_DIR}/${tag}.concurrency.json" "$conc_span" "${OUT_DIR}/${tag}.engine.log" "$ACTIVE_GPUS"
  done
done

log "sweep complete — ${OUT_DIR}"
{ "$PROBES/summarize-sweep.py" "$OUT_DIR"; echo; ./strata-summary.py "$OUT_DIR"; } | tee "${OUT_DIR}/SUMMARY.md"
