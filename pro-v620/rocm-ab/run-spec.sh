#!/usr/bin/env bash
# MTP speculative decoding, Vulkan vs ROCm, in VM 301 on GPU 2 (0000:83:00.0). Proxmox HOST, root.
#
# Each arm is a llama-server with CT 120's production flags (262k context, 2 slots, q8_0 KV,
# FA, batch 4096, ubatch 1024, reasoning off, no prompt cache), started in the guest as a
# transient unit and measured by ../spec-ab/spec-probe.py: short prompts greedy and sampled,
# two concurrent streams, 16k/48k deep contexts and a tool call. Each backend has a
# non-speculative control and MTP at draft lengths 2, 3 and 4, since the best length can
# differ by backend. Arms rotate every repetition so drift spreads evenly.
#
# On exit the card returns to the host and CT 123's model service is re-enabled.
#
#   systemd-run --unit=rocm-ab-spec --collect bash rocm-ab/run-spec.sh
#   ONLY='vk/mtp-n3-q8|rocm/mtp-n3-q8' REPS=1 ...      # a smoke subset
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
VMID="${VMID:-301}"
CT="${CT:-123}"; CT_SERVICE="${CT_SERVICE:-llamacpp-qwen38fn}"
REPS="${REPS:-3}"
RUN="${RUN:-/root/rocm-ab/results/spec-$(date -u +%Y%m%dT%H%M%SZ)}"
CTX="${CTX:-262144}"; PARALLEL="${PARALLEL:-2}"
# ubatch per backend. ROCm cannot place buffers in GTT the way RADV does, so at 262k with
# MTP it runs out of VRAM at ubatch 1024 on the first deep prompt; 512 is the most that fits,
# and is what the README's Phase 4 figures used. Vulkan keeps CT 120's production 1024.
UB_VK="${UB_VK:-1024}"; UB_ROCM="${UB_ROCM:-512}"
export AB_OFFSET_MV="${AB_OFFSET_MV:-0}"
SPEC=/opt/rocm-ab/spec
BASE=/models/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf
MTP=/models/Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL.gguf
VK=/opt/rocm-ab/llama-b11018-vulkan
ROCM=/opt/rocm-ab/llama-b11018-rocm
ROCM_LIB=/opt/rocm/core-10.0/lib

# name|backend|model|extra llama-server args
Q8="-ctk q8_0 -ctv q8_0"
ARMS=()
for b in vk rocm; do
  ARMS+=("${b}/base-q8|${b}|${BASE}|${Q8}")
  for n in 2 3 4; do
    ARMS+=("${b}/mtp-n${n}-q8|${b}|${MTP}|${Q8} --spec-type draft-mtp --spec-draft-n-max ${n}")
  done
done
if [ -n "${ONLY:-}" ]; then
  mapfile -t ARMS < <(printf '%s\n' "${ARMS[@]}" | grep -E "^(${ONLY})\|")
fi

