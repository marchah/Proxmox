#!/usr/bin/env bash
# Sweep Qwen3.8-Flash-Next placements on a container's V620(s) and report, per config,
# decode/prefill by prompt class and context depth plus per-card VRAM and GTT.
# Runs on the Proxmox HOST as root, from this directory.
#
#   ./placement-sweep.sh                            # the default matrix, CT 120
#   NCMOE_LIST="20 28 34" CTX=65536 ./placement-sweep.sh
#   ONE_GPU=true NCMOE_LIST="34 40 48" ./placement-sweep.sh
#   VMID=123 CONFIGS="34 34:auto 40:auto 48:auto" DEPTHS=0,8000 ./placement-sweep.sh
#
# What it answers: how much VRAM can be handed back to a second model before decode
# degrades unacceptably — i.e. which placement is the most VERSATILE, not just fastest.
# With CONFIGS it also measures --moe-cache-mib, a GPU cache for the experts --n-cpu-moe
# keeps in RAM. `N:auto` sizes the cache to the VRAM placement N leaves free after a
# full-ubatch request, minus CACHE_MARGIN_MIB, so every cache cell keeps the same headroom.
#
# ⚠️ Method rules this encodes, each learned the hard way on this box:
#   * INTERLEAVE and take >=3 reps. One rep per cell understated a cost by half here
#     once and flipped a recommendation. Configs run ROUND-ROBIN, not blocked, so drift
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
DEPTHS="${DEPTHS:-0,8000,32000}"
ONE_GPU="${ONE_GPU:-false}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-1800}"
# auto | none | mmap | mlock. llama.cpp warns that CPU tensor overrides + mmap is slower
# and suggests `none`; empty leaves the default.
LOAD_MODE="${LOAD_MODE:-}"
# Override the derived layer split (see start_server). Empty = derive from n_cpu_moe.
TENSOR_SPLIT="${TENSOR_SPLIT:-}"
# llama-server --threads. Empty leaves whatever the env file already has.
# ⚠️ Worth sweeping: STREAM measured 8 threads saturating four channels (80.3 GB/s) and 32
# being WORSE (74.8), and the CPU-side expert FFN is memory-bound GEMV — so the inherited
# --threads 32 may be contention rather than throughput.
THREADS="${THREADS:-}"
# 48 MoE layers, ~1.56 GB of Q4 expert weight each, so each +1 hands ~1.56 GB back:
#   15 = minimum that fits two cards · 20 = ~8 GB spare · 28 = ~20 GB spare
#   34 = fits one card · 48 = all experts in RAM (the no-GPU-experts control)
NCMOE_LIST="${NCMOE_LIST:-15 20 28 34 48}"
# Space-separated NCMOE[:CACHE] entries; CACHE is MiB or `auto`. Defaults to NCMOE_LIST
# with no cache. A cache needs a one-card container: the sizing reads that card.
CONFIGS="${CONFIGS:-$NCMOE_LIST}"
# VRAM an `auto` cache leaves free after a full-ubatch request.
CACHE_MARGIN_MIB="${CACHE_MARGIN_MIB:-1024}"
# llama-server -lv. The cache's size and hit-rate lines are library INFO, which this
# build logs only at 4; any cache config sets 4 for every cell so all pay the same.
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
# Be location-independent: systemd-run and cron do not inherit a working directory, and the
# helper scripts are resolved relative to this one.
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

has_cache=false
for cfg in $CONFIGS; do
  case "$cfg" in
    *:*) has_cache=true ;;
  esac
done
if [ "$has_cache" = "true" ]; then
  [ "${#CARDS[@]}" -eq 1 ] || die "cache configs need a one-card container; CT ${VMID} has ${#CARDS[@]}"
  [ -n "$LOG_VERBOSITY" ] || LOG_VERBOSITY=4
fi

if [ "${CPU_ONLY:-false}" = "true" ]; then
  # Everything on the CPU. The 111.3 GB model fits the container's 160 GiB cap with room for
  # KV and compute buffers. --n-cpu-moe and --tensor-split become meaningless and are cleared.
  EXPECTED_GPUS=0
  SERVER_EXTRA=""
elif [ "$ONE_GPU" = "true" ]; then
  EXPECTED_GPUS=1
  # Confine llama.cpp to one Vulkan device rather than detaching a card: reversible and
  # needs no container restart. Confirm in the unit log that only one device is listed.
  SERVER_EXTRA="--device Vulkan0"
else
  EXPECTED_GPUS=2
  SERVER_EXTRA=""
