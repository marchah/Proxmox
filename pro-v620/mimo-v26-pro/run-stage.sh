#!/usr/bin/env bash
# Run one stage of the baseline record (runs/2026-10-15-baseline.md) with its samplers.
# Runs on the Proxmox HOST as root, from a harness staged by ../push-harness.sh.
#
#   ./run-stage.sh fit|fit2|mtp|timed
#   WAIT_DOWNLOAD=true SETUP=true ./run-stage.sh fit   # queued: after the download, set up
#                                                      # both cards, then run stage 1
#
# - WAIT_DOWNLOAD=true waits for CT 123's mimo-dl unit to end and needs all 9 files verified.
# - SETUP=true runs TEST_MODEL=mimo TEST_CPUSET=0-47 ct123-test-host.sh two-card first.
# - Starts the thermal guard (left running for the next stage), both cards' residency
#   samplers, the VRAM trace and the page-in sampler; runs the sweep with the stage's
#   settings from the record's Method. On exit it stops the samplers, whatever happened, and
#   writes the page-in summary into the sweep's directory.
# - Refuses to start while any guest other than CT 123 runs, or a thermal trip is recorded.
set -Eeuo pipefail

STAGE="${1:-}"
WAIT_DOWNLOAD="${WAIT_DOWNLOAD:-false}"
SETUP="${SETUP:-false}"

VMID=123
readonly STATE=/root/mimo
readonly CORPUS="${STATE}/corpus-f7e762c53388.txt"
readonly CORPUS_SRC=/root/glm53-flash/corpus-f7e762c53388.txt
readonly CORPUS_SHA=ed17f002764b435c85877bcdf94d1f51cc41ed7acfc9c0152b11113456fb2439
readonly MODEL_DIR=/models/hf/mimo-v2.6-pro-rl
readonly TRIP_FILE=/root/qwen38-flash-next/THERMAL_TRIP
readonly CARDS=(0000:03:00.0 0000:83:00.0)
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
readonly HERE SWEEP_DIR="${HERE}/../qwen38-flash-next"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '%s ==> %s\n' "$(date -u +%FT%TZ)" "$*"; }

# The record's per-stage probe settings (Method table).
case "$STAGE" in
  fit | fit2) REPS=1; DEPTHS=0,8000; CLASSES=prose ;;
  mtp)   REPS=1; DEPTHS=0;      CLASSES= ;;
  timed) REPS=3; DEPTHS=0,8000; CLASSES= ;;
  *) die "usage: run-stage.sh fit|fit2|mtp|timed" ;;
esac
CELLS="${HERE}/runs/2026-10-15-baseline-${STAGE}.cells"

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
[ -f "${HERE}/../../HARNESS_COMMIT" ] || die "not a staged harness; run ../push-harness.sh and use its path"
[ -f "$CELLS" ] || die "no ${CELLS}; commit the stage's cells and stage the harness again"
mkdir -p "$STATE"

if [ "$WAIT_DOWNLOAD" = "true" ]; then
  log "waiting for the download (CT ${VMID}: mimo-dl)"
  while pct exec "$VMID" -- systemctl is-active --quiet mimo-dl; do sleep 60; done
fi
# shellcheck disable=SC2016  # expands inside the container
n="$(pct exec "$VMID" -- bash -c 'ls "$1"/*.verified 2>/dev/null | wc -l' _ "$MODEL_DIR")"
[ "$n" -eq 9 ] || die "${n}/9 model files verified; see: pct exec ${VMID} -- journalctl -u mimo-dl"

others="$( { pct list | awk 'NR > 1 && $2 == "running" {print "CT " $1}'
             qm list | awk 'NR > 1 && $3 == "running" {print "VM " $1}'; } | grep -v "^CT ${VMID}$" || true)"
[ -z "$others" ] || die "other guests are running ($(echo "$others" | paste -sd, -)); the record needs them shut down"
[ ! -e "$TRIP_FILE" ] || die "thermal trip recorded in ${TRIP_FILE}; check cooling, then remove it"

if [ "$SETUP" = "true" ]; then
  log "two-card setup"
  (cd "${HERE}/../glm53-flash" && TEST_MODEL=mimo TEST_CPUSET=0-47 ./ct123-test-host.sh two-card)
fi
grep -q "^GPU_SERVICE_MAP=${CARDS[0]}=${VMID}:llamacpp-mimo,${CARDS[1]}=${VMID}:llamacpp-mimo$" \
  /etc/gpu-thermal-watchdog.env || die "CT ${VMID} is not in the MiMo two-card setup; run with SETUP=true"

if [ ! -f "$CORPUS" ]; then cp "$CORPUS_SRC" "$CORPUS"; fi
[ "$(sha256sum "$CORPUS" | cut -d' ' -f1)" = "$CORPUS_SHA" ] || die "${CORPUS} does not match its SHA-256"

# The guard reads CT 123's cards when it starts, so it starts after the two-card setup.
if ! systemctl is-active --quiet mimo-guard; then
  systemd-run --unit=mimo-guard --collect --setenv=VMID="$VMID" --setenv=UNIT=llamacpp-mimo \
    --setenv=LOG="${STATE}/guard.log" "${SWEEP_DIR}/thermal-guard.sh"
fi

SAMPLERS=(vram-release-trace mimo-pagein)
stop_samplers() { systemctl stop "${SAMPLERS[@]}" 2>/dev/null || true; }
trap stop_samplers EXIT
for pci in "${CARDS[@]}"; do
  unit="vram-residency-${pci:5:2}"
  SAMPLERS+=("$unit")
  systemd-run --unit="$unit" --collect /usr/bin/python3 "${SWEEP_DIR}/vram-residency-sampler.py" \
    --pci "$pci" --output "${STATE}/residency-${STAGE}-${pci:5:2}.jsonl"
done
systemd-run --unit=vram-release-trace --collect "${SWEEP_DIR}/vram-release-trace.sh" \
  "${STATE}/trace-${STAGE}.txt"
systemd-run --unit=mimo-pagein --collect "${HERE}/page-in-sampler.sh" "${STATE}/pagein-${STAGE}.tsv"

OUT_DIR="${STATE}/sweep-${STAGE}-$(date -u +%Y%m%dT%H%M%SZ)"
log "stage ${STAGE}: sweep into ${OUT_DIR}"
rc=0
(cd "$SWEEP_DIR" && VMID="$VMID" UNIT=llamacpp-mimo N_BLOCKS=70 CONTRACT_EFFORTS=none,high \
  PROBE_CHAT=true CTX=65536 PARALLEL=2 CONTEXT_FILE="$CORPUS" REPS="$REPS" DEPTHS="$DEPTHS" \
  PROBE_CLASSES="$CLASSES" CELLS="$CELLS" OUT_DIR="$OUT_DIR" ./placement-sweep.sh) \
  2>&1 | tee "${OUT_DIR}.log" || rc=$?

stop_samplers
if [ -d "$OUT_DIR" ]; then
  "${HERE}/page-in-summary.py" "$OUT_DIR" "${STATE}/pagein-${STAGE}.tsv" \
    | tee "${OUT_DIR}/pagein-summary.tsv" || true
fi
log "stage ${STAGE} ended (sweep exit ${rc})"
exit "$rc"
