#!/usr/bin/env bash
# Sweep Qwen3.8-Flash-Next placements on CT 120's two V620s and report, per config,
# decode/prefill by prompt class and context depth plus per-card VRAM and GTT.
# Runs on the Proxmox HOST as root, from this directory.
#
#   ./placement-sweep.sh                            # the default matrix
#   NCMOE_LIST="20 28 34" CTX=65536 ./placement-sweep.sh
#   ONE_GPU=true NCMOE_LIST="34 40 48" ./placement-sweep.sh
#
# What it answers: how much VRAM can be handed back to a second model before decode
# degrades unacceptably — i.e. which placement is the most VERSATILE, not just fastest.
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
# 48 MoE layers, ~1.56 GB of Q4 expert weight each, so each +1 hands ~1.56 GB back:
#   15 = minimum that fits two cards · 20 = ~8 GB spare · 28 = ~20 GB spare
#   34 = fits one card · 48 = all experts in RAM (the no-GPU-experts control)
NCMOE_LIST="${NCMOE_LIST:-15 20 28 34 48}"
OUT_DIR="${OUT_DIR:-/root/qwen38-flash-next/sweep-$(date -u +%Y%m%dT%H%M%SZ)}"

readonly GPU1_PCI=0000:03:00.0
readonly GPU2_PCI=0000:83:00.0
readonly CARD_MIB=32768
readonly ENVFILE=/etc/llamacpp-qwen38fn.env

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
[ -x ./placement-probe.py ]   || die "placement-probe.py not found or not executable"
[ -x ./summarize-sweep.py ]   || die "summarize-sweep.py not found or not executable"
mkdir -p "$OUT_DIR"

if [ "$ONE_GPU" = "true" ]; then
  EXPECTED_GPUS=1
  # Confine llama.cpp to one Vulkan device rather than detaching a card: reversible and
  # needs no container restart. Confirm in the unit log that only one device is listed.
  SERVER_EXTRA="--device Vulkan0"
else
  EXPECTED_GPUS=2
  SERVER_EXTRA=""
fi

CT_IP="$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$CT_IP" ] || die "could not resolve CT ${VMID}'s IP"
BASE="http://${CT_IP}:${PORT}"
log "CT ${VMID} at ${BASE}; results -> ${OUT_DIR}"

