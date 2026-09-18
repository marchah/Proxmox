#!/usr/bin/env bash
# Is decode losing time to CPU POWER MANAGEMENT? Proxmox HOST, root, from this directory.
#
# Evidence that led here:
#   * ~67 ms/token unaccounted for by any compute or bandwidth budget
#   * nothing saturated: GPUs 8 W / 43 C / ~30% busy, host CPU 33-43%
#   * DIMMs 9 C COOLER than a genuine memory soak
#   * disk paging ruled out (zero majflt and 0.1 MB/s after cold start, with NO t/s gain)
#   * 36% spread across 8 probes of ONE server instance with nothing changed
#   * governor = powersave, and C2 costs 400 us to exit with 15.4M entries logged
#   * all of it set on 2026-09-16, the day before these measurements
#
# 🔴 DESIGN: all three arms run against a SINGLE server instance. The governor and
# /dev/cpu_dma_latency are both live-tunable, so nothing restarts between arms — which
# removes the page-cache warmth and cpuset-lottery confounds that made every earlier
# comparison unreliable. Arms are INTERLEAVED and the baseline is revisited last.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
CT=120; ENVF=/etc/llamacpp-qwen38fn.env
OUT="${OUT:-/root/qwen38-flash-next/power-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"
ROUNDS="${ROUNDS:-3}"

setv() { pct exec "$CT" -- python3 -c '
import json, os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
line = key + "=" + json.dumps(val)
src = open(path).read() if os.path.exists(path) else ""
src, n = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", lambda m: line, src)
if not n: src = src.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(src)' "$ENVF" "$1" "$2"; }

ORIG_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
LAT_PID=""
cleanup() {
  [ -n "$LAT_PID" ] && kill "$LAT_PID" 2>/dev/null || true
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$ORIG_GOV" >"$g" 2>/dev/null || true; done
  echo "==> restored governor to ${ORIG_GOV}, released cpu_dma_latency"
}
trap cleanup EXIT

set_gov() { for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$1" >"$g"; done; }

# Holding /dev/cpu_dma_latency open with a 0 value is the documented way to stop the kernel
# entering idle states whose exit latency exceeds the value — i.e. it pins cores out of C2.
pin_latency() { python3 -c '
import os, time, struct
fd = os.open("/dev/cpu_dma_latency", os.O_WRONLY)
os.write(fd, struct.pack("i", 0))
while True: time.sleep(3600)
' & LAT_PID=$!; sleep 1; }
unpin_latency() { [ -n "$LAT_PID" ] && kill "$LAT_PID" 2>/dev/null || true; LAT_PID=""; sleep 1; }

setv MODEL_CPU_MOE 20; setv MODEL_TENSOR_SPLIT 34,14; setv MODEL_THREADS 32
setv MODEL_GPU_LAYERS 99; setv MODEL_EXPECTED_GPUS 2; setv EXTRA_ARGS ""
setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"; setv MODEL_LOAD_MODE ""
setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline

echo "==> starting the server ONCE; no restarts for the rest of the run"
pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
IP=$(pct exec "$CT" -- hostname -I | awk '{print $1}')
t=0; until curl -fsS -m 4 "http://${IP}:1234/health" >/dev/null 2>&1; do
  sleep 5; t=$((t+5)); [ "$t" -ge 1200 ] && { echo "TIMEOUT"; exit 1; }; done
echo "    healthy after ${t}s"
echo "==> warming the page cache so arm 1 is not paying cold-start I/O"
./placement-probe.py "http://${IP}:1234" --reps 1 --n-predict 160 --depths 0,8000 >/dev/null 2>&1 || true
echo

probe() {  # probe <arm> <round>
  local arm="$1" r="$2" c2a c2b
  c2a=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state2/usage)
  ./placement-probe.py "http://${IP}:1234" --reps 2 --n-predict 160 --depths 0,8000 \
    >"${OUT}/${arm}-r${r}.json" 2>/dev/null || true
  c2b=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state2/usage)
  python3 -c "
import json, statistics as st
d=json.load(open('${OUT}/${arm}-r${r}.json')); s=d.get('summary',{})
d0=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d0/')]
d8=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d8000/')]
print('    %-22s r%s  d0=%6.2f  d8000=%6.2f  C2-entries(cpu0)=%s' % (
  '${arm}', '${r}', st.median(d0) if d0 else 0, st.median(d8) if d8 else 0, $c2b - $c2a))"
}

for r in $(seq 1 "$ROUNDS"); do
  echo "======== round ${r} ========"
  set_gov powersave;   unpin_latency;  probe "A-powersave"          "$r"
  set_gov performance; unpin_latency;  probe "B-performance"        "$r"
  set_gov performance; pin_latency;    probe "C-perf+noC2"          "$r"
  unpin_latency
done

echo
echo "======== SUMMARY (median over rounds) ========"
python3 - "$OUT" <<'PYS'
import glob, json, os, statistics as st, sys
base = sys.argv[1]
print("  %-22s %8s %8s   %s" % ("arm", "d0", "d8000", "n"))
ref = {}
for arm in ("A-powersave", "B-performance", "C-perf+noC2"):
    d0s, d8s = [], []
    for f in sorted(glob.glob(os.path.join(base, arm + "-r*.json"))):
        s = json.load(open(f)).get("summary", {})
        a = [v["decode_tps_median"] for k, v in s.items() if k.startswith("d0/")]
        b = [v["decode_tps_median"] for k, v in s.items() if k.startswith("d8000/")]
        if a: d0s.append(st.median(a))
        if b: d8s.append(st.median(b))
    if not d0s: continue
    m0, m8 = st.median(d0s), st.median(d8s) if d8s else 0
    ref.setdefault("base", (m0, m8))
    b0, b8 = ref["base"]
    print("  %-22s %8.2f %8.2f   n=%d   vs powersave: d0 %+.1f%%  d8000 %+.1f%%"
          % (arm, m0, m8, len(d0s), 100*(m0-b0)/b0, 100*(m8-b8)/b8 if b8 else 0))
print()
print("  C2 exit latency is 400 us. If arms B/C are much faster, the deficit was power")
print("  management, not placement, bandwidth, or the engine.")
PYS
echo "results in ${OUT}"
