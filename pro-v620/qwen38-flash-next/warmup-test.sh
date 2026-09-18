#!/usr/bin/env bash
# Is decode I/O-BOUND on a cold page cache? Proxmox HOST, root, from this directory.
#
# Measured during decode: llama-server read 412 MiB in 5 s (82 MB/s) at 17-34k IOPS with
# 46,706 major faults — i.e. ~7 MB of DISK reads per token. At ~100 us per random SATA read
# in a dependent chain that is tens of ms, which is the ~67 ms/token this box could not
# otherwise account for. It also explains why NOTHING is saturated: GPUs 8 W / 43 C, CPU
# 33-43%, DIMMs 9 C cooler than a real memory load — everything waits on the 860 EVO.
#
# 🔴 If true, EVERY measurement taken today is suspect, because the harness restarts the
# server (and the variance test restarted the whole container, dropping its cgroup page
# cache) before each cell. This starts the server ONCE and then probes repeatedly WITHOUT
# touching it, tracking disk reads and resident bytes per iteration. If t/s climbs as reads
# fall, decode is I/O-bound while cold and the real steady-state number is the last one.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
CT=120; ENVF=/etc/llamacpp-qwen38fn.env
N="${N:-8}"
OUT="${OUT:-/root/qwen38-flash-next/warmup-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"

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
setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"; setv MODEL_LOAD_MODE ""
setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline

# 🔴 COLD START ON PURPOSE: stop the container to drop its cgroup page cache, and drop the
# host's too, so iteration 1 is genuinely cold and the warm-up curve is visible.
echo "==> dropping caches for a genuinely cold start"
pct stop "$CT" >/dev/null 2>&1 || true; sleep 4
sync; echo 3 >/proc/sys/vm/drop_caches; sleep 2
pct start "$CT" >/dev/null 2>&1; sleep 18
pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
IP=$(pct exec "$CT" -- hostname -I | awk '{print $1}')
t=0; until curl -fsS -m 4 "http://${IP}:1234/health" >/dev/null 2>&1; do
  sleep 5; t=$((t+5)); [ "$t" -ge 1200 ] && { echo "TIMEOUT"; exit 1; }; done
echo "    healthy after ${t}s"
echo

printf '  %-5s %-9s %-11s %-13s %-11s %s\n' iter "d0 t/s" "disk MB/s" "majflt delta" "cgroup GiB" "file_mapped GiB"
for i in $(seq 1 "$N"); do
  pid=$(pgrep -f "llama-server" | head -1)
  r0=$(awk '/ sda /{print $6}' /proc/diskstats); f0=$(awk '{print $12}' "/proc/${pid}/stat")
  s0=$(date +%s.%N)
  tps=$(./placement-probe.py "http://${IP}:1234" --reps 1 --n-predict 160 --depths 0 2>/dev/null \
        | python3 -c "import json,sys; print('%.2f' % json.load(sys.stdin)['decode_tps_overall_median'])")
  s1=$(date +%s.%N)
  r1=$(awk '/ sda /{print $6}' /proc/diskstats); f1=$(awk '{print $12}' "/proc/${pid}/stat")
  el=$(echo "$s1 - $s0" | bc -l)
  printf '  %-5s %-9s %-11.1f %-13s %-11s %s\n' "$i" "$tps" \
    "$(echo "($r1-$r0)*512/$el/1048576" | bc -l)" "$(( f1 - f0 ))" \
    "$(( $(cat /sys/fs/cgroup/lxc/${CT}/memory.current)/1073741824 ))" \
    "$(awk '/^file_mapped/{printf "%d", $2/1073741824}' /sys/fs/cgroup/lxc/${CT}/memory.stat)"
done
echo
echo "  If t/s climbs while disk MB/s and majflt fall, decode is I/O-bound while cold and"
echo "  every single-shot measurement taken today understated the steady state."
echo "results in ${OUT}"
