#!/usr/bin/env bash
# Hand GPU 2 (0000:83:00.0) between Flash-Next on CT 123 and CT 124 strata-dev, where an
# agent develops the DeepSeek fork of Strata (PLAN.md). Runs on the Proxmox HOST as root,
# after create-lxc-strata-dev.sh.
#
#   ./strata-dev-host.sh dev       # GPU 2 to CT 124; CT 123 stopped with autostart off
#   ./strata-dev-host.sh restore   # CT 124 stopped and off the card; Flash-Next back on GPU 2
#   ./strata-dev-host.sh status
#
# Both directions keep the lab's two invariants, across a host reboot too: no two
# containers own a card, and the thermal watchdog maps each card to the workload on it.
# The agent's GPU runs belong to no unit, so CT 124's map entry is `124:@container`: a
# trip stops the whole container. Two-card tests come after the one-card work (PLAN.md).
#
# CT 124 is unprivileged and takes GPU 2 through Proxmox device entries, which allow only
# those device numbers in its cgroup: the narrow DRM rule HIP needs (../strata/README.md).
set -Eeuo pipefail

readonly VMID="${VMID:-124}"
readonly CT123=123
readonly CONF="${CONF:-/etc/pve/lxc/${VMID}.conf}"
readonly CT120_CONF="${CT120_CONF:-/etc/pve/lxc/120.conf}"
readonly STATE_DIR="${STATE_DIR:-/root/strata-dev}"
readonly DRI_BY_PATH="${DRI_BY_PATH:-/dev/dri/by-path}"
readonly WATCHDOG_ENV="${WATCHDOG_ENV:-/etc/gpu-thermal-watchdog.env}"
readonly KFD_NODE="${KFD_NODE:-/dev/kfd}"
readonly GPU1_PCI='0000:03:00.0'
readonly GPU2_PCI='0000:83:00.0'
# Left to the host after CT 124's limit and every other running guest's.
readonly HOST_RESERVE_MIB="${HOST_RESERVE_MIB:-16384}"
# CT 124's limit while CT 123 runs, as create-lxc-strata-dev.sh creates it.
readonly SHARED_MEMORY_MIB="${SHARED_MEMORY_MIB:-65536}"
readonly ROCMINFO=/opt/rocm/core-10.0/bin/rocminfo

