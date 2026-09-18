#!/usr/bin/env bash
# How fast is Qwen3.8-Flash-Next on ONE V620? Proxmox HOST, root.
#
# -ncmoe 16 (the two-card default) needs ~60.5 GiB and cannot fit a 32 GiB card at all, so
# single-GPU means moving much further up the offload curve. Two things to establish:
#
#   1. the FASTEST placement that fits one card, and what it costs against the two-card best
#   2. whether one card is faster or slower than two AT THE SAME PLACEMENT
#
# (2) is not obvious. llama.cpp #28699 measured this architecture's QSA indexer shipping
# pooled rows across inter-GPU links every layer at ~2x decode cost, and the per-device fix
# is still an open draft — so a layer split may be a penalty rather than a benefit. This
# repo's own rule is to run ONE_GPU as a control before concluding two cards help.
#
# Single-GPU is pinned with `--device`, not by detaching a card: reversible, and no
# container restart. The guard counts devices, so MODEL_EXPECTED_GPUS must match or startup
# fails loudly.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

CT=120; ENVF=/etc/llamacpp-qwen38fn.env
OUT="${OUT:-/root/qwen38-flash-next/onegpu-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"
exec > >(tee -a "${OUT}/run.log") 2>&1

setv() { pct exec "$CT" -- python3 -c '
import json, os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
line = key + "=" + json.dumps(val)
src = open(path).read() if os.path.exists(path) else ""
src, n = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", lambda m: line, src)
if not n: src = src.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(src)' "$ENVF" "$1" "$2"; }

ip() { pct exec "$CT" -- hostname -I | awk '{print $1}'; }

cell() {  # <label> <ncmoe> <gpus:1|2>
  local label="$1" nc="$2" gpus="$3" c1 t=0
  setv MODEL_CPU_MOE "$nc"; setv MODEL_THREADS 16; setv MODEL_PARALLEL 1
  setv MODEL_CONTEXT_LENGTH 65536
  setv MODEL_KV_TYPE q8_0; setv MODEL_MMPROJ_ON_CPU true
  setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"; setv MODEL_LOAD_MODE ""
  setv MODEL_GPU_LAYERS 99; setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline
  if [ "$gpus" = 1 ]; then
    # Vulkan0 only. No --tensor-split: there is nothing to split across.
    setv EXTRA_ARGS "--device Vulkan0"; setv MODEL_TENSOR_SPLIT ""; setv MODEL_EXPECTED_GPUS 1
  else
    c1=$(( nc + (48 - nc) / 2 - 2 ))          # the CORRECTED rule
    setv EXTRA_ARGS ""; setv MODEL_TENSOR_SPLIT "${c1},$(( 48 - c1 ))"; setv MODEL_EXPECTED_GPUS 2
  fi
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
  until curl -fsS -m 4 "http://$(ip):1234/health" >/dev/null 2>&1; do
    pct exec "$CT" -- systemctl is-active --quiet llamacpp-qwen38fn || { echo "    ${label}: DIED (did not fit?)"; return 0; }
    sleep 5; t=$((t+5)); [ "$t" -ge 900 ] && { echo "    ${label}: TIMEOUT"; return 0; }
  done
  ./placement-probe.py "http://$(ip):1234" --reps 1 --n-predict 64 --depths 0,8000 --classes code >/dev/null 2>&1 || true
  ./placement-probe.py "http://$(ip):1234" --reps 2 --n-predict 160 --depths 0,8000 \
    >"${OUT}/${label}.json" 2>/dev/null || true
  local A=/sys/bus/pci/devices/0000:03:00.0 B=/sys/bus/pci/devices/0000:83:00.0
  python3 - "${OUT}/${label}.json" "$label" "$gpus" \
    "$(( ($(cat $A/mem_info_vram_total)-$(cat $A/mem_info_vram_used))/1048576 ))" \
    "$(( $(cat $A/mem_info_gtt_used)/1048576 ))" \
    "$(( ($(cat $B/mem_info_vram_total)-$(cat $B/mem_info_vram_used))/1048576 ))" <<'PY'
import json, statistics as st, sys
_, path, label, gpus, f1, g1, f2 = sys.argv
try: s = json.load(open(path))["summary"]
except Exception: print("    %-22s probe failed" % label); raise SystemExit
def m(pre, k="decode_tps_median"):
    v=[x[k] for kk,x in s.items() if kk.startswith(pre) and x.get(k)]
    return st.median(v) if v else 0.0
print("    %-22s %sgpu  d0=%6.2f  d8k=%6.2f  prefill_d8k=%6.1f  free=%s/%s MiB  gtt=%s" % (
    label, gpus, m("d0/"), m("d8000/"), m("d8000/","prefill_tps_median"), f1, f2, g1))
PY
}

echo "==> one card vs two, same placement and same shape (q8_0 + projCPU, threads 16, ctx 65536)"
# Paired, so the only difference is the device count. -ncmoe 34 is the lowest placement that
# fits one card; 36 and 40 give the curve past it.
cell "nc34-1gpu" 34 1
cell "nc34-2gpu" 34 2
cell "nc36-1gpu" 36 1
cell "nc40-1gpu" 40 1
echo "==> done; results in ${OUT}"
