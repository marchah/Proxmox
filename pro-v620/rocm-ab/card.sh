#!/usr/bin/env bash
# Move GPU 2 between the host (amdgpu, used by CT 123) and the test VM (vfio-pci). HOST, root.
#
#   card.sh to-vm     stop CT 123, rebind the card to vfio-pci, boot the VM, undervolt it there
#   card.sh to-host   shut the VM down, rebind the card to amdgpu, re-apply the host undervolt,
#                     start CT 123 (its model service stays disabled while a phase runs)
#   card.sh restore   to-host, then re-enable and start CT 123's model service
#   card.sh status
#
# Runtime rebinds only: nothing persists across a host reboot, which binds amdgpu as usual.
# CT 120's card is never touched; every move ends by checking CT 120 still answers.
set -Eeuo pipefail

PCI="${PCI:-0000:83:00.0}"
CT="${CT:-123}"; CT_SERVICE="${CT_SERVICE:-llamacpp-qwen38fn}"
VMID="${VMID:-301}"
CT120_HEALTH="${CT120_HEALTH:-http://llamacpp.lan:1234/health}"
# GFX offset for the test card, on both sides. 0 = stock: at −100 mV this card returns
# non-reproducible perplexity and occasional NaN (see README). CT 120's card is not touched.
AB_OFFSET_MV="${AB_OFFSET_MV:-0}"
DEV="/sys/bus/pci/devices/${PCI}"

