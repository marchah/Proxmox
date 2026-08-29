#!/usr/bin/env bash
# Give Qwen3.8-27B (dense) the same rigorous two-GPU A/B the MoE got: llama-bench,
# prefill + decode + depth, 3 interleaved rounds in alternating order.
# Both devices driven from CT 123, so binary/model-file/flags are identical and the
# ONLY variable is --device.  Vulkan1 = GPU 1 (2d, Gen4 x16), Vulkan0 = GPU 2 (06, Gen3 x4).
set -Eeuo pipefail
OUT="${BENCH_DIR:-/root/gpu-ab-bench}/q38"
LC=/opt/llamacpp/current
MODEL=/models/hf/Qwen3.8-27B-UD-Q5_K_XL.gguf
mkdir -p "$OUT"
PHASES="$OUT/phases.jsonl"
COMMON=(-m "$MODEL" -ngl 99 -fa 1 -b 4096 -ub 1024)

dev_of(){ case "$1" in gpu1) echo Vulkan1;; gpu2) echo Vulkan0;; esac; }

bench(){ # <gpu> <phase> <args...>
  local g="$1" phase="$2"; shift 2
  local tag="${phase}.${g}" dev; dev="$(dev_of "$g")"
  local t0; t0="$(date +%s.%N)"
  echo ">>> [$(date -u +%H:%M:%S)] $tag  (device $dev)  $*"
  set +e
  pct exec 123 -- env LD_LIBRARY_PATH="$LC" \
    VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json \
    "$LC/llama-bench" "${COMMON[@]}" -dev "$dev" "$@" -o json \
    >"$OUT/${tag}.json" 2>"$OUT/${tag}.err"
  local rc=$?; set -e
  local t1; t1="$(date +%s.%N)"
  # placement is proven from the telemetry JSONL (vram_used per PCI address)
  printf '{"phase":"%s","gpu":"%s","dev":"%s","args":"%s","start":%s,"end":%s,"rc":%s}\n' \
    "$phase" "$g" "$dev" "$*" "$t0" "$t1" "$rc" >>"$PHASES"
  [ "$rc" -eq 0 ] || echo "  !! rc=$rc see ${tag}.err" >&2
}

: >"$PHASES"
echo "=== Qwen3.8-27B dense: core A/B, 3 interleaved rounds ==="
for r in 1 2 3; do
  if (( r % 2 == 1 )); then order=(gpu1 gpu2); else order=(gpu2 gpu1); fi
  for g in "${order[@]}"; do bench "$g" "core-r${r}" -p 512,4096 -n 128 -r 3; sleep 40; done
done
echo "=== decode at depth ==="
for g in gpu1 gpu2; do bench "$g" depth -n 128 -d 8192,32768 -r 2; sleep 60; done
echo "=== q38 done ==="
