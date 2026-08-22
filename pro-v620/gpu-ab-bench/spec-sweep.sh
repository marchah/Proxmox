#!/usr/bin/env bash
# Speculative-decoding sweep across BOTH V620s from ONE container (CT 123), so the only
# variable is the selected Vulkan device. Needs ct123-dual-gpu.sh add first.
#
#   Vulkan0 -> pciBus 6  (0000:06:00.0) = GPU 2, chipset PCIe-3, Gen3 x4
#   Vulkan1 -> pciBus 45 (0000:2d:00.0) = GPU 1, CPU PCIe-1,     Gen4 x16
#
# n-max is a STARTUP flag and the n>=8 cliff is exactly what is under test, so each n-max
# gets its own server start rather than a per-request override (which llama.cpp may clamp
# to the startup value, and which would allocate draft buffers for the largest n anyway).
# Target-outer ordering keeps the 20 GB target file in page cache across its runs.
set -Eeuo pipefail

CT=123
BENCH_DIR="${BENCH_DIR:-/root/gpu-ab-bench}"
OUT="$BENCH_DIR/spec"
LC=/opt/llamacpp/current
PORT=5999
CTX="${CTX:-65536}"
NPREDICT="${NPREDICT:-512}"
mkdir -p "$OUT"
RESULTS="$OUT/results.jsonl"

DEV_GPU1=Vulkan1   # 2d:00.0  Gen4 x16
DEV_GPU2=Vulkan0   # 06:00.0  Gen3 x4

declare -a CONFIGS=(
  "mtp|/models/hf/Qwen3.8-27B-UD-Q5_K_XL.gguf|/models/hf/Qwen3.8-27B-MTP-ONLY-Q8_0.gguf|draft-mtp"
  "dflash|/models/hf/Qwen3.6-27B-UD-Q5_K_XL.gguf|/models/hf/Qwen3.6-27B-DFlash-Q8_0.gguf|draft-dflash"
)
NMAX_LIST="${NMAX_LIST:-2 3 4 6 8}"

stop_server() {
  pkill -f "llama-server .*--port ${PORT}" 2>/dev/null || true
  local i=0
  while pgrep -f "llama-server .*--port ${PORT}" >/dev/null && [ $i -lt 90 ]; do sleep 1; i=$((i+1)); done
  sleep 3
}

start_server() {  # <device> <target> [drafter] [spec-type] [n_max]
  local dev="$1" target="$2" drafter="${3:-}" stype="${4:-}" nmax="${5:-}"
  local args=(--model "$target" --host 127.0.0.1 --port "$PORT" --device "$dev"
              --n-gpu-layers 99 --ctx-size "$CTX" --parallel 1 --flash-attn on
              --batch-size 4096 --ubatch-size 1024 --jinja --reasoning-format none
              --metrics --alias probe)
  if [ -n "$drafter" ]; then
    args+=(--spec-type "$stype" --spec-draft-model "$drafter" --spec-draft-ngl 99)
    [ -n "$nmax" ] && args+=(--spec-draft-n-max "$nmax")
  fi
  pct exec "$CT" -- env LD_LIBRARY_PATH="$LC" \
      VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json \
      "$LC/llama-server" "${args[@]}" >"$OUT/server.log" 2>&1 &
  local i=0
  until pct exec "$CT" -- curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; do
    sleep 3; i=$((i+3))
    if [ $i -gt 600 ]; then echo "  !! not healthy in 600s" >&2; return 1; fi
  done
  # MUST be explicit: an until/while loop returns the status of the LAST command run in
  # its body, so the false n-max guard above would otherwise make this function return 1
  # on a perfectly healthy server.
  return 0
}

