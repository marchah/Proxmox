#!/usr/bin/env bash
# The two structural experiments, plus the LXC-passthrough control. Proxmox HOST, root, from
# this directory. Each mode is independent; run them one at a time on a QUIET box.
#
#   ./structural-tests.sh wholelayer   # #3 collapse the CPU<->GPU handoffs
#   ./structural-tests.sh pr28699      # #2 baseline vs the QSA pooled-key-cache PR
#   ./structural-tests.sh passthrough  # #4 same binary, host-native vs inside CT 120
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

CT=120
ENVF=/etc/llamacpp-qwen38fn.env
MODEL=/models/hf/qwen3.8-flash-next/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf
MMPROJ=/models/hf/qwen3.8-flash-next/mmproj-F16.gguf
OUT="${OUT:-/root/qwen38-flash-next/structural-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

setv() {
  pct exec "$CT" -- python3 -c '
import json, os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
line = key + "=" + json.dumps(val)
src = open(path).read() if os.path.exists(path) else ""
src, n = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", lambda m: line, src)
if not n:
    src = src.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(src)
' "$ENVF" "$1" "$2"
}

ct_ip() { pct exec "$CT" -- hostname -I | awk '{print $1}'; }

wait_health() {  # wait_health <base-url> <what>
  local base="$1" what="$2" t=0
  until curl -fsS -m 4 "${base}/health" >/dev/null 2>&1; do
    sleep 5; t=$((t+5))
    [ "$t" -ge "${HEALTH_TIMEOUT:-1200}" ] && { echo "    TIMEOUT waiting for ${what}"; return 1; }
    if [ "$what" = "ct" ] && ! pct exec "$CT" -- systemctl is-active --quiet llamacpp-qwen38fn; then
      pct exec "$CT" -- journalctl -u llamacpp-qwen38fn --no-pager -n 15 -o cat >&2; return 1
    fi
  done
  echo "    healthy after ${t}s"
}

vram() { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_vram_used" 2>/dev/null || echo 0)/1048576 )); }
gtt()  { echo $(( $(cat "/sys/bus/pci/devices/$1/mem_info_gtt_used"  2>/dev/null || echo 0)/1048576 )); }

report() {  # report <label> <base-url>
  local label="$1" base="$2"
  printf '    GPU1 vram=%5d gtt=%4d | GPU2 vram=%5d gtt=%4d\n' \
    "$(vram 0000:03:00.0)" "$(gtt 0000:03:00.0)" "$(vram 0000:83:00.0)" "$(gtt 0000:83:00.0)"
  ./placement-probe.py "$base" --reps 3 --n-predict 160 --depths 0,8000 \
    >"${OUT}/${label}.json" 2>"${OUT}/${label}.rows.jsonl" || echo "    probe failed"
  python3 -c "
import json
d=json.load(open('${OUT}/${label}.json'))
s=d.get('summary',{})
for k in sorted(s): print('    %-12s %6.2f t/s' % (k, s[k]['decode_tps_median']))
print('    overall %.2f t/s | degenerate=%s | reps agree=%s' % (
  d['decode_tps_overall_median'], d['any_degenerate'], d['all_reps_agree']))"
}

restore_production() {
  log "restoring production placement"
  setv MODEL_CPU_MOE 20; setv MODEL_TENSOR_SPLIT 34,14; setv MODEL_THREADS 32
  setv MODEL_GPU_LAYERS 99; setv MODEL_EXPECTED_GPUS 2; setv EXTRA_ARGS ""
  setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"
  setv LLAMACPP_DIR /opt/llamacpp/llama-b11018
}

case "${1:-}" in

# ---------------------------------------------------------------- #3 whole-layer placement
wholelayer)
  # --n-cpu-moe keeps ATTENTION on the GPU and moves only the experts, so each of the first N
  # layers does GPU -> CPU -> GPU: 2N transitions. Moving layers 0..N-1 ENTIRELY to the CPU
  # gives ONE transition. Cheap on KV here: only 12 of 48 layers hold a cache (the other 36
  # are Gated DeltaNet with a fixed-size state), so few of the moved layers carry KV at all.
  # ⚠️ The cost is CPU attention for those layers, which may swamp the saving. That is the test.
  setv MODEL_THREADS 32; setv MODEL_EXPECTED_GPUS 2; setv MODEL_GPU_LAYERS 99; setv EXTRA_ARGS ""
  setv LLAMACPP_DIR /opt/llamacpp/llama-b11018

  log "CONTROL: -ncmoe 20 (experts only, ~40 transitions)"
  setv MODEL_CPU_MOE 20; setv MODEL_TENSOR_SPLIT 34,14
  setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
  wait_health "http://$(ct_ip):1234" ct && report "wholelayer-control-ncmoe20" "http://$(ct_ip):1234"

  for n in 12 20; do
    log "WHOLE LAYERS 0..$((n-1)) on CPU (2 transitions)"
    setv MODEL_CPU_MOE ""
    # 🔴 --tensor-split is REQUIRED here too, for exactly the same reason as with --n-cpu-moe,
    # and I got this wrong the first time. Forcing layers 0..N-1 to the CPU with -ot does NOT
    # make llama.cpp rebalance: it still splits all 48 positions evenly, so card 1 gets
    # 0..23 (of which the first N are on the CPU, leaving few real layers) while card 2 gets
    # a full 24. Measured at N=12 with no split: GPU2 pinned at 30668 MiB spilling 7962 MiB
    # to GTT, which made the run a spill measurement rather than a handoff measurement.
    # Same formula as the -ncmoe case: card1 = N + (48 - N)/2.
    c1=$(( n + (48 - n) / 2 ))
    setv MODEL_TENSOR_SPLIT "${c1},$(( 48 - c1 ))"
    log "  tensor-split ${c1},$(( 48 - c1 )) (derived, same formula as -ncmoe)"
    # blk.0 .. blk.(n-1), whole layer: attention, experts, norms, hyper-connections
    if [ "$n" -le 10 ]; then rx="blk\\.[0-$((n-1))]\\."
    else rx="blk\\.([0-9]|1[0-$((n-11))])\\."; fi
    setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU,${rx}=CPU"
    pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
    wait_health "http://$(ct_ip):1234" ct && report "wholelayer-${n}" "http://$(ct_ip):1234"
  done
  restore_production
  ;;

