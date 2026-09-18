#!/usr/bin/env bash
# STEP 2 of the plan: re-validate placement at FULL CLOCK.
#
# 🔴 Why this is necessary: every placement number measured on 2026-09-17 was taken with the
# governor pinned to `powersave`, i.e. all cores at 1500 MHz against a 3308 MHz maximum. That
# cost ~30% throughput AND blew run-to-run spread out to as much as 36%, so the SHAPE of the
# -ncmoe curve and the (flat) threads result are both unproven. With the governor fixed the
# spread collapses to ~1.4%, which is why 2 samples per cell is now enough where 3 was not.
#
# What is NOT re-tested, deliberately:
#   * --parallel and MTP — both deferred to the end by design; placement is independent of
#     them because --ctx-size is the TOTAL KV budget and --parallel only divides it into
#     slots, so VRAM does not move.
#   * whole-layer -ot (-42%), CPU-only (-59%), --tensor-split (+78%) — all far larger than
#     any plausible noise, so their direction stands.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
CT=120; ENVF=/etc/llamacpp-qwen38fn.env
GOV="${GOV:-performance}"
ROUNDS="${ROUNDS:-2}"
OUT="${OUT:-/root/qwen38-flash-next/reval-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"

ORIG=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
cleanup() { local f; for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$ORIG" >"$f" 2>/dev/null || true; done; }
trap cleanup EXIT
set_gov() { local want="$1" f got; for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$want" >"$f"; done; sleep 2
  got=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor); [ "$got" = "$want" ] || { echo "FATAL: governor '${got}' != '${want}'"; exit 1; }; }

