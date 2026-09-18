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

# Overridable so cutover-transition-test.sh can drive the real transitions against a mocked
# host. Defaults are the production paths; nothing else sets them.
readonly VMID="${VMID:-120}"
readonly CONF="${CONF:-/etc/pve/lxc/${VMID}.conf}"
readonly BAK_DIR="${BAK_DIR:-/root/qwen38-flash-next}"

# GPU 2. Mount at the REAL host node names — mounting at a different name inside the
# container makes RADV fail DRM auth, and llama.cpp then falls back to CPU silently.
readonly GPU2_PCI='0000:83:00.0'
readonly GPU2_RENDER_DST='renderD128'
readonly GPU2_CARD_DST='card1'
readonly GPU1_PCI='0000:03:00.0'

readonly WATCHDOG_ENV="${WATCHDOG_ENV:-/etc/gpu-thermal-watchdog.env}"
# Overridable for the mocked transition test; production value is the real udev path.
readonly DRI_BY_PATH="${DRI_BY_PATH:-/dev/dri/by-path}"

# Set when the map check fails. Deferred to the end so the status dump below still prints —
# that output is exactly what an operator needs when protection is broken.
MAP_BAD=0

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"; }

gpu2_attached() { grep -q "${GPU2_PCI}-render" "$CONF"; }

# 🔴 Retiring the OUTGOING workload is a precondition, not a courtesy. This was
# `systemctl disable --now X 2>/dev/null || true` in both directions, which swallowed a
# FAILED retirement: the script carried on attaching GPU 2, restarting the container,
# rewriting the watchdog map and enabling the incoming unit, leaving BOTH units enabled and
# active. They then contend for the card and for port 1234, and the map points only at the
# incoming one — so a thermal trip sheds the wrong load.
# ⚠️ The `|| true` on the disable itself stays, and deliberately: the unit may legitimately
# be absent (a fresh install, or a direction already taken). What is not optional is the
# CHECK. Tolerate the command failing; never tolerate the unit surviving.
retire_unit() {  # <vmid> <unit>
  local vm="$1" unit="$2"
  pct exec "$vm" -- systemctl disable --now "$unit" >/dev/null 2>&1 || true
  if pct exec "$vm" -- systemctl is-enabled "$unit" >/dev/null 2>&1; then
    die "CT ${vm}: ${unit} is still ENABLED after disabling it — it would restart with the container and fight the incoming server for the card and port 1234. Retire it by hand, then re-run."
  fi
  if pct exec "$vm" -- systemctl is-active "$unit" >/dev/null 2>&1; then
    die "CT ${vm}: ${unit} is still ACTIVE after stopping it — two model servers on one card. Stop it by hand, then re-run."
  fi
}

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

# What this checks, reported as three DISTINCT states:
#   - both known cards have a map entry at all;
#   - the target container actually has that card's render node bound in its config;
#   - the unit is active (serving), enabled-but-inactive (configured, not serving — the
#     legitimate state of a deliberately stopped CT 123 after rollback), or neither.
# It returns non-zero on a real mismatch. ⚠️ It still cannot prove which device a running
# process has open, and it says nothing about intermediate or post-reboot states — an
# end-of-script assertion structurally cannot. That is what a mocked transition test is for.
assert_map_owns_cards() {
  local map addr svc vm unit conf ct_state bad=0 seen=""
  map="$(grep -m1 '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV" 2>/dev/null | cut -d= -f2-)"
  [ -n "$map" ] || { log "🔴 watchdog map EMPTY — a trip on either card sheds no load"; return 1; }
  # ⚠️ Narrow the IFS change to the split itself. Left function-wide it also rewrites `$*`
  # for every command invoked below, which is a trap for anything added later (and it broke
  # a mocked test of this very function). Split once, restore, then use the array.
  local -a pairs=()
  local oldifs="$IFS"; IFS=','; read -ra pairs <<<"$map"; IFS="$oldifs"
  for pair in "${pairs[@]}"; do
    addr="${pair%%=*}"; svc="${pair#*=}"; vm="${svc%%:*}"; unit="${svc#*:}"
    seen="${seen} ${addr}"
    conf="${LXC_CONF_DIR:-/etc/pve/lxc}/${vm}.conf"
    if ! grep -q "pci-${addr}-render" "$conf" 2>/dev/null; then
      log "🔴 MAP MISMATCH: ${addr} -> CT ${vm}, but CT ${vm} does not bind that render node"
      bad=1
      continue
    fi
    # 🔴 `pct exec` CANNOT RUN IN A STOPPED CONTAINER, and the ordinary rollback leaves
    # CT 123 stopped on purpose (it tells you to start it afterwards). So both service
    # queries failed, the "CONFIGURED but not serving" state was unreachable for exactly the
    # container that needs it, and `to-qwen36` raised a false protection alarm and exited 1
    # on a completely correct setup. Container-stopped and unit-inactive are different
    # states and must be reported differently.
    ct_state="$(pct status "$vm" 2>/dev/null | awk '{print $2}')"
    if [ "$ct_state" != "running" ]; then
      log "  ${addr} -> ${vm}:${unit} — binding and map correct; CT ${vm} is ${ct_state:-unknown},"
      log "      so runtime service state is DEFERRED (not verifiable from outside a stopped CT)"
    elif pct exec "$vm" -- systemctl is-active "$unit" >/dev/null 2>&1; then
      log "  ${addr} -> ${vm}:${unit} — owns the card, unit ACTIVE"
    elif pct exec "$vm" -- systemctl is-enabled "$unit" >/dev/null 2>&1; then
      log "  ${addr} -> ${vm}:${unit} — owns the card, unit CONFIGURED but not serving"
    else
      log "🔴 MAP MISMATCH: ${addr} -> ${vm}:${unit} is neither active nor enabled"
      bad=1
    fi
  done
  local c
  for c in "$GPU1_PCI" "$GPU2_PCI"; do
    case "$seen" in *"$c"*) ;; *) log "🔴 ${c} has NO map entry — unprotected"; bad=1 ;; esac
  done
  if [ "$bad" -ne 0 ]; then
    log "🔴 the watchdog would be a NO-OP for at least one card — fix the map before loading"
    return 1
  fi
  log "watchdog map checked: both cards mapped to a unit in a container that binds them"
  return 0
}

