#!/usr/bin/env bash
# Sweep Qwen3.8-Flash-Next server configurations in one container and report, per cell,
# decode/prefill by prompt class and context depth plus per-card VRAM and GTT.
# Runs on the Proxmox HOST as root, from this directory.
#
#   VMID=120 CELLS=runs/<record>.cells ./placement-sweep.sh   # cells defined in a file
#   VMID=123 CONFIGS="34 34:auto 40:auto 48:leave12288" DEPTHS=0,8000 ./placement-sweep.sh
#   NCMOE_LIST="20 28 34" CTX=65536 ./placement-sweep.sh
#
# A CELLS file holds one cell per line, `LABEL KEY=VALUE ...` with shell-quoted values, run in
# file order (# starts a comment). Keys:
#   MODE        2gpu | 1gpu | cpu. Picks the devices (1gpu: --device Vulkan0; cpu: --device
#               none and -ngl 0) and that shape's validated batch: two cards 1024/256, one card
#               and CPU 4096/1024. Unset: every card in the container.
#   NCMOE       --n-cpu-moe (not for cpu)
#   CACHE       --moe-cache-mib: MiB, `auto` (free VRAM under a sizing probe minus
#               CACHE_MARGIN_MIB) or `leaveM` (leaves M MiB free). One GPU only.
#   SPLIT_MODE  layer (default; split derived from NCMOE) | tensor | row, two GPUs only
#   TENSOR_SPLIT, BATCH, UBATCH, THREADS, KV, CTX, PARALLEL, LOAD_MODE, MMPROJ_CPU
#               override the server setting of the same meaning
#   EXTRA       more llama-server arguments
#   STREAMS     also run concurrency-probe.py with this many concurrent streams; set
#               PARALLEL to at least as many slots
#   DEPTHS      this cell's probe depths, replacing the global DEPTHS
#   DEVICE      the Vulkan device a 1gpu cell runs on (default Vulkan0), to compare cards
#               in one container; the cell's JSON records the card it loaded onto
# CONFIGS (NCMOE[:CACHE] entries) is the short form for cells that vary only those two.
#
# ⚠️ Method rules this encodes, each learned the hard way on this box:
#   * INTERLEAVE and take >=3 reps. One rep per cell understated a cost by half here
#     once and flipped a recommendation. Cells run ROUND-ROBIN, not blocked, so drift
#     cannot be mistaken for an effect.
#   * Read GTT alongside VRAM. Below roughly 1 GiB of VRAM headroom RADV spills to GTT —
#     a ~12x decode collapse the startup guard does NOT catch. Flat VRAM can mean the KV
#     moved to host memory, not that it got cheaper.
#   * Gate on output sanity: degenerate repetition is cheap to generate and reads as a
#     win on a tok/s-only sweep. placement-probe.py carries the 8-gram gate.
#   * Read DIMM temperatures beside CPU-offload throughput: the BMC silently caps memory
#     bandwidth to a third while any DIMM reads 66 °C. Each cell records its hottest DIMM.
#   * Run ./thermal-guard.sh alongside. The production watchdog stops the container's
#     *service*; this sweep restarts that service itself, so keep an independent guard.
set -Eeuo pipefail

VMID="${VMID:-120}"
PORT="${PORT:-1234}"
CTX="${CTX:-65536}"
PARALLEL="${PARALLEL:-1}"
REPS="${REPS:-3}"
N_PREDICT="${N_PREDICT:-256}"
# Rounds of concurrent requests per pass in a STREAMS cell. The concurrency probe takes its
# medians from the rounds in which every stream completed.
CONC_REPS="${CONC_REPS:-1}"
# Probe depth targets. The filler tokenizes at about 5.5 characters per token, so a target
# yields ~0.72 as many prompt tokens (d8000 is ~5,800); the summary prints the measured size.
DEPTHS="${DEPTHS:-0,8000,32000}"
# Comma-separated placement-probe classes (code, list, prose); empty runs all three. Decode
# is prompt-dependent, so a record that limits classes quotes decode for those classes only.
PROBE_CLASSES="${PROBE_CLASSES:-}"
ONE_GPU="${ONE_GPU:-false}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-1800}"
# auto | none | mmap | mlock | mmap+mlock | dio. Empty leaves the default (auto).
LOAD_MODE="${LOAD_MODE:-}"
# Drop the host page cache before every load, so each cell loads cold from the NVMe store.
# Host-wide: run it with the other guests shut down.
DROP_CACHES="${DROP_CACHES:-false}"
# Start no cell while the hottest DIMM is above this, so one cell's heat does not carry into
# the next. The BMC silently caps memory bandwidth to a third at 66 °C and its fan curve
# reaches 100% at 58 °C.
DIMM_START_MAX_C="${DIMM_START_MAX_C:-58}"
# Override the derived layer split (see start_server). Empty = derive from n_cpu_moe.
TENSOR_SPLIT="${TENSOR_SPLIT:-}"
# llama-server --threads. Empty leaves whatever the env file already has. The CPU-side
# expert FFN is memory-bound, and STREAM on eight channels peaks at 16 threads.
THREADS="${THREADS:-}"
# 48 MoE layers, ~1.56 GB of Q4 expert weight each, so each +1 hands ~1.56 GB back:
#   15 = minimum that fits two cards · 20 = ~8 GB spare · 28 = ~20 GB spare
#   34 = fits one card · 48 = all experts in RAM (the no-GPU-experts control)
NCMOE_LIST="${NCMOE_LIST:-15 20 28 34 48}"
CONFIGS="${CONFIGS:-$NCMOE_LIST}"
CELLS="${CELLS:-}"
# VRAM an `auto` cache leaves free under a sizing probe.
CACHE_MARGIN_MIB="${CACHE_MARGIN_MIB:-1024}"
# llama-server -lv. The cache's size and hit-rate lines are library INFO, which this
# build logs only at 4; any cache cell sets 4 for every cell so all pay the same.
LOG_VERBOSITY="${LOG_VERBOSITY:-}"
# Put back the container's env file, and the service state, when the sweep ends.
RESTORE="${RESTORE:-true}"
# A run a test record cites must come from ../push-harness.sh, which pins the scripts to a
# commit. UNPINNED=true allows a scratch run from an arbitrary copy.
UNPINNED="${UNPINNED:-false}"
# thermal-guard.sh writes this on a trip. The sweep then starts no further cell and
# leaves the server stopped, as the production watchdog does, until cooling is checked.
TRIP_FILE="${TRIP_FILE:-/root/qwen38-flash-next/THERMAL_TRIP}"
OUT_DIR="${OUT_DIR:-/root/qwen38-flash-next/sweep-$(date -u +%Y%m%dT%H%M%SZ)}"

