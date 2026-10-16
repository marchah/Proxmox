#!/usr/bin/env bash
# Switch CT 123's Qwen3.8-Flash-Next server between llama.cpp and Strata, on GPU 2
# (0000:83:00.0) or, for Strata's tests, on both cards. Runs on the Proxmox HOST as root,
# after ./install.sh.
#
#   ./use-engine.sh status
#   ./use-engine.sh strata            # Strata on GPU 2; CT 123 set up for HIP if needed
#   ./use-engine.sh strata-two-card   # Strata with GPU 1 attached too; CT 120 must be stopped
#   ./use-engine.sh llamacpp          # back to the deployed llama.cpp server on GPU 2
#
# Each direction changes together, as ct120-cutover.sh does for the cards: the cards CT 123
# binds, the unit that runs, the unit enabled at boot and the thermal watchdog's map. A map
# that names a stopped engine leaves a card unprotected. strata-two-card also turns CT 120's
# autostart off, so a host reboot cannot start a second server on GPU 1; the one-card
# directions give it back. CT 120 itself is never started.
#
# HIP needs /dev/kfd in the container and a DRM cgroup rule that allows only the cards CT 123
# binds (ensure_drm_cgroup). /dev/kfd joins a running container; a changed cgroup rule or
# card set needs one container restart, which the script announces before it does it.
set -Eeuo pipefail

VMID="${VMID:-123}"
CONF="/etc/pve/lxc/${VMID}.conf"
GPU1_PCI="0000:03:00.0"
GPU2_PCI="0000:83:00.0"
DRI_BY_PATH="${DRI_BY_PATH:-/dev/dri/by-path}"
WATCHDOG_ENV="${WATCHDOG_ENV:-/etc/gpu-thermal-watchdog.env}"
BAK_DIR="${BAK_DIR:-/root/strata-backups}"
CT120_ONBOOT_FILE="${BAK_DIR}/120.onboot.before-two-card"
PORT="${PORT:-1234}"
LLAMACPP_UNIT=llamacpp-qwen38fn
STRATA_UNIT=strata-qwen38fn
CT120_UNIT=llamacpp

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }
in_ct() { pct exec "$VMID" -- "$@"; }
backup_conf() { install -d -m 0700 "$BAK_DIR"; cp -a "$CONF" "${BAK_DIR}/${VMID}.conf.bak.$(date -u +%Y%m%dT%H%M%SZ)"; }
# Rewrite in place from a filtered copy: /etc/pve is the cluster filesystem.
rewrite_conf() { cat "${BAK_DIR}/${VMID}.conf.new" >"$CONF"; rm -f "${BAK_DIR}/${VMID}.conf.new"; }
gpu1_attached() { grep -q "pci-${GPU1_PCI}-render" "$CONF"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"

# CT 123 must hold GPU 2's render node and CT 120 must not: the two-card cutover gives both
# cards to CT 120, and then neither engine may run here.
assert_owns_gpu2() {
  grep -q "pci-${GPU2_PCI}-render" "$CONF" \
    || die "CT ${VMID} does not pass ${GPU2_PCI} through (two-card cutover active? ./ct120-cutover.sh status)"
  if grep -q "pci-${GPU2_PCI}-render" /etc/pve/lxc/120.conf 2>/dev/null; then
    die "CT 120 also passes ${GPU2_PCI} through; resolve that before switching engines"
  fi
}

# Proxmox's device passthrough resolves /dev/kfd's (dynamic) major number at every start, and
# adds it to a running container.
ensure_kfd() {
  if grep -qE '^dev[0-9]+: /dev/kfd' "$CONF"; then
    in_ct test -c /dev/kfd && return 0
    log "/dev/kfd is configured but absent in CT ${VMID}: a restart applies it"
    return 1
  fi
  local n=0 gid
  while grep -q "^dev${n}:" "$CONF"; do n=$((n + 1)); done
  gid="$(stat -c %g /dev/kfd)"
  log "passing /dev/kfd into CT ${VMID} as dev${n} (gid ${gid}, render)"
  pct set "$VMID" "-dev${n}" "/dev/kfd,gid=${gid},mode=0660" || die "pct set -dev${n} failed"
  in_ct test -c /dev/kfd 2>/dev/null && return 0
  return 1
}

# KFD reports to a process every GPU whose render node its device cgroup allows. With
# `c 226:* rwm` that includes a card CT 123 has no render node for; ROCm's thunk then fails
# to set that card's memory policy and HIP finds no device at all. Allowing exactly the DRM
# minors of the cards CT 123 binds hides the others (their KFD nodes read EPERM). The minors
# follow the by-path links, so this also repairs the rule after a DRM renumber.
ensure_drm_cgroup() {
  local rules=() pci node have
  while read -r pci; do
    node="$(readlink -f "${DRI_BY_PATH}/${pci}")"
    [ -c "$node" ] || die "${DRI_BY_PATH}/${pci} does not resolve to a device node"
    rules+=("lxc.cgroup2.devices.allow: c 226:$((16#$(stat -c %T "$node"))) rwm")
  done < <(grep -oE 'pci-0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]-(card|render)' "$CONF" | sort -u)
  [ "${#rules[@]}" -ge 2 ] || die "CT ${VMID} binds no card and render node"
  have="$(grep '^lxc.cgroup2.devices.allow: c 226:' "$CONF" | sort)"
  [ "$have" = "$(printf '%s\n' "${rules[@]}" | sort)" ] && return 0
  backup_conf
  # Every DRM allow line goes; the wanted ones take the first one's place.
  awk -v rules="$(printf '%s\\n' "${rules[@]}")" '/^lxc.cgroup2.devices.allow: c 226:/ {
      if (!done) printf "%s", rules; done = 1; next }
    { print }' "$CONF" >"${BAK_DIR}/${VMID}.conf.new"
  rewrite_conf
  log "CT ${VMID} DRM cgroup -> $(printf '%s\n' "${rules[@]}" | awk '{print $3}' | paste -sd' ' -); a restart applies it"
  return 1
}

