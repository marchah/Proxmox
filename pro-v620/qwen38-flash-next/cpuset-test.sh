#!/usr/bin/env bash
# Is the in-container deficit the CPUSET or the DRM passthrough?
#
# #4 measured CT 120 at 11.28/9.60 (d0/d8000) against 11.96/11.15 host-native — a 6% / 16%
# deficit. Memory reclaim is ruled out (pgscan 0, pgsteal 0, 50 of 160 GiB used), so the
# leading suspect is that CT 120 is pinned to `cores: 48` of the host's 64 AND the cgroup
# picked a FRAGMENTED set: 4-5,8-10,13-16,19-42,45,47-49,51-52,54-55,57-63. On an EPYC 7532
# (8 CCDs x 4 cores, private 32 MB L3 per CCD) a scattered cpuset breaks L3 locality for the
# CPU-side expert FFN, while the host leg ran unrestricted.
#
# If lifting the cpuset closes the gap, this is a container CONFIG problem, not GPU
# passthrough overhead — a very different conclusion and a free fix.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
CT=120; ENVF=/etc/llamacpp-qwen38fn.env
OUT="${OUT:-/root/qwen38-flash-next/cpuset-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"

setv() { pct exec "$CT" -- python3 -c '
import json, os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
line = key + "=" + json.dumps(val)
src = open(path).read() if os.path.exists(path) else ""
src, n = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", lambda m: line, src)
if not n: src = src.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(src)' "$ENVF" "$1" "$2"; }

probe() {  # probe <label>
  local label="$1" ip t=0
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
  ip=$(pct exec "$CT" -- hostname -I | awk '{print $1}')
  until curl -fsS -m 4 "http://${ip}:1234/health" >/dev/null 2>&1; do
    sleep 5; t=$((t+5)); [ "$t" -ge 900 ] && { echo "    TIMEOUT"; return 1; }
  done
  echo "    healthy after ${t}s  cpuset=$(cat /sys/fs/cgroup/lxc/${CT}/cpuset.cpus.effective)"
  ./placement-probe.py "http://${ip}:1234" --reps 3 --n-predict 160 --depths 0,8000 \
    >"${OUT}/${label}.json" 2>/dev/null || true
  python3 -c "
import json, statistics as st
d=json.load(open('${OUT}/${label}.json')); s=d.get('summary',{})
d0=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d0/')]
d8=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d8000/')]
print('    %-22s d0=%6.2f  d8000=%6.2f  agree=%s' % ('${label}', st.median(d0), st.median(d8), d['all_reps_agree']))"
}

# identical placement to both #4 legs
setv MODEL_CPU_MOE 20; setv MODEL_TENSOR_SPLIT 34,14; setv MODEL_THREADS 32
setv MODEL_GPU_LAYERS 99; setv MODEL_EXPECTED_GPUS 2; setv EXTRA_ARGS ""
setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"
setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline

echo "==> A: cores 48, fragmented cpuset (the #4 in-CT condition, as a reproduction)"
pct set "$CT" --cores 48; pct stop "$CT"; sleep 4; pct start "$CT"; sleep 18
probe "cores48"

echo "==> B: cpuset REMOVED entirely (all 64 threads, like the host leg)"
pct set "$CT" --delete cores; pct stop "$CT"; sleep 4; pct start "$CT"; sleep 18
probe "cores-unrestricted"

echo
echo "reference — #4: in-CT d0 11.28 / d8000 9.60 | host-native d0 11.96 / d8000 11.15"
echo "results in ${OUT}"
