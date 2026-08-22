#!/usr/bin/env bash
# Interleaved A/B of the two Radeon Pro V620s on the SAME model/build/flags.
#   GPU 1 = 0000:2d:00.0 (PCIe-1, CPU slot)   -> CT 120
#   GPU 2 = 0000:06:00.0 (PCIe-3, chipset)    -> CT 123
# Rounds alternate card order so thermal drift cannot favour whichever ran first.
set -Eeuo pipefail

OUT="${BENCH_DIR:-/root/gpu-ab-bench}"
MODEL=/models/hf/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf
LC=/opt/llamacpp/current
# Match the production llamacpp-serve / llamaswap-guarded-serve flags.
COMMON=(-m "$MODEL" -ngl 99 -fa 1 -b 4096 -ub 1024)
ROUNDS="${ROUNDS:-3}"
PHASES="$OUT/phases.jsonl"

# gpu label -> CT id
ct_of() { case "$1" in gpu1) echo 120 ;; gpu2) echo 123 ;; esac; }

bench() {  # bench <gpu-label> <phase-name> <extra llama-bench args...>
  local gpu="$1" phase="$2"; shift 2
  local ct; ct="$(ct_of "$gpu")"
  local tag="${phase}.${gpu}"
  local start; start="$(date +%s.%N)"
  echo ">>> [$(date -u +%H:%M:%S)] $tag  (CT $ct)  args: $*"
  set +e
  pct exec "$ct" -- env \
      LD_LIBRARY_PATH="$LC" \
      VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json \
      "$LC/llama-bench" "${COMMON[@]}" "$@" -o json \
      >"$OUT/${tag}.json" 2>"$OUT/${tag}.err"
  local rc=$?
  set -e
  local end; end="$(date +%s.%N)"
  printf '{"phase":"%s","gpu":"%s","ct":%s,"args":"%s","start":%s,"end":%s,"rc":%s}\n' \
    "$phase" "$gpu" "$ct" "$*" "$start" "$end" "$rc" >>"$PHASES"
  [ "$rc" -eq 0 ] || echo "!!! $tag exited $rc — see ${tag}.err" >&2
}

main() {
  : >"$PHASES"
  echo "=== core A/B: prefill 512/4096 + decode 128, ${ROUNDS} interleaved rounds ==="
  for r in $(seq 1 "$ROUNDS"); do
    # alternate which card goes first each round
    if (( r % 2 == 1 )); then order=(gpu1 gpu2); else order=(gpu2 gpu1); fi
    for g in "${order[@]}"; do
      bench "$g" "core-r${r}" -p 512,4096 -n 128 -r 3
      sleep 45   # let the card return toward idle so each round starts alike
    done
  done

  echo "=== decode at depth (8k / 32k) ==="
  for g in gpu1 gpu2; do
    bench "$g" "depth" -n 128 -d 8192,32768 -r 2
    sleep 60
  done

  echo "=== thermal soak: repeated 32k prefill (the hottest phase) ==="
  for g in gpu1 gpu2; do
    bench "$g" "soak" -p 32768 -n 128 -r 3
    sleep 90
  done
  echo "=== done ==="
}
main "$@"