fi
[ -n "$LOG_VERBOSITY" ] && SERVER_EXTRA="${SERVER_EXTRA:+$SERVER_EXTRA }-lv ${LOG_VERBOSITY}"

CT_IP="$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$CT_IP" ] || die "could not resolve CT ${VMID}'s IP"
BASE="http://${CT_IP}:${PORT}"
log "CT ${VMID} at ${BASE}, cards ${CARDS[*]}, harness ${HARNESS_COMMIT:0:12}; results -> ${OUT_DIR}"

# The environment block a test record pastes, taken before the sweep changes anything.
../capture-env.sh "$VMID" llamacpp-qwen38fn >"${OUT_DIR}/environment.json" \
  || die "capture-env.sh failed for CT ${VMID}"

vram_mib()       { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_vram_used"  2>/dev/null || echo 0) / 1048576 )); }
vram_total_mib() { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_vram_total" 2>/dev/null || echo 0) / 1048576 )); }
gtt_mib()        { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_gtt_used"   2>/dev/null || echo 0) / 1048576 )); }

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
DIMM_PID=""
cleanup() {
  [ -n "$DIMM_PID" ] && kill "$DIMM_PID" 2>/dev/null
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

start_server() {
  local ncmoe="$1" cache="${2:-}"
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

  if [ "${CPU_ONLY:-false}" = "true" ]; then
    set_env_var MODEL_GPU_LAYERS 0
    set_env_var MODEL_CPU_MOE    ""
  else
    set_env_var MODEL_GPU_LAYERS "${GPU_LAYERS:-99}"
    set_env_var MODEL_CPU_MOE    "$ncmoe"
  fi
  set_env_var MODEL_MOE_CACHE_MIB "$cache"
  # 🔴 Derive the split from ncmoe — a FIXED split is wrong for every other value.
  # --n-cpu-moe N makes layers 0..N-1 light (experts on CPU) and N..47 heavy, so an even
  # split by layer COUNT gives card 2 every heavy one: at ncmoe 20 that pinned GPU 2 at
  # 30.7 GiB and spilled 9.3 GiB to GTT for 6.6 t/s.
  # ⚠️ The `- 2` is load-bearing. Card 1 also carries the output head and a larger KV share,
  # which a layer count cannot see, so "light layers + half the heavy ones" overcommits it by
  # ~2 layers and spills anyway — silently, at ncmoe 15/16/20. Validated where the spilling
  # was: 16 -> "30,18" (the deployed config, 14.46 t/s), 20 -> "32,16", 28 -> "36,12". Above
  # that range card 1 has room either way. Override with TENSOR_SPLIT= to sweep the split.
  if [ "${CPU_ONLY:-false}" = "true" ]; then
    set_env_var MODEL_TENSOR_SPLIT ""
  elif [ "$EXPECTED_GPUS" -ge 2 ]; then
    if [ -n "${TENSOR_SPLIT:-}" ]; then
      ts="$TENSOR_SPLIT"
    else
      if [ "$ncmoe" -ge 48 ]; then
        # No heavy layers left to rebalance, so the -2 would hand card 2 two LIGHT layers
        # and an inter-GPU hop for nothing. Keep this case exact so the "*,0" single-GPU
        # detection below still fires.
        c1=48
      else
        c1=$(( ncmoe + (48 - ncmoe) / 2 - 2 ))
        # Defensive clamp; ncmoe >= 5 already makes it unreachable. Written as a full `if`
        # rather than `[ ... ] && c1=1` out of habit, not necessity: that construct is only
        # a `set -e` hazard when it is the LAST command of a FUNCTION (the function then
        # returns 1 and the call site dies). In a loop body or an if-branch like this one it
        # is harmless -- verified, because this repo has previously chased it as the cause of
        # a failure it was not.
      fi
      ts="${c1},$(( 48 - c1 ))"
    fi
    set_env_var MODEL_TENSOR_SPLIT "$ts"
    log "tensor-split ${ts} (derived from n_cpu_moe ${ncmoe})"
    # ⚠️ At n_cpu_moe 48 there are no heavy layers left, so the formula yields "48,0" and
    # card 2 gets NOTHING. That is arguably the right placement — splitting the non-expert
    # layers would only add an inter-GPU hop — but it makes the row effectively
    # SINGLE-GPU, so it must not be read as a two-card data point. Recorded, not silently
    # allowed.
    case "$ts" in
      *,0) log "⚠️  card 2 gets 0 layers — this row is effectively SINGLE-GPU"
           printf '%s\n' "$ncmoe" >>"${OUT_DIR}/.single_gpu_rows" ;;
    esac
  else
    set_env_var MODEL_TENSOR_SPLIT ""
  fi
  set_env_var MODEL_LOAD_MODE      "${LOAD_MODE:-}"
  [ -n "$THREADS" ] && set_env_var MODEL_THREADS "$THREADS"
  [ -n "${BATCH:-}" ]   && set_env_var MODEL_BATCH_SIZE  "$BATCH"
  [ -n "${UBATCH:-}" ]  && set_env_var MODEL_UBATCH_SIZE "$UBATCH"
  # q8_0 KV halves the cache. ⚠️ The KB's "q8_0 breaks thinking termination" warning does NOT
  # apply here: this server runs --reasoning off, which that same note identifies as the
  # provably-lossless case. Output hashes still get compared by the probe.
  [ -n "${KV_TYPE:-}" ] && set_env_var MODEL_KV_TYPE     "$KV_TYPE"
  [ -n "${MMPROJ_CPU:-}" ] && set_env_var MODEL_MMPROJ_ON_CPU "$MMPROJ_CPU"
  # llamacpp-serve-qwen38fn sources the env file under `set -a`, so anything written here is
  # EXPORTED to llama-server. That is how upstream env knobs get through — e.g.
  # LLAMA_PLE_RESIDENT, which appears in llama.cpp #28623's description and is undocumented.
  set_env_var LLAMA_PLE_RESIDENT "${PLE_RESIDENT:-}"
  set_env_var MODEL_CONTEXT_LENGTH "$CTX"
  set_env_var MODEL_PARALLEL       "$PARALLEL"
  set_env_var MODEL_EXPECTED_GPUS  "$EXPECTED_GPUS"
  # This is what actually carries --device into llama-server; the serve script
  # word-splits EXTRA_ARGS and appends it verbatim.
  set_env_var EXTRA_ARGS           "$SERVER_EXTRA"

  pct exec "$VMID" -- systemctl restart llamacpp-qwen38fn

  log "waiting for /health (a 111 GB model is slow to load cold)"
  local t=0
  until curl -fsS --max-time 5 "${BASE}/health" >/dev/null 2>&1; do
    if ! pct exec "$VMID" -- systemctl is-active --quiet llamacpp-qwen38fn; then
      pct exec "$VMID" -- journalctl -u llamacpp-qwen38fn --no-pager -n 40 -o cat >&2
      die "server exited while loading (n_cpu_moe=${ncmoe}, cache=${cache:-none}) — see log above"
    fi
    sleep 5; t=$((t + 5))
    [ "$t" -ge "$HEALTH_TIMEOUT" ] && {
      pct exec "$VMID" -- journalctl -u llamacpp-qwen38fn --no-pager -n 40 -o cat >&2
      die "not healthy after ${HEALTH_TIMEOUT}s (n_cpu_moe=${ncmoe}, cache=${cache:-none})"; }
  done
  log "healthy after ${t}s"
}

# One ~3k-token prompt fills whole 1024-token ubatches. The compute buffer grows past its
# load-time reservation on the first such batch (1,356 -> 1,709 MiB on CT 123 at -ncmoe 34),
# so free VRAM read before it overstates what a cache can take.
warm_request() {
  python3 - "$BASE" <<'PY'
import json, sys, urllib.request
words = ("The council reviewed the harbour budget, the rail timetable and the library plan, "
         "then asked each department for revised figures before the spring session.").split()
prompt = " ".join(words[i % len(words)] for i in range(2400))
body = json.dumps({"messages": [{"role": "user", "content": prompt + "\n\nSummarise in one sentence."}],
                   "max_tokens": 16, "temperature": 0, "cache_prompt": False}).encode()
urllib.request.urlopen(urllib.request.Request(sys.argv[1] + "/v1/chat/completions", body,
                       {"content-type": "application/json"}), timeout=1800).read()
PY
}

# `auto` cache per n_cpu_moe, sized once and reused by every round.
declare -A AUTO_CACHE=()
size_auto_cache() {
  local ncmoe="$1" free cache
  log "=== sizing the auto cache for n_cpu_moe ${ncmoe} ==="
  start_server "$ncmoe" ""
  warm_request
  free=$(( $(vram_total_mib "${CARDS[0]}") - $(vram_mib "${CARDS[0]}") ))
  cache=$(( free - CACHE_MARGIN_MIB ))
  if [ "$cache" -lt 256 ]; then
    log "⚠️  n_cpu_moe ${ncmoe} leaves ${free} MiB free; no room for a cache above the ${CACHE_MARGIN_MIB} MiB margin"
    cache=0
  fi
  AUTO_CACHE[$ncmoe]="$cache"
  log "n_cpu_moe ${ncmoe}: ${free} MiB free after a full ubatch -> cache ${cache} MiB"
  printf '%s %s %s\n' "$ncmoe" "$free" "$cache" >>"${OUT_DIR}/auto-cache.txt"
}

# The hottest DIMM every ~10 s (ipmitool takes ~3 s), as "epoch<TAB>max °C".
dimm_sampler() {
  while :; do
    printf '%s\t%s\n' "$(date +%s)" "$(ipmitool sdr type Temperature 2>/dev/null \
      | awk -F'|' '/DDR4/ && $5 ~ /degrees/ {v = $5; gsub(/[^0-9]/, "", v); if (v + 0 > m) m = v + 0} END {print m + 0}')"
    sleep 10
  done
}

cat >"${OUT_DIR}/manifest.json" <<JSON
{
 "when": "$(date -u +%FT%TZ)",
 "harness_commit": "${HARNESS_COMMIT}",
 "vmid": ${VMID}, "cards": "${CARDS[*]}",
 "ctx": ${CTX}, "parallel": ${PARALLEL}, "reps": ${REPS},
 "n_predict": ${N_PREDICT}, "depths": "${DEPTHS}",
 "one_gpu": ${ONE_GPU}, "expected_gpus": ${EXPECTED_GPUS},
 "load_mode": "${LOAD_MODE}", "tensor_split_override": "${TENSOR_SPLIT}",
 "threads_override": "${THREADS}", "cpu_only": ${CPU_ONLY:-false},
 "batch_override": "${BATCH:-}", "ubatch_override": "${UBATCH:-}",
 "kv_type_override": "${KV_TYPE:-}", "mmproj_cpu": "${MMPROJ_CPU:-}",
 "ple_resident": "${PLE_RESIDENT:-}",
 "server_extra": "${SERVER_EXTRA}", "configs": "${CONFIGS}",
 "cache_margin_mib": ${CACHE_MARGIN_MIB},
 "llamacpp_dir": "$(pct exec "$VMID" -- bash -lc "grep -m1 '^LLAMACPP_DIR=' ${ENVFILE} | cut -d= -f2")",
 "host_ram_gib": $(free -g | awk '/^Mem:/{print $2}'),
 "dimms_64gb": $(dmidecode -t memory 2>/dev/null | grep -c 'Size: 64 GB' || true)
}
JSON

first_cfg="${CONFIGS%% *}"
# Round-robin, so thermal or cache drift spreads across configs instead of favouring
# whichever ran first.
for round in $(seq 1 "$REPS"); do
  for cfg in $CONFIGS; do
    ncmoe="${cfg%%:*}"
    spec=""
    [ "$cfg" != "$ncmoe" ] && spec="${cfg#*:}"
    case "$spec" in
      "")     cache=""; label="ncmoe${ncmoe}" ;;
      auto)   [ -n "${AUTO_CACHE[$ncmoe]:-}" ] || size_auto_cache "$ncmoe"
              cache="${AUTO_CACHE[$ncmoe]}"; label="ncmoe${ncmoe}-cacheauto" ;;
      *[!0-9]*) die "bad cache size '${spec}' in CONFIGS entry '${cfg}' (MiB or auto)" ;;
      *)      cache="$spec"; label="ncmoe${ncmoe}-cache${spec}" ;;
    esac
    tag="${label}-r${round}"
    log "=== ${tag} (ctx ${CTX}, one_gpu=${ONE_GPU}, cache ${cache:-none} MiB) ==="
    cell_start="$(date +%s)"
    start_server "$ncmoe" "$cache"

    c_id=(); c_used=(); c_gtt=(); c_total=()
    for card in "${CARDS[@]}"; do
      c_id+=("$card"); c_used+=("$(vram_mib "$card")"); c_gtt+=("$(gtt_mib "$card")"); c_total+=("$(vram_total_mib "$card")")
    done
    log "VRAM ${c_used[*]} MiB of ${c_total[*]} | GTT ${c_gtt[*]} MiB (${c_id[*]})"
    # shellcheck disable=SC2016  # expands inside the container
    cmdline="$(pct exec "$VMID" -- bash -c 'p=$(pgrep -o -x llama-server) && tr "\0" " " <"/proc/${p}/cmdline"' 2>/dev/null || true)"

    # 🔴 The spill check: under ~1 GiB of headroom RADV silently moves allocations to GTT
    # and decode collapses. Measured against each card's real size: the 30,704 MiB the
    # driver exposes, not the 32 GiB on the box.
    spill=false
    for i in "${!c_id[@]}"; do
      if [ "${c_used[$i]}" -gt 1000 ] && [ $(( c_total[i] - c_used[i] )) -lt 1024 ]; then spill=true; fi
      if [ "${c_gtt[$i]}" -gt 1536 ]; then spill=true; fi
    done
    if [ "$spill" = "true" ]; then log "⚠️  possible GTT spill — treat this row's decode as suspect"; fi

    probe_args=( "$BASE" --reps 1 --n-predict "$N_PREDICT" --depths "$DEPTHS" )
    # The template-contract assertions only need running once per sweep.
    [ "$round" = "1" ] && [ "$cfg" = "$first_cfg" ] && probe_args+=( --contract )

    dimm_sampler >"${OUT_DIR}/${tag}.dimm.tsv" 2>/dev/null &
    DIMM_PID=$!
    ./placement-probe.py "${probe_args[@]}" \
      >"${OUT_DIR}/${tag}.json" 2>"${OUT_DIR}/${tag}.rows.jsonl" \
      || log "probe FAILED for ${tag} (row kept, marked)"
    kill "$DIMM_PID" 2>/dev/null || true
    wait "$DIMM_PID" 2>/dev/null || true
    DIMM_PID=""

    # The cache logs its hit rate when the context is destroyed, so stop the server now
    # and collect this cell's lines.
    pct exec "$VMID" -- systemctl stop llamacpp-qwen38fn 2>/dev/null || true
    pct exec "$VMID" -- journalctl -u llamacpp-qwen38fn --since "@${cell_start}" --no-pager -o cat \
      | grep -E 'moe_cache|MoE cache|layers, .* slots' >"${OUT_DIR}/${tag}.moecache.log" || true

    cards_csv="$(printf '%s\n' "${c_id[@]}" | paste -sd, -)"
    python3 - "${OUT_DIR}/${tag}.json" "$ncmoe" "$spec" "${cache:-0}" "$spill" \
      "$cards_csv" "${c_used[*]}" "${c_gtt[*]}" "${c_total[*]}" \
      "${OUT_DIR}/${tag}.moecache.log" "${OUT_DIR}/${tag}.dimm.tsv" "$cmdline" <<'PYADD'
