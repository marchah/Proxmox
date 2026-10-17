#!/usr/bin/env bash
# Strata against the deployed llama.cpp server on CT 123, in interleaved rounds: each round is a
# llama.cpp pass on GPU 2 alone (../qwen38-flash-next/placement-sweep.sh, chat mode) and then a
# Strata pass in CT 123 holding both cards (strata-sweep.sh), switching engines and cards with
# use-engine.sh. Both passes run the same probes: chat mode, greedy, 256 tokens, depths
# 0/8000/32000, every load cold. Runs on the Proxmox HOST as root, from a harness staged with
# ../push-harness.sh, with thermal-guard.sh and the residency samplers beside it (the test record
# has the commands). Ends with Strata serving on GPU 2 alone; a thermal trip stops it where it is.
#
#   ./strata-vs-llamacpp.sh                                   # ROUNDS=3
#   LLAMA_CELLS=... STRATA_CELLS=... ./strata-vs-llamacpp.sh  # other cells files
set -Eeuo pipefail

ROUNDS="${ROUNDS:-3}"
LLAMA_CELLS="${LLAMA_CELLS:-../qwen38-flash-next/runs/2026-10-16-strata-8-llamacpp.cells}"
STRATA_CELLS="${STRATA_CELLS:-../qwen38-flash-next/runs/2026-10-16-strata-8-strata.cells}"
OUT_ROOT="${OUT_ROOT:-/root/qwen38-flash-next/strata-vs-llamacpp-$(date -u +%Y%m%dT%H%M%SZ)}"
TRIP_FILE="${TRIP_FILE:-/root/qwen38-flash-next/THERMAL_TRIP}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }
no_trip() { [ ! -e "$TRIP_FILE" ] || die "thermal trip recorded in ${TRIP_FILE}; check cooling first"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
[[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || die "ROUNDS must be a positive whole number"
cd "$(dirname "$(readlink -f "$0")")"
LLAMA_CELLS="$(readlink -f "$LLAMA_CELLS")"
STRATA_CELLS="$(readlink -f "$STRATA_CELLS")"
[ -f "$LLAMA_CELLS" ] || die "no llama.cpp cells file ${LLAMA_CELLS}"
[ -f "$STRATA_CELLS" ] || die "no Strata cells file ${STRATA_CELLS}"
mkdir -p "$OUT_ROOT"
log "${ROUNDS} rounds; results -> ${OUT_ROOT}"

for round in $(seq 1 "$ROUNDS"); do
  no_trip
  log "round ${round}/${ROUNDS}: llama.cpp"
  ./use-engine.sh llamacpp
  (cd ../qwen38-flash-next && VMID=123 UNIT=llamacpp-qwen38fn REPS=1 PROBE_CHAT=true \
    CELLS="$LLAMA_CELLS" OUT_DIR="${OUT_ROOT}/llamacpp-r${round}" ./placement-sweep.sh)
  no_trip
  log "round ${round}/${ROUNDS}: Strata"
  ./use-engine.sh strata-two-card
  PASSES=1 CELLS="$STRATA_CELLS" OUT_DIR="${OUT_ROOT}/strata-r${round}" ./strata-sweep.sh
done

no_trip
./use-engine.sh strata
log "done — ${OUT_ROOT}"
