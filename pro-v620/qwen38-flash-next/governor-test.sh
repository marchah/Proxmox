#!/usr/bin/env bash
# Which governor? Measures THROUGHPUT and IDLE POWER for each, so the tradeoff is priced
# rather than argued. Proxmox HOST, root, from this directory.
#
# Background: cpu-powersave.service (enabled, from the 2026-09-16 power work) pins the
# governor to `powersave`. Its own comment says it "works on both acpi-cpufreq and
# amd-pstate-epp" — but that is the trap. Under amd-pstate-epp, `powersave` is DYNAMIC and
# the EPP hint tunes it. Under acpi-cpufreq, which this Zen 2 EPYC actually uses,
# `powersave` PINS CORES TO THE MINIMUM 1500 MHz forever, against a 3308 MHz maximum.
# Measured cost: -54% decode at short prompt, -26% at depth, and variance blowing out from
# ~1.4% to ~36%.
#
# The open question this answers: does a DYNAMIC governor (schedutil / ondemand) recover the
# throughput without giving up idle power? If so it beats both pinning `performance` and
# toggling per-service, because it needs no toggle and so has no silent failure mode.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
CT=120; ENVF=/etc/llamacpp-qwen38fn.env
OUT="${OUT:-/root/qwen38-flash-next/gov-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"
ROUNDS="${ROUNDS:-2}"
ARMS="${ARMS:-performance schedutil ondemand powersave}"
# Idle package power, measured 2026-09-18 before this script crashed: performance 54.9 W,
# schedutil 54.2, ondemand 54.2, powersave 53.2 — a 1.7 W spread. That already answers the
# "pin performance per-core so idle cores stay cheap" question: NO, not worth it, because
# idle cores are halted in C2 regardless of governor and the governor only sets the P-state
# of cores that actually run. Set SKIP_IDLE=1 to skip re-measuring it.
SKIP_IDLE="${SKIP_IDLE:-}"

ORIG=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
# 🔴 `local` on these loop variables is load-bearing. Without it they are GLOBAL and clobber
# the caller's loop variable — the first version of this script used `g` in both the arm loop
# and inside set_gov, so after the first call `$g` held a sysfs PATH instead of a governor
# name. The result was a probe filename of ".../sys/devices/.../scaling_governor-r1.json" and
# a crash, after the idle measurements had already been taken under the right governors.
cleanup() {
  local f
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$ORIG" >"$f" 2>/dev/null || true; done
  echo "==> restored governor to ${ORIG}"
}
trap cleanup EXIT
set_gov() {
  local want="$1" f
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$want" >"$f"; done
  sleep 2
  # assert it actually took, rather than trusting the write
  local got
  got=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
  [ "$got" = "$want" ] || { echo "FATAL: governor is '${got}', wanted '${want}'"; exit 1; }
}

