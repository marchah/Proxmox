#!/usr/bin/env bash
# Is a GFX offset error-free? Proxmox HOST, root.
#
#   ppl-determinism.sh <ct> <pci> <runs> <offset_mv>...
#   e.g.  ppl-determinism.sh 123 0000:83:00.0 8 -50
#         ppl-determinism.sh 123 0000:83:00.0 1 -100 0 -100 0     # interleaved, 0 mV controls
#
# At 0 mV a perplexity run is bit-reproducible, so it is the reference: one run at 0 mV,
# then <runs> runs at each offset, each compared with the reference on every per-chunk value
# and the final estimate. Any difference is a compute error. Faults and garbage checks miss
# these: −100 mV passed both and still failed this test on both V620s.
#
# The container must hold the card with its model service stopped (the run needs the VRAM).
# A thermal guard for the card runs for the duration. The card is left at 0 mV.
#
# Env (paths inside the container):
#   BIN    llama.cpp release dir        (default /opt/llamacpp/llama-b11505)
#   MODEL  GGUF                         (default /models/hf/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf)
#   WIKI   wikitext-2 wiki.test.raw     (default /tmp/wiki.test.raw)
#   ARGS   llama-perplexity flags       (default: production KV/FA/ubatch)
set -Eeuo pipefail

ct=$1 pci=$2 runs=$3; shift 3
offsets=("$@")
BIN="${BIN:-/opt/llamacpp/llama-b11505}"
MODEL="${MODEL:-/models/hf/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf}"
WIKI="${WIKI:-/tmp/wiki.test.raw}"
ARGS="${ARGS:--fa on -ctk q8_0 -ctv q8_0 -b 2048 -ub 1024}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
OUT="${OUT:-/root/ppl-determinism/$(date -u +%Y%m%dT%H%M%SZ)-${pci}}"
GUARD=ppl-determinism-guard
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
systemd-run --unit="$GUARD" --collect -E CARDS="$pci" -E PATTERNS=llama-perplexity -E LIMIT=100 \
  -E LOG="${OUT}/guard.log" bash "${HERE}/../qwen38-flash-next/thermal-guard.sh" >/dev/null
sleep 2; systemctl is-active --quiet "$GUARD" || { echo "thermal guard did not start" >&2; exit 1; }

# One perplexity run at the current offset, sampling junction and board power each second.
run(){ local label=$1 sampler
  ( while :; do echo "$(cat "${hw}/temp2_input") $(cat "${hw}/power1_average" 2>/dev/null || cat "${hw}/power1_input")"; sleep 1; done ) \
    >"${OUT}/${label}.telemetry" &
  sampler=$!
  # shellcheck disable=SC2086  # ARGS is a flag list
  pct exec "$ct" -- env LD_LIBRARY_PATH="$BIN" VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json \
    "${BIN}/llama-perplexity" -m "$MODEL" -dev Vulkan0 -ngl 99 -t 8 -c 2048 --chunks 40 -f "$WIKI" $ARGS \
    >"${OUT}/${label}.log" 2>&1 || true
  kill "$sampler" 2>/dev/null || true; }

# "<chunks> <final>" from a run's log; a missing final estimate reads as FAILED.
result(){ python3 - "$1" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
chunks = ",".join(v for _, v in re.findall(r"\[(\d+)\]([\d.]+|nan|-?inf)", s))
fin = re.search(r"Final estimate: PPL = ([\d.]+ \+/- [\d.]+)", s)
print(chunks or "none", fin.group(1).replace(" ", "") if fin else "FAILED")
PY
}
thermals(){ awk '{ if ($1 > j) j = $1; if ($2 > p) p = $2 } END { printf "peak %dC %dW", j / 1000, p / 1e6 }' "$1"; }

set_offset 0
run ref
read -r ref_chunks ref_final <<<"$(result "${OUT}/ref.log")"
[ "$ref_final" != FAILED ] || { say "FATAL: the 0 mV reference run failed"; exit 1; }
say "reference 0 mV: final ${ref_final} ($(thermals "${OUT}/ref.telemetry"))"

n=0
for mv in "${offsets[@]}"; do
  set_offset "$mv"; bad=0
  for i in $(seq 1 "$runs"); do
    n=$((n + 1)); label="$(printf '%02d' "$n")-${mv}mV"
    run "$label"
    read -r chunks final <<<"$(result "${OUT}/${label}.log")"
    if [ "$chunks" = "$ref_chunks" ] && [ "$final" = "$ref_final" ]; then verdict=identical
    else
      bad=$((bad + 1))
      verdict="DIFFERS at chunk $(python3 -c 'import sys; a, b = sys.argv[1].split(","), sys.argv[2].split(","); print(next((i + 1 for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)) + 1))' "$ref_chunks" "$chunks")"
    fi
    say "#${n} ${mv} mV run ${i}/${runs}: final ${final} — ${verdict} ($(thermals "${OUT}/${label}.telemetry"))"
  done
  say "${mv} mV: ${bad}/${runs} runs differ from the 0 mV reference"
done
grep -q "THERMAL GUARD" "${OUT}/guard.log" 2>/dev/null && say "WARN the thermal guard tripped during the test"
exit 0