import json, pathlib, re, sys
(path, ncmoe, spec, cache, spill, cards, vs, gs, ts, cache_log, dimm_log, cmdline) = sys.argv[1:13]
cards = cards.split(",")
vs, gs, ts = ([int(x) for x in s.split()] for s in (vs, gs, ts))
p = pathlib.Path(path)
try:
    d = json.loads(p.read_text())
except Exception as e:
    d = {"error": "probe produced no parsable output: %r" % (e,)}
pl = {
    "n_cpu_moe": int(ncmoe),
    "moe_cache_spec": spec,
    "moe_cache_mib": int(cache),
    "cards": cards,
    "vram_total_mib": sum(vs),
    "vram_free_for_a_guest_mib": sum(t - v for t, v in zip(ts, vs)),
    "possible_gtt_spill": spill == "true",
    "server_cmdline": cmdline.strip() or None,
}
for i, name in enumerate(("gpu1", "gpu2")):
    if i < len(cards):
        pl[name + "_vram_mib"], pl[name + "_gtt_mib"], pl[name + "_card_mib"] = vs[i], gs[i], ts[i]
text = pathlib.Path(cache_log).read_text() if pathlib.Path(cache_log).exists() else ""
mc = {"lines": len(text.splitlines())}
m = re.search(r"MoE cache size =\s*([\d.]+) MiB for ([\d.]+) MiB of host experts", text)
if m:
    mc["size_mib"], mc["host_experts_mib"] = float(m.group(1)), float(m.group(2))
mc["disabled"] = bool(re.search(r"MoE cache is disabled|budget is too small", text))
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
d["placement"] = pl
p.write_text(json.dumps(d, indent=1))
PYADD
  done
done

log "sweep complete — ${OUT_DIR}"
./summarize-sweep.py "$OUT_DIR" | tee "${OUT_DIR}/SUMMARY.md"
