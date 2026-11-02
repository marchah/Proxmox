#!/usr/bin/env bash
# Hand GPU 2 (0000:83:00.0) between Flash-Next on CT 123 and one of the DeepSeek-V4.1-Flash
# containers (README.md): CT 125 ds41-strata (upstream Strata's engine) or CT 126 ds41-llama
# (llama.cpp). Runs on the Proxmox HOST as root, after create-lxc-ds41-engine.sh.
#
#   ./ds41-host.sh take <125|126>   # GPU 2 to that container; CT 123 and the other one
#                                   # stopped with autostart off
#   ./ds41-host.sh restore          # both stopped and off the card; Flash-Next back on GPU 2
#   ./ds41-host.sh status
#
# Both directions keep the lab's two invariants, across a host reboot too: no two
# containers own a card, and the thermal watchdog maps each card to the workload on it.
# The DeepSeek containers' GPU runs belong to no unit, so the map entry is `<ct>:@container`:
# a trip stops the whole container. Only the container holding GPU 2 starts at boot. The
# other one can still be started by hand for CPU work, without the card and with
# SHARED_MEMORY_MIB.
#
# The containers are unprivileged and take GPU 2 through Proxmox device entries. Their device
# cgroup still allows every device no rule denies, and KFD reports every GPU whose render
# node the cgroup allows; with GPU 1 in that list ROCm 10 fails ("Failed to set mem policy
# for GPU") and finds no device (../strata/README.md). So `take` also denies GPU 1's DRM nodes.
set -Eeuo pipefail

readonly DS_CTS="125 126"
readonly CT123=123
readonly LXC_CONF_DIR="${LXC_CONF_DIR:-/etc/pve/lxc}"
readonly CT120_CONF="${CT120_CONF:-${LXC_CONF_DIR}/120.conf}"
readonly STATE_DIR="${STATE_DIR:-/root/ds41}"
readonly DRI_BY_PATH="${DRI_BY_PATH:-/dev/dri/by-path}"
readonly WATCHDOG_ENV="${WATCHDOG_ENV:-/etc/gpu-thermal-watchdog.env}"
readonly KFD_NODE="${KFD_NODE:-/dev/kfd}"
readonly MEMINFO="${MEMINFO:-/proc/meminfo}"
readonly GPU1_PCI='0000:03:00.0'
readonly GPU2_PCI='0000:83:00.0'
# Left to the host after the GPU 2 container's limit and every other running guest's.
readonly HOST_RESERVE_MIB="${HOST_RESERVE_MIB:-16384}"
# A DeepSeek container's limit without GPU 2, as create-lxc-ds41-engine.sh creates it.
readonly SHARED_MEMORY_MIB="${SHARED_MEMORY_MIB:-65536}"

