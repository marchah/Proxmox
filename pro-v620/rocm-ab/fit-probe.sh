#!/usr/bin/env bash
# Which two-slot coder configurations fit in VRAM? Proxmox HOST, root, with the card already in
# VM 301 (card.sh to-vm) and CT 123's model service stopped.
#
# Loads each configuration as a llama-server in the guest, waits for /health or failure, and
# prints whether it loaded with VRAM and GTT in use. A load is necessary, not sufficient: deep
# prompts need more scratch space, so run a session before trusting a tight fit.
set -uo pipefail
VMID="${VMID:-301}"
VM="ubuntu@$(qm guest cmd "$VMID" network-get-interfaces | perl -MJSON::PP -e '
  for my $if (@{ decode_json(do { local $/; <STDIN> }) }) { next if $if->{name} eq "lo";
    for my $a (@{ $if->{"ip-addresses"} || [] }) {
      if ($a->{"ip-address-type"} eq "ipv4") { print $a->{"ip-address"}; exit 0 } } } exit 1')"
v(){ ssh -o BatchMode=yes "$VM" "sudo $(printf '%q ' "$@")"; }
M=/models/Qwen3.8-27B-UD-Q4_K_XL.gguf
Q8=/models/Qwen3.8-27B-MTP-ONLY-Q8_0.gguf; Q6=/models/Qwen3.8-27B-MTP-ONLY-Q6_K.gguf
mtp(){ echo "--spec-type draft-mtp --model-draft $1 --spec-draft-n-max 2 --spec-draft-ngl 99 -ctkd q8_0 -ctvd q8_0"; }
# label|backend|ctx|ub|extra
CONFIGS=(
  "vk mtp Q8 2x128k|vk|262144|1024|$(mtp $Q8)"
  "rocm mtp Q8 2x128k|rocm|262144|1024|$(mtp $Q8)"
  "rocm mtp Q6 2x128k|rocm|262144|1024|$(mtp $Q6)"
  "vk mtp Q6 2x128k|vk|262144|1024|$(mtp $Q6)"
  "rocm mtp Q8 2x112k|rocm|229376|1024|$(mtp $Q8)"
  "rocm mtp Q8 2x96k|rocm|196608|1024|$(mtp $Q8)"
)
for c in "${CONFIGS[@]}"; do
  IFS='|' read -r label b ctx ub extra <<<"$c"
  if [ "$b" = vk ]; then bin=/opt/rocm-ab/llama-b11018-vulkan; env=(-p "Environment=LD_LIBRARY_PATH=$bin" -p Environment=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json)
  else bin=/opt/rocm-ab/llama-b11018-rocm; env=(-p "Environment=LD_LIBRARY_PATH=$bin:/opt/rocm/core-10.0/lib"); fi
  v systemctl stop llamacpp-fit >/dev/null 2>&1; v systemctl reset-failed llamacpp-fit >/dev/null 2>&1
  # shellcheck disable=SC2086
  v systemd-run --unit=llamacpp-fit "${env[@]}" "$bin/llama-server" --model "$M" --host 127.0.0.1 --port 1234 \
    --n-gpu-layers 99 --ctx-size "$ctx" --parallel 2 --flash-attn on --batch-size 4096 --ubatch-size "$ub" \
    -ctk q8_0 -ctv q8_0 --jinja --reasoning-format auto --reasoning off --cache-ram 0 $extra >/dev/null
  t=0; ok=no
  while [ $t -lt 240 ]; do
    if v curl -fsS -m 3 http://127.0.0.1:1234/health >/dev/null 2>&1; then ok=yes; break; fi
    v systemctl is-active --quiet llamacpp-fit || break
    sleep 4; t=$((t + 4))
  done
  # shellcheck disable=SC2016  # expands in the guest
  mem=$(v sh -c 'for d in /sys/class/drm/card*/device; do [ "$(cat $d/vendor 2>/dev/null)" = 0x1002 ] || continue
    echo "vram=$(( $(cat $d/mem_info_vram_used)/1048576 )) MiB gtt=$(( $(cat $d/mem_info_gtt_used)/1048576 )) MiB"; break; done')
  err=""; [ "$ok" = no ] && err=$(v journalctl -u llamacpp-fit --no-pager -o cat -n 60 | grep -m1 -oE "allocating [0-9.]+ MiB.*out of memory|failed to allocate [^,]*" || true)
  printf '%-30s loaded=%-3s %s %s\n' "$label" "$ok" "$mem" "${err:+($err)}"
done
v systemctl stop llamacpp-fit >/dev/null 2>&1
