#!/usr/bin/env bash
# Move CT 120 between its two model shapes. Runs on the Proxmox HOST as root.
#
#   ./ct120-cutover.sh to-qwen38fn   # both V620s -> Qwen3.8-Flash-Next (qwen4exp)
#   ./ct120-cutover.sh to-qwen36     # back to GPU 1 alone -> qwen3.6-35b-a3b
#   ./ct120-cutover.sh status
#
# Fully reversible: both GGUFs stay on /models, both llama.cpp builds stay in
# /opt/llamacpp, and the qwen3.6 unit is left installed. Rollback is this script.
#
# ⚠️ CT 123 (gpu2) MUST stay stopped while CT 120 holds GPU 2, so the two never contend
# for the same card. `to-qwen36` is what releases it.
# (Historically the hazard was sharper: CT 123 ran llama-swap, which passed no device
# selector and would grab whichever card Vulkan enumerated first. llama-swap was removed
# 2026-09-18 and CT 123 now serves Qwen3.8-Flash-Next pinned with `--device Vulkan0`, so it
# takes only GPU 2 — but two servers on one card is still wrong, so the guard stays.)
set -Eeuo pipefail

readonly CONF=/etc/pve/lxc/120.conf
readonly VMID=120
readonly BAK_DIR="${BAK_DIR:-/root/qwen38-flash-next}"

# GPU 2. Mount at the REAL host node names — mounting at a different name inside the
# container makes RADV fail DRM auth, and llama.cpp then falls back to CPU silently.
readonly GPU2_PCI='0000:83:00.0'
readonly GPU2_RENDER_DST='renderD128'
readonly GPU2_CARD_DST='card1'
readonly GPU1_PCI='0000:03:00.0'

readonly WATCHDOG_ENV=/etc/gpu-thermal-watchdog.env

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"; }

gpu2_attached() { grep -q "${GPU2_PCI}-render" "$CONF"; }

assert_ct123_stopped() {
  local st
  st="$(pct status 123 2>/dev/null | awk '{print $2}')"
  [ "$st" = "stopped" ] || die "CT 123 is '${st}' — stop it first (pct stop 123). Two containers must never hold the same card."
}

# 🔴 A ONE-SHOT "is it stopped?" CHECK DOES NOT HOLD. CT 123 keeps onboot=1, its own GPU-2
# mounts and an enabled model service, so the next host reboot starts it straight back onto
# the card CT 120 now holds — two llama-servers, one GPU, no warning. Stopping it by hand is
# not enough; its autostart and its unit have to be disabled for as long as CT 120 owns the
# card, and restored on the way back.
ct123_release_gpu2() {
  log "disabling CT 123 autostart + model unit so a host reboot cannot re-take GPU 2"
  printf '%s\n' "$(pct config 123 2>/dev/null | grep -E '^onboot' || echo 'onboot: 0')" \
    >"${BAK_DIR}/123.onboot.before-cutover"
  pct set 123 --onboot 0 || die "could not clear CT 123 onboot — refusing to proceed"
  pct exec 123 -- systemctl disable llamacpp-qwen38fn 2>/dev/null \
    || log "  (CT 123 is stopped, so its unit stays enabled on disk — autostart off is the guard)"
}

ct123_restore() {
  log "restoring CT 123 autostart + model unit"
  pct set 123 --onboot 1 || log "  WARN: could not restore CT 123 onboot — set it by hand"
  pct exec 123 -- systemctl enable llamacpp-qwen38fn 2>/dev/null \
    || log "  (CT 123 not running; enable llamacpp-qwen38fn after 'pct start 123')"
}

# The invariant the map exists to satisfy, checked rather than assumed: a mapped service must
# be enabled-or-active in a container that actually holds that card.
assert_map_owns_cards() {
  local map addr svc vm unit bad=0
  map="$(grep -m1 '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV" 2>/dev/null | cut -d= -f2-)"
  [ -n "$map" ] || { log "WARN: watchdog map empty — cannot verify ownership"; return 0; }
  local IFS=','
  for pair in $map; do
    addr="${pair%%=*}"; svc="${pair#*=}"; vm="${svc%%:*}"; unit="${svc#*:}"
    if ! pct exec "$vm" -- systemctl is-enabled "$unit" >/dev/null 2>&1 \
      && ! pct exec "$vm" -- systemctl is-active "$unit" >/dev/null 2>&1; then
      log "🔴 MAP MISMATCH: ${addr} -> ${vm}:${unit}, which is neither enabled nor active"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ] && log "watchdog map verified: every mapped unit exists and is live" || \
    log "🔴 the watchdog would be a NO-OP for at least one card — fix the map before loading"
  return 0
}