readonly ENVFILE=/etc/llamacpp-qwen38fn.env

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
case "$DROP_CACHES" in true | false) ;; *) die "DROP_CACHES must be true or false" ;; esac
[[ "$DIMM_START_MAX_C" =~ ^[0-9]+$ ]] || die "DIMM_START_MAX_C must be a whole number of °C"
[[ "$CONC_REPS" =~ ^[1-9][0-9]*$ ]] || die "CONC_REPS must be a whole number of rounds, at least 1"
# Be location-independent: systemd-run and cron do not inherit a working directory, and the
# helper scripts are resolved relative to this one.
[ -z "$CELLS" ] || CELLS="$(readlink -f "$CELLS")"
cd "$(dirname "$(readlink -f "$0")")"
[ -x ./placement-probe.py ]   || die "placement-probe.py not found or not executable"
[ -x ./summarize-sweep.py ]   || die "summarize-sweep.py not found or not executable"
[ -x ../capture-env.sh ]      || die "../capture-env.sh not found or not executable"
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
mkdir -p "$OUT_DIR"

# The cards passed through to this container, from its by-path bind mounts. Reading them
# from the config keeps VRAM readings on the container's own cards: a fixed address read
# CT 120's card while sweeping CT 123.
mapfile -t CARDS < <(pct config "$VMID" | grep -oE 'pci-0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' \
                     | sed 's/^pci-//' | sort -u)
[ "${#CARDS[@]}" -ge 1 ] || die "no passed-through GPU in CT ${VMID}'s config"
if [ "${#CARDS[@]}" -eq 1 ] && [ "${CPU_ONLY:-false}" != "true" ]; then
  ONE_GPU=true
fi

# Devices for cells that set no MODE.
if [ "${CPU_ONLY:-false}" = "true" ]; then
  # Everything on the CPU, with --device none so no op is offloaded to a card either.
  GLOBAL_GPUS=0; GLOBAL_DEVICE_ARG="--device none"
elif [ "$ONE_GPU" = "true" ]; then
  # Confine llama.cpp to one Vulkan device rather than detaching a card: reversible and
  # needs no container restart. Confirm in the unit log that only one device is listed.
  GLOBAL_GPUS=1; GLOBAL_DEVICE_ARG="--device Vulkan0"
else
  GLOBAL_GPUS=2; GLOBAL_DEVICE_ARG=""
fi

# ---- cells ---------------------------------------------------------------------------
declare -a CELL_ORDER=()
declare -A CELL=()
if [ -n "$CELLS" ]; then
  [ -f "$CELLS" ] || die "CELLS file ${CELLS} not found"
  cp "$CELLS" "${OUT_DIR}/cells.txt"
  # Parsed in python: shlex handles the quoting, and a parse error must stop the sweep
  # here, which a process substitution would swallow.
  parsed="$(python3 - "$CELLS" <<'PY'
import re, shlex, sys
KEYS = {"MODE", "NCMOE", "CACHE", "SPLIT_MODE", "TENSOR_SPLIT", "BATCH", "UBATCH", "THREADS",
        "KV", "CTX", "PARALLEL", "LOAD_MODE", "MMPROJ_CPU", "EXTRA", "STREAMS", "DEPTHS",
        "DEVICE"}
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
        if not eq or key not in KEYS or "\t" in value:
            sys.exit("CELLS line %d: bad setting %r" % (n, word))
        print("S\t%s\t%s\t%s" % (label, key, value))
PY
  )" || die "bad CELLS file ${CELLS}"
  while IFS=$'\t' read -r kind label key val; do
    if [ "$kind" = L ]; then CELL_ORDER+=("$label"); CELL[$label|]=1; else CELL[$label|$key]="$val"; fi
  done <<<"$parsed"
else
  for cfg in $CONFIGS; do
    case "$cfg" in *:) die "bad CONFIGS entry '${cfg}': NCMOE[:CACHE], CACHE in MiB, auto or leaveM" ;; esac
    ncmoe="${cfg%%:*}"
    spec=""
    [ "$cfg" != "$ncmoe" ] && spec="${cfg#*:}"
    label="ncmoe${ncmoe}${spec:+-cache${spec}}"
    CELL_ORDER+=("$label"); CELL[$label|]=1; CELL[$label|NCMOE]="$ncmoe"
    [ -n "$spec" ] && CELL[$label|CACHE]="$spec"
  done
fi
[ "${#CELL_ORDER[@]}" -ge 1 ] || die "no cells to run"

cell_gpus() {
  case "${CELL[$1|MODE]:-}" in
    2gpu) echo 2 ;;
    1gpu) echo 1 ;;
    cpu)  echo 0 ;;
    *)    echo "$GLOBAL_GPUS" ;;
  esac
}