setv() { pct exec "$CT" -- python3 -c '
import json, os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
line = key + "=" + json.dumps(val)
src = open(path).read() if os.path.exists(path) else ""
src, n = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", lambda m: line, src)
if not n: src = src.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(src)' "$ENVF" "$1" "$2"; }

# 🔴 EVERY knob to its production default. Cells then override ONLY what they vary.
# Without this a knob set by one cell leaks into the next and the leak is invisible in the
# results: it has already happened twice here (a cleared --tensor-split silently made a
# whole-layer row spill 8 GiB to GTT, and MODEL_KV_TYPE=q8_0 + MODEL_MMPROJ_ON_CPU=true
# were found still set from an earlier extreme run, inherited by everything after them).
reset_env() {
  setv MODEL_GPU_LAYERS 99; setv MODEL_EXPECTED_GPUS 2
  # 🔴 Must match the split cell() derives. If the baseline differs, the q8_0 arm (which
  # overrides only the KV keys) runs at a DIFFERENT placement from the f16 arm, and the
  # comparison measures the spill instead of the cache type.
  setv MODEL_CPU_MOE 20; setv MODEL_TENSOR_SPLIT "32,16"; setv MODEL_THREADS 32
  setv MODEL_PARALLEL 1; setv MODEL_CONTEXT_LENGTH 65536
  setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"; setv MODEL_LOAD_MODE ""
  setv MODEL_KV_TYPE ""; setv MODEL_MMPROJ_ON_CPU ""
  setv MODEL_BATCH_SIZE 1024; setv MODEL_UBATCH_SIZE 256
  setv EXTRA_ARGS ""; setv LLAMA_PLE_RESIDENT ""
  setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline
}

# busy-core clock: the MEAN is useless here because 32 idle cores at 1500 MHz drag it down
# while the working cores sit at 3300. p90 tracks the cores actually doing the work.
busy_clk() { awk '{print int($1/1000)}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq \
  | sort -n | awk '{v[NR]=$1} END{print v[int(NR*0.9)]}'; }

set_gov "$GOV"
echo "==> governor pinned to ${GOV} for the whole run"

cell() {  # cell <label> <ncmoe> <threads>
  local label="$1" ncmoe="$2" threads="$3" c1 ip t=0
  # Same corrected split as placement-sweep.sh: the naive "light layers + half the heavy
  # ones" leaves card 1 ~2 layers overcommitted and it spills anyway (silently, at ncmoe
  # 15/16/20). Keep these two derivations identical or a revalidation measures a different
  # placement than the sweep it is checking.
  if [ "$ncmoe" -ge 48 ]; then
    c1=48
  else
    c1=$(( ncmoe + (48 - ncmoe) / 2 - 2 ))
    if [ "$c1" -lt 1 ]; then c1=1; fi
  fi
  reset_env
  setv MODEL_CPU_MOE "$ncmoe"; setv MODEL_THREADS "$threads"
  setv MODEL_TENSOR_SPLIT "${c1},$(( 48 - c1 ))"
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
  ip=$(pct exec "$CT" -- hostname -I | awk '{print $1}')
  until curl -fsS -m 4 "http://${ip}:1234/health" >/dev/null 2>&1; do
    pct exec "$CT" -- systemctl is-active --quiet llamacpp-qwen38fn || { echo "    DIED"; return 0; }
    sleep 5; t=$((t+5)); [ "$t" -ge 1200 ] && { echo "    TIMEOUT"; return 0; }
  done
  # warm BOTH depths before measuring: the 8k prefill path and its indexer state are cold
  # otherwise, which made the first arm of the governor test read ~11% low.
  ./placement-probe.py "http://${ip}:1234" --reps 1 --n-predict 64 --depths 0,8000 >/dev/null 2>&1 || true
  ./placement-probe.py "http://${ip}:1234" --reps 1 --n-predict 160 --depths 0,8000 \
    >"${OUT}/${label}.json" 2>/dev/null || true
  local v1 v2
  v1=$(( $(cat /sys/bus/pci/devices/0000:03:00.0/mem_info_vram_used)/1048576 ))
  v2=$(( $(cat /sys/bus/pci/devices/0000:83:00.0/mem_info_vram_used)/1048576 ))
  python3 -c "
import json, statistics as st
d=json.load(open('${OUT}/${label}.json')); s=d.get('summary',{})
a=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d0/')]
b=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d8000/')]
print('    %-22s d0=%6.2f  d8000=%6.2f  vram=%5d MiB  busyclk=%s MHz' % (
  '${label}', st.median(a) if a else 0, st.median(b) if b else 0, $v1+$v2, '$(busy_clk)'))"
}

# The three placement EXTREMES, so the spectrum is complete rather than just its middle:
#   max VRAM        -> -ncmoe 14 plus q8_0 KV and the projector on CPU, which frees ~1.9 GiB
#                      and is the only way 14 fits without spilling to GTT
#   important only  -> -ncmoe 48: attention and the non-expert layers on GPU (9.2 GiB), every
#                      expert in RAM. The whole-layer test showed attention is the part that
#                      MUST stay on the GPU (-42% when moved), so this is the informed minimum.
#   full RAM        -> -ngl 0, both cards free entirely
extreme_maxvram() {  # label
  local label="$1" ip t=0
  reset_env
  setv MODEL_CPU_MOE 14; setv MODEL_TENSOR_SPLIT "31,17"
  # q8_0 KV is safe ONLY because the server runs --reasoning off. The coupling is a hard
  # XOR on this box: `reasoning off + q8_0` or `reasoning low/medium + f16`; mixing gives
  # silent empty replies. Together with the projector on CPU this frees ~1.9 GiB, which is
  # the only way -ncmoe 14 fits two cards without spilling to GTT.
  setv MODEL_KV_TYPE q8_0; setv MODEL_MMPROJ_ON_CPU true
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
  ip=$(pct exec "$CT" -- hostname -I | awk '{print $1}')
  until curl -fsS -m 4 "http://${ip}:1234/health" >/dev/null 2>&1; do
    pct exec "$CT" -- systemctl is-active --quiet llamacpp-qwen38fn || { echo "    DIED (likely OOM/spill at ncmoe 14)"; setv MODEL_KV_TYPE ""; setv MODEL_MMPROJ_ON_CPU ""; return 0; }
    sleep 5; t=$((t+5)); [ "$t" -ge 1200 ] && { echo "    TIMEOUT"; setv MODEL_KV_TYPE ""; setv MODEL_MMPROJ_ON_CPU ""; return 0; }
  done
  ./placement-probe.py "http://${ip}:1234" --reps 1 --n-predict 64 --depths 0,8000 >/dev/null 2>&1 || true
  ./placement-probe.py "http://${ip}:1234" --reps 1 --n-predict 160 --depths 0,8000 >"${OUT}/${label}.json" 2>/dev/null || true
  local v1 v2 g1 g2
  v1=$(( $(cat /sys/bus/pci/devices/0000:03:00.0/mem_info_vram_used)/1048576 )); g1=$(( $(cat /sys/bus/pci/devices/0000:03:00.0/mem_info_gtt_used)/1048576 ))
  v2=$(( $(cat /sys/bus/pci/devices/0000:83:00.0/mem_info_vram_used)/1048576 )); g2=$(( $(cat /sys/bus/pci/devices/0000:83:00.0/mem_info_gtt_used)/1048576 ))
  python3 -c "
import json, statistics as st
d=json.load(open('${OUT}/${label}.json')); s=d.get('summary',{})
a=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d0/')]
b=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d8000/')]
print('    %-22s d0=%6.2f  d8000=%6.2f  vram=%5d MiB  gtt=%d MiB' % (
  '${label}', st.median(a) if a else 0, st.median(b) if b else 0, $v1+$v2, max($g1,$g2)))"
  setv MODEL_KV_TYPE ""; setv MODEL_MMPROJ_ON_CPU ""
}

extreme_cpuonly() {  # label <threads>
  local label="$1" threads="$2" ip t=0
  reset_env
  setv MODEL_GPU_LAYERS 0; setv MODEL_EXPECTED_GPUS 0
  setv MODEL_CPU_MOE ""; setv MODEL_TENSOR_SPLIT ""
  setv MODEL_THREADS "$threads"
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
  ip=$(pct exec "$CT" -- hostname -I | awk '{print $1}')
  until curl -fsS -m 4 "http://${ip}:1234/health" >/dev/null 2>&1; do
    pct exec "$CT" -- systemctl is-active --quiet llamacpp-qwen38fn || { echo "    DIED"; return 0; }
    sleep 5; t=$((t+5)); [ "$t" -ge 1800 ] && { echo "    TIMEOUT"; return 0; }
  done
  ./placement-probe.py "http://${ip}:1234" --reps 1 --n-predict 64 --depths 0,8000 >/dev/null 2>&1 || true
  ./placement-probe.py "http://${ip}:1234" --reps 1 --n-predict 160 --depths 0,8000 >"${OUT}/${label}.json" 2>/dev/null || true
  local v1 v2
  v1=$(( $(cat /sys/bus/pci/devices/0000:03:00.0/mem_info_vram_used)/1048576 ))
  v2=$(( $(cat /sys/bus/pci/devices/0000:83:00.0/mem_info_vram_used)/1048576 ))
  python3 -c "
import json, statistics as st
d=json.load(open('${OUT}/${label}.json')); s=d.get('summary',{})
a=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d0/')]
b=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d8000/')]
print('    %-22s d0=%6.2f  d8000=%6.2f  vram=%5d MiB (both cards FREE)' % (
  '${label}', st.median(a) if a else 0, st.median(b) if b else 0, $v1+$v2))"
}

# Price q8_0 KV + projector-on-CPU on its own, at the incumbent -ncmoe, so the ~1.9 GiB it
# frees can be judged against its throughput cost rather than bundled into the -ncmoe 14
# extreme. Safe here only because the server runs --reasoning off (hard XOR on this box).
cell_frugal_kv() {  # label
  local label="$1" ip t=0
  reset_env
  setv MODEL_KV_TYPE q8_0; setv MODEL_MMPROJ_ON_CPU true
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
  ip=$(pct exec "$CT" -- hostname -I | awk '{print $1}')
  until curl -fsS -m 4 "http://${ip}:1234/health" >/dev/null 2>&1; do
    pct exec "$CT" -- systemctl is-active --quiet llamacpp-qwen38fn || { echo "    DIED"; return 0; }
    sleep 5; t=$((t+5)); [ "$t" -ge 1200 ] && { echo "    TIMEOUT"; return 0; }
  done
  ./placement-probe.py "http://${ip}:1234" --reps 1 --n-predict 64 --depths 0,8000 >/dev/null 2>&1 || true
  ./placement-probe.py "http://${ip}:1234" --reps 1 --n-predict 160 --depths 0,8000 >"${OUT}/${label}.json" 2>/dev/null || true
  local v1 v2
  v1=$(( $(cat /sys/bus/pci/devices/0000:03:00.0/mem_info_vram_used)/1048576 ))
  v2=$(( $(cat /sys/bus/pci/devices/0000:83:00.0/mem_info_vram_used)/1048576 ))
  python3 -c "
import json, statistics as st
d=json.load(open('${OUT}/${label}.json')); s=d.get('summary',{})
a=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d0/')]
b=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d8000/')]
print('    %-22s d0=%6.2f  d8000=%6.2f  vram=%5d MiB (q8_0 KV + mmproj on CPU)' % (
  '${label}', st.median(a) if a else 0, st.median(b) if b else 0, $v1+$v2))"
}

for r in $(seq 1 "$ROUNDS"); do
  echo "======== round ${r} : -ncmoe curve at threads 32 ========"
  for n in 15 20 28 34 48; do cell "ncmoe${n}-t32-r${r}" "$n" 32; done
  echo "======== round ${r} : threads at the incumbent -ncmoe 20 ========"
  for th in 8 16; do cell "ncmoe20-t${th}-r${r}" 20 "$th"; done
  echo "======== round ${r} : VRAM-frugal KV at the incumbent ========"
  cell_frugal_kv "ncmoe20-q8kv-mmprojcpu-r${r}"
  echo "======== round ${r} : the placement EXTREMES ========"
  extreme_maxvram "maxvram-ncmoe14-q8kv-r${r}"
  extreme_cpuonly "cpuonly-t16-r${r}" 16
  extreme_cpuonly "cpuonly-t32-r${r}" 32
done

# A third pass, but only where it changes a decision: the top three configs by median.
# Rigor aimed at the ranking rather than spread evenly over 11 cells that are already
# separated by far more than the ~1.4% run-to-run spread at full clock.
echo "======== confirmation pass: top 3 configs, 2 more samples each ========"
mapfile -t TOP < <(python3 - "$OUT" <<'PYT'
import glob, json, os, re, statistics as st, sys
agg = {}
for f in glob.glob(os.path.join(sys.argv[1], "ncmoe*-t*-r*.json")):
    m = re.match(r"ncmoe(\d+)-t(\d+)-r\d+\.json$", os.path.basename(f))
    if not m:
        continue
    try:
        su = json.load(open(f)).get("summary", {})
    except Exception:
        continue
    a = [v["decode_tps_median"] for k, v in su.items()
         if k.startswith("d0/") and v.get("decode_tps_median")]
    if a:
        agg.setdefault((int(m.group(1)), int(m.group(2))), []).append(st.median(a))
for (n, t), vals in sorted(agg.items(), key=lambda kv: -st.median(kv[1]))[:3]:
    print("%d %d" % (n, t))
PYT
)
for pair in "${TOP[@]}"; do
  read -r n t <<<"$pair"
  for c in 1 2; do cell "ncmoe${n}-t${t}-r$((ROUNDS + c))" "$n" "$t"; done
done

echo
echo "======== RE-VALIDATED AT FULL CLOCK ========"
python3 - "$OUT" <<'PYS'
import glob, json, os, re, statistics as st, sys
base = sys.argv[1]
agg = {}
for f in sorted(glob.glob(os.path.join(base, "*.json"))):
    # Every label, not just the -ncmoe curve: the three EXTREMES have to appear in the
    # same table or the spectrum reads as if only its middle was measured.
    m = re.match(r"(.+)-r\d+\.json$", os.path.basename(f))
    if not m: continue
    try: s = json.load(open(f)).get("summary", {})
    except Exception: continue
    a = [v["decode_tps_median"] for k, v in s.items() if k.startswith("d0/")]
    b = [v["decode_tps_median"] for k, v in s.items() if k.startswith("d8000/")]
    if a: agg.setdefault(m.group(1), ([], []))[0].append(st.median(a))
    if b: agg.setdefault(m.group(1), ([], []))[1].append(st.median(b))
print("  %-26s %8s %8s %9s   n" % ("config", "d0", "d8000", "spread"))
for k in sorted(agg, key=lambda x: -(st.median(agg[x][0]) if agg[x][0] else 0)):
    a, b = agg[k]
    if not a: print("  %-26s %8s %8s %9s   0" % (k, "DIED", "—", "—")); continue
    sp = 100*(max(a)-min(a))/min(a) if len(a) > 1 else 0
    print("  %-26s %8.2f %8.2f %8.1f%%   %d" % (k, st.median(a), st.median(b) if b else 0, sp, len(a)))
print()
print("  \u26a0 Output is NOT bit-reproducible at DEPTH. Measured across the governor test:")
print("  reps at d0 always agree, but a d8000 cell disagrees intermittently (one prompt")
print("  class at a time, ~3% tok/s apart) even at temperature 0 with top_k 1. Hybrid")
print("  CPU/GPU expert reduction order varies with thread scheduling and ~5.8k tokens of")
print("  accumulated state is enough to flip a token. Consequence: compare output HASHES")
print("  at d0 only. Medians at d8000 are fine; hashes there are not a valid gate.")
print()
print("  Under powersave the same cells read: ncmoe15 13.0, 20 11.7, 28 10.1, 34 8.4, 48 8.6 (d0)")
print("  If the ORDERING changed, the placement conclusions drawn at 1500 MHz were wrong too.")
PYS
echo "results in ${OUT}"