# 🔴 The watchdog stops the service OWNING the hot card, so each entry must name the unit
# that is actually RUNNING on that card. A map naming a stopped or disabled unit makes a
# thermal trip a silent NO-OP — the real load keeps cooking the card with only the 105 °C
# hardware MODE1 reset behind it. While CT 120 serves qwen4exp both entries are
# `120:llamacpp-qwen38fn`; `120:llamacpp` is correct only after the revert re-enables it.
# ✅ Invariant, checked by assert_map_owns_cards: every mapped service owns the card it is
# mapped to.
set_watchdog_map() {
  local want="$1"
  [ -f "$WATCHDOG_ENV" ] || { log "watchdog env absent — skipping map update"; return 0; }
  cp -a "$WATCHDOG_ENV" "${BAK_DIR}/gpu-thermal-watchdog.env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  # ⚠️ `sed -i` here is GNU syntax. This script targets the Proxmox host, which has GNU sed;
  # it will not run as-is on a BSD/macOS box (cutover-transition-test.sh shims it).
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

    [ -e "${DRI_BY_PATH}/pci-${GPU2_PCI}-render" ] \
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

    log "retiring the qwen3.6 server"
    retire_unit "$VMID" llamacpp

    if gpu2_attached; then
      log "GPU 2 already attached to CT ${VMID}"
    else
      cp -a "$CONF" "${BAK_DIR}/120.conf.bak.$(date -u +%Y%m%dT%H%M%SZ)"
      log "attaching GPU 2 (${GPU2_PCI}) to CT ${VMID}"
      {
        printf 'lxc.mount.entry: %s/pci-%s-render dev/dri/%s none bind,optional,create=file\n' "$DRI_BY_PATH" \
          "$GPU2_PCI" "$GPU2_RENDER_DST"
        printf 'lxc.mount.entry: %s/pci-%s-card dev/dri/%s none bind,optional,create=file\n' "$DRI_BY_PATH" \
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
    assert_map_owns_cards || MAP_BAD=1
    ;;

  to-qwen36)
    require_root
    mkdir -p "$BAK_DIR"

    log "retiring the qwen4exp server"
    retire_unit "$VMID" llamacpp-qwen38fn

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
    assert_map_owns_cards || MAP_BAD=1
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
assert_map_owns_cards || MAP_BAD=1
echo "--- per-card VRAM / GTT ---"
for pci in "$GPU1_PCI" "$GPU2_PCI"; do
  d="/sys/bus/pci/devices/${pci}"
  printf '  %s  vram=%5s MiB  gtt=%5s MiB\n' "$pci" \
    "$(( $(cat "${d}/mem_info_vram_used" 2>/dev/null || echo 0) / 1048576 ))" \
    "$(( $(cat "${d}/mem_info_gtt_used"  2>/dev/null || echo 0) / 1048576 ))"
done

if [ "${MAP_BAD:-0}" -ne 0 ]; then
  echo
  echo "🔴 EXITING NON-ZERO: the thermal watchdog map does not match reality, so a trip on at"
  echo "   least one card would shed no load. Fix GPU_SERVICE_MAP in ${WATCHDOG_ENV} before"
  echo "   putting load on these cards — only the 105 °C hardware reset is behind it."
  exit 1
fi

