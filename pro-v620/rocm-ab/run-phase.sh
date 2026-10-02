#!/usr/bin/env bash
# One gated phase of the Vulkan/ROCm A/B on GPU 2 (0000:83:00.0). Proxmox HOST, root.
#
#   run-phase.sh <phase> <X> <Y>          e.g.  run-phase.sh p1 A B
#
#   A  Vulkan in CT 123 — the host's in-tree amdgpu and the production Mesa
#   B  Vulkan in VM 301 — AMD's amdgpu-dkms, same Mesa
#   C  ROCm 10.0 in VM 301 — same amdgpu-dkms
#
# Three rounds, X Y | Y X | X Y: a linear drift cancels, and the card changes sides only
# three times. Round 1 also runs the perplexity gate. Results land in
# ${RESULTS_ROOT}/<phase>/r<round>-<setup>/. When the phase finishes or fails, production is
# restored: the card returns to the host and CT 123's model service is re-enabled.
# `systemctl stop` on the unit kills that restore along with the run; follow it with card.sh restore.
#
# Run it as a unit so it survives the SSH session:
#   systemd-run --unit=rocm-ab-p1 --collect bash /root/rocm-ab/src/rocm-ab/run-phase.sh p1 A B
set -Eeuo pipefail

phase=$1 X=$2 Y=$3
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SRC="$(dirname "$HERE")"
ROOT="${ROOT:-/root/rocm-ab}"
RESULTS_ROOT="${RESULTS_ROOT:-${ROOT}/results}"
MNT="${MNT:-/mnt/rocm-ab-models}"
CT="${CT:-123}"; CT_SERVICE="${CT_SERVICE:-llamacpp-qwen38fn}"; VMID="${VMID:-301}"
PCI="${PCI:-0000:83:00.0}"
TAG=b11018
MOE=Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf
DENSE=Qwen3.8-27B-UD-Q5_K_XL.gguf
GUARD_PATTERNS="llama-bench llama-batched-bench llama-perplexity"
SMOKE="${SMOKE:-0}"
export AB_OFFSET_MV="${AB_OFFSET_MV:-0}"

out="${RESULTS_ROOT}/${phase}"; mkdir -p "$out"
exec > >(tee -a "${out}/phase.log") 2>&1
say(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die(){ say "FATAL: $*"; exit 1; }
card(){ "${HERE}/card.sh" "$@"; }
for s in "$X" "$Y"; do case $s in A|B|C) ;; *) die "unknown setup ${s}" ;; esac; done

vm(){ local ip
  ip=$(qm guest cmd "$VMID" network-get-interfaces | perl -MJSON::PP -e '
    for my $if (@{ decode_json(do { local $/; <STDIN> }) }) { next if $if->{name} eq "lo";
      for my $a (@{ $if->{"ip-addresses"} || [] }) {
        if ($a->{"ip-address-type"} eq "ipv4") { print $a->{"ip-address"}; exit 0 } } } exit 1')
  # ssh joins its arguments into one remote command line, so quote each one for the remote shell.
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 "ubuntu@${ip}" "sudo $(printf '%q ' "$@")"; }

restore(){ local rc=$?
  systemctl stop rocm-ab-guard 2>/dev/null || true
  say "restoring production (exit ${rc})"
  card restore || say "🔴 RESTORE FAILED — run card.sh status and restore by hand"
  say "phase ${phase} ended (exit ${rc})"; }
trap restore EXIT

host_guard(){
  systemctl is-active --quiet rocm-ab-guard && return 0
  systemd-run --unit=rocm-ab-guard --collect -E CARDS="$PCI" -E PATTERNS="$GUARD_PATTERNS" -E LIMIT=100 \
    -E LOG="${ROOT}/guard-host.log" bash "${SRC}/qwen38-flash-next/thermal-guard.sh" >/dev/null
  sleep 3; systemctl is-active --quiet rocm-ab-guard || die "host thermal guard did not start"; }
vm_guard(){ local gpci
  vm systemctl is-active --quiet rocm-ab-guard && return 0
  # shellcheck disable=SC2016  # expands in the guest
  gpci=$(vm sh -c 'for d in /sys/class/drm/card*/device; do [ -d "$d/hwmon" ] && [ "$(cat $d/vendor 2>/dev/null)" = 0x1002 ] && basename "$(readlink -f "$d")"; done | sort -u')
  [ "$(wc -w <<<"$gpci")" = 1 ] || die "guest amdgpu card ambiguous: '${gpci}'"
  vm systemd-run --unit=rocm-ab-guard --collect -E CARDS="$gpci" -E PATTERNS="$GUARD_PATTERNS" -E LIMIT=100 \
    -E LOG=/opt/rocm-ab/guard.log bash /opt/rocm-ab/thermal-guard.sh >/dev/null
  sleep 3; vm systemctl is-active --quiet rocm-ab-guard || die "guest thermal guard did not start"; }

side(){ case $1 in A) echo host ;; *) echo vm ;; esac; }
move_to(){
  if [ "$1" = host ]; then
    if [ "$(basename "$(readlink -f "/sys/bus/pci/devices/${PCI}/driver")")" != amdgpu ] \
       || ! grep -q running <<<"$(pct status "$CT")"; then
      card to-host
    fi
    host_guard
  else
    systemctl stop rocm-ab-guard 2>/dev/null || true
    grep -q running <<<"$(qm status "$VMID")" || card to-vm
    vm tee /opt/rocm-ab/bench.sh >/dev/null <"${HERE}/bench.sh"
    vm_guard
  fi; }