# Every cell is checked before the first model load, so a typo fails at once rather than
# after the cells ahead of it have run.
has_cache=false
for label in "${CELL_ORDER[@]}"; do
  bad() { die "cell '${label}': $*"; }
  mode="${CELL[$label|MODE]:-}"; ncmoe="${CELL[$label|NCMOE]:-}"; spec="${CELL[$label|CACHE]:-}"
  case "$mode" in ""|1gpu|2gpu|cpu) ;; *) bad "MODE must be 1gpu, 2gpu or cpu" ;; esac
  if [ "$mode" != cpu ]; then
    [[ "$ncmoe" =~ ^[0-9]+$ ]] || bad "NCMOE must be a number (NCMOE[:CACHE], CACHE in MiB, auto or leaveM)"
  fi
  case "$spec" in
    "" | auto) ;;
    leave*) [[ "${spec#leave}" =~ ^[0-9]+$ ]] || bad "CACHE must be MiB, auto or leaveM" ;;
    *)      [[ "$spec" =~ ^[0-9]+$ ]] || bad "CACHE must be MiB, auto or leaveM" ;;
  esac
  gpus="$(cell_gpus "$label")"
  [ "$gpus" -le "${#CARDS[@]}" ] || bad "needs ${gpus} GPUs; CT ${VMID} has ${#CARDS[@]}"
  if [ -n "$spec" ]; then
    has_cache=true
    [ "$gpus" -eq 1 ] || bad "the MoE cache needs exactly one GPU (it refuses multiple devices)"
  fi
  case "${CELL[$label|SPLIT_MODE]:-}" in
    "" | layer) ;;
    tensor | row) [ "$gpus" -ge 2 ] || bad "SPLIT_MODE ${CELL[$label|SPLIT_MODE]} needs two GPUs" ;;
    *) bad "SPLIT_MODE must be layer, tensor or row" ;;
  esac
  for key in BATCH UBATCH THREADS CTX PARALLEL STREAMS; do
    v="${CELL[$label|$key]:-}"
    [ -z "$v" ] || [[ "$v" =~ ^[0-9]+$ ]] || bad "${key} must be a number"
  done
  v="${CELL[$label|DEPTHS]:-}"
  [ -z "$v" ] || [[ "$v" =~ ^[0-9]+(,[0-9]+)*$ ]] || bad "DEPTHS must be comma-separated numbers"
  v="${CELL[$label|DEVICE]:-}"
  if [ -n "$v" ]; then
    [ "$mode" = 1gpu ] || bad "DEVICE needs MODE=1gpu"
    [[ "$v" =~ ^Vulkan([0-9]+)$ ]] || bad "DEVICE must be VulkanN"
    [ "${BASH_REMATCH[1]}" -lt "${#CARDS[@]}" ] || bad "DEVICE ${v}: CT ${VMID} has ${#CARDS[@]} card(s)"
  fi
  streams="${CELL[$label|STREAMS]:-}"
  if [ -n "$streams" ]; then
    [ "$streams" -le "${CELL[$label|PARALLEL]:-$PARALLEL}" ] || bad "STREAMS ${streams} needs PARALLEL of at least ${streams}"
    [ -x ./concurrency-probe.py ] || bad "STREAMS needs concurrency-probe.py, not found or not executable"
  fi
done
if [ "$has_cache" = "true" ]; then
  [ -n "$LOG_VERBOSITY" ] || LOG_VERBOSITY=4
fi

CT_IP="$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$CT_IP" ] || die "could not resolve CT ${VMID}'s IP"
BASE="http://${CT_IP}:${PORT}"
log "CT ${VMID} at ${BASE}, cards ${CARDS[*]}, harness ${HARNESS_COMMIT:0:12}; ${#CELL_ORDER[@]} cells; results -> ${OUT_DIR}"

# The environment block a test record pastes, taken before the sweep changes anything.
../capture-env.sh "$VMID" llamacpp-qwen38fn >"${OUT_DIR}/environment.json" \
  || die "capture-env.sh failed for CT ${VMID}"