# Which physical card actually took the load? Proven from host sysfs, never assumed.
busy_card() {
  local g1 g2
  g1=$(cat /sys/bus/pci/devices/0000:2d:00.0/mem_info_vram_used)
  g2=$(cat /sys/bus/pci/devices/0000:06:00.0/mem_info_vram_used)
  # whichever holds > 5 GiB is the one running the model
  if [ "$g1" -gt 5368709120 ] && [ "$g2" -gt 5368709120 ]; then echo "BOTH"
  elif [ "$g1" -gt 5368709120 ]; then echo "gpu1"
  elif [ "$g2" -gt 5368709120 ]; then echo "gpu2"
  else echo "none"; fi
}

run_one() {  # <device> <gpu-label> <cfg> <target> <drafter> <stype> <nmax>
  local dev="$1" glabel="$2" cfg="$3" target="$4" drafter="$5" stype="$6" nmax="$7"
  local tag="${cfg}.${glabel}.n${nmax:-base}"
  echo ">>> [$(date -u +%H:%M:%S)] $tag  (device $dev)"
  stop_server
  local t0; t0="$(date +%s.%N)"
  if ! start_server "$dev" "$target" "$drafter" "$stype" "$nmax"; then
    printf '{"tag":"%s","gpu":"%s","config":"%s","n_max":"%s","error":"unhealthy"}\n' \
      "$tag" "$glabel" "$cfg" "${nmax:-base}" >>"$RESULTS"
    cp "$OUT/server.log" "$OUT/${tag}.serverlog"; return
  fi
  local t1; t1="$(date +%s.%N)"
  local placed; placed="$(busy_card)"
  pct exec "$CT" -- python3 /root/spec-probe.py "http://127.0.0.1:${PORT}" - "$NPREDICT" \
      >"$OUT/${tag}.probe.json" 2>"$OUT/${tag}.probeerr" || true
  local t2; t2="$(date +%s.%N)"
  python3 "$BENCH_DIR/merge-row.py" "$tag" "$glabel" "$cfg" "${nmax:-base}" \
      "$t0" "$t1" "$t2" "$placed" "$OUT/${tag}.probe.json" "$RESULTS"
  cp "$OUT/server.log" "$OUT/${tag}.serverlog"
  stop_server
}

main() {
  : >"$RESULTS"
  # The probe runs INSIDE the container (it talks to 127.0.0.1), so push it in rather than
  # assuming a copy is already there.
  for f in spec-probe.py spec-probe-text.py; do
    [ -f "$BENCH_DIR/$f" ] || { echo "missing $BENCH_DIR/$f" >&2; exit 1; }
    pct push "$CT" "$BENCH_DIR/$f" "/root/$f" --perms 755
  done
  if [ -n "${SMOKE:-}" ]; then
    echo "=== SMOKE: one run (mtp / gpu1 / n-max 2) to validate the harness ==="
    run_one "$DEV_GPU1" gpu1 mtp /models/hf/Qwen3.8-27B-UD-Q5_K_XL.gguf \
            /models/hf/Qwen3.8-27B-MTP-ONLY-Q8_0.gguf draft-mtp 2
    echo "=== smoke done ==="; return 0
  fi
  for entry in "${CONFIGS[@]}"; do
    IFS='|' read -r cfg target drafter stype <<<"$entry"
    echo "=== $cfg : target $(basename "$target") drafter $(basename "$drafter") ==="
    # GPU_LIST selects which cards to sweep, e.g. GPU_LIST="Vulkan0:gpu2" for GPU 2 only
    # (which needs no dual-GPU setup and leaves CT 120 serving).
    for pair in ${GPU_LIST:-"$DEV_GPU1:gpu1" "$DEV_GPU2:gpu2"}; do
      IFS=':' read -r dev glabel <<<"$pair"
      run_one "$dev" "$glabel" "$cfg" "$target" "" "" ""       # unaccelerated baseline
      for n in $NMAX_LIST; do
        run_one "$dev" "$glabel" "$cfg" "$target" "$drafter" "$stype" "$n"
      done
    done
  done
  echo "=== spec sweep done ==="
}
main "$@"
