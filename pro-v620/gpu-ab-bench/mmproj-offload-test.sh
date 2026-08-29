#!/usr/bin/env bash
# Projector on GPU (default) vs on CPU (--no-mmproj-offload). Text-only throughput is
# already known to be unaffected by loading the projector at all, so this measures the
# thing that actually differs: IMAGE request latency, and the VRAM it buys back.
set -Eeuo pipefail
OUT=/root/gpu-ab-bench/mmproj-offload.out
: >"$OUT"; exec >>"$OUT" 2>&1
LC=/opt/llamacpp/current
M=/models/hf/Qwen3.8-27B-UD-Q5_K_XL.gguf
D=/models/hf/Qwen3.8-27B-MTP-ONLY-Q8_0.gguf
P=/models/hf/Qwen3.8-27B-mmproj-F16.gguf
pct exec 123 -- systemctl stop llama-swap || true; sleep 5

run() { # <label> [extra flags...]
  local label="$1"; shift
  echo "=== $label ==="
  pct exec 123 -- env LD_LIBRARY_PATH="$LC" VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json \
    "$LC/llama-server" --model "$M" --host 127.0.0.1 --port 5995 --n-gpu-layers 99 \
    --ctx-size 65536 --parallel 1 --flash-attn on --batch-size 4096 --ubatch-size 1024 \
    --jinja --reasoning-format auto --metrics --n-predict 32768 --alias mm \
    --spec-type draft-mtp --model-draft "$D" --spec-draft-n-max 2 --spec-draft-ngl 99 \
    --mmproj "$P" "$@" >/root/gpu-ab-bench/mm-"$label".log 2>&1 &
  local i=0
  until pct exec 123 -- curl -sf http://127.0.0.1:5995/health >/dev/null 2>&1; do
    sleep 5; i=$((i+5)); [ $i -gt 420 ] && { echo "  !! not healthy"; tail -5 /root/gpu-ab-bench/mm-"$label".log | sed 's/^/     /'; pct exec 123 -- pkill -f "port 5995" || true; sleep 5; return; }
  done
  local d=/sys/bus/pci/devices/0000:06:00.0
  printf '  VRAM %.2f GiB | GTT %.2f GiB\n' \
    "$(python3 -c "print($(cat $d/mem_info_vram_used)/1024**3)")" \
    "$(python3 -c "print($(cat $d/mem_info_gtt_used)/1024**3)")"
  pct exec 123 -- python3 /root/mmproj-probe.py http://127.0.0.1:5995 mm 3
  pct exec 123 -- pkill -f "port 5995" || true
  sleep 8
}

run gpu-offload
run cpu-offload --no-mmproj-offload

pct exec 123 -- systemctl start llama-swap || true; sleep 5
echo "=== done (llama-swap: $(pct exec 123 -- systemctl is-active llama-swap)) ==="