say(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die(){ say "FATAL: $*"; exit 1; }
# readlink -f canonicalizes even a missing link, so test for the link itself.
driver(){ if [ -e "${DEV}/driver" ]; then basename "$(readlink -f "${DEV}/driver")"; else echo none; fi; }
wait_for(){ local secs=$1 t=0; shift; until "$@"; do sleep 2; t=$((t + 2)); [ "$t" -lt "$secs" ] || return 1; done; }
on_driver(){ [ "$(driver)" = "$1" ]; }
vm_running(){ grep -q running <<<"$(qm status "$VMID" 2>/dev/null)"; }
ct_running(){ grep -q running <<<"$(pct status "$CT")"; }
agent_up(){ qm guest cmd "$VMID" ping >/dev/null 2>&1; }
# `qm shutdown` can return while QEMU still holds the card. Unbinding vfio-pci then only
# relays a release request to QEMU, and the following amdgpu probe is rejected.
vm_released(){ local pid group
  pid=$(cat "/var/run/qemu-server/${VMID}.pid" 2>/dev/null) && kill -0 "$pid" 2>/dev/null && return 1
  group=$(basename "$(readlink -f "${DEV}/iommu_group")")
  ! fuser -s "/dev/vfio/${group}" 2>/dev/null; }
probe(){ local _
  for _ in 1 2 3 4 5; do echo "$PCI" > /sys/bus/pci/drivers_probe 2>/dev/null && return 0; sleep 3; done
  return 1; }

# The guest's first non-loopback IPv4, from the guest agent (no DNS dependency).
vm_ip(){ qm guest cmd "$VMID" network-get-interfaces | perl -MJSON::PP -e '
  for my $if (@{ decode_json(do { local $/; <STDIN> }) }) {
    next if $if->{name} eq "lo";
    for my $a (@{ $if->{"ip-addresses"} || [] }) {
      if ($a->{"ip-address-type"} eq "ipv4") { print $a->{"ip-address"}; exit 0 } } }
  exit 1'; }
# ssh joins its arguments into one remote command line, so quote each one for the remote shell.
vm(){ ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "ubuntu@$(vm_ip)" "sudo $(printf '%q ' "$@")"; }
guest_card_up(){ vm sh -c 'ls -d /sys/class/drm/card*/device/hwmon/hwmon* >/dev/null 2>&1' 2>/dev/null; }

blower_reads_vm(){ grep -q "temps from: vm${VMID}" <<<"$(journalctl -u gpu-blower-control --since "$1" --no-pager -o cat)"; }

check_ct120(){ curl -fsS -m 10 "$CT120_HEALTH" >/dev/null || die "CT 120 does not answer ${CT120_HEALTH}"; say "CT 120 healthy"; }

offset_of(){ grep -A1 OD_VDDGFX_OFFSET "/sys/bus/pci/devices/$1/pp_od_clk_voltage" | tail -1; }
# amdgpu forgets OverDrive state on unbind, so set the test card's offset after every rebind.
# Only this card: restarting gpu-undervolt would also reset CT 120's card.
host_undervolt(){ local o
  GPU_PCI_ADDRESS="$PCI" OFFSET_MV="$AB_OFFSET_MV" /usr/local/sbin/gpu-undervolt apply >/dev/null
  o=$(offset_of "$PCI"); [ "$o" = "${AB_OFFSET_MV}mV" ] || die "${PCI} offset is '${o}', expected ${AB_OFFSET_MV}mV"
  say "host offset ${PCI} ${AB_OFFSET_MV}mV (0000:03:00.0 untouched at $(offset_of 0000:03:00.0))"; }

to_vm(){
  local since holders
  on_driver amdgpu || on_driver vfio-pci || die "card on unexpected driver: $(driver)"
  systemctl stop rocm-ab-guard 2>/dev/null || true          # the host guard reads this card's hwmon
  if ct_running; then say "stopping CT ${CT}"; pct stop "$CT"; fi
  if on_driver amdgpu; then
    holders=$(fuser "/dev/dri/by-path/pci-${PCI}-render" "/dev/dri/by-path/pci-${PCI}-card" 2>/dev/null || true)
    [ -z "${holders// /}" ] || die "host processes hold the card: ${holders}"
    say "unbinding ${PCI} from amdgpu"
    modprobe vfio-pci
    echo vfio-pci > "${DEV}/driver_override"
    echo "$PCI" > "${DEV}/driver/unbind"
    probe || die "vfio-pci probe of ${PCI} rejected"
  fi
  wait_for 20 on_driver vfio-pci || die "card did not bind to vfio-pci (driver: $(driver))"
  say "card on vfio-pci"
  grep -q "^hostpci0: ${PCI}," <<<"$(qm config "$VMID")" || qm set "$VMID" --hostpci0 "${PCI},pcie=1" >/dev/null
  since=$(date '+%F %T')
  vm_running || { say "starting VM ${VMID}"; qm start "$VMID"; }
  wait_for 240 agent_up || die "guest agent did not come up"
  wait_for 120 guest_card_up || die "amdgpu did not bind the card inside the guest"
  say "guest sees the card at $(vm_ip)"
  if wait_for 30 blower_reads_vm "$since"; then
    say "blower control reads the card from vm${VMID}"
  else
    say "WARN blower control is not reading the guest — FAN on this card stays at 100%"
  fi
  vm env EXPECTED_GPU_COUNT=1 OFFSET_MV="$AB_OFFSET_MV" /opt/rocm-ab/gpu-undervolt.sh apply >/dev/null
  [ "$(vm sh -c 'grep -A1 OD_VDDGFX_OFFSET /sys/class/drm/card*/device/pp_od_clk_voltage 2>/dev/null | tail -1')" = "${AB_OFFSET_MV}mV" ] \
    || die "guest offset did not apply"
  say "guest offset ${AB_OFFSET_MV}mV"
  check_ct120
}

to_host(){
  local r c
  if vm_running; then
    say "shutting down VM ${VMID}"
    qm shutdown "$VMID" --timeout 180 || { say "WARN clean shutdown failed — stopping"; qm stop "$VMID"; }
  fi
  wait_for 60 vm_released || die "VM ${VMID} still holds the card after shutdown"
  if on_driver vfio-pci; then
    say "rebinding ${PCI} to amdgpu"
    echo > "${DEV}/driver_override"
    echo "$PCI" > /sys/bus/pci/drivers/vfio-pci/unbind
  fi
  if on_driver none; then
    [ "$(cat "${DEV}/driver_override")" = "(null)" ] || echo > "${DEV}/driver_override"
    probe || die "amdgpu probe of ${PCI} rejected"
  fi
  wait_for 60 on_driver amdgpu || die "card did not bind to amdgpu (driver: $(driver))"
  wait_for 60 test -e "/dev/dri/by-path/pci-${PCI}-render" || die "no DRM render node for ${PCI}"
  wait_for 30 test -e "${DEV}/pp_od_clk_voltage" || die "no OverDrive node for ${PCI}"
  # CT 123 mounts the card at fixed node names. A renumber would leave it on the wrong node,
  # and RADV would fail DRM auth.
  r=$(basename "$(readlink -f "/dev/dri/by-path/pci-${PCI}-render")")
  c=$(basename "$(readlink -f "/dev/dri/by-path/pci-${PCI}-card")")
  if ! grep -q " dev/dri/${r} " "/etc/pve/lxc/${CT}.conf" || ! grep -q " dev/dri/${c} " "/etc/pve/lxc/${CT}.conf"; then
    die "DRM nodes are now ${c}/${r}; fix CT ${CT}'s lxc.mount.entry lines (pro-v620/README.md) before starting it"
  fi
  say "card on amdgpu as ${c}/${r}"
  host_undervolt
  # A CT started while the card was away has no node for it; restart so it mounts the card.
  if ct_running; then say "stopping CT ${CT} to remount the card"; pct stop "$CT"; fi
  say "starting CT ${CT}"; pct start "$CT"
  check_ct120
}

restore(){
  to_host
  pct exec "$CT" -- systemctl enable --now "$CT_SERVICE"
  say "CT ${CT} ${CT_SERVICE} re-enabled and started"
}

status(){
  echo "card ${PCI}: $(driver)"
  echo "VM ${VMID}: $(qm status "$VMID" 2>/dev/null || echo absent)"
  echo "CT ${CT}: $(pct status "$CT") / ${CT_SERVICE}: $(pct exec "$CT" -- systemctl is-enabled "$CT_SERVICE" 2>/dev/null; true)"
  journalctl -u gpu-blower-control -n 2 --no-pager -o cat
}

case "${1:-}" in
  to-vm) to_vm ;;
  to-host) to_host ;;
  restore) restore ;;
  status) status ;;
  *) echo "usage: $0 to-vm|to-host|restore|status" >&2; exit 2 ;;
esac
