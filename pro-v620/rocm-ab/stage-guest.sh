#!/usr/bin/env bash
# Stage everything the A/B phases read inside VM 301. Proxmox HOST, root, after stage-host.sh and
# create-vm.sh. Idempotent: each file is checked by sha256 and copied only when missing or
# different, so a rerun after a phase or a disk change costs only the checks.
#
# The VM must be running. Booting it without the card stages without touching production;
# card.sh to-vm adds the card back:
#   qm set 301 --delete hostpci0; qm start 301
# A fresh cloud image has no QEMU guest agent, so when the agent is down this reaches the VM by
# its DHCP name (VM_HOST, default <vm name>.lan), waits for cloud-init and installs the agent:
# card.sh and the runners need it.
#
# Guest layout:
#   /opt/rocm-ab/        bench.sh agent-sim.py guest-setup.sh guest-rocm.sh gpu-undervolt.sh
#                        thermal-guard.sh wiki.test.raw llama-b11018-{vulkan,rocm}/
#   /opt/rocm-ab/spec/   spec-probe.py deep-context.txt agent-sim.py
#   /models/             the models in MODELS below
#
# ONLY='<regex>' limits which models are staged (the files are ~100 GB together):
#   ONLY='^Qwen3\.(6-35B-A3B|8-27B)-UD-Q5'   Phases 1-3
#   ONLY='^Qwen3\.6-35B-A3B-(MTP-)?UD'       Phase 4
#   ONLY='27B-(UD-Q4|DFlash2|MTP)'           Phase 5
# shellcheck disable=SC2016  # the single-quoted sh -c bodies expand in the guest
set -Eeuo pipefail

VMID="${VMID:-301}"
ROOT="${ROOT:-/root/rocm-ab}"
MNT="${MNT:-/mnt/rocm-ab-models}"
TAG=b11018
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SRC="$(dirname "$HERE")"
HF=https://huggingface.co
VM_HOST="${VM_HOST:-$(qm config "$VMID" 2>/dev/null | sed -n 's/^name: //p').lan}"

# guest file|sha256|source: host:<path> | ct:<id>:<path> | hf:<repo>@<revision>/<file>
MODELS=(
  "Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf|25233af7642e3a91bd52cc4aeefdbd4a117479088e06cf1aea5b6bedb443c506|host:${MNT}/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"
  "Qwen3.8-27B-UD-Q5_K_XL.gguf|8601193d3d5760c37fb8ce1b43afebc69df5fb24e1fbc5a547c32e2200305276|host:${MNT}/Qwen3.8-27B-UD-Q5_K_XL.gguf"
  "Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL.gguf|9de9a9420f61a0bb59bb2ca1ea170a6a57f6821fa1deec915bcaef523730a919|ct:120:/models/hf/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"
  "Qwen3.8-27B-UD-Q4_K_XL.gguf|3f227079003add2511437e5b1e94812e363385225bf6a9b47b0054a72bc8b01e|hf:unsloth/Qwen3.8-27B-GGUF@4ca720788d1e01f1bff70c033e0d0028fd02e502/Qwen3.8-27B-UD-Q4_K_XL.gguf"
  "Qwen3.8-27B-DFlash2-Q8_0.gguf|c18e800daedc59ca68fd13b6a856d795746af6d399a9279ac6a277d1d422f87e|ct:123:/models/hf/Qwen3.8-27B-DFlash2-Q8_0.gguf"
  "Qwen3.8-27B-MTP-ONLY-Q8_0.gguf|674d0fc3b2b09c48cf77fbab0aba39b9c4ee538bd240fa87c1f13044260f7d7b|hf:a4lg/Qwen3.8-27B-MTP-ONLY-GGUF@2476d11971c63a9185686ab4ab0d311506d192b0/Qwen3.8-27B-MTP-ONLY-Q8_0.gguf"
  "Qwen3.8-27B-MTP-ONLY-Q6_K.gguf|cad8b30e33294caa91d1c60229fefac5a683c88d85835f3a9767a035cac8870c|hf:a4lg/Qwen3.8-27B-MTP-ONLY-GGUF@2476d11971c63a9185686ab4ab0d311506d192b0/Qwen3.8-27B-MTP-ONLY-Q6_K.gguf"
)
# guest file|host source; checksums are taken from the host copy
FILES=(
  "/opt/rocm-ab/bench.sh|${HERE}/bench.sh"
  "/opt/rocm-ab/agent-sim.py|${HERE}/agent-sim.py"
  "/opt/rocm-ab/spec/agent-sim.py|${HERE}/agent-sim.py"
  "/opt/rocm-ab/guest-setup.sh|${HERE}/guest-setup.sh"
  "/opt/rocm-ab/guest-rocm.sh|${HERE}/guest-rocm.sh"
  "/opt/rocm-ab/gpu-undervolt.sh|${SRC}/undervolt/gpu-undervolt.sh"
  "/opt/rocm-ab/thermal-guard.sh|${SRC}/qwen38-flash-next/thermal-guard.sh"
  "/opt/rocm-ab/spec/spec-probe.py|${SRC}/spec-ab/spec-probe.py"
  "/opt/rocm-ab/spec/deep-context.txt|${SRC}/spec-ab/deep-context.txt"
  "/opt/rocm-ab/wiki.test.raw|${ROOT}/dl/wiki.test.raw"
)

