#!/usr/bin/env bash
# Speculative-decoding A/B on CT 120's own card. Proxmox HOST, root.
#
# Stops the production `llamacpp` unit, then loads each arm in turn as a transient unit
# (`llamacpp-ab`) with the production flags plus the arm's spec flags, and runs
# spec-probe.py against it. Arms rotate every repetition so drift spreads evenly.
# An EXIT trap restarts production whatever happens.
#
# Needs BASE (unsloth/Qwen3.6-35B-A3B-GGUF@a483e9e6, sha256 25233af7...), MTP (the
# production file) and DFLASH (Alittlehammmer/Qwen3.6-35B-A3B-DFlash-GGUF-llama.cpp@2aa57b64,
# Q8_0, sha256 724ac8a1...) on CT 120's /models, plus deep-context.txt next to this script:
#   git ls-files -- '*.sh' '*.py' '*.md' | grep -v '^pro-v620/spec-ab/' | sort | while read -r f; do
#     printf '\n===== FILE: %s =====\n' "$f"; cat "$f"; done > pro-v620/spec-ab/deep-context.txt
#
# ⚠️ Hermes loses its model for the whole run. Pause any model-using CT 121 cron that
# would fire inside the window, or the KB refresh quarantines its entries for 14 days.
# ⚠️ The production thermal watchdog stops the `llamacpp` unit, not this one. Run
# qwen38-flash-next/thermal-guard.sh alongside as a unit; this script refuses to start without it:
#   systemd-run --unit=spec-ab-guard -E PATTERNS=llama-server -E LOG=/root/spec-ab/guard.log \
#     bash /root/spec-ab/harness/thermal-guard.sh
set -Eeuo pipefail

CT=120
PCI=0000:03:00.0
REPS="${REPS:-3}"
RUN="${RUN:-/root/spec-ab/run-$(date -u +%Y%m%dT%H%M%SZ)}"
CTDIR=/root/spec-ab
MODELS=/models/hf
BASE="${MODELS}/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"
# The production file since 2026-09-22; BASE is the MTP-less file kept for rollback.
MTP="${MODELS}/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"
DFLASH="${MODELS}/spec-ab/Qwen3.6-35B-A3B-DFlash-Q8_0.gguf"
CTX="${CTX:-262144}"
PARALLEL="${PARALLEL:-2}"

# name|model|extra llama-server args
# q8_0 KV frees ~2.5 GiB at 262k, which is what lets MTP fit without cutting context.
# base-q8 isolates the KV-type change from the speculation change.
Q8="-ctk q8_0 -ctv q8_0"
ARMS=(
  "base|${BASE}|"
  "base-q8|${BASE}|${Q8}"
  "mtp-n2-q8|${MTP}|${Q8} --spec-type draft-mtp --spec-draft-n-max 2"
  "mtp-n3-q8|${MTP}|${Q8} --spec-type draft-mtp --spec-draft-n-max 3"
  "mtp-n4-q8|${MTP}|${Q8} --spec-type draft-mtp --spec-draft-n-max 4"
  "dflash-n6-q8|${BASE}|${Q8} -ctkd q8_0 -ctvd q8_0 --spec-type draft-dflash --model-draft ${DFLASH} --spec-draft-ngl 99 --spec-draft-n-max 6"
)
# Prefill isolation: is q8_0's deep-prefill gain the KV type, or relief from the near-full
# card at 262k? The same KV types at half the context separate the two. An arm's `-c`
# comes after the global one, and llama-server takes the last value.
if [ "${ARM_SET:-spec}" = prefill ]; then
  ARMS=(
    "f16-262k|${BASE}|"
    "q8-262k|${BASE}|${Q8}"
    "f16-131k|${BASE}|-c 131072"
    "q8-131k|${BASE}|${Q8} -c 131072"
  )
fi
if [ -n "${ONLY:-}" ]; then
  mapfile -t ARMS < <(printf '%s\n' "${ARMS[@]}" | grep -E "^(${ONLY})\|")
fi

say() { printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "${RUN}/driver.log"; }

gpu_state() {
  local d="/sys/bus/pci/devices/${PCI}" h
  for h in "${d}"/hwmon/hwmon*; do break; done
  printf 'vram_mib=%d gtt_mib=%d junction_c=%d mem_c=%d' \
    $(( $(cat "${d}/mem_info_vram_used") / 1048576 )) \
    $(( $(cat "${d}/mem_info_gtt_used") / 1048576 )) \
    $(( $(cat "${h}/temp2_input") / 1000 )) $(( $(cat "${h}/temp3_input") / 1000 ))
}

stop_arm() { pct exec "$CT" -- systemctl stop llamacpp-ab 2>/dev/null || true
             pct exec "$CT" -- systemctl reset-failed llamacpp-ab 2>/dev/null || true; }