run_setup(){ local s=$1 r=$2 ppl=0 dir="r${2}-${1}" env
  [ "$r" = 1 ] && ppl=1
  [ "$SMOKE" = 1 ] && ppl=0
  move_to "$(side "$s")"
  say "round ${r} setup ${s}"
  case $s in
    A) pct exec "$CT" -- env BIN="/root/rocm-ab/llama-${TAG}-vulkan" DEV=Vulkan0 PCI="$PCI" PPL="$ppl" SMOKE="$SMOKE" EXPECT_OFFSET_MV="$AB_OFFSET_MV" \
         MODELS="/ab-models/${MOE} /ab-models/${DENSE}" WIKI=/ab-models/wiki.test.raw \
         bash /root/rocm-ab/bench.sh "$s" "$r" "/root/rocm-ab/out/${phase}/${dir}"
       pct exec "$CT" -- tar czf - -C "/root/rocm-ab/out/${phase}" "$dir" | tar xzf - -C "$out" ;;
    B|C)
       if [ "$s" = B ]; then env=(BIN="/opt/rocm-ab/llama-${TAG}-vulkan" DEV=Vulkan0)
       else env=(BIN="/opt/rocm-ab/llama-${TAG}-rocm" DEV=ROCm0 LD_LIBRARY_PATH=/opt/rocm/core-10.0/lib); fi
       vm env "${env[@]}" PPL="$ppl" SMOKE="$SMOKE" EXPECT_OFFSET_MV="$AB_OFFSET_MV" MODELS="/models/${MOE} /models/${DENSE}" \
         WIKI=/opt/rocm-ab/wiki.test.raw bash /opt/rocm-ab/bench.sh "$s" "$r" "/opt/rocm-ab/out/${phase}/${dir}"
       vm tar czf - -C "/opt/rocm-ab/out/${phase}" "$dir" | tar xzf - -C "$out" ;;
  esac
  [ -s "${ROOT}/guard-host.log" ] && grep -q "THERMAL GUARD" "${ROOT}/guard-host.log" && die "host guard tripped"
  return 0; }

# Once per phase: CT 123's model service off, the model volume bound read-only into CT 123,
# and the current harness and Vulkan build inside it.
prepare(){
  mountpoint -q "$MNT" || mount "/dev/pve/rocm-ab-models" "$MNT"
  [ -s "${MNT}/wiki.test.raw" ] || cp "${ROOT}/dl/wiki.test.raw" "${MNT}/"
  if grep -q running <<<"$(pct status "$CT")"; then
    pct exec "$CT" -- systemctl disable --now "$CT_SERVICE"
  fi
  if ! grep -q "^mp1: ${MNT}," <<<"$(pct config "$CT")"; then
    if grep -q running <<<"$(pct status "$CT")"; then pct stop "$CT"; fi
    pct set "$CT" -mp1 "${MNT},mp=/ab-models,ro=1"
  fi
  if ! grep -q running <<<"$(pct status "$CT")"; then pct start "$CT"; fi
  pct exec "$CT" -- systemctl disable --now "$CT_SERVICE"
  pct exec "$CT" -- mkdir -p /root/rocm-ab
  pct push "$CT" "${HERE}/bench.sh" /root/rocm-ab/bench.sh
  if ! pct exec "$CT" -- test -x "/root/rocm-ab/llama-${TAG}-vulkan/llama-bench"; then
    pct push "$CT" "${ROOT}/dl/llama-${TAG}-bin-ubuntu-vulkan-x64.tar.gz" /root/rocm-ab/vulkan.tgz
    pct exec "$CT" -- sh -c "mkdir -p /root/rocm-ab/llama-${TAG}-vulkan && tar xzf /root/rocm-ab/vulkan.tgz --strip-components=1 -C /root/rocm-ab/llama-${TAG}-vulkan && rm /root/rocm-ab/vulkan.tgz"
  fi
  # Without the card, CT 123 must not stay up: card.sh to-host starts it with the card mounted.
  if [ "$(basename "$(readlink -f "/sys/bus/pci/devices/${PCI}/driver")")" != amdgpu ]; then pct stop "$CT"; fi
  say "prepared: CT ${CT} service disabled, /ab-models bound read-only, harness pushed"; }

say "phase ${phase}: ${X} vs ${Y}, smoke=${SMOKE}, test-card offset ${AB_OFFSET_MV}mV"
prepare
rounds=("$X $Y" "$Y $X" "$X $Y")
[ "$SMOKE" = 1 ] && rounds=("$X $Y")
r=0
for pair in "${rounds[@]}"; do
  r=$((r + 1))
  for s in $pair; do run_setup "$s" "$r"; done
done
say "phase ${phase} measurements complete"