vram_mib()       { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_vram_used"  2>/dev/null || echo 0) / 1048576 )); }
vram_total_mib() { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_vram_total" 2>/dev/null || echo 0) / 1048576 )); }
gtt_mib()        { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_gtt_used"   2>/dev/null || echo 0) / 1048576 )); }
# The container's memory charge in MiB: total, anonymous, page cache. Anonymous memory is
# what the load mode copies into RAM (none, dio). Page cache is charged to whichever cgroup
# first read the file, so an mmap load of files already cached shows little of it.
ct_mem() {
  local cg="/sys/fs/cgroup/lxc/${VMID}"
  if [ ! -r "${cg}/memory.current" ]; then echo "0 0 0"; return; fi
  awk -v cur="$(cat "${cg}/memory.current")" '$1 == "anon" { a = $2 } $1 == "file" { f = $2 }
    END { printf "%d %d %d\n", cur / 1048576, a / 1048576, f / 1048576 }' "${cg}/memory.stat"
}
# The card holding the most VRAM: the one a one-GPU cell loaded onto, whichever VulkanN it is.
active_card() {
  local card best="" most=-1 used
  for card in "${CARDS[@]}"; do
    used="$(vram_mib "$card")"
    if [ "$used" -gt "$most" ]; then most="$used"; best="$card"; fi
  done
  echo "$best"
}

# Rewrite one KEY=value in the container's env file, appending if absent.
#
# 🔴 The value MUST land QUOTED. llamacpp-serve-qwen38fn does
# `set -a; source /etc/llamacpp-qwen38fn.env`, so an unquoted value containing a space is
# parsed as an assignment followed by a COMMAND: writing `EXTRA_ARGS=--device Vulkan0`
# made bash try to run `Vulkan0`, the serve script exited 127, and systemd crash-looped
# the unit while the ONE_GPU control died on its first config.
#
# json.dumps does the quoting and escaping, and the python below contains no single quotes
# so it survives being wrapped in them. sed would need & and | escaped as well, plus
# another shell quoting layer on top — that is what broke the first time.
set_env_var() {
  local key="$1" val="$2"
  pct exec "$VMID" -- python3 -c '
import json, os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
line = key + "=" + json.dumps(val)
src = open(path).read() if os.path.exists(path) else ""
src, n = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", lambda m: line, src)
if not n:
    src = src.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(src)
' "$ENVFILE" "$key" "$val"
}

# The sweep rewrites the production env file, so keep a copy and put it back on exit,
# restarting the service only if it was running before.
ENV_BACKUP="${ENVFILE}.pre-sweep-$(date -u +%Y%m%dT%H%M%SZ)"
pct exec "$VMID" -- cp -p "$ENVFILE" "$ENV_BACKUP"
WAS_ACTIVE="$(pct exec "$VMID" -- systemctl is-active llamacpp-qwen38fn 2>/dev/null || true)"
DIMM_PID=""; GPU_PID=""
cleanup() {
  [ -n "$DIMM_PID" ] && kill "$DIMM_PID" 2>/dev/null
  [ -n "$GPU_PID" ] && kill "$GPU_PID" 2>/dev/null
  if [ "$RESTORE" = "true" ]; then
    pct exec "$VMID" -- cp -p "$ENV_BACKUP" "$ENVFILE"
    if [ -e "$TRIP_FILE" ]; then
      pct exec "$VMID" -- systemctl stop llamacpp-qwen38fn 2>/dev/null || true
      log "restored ${ENVFILE}; thermal trip in ${TRIP_FILE}, so the service stays stopped"
    elif [ "$WAS_ACTIVE" = "active" ]; then
      pct exec "$VMID" -- systemctl restart llamacpp-qwen38fn
      log "restored ${ENVFILE} from ${ENV_BACKUP} and restarted llamacpp-qwen38fn"
    else
      pct exec "$VMID" -- systemctl stop llamacpp-qwen38fn 2>/dev/null || true
      log "restored ${ENVFILE} from ${ENV_BACKUP}; service left stopped, as found"
    fi
  fi
}
trap cleanup EXIT

# Start one cell's server. Sets LOAD_OK (true/false) and LOAD_S; a load failure is recorded
# by the caller and the sweep moves on, so one unloadable cell cannot end a long run.
LOAD_OK=false; LOAD_S=0
start_server() {
  local label="$1" cache="${2:-}"
  [ ! -e "$TRIP_FILE" ] || die "thermal trip recorded in ${TRIP_FILE}; stopping the sweep"
  pct exec "$VMID" -- systemctl stop llamacpp-qwen38fn 2>/dev/null || true

  # Wait for VRAM to actually drain. Starting the next config on top of the previous
  # one's buffers is how a sweep measures a spill it created itself.
  local waited=0 card busy
  while [ "$waited" -lt 90 ]; do
    busy=false
    for card in "${CARDS[@]}"; do
      [ "$(vram_mib "$card")" -gt 2000 ] && busy=true
    done
    [ "$busy" = "false" ] && break
    sleep 3; waited=$((waited + 3))
  done

  local mode gpus ncmoe dev sm ts def_b def_ub v
  mode="${CELL[$label|MODE]:-}"; gpus="$(cell_gpus "$label")"; ncmoe="${CELL[$label|NCMOE]:-}"
  case "$mode" in
    cpu)  dev="--device none";    def_b=4096; def_ub=1024 ;;
    1gpu) dev="--device ${CELL[$label|DEVICE]:-Vulkan0}"; def_b=4096; def_ub=1024 ;;
    2gpu) dev="";                 def_b=1024; def_ub=256 ;;
    *)    dev="$GLOBAL_DEVICE_ARG"; def_b="${BATCH:-}"; def_ub="${UBATCH:-}" ;;
  esac

  if [ "$gpus" -eq 0 ]; then
    set_env_var MODEL_GPU_LAYERS 0
    set_env_var MODEL_CPU_MOE    ""
  else
    set_env_var MODEL_GPU_LAYERS "${GPU_LAYERS:-99}"
    set_env_var MODEL_CPU_MOE    "$ncmoe"
  fi
  set_env_var MODEL_MOE_CACHE_MIB "$cache"
  # 🔴 Derive the layer split from ncmoe — a FIXED split is wrong for every other value.
  # --n-cpu-moe N makes layers 0..N-1 light (experts on CPU) and N..47 heavy, so an even
  # split by layer COUNT gives card 2 every heavy one: at ncmoe 20 that pinned GPU 2 at
  # 30.7 GiB and spilled 9.3 GiB to GTT for 6.6 t/s.
  # ⚠️ The `- 2` is load-bearing. Card 1 also carries the output head and a larger KV share,
  # which a layer count cannot see, so "light layers + half the heavy ones" overcommits it by
  # ~2 layers and spills anyway — silently, at ncmoe 15/16/20. Validated where the spilling
  # was: 16 -> "30,18" (the shipped two-card config), 20 -> "32,16", 28 -> "36,12". Above
  # that range card 1 has room either way. Override with TENSOR_SPLIT= to sweep the split.
  if [ "$gpus" -ge 2 ]; then
    sm="${CELL[$label|SPLIT_MODE]:-layer}"
    ts="${CELL[$label|TENSOR_SPLIT]:-${TENSOR_SPLIT:-}}"
    if [ -z "$ts" ] && [ "$sm" = layer ]; then
      if [ "$ncmoe" -ge 48 ]; then
        # No heavy layers left to rebalance, so the -2 would hand card 2 two LIGHT layers
        # and an inter-GPU hop for nothing. Keep this case exact so the "*,0" single-GPU
        # detection below still fires.
        c1=48
      else
        c1=$(( ncmoe + (48 - ncmoe) / 2 - 2 ))
      fi
      ts="${c1},$(( 48 - c1 ))"
    fi
    set_env_var MODEL_TENSOR_SPLIT "$ts"
    [ "$sm" = layer ] || dev="${dev:+$dev }-sm ${sm}"
    log "split mode ${sm}, tensor-split ${ts:-even}"
    # ⚠️ At n_cpu_moe 48 there are no heavy layers left, so the formula yields "48,0" and
    # card 2 gets NOTHING: an effectively SINGLE-GPU row, not a two-card data point.
    case "$ts" in
      *,0) log "⚠️  card 2 gets 0 layers — this row is effectively SINGLE-GPU"
           printf '%s\n' "$label" >>"${OUT_DIR}/.single_gpu_rows" ;;
    esac
  else
    set_env_var MODEL_TENSOR_SPLIT ""
  fi
  v="${CELL[$label|BATCH]:-$def_b}";  [ -n "$v" ] && set_env_var MODEL_BATCH_SIZE  "$v"
  v="${CELL[$label|UBATCH]:-$def_ub}"; [ -n "$v" ] && set_env_var MODEL_UBATCH_SIZE "$v"
  set_env_var MODEL_LOAD_MODE "${CELL[$label|LOAD_MODE]:-$LOAD_MODE}"
  v="${CELL[$label|THREADS]:-$THREADS}"; [ -n "$v" ] && set_env_var MODEL_THREADS "$v"
  # q8_0 KV halves the cache. ⚠️ The KB's "q8_0 breaks thinking termination" warning does NOT
  # apply here: this server runs --reasoning off, which that same note identifies as the
  # provably-lossless case. Output hashes still get compared by the probe.
  v="${CELL[$label|KV]:-${KV_TYPE:-}}"; [ -n "$v" ] && set_env_var MODEL_KV_TYPE "$v"
  v="${CELL[$label|MMPROJ_CPU]:-${MMPROJ_CPU:-}}"; [ -n "$v" ] && set_env_var MODEL_MMPROJ_ON_CPU "$v"
  # llamacpp-serve-qwen38fn sources the env file under `set -a`, so anything written here is
  # EXPORTED to llama-server. That is how upstream env knobs get through — e.g.
  # LLAMA_PLE_RESIDENT, which appears in llama.cpp #28623's description and is undocumented.
  set_env_var LLAMA_PLE_RESIDENT "${PLE_RESIDENT:-}"
  set_env_var MODEL_CONTEXT_LENGTH "${CELL[$label|CTX]:-$CTX}"
  set_env_var MODEL_PARALLEL       "${CELL[$label|PARALLEL]:-$PARALLEL}"
  set_env_var MODEL_EXPECTED_GPUS  "$gpus"
  # This is what actually carries --device into llama-server; the serve script
  # word-splits EXTRA_ARGS and appends it verbatim.
  v="${CELL[$label|EXTRA]:-}"
  [ -n "$v" ] && dev="${dev:+$dev }${v}"
  [ -n "$LOG_VERBOSITY" ] && dev="${dev:+$dev }-lv ${LOG_VERBOSITY}"
  set_env_var EXTRA_ARGS "$dev"

  if [ "$DROP_CACHES" = "true" ]; then
    # Stop first: pages a running server has mapped are not dropped.
    pct exec "$VMID" -- systemctl stop llamacpp-qwen38fn
    sync; echo 3 >/proc/sys/vm/drop_caches
    log "page cache dropped ($(awk '/^Cached:/ { printf "%d MiB", $2 / 1024 }' /proc/meminfo) left)"
  fi
  pct exec "$VMID" -- systemctl restart llamacpp-qwen38fn

  log "waiting for /health (a 111 GB model is slow to load cold)"
  local t=0 t0
  t0="$(date +%s)"
  LOAD_OK=false; LOAD_S=0
  until curl -fsS --max-time 5 "${BASE}/health" >/dev/null 2>&1; do
    if ! pct exec "$VMID" -- systemctl is-active --quiet llamacpp-qwen38fn; then
      pct exec "$VMID" -- journalctl -u llamacpp-qwen38fn --no-pager -n 40 -o cat >&2
      log "🔴 ${label}: server exited while loading (cache ${cache:-none}) — cell recorded as failed"
      return 0
    fi
    sleep 1; t=$(( $(date +%s) - t0 ))
    if [ "$t" -ge "$HEALTH_TIMEOUT" ]; then
      pct exec "$VMID" -- journalctl -u llamacpp-qwen38fn --no-pager -n 40 -o cat >&2
      log "🔴 ${label}: not healthy after ${HEALTH_TIMEOUT}s — cell recorded as failed"
      return 0
    fi
  done
  t=$(( $(date +%s) - t0 ))
  LOAD_OK=true; LOAD_S="$t"
  log "healthy after ${t}s"
}