start_arm() {
  local model="$1" extra="$2"
  # shellcheck disable=SC2086  # $extra is a deliberate word list of flags
  pct exec "$CT" -- systemd-run --unit=llamacpp-ab --uid=llamacpp --gid=llamacpp \
    -p Environment=HOME=/home/llamacpp \
    -p Environment=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json \
    -p Environment=LD_LIBRARY_PATH=/opt/llamacpp/current \
    /opt/llamacpp/current/llama-server --model "$model" --host 0.0.0.0 --port 1234 \
    --n-gpu-layers 99 --ctx-size "$CTX" --parallel "$PARALLEL" --flash-attn on \
    --batch-size 4096 --ubatch-size 1024 --jinja --reasoning-format auto --reasoning off \
    --cache-ram 0 --metrics --alias ab $extra >/dev/null
}

wait_up() {
  local t=0
  until pct exec "$CT" -- curl -fsS -m 4 http://127.0.0.1:1234/health >/dev/null 2>&1; do
    pct exec "$CT" -- systemctl is-active --quiet llamacpp-ab || return 1
    sleep 5; t=$((t + 5)); [ "$t" -ge 900 ] && return 1
  done
  say "    up in ${t}s"
}

restore() {
  local rc=$?
  stop_arm
  say "restoring production llamacpp (exit ${rc})"
  pct exec "$CT" -- systemctl start llamacpp
  local t=0
  until pct exec "$CT" -- curl -fsS -m 4 http://127.0.0.1:1234/health >/dev/null 2>&1; do
    sleep 5; t=$((t + 5)); [ "$t" -ge 600 ] && { say "🔴 production NOT healthy after 600s"; exit 1; }
  done
  say "production healthy after ${t}s"
}

main() {
  mkdir -p "$RUN"
  systemctl is-active --quiet spec-ab-guard || { echo "FATAL: spec-ab-guard (thermal-guard.sh) not active" >&2; exit 1; }
  local gov; gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
  [ "$gov" = schedutil ] || { echo "FATAL: CPU governor is ${gov}, expected schedutil" >&2; exit 1; }
  for f in "$BASE" "$MTP" "$DFLASH"; do pct exec "$CT" -- test -r "$f" || { echo "FATAL: missing $f" >&2; exit 1; }; done
  pct exec "$CT" -- mkdir -p "$CTDIR"
  pct push "$CT" "$(dirname "$0")/spec-probe.py" "${CTDIR}/spec-probe.py"
  pct push "$CT" "$(dirname "$0")/deep-context.txt" "${CTDIR}/deep-context.txt"
  local out
  out="${CTDIR}/$(basename "$RUN").jsonl"

  say "run=${RUN} reps=${REPS} ctx=${CTX} parallel=${PARALLEL} arms=${#ARMS[@]} build=$(pct exec "$CT" -- readlink -f /opt/llamacpp/current)"
  trap restore EXIT
  pct exec "$CT" -- systemctl stop llamacpp

  local rep i n=${#ARMS[@]} name model extra since
  for rep in $(seq 1 "$REPS"); do
    for i in $(seq 0 $((n - 1))); do
      IFS='|' read -r name model extra <<<"${ARMS[$(( (i + rep - 1) % n ))]}"
      say "rep ${rep} arm ${name}"
      stop_arm
      since="@$(date +%s)"
      start_arm "$model" "$extra"
      if ! wait_up; then
        say "    🔴 ${name} failed to load"
        pct exec "$CT" -- journalctl -u llamacpp-ab --no-pager --since "$since" >"${RUN}/${name}-rep${rep}-fail.log" 2>&1 || true
        continue
      fi
      say "    loaded: $(gpu_state) n_ctx=$(pct exec "$CT" -- curl -s http://127.0.0.1:1234/props | python3 -c 'import json,sys; print(json.load(sys.stdin)["default_generation_settings"]["n_ctx"])' 2>/dev/null)"
      # shellcheck disable=SC2086  # PROBE_ARGS is a deliberate word list of flags
      pct exec "$CT" -- python3 "${CTDIR}/spec-probe.py" --arm "$name" --rep "$rep" \
        --deep-file "${CTDIR}/deep-context.txt" --out "$out" ${PROBE_ARGS:-} 2>&1 | tee -a "${RUN}/driver.log" \
        || say "    🔴 probe failed"
      say "    after: $(gpu_state)"
      pct exec "$CT" -- journalctl -u llamacpp-ab --no-pager -o cat --since "$since" >"${RUN}/${name}-rep${rep}.log" 2>&1 || true
    done
  done
  pct pull "$CT" "$out" "${RUN}/results.jsonl"
  say "done: ${RUN}/results.jsonl"
}

main "$@"
