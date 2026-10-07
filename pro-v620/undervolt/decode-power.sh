#!/usr/bin/env bash
# What does a GFX offset save below the 250 W cap? Proxmox HOST, root.
#
#   decode-power.sh <ct> <pci> <rounds> <offset_mv>...
#   e.g.  decode-power.sh 123 0000:83:00.0 2 0 -50 -100
#
# Single-stream decode, where the card runs well under its cap and an undervolt saves power
# rather than buying clock: llama-bench tg1024 at depth 8192, 8 repetitions per run. The
# offsets are interleaved for <rounds> rounds so drift spreads evenly; board power, sclk and
# junction are sampled every second. This measures power only: an offset's correctness
# is ppl-determinism.sh's job.
#
# The container must hold the card with its model service stopped. A thermal guard runs for
# the duration and the card is left at 0 mV. Env: BIN, MODEL as in ppl-determinism.sh.
set -Eeuo pipefail

ct=$1 pci=$2 rounds=$3; shift 3
offsets=("$@")
BIN="${BIN:-/opt/llamacpp/llama-b11475}"
MODEL="${MODEL:-/models/hf/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
OUT="${OUT:-/root/decode-power/$(date -u +%Y%m%dT%H%M%SZ)-${pci}}"
GUARD=decode-power-guard
mkdir -p "$OUT"

say(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "${OUT}/summary.log"; }
set_offset(){ GPU_PCI_ADDRESS="$pci" OFFSET_MV="$1" "${HERE}/gpu-undervolt.sh" apply >/dev/null
  local o; o=$(grep -A1 OD_VDDGFX_OFFSET "/sys/bus/pci/devices/${pci}/pp_od_clk_voltage" | tail -1)
  [ "$o" = "${1}mV" ] || { say "FATAL: ${pci} offset is '${o}', expected ${1}mV"; exit 1; }; }
hw=; for h in "/sys/bus/pci/devices/${pci}"/hwmon/hwmon*; do [ -d "$h" ] && { hw=$h; break; }; done
[ -n "$hw" ] || { echo "no hwmon for ${pci}: is the card on amdgpu?" >&2; exit 1; }

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup(){ systemctl stop "$GUARD" 2>/dev/null || true; set_offset 0 || true; say "card left at 0 mV"; }
trap cleanup EXIT
systemd-run --unit="$GUARD" --collect -E CARDS="$pci" -E PATTERNS=llama-bench -E LIMIT=100 \
  -E LOG="${OUT}/guard.log" bash "${HERE}/../qwen38-flash-next/thermal-guard.sh" >/dev/null
sleep 2; systemctl is-active --quiet "$GUARD" || { echo "thermal guard did not start" >&2; exit 1; }

run(){ local label=$1 sampler w=0
  # Start every run from a similar card temperature.
  while [ "$(( $(cat "${hw}/temp2_input") / 1000 ))" -gt 50 ] && [ "$w" -lt 180 ]; do sleep 5; w=$((w + 5)); done
  ( while :; do echo "$(cat "${hw}/power1_average") $(cat "${hw}/freq1_input") $(cat "${hw}/temp2_input")"; sleep 1; done ) \
    >"${OUT}/${label}.telemetry" &
  sampler=$!
  pct exec "$ct" -- env LD_LIBRARY_PATH="$BIN" VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json \
    "${BIN}/llama-bench" -m "$MODEL" -dev Vulkan0 -ngl 99 -t 8 -fa on -ctk q8_0 -ctv q8_0 -b 2048 -ub 1024 \
    -p 0 -n 1024 -d 8192 -r 8 -o jsonl >"${OUT}/${label}.jsonl" 2>"${OUT}/${label}.log"
  kill "$sampler" 2>/dev/null || true
  # Medians over the run; the brief depth fill is a few samples out of ~120.
  python3 - "${OUT}/${label}.jsonl" "${OUT}/${label}.telemetry" <<'PY'
import json, statistics as st, sys
tps = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])["avg_ts"]
rows = [tuple(map(float, l.split())) for l in open(sys.argv[2]) if len(l.split()) == 3]
p = st.median(r[0] for r in rows) / 1e6; c = st.median(r[1] for r in rows) / 1e6
j = st.median(r[2] for r in rows[-60:]) / 1000
print(f"{tps:.2f} tok/s, {p:.1f} W, {c:.0f} MHz, junction {j:.0f}C")
PY
}

for r in $(seq 1 "$rounds"); do
  for mv in "${offsets[@]}"; do
    set_offset "$mv"
    say "round ${r} ${mv} mV: $(run "r${r}-${mv}mV")"
  done
done
grep -q "THERMAL GUARD" "${OUT}/guard.log" 2>/dev/null && say "WARN the thermal guard tripped during the test"
exit 0
