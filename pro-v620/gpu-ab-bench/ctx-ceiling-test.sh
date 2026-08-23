#!/usr/bin/env bash
# How much f16 context actually fits with the projector on the CPU? Arithmetic put the
# ceiling near 96-112k, but every VRAM prediction this session has been off, so measure.
# Watches GTT as closely as VRAM: on RADV the failure mode is a silent spill, not an OOM.
set -Eeuo pipefail
OUT=/root/gpu-ab-bench/ctx-ceiling.out
: >"$OUT"; exec >>"$OUT" 2>&1
LC=/opt/llamacpp/current
M=/models/hf/Qwen3.8-27B-UD-Q5_K_XL.gguf
D=/models/hf/Qwen3.8-27B-MTP-ONLY-Q8_0.gguf
P=/models/hf/Qwen3.8-27B-mmproj-F16.gguf
pct exec 123 -- systemctl stop llama-swap || true; sleep 5

run() { # <ctx>
  local ctx="$1"
  echo "=== ctx $ctx, f16 KV, projector on CPU ==="
  pct exec 123 -- env LD_LIBRARY_PATH="$LC" VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json \
    "$LC/llama-server" --model "$M" --host 127.0.0.1 --port 5994 --n-gpu-layers 99 \
    --ctx-size "$ctx" --parallel 1 --flash-attn on --batch-size 4096 --ubatch-size 1024 \
    --jinja --reasoning-format auto --metrics --n-predict 32768 --alias cx \
    --spec-type draft-mtp --model-draft "$D" --spec-draft-n-max 2 --spec-draft-ngl 99 \
    --mmproj "$P" --no-mmproj-offload >/root/gpu-ab-bench/cx-"$ctx".log 2>&1 &
  local i=0
  until pct exec 123 -- curl -sf http://127.0.0.1:5994/health >/dev/null 2>&1; do
    sleep 5; i=$((i+5))
    if [ $i -gt 420 ]; then
      echo "  !! never healthy — over-committed. tail:"; tail -5 /root/gpu-ab-bench/cx-"$ctx".log | sed 's/^/     /'
      pct exec 123 -- pkill -f "port 5994" || true; sleep 5; return
    fi
  done
  local d=/sys/bus/pci/devices/0000:06:00.0
  local v g
  v=$(cat $d/mem_info_vram_used); g=$(cat $d/mem_info_gtt_used)
  python3 -c "
v=$v/1024**3; g=$g/1024**3
print('  VRAM %.2f GiB of 29.98 (headroom %.2f) | GTT %.2f GiB%s' % (
  v, 29.98-v, g, '   <-- SPILL: decode will collapse' if g > 1.0 else
                  ('   <-- GTT creeping, at the edge' if g > 0.55 else '')))"
  pct exec 123 -- python3 /root/kv-probe.py http://127.0.0.1:5994 cx
  pct exec 123 -- pkill -f "port 5994" || true
  sleep 8
}

run 98304    # 96k  — the arithmetic target
run 114688   # 112k — the ragged edge
pct exec 123 -- systemctl start llama-swap || true; sleep 5
echo "=== done (llama-swap: $(pct exec 123 -- systemctl is-active llama-swap)) ==="