vram_mib() { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_vram_used" 2>/dev/null || echo 0) / 1048576 )); }
gtt_mib()  { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_gtt_used"  2>/dev/null || echo 0) / 1048576 )); }

# Rewrite one KEY=value in the container's env file, appending if absent.
set_env_var() {
  pct exec "$VMID" -- bash -lc \
    "if grep -q '^${1}=' ${ENVFILE}; then sed -i 's|^${1}=.*|${1}=${2}|' ${ENVFILE}; else printf '%s\n' '${1}=${2}' >> ${ENVFILE}; fi"
}

start_server() {
  local ncmoe="$1"
  pct exec "$VMID" -- systemctl stop llamacpp-qwen38fn 2>/dev/null || true

  # Wait for VRAM to actually drain. Starting the next config on top of the previous
  # one's buffers is how a sweep measures a spill it created itself.
  local waited=0
  while [ "$(vram_mib "$GPU1_PCI")" -gt 2000 ] && [ "$waited" -lt 90 ]; do
    sleep 3; waited=$((waited + 3))
  done

  set_env_var MODEL_CPU_MOE        "$ncmoe"
  # 🔴 Derive the layer split from ncmoe — a FIXED split is wrong for every other value.
  # --n-cpu-moe N makes layers 0..N-1 light (experts on CPU) and N..47 heavy, so an even
  # split by layer COUNT loads the second card with all the heavy ones. Give card 1 the
  # light layers plus half the heavy ones. Measured at ncmoe 20: without this, GPU 2
  # pinned at 30.7 GiB and spilled 9.3 GiB to GTT for 6.6 t/s; with it, 25.7/21.7 GiB,
  # no spill, 11.7 t/s. Override with TENSOR_SPLIT= to sweep the split itself.
  if [ "$EXPECTED_GPUS" -ge 2 ]; then
    if [ -n "${TENSOR_SPLIT:-}" ]; then
      ts="$TENSOR_SPLIT"
    else
      c1=$(( ncmoe + (48 - ncmoe) / 2 ))
      ts="${c1},$(( 48 - c1 ))"
    fi
    set_env_var MODEL_TENSOR_SPLIT "$ts"
    log "tensor-split ${ts} (derived from n_cpu_moe ${ncmoe})"
  else
    set_env_var MODEL_TENSOR_SPLIT ""
  fi
  set_env_var MODEL_LOAD_MODE      "${LOAD_MODE:-}"
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
      die "server exited while loading (n_cpu_moe=${ncmoe}) — see log above"
    fi
    sleep 5; t=$((t + 5))
    [ "$t" -ge "$HEALTH_TIMEOUT" ] && {
      pct exec "$VMID" -- journalctl -u llamacpp-qwen38fn --no-pager -n 40 -o cat >&2
      die "not healthy after ${HEALTH_TIMEOUT}s (n_cpu_moe=${ncmoe})"; }
  done
  log "healthy after ${t}s"
}

cat >"${OUT_DIR}/manifest.json" <<JSON
{
 "when": "$(date -u +%FT%TZ)",
 "ctx": ${CTX}, "parallel": ${PARALLEL}, "reps": ${REPS},
 "n_predict": ${N_PREDICT}, "depths": "${DEPTHS}",
 "one_gpu": ${ONE_GPU}, "expected_gpus": ${EXPECTED_GPUS},
 "load_mode": "${LOAD_MODE}", "tensor_split_override": "${TENSOR_SPLIT}",
 "server_extra": "${SERVER_EXTRA}", "ncmoe_list": "${NCMOE_LIST}",
 "llamacpp_dir": "$(pct exec "$VMID" -- bash -lc "grep -m1 '^LLAMACPP_DIR=' ${ENVFILE} | cut -d= -f2")",
 "host_ram_gib": $(free -g | awk '/^Mem:/{print $2}'),
 "dimms_64gb": $(dmidecode -t memory 2>/dev/null | grep -c 'Size: 64 GB' || true)
}
JSON

# Round-robin, so thermal or cache drift spreads across configs instead of favouring
# whichever ran first.
for round in $(seq 1 "$REPS"); do
  for ncmoe in $NCMOE_LIST; do
    tag="ncmoe${ncmoe}-r${round}"
    log "=== ${tag} (ctx ${CTX}, one_gpu=${ONE_GPU}) ==="
    start_server "$ncmoe"

    v1="$(vram_mib "$GPU1_PCI")"; g1="$(gtt_mib "$GPU1_PCI")"
    v2="$(vram_mib "$GPU2_PCI")"; g2="$(gtt_mib "$GPU2_PCI")"
    log "GPU1 vram=${v1}MiB gtt=${g1}MiB | GPU2 vram=${v2}MiB gtt=${g2}MiB"

    # 🔴 The spill check: under ~1 GiB of headroom on a 32 GiB card RADV silently moves
    # allocations to GTT and decode collapses. Record it as a flag, not a footnote.
    spill=false
    for pair in "${v1}:${g1}" "${v2}:${g2}"; do
      vv="${pair%%:*}"; gg="${pair##*:}"
      if [ "$vv" -gt 1000 ] && [ $(( CARD_MIB - vv )) -lt 1024 ]; then spill=true; fi
      if [ "$gg" -gt 1536 ]; then spill=true; fi
    done
    if [ "$spill" = "true" ]; then log "⚠️  possible GTT spill — treat this row's decode as suspect"; fi

    probe_args=( "$BASE" --reps 1 --n-predict "$N_PREDICT" --depths "$DEPTHS" )
    # The template-contract assertions only need running once per sweep.
    [ "$round" = "1" ] && [ "$ncmoe" = "${NCMOE_LIST%% *}" ] && probe_args+=( --contract )

    ./placement-probe.py "${probe_args[@]}" \
      >"${OUT_DIR}/${tag}.json" 2>"${OUT_DIR}/${tag}.rows.jsonl" \
      || log "probe FAILED for ${tag} (row kept, marked)"

    python3 - "${OUT_DIR}/${tag}.json" "$ncmoe" "$v1" "$g1" "$v2" "$g2" "$spill" <<'PYADD'
import json, pathlib, sys
path, ncmoe, v1, g1, v2, g2, spill = sys.argv[1:8]
p = pathlib.Path(path)
try:
    d = json.loads(p.read_text())
except Exception as e:
    d = {"error": "probe produced no parsable output: %r" % (e,)}
d["placement"] = {
    "n_cpu_moe": int(ncmoe),
    "gpu1_vram_mib": int(v1), "gpu1_gtt_mib": int(g1),
    "gpu2_vram_mib": int(v2), "gpu2_gtt_mib": int(g2),
    "vram_total_mib": int(v1) + int(v2),
    "vram_free_for_a_guest_mib": (32768 - int(v1)) + (32768 - int(v2)),
    "possible_gtt_spill": spill == "true",
}
p.write_text(json.dumps(d, indent=1))
PYADD
  done
done

pct exec "$VMID" -- systemctl stop llamacpp-qwen38fn 2>/dev/null || true
log "sweep complete — ${OUT_DIR}"
./summarize-sweep.py "$OUT_DIR" | tee "${OUT_DIR}/SUMMARY.md"