# Saved by the first `take`, put back and removed by `restore`.
readonly CT123_ONBOOT_FILE="${STATE_DIR}/123.onboot.before-take"
readonly MAP_FILE="${STATE_DIR}/watchdog-map.before-take"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"; }
ct_state() { pct status "$1" 2>/dev/null | awk '{print $2}'; }
ct_exists() { [ -n "$(ct_state "$1")" ]; }
onboot_of() { pct config "$1" | awk -F': ' '$1 == "onboot" {v = $2} END {print v + 0}'; }
memory_of() { pct config "$1" | awk -F': ' '$1 == "memory" {print $2}'; }
current_map() { grep -m1 '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV" 2>/dev/null | cut -d= -f2-; }
conf_of() { echo "${LXC_CONF_DIR}/$1.conf"; }
holds_gpu() { grep -qE '^dev[0-9]+: /dev/dri/' "$(conf_of "$1")"; }  # <ct>

set_watchdog_map() {  # <map>
  local want="$1"
  [ -f "$WATCHDOG_ENV" ] || die "${WATCHDOG_ENV} missing: no thermal watchdog to point at the container"
  [ "$(current_map)" = "$want" ] && return 0
  cp -a "$WATCHDOG_ENV" "${STATE_DIR}/gpu-thermal-watchdog.env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  if grep -q '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV"; then
    sed -i "s|^GPU_SERVICE_MAP=.*|GPU_SERVICE_MAP=${want}|" "$WATCHDOG_ENV"
  else
    printf 'GPU_SERVICE_MAP=%s\n' "$want" >>"$WATCHDOG_ENV"
  fi
  systemctl restart gpu-thermal-watchdog
  log "watchdog map -> ${want}"
}

# GPU 1's entry stays whatever owns GPU 1 now (CT 120's server).
gpu1_entry() {
  local e
  e="$(current_map | tr ',' '\n' | grep "^${GPU1_PCI}=" || true)"
  echo "${e:-${GPU1_PCI}=120:llamacpp}"
}

node_of() {  # <pci> <card|render>: the card's real node name, e.g. renderD128
  local n
  n="$(basename "$(readlink -f "${DRI_BY_PATH}/pci-$1-$2")")"
  [[ $n =~ ^(card|renderD)[0-9]+$ ]] || die "${DRI_BY_PATH}/pci-$1-$2 does not resolve to a DRM node"
  echo "$n"
}

ct_gid() { pct exec "$1" -- getent group "$2" | cut -d: -f3; }  # <ct> <group>

# A two-card setup gives a DeepSeek container GPU 1 as well; this script only moves GPU 2.
holds_gpu1() {  # <ct>
  local render card
  render="$(node_of "$GPU1_PCI" render)"; card="$(node_of "$GPU1_PCI" card)"
  grep -qE "^dev[0-9]+: /dev/dri/(${render}|${card})," "$(conf_of "$1")"
}

# The memory every running guest but <ct> and CT 123 leaves, less the host reserve.
dev_memory_mib() {  # <ct>
  local total others=0 id m
  total=$(( $(awk '/^MemTotal:/ {print $2}' "$MEMINFO") / 1024 ))
  for id in $(pct list | awk 'NR > 1 && $2 == "running" {print $1}'); do
    { [ "$id" = "$1" ] || [ "$id" = "$CT123" ]; } && continue
    m="$(memory_of "$id")"
    others=$(( others + ${m:-512} ))
  done
  for id in $(qm list | awk 'NR > 1 && $3 == "running" {print $1}'); do
    m="$(qm config "$id" | awk -F': ' '$1 == "memory" {print $2}')"
    others=$(( others + ${m:-512} ))
  done
  echo $(( total - others - HOST_RESERVE_MIB ))
}

# /dev/kfd and GPU 2's nodes at their real names: HIP opens /dev/dri/renderD*, and a
# different name inside the container breaks DRM authentication (../README.md).
# Returns 1 when it changed the entries, which a container restart applies.
attach_gpu2() {  # <ct>
  local ct="$1" conf render card rgid vgid want have
  conf="$(conf_of "$ct")"
  render="$(node_of "$GPU2_PCI" render)"; card="$(node_of "$GPU2_PCI" card)"
  rgid="$(ct_gid "$ct" render)"; vgid="$(ct_gid "$ct" video)"
  [[ $rgid =~ ^[0-9]+$ && $vgid =~ ^[0-9]+$ ]] || die "CT ${ct} has no render or video group"
  want="$(printf 'dev0: %s,gid=%s,mode=0660\ndev1: /dev/dri/%s,gid=%s,mode=0660\ndev2: /dev/dri/%s,gid=%s,mode=0660' \
    "$KFD_NODE" "$rgid" "$render" "$rgid" "$card" "$vgid")"
  have="$(grep -E '^dev[0-9]+: ' "$conf" || true)"
  [ "$have" = "$want" ] && return 0
  [ -z "$(grep -vE "^dev[0-9]+: (${KFD_NODE}|/dev/dri/)" <<<"$have" || true)" ] \
    || die "CT ${ct} passes through other devices; review ${conf}"
  detach_gpus "$ct"
  pct set "$ct" --dev0 "${KFD_NODE},gid=${rgid},mode=0660" \
    --dev1 "/dev/dri/${render},gid=${rgid},mode=0660" --dev2 "/dev/dri/${card},gid=${vgid},mode=0660"
  log "GPU 2 (${GPU2_PCI}) -> CT ${ct} as ${render}, ${card}, with /dev/kfd"
  return 1
}

# Rewrite in place from a filtered copy: /etc/pve is the cluster filesystem.
strip_drm_denies() {  # <ct>
  local conf
  conf="$(conf_of "$1")"
  grep -q '^lxc.cgroup2.devices.deny: c 226:' "$conf" || return 0
  grep -v '^lxc.cgroup2.devices.deny: c 226:' "$conf" >"${STATE_DIR}/$1.conf.new" || true
  cat "${STATE_DIR}/$1.conf.new" >"$conf"
  rm -f "${STATE_DIR}/$1.conf.new"
}

# Deny GPU 1's render and card nodes, at their current minors. Returns 1 when it changed
# the rules, which a container restart applies.
deny_gpu1() {  # <ct>
  local ct="$1" conf kind node want="" have
  conf="$(conf_of "$ct")"
  for kind in render card; do
    node="$(readlink -f "${DRI_BY_PATH}/pci-${GPU1_PCI}-${kind}")"
    [ "$(stat -L -c %F "$node" 2>/dev/null)" = "character special file" ] \
      || die "${DRI_BY_PATH}/pci-${GPU1_PCI}-${kind} does not resolve to a device node"
    want+="lxc.cgroup2.devices.deny: c 226:$((16#$(stat -c %T "$node"))) rwm"$'\n'
  done
  have="$(grep '^lxc.cgroup2.devices.deny: c 226:' "$conf" || true)"
  [ "${have}"$'\n' = "$want" ] && return 0
  cp -a "$conf" "${STATE_DIR}/${ct}.conf.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  strip_drm_denies "$ct"
  printf '%s' "$want" >>"$conf"
  log "CT ${ct} denies GPU 1's DRM nodes: $(grep -o 'c 226:[0-9]*' <<<"$want" | paste -sd' ' -)"
  return 1
}

detach_gpus() {  # <ct>
  local keys
  keys="$(grep -E "^dev[0-9]+: (${KFD_NODE}|/dev/dri/)" "$(conf_of "$1")" | cut -d: -f1 || true)"
  [ -n "$keys" ] || return 0
  pct set "$1" --delete "$(paste -sd, - <<<"$keys")"
  log "CT $1: removed $(paste -sd' ' - <<<"$keys")"
}

stop_ct() {  # <ct>
  [ "$(ct_state "$1")" = running ] || return 0
  log "stopping CT $1"
  pct shutdown "$1" --timeout 60 || pct stop "$1"
}

start_ct() {  # <ct>
  [ "$(ct_state "$1")" = running ] || { log "starting CT $1"; pct start "$1"; }
  for _ in $(seq 1 30); do
    pct exec "$1" -- test -d /run/systemd/system 2>/dev/null && return 0
    sleep 2
  done
  die "CT $1 did not come up"
}

hip_devices() {  # <ct>: the GPUs ROCm lists for the agent user, on its login PATH
  pct exec "$1" -- runuser -u agent -- bash -lc rocminfo 2>/dev/null \
    | grep -cE '^[[:space:]]+Name:[[:space:]]+gfx[0-9a-f]+[[:space:]]*$' || true
}

# A DeepSeek container without the card: stopped, no autostart, the shared memory limit,
# no GPU entries and no deny rules.
release() {  # <ct>
  ct_exists "$1" || return 0
  stop_ct "$1"
  pct set "$1" --onboot 0 --memory "$SHARED_MEMORY_MIB"
  detach_gpus "$1"
  strip_drm_denies "$1"
}

preflight_take() {  # <ct>
  local ct="$1" other
  [[ " ${DS_CTS} " == *" ${ct} "* ]] || die "take one of: ${DS_CTS}"
  ct_exists "$ct" || die "CT ${ct} does not exist; create-lxc-ds41-engine.sh creates it"
  if grep -q "pci-${GPU2_PCI}-render" "$CT120_CONF" 2>/dev/null; then
    die "CT 120 holds GPU 2 (two-card cutover); ../qwen38-flash-next/ct120-cutover.sh to-qwen36 first"
  fi
  for other in $DS_CTS; do
    ct_exists "$other" || continue
    ! holds_gpu1 "$other" || die "CT ${other} holds GPU 1 (two-card setup); undo it first"
  done
  [ "$(stat -L -c %F "$KFD_NODE" 2>/dev/null)" = "character special file" ] || die "the host has no ${KFD_NODE}"
  node_of "$GPU2_PCI" render >/dev/null; node_of "$GPU2_PCI" card >/dev/null
}

take() {  # <ct>
  local ct="$1" other restart=false mem
  preflight_take "$ct"
  install -d -m 0700 "$STATE_DIR"
  [ -f "$CT123_ONBOOT_FILE" ] || onboot_of "$CT123" >"$CT123_ONBOOT_FILE"
  [ -f "$MAP_FILE" ] || current_map >"$MAP_FILE"

  if [ "$(ct_state "$CT123")" = running ]; then
    log "stopping CT ${CT123} (Flash-Next)"
    pct shutdown "$CT123" --timeout 180 || pct stop "$CT123"
  fi
  pct set "$CT123" --onboot 0
  log "CT ${CT123} stopped, autostart off (was onboot=$(cat "$CT123_ONBOOT_FILE"))"
  for other in $DS_CTS; do
    [ "$other" = "$ct" ] || release "$other"
  done

  set_watchdog_map "$(gpu1_entry),${GPU2_PCI}=${ct}:@container"
  # The device entries take the container's own group IDs.
  start_ct "$ct"
  attach_gpu2 "$ct" || restart=true
  deny_gpu1 "$ct" || restart=true
  mem="$(dev_memory_mib "$ct")"
  [ "$mem" -gt "$SHARED_MEMORY_MIB" ] || die "only ${mem} MiB left for CT ${ct}; check the other guests' limits"
  pct set "$ct" --memory "$mem" --onboot 1
  log "CT ${ct} memory -> ${mem} MiB, autostart on"
  if [ "$restart" = true ]; then
    stop_ct "$ct"
    start_ct "$ct"
  fi
  [ "$(hip_devices "$ct")" = 1 ] || die "ROCm does not list exactly one GPU in CT ${ct}"
}

restore() {
  local ct onboot=1
  install -d -m 0700 "$STATE_DIR"
  for ct in $DS_CTS; do release "$ct"; done
  if [ -s "$MAP_FILE" ]; then
    set_watchdog_map "$(cat "$MAP_FILE")"
  else
    log "WARN: no saved watchdog map; check it names CT ${CT123}'s Flash-Next unit"
  fi
  [ -f "$CT123_ONBOOT_FILE" ] && onboot="$(cat "$CT123_ONBOOT_FILE")"
  pct set "$CT123" --onboot "$onboot"
  log "starting CT ${CT123}; its enabled Flash-Next engine loads"
  pct start "$CT123"
  rm -f "$CT123_ONBOOT_FILE" "$MAP_FILE"
  log "CT ${DS_CTS// / and } stay stopped; start one without the GPU, or run take again"
}

status() {
  local ct d pci
  for ct in $DS_CTS; do
    ct_exists "$ct" || continue
    printf -- '--- CT %s: %s, onboot=%s, memory=%s MiB ---\n' "$ct" "$(ct_state "$ct")" \
      "$(onboot_of "$ct")" "$(memory_of "$ct")"
    grep -E '^(dev[0-9]+: |lxc.cgroup2.devices.deny: )' "$(conf_of "$ct")" | sed 's/^/  /' || echo "  (no devices)"
    if [ "$(ct_state "$ct")" = running ] && holds_gpu "$ct"; then
      echo "  ROCm lists $(hip_devices "$ct") GPU(s)"
    fi
  done
  printf -- '--- CT %s: %s, onboot=%s ---\n' "$CT123" "$(ct_state "$CT123")" "$(onboot_of "$CT123")"
  echo "--- watchdog map: $(current_map) ---"
  for pci in "$GPU1_PCI" "$GPU2_PCI"; do
    d="/sys/bus/pci/devices/${pci}"
    printf '  %s  vram=%5s MiB  gtt=%5s MiB\n' "$pci" \
      "$(( $(cat "${d}/mem_info_vram_used" 2>/dev/null || echo 0) / 1048576 ))" \
      "$(( $(cat "${d}/mem_info_gtt_used" 2>/dev/null || echo 0) / 1048576 ))"
  done
}

case "${1:-status}" in
  take) require_root; take "${2:-}" ;;
  restore) require_root; restore ;;
  status) ;;
  *) die "usage: $0 {take <125|126>|restore|status}" ;;
esac
status