say(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die(){ say "FATAL: $*"; exit 1; }
# The guest's address from its agent, else from its DHCP name.
vm_ip(){ qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | perl -MJSON::PP -e '
    for my $if (@{ decode_json(do { local $/; <STDIN> }) }) { next if $if->{name} eq "lo";
      for my $a (@{ $if->{"ip-addresses"} || [] }) {
        if ($a->{"ip-address-type"} eq "ipv4") { print $a->{"ip-address"}; exit 0 } } } exit 1' 2>/dev/null \
  || getent hosts "$VM_HOST" | awk '{ print $1; exit }'; }
# ssh joins its arguments into one remote command line, so quote each one for the remote shell.
vm(){ ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "ubuntu@$(vm_ip)" "sudo $(printf '%q ' "$@")"; }
guest_sha(){ vm sh -c 'sha256sum "$1" 2>/dev/null | cut -d" " -f1' sh "$1"; }
# Write stdin to a guest file, through a temporary name so a broken copy never looks complete.
put(){ vm sh -c 'cat > "$1.part" && mv "$1.part" "$1"' sh "$1"; }

stage(){ local dest=$1 sha=$2 src=$3 kind path
  if [ "$(guest_sha "$dest")" = "$sha" ]; then say "ok      ${dest}"; return 0; fi
  say "staging ${dest}"
  kind=${src%%:*}; path=${src#*:}
  case $kind in
    host) put "$dest" <"$path" ;;
    ct)   pct exec "${path%%:*}" -- cat "${path#*:}" | put "$dest" ;;
    hf)   vm curl -fsSL --retry 3 -o "${dest}.part" "${HF}/${path%%@*}/resolve/${path#*@}"
          vm mv "${dest}.part" "$dest" ;;
    *)    die "unknown source ${src}" ;;
  esac
  [ "$(guest_sha "$dest")" = "$sha" ] || die "sha256 mismatch after staging ${dest}"
  say "ok      ${dest}"; }

grep -q running <<<"$(qm status "$VMID" 2>/dev/null)" || die "VM ${VMID} is not running"
if ! qm guest cmd "$VMID" ping >/dev/null 2>&1; then
  say "guest agent down: reaching ${VM_HOST} over ssh to install it"
  t=0; until vm true 2>/dev/null; do sleep 5; t=$((t + 5)); [ "$t" -lt 300 ] || die "no ssh to ${VM_HOST} after 300 s"; done
  vm cloud-init status --wait >/dev/null || true
  vm env DEBIAN_FRONTEND=noninteractive sh -c 'apt-get update -q >/dev/null && apt-get install -y -q qemu-guest-agent >/dev/null'
  vm systemctl start qemu-guest-agent
  t=0; until qm guest cmd "$VMID" ping >/dev/null 2>&1; do sleep 3; t=$((t + 3)); [ "$t" -lt 60 ] || die "guest agent still down after installing it"; done
  say "guest agent up"
fi
[ -s "${SRC}/spec-ab/deep-context.txt" ] \
  || die "missing ${SRC}/spec-ab/deep-context.txt: build it from a checkout as spec-ab/run-ab.sh's header shows"
vm mkdir -p /opt/rocm-ab/spec /models

for f in "${FILES[@]}"; do
  src=${f#*|}; [ -s "$src" ] || die "missing ${src}"
  stage "${f%%|*}" "$(sha256sum "$src" | cut -d' ' -f1)" "host:${src}"
done
vm chmod +x /opt/rocm-ab/bench.sh /opt/rocm-ab/guest-setup.sh /opt/rocm-ab/guest-rocm.sh \
  /opt/rocm-ab/gpu-undervolt.sh /opt/rocm-ab/thermal-guard.sh

# The same release tarballs stage-host.sh fetched and checked.
for b in vulkan:vulkan-x64 rocm:rocm-10.0-x64; do
  dir="/opt/rocm-ab/llama-${TAG}-${b%%:*}"
  if vm test -x "${dir}/llama-server"; then say "ok      ${dir}/"; continue; fi
  say "staging ${dir}/"
  vm sh -c 'rm -rf "$1" && mkdir -p "$1" && tar xzf - --strip-components=1 -C "$1"' sh "$dir" \
    <"${ROOT}/dl/llama-${TAG}-bin-ubuntu-${b#*:}.tar.gz"
done

for m in "${MODELS[@]}"; do
  IFS='|' read -r name sha src <<<"$m"
  if [ -n "${ONLY:-}" ] && ! grep -qE "$ONLY" <<<"$name"; then continue; fi
  stage "/models/${name}" "$sha" "$src"
done
say "guest staged: $(vm df -h / | tail -1 | awk '{print $4 " free on the guest disk"}')"
