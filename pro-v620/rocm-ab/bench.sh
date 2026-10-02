#!/usr/bin/env bash
# One measurement round of one setup. Runs inside CT 123 or the test VM, root.
#
#   bench.sh <setup> <round> <out-dir>
#
# Env:
#   BIN     llama.cpp release directory (Vulkan or ROCm build of the same tag)
#   DEV     backend device: Vulkan0 or ROCm0
#   MODELS  space-separated GGUF paths
#   PCI     the card's PCI address in this environment (default: the only amdgpu card)
#   WIKI    wiki.test.raw, for PPL=1
#   PPL     1 = also run the perplexity correctness gate
#   SMOKE   1 = tiny shapes, to check the pipeline end to end
#   EXPECT_OFFSET_MV  the card's GFX offset this run must find (default 0)
#
# Per model: llama-bench pp512/tg128 at depth 0/8k/32k, then llama-batched-bench at 1/2/4
# parallel sequences, then (PPL=1) perplexity on wikitext-2. Production flags throughout:
# FA on, q8_0 KV, ubatch 1024. Batch is 2048, the largest llama-bench fits next to the
# MoE weights on this card; there is no speculative decoding, so the backend is all that
# varies. GPU telemetry is sampled every second for the whole round.
set -Eeuo pipefail

setup=$1 round=$2 out=$3
: "${BIN:?}" "${DEV:?}" "${MODELS:?}"
mkdir -p "$out"
export LD_LIBRARY_PATH="${BIN}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
# RADV only, as production; no effect on the ROCm build.
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json

say(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "${out}/steps.log"; }
die(){ say "FATAL: $*"; exit 1; }

if [ -n "${PCI:-}" ]; then
  card="/sys/bus/pci/devices/${PCI}"
else
  mapfile -t cards < <(for d in /sys/class/drm/card*/device; do
    [ "$(cat "${d}/vendor" 2>/dev/null)" = 0x1002 ] && [ -d "${d}/hwmon" ] && readlink -f "$d"; done | sort -u)
  [ "${#cards[@]}" -eq 1 ] || die "expected one amdgpu card, found ${#cards[@]}"
  card=${cards[0]}
fi
hw=; for h in "${card}"/hwmon/hwmon*; do [ -d "$h" ] && { hw=$h; break; }; done
[ -n "$hw" ] || die "no hwmon under ${card}"

# The backend must see the V620; otherwise llama.cpp would run on the CPU.
"${BIN}/llama-bench" --list-devices >"${out}/devices.txt" 2>&1 || true
grep -qiE "^ *${DEV}: .*V620" "${out}/devices.txt" || die "${DEV} is not the V620: $(cat "${out}/devices.txt")"

od=$(grep -A1 OD_VDDGFX_OFFSET "${card}/pp_od_clk_voltage" | tail -1)
[ "$od" = "${EXPECT_OFFSET_MV:-0}mV" ] || die "card offset is '${od}', expected ${EXPECT_OFFSET_MV:-0}mV"

python3 - "$out/meta.json" "$setup" "$round" "$BIN" "$DEV" "$card" "$od" <<'PY'
import json, os, platform, subprocess, sys
out, setup, rnd, bin_, dev, card, od = sys.argv[1:]
def sh(c):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception as e: return f"error: {e}"
json.dump({
    "setup": setup, "round": int(rnd), "bin": bin_, "device": dev, "card": card,
    "host": platform.node(), "kernel": platform.release(),
    "amdgpu": sh("cat /sys/module/amdgpu/version 2>/dev/null || echo in-tree"),
    "mesa": sh("dpkg-query -W -f='${Version}' mesa-vulkan-drivers"),
    "rocm": sh("dpkg-query -W -f='${Package}=${Version} ' 'amdrocm10*' 'rocm-core' 2>/dev/null"),
    "llamacpp": sh(f"LD_LIBRARY_PATH={bin_} {bin_}/llama-bench --version 2>&1 | grep -m1 '^version'"),
    "od_vddgfx_offset": od,
    "power_cap_w": int(sh(f"cat {card}/hwmon/hwmon*/power1_cap") or 0) // 1_000_000,
    "devices": open(os.path.join(os.path.dirname(out), "devices.txt")).read(),
}, open(out, "w"), indent=1)
PY

# Raw units, converted by summarize.py: temps m°C, power µW, clocks Hz, VRAM/GTT bytes.
sample(){
  echo "ts,edge,junction,mem,power_avg,power_in,sclk,mclk,busy,vram_used,gtt_used"
  while :; do
    printf '%s' "$(date +%s.%N)"
    for f in "${hw}/temp1_input" "${hw}/temp2_input" "${hw}/temp3_input" "${hw}/power1_average" \
             "${hw}/power1_input" "${hw}/freq1_input" "${hw}/freq2_input" "${card}/gpu_busy_percent" \
             "${card}/mem_info_vram_used" "${card}/mem_info_gtt_used"; do
      printf ',%s' "$(cat "$f" 2>/dev/null)"
    done
    printf '\n'
    sleep 1
  done
}
sample >"${out}/telemetry.csv" &
sampler=$!
trap 'kill "$sampler" 2>/dev/null || true' EXIT

# Start every run from a similar card temperature.
start_c=$(( $(cat "${hw}/temp2_input") / 1000 )); waited=0
while [ "$(( $(cat "${hw}/temp2_input") / 1000 ))" -gt 50 ] && [ "$waited" -lt 180 ]; do sleep 5; waited=$((waited + 5)); done
say "${setup} r${round}: junction ${start_c}C -> $(( $(cat "${hw}/temp2_input") / 1000 ))C after ${waited}s cooldown"

common=(-dev "$DEV" -ngl 99 -t 8 -fa on -ctk q8_0 -ctv q8_0 -b 2048 -ub 1024)
shape=(-p 512 -n 128 -d "0,8192,32768" -r 3); npl=1,2,4
[ "${SMOKE:-0}" = 1 ] && { shape=(-p 64 -n 16 -d "0,512" -r 1); npl=1,2; }
for m in $MODELS; do
  name=$(basename "$m" .gguf)
  say "${setup} r${round} ${name}: llama-bench"
  "${BIN}/llama-bench" -m "$m" "${common[@]}" "${shape[@]}" -o jsonl \
    >"${out}/${name}.bench.jsonl" 2>"${out}/${name}.bench.log"
  say "${setup} r${round} ${name}: llama-batched-bench"
  "${BIN}/llama-batched-bench" -m "$m" "${common[@]}" -c 8192 -npp 512 -ntg 128 -npl "$npl" \
    --output-format jsonl >"${out}/${name}.batched.jsonl" 2>"${out}/${name}.batched.log"
  if [ "${PPL:-0}" = 1 ]; then
    say "${setup} r${round} ${name}: perplexity"
    # A NaN is a result to report, not a reason to lose the round's speed data.
    if "${BIN}/llama-perplexity" -m "$m" "${common[@]}" -c 2048 --chunks 40 -f "${WIKI:?}" \
         >"${out}/${name}.ppl.log" 2>&1; then
      say "${setup} r${round} ${name}: $(grep -m1 "Final estimate" "${out}/${name}.ppl.log")"
    else
      say "${setup} r${round} ${name}: perplexity FAILED: $(tail -1 "${out}/${name}.ppl.log")"
    fi
  fi
done
say "${setup} r${round} done"