# ---------------------------------------------------------------- #2 PR 28699
pr28699)
  # Self-built baseline vs the same tree with the PR, so build flags cannot be confounded with
  # the patch. Upstream measured +9.3-9.4% AT DEPTH, so d8000 is the cell that matters; d0 is
  # expected to be flat and acts as a negative control.
  for b in b11018-baseline b11018-pr28699; do
    pct exec "$CT" -- test -x "/opt/llamacpp/${b}/llama-server" || die "${b} not installed in CT ${CT}"
  done
  setv MODEL_CPU_MOE 20; setv MODEL_TENSOR_SPLIT 34,14; setv MODEL_THREADS 32
  setv MODEL_GPU_LAYERS 99; setv MODEL_EXPECTED_GPUS 2; setv EXTRA_ARGS ""
  setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"

  for b in b11018-baseline b11018-pr28699 b11018-baseline; do   # baseline twice = drift check
    log "build ${b}"
    setv LLAMACPP_DIR "/opt/llamacpp/${b}"
    pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
    wait_health "http://$(ct_ip):1234" ct && report "pr28699-${b}-$(date -u +%H%M%S)" "http://$(ct_ip):1234"
  done
  restore_production
  ;;

# ---------------------------------------------------------------- #4 LXC passthrough overhead
passthrough)
  # CT 120 is an LXC with BIND-MOUNTED DRM render nodes, not a VM with VFIO passthrough — same
  # kernel, same amdgpu driver — so the expected overhead is ~0. Measured anyway, with the SAME
  # binary in both legs: it is built on glibc 2.39 (Ubuntu 24.04, matching CT 120) and glibc is
  # forward compatible, so it also runs on this Debian 13 host (2.41).
  BIN="${BIN:-/root/builds/b11018-baseline}"
  [ -x "${BIN}/llama-server" ] || die "${BIN}/llama-server not on the host"
  command -v vulkaninfo >/dev/null || die "install mesa-vulkan-drivers on the host first"

  log "leg 1 — INSIDE CT ${CT}"
  setv MODEL_CPU_MOE 20; setv MODEL_TENSOR_SPLIT 34,14; setv MODEL_THREADS 32
  setv MODEL_GPU_LAYERS 99; setv MODEL_EXPECTED_GPUS 2; setv EXTRA_ARGS ""
  setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"
  setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
  wait_health "http://$(ct_ip):1234" ct && report "passthrough-in-ct" "http://$(ct_ip):1234"
  pct exec "$CT" -- systemctl stop llamacpp-qwen38fn

  log "leg 2 — HOST NATIVE (stopping CT ${CT} to release the model LV and both cards)"
  pct stop "$CT"; sleep 5
  local_mnt=/mnt/models120
  mkdir -p "$local_mnt"
  mount -o ro /dev/pve/vm-120-disk-1 "$local_mnt" || die "could not mount the model LV"
  trap 'umount "$local_mnt" 2>/dev/null || true; pct start '"$CT"' 2>/dev/null || true' EXIT

  LD_LIBRARY_PATH="$BIN" VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json \
  "${BIN}/llama-server" \
    --model "${local_mnt}${MODEL#/models}" --mmproj "${local_mnt}${MMPROJ#/models}" \
    --host 127.0.0.1 --port 1235 --alias qwen3.8-flash-next \
    --n-gpu-layers 99 --ctx-size 65536 --parallel 1 --threads 32 \
    --flash-attn on --batch-size 4096 --ubatch-size 1024 --jinja \
    --reasoning off --reasoning-format auto --cache-ram 0 --metrics \
    --override-tensor "per_layer_token_embd=CPU" --n-cpu-moe 20 --tensor-split 34,14 \
    >"${OUT}/host-native.log" 2>&1 &
  hostpid=$!
  wait_health "http://127.0.0.1:1235" host && report "passthrough-host-native" "http://127.0.0.1:1235"
  kill "$hostpid" 2>/dev/null || true; wait "$hostpid" 2>/dev/null || true
  umount "$local_mnt" || true
  trap - EXIT
  pct start "$CT"; sleep 15
  restore_production
  ;;

*) die "usage: $0 {wholelayer|pr28699|passthrough}" ;;
esac

echo
log "results in ${OUT}"