# The cell's settings that decide its VRAM, without its cache: cells that share them share
# one sizing measurement.
cell_sig() {
  local key out=""
  for key in MODE NCMOE SPLIT_MODE TENSOR_SPLIT BATCH UBATCH KV CTX PARALLEL MMPROJ_CPU LOAD_MODE EXTRA DEVICE; do
    out+="${key}=${CELL[$1|$key]:-}|"
  done
  echo "$out"
}
# Free VRAM per sizing signature, measured once and reused by every round and by both `auto`
# and `leaveM`. "fail" when the cell's placement does not load.
declare -A AUTO_FREE=()
measure_free() {  # <label> <sig>
  local label="$1" sig="$2" card at_load after
  log "=== sizing the cache for ${label} ==="
  start_server "$label" ""
  if [ "$LOAD_OK" != true ]; then AUTO_FREE[$sig]=fail; return 0; fi
  card="$(active_card)"
  # The lower of free VRAM right after load and after one code prompt at the deepest probed
  # depth. At -ncmoe 34 those read 2,076 and 2,154 MiB; sizing from the second alone loaded
  # the cache cell under the margin. A synthetic 3k request read 2,229.
  at_load=$(( $(vram_total_mib "$card") - $(vram_mib "$card") ))
  ./placement-probe.py "$BASE" --reps 1 --n-predict 64 --classes code \
    --depths "$(tr ',' '\n' <<<"$DEPTHS" | sort -n | tail -1)" >/dev/null 2>&1 \
    || log "sizing probe failed for ${label}"
  after=$(( $(vram_total_mib "$card") - $(vram_mib "$card") ))
  AUTO_FREE[$sig]=$(( at_load < after ? at_load : after ))
  log "${label}: ${at_load} MiB free after load on ${card}, ${after} after the sizing probe"
}
size_auto_cache() {  # <label> <sig> <MiB to leave free>; prints the cache size. measure_free first.
  local label="$1" sig="$2" margin="$3" free cache
  free="${AUTO_FREE[$sig]}"
  cache=$(( free - margin ))
  if [ "$cache" -lt 256 ]; then
    log "⚠️  ${label} leaves ${free} MiB free; no room for a cache that leaves ${margin} MiB" >&2
    cache=0
  fi
  log "${label}: ${free} MiB free under a sizing probe, leave ${margin} -> cache ${cache} MiB" >&2
  printf '%s %s %s %s\n' "$label" "$free" "$margin" "$cache" >>"${OUT_DIR}/auto-cache.txt"
  echo "$cache"
}

