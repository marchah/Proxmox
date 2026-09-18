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

# The watchdog stops the service OWNING the hot card. While CT 120 drives both cards the
# map must point BOTH at 120:llamacpp — otherwise a trip on GPU 2 tries to stop CT 123's
# the wrong container's service, which is a no-op, and the real load keeps cooking an
# overheating card.
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

    set_watchdog_map "${GPU1_PCI}=120:llamacpp,${GPU2_PCI}=120:llamacpp"

    log "enabling the qwen4exp server"
    pct exec "$VMID" -- systemctl enable --now llamacpp-qwen38fn
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
echo "--- per-card VRAM / GTT ---"
for pci in "$GPU1_PCI" "$GPU2_PCI"; do
  d="/sys/bus/pci/devices/${pci}"
  printf '  %s  vram=%5s MiB  gtt=%5s MiB\n' "$pci" \
    "$(( $(cat "${d}/mem_info_vram_used" 2>/dev/null || echo 0) / 1048576 ))" \
    "$(( $(cat "${d}/mem_info_gtt_used"  2>/dev/null || echo 0) / 1048576 ))"
done