mkdir -p "$RUN"
exec > >(tee -a "${RUN}/driver.log") 2>&1
say(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die(){ say "FATAL: $*"; exit 1; }

# ssh joins its arguments into one remote command line, so quote each one for the remote shell.
vm(){ local ip
  ip=$(qm guest cmd "$VMID" network-get-interfaces | perl -MJSON::PP -e '
    for my $if (@{ decode_json(do { local $/; <STDIN> }) }) { next if $if->{name} eq "lo";
      for my $a (@{ $if->{"ip-addresses"} || [] }) {
        if ($a->{"ip-address-type"} eq "ipv4") { print $a->{"ip-address"}; exit 0 } } } exit 1')
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 "ubuntu@${ip}" "sudo $(printf '%q ' "$@")"; }

# shellcheck disable=SC2016  # expands in the guest
gpu_state(){ vm sh -c 'for d in /sys/class/drm/card*/device; do [ "$(cat $d/vendor 2>/dev/null)" = 0x1002 ] || continue
  h=$(ls -d $d/hwmon/hwmon* | head -1)
  echo "vram_mib=$(( $(cat $d/mem_info_vram_used) / 1048576 )) gtt_mib=$(( $(cat $d/mem_info_gtt_used) / 1048576 )) junction_c=$(( $(cat $h/temp2_input) / 1000 ))"; break; done'; }

stop_arm(){ vm systemctl stop llamacpp-ab 2>/dev/null || true; vm systemctl reset-failed llamacpp-ab 2>/dev/null || true; }

start_arm(){ local backend=$1 model=$2 extra=$3 bin env ub
  if [ "$backend" = vk ]; then
    bin="${VK}/llama-server"; ub=$UB_VK
    env=(-p "Environment=LD_LIBRARY_PATH=${VK}" -p Environment=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json)
  else
    bin="${ROCM}/llama-server"; ub=$UB_ROCM
    env=(-p "Environment=LD_LIBRARY_PATH=${ROCM}:${ROCM_LIB}")
  fi
  # shellcheck disable=SC2086  # $extra is a deliberate word list of flags
  vm systemd-run --unit=llamacpp-ab "${env[@]}" "$bin" --model "$model" --host 127.0.0.1 --port 1234 \
    --n-gpu-layers 99 --ctx-size "$CTX" --parallel "$PARALLEL" --flash-attn on \
    --batch-size 4096 --ubatch-size "$ub" --jinja --reasoning-format auto --reasoning off \
    --cache-ram 0 --metrics --alias ab $extra >/dev/null; }

wait_up(){ local t=0
  until vm curl -fsS -m 4 http://127.0.0.1:1234/health >/dev/null 2>&1; do
    vm systemctl is-active --quiet llamacpp-ab || return 1
    sleep 5; t=$((t + 5)); [ "$t" -lt 900 ] || return 1
  done
  say "    up in ${t}s"; }

guard(){ local gpci
  vm systemctl is-active --quiet rocm-ab-guard && return 0
  # shellcheck disable=SC2016  # expands in the guest
  gpci=$(vm sh -c 'for d in /sys/class/drm/card*/device; do [ -d "$d/hwmon" ] && [ "$(cat $d/vendor 2>/dev/null)" = 0x1002 ] && basename "$(readlink -f "$d")"; done | sort -u')
  [ "$(wc -w <<<"$gpci")" = 1 ] || die "guest amdgpu card ambiguous: '${gpci}'"
  vm systemd-run --unit=rocm-ab-guard --collect -E CARDS="$gpci" -E PATTERNS=llama-server -E LIMIT=100 \
    -E LOG=/opt/rocm-ab/guard.log bash /opt/rocm-ab/thermal-guard.sh >/dev/null
  sleep 3; vm systemctl is-active --quiet rocm-ab-guard || die "guest thermal guard did not start"; }

restore(){ local rc=$?
  say "restoring production (exit ${rc})"
  "${HERE}/card.sh" restore || say "🔴 RESTORE FAILED — run card.sh status and restore by hand"; }

main(){
  local gov out rep i n name backend model extra since safe
  gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
  [ "$gov" = schedutil ] || die "CPU governor is ${gov}, expected schedutil"
  say "run=${RUN} reps=${REPS} ctx=${CTX} parallel=${PARALLEL} ubatch vk=${UB_VK} rocm=${UB_ROCM} arms=${#ARMS[@]} offset=${AB_OFFSET_MV}mV"
  trap restore EXIT
  if grep -q running <<<"$(pct status "$CT")"; then pct exec "$CT" -- systemctl disable --now "$CT_SERVICE"; fi
  grep -q running <<<"$(qm status "$VMID")" || "${HERE}/card.sh" to-vm
  for f in "$BASE" "$MTP" "${SPEC}/spec-probe.py" "${SPEC}/deep-context.txt" "${VK}/llama-server" "${ROCM}/llama-server"; do
    vm test -r "$f" || die "missing in the guest: ${f}"
  done
  guard
  out="${SPEC}/$(basename "$RUN").jsonl"
  n=${#ARMS[@]}
  for rep in $(seq 1 "$REPS"); do
    for i in $(seq 0 $((n - 1))); do
      IFS='|' read -r name backend model extra <<<"${ARMS[$(( (i + rep - 1) % n ))]}"
      safe=${name//\//_}
      say "rep ${rep} arm ${name}"
      stop_arm
      since="@$(date +%s)"
      start_arm "$backend" "$model" "$extra"
      if ! wait_up; then
        say "    🔴 ${name} failed to load"
        vm journalctl -u llamacpp-ab --no-pager -o cat --since "$since" >"${RUN}/${safe}-rep${rep}-fail.log" 2>&1 || true
        continue
      fi
      say "    loaded: $(gpu_state)"
      vm python3 "${SPEC}/spec-probe.py" --arm "$name" --rep "$rep" --deep-file "${SPEC}/deep-context.txt" \
        --out "$out" || say "    🔴 probe failed"
      say "    after: $(gpu_state)"
      vm journalctl -u llamacpp-ab --no-pager -o cat --since "$since" >"${RUN}/${safe}-rep${rep}.log" 2>&1 || true
    done
  done
  stop_arm
  vm cat "$out" >"${RUN}/results.jsonl"
  say "done: ${RUN}/results.jsonl ($(wc -l <"${RUN}/results.jsonl") rows)"
}

main "$@"