# The hottest DIMM every ~10 s (ipmitool takes ~3 s), as "epoch<TAB>max °C".
hottest_dimm() {
  ipmitool sdr type Temperature 2>/dev/null \
    | awk -F'|' '/DDR4/ && $5 ~ /degrees/ {v = $5; gsub(/[^0-9]/, "", v); if (v + 0 > m) m = v + 0} END {print m + 0}'
}
dimm_sampler() {
  while :; do
    printf '%s\t%s\n' "$(date +%s)" "$(hottest_dimm)"
    sleep 10
  done
}
# Each second, per card: GPU busy %, VRAM-controller busy %, sclk MHz, power W, junction °C,
# plus the container's cumulative CPU time in µs. gpu_busy_percent counts any queued work,
# so it reads 99% at a fraction of the power cap; power and clocks show the real load. A
# busy read can fail with EBUSY; it is logged as -1 and left out.
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
# Wait for the DIMMs to cool to DIMM_START_MAX_C. An unreadable BMC reads 0 and does not wait.
dimm_cooldown() {
  local t waited=0
  while t="$(hottest_dimm)"; [ "$t" -gt "$DIMM_START_MAX_C" ]; do
    [ "$waited" -gt 0 ] || log "hottest DIMM ${t} °C, above ${DIMM_START_MAX_C} °C: waiting before the next cell"
    sleep 30; waited=$((waited + 30))
  done
  [ "$waited" -eq 0 ] || log "hottest DIMM ${t} °C after ${waited}s"
}

# A cell's settings as a JSON object, for the manifest and its per-cell JSON.
cell_json() {
  local label="$1" key args=()
  for key in MODE NCMOE CACHE SPLIT_MODE TENSOR_SPLIT BATCH UBATCH THREADS KV CTX PARALLEL LOAD_MODE MMPROJ_CPU EXTRA STREAMS DEPTHS DEVICE; do
    [ -n "${CELL[$label|$key]+x}" ] && args+=("$key" "${CELL[$label|$key]}")
  done
  python3 -c 'import json, sys; a = sys.argv[1:]; print(json.dumps(dict(zip(a[::2], a[1::2]))))' "${args[@]}"
}
cells_json="$(for label in "${CELL_ORDER[@]}"; do printf '%s\t%s\n' "$label" "$(cell_json "$label")"; done \
  | python3 -c 'import json, sys; print(json.dumps([{"label": l.split("\t")[0], "settings": json.loads(l.split("\t")[1])} for l in sys.stdin.read().splitlines()]))')"

cat >"${OUT_DIR}/manifest.json" <<JSON
{
 "when": "$(date -u +%FT%TZ)",
 "harness_commit": "${HARNESS_COMMIT}",
 "vmid": ${VMID}, "cards": "${CARDS[*]}",
 "ctx": ${CTX}, "parallel": ${PARALLEL}, "reps": ${REPS},
 "n_predict": ${N_PREDICT}, "conc_reps": ${CONC_REPS}, "depths": "${DEPTHS}", "probe_classes": "${PROBE_CLASSES}",
 "drop_caches": ${DROP_CACHES}, "dimm_start_max_c": ${DIMM_START_MAX_C},
 "one_gpu": ${ONE_GPU}, "expected_gpus": ${GLOBAL_GPUS},
 "load_mode": "${LOAD_MODE}", "tensor_split_override": "${TENSOR_SPLIT}",
 "threads_override": "${THREADS}", "cpu_only": ${CPU_ONLY:-false},
 "batch_override": "${BATCH:-}", "ubatch_override": "${UBATCH:-}",
 "kv_type_override": "${KV_TYPE:-}", "mmproj_cpu": "${MMPROJ_CPU:-}",
 "ple_resident": "${PLE_RESIDENT:-}",
 "configs": "${CONFIGS}", "cells_file": "${CELLS}", "cells": ${cells_json},
 "log_verbosity": "${LOG_VERBOSITY}", "cache_margin_mib": ${CACHE_MARGIN_MIB},
 "llamacpp_dir": $(python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["guest"]["llamacpp"]["dir"]))' "${OUT_DIR}/environment.json"),
 "host_ram_gib": $(free -g | awk '/^Mem:/{print $2}')
}
JSON

first_label="${CELL_ORDER[0]}"
# Round-robin, so thermal or cache drift spreads across cells instead of favouring
# whichever ran first.
for round in $(seq 1 "$REPS"); do
  for label in "${CELL_ORDER[@]}"; do
    spec="${CELL[$label|CACHE]:-}"
    ncmoe="${CELL[$label|NCMOE]:-}"
    tag="${label}-r${round}"
    case "$spec" in
      "")     cache="" ;;
      auto|leave*)
              # measure_free starts and probes a server, so it runs here, in this shell,
              # where AUTO_FREE persists; size_auto_cache then only does arithmetic.
              sig="$(cell_sig "$label")"
              [ -n "${AUTO_FREE[$sig]:-}" ] || measure_free "$label" "$sig"
              if [ "${AUTO_FREE[$sig]}" = fail ]; then
                cache=fail
              else
                if [ "$spec" = auto ]; then margin="$CACHE_MARGIN_MIB"; else margin="${spec#leave}"; fi
                cache="$(size_auto_cache "$label" "$sig" "$margin")"
              fi ;;
      *)      cache="$spec" ;;
    esac
    log "=== ${tag} (mode ${CELL[$label|MODE]:-default}, n_cpu_moe ${ncmoe:-n/a}, cache ${cache:-none}) ==="
    dimm_cooldown
    cell_start="$(date +%s)"
    if [ "$cache" = fail ]; then
      LOAD_OK=false
    else
      start_server "$label" "$cache"
    fi
    if [ "$LOAD_OK" != true ]; then
      pct exec "$VMID" -- journalctl -u llamacpp-qwen38fn --since "@${cell_start}" --no-pager -o cat \
        >"${OUT_DIR}/${tag}.load.log" 2>/dev/null || true
      python3 - "${OUT_DIR}/${tag}.json" "$label" "$(cell_json "$label")" <<'PYFAIL'
import json, sys
path, label, settings = sys.argv[1:4]
json.dump({"error": "load failed", "placement": {"label": label, "cell": json.loads(settings),
           "load_failed": True}}, open(path, "w"), indent=1)
