#!/usr/bin/env bash
# TEMPORARILY give CT 123 a second GPU (GPU 1, 0000:2d:00.0) so a single container can
# benchmark BOTH cards with one binary and one set of model files. Fully reversible.
#
#   ./ct123-dual-gpu.sh add      # add GPU 1's DRM nodes, restart CT 123
#   ./ct123-dual-gpu.sh revert   # remove them, restart CT 123 (back to the pinned state)
#   ./ct123-dual-gpu.sh status
#
# ⚠️ While added, CT 123's production llama-swap MUST stay stopped: its config passes no
# device selector, so it would take Vulkan device 0 — which may be GPU 1, i.e. CT 120's
# card. ALWAYS revert before bringing llama-swap back up.
set -Eeuo pipefail

CONF=/etc/pve/lxc/123.conf
# GPU 1's real host node names (matching what CT 120 uses — mount at the REAL name or
# RADV fails DRM auth and llama.cpp silently falls back to CPU).
G1_RENDER='lxc.mount.entry: /dev/dri/by-path/pci-0000:2d:00.0-render dev/dri/renderD129 none bind,optional,create=file'
G1_CARD='lxc.mount.entry: /dev/dri/by-path/pci-0000:2d:00.0-card dev/dri/card1 none bind,optional,create=file'

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-status}" in
  add)
    grep -q '2d:00.0-render' "$CONF" && { echo "already added"; exit 0; }
    [ -e /dev/dri/by-path/pci-0000:2d:00.0-render ] || die "GPU 1 by-path render node missing"
    cp -a "$CONF" "${BENCH_DIR:-/root/gpu-ab-bench}/123.conf.bak"
    printf '%s\n%s\n' "$G1_RENDER" "$G1_CARD" >>"$CONF"
    echo "added GPU 1 nodes; restarting CT 123"
    pct exec 123 -- systemctl stop llama-swap 2>/dev/null || true
    pct stop 123; sleep 3; pct start 123; sleep 12
    pct exec 123 -- systemctl stop llama-swap 2>/dev/null || true
    pct exec 123 -- systemctl disable llama-swap 2>/dev/null || true
    ;;
  revert)
    cp -a "$CONF" "${BENCH_DIR:-/root/gpu-ab-bench}/123.conf.before-revert"
    grep -v '2d:00\.0-\(render\|card\)' "$CONF" >/tmp/123.conf.new
    cat /tmp/123.conf.new >"$CONF"
    echo "removed GPU 1 nodes; restarting CT 123"
    pct stop 123; sleep 3; pct start 123; sleep 12
    pct exec 123 -- systemctl enable llama-swap 2>/dev/null || true
    echo "llama-swap re-enabled (NOT started — start it when you want production back)"
    ;;
  status) ;;
esac

echo "--- 123.conf DRM entries ---"
grep -n 'dev/dri' "$CONF" | sed 's/^/  /'
echo "--- devices visible to llama.cpp in CT 123 ---"
pct exec 123 -- bash -lc "LD_LIBRARY_PATH=/opt/llamacpp/current VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json /opt/llamacpp/current/llama-server --list-devices 2>/dev/null | tail -4" || true
echo "--- llama-swap state (must be inactive while dual-GPU) ---"
pct exec 123 -- systemctl is-active llama-swap || true