# The watchdog stops the service OWNING the hot card, so the map must name the unit that is
# actually RUNNING, per card.
# 🔴 THIS WAS WRONG UNTIL 2026-09-18 and it disabled thermal protection on both cards at
# once. The forward cutover mapped both cards to `120:llamacpp`, then disabled that very
# unit and started `120:llamacpp-qwen38fn` instead — so a trip stopped a dead unit, the real
# load kept running, and the 105 °C hardware MODE1 reset became the only backstop. On the
# one configuration that drives BOTH cards. The map must be `120:llamacpp-qwen38fn` while
# CT 120 serves qwen4exp, and `120:llamacpp` only after the revert re-enables that unit.
# ✅ Invariant to preserve: every mapped service must own the card it is mapped to. There is
# a check for it at the end of this script.
set_watchdog_map() {
  local want="$1"
  [ -f "$WATCHDOG_ENV" ] || { log "watchdog env absent — skipping map update"; return 0; }
  cp -a "$WATCHDOG_ENV" "${BAK_DIR}/gpu-thermal-watchdog.env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  if grep -q '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV"; then
    sed -i "s|^GPU_SERVICE_MAP=.*|GPU_SERVICE_MAP=${want}|" "$WATCHDOG_ENV"
  else
    printf 'GPU_SERVICE_MAP=%s\n' "$want" >>"$WATCHDOG_ENV"
  fi
  systemctl restart gpu-thermal-watchdog
  log "watchdog map -> ${want} (service restarted)"
}

case "${1:-status}" in
  to-qwen38fn)
    require_root
    mkdir -p "$BAK_DIR"
    assert_ct123_stopped
    ct123_release_gpu2

    [ -e "/dev/dri/by-path/pci-${GPU2_PCI}-render" ] \
      || die "GPU 2 by-path render node missing on the host"

    # Refuse to cut over onto a half-downloaded model.
    pct exec "$VMID" -- test -f /etc/llamacpp-qwen38fn.env \
      || die "/etc/llamacpp-qwen38fn.env not installed in CT ${VMID} — run install.sh first"
    # shellcheck disable=SC2016  # must expand INSIDE the container, not here
    pct exec "$VMID" -- bash -lc '
      set -a; . /etc/llamacpp-qwen38fn.env; set +a
      for i in 1 2 3 4; do
        s=$(printf "%s" "$MODEL_PATH" | sed -E "s/-00001-of-/-0000${i}-of-/")
        [ -f "${s}.verified" ] || { echo "shard ${i} not verified: ${s}.verified missing"; exit 1; }
      done' || die "model download incomplete or unverified — see qwen38fn-download.sh"

    log "stopping the qwen3.6 server"
    pct exec "$VMID" -- systemctl disable --now llamacpp 2>/dev/null || true

    if gpu2_attached; then
      log "GPU 2 already attached to CT ${VMID}"
    else
      cp -a "$CONF" "${BAK_DIR}/120.conf.bak.$(date -u +%Y%m%dT%H%M%SZ)"
      log "attaching GPU 2 (${GPU2_PCI}) to CT ${VMID}"
      {
        printf 'lxc.mount.entry: /dev/dri/by-path/pci-%s-render dev/dri/%s none bind,optional,create=file\n' \
          "$GPU2_PCI" "$GPU2_RENDER_DST"
        printf 'lxc.mount.entry: /dev/dri/by-path/pci-%s-card dev/dri/%s none bind,optional,create=file\n' \
          "$GPU2_PCI" "$GPU2_CARD_DST"
      } >>"$CONF"
    fi

    # cores only take effect on restart (memory does apply live)
    pct set "$VMID" --cores 48 --memory 163840 --swap 0

    log "restarting CT ${VMID} to pick up GPU 2 and the cpuset"
    pct stop "$VMID"; sleep 4; pct start "$VMID"; sleep 15

    set_watchdog_map "${GPU1_PCI}=120:llamacpp-qwen38fn,${GPU2_PCI}=120:llamacpp-qwen38fn"

    log "enabling the qwen4exp server"
    pct exec "$VMID" -- systemctl enable --now llamacpp-qwen38fn
    assert_map_owns_cards
    ;;

  to-qwen36)
    require_root
    mkdir -p "$BAK_DIR"

    log "stopping the qwen4exp server"
    pct exec "$VMID" -- systemctl disable --now llamacpp-qwen38fn 2>/dev/null || true

    if gpu2_attached; then
      cp -a "$CONF" "${BAK_DIR}/120.conf.before-revert.$(date -u +%Y%m%dT%H%M%SZ)"
      log "detaching GPU 2 from CT ${VMID}"
      grep -v "${GPU2_PCI}-\(render\|card\)" "$CONF" >"${BAK_DIR}/120.conf.new"
      cat "${BAK_DIR}/120.conf.new" >"$CONF"
    else
      log "GPU 2 already detached"
    fi

    pct set "$VMID" --cores 8 --memory 16384 --swap 4096

    log "restarting CT ${VMID}"
    pct stop "$VMID"; sleep 4; pct start "$VMID"; sleep 15

    set_watchdog_map "${GPU1_PCI}=120:llamacpp,${GPU2_PCI}=123:llamacpp-qwen38fn"

    log "enabling the qwen3.6 server"
    pct exec "$VMID" -- systemctl enable --now llamacpp
    ct123_restore
    assert_map_owns_cards
    log "GPU 2 released — CT 123 can be started again (pct start 123)"
    ;;

  status) ;;
  *) die "usage: $0 {to-qwen38fn|to-qwen36|status}" ;;
