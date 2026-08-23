#!/usr/bin/env bash
# Does quantising the KV cache cost throughput, and how much context fits?
# The existing -32% figure changed ctx 65536->131072 AND f16->q8_0 together, so it cannot
# separate "quantised KV is slower" from "longer context is slower". These runs isolate it:
# same ctx, only the cache type changes; then q8_0 at 128k for the capacity question.
set -Eeuo pipefail
OUT=/root/gpu-ab-bench/kv-quant.out
: >"$OUT"; exec >>"$OUT" 2>&1
LC=/opt/llamacpp/current
M=/models/hf/Qwen3.8-27B-UD-Q5_K_XL.gguf
D=/models/hf/Qwen3.8-27B-MTP-ONLY-Q8_0.gguf
P=/models/hf/Qwen3.8-27B-mmproj-F16.gguf

pct exec 123 -- systemctl stop llama-swap || true
sleep 5

run() { # <label> <ctx> <cache-type or "f16">
  local label="$1" ctx="$2" ct="$3"
  local extra=()
  [ "$ct" = f16 ] || extra=(--cache-type-k "$ct" --cache-type-v "$ct")
  echo "=== $label : ctx=$ctx cache=$ct ==="
  pct exec 123 -- env LD_LIBRARY_PATH="$LC" VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json \
    "$LC/llama-server" --model "$M" --host 127.0.0.1 --port 5997 --n-gpu-layers 99 \
    --ctx-size "$ctx" --parallel 1 --flash-attn on --batch-size 4096 --ubatch-size 1024 \
    --jinja --reasoning-format auto --metrics --n-predict 32768 --alias kv \
    --spec-type draft-mtp --model-draft "$D" --spec-draft-n-max 2 --spec-draft-ngl 99 \
    --mmproj "$P" "${extra[@]}" >/root/gpu-ab-bench/kv-$label.log 2>&1 &
  local i=0
  until pct exec 123 -- curl -sf http://127.0.0.1:5997/health >/dev/null 2>&1; do
    sleep 5; i=$((i+5))
    if [ $i -gt 420 ]; then
      echo "  !! never healthy — likely OOM/over-commit. tail:"; tail -6 /root/gpu-ab-bench/kv-"$label".log | sed 's/^/     /'
      pct exec 123 -- pkill -f "port 5997" || true; sleep 5; return
    fi
  done
  local d=/sys/bus/pci/devices/0000:06:00.0
  printf '  VRAM %.2f GiB of 29.98 | GTT %.2f GiB%s\n' \
    "$(python3 -c "print($(cat $d/mem_info_vram_used)/1024**3)")" \
    "$(python3 -c "print($(cat $d/mem_info_gtt_used)/1024**3)")" \
    "$(python3 -c "print('   <-- GTT SPILL, decode will collapse' if $(cat $d/mem_info_gtt_used) > 2147483648 else '')")"
  pct exec 123 -- python3 /root/kv-probe.py http://127.0.0.1:5997 kv
  pct exec 123 -- pkill -f "port 5997" || true
  sleep 8
}

run f16-64k    65536  f16
run q8-64k     65536  q8_0
run q8-128k   131072  q8_0

pct exec 123 -- systemctl start llama-swap || true
sleep 5
echo "=== done (llama-swap restored: $(pct exec 123 -- systemctl is-active llama-swap)) ==="