# GPU 1 is mounted at its REAL host node names: a different name inside the container makes
# RADV fail DRM auth (pro-v620/README.md), and the same names keep HIP's view consistent.
attach_gpu1() {
  local render card
  render="$(basename "$(readlink -f "${DRI_BY_PATH}/pci-${GPU1_PCI}-render")")"
  card="$(basename "$(readlink -f "${DRI_BY_PATH}/pci-${GPU1_PCI}-card")")"
  [[ "$render" =~ ^renderD[0-9]+$ && "$card" =~ ^card[0-9]+$ ]] \
    || die "GPU 1 by-path nodes missing or unexpected (${render}, ${card})"
  if grep -qE "dev/dri/(${render}|${card}) " "$CONF"; then
    die "CT ${VMID} already mounts dev/dri/${render} or dev/dri/${card} from another card"
  fi
  backup_conf
  {
    printf 'lxc.mount.entry: %s/pci-%s-render dev/dri/%s none bind,optional,create=file\n' \
      "$DRI_BY_PATH" "$GPU1_PCI" "$render"
    printf 'lxc.mount.entry: %s/pci-%s-card dev/dri/%s none bind,optional,create=file\n' \
      "$DRI_BY_PATH" "$GPU1_PCI" "$card"
  } >>"$CONF"
  log "GPU 1 (${GPU1_PCI}) attached to CT ${VMID} as ${render}, ${card}"
}

detach_gpu1() {
  backup_conf
  grep -v "pci-${GPU1_PCI}-\(render\|card\)" "$CONF" >"${BAK_DIR}/${VMID}.conf.new"
  rewrite_conf
  log "GPU 1 detached from CT ${VMID}"
}

# CT 120 must not autostart onto GPU 1 while CT 123 holds it.
ct120_release_gpu1() {
  local v st
  st="$(pct status 120 2>/dev/null | awk '{print $2}')"
  [ "$st" = "stopped" ] || die "CT 120 is '${st}'; shut it down first (stop Hermes, CT 121, before it)"
  if [ ! -f "$CT120_ONBOOT_FILE" ]; then
    v="$(pct config 120 | awk -F': ' '$1 == "onboot" {print $2}')"
    install -d -m 0700 "$BAK_DIR"
    echo "${v:-0}" >"$CT120_ONBOOT_FILE"
  fi
  pct set 120 --onboot 0 || die "could not clear CT 120 onboot"
  log "CT 120 autostart off while CT ${VMID} holds GPU 1 (was onboot=$(cat "$CT120_ONBOOT_FILE"))"
}

ct120_restore() {
  [ -f "$CT120_ONBOOT_FILE" ] || return 0
  pct set 120 --onboot "$(cat "$CT120_ONBOOT_FILE")" || die "could not restore CT 120 onboot"
  log "CT 120 onboot=$(cat "$CT120_ONBOOT_FILE") restored; CT 120 stays stopped until the owner starts it"
  rm -f "$CT120_ONBOOT_FILE"
}