# Saved by the first `dev`, put back and removed by `restore`.
readonly CT123_ONBOOT_FILE="${STATE_DIR}/123.onboot.before-dev"
readonly MAP_FILE="${STATE_DIR}/watchdog-map.before-dev"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"; }
ct_state() { pct status "$1" 2>/dev/null | awk '{print $2}'; }
onboot_of() { pct config "$1" | awk -F': ' '$1 == "onboot" {v = $2} END {print v + 0}'; }
current_map() { grep -m1 '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV" 2>/dev/null | cut -d= -f2-; }
holds_gpu() { grep -qE '^dev[0-9]+: /dev/dri/' "$CONF"; }

set_watchdog_map() {  # <map>
  local want="$1"
  [ -f "$WATCHDOG_ENV" ] || die "${WATCHDOG_ENV} missing: no thermal watchdog to point at CT ${VMID}"
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

node_of() {  # <card|render>: GPU 2's real node name, e.g. renderD128
  local n
  n="$(basename "$(readlink -f "${DRI_BY_PATH}/pci-${GPU2_PCI}-$1")")"
  [[ $n =~ ^(card|renderD)[0-9]+$ ]] || die "${DRI_BY_PATH}/pci-${GPU2_PCI}-$1 does not resolve to a DRM node"
  echo "$n"
}

ct_gid() { pct exec "$VMID" -- getent group "$1" | cut -d: -f3; }

# The memory every running guest but CT 124 and CT 123 leaves, less the host reserve.
dev_memory_mib() {
  local total others=0 id m
  total=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))
  for id in $(pct list | awk 'NR > 1 && $2 == "running" {print $1}'); do
    { [ "$id" = "$VMID" ] || [ "$id" = "$CT123" ]; } && continue
    m="$(pct config "$id" | awk -F': ' '$1 == "memory" {print $2}')"
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
attach_gpu2() {
  local render card rgid vgid want have
  render="$(node_of render)"; card="$(node_of card)"
  rgid="$(ct_gid render)"; vgid="$(ct_gid video)"
  [[ $rgid =~ ^[0-9]+$ && $vgid =~ ^[0-9]+$ ]] || die "CT ${VMID} has no render or video group"
  want="$(printf 'dev0: %s,gid=%s,mode=0660\ndev1: /dev/dri/%s,gid=%s,mode=0660\ndev2: /dev/dri/%s,gid=%s,mode=0660' \
    "$KFD_NODE" "$rgid" "$render" "$rgid" "$card" "$vgid")"
  have="$(grep -E '^dev[0-9]+: ' "$CONF" || true)"
  [ "$have" = "$want" ] && return 0
  [ -z "$(grep -vE '^dev[0-9]+: (/dev/kfd|/dev/dri/)' <<<"$have" || true)" ] \
    || die "CT ${VMID} passes through other devices; review ${CONF}"
  detach_gpus
  pct set "$VMID" --dev0 "${KFD_NODE},gid=${rgid},mode=0660" \
    --dev1 "/dev/dri/${render},gid=${rgid},mode=0660" --dev2 "/dev/dri/${card},gid=${vgid},mode=0660"
  log "GPU 2 (${GPU2_PCI}) -> CT ${VMID} as ${render}, ${card}, with /dev/kfd"
  return 1
}

detach_gpus() {
  local keys
  keys="$(grep -E '^dev[0-9]+: (/dev/kfd|/dev/dri/)' "$CONF" | cut -d: -f1 || true)"
  [ -n "$keys" ] || return 0
  pct set "$VMID" --delete "$(paste -sd, - <<<"$keys")"
  log "CT ${VMID}: removed $(paste -sd' ' - <<<"$keys")"
}

restart_ct124() {
  log "restarting CT ${VMID}"
  if [ "$(ct_state "$VMID")" = running ]; then pct shutdown "$VMID" --timeout 60 || pct stop "$VMID"; fi
  pct start "$VMID"
  for _ in $(seq 1 30); do
    pct exec "$VMID" -- test -d /run/systemd/system 2>/dev/null && return 0
    sleep 2
  done
  die "CT ${VMID} did not come back"
}

hip_devices() {  # the GPUs ROCm lists in CT 124 for the agent user
  pct exec "$VMID" -- runuser -u agent -- "$ROCMINFO" 2>/dev/null \
    | grep -cE '^[[:space:]]+Name:[[:space:]]+gfx[0-9a-f]+[[:space:]]*$' || true
}

preflight_dev() {
  [ "$(ct_state "$VMID")" = running ] || die "CT ${VMID} is not running; create-lxc-strata-dev.sh starts it"
  if grep -q "pci-${GPU2_PCI}-render" "$CT120_CONF" 2>/dev/null; then
    die "CT 120 holds GPU 2 (two-card cutover); ../qwen38-flash-next/ct120-cutover.sh to-qwen36 first"
  fi
  [ "$(stat -L -c %F "$KFD_NODE" 2>/dev/null)" = "character special file" ] || die "the host has no ${KFD_NODE}"
  node_of render >/dev/null; node_of card >/dev/null
}

dev() {
  local restart=false mem
  preflight_dev
  install -d -m 0700 "$STATE_DIR"
  [ -f "$CT123_ONBOOT_FILE" ] || onboot_of "$CT123" >"$CT123_ONBOOT_FILE"
  [ -f "$MAP_FILE" ] || current_map >"$MAP_FILE"

  if [ "$(ct_state "$CT123")" = running ]; then
    log "stopping CT ${CT123} (Flash-Next)"
    pct shutdown "$CT123" --timeout 180 || pct stop "$CT123"
  fi
  pct set "$CT123" --onboot 0
  log "CT ${CT123} stopped, autostart off (was onboot=$(cat "$CT123_ONBOOT_FILE"))"

  set_watchdog_map "$(gpu1_entry),${GPU2_PCI}=${VMID}:@container"
  attach_gpu2 || restart=true
  mem="$(dev_memory_mib)"
  [ "$mem" -gt "$SHARED_MEMORY_MIB" ] || die "only ${mem} MiB left for CT ${VMID}; check the other guests' limits"
  pct set "$VMID" --memory "$mem" --onboot 1
  log "CT ${VMID} memory -> ${mem} MiB"
  [ "$restart" = true ] && restart_ct124
  [ "$(hip_devices)" = 1 ] || die "ROCm does not list exactly one GPU in CT ${VMID}"
}

restore() {
  local onboot=1
  install -d -m 0700 "$STATE_DIR"
  if [ "$(ct_state "$VMID")" = running ]; then
    log "stopping CT ${VMID}"
    pct shutdown "$VMID" --timeout 60 || pct stop "$VMID"
  fi
  pct set "$VMID" --onboot 0 --memory "$SHARED_MEMORY_MIB"
  detach_gpus
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
  log "CT ${VMID} stays stopped; start it without the GPU, or run dev again"
}

status() {
  local d pci
  printf -- '--- CT %s: %s, onboot=%s, memory=%s MiB ---\n' "$VMID" "$(ct_state "$VMID")" \
    "$(onboot_of "$VMID")" "$(pct config "$VMID" | awk -F': ' '$1 == "memory" {print $2}')"
  grep -E '^dev[0-9]+: ' "$CONF" | sed 's/^/  /' || echo "  (no devices)"
  if [ "$(ct_state "$VMID")" = running ] && holds_gpu; then
    echo "  ROCm lists $(hip_devices) GPU(s)"
  fi
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
  dev) require_root; dev ;;
  restore) require_root; restore ;;
  status) ;;
  *) die "usage: $0 {dev|restore|status}" ;;
esac
status