PYFAIL
      continue
    fi

    c_id=(); c_used=(); c_gtt=(); c_total=()
    for card in "${CARDS[@]}"; do
      c_id+=("$card"); c_used+=("$(vram_mib "$card")"); c_gtt+=("$(gtt_mib "$card")"); c_total+=("$(vram_total_mib "$card")")
    done
    log "VRAM ${c_used[*]} MiB of ${c_total[*]} | GTT ${c_gtt[*]} MiB (${c_id[*]})"
    mem="$(ct_mem)"
    log "CT ${VMID} memory, MiB (total anon file): ${mem}"
    # shellcheck disable=SC2016  # expands inside the container
    cmdline="$(pct exec "$VMID" -- bash -c 'p=$(pgrep -o -x llama-server) && tr "\0" " " <"/proc/${p}/cmdline"' 2>/dev/null || true)"

    # 🔴 The spill check: under ~1 GiB of headroom RADV silently moves allocations to GTT
    # and decode collapses. Measured against each card's real size: the 30,704 MiB the
    # driver exposes, not the 32 GiB on the box.
    spill=false
    for i in "${!c_id[@]}"; do
      if [ "${c_used[$i]}" -gt 1000 ] && [ $(( c_total[i] - c_used[i] )) -lt 1024 ]; then spill=true; fi
      # With none or dio the CPU-resident weights load into pinned host memory, which RADV
      # counts as GTT (52.8 GB at -ncmoe 34). There only GTT that grows under the probe is spill.
      case "${CELL[$label|LOAD_MODE]:-${LOAD_MODE:-auto}}" in
        none | dio) ;;
        *) if [ "${c_gtt[$i]}" -gt 1536 ]; then spill=true; fi ;;
      esac
    done
    if [ "$spill" = "true" ]; then log "⚠️  possible GTT spill — treat this row's decode as suspect"; fi

    probe_args=( "$BASE" --reps 1 --n-predict "$N_PREDICT" --depths "${CELL[$label|DEPTHS]:-$DEPTHS}" )
    [ -n "$PROBE_CLASSES" ] && probe_args+=( --classes "$PROBE_CLASSES" )
    # The template-contract assertions only need running once per sweep.
    [ "$round" = "1" ] && [ "$label" = "$first_label" ] && probe_args+=( --contract )

    dimm_sampler >"${OUT_DIR}/${tag}.dimm.tsv" 2>/dev/null &
    DIMM_PID=$!
    gpu_sampler >"${OUT_DIR}/${tag}.gpu.tsv" 2>/dev/null &
    GPU_PID=$!
    ./placement-probe.py "${probe_args[@]}" \
      >"${OUT_DIR}/${tag}.json" 2>"${OUT_DIR}/${tag}.rows.jsonl" \
      || log "probe FAILED for ${tag} (row kept, marked)"
    streams="${CELL[$label|STREAMS]:-}"
    conc_span=""
    if [ -n "$streams" ]; then
      conc_span="$(date +%s.%N)"
      ./concurrency-probe.py "$BASE" "$streams" --reps "$CONC_REPS" --n-predict "$N_PREDICT" \
        >"${OUT_DIR}/${tag}.concurrency.json" 2>"${OUT_DIR}/${tag}.concurrency.log" \
        || log "concurrency probe FAILED for ${tag}"
      conc_span="${conc_span} $(date +%s.%N)"
    fi
    kill "$DIMM_PID" "$GPU_PID" 2>/dev/null || true
    wait "$DIMM_PID" "$GPU_PID" 2>/dev/null || true
    DIMM_PID=""; GPU_PID=""

    # Read again under the probe's own buffers: a spill shows as GTT that grew while it ran.
    p_used=(); p_gtt=()
    for card in "${CARDS[@]}"; do p_used+=("$(vram_mib "$card")"); p_gtt+=("$(gtt_mib "$card")"); done
    log "after the probe: VRAM ${p_used[*]} MiB | GTT ${p_gtt[*]} MiB"
    for i in "${!c_id[@]}"; do
      if [ $(( p_gtt[i] - c_gtt[i] )) -gt 256 ]; then spill=true; log "⚠️  GTT grew during the probe — possible spill"; fi
    done

    # The cache logs its hit rate when the context is destroyed, so stop the server now
    # and collect this cell's lines.
    pct exec "$VMID" -- systemctl stop llamacpp-qwen38fn 2>/dev/null || true
    pct exec "$VMID" -- journalctl -u llamacpp-qwen38fn --since "@${cell_start}" --no-pager -o cat \
      | grep -E 'moe_cache|MoE cache|layers, .* slots' >"${OUT_DIR}/${tag}.moecache.log" || true

    cards_csv="$(printf '%s\n' "${c_id[@]}" | paste -sd, -)"
    python3 - "${OUT_DIR}/${tag}.json" "$ncmoe" "$spec" "${cache:-0}" "$spill" \
      "$cards_csv" "${c_used[*]}" "${c_gtt[*]}" "${c_total[*]}" \
      "${OUT_DIR}/${tag}.moecache.log" "${OUT_DIR}/${tag}.dimm.tsv" "$cmdline" "${p_used[*]}" "${p_gtt[*]}" \
      "$label" "$(cell_json "$label")" "$(cell_gpus "$label")" "$LOAD_S" "${OUT_DIR}/${tag}.concurrency.json" "$mem" \
      "${OUT_DIR}/${tag}.gpu.tsv" "${OUT_DIR}/${tag}.rows.jsonl" "$conc_span" <<'PYADD'
import json, pathlib, re, statistics, sys
(path, ncmoe, spec, cache, spill, cards, vs, gs, ts, cache_log, dimm_log, cmdline, pvs, pgs,
 label, settings, gpus, load_s, conc_path, mem, gpu_log, rows_log, conc_span) = sys.argv[1:24]
cards = cards.split(",")
vs, gs, ts, pvs, pgs = ([int(x) for x in s.split()] for s in (vs, gs, ts, pvs, pgs))
p = pathlib.Path(path)
try:
    d = json.loads(p.read_text())
except Exception as e:
    d = {"error": "probe produced no parsable output: %r" % (e,)}