setv() { pct exec "$CT" -- python3 -c '
import json, os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
line = key + "=" + json.dumps(val)
src = open(path).read() if os.path.exists(path) else ""
src, n = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", lambda m: line, src)
if not n: src = src.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(src)' "$ENVF" "$1" "$2"; }

# mean core clock across all CPUs — the mechanism, so the result is explainable not magic
clk() { awk '{s+=$1; n++} END{printf "%d", s/n/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; }

# CPU PACKAGE POWER via RAPL. Despite the driver being called intel-rapl it covers AMD Zen,
# and it is what prices the idle side of this tradeoff.
# ⚠️ This contradicts the standing note that idle watts are "unmeasurable in-band" — that is
# true of SYSTEM power (the PSU has no PMBus), but the CPU package is readable right here.
RAPL=/sys/class/powercap/intel-rapl:0/energy_uj
pkg_watts() {  # pkg_watts <seconds>
  local secs="$1" a b
  [ -r "$RAPL" ] || { echo "n/a"; return; }
  a=$(cat "$RAPL"); sleep "$secs"; b=$(cat "$RAPL")
  # the counter wraps; a negative delta means it did, so just report n/a rather than nonsense
  awk -v a="$a" -v b="$b" -v s="$secs" 'BEGIN{d=b-a; if(d<0){print "wrap"} else {printf "%.1f", d/1e6/s}}'
}

setv MODEL_CPU_MOE 20; setv MODEL_TENSOR_SPLIT 34,14; setv MODEL_THREADS 32
setv MODEL_GPU_LAYERS 99; setv MODEL_EXPECTED_GPUS 2; setv EXTRA_ARGS ""
setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"; setv MODEL_LOAD_MODE ""
setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline

echo "==> one server instance for the whole run; no restarts between arms"
pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
IP=$(pct exec "$CT" -- hostname -I | awk '{print $1}')
t=0; until curl -fsS -m 4 "http://${IP}:1234/health" >/dev/null 2>&1; do
  sleep 5; t=$((t+5)); [ "$t" -ge 1200 ] && { echo TIMEOUT; exit 1; }; done
echo "    healthy after ${t}s"
./placement-probe.py "http://${IP}:1234" --reps 1 --n-predict 160 --depths 0 >/dev/null 2>&1 || true

echo
echo "==> IDLE clock AND PACKAGE POWER per governor (nothing running) — the power side of"
echo "    the trade, and the test of whether per-core governors would even be worth it:"
echo "    idle cores sit in C2 regardless of governor, so if performance costs little at"
echo "    idle then pinning it globally is simpler and just as cheap."
if [ -z "$SKIP_IDLE" ]; then
  pct exec "$CT" -- systemctl stop llamacpp-qwen38fn
  sleep 10
  for gov in $ARMS; do
    set_gov "$gov"; sleep 20
    printf '    %-12s idle: %4s MHz   package %s W\n' "$gov" "$(clk)" "$(pkg_watts 20)"
  done
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
else
  echo "    (skipped — already measured: performance 54.9 W vs powersave 53.2 W idle,"
  echo "     a 1.7 W spread, which is why per-core governor pinning is not worth building)"
fi
t=0; until curl -fsS -m 4 "http://${IP}:1234/health" >/dev/null 2>&1; do sleep 5; t=$((t+5)); [ "$t" -ge 1200 ] && exit 1; done
./placement-probe.py "http://${IP}:1234" --reps 1 --n-predict 160 --depths 0 >/dev/null 2>&1 || true
echo

for r in $(seq 1 "$ROUNDS"); do
  echo "======== round ${r} ========"
  for gov in $ARMS; do
    set_gov "$gov"
    ./placement-probe.py "http://${IP}:1234" --reps 2 --n-predict 160 --depths 0,8000 \
      >"${OUT}/${gov}-r${r}.json" 2>/dev/null || true
    LOADW=$(pkg_watts 5)
    python3 -c "
import json, statistics as st
d=json.load(open('${OUT}/${gov}-r${r}.json')); s=d.get('summary',{})
a=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d0/')]
b=[v['decode_tps_median'] for k,v in s.items() if k.startswith('d8000/')]
print('    %-12s r%s  d0=%6.2f  d8000=%6.2f  clock %s MHz  pkg %s W' % (
  '${gov}', '${r}', st.median(a) if a else 0, st.median(b) if b else 0, '$(clk)', '${LOADW}'))"
  done
done

echo
echo "======== SUMMARY ========"
python3 - "$OUT" "$ARMS" <<'PYS'
import glob, json, os, statistics as st, sys
base, arms = sys.argv[1], sys.argv[2].split()
res = {}
for g in arms:
    a, b = [], []
    for f in sorted(glob.glob(os.path.join(base, g + "-r*.json"))):
        s = json.load(open(f)).get("summary", {})
        x = [v["decode_tps_median"] for k, v in s.items() if k.startswith("d0/")]
        y = [v["decode_tps_median"] for k, v in s.items() if k.startswith("d8000/")]
        if x: a.append(st.median(x))
        if y: b.append(st.median(y))
    if a: res[g] = (st.median(a), st.median(b) if b else 0,
                    100*(max(a)-min(a))/min(a) if len(a) > 1 else 0)
base_g = "powersave" if "powersave" in res else arms[-1]
print("  %-12s %8s %8s %9s   %s" % ("governor", "d0", "d8000", "spread", "vs powersave"))
for g in arms:
    if g not in res: continue
    d0, d8, sp = res[g]
    b0 = res[base_g][0]
    print("  %-12s %8.2f %8.2f %8.1f%%   d0 %+.0f%%" % (g, d0, d8, sp, 100*(d0-b0)/b0))
print()
print("  If schedutil matches performance, it is the answer: no toggle, no silent failure")
print("  mode, and idle clocks stay low. If it does not, the choice is pin performance")
print("  (simple, costs idle watts) versus toggle per-service (needs a loud guard).")
PYS
echo "results in ${OUT}"