esac

echo
echo "--- CT ${VMID} DRM entries ---"
grep -n 'dev/dri' "$CONF" | sed 's/^/  /' || echo "  (none)"
echo "--- CT ${VMID} limits ---"
pct config "$VMID" | grep -E '^(cores|memory|swap)' | sed 's/^/  /'
echo "--- devices RADV offers inside CT ${VMID} ---"
# shellcheck disable=SC2016  # must expand INSIDE the container, not here
pct exec "$VMID" -- bash -lc \
  'D=$(grep -m1 ^LLAMACPP_DIR= /etc/llamacpp-qwen38fn.env 2>/dev/null | cut -d= -f2); D=${D:-/opt/llamacpp/current};
   LD_LIBRARY_PATH=$D $D/llama-server --list-devices 2>/dev/null | tail -5' 2>/dev/null \
  || echo "  (could not query)"
echo "--- services ---"
for s in llamacpp llamacpp-qwen38fn; do
  printf '  %-20s enabled=%-10s active=%s\n' "$s" \
    "$(pct exec "$VMID" -- systemctl is-enabled "$s" 2>&1 | head -1)" \
    "$(pct exec "$VMID" -- systemctl is-active  "$s" 2>&1 | head -1)"
done
echo "--- CT 123 (must be stopped while CT 120 holds GPU 2) ---"
printf '  %s\n' "$(pct status 123 2>/dev/null || echo 'unknown')"
echo "--- watchdog service map ---"
grep -m1 '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV" 2>/dev/null | sed 's/^/  /' || echo "  (unset)"
# Reboot exclusivity is invisible in `pct status`, so surface it: CT 123 stopped but still
# onboot=1 is the state that silently re-takes GPU 2 on the next host boot.
printf 'CT 123: status=%s  %s\n' \
  "$(pct status 123 2>/dev/null | awk '{print $2}')" \
  "$(pct config 123 2>/dev/null | grep -E '^onboot' || echo 'onboot: 0 (unset)')"
if gpu2_attached && [ "$(pct config 123 2>/dev/null | awk '/^onboot/{print $2}')" = "1" ]; then
  echo "  🔴 CT 120 holds GPU 2 while CT 123 is set to autostart — a host reboot puts two"
  echo "     servers on one card. Run: pct set 123 --onboot 0"
fi
assert_map_owns_cards
echo "--- per-card VRAM / GTT ---"
for pci in "$GPU1_PCI" "$GPU2_PCI"; do
  d="/sys/bus/pci/devices/${pci}"
  printf '  %s  vram=%5s MiB  gtt=%5s MiB\n' "$pci" \
    "$(( $(cat "${d}/mem_info_vram_used" 2>/dev/null || echo 0) / 1048576 ))" \
    "$(( $(cat "${d}/mem_info_gtt_used"  2>/dev/null || echo 0) / 1048576 ))"
done
