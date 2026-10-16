#!/usr/bin/env bash
# Switch CT 123's Qwen3.8-Flash-Next server between llama.cpp and Strata on GPU 2
# (0000:83:00.0). Runs on the Proxmox HOST as root, after ./install.sh.
#
#   ./use-engine.sh status
#   ./use-engine.sh strata      # passes /dev/kfd in if missing, then serves with Strata
#   ./use-engine.sh llamacpp    # back to the deployed llama.cpp server
#
# Each direction changes three things together, as ct120-cutover.sh does for the cards:
# the unit that runs, the unit enabled at boot, and the thermal watchdog's map entry for the
# card. A map that names the stopped engine leaves the card unprotected.
#
# Adding /dev/kfd needs a container restart. That restart stops the llama.cpp server for its
# reload (about 50 s with dio); the script says so before it does it.
set -Eeuo pipefail

VMID="${VMID:-123}"
GPU2_PCI="0000:83:00.0"
WATCHDOG_ENV="${WATCHDOG_ENV:-/etc/gpu-thermal-watchdog.env}"
BAK_DIR="${BAK_DIR:-/root/strata-backups}"
PORT="${PORT:-1234}"
LLAMACPP_UNIT=llamacpp-qwen38fn
STRATA_UNIT=strata-qwen38fn

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }
in_ct() { pct exec "$VMID" -- "$@"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"

# CT 123 must hold GPU 2's render node and CT 120 must not: the two-card cutover gives both
# cards to CT 120, and then neither engine may run here.
assert_owns_card() {
  grep -q "pci-${GPU2_PCI}-render" "/etc/pve/lxc/${VMID}.conf" \
    || die "CT ${VMID} does not pass ${GPU2_PCI} through (two-card cutover active? ./ct120-cutover.sh status)"
  if grep -q "pci-${GPU2_PCI}-render" /etc/pve/lxc/120.conf 2>/dev/null; then
    die "CT 120 also passes ${GPU2_PCI} through; resolve that before switching engines"
  fi
}

# Proxmox's device passthrough resolves /dev/kfd's (dynamic) major number at every start.
ensure_kfd() {
  if grep -qE '^dev[0-9]+: /dev/kfd' "/etc/pve/lxc/${VMID}.conf"; then
    in_ct test -c /dev/kfd && return 0
    log "/dev/kfd is configured but absent in CT ${VMID}: a restart applies it"
    return 1
  fi
  local n=0 gid
  while grep -q "^dev${n}:" "/etc/pve/lxc/${VMID}.conf"; do n=$((n + 1)); done
  gid="$(stat -c %g /dev/kfd)"
  log "passing /dev/kfd into CT ${VMID} as dev${n} (gid ${gid}, render)"
  pct set "$VMID" "-dev${n}" "/dev/kfd,gid=${gid},mode=0660" || die "pct set -dev${n} failed"
  in_ct test -c /dev/kfd 2>/dev/null && return 0
  return 1
}

set_map_entry() {   # <unit>: point GPU 2's watchdog entry at it, keep every other entry
  local unit="$1" map new
  [ -f "$WATCHDOG_ENV" ] || die "no ${WATCHDOG_ENV}: the watchdog is not installed"
  map="$(grep -m1 '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV" | cut -d= -f2-)"
  new="$(printf '%s' "$map" | tr ',' '\n' | grep -v "^${GPU2_PCI}=" | paste -sd, -)"
  new="${new:+${new},}${GPU2_PCI}=${VMID}:${unit}"
  [ "$new" = "$map" ] && { log "watchdog map already ${map}"; return 0; }
  install -d -m 0700 "$BAK_DIR"
  cp -a "$WATCHDOG_ENV" "${BAK_DIR}/gpu-thermal-watchdog.env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  sed -i "s|^GPU_SERVICE_MAP=.*|GPU_SERVICE_MAP=${new}|" "$WATCHDOG_ENV"
  systemctl restart gpu-thermal-watchdog
  log "watchdog map -> ${new} (service restarted)"
}

wait_serving() {   # <unit>
  local unit="$1"
  for _ in $(seq 1 360); do
    if in_ct curl -fsS "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null | grep -q '"id"'; then
      log "${unit} serves on :${PORT}"
      return 0
    fi
    in_ct systemctl is-failed --quiet "$unit" && die "${unit} failed; pct exec ${VMID} -- journalctl -u ${unit}"
    sleep 5
  done
  die "${unit} was not serving after 30 min"
}

switch_to() {   # <unit to run> <unit to stop>
  local on="$1" off="$2"
  assert_owns_card
  in_ct test -f "/etc/systemd/system/${on}.service" || die "CT ${VMID} has no ${on}.service; run install.sh"
  in_ct systemctl disable --now "$off"
  in_ct systemctl enable "$on" >/dev/null
  set_map_entry "$on"
  in_ct systemctl start "$on"
  wait_serving "$on"
}

status() {
  local map
  map="$(grep -m1 '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV" 2>/dev/null | cut -d= -f2-)"
  echo "  watchdog map: ${map:-MISSING}"
  echo "  /dev/kfd:     config $(grep -cE '^dev[0-9]+: /dev/kfd' "/etc/pve/lxc/${VMID}.conf"), in CT $(in_ct test -c /dev/kfd && echo yes || echo no)"
  for u in "$LLAMACPP_UNIT" "$STRATA_UNIT"; do
    echo "  ${u}: $(in_ct systemctl is-active "$u" 2>&1 | head -1)/$(in_ct systemctl is-enabled "$u" 2>&1 | head -1)"
  done
}

case "${1:-}" in
  status)
    status
    ;;
  strata)
    assert_owns_card
    if ! ensure_kfd; then
      log "restarting CT ${VMID} to apply /dev/kfd; ${LLAMACPP_UNIT} stops until the switch below"
      in_ct systemctl disable --now "$LLAMACPP_UNIT"
      pct reboot "$VMID"
      for _ in $(seq 1 60); do in_ct true 2>/dev/null && break; sleep 2; done
      in_ct test -c /dev/kfd || die "/dev/kfd is still absent in CT ${VMID} after the restart"
    fi
    switch_to "$STRATA_UNIT" "$LLAMACPP_UNIT"
    status
    ;;
  llamacpp)
    switch_to "$LLAMACPP_UNIT" "$STRATA_UNIT"
    status
    ;;
  *)
    sed -n '2,14p' "$0"
    exit 2
    ;;
esac