pl = {
    "label": label,
    "cell": json.loads(settings),
    "gpus": int(gpus),
    "load_s": int(load_s),
    "n_cpu_moe": int(ncmoe) if ncmoe else None,
    "moe_cache_spec": spec,
    "moe_cache_mib": int(cache),
    "cards": cards,
    "vram_total_mib": sum(vs),
    "vram_free_for_a_guest_mib": sum(t - v for t, v in zip(ts, vs)),
    "possible_gtt_spill": spill == "true",
    "server_cmdline": cmdline.strip() or None,
    "vram_free_after_probe_mib": sum(t - v for t, v in zip(ts, pvs)),
}
pl["ct_mem_mib"], pl["ct_anon_mib"], pl["ct_file_mib"] = (int(x) for x in mem.split())
# The card a one-GPU cell loaded onto: the two V620s are not interchangeable for measurements.
if int(gpus) == 1:
    pl["active_card"] = cards[vs.index(max(vs))]
for i, name in enumerate(("gpu1", "gpu2")):
    if i < len(cards):
        pl[name + "_vram_mib"], pl[name + "_gtt_mib"], pl[name + "_card_mib"] = vs[i], gs[i], ts[i]
        pl[name + "_vram_after_probe_mib"], pl[name + "_gtt_after_probe_mib"] = pvs[i], pgs[i]
text = pathlib.Path(cache_log).read_text() if pathlib.Path(cache_log).exists() else ""
mc = {"lines": len(text.splitlines())}
m = re.search(r"MoE cache size =\s*([\d.]+) MiB for ([\d.]+) MiB of host experts", text)
if m:
    mc["size_mib"], mc["host_experts_mib"] = float(m.group(1)), float(m.group(2))
mc["disabled"] = "MoE cache is disabled" in text
# A budget too small for a layer group leaves those layers uncached; the rest still are.
mc["uncached_layers"] = sum(int(n) for n in re.findall(r"budget is too small for (\d+) layers", text))
for m in re.finditer(r"llama_moe_cache: (ubatch\s*[<>]=?\s*8): hits = (\d+), misses = (\d+), "
                     r"hit rate = ([\d.]+)%, uploaded = ([\d.]+) MiB", text):
    key = "small" if "<" in m.group(1) else "large"
    mc[key] = {"hits": int(m.group(2)), "misses": int(m.group(3)),
               "hit_rate_pct": float(m.group(4)), "uploaded_mib": float(m.group(5))}
pl["moe_cache"] = mc
temps = []
if pathlib.Path(dimm_log).exists():
    for line in pathlib.Path(dimm_log).read_text().splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[1].strip().isdigit() and int(parts[1]) > 0:
            temps.append(int(parts[1]))
pl["dimm_max_c"] = max(temps) if temps else None
pl["dimm_samples"] = len(temps)
# The BMC caps bandwidth to a third at 66 °C and releases near 62-63 °C.
pl["dimm_samples_at_cap"] = sum(1 for t in temps if t >= 66)
conc = pathlib.Path(conc_path)
if conc.exists():
    try:
        c = json.loads(conc.read_text())
        pl["concurrency"] = {k: c.get(k) for k in ("streams", "total_slots", "n_ctx_per_slot",
                             "per_stream_tps", "aggregate_tps", "wall_aggregate_tps",
                             "any_degenerate", "total_failed", "accept_pct",
                             "reps", "complete_rounds")}
    except Exception as e:
        pl["concurrency"] = {"error": "unparsable: %r" % (e,)}
# Utilization per phase. Prefill is each deep request's prompt time, decode its generation
# time, streams the concurrency probe's span; samples are placed by timestamp.
samples = []
if pathlib.Path(gpu_log).exists():
    for line in pathlib.Path(gpu_log).read_text().splitlines():
        f = line.split("\t")
        if len(f) == 8:
            samples.append((float(f[0]), f[1], *(int(x) for x in f[2:8])))
windows = {"prefill": [], "decode": [], "streams": []}
if pathlib.Path(rows_log).exists():
    for line in pathlib.Path(rows_log).read_text().splitlines():
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not (r.get("t0") and r.get("prompt_ms") is not None and r.get("predicted_ms") is not None):
            continue
        a, b = r["t0"], r["t0"] + r["prompt_ms"] / 1000
        if r.get("depth_target"):
            windows["prefill"].append((a, b))
        windows["decode"].append((b, b + r["predicted_ms"] / 1000))
if len(conc_span.split()) == 2:
    windows["streams"].append(tuple(float(x) for x in conc_span.split()))
util = {}
for phase, wins in windows.items():
    inside = [s for s in samples if any(a <= s[0] <= b for a, b in wins)]
    if not inside:
        continue
    u = {"samples": len(inside)}
    # Only the cards holding the model; an idle card's readings are noise.
    held = {c for c, v in zip(cards, vs) if v > 1024}
    for card in sorted({s[1] for s in inside} & held):
        cs = [s for s in inside if s[1] == card]
        busy = [s[2] for s in cs if s[2] >= 0]
        mbusy = [s[3] for s in cs if s[3] >= 0]
        u[card] = {"busy_pct": statistics.median(busy) if busy else None,
                   "mem_busy_pct": statistics.median(mbusy) if mbusy else None,
                   "sclk_mhz": statistics.median(s[4] for s in cs),
                   "power_w": statistics.median(s[5] for s in cs),
                   "junction_max_c": max(s[6] for s in cs)}
    # CPU cores in use: the container's CPU time between consecutive samples of one card.
    first = inside[0][1]
    seq = sorted((s[0], s[7]) for s in samples if s[1] == first)
    rates = [(c2 - c1) / 1e6 / (t2 - t1) for (t1, c1), (t2, c2) in zip(seq, seq[1:])
             if t2 > t1 and any(a <= t2 <= b for a, b in wins)]
    u["cpu_cores"] = round(statistics.median(rates), 1) if rates else None
    util[phase] = u
pl["utilization"] = util
d["placement"] = pl
p.write_text(json.dumps(d, indent=1))
PYADD
  done
done

log "sweep complete — ${OUT_DIR}"
./summarize-sweep.py "$OUT_DIR" | tee "${OUT_DIR}/SUMMARY.md"
