#!/usr/bin/env bash
# How much does the RESTART LOTTERY cost, and does removing the cpuset make it deterministic?
#
# Today the same nominal config produced 9.60 and 11.14 t/s at depth — a 16% spread — and LXC
# was observed handing CT 120 a DIFFERENT fragmented core set on every start (three seen):
#   4-5,8-10,13-16,19-42,45,47-49,51-52,54-55,57-63
#   4-5,8-10,13-16,19-37,39-45,47-50,52-55,57,59-60,62-63
# On an 8-CCD EPYC 7532 (private 32 MB L3 per CCD) that scatters the CPU-side expert FFN across
# L3 slices differently each time. This measures the spread rather than assuming it: N restarts
# at cores 48, N with the cpuset removed, same placement throughout, d8000 only (the sensitive
# cell). If the unrestricted arm is TIGHTER, determinism is the real prize, not the mean.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
CT=120; ENVF=/etc/llamacpp-qwen38fn.env
N="${N:-4}"
OUT="${OUT:-/root/qwen38-flash-next/cpuvar-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"

setv() { pct exec "$CT" -- python3 -c '
import json, os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
line = key + "=" + json.dumps(val)
src = open(path).read() if os.path.exists(path) else ""
src, n = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", lambda m: line, src)
if not n: src = src.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(src)' "$ENVF" "$1" "$2"; }

setv MODEL_CPU_MOE 20; setv MODEL_TENSOR_SPLIT 34,14; setv MODEL_THREADS 32
setv MODEL_GPU_LAYERS 99; setv MODEL_EXPECTED_GPUS 2; setv EXTRA_ARGS ""
setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"
setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline

one() {  # one <arm> <iteration>
  local arm="$1" i="$2" ip t=0 cs
  pct stop "$CT" >/dev/null 2>&1 || true; sleep 4
  pct start "$CT" >/dev/null 2>&1; sleep 18
  cs=$(cat "/sys/fs/cgroup/lxc/${CT}/cpuset.cpus.effective")
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
  ip=$(pct exec "$CT" -- hostname -I | awk '{print $1}')
  until curl -fsS -m 4 "http://${ip}:1234/health" >/dev/null 2>&1; do
    sleep 5; t=$((t+5)); [ "$t" -ge 900 ] && { echo "    TIMEOUT"; return 1; }
  done
  ./placement-probe.py "http://${ip}:1234" --reps 2 --n-predict 160 --depths 8000 \
    >"${OUT}/${arm}-${i}.json" 2>/dev/null || true
  python3 -c "
import json, statistics as st
d=json.load(open('${OUT}/${arm}-${i}.json')); s=d.get('summary',{})
v=[x['decode_tps_median'] for x in s.values() if x.get('decode_tps_median')]
print('    %-14s iter %s  d8000=%6.2f   cpuset=%s' % ('${arm}', '${i}', st.median(v) if v else 0, '${cs}'[:44]))"
}

echo "==== ARM 1: cores 48 (the restart lottery) ===="
pct set "$CT" --cores 48
for i in $(seq 1 "$N"); do one cores48 "$i"; done

echo "==== ARM 2: cpuset removed (all 64, should be deterministic) ===="
pct set "$CT" --delete cores
for i in $(seq 1 "$N"); do one unrestricted "$i"; done

echo
echo "==== SPREAD ===="
python3 - "$OUT" <<'PYS'
import glob, json, os, statistics as st, sys
base = sys.argv[1]
for arm in ("cores48", "unrestricted"):
    vals = []
    for f in sorted(glob.glob(os.path.join(base, arm + "-*.json"))):
        s = json.load(open(f)).get("summary", {})
        v = [x["decode_tps_median"] for x in s.values() if x.get("decode_tps_median")]
        if v: vals.append(st.median(v))
    if not vals: continue
    spread = 100.0 * (max(vals) - min(vals)) / min(vals)
    print("  %-14s n=%d  min=%5.2f  max=%5.2f  median=%5.2f  stdev=%4.2f  SPREAD=%5.1f%%"
          % (arm, len(vals), min(vals), max(vals), st.median(vals),
             st.stdev(vals) if len(vals) > 1 else 0.0, spread))
print()
print("  If cores48's spread is large and unrestricted's is small, the cpuset lottery is the")
print("  noise source and `pct set 120 --delete cores` is the fix — for CONSISTENCY, not speed.")
PYS
echo "results in ${OUT}"