set_map() {   # <map>
  local want="$1" map
  [ -f "$WATCHDOG_ENV" ] || die "no ${WATCHDOG_ENV}: the watchdog is not installed"
  map="$(grep -m1 '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV" | cut -d= -f2-)"
  [ "$want" = "$map" ] && { log "watchdog map already ${map}"; return 0; }
  install -d -m 0700 "$BAK_DIR"
  cp -a "$WATCHDOG_ENV" "${BAK_DIR}/gpu-thermal-watchdog.env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  if grep -q '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV"; then
    sed -i "s|^GPU_SERVICE_MAP=.*|GPU_SERVICE_MAP=${want}|" "$WATCHDOG_ENV"
  else
    printf 'GPU_SERVICE_MAP=%s\n' "$want" >>"$WATCHDOG_ENV"
  fi
  systemctl restart gpu-thermal-watchdog
  log "watchdog map -> ${want} (service restarted)"
}

restart_ct() {
  log "restarting CT ${VMID} to apply its device changes; both engines stop until the switch"
  in_ct systemctl disable --now "$LLAMACPP_UNIT" "$STRATA_UNIT" 2>/dev/null || true
  pct reboot "$VMID"
  for _ in $(seq 1 60); do in_ct true 2>/dev/null && break; sleep 2; done
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

# <unit to run> <unit to stop> <watchdog map>
switch_to() {
  local on="$1" off="$2" map="$3"
  in_ct test -f "/etc/systemd/system/${on}.service" || die "CT ${VMID} has no ${on}.service; run install.sh"
  in_ct systemctl disable --now "$off" 2>/dev/null || true
  in_ct systemctl enable "$on" >/dev/null
  set_map "$map"
  in_ct systemctl start "$on"
  wait_serving "$on"
}

# Bring CT 123 to one card (GPU 2) or two, with /dev/kfd and the matching DRM rule; restart
# it once if anything changed.
set_cards() {   # one | two
  local restart=false
  if [ "$1" = two ]; then
    ct120_release_gpu1
    gpu1_attached || { attach_gpu1; restart=true; }
  else
    gpu1_attached && { detach_gpu1; restart=true; }
  fi
  ensure_kfd || restart=true
  ensure_drm_cgroup || restart=true
  [ "$restart" = true ] && restart_ct
  in_ct test -c /dev/kfd || die "/dev/kfd is absent in CT ${VMID}"
  if [ "$1" = one ]; then ct120_restore; fi
}

status() {
  local map
  map="$(grep -m1 '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV" 2>/dev/null | cut -d= -f2-)"
  echo "  watchdog map: ${map:-MISSING}"
  echo "  cards:        $(grep -oE 'pci-0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]-render' "$CONF" | sed 's/^pci-//; s/-render$//' | paste -sd' ' -)"
  echo "  /dev/kfd:     config $(grep -cE '^dev[0-9]+: /dev/kfd' "$CONF"), in CT $(in_ct test -c /dev/kfd && echo yes || echo no)"
  echo "  DRM cgroup:   $(grep '^lxc.cgroup2.devices.allow: c 226:' "$CONF" | awk '{print $3}' | paste -sd' ' -)"
  echo "  CT 120:       $(pct status 120 | awk '{print $2}'), onboot=$(pct config 120 | awk -F': ' '$1 == "onboot" {print $2}')"
  for u in "$LLAMACPP_UNIT" "$STRATA_UNIT"; do
    echo "  ${u}: $(in_ct systemctl is-active "$u" 2>&1 | head -1)/$(in_ct systemctl is-enabled "$u" 2>&1 | head -1)"
  done
}

case "${1:-}" in
  status)
    status
    ;;
  strata)
    assert_owns_gpu2
    set_cards one
    switch_to "$STRATA_UNIT" "$LLAMACPP_UNIT" "${GPU1_PCI}=120:${CT120_UNIT},${GPU2_PCI}=${VMID}:${STRATA_UNIT}"
    status
    ;;
  strata-two-card)
    assert_owns_gpu2
    set_cards two
    switch_to "$STRATA_UNIT" "$LLAMACPP_UNIT" "${GPU1_PCI}=${VMID}:${STRATA_UNIT},${GPU2_PCI}=${VMID}:${STRATA_UNIT}"
    status
    ;;
  llamacpp)
    assert_owns_gpu2
    set_cards one
    switch_to "$LLAMACPP_UNIT" "$STRATA_UNIT" "${GPU1_PCI}=120:${CT120_UNIT},${GPU2_PCI}=${VMID}:${LLAMACPP_UNIT}"
    status
    ;;
  *)
    sed -n '2,19p' "$0"
    exit 2
    ;;
esac
