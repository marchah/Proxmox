#!/usr/bin/env bash
# Maya against the long-tasks record's llama.cpp configuration on CT 123, in interleaved rounds:
# each round is a llama.cpp pass (../qwen38-flash-next/placement-sweep.sh, chat mode, GPU 2) and
# then a Maya pass (../strata/strata-sweep.sh, UNIT=maya-glm53f), in CT 123 holding both cards
# throughout. ../glm53-flash/ct123-test-host.sh engine moves the watchdog's map to the engine that
# runs. Both passes run the same probes: chat mode, greedy, 256 tokens, depths 0/8000/32000, every
# load cold. Runs on the Proxmox HOST as root, from a harness staged with ../push-harness.sh, with
# thermal-guard.sh and the residency samplers beside it (the test record has the commands). Ends
# with Maya's unit selected and stopped; a thermal trip stops it where it is.
#
#   ./maya-vs-llamacpp.sh                                 # ROUNDS=3
#   LLAMA_CELLS=... MAYA_CELLS=... ./maya-vs-llamacpp.sh  # other cells files
set -Eeuo pipefail

ROUNDS="${ROUNDS:-3}"
LLAMA_CELLS="${LLAMA_CELLS:-../glm53-flash/runs/2026-10-16-maya-3-llamacpp.cells}"
MAYA_CELLS="${MAYA_CELLS:-../glm53-flash/runs/2026-10-16-maya-3-maya.cells}"
OUT_ROOT="${OUT_ROOT:-/root/glm53-flash/maya-vs-llamacpp-$(date -u +%Y%m%dT%H%M%SZ)}"
TRIP_FILE="${TRIP_FILE:-/root/qwen38-flash-next/THERMAL_TRIP}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }
no_trip() { [ ! -e "$TRIP_FILE" ] || die "thermal trip recorded in ${TRIP_FILE}; check cooling first"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
[[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || die "ROUNDS must be a positive whole number"
cd "$(dirname "$(readlink -f "$0")")"
LLAMA_CELLS="$(readlink -f "$LLAMA_CELLS")"
MAYA_CELLS="$(readlink -f "$MAYA_CELLS")"
[ -f "$LLAMA_CELLS" ] || die "no llama.cpp cells file ${LLAMA_CELLS}"
[ -f "$MAYA_CELLS" ] || die "no Maya cells file ${MAYA_CELLS}"
mkdir -p "$OUT_ROOT"
log "${ROUNDS} rounds; results -> ${OUT_ROOT}"

for round in $(seq 1 "$ROUNDS"); do
  no_trip
  log "round ${round}/${ROUNDS}: llama.cpp"
  (cd ../glm53-flash && TEST_ENGINE=llamacpp ./ct123-test-host.sh engine >/dev/null)
  (cd ../qwen38-flash-next && VMID=123 UNIT=llamacpp-glm53f N_BLOCKS=46 REPS=1 PROBE_CHAT=true \
    CONTRACT_EFFORTS=none,low,high,max CTX=65536 PARALLEL=1 \
    CELLS="$LLAMA_CELLS" OUT_DIR="${OUT_ROOT}/llamacpp-r${round}" ./placement-sweep.sh)
  no_trip
  log "round ${round}/${ROUNDS}: Maya"
  (cd ../glm53-flash && TEST_ENGINE=maya ./ct123-test-host.sh engine >/dev/null)
  (cd ../strata && UNIT=maya-glm53f PASSES=1 CELLS="$MAYA_CELLS" OUT_DIR="${OUT_ROOT}/maya-r${round}" \
    ./strata-sweep.sh)
done
log "done — ${OUT_ROOT}"
