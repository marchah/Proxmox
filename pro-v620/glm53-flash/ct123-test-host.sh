#!/usr/bin/env bash
# Put CT 123 into the GLM-5.3-Flash test configurations and back. Runs on the Proxmox HOST
# as root, from this directory, after ./install.sh.
#
#   ./ct123-test-host.sh one-card   # the GLM unit owns GPU 2; Flash-Next disabled; 240 GiB, 48 cores
#   ./ct123-test-host.sh two-card   # also GPU 1, while CT 120 stays stopped with autostart off
#   ./ct123-test-host.sh restore    # Flash-Next on GPU 2 alone; CT 120's autostart restored
#   ./ct123-test-host.sh status
#
#   TEST_CPUSET=0-47 ./ct123-test-host.sh one-card   # also fix CT 123's CPUs; a run without
#                                                    # it, and restore, drop the fixed set
#
# Every transition keeps two invariants: no two containers own a card, including after a
# host reboot, and the thermal watchdog maps each card to the unit that runs on it.
# CT 120 itself is never started: that waits for the owner after a test.
#
# Without TEST_CPUSET, Proxmox gives the container a random set of `cores` CPUs at every
# start. On the 7532 (32 cores, CPU n and n+32 share one), 48 of the 64 can leave physical
# cores out: one start covered 30. TEST_CPUSET must name TEST_CORES distinct online CPUs.
set -Eeuo pipefail

readonly VMID=123
readonly CONF="${CONF:-/etc/pve/lxc/${VMID}.conf}"
readonly STATE_DIR="${STATE_DIR:-/root/glm53-flash}"
readonly DRI_BY_PATH="${DRI_BY_PATH:-/dev/dri/by-path}"
readonly WATCHDOG_ENV="${WATCHDOG_ENV:-/etc/gpu-thermal-watchdog.env}"
readonly CPU_ONLINE="${CPU_ONLINE:-/sys/devices/system/cpu/online}"

readonly GPU1_PCI='0000:03:00.0'
readonly GPU2_PCI='0000:83:00.0'
readonly TEST_UNIT=llamacpp-glm53f
readonly PROD_UNIT=llamacpp-qwen38fn
readonly CT120_UNIT=llamacpp

# The test's limits: the model under auto page cache or dio pinning (~200 GB), and room
# for 32 threads without the threads = cores collapse seen on CT 123 at 24/24.
readonly TEST_MEMORY_MIB=245760
readonly TEST_CORES=48
readonly TEST_CPUSET="${TEST_CPUSET:-}"

readonly LIMITS_FILE="${STATE_DIR}/123.limits.before-test"
readonly CT120_ONBOOT_FILE="${STATE_DIR}/120.onboot.before-test"
readonly CPUSET_KEY='lxc.cgroup2.cpuset.cpus'

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"; }
ct_state() { pct status "$1" 2>/dev/null | awk '{print $2}'; }
gpu1_attached() { grep -q "pci-${GPU1_PCI}-render" "$CONF"; }

# Disable and stop a unit, then check it is gone: a unit that survives would fight the
# incoming server for the card and port 1234 (see ct120-cutover.sh, retire_unit).
retire_unit() {  # <vmid> <unit>
  local vm="$1" unit="$2"
  pct exec "$vm" -- systemctl disable --now "$unit" >/dev/null 2>&1 || true
  if pct exec "$vm" -- systemctl is-enabled "$unit" >/dev/null 2>&1; then
    die "CT ${vm}: ${unit} is still enabled after disabling it; retire it by hand, then re-run"
  fi
  if pct exec "$vm" -- systemctl is-active "$unit" >/dev/null 2>&1; then
    die "CT ${vm}: ${unit} is still active after stopping it; stop it by hand, then re-run"
  fi
}

set_watchdog_map() {  # <map>
  local want="$1"
  [ -f "$WATCHDOG_ENV" ] || die "${WATCHDOG_ENV} missing: no thermal watchdog to point at the test unit"
  cp -a "$WATCHDOG_ENV" "${STATE_DIR}/gpu-thermal-watchdog.env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  if grep -q '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV"; then
    sed -i "s|^GPU_SERVICE_MAP=.*|GPU_SERVICE_MAP=${want}|" "$WATCHDOG_ENV"
  else
    printf 'GPU_SERVICE_MAP=%s\n' "$want" >>"$WATCHDOG_ENV"
  fi
  systemctl restart gpu-thermal-watchdog
  log "watchdog map -> ${want}"
}

# Record CT 123's limits once, before the first change, so restore puts back what was there.
save_limits() {
  [ -f "$LIMITS_FILE" ] && return 0
  pct config "$VMID" | awk -F': ' '$1 == "memory" || $1 == "cores" || $1 == "swap" {print $1, $2}' >"$LIMITS_FILE"
  log "saved CT ${VMID} limits: $(tr '\n' ' ' <"$LIMITS_FILE")"
}

restart_ct() {
  log "restarting CT ${VMID}"
  if [ "$(ct_state "$VMID")" = "running" ]; then pct stop "$VMID"; sleep 4; fi
  pct start "$VMID"
  # degraded counts as up: apparmor.service always fails in this unprivileged container.
  # is-system-running exits non-zero for degraded, so read its output, not its status.
  local st
  for _ in $(seq 1 30); do
    st="$(pct exec "$VMID" -- systemctl is-system-running 2>/dev/null || true)"
    case "$st" in running | degraded) return 0 ;; esac
    sleep 2
  done
  log "WARN: CT ${VMID} not fully up after 60 s"
}

require_glm_installed() {
  pct exec "$VMID" -- test -f "/etc/systemd/system/${TEST_UNIT}.service" \
    || die "${TEST_UNIT} not installed in CT ${VMID}; run VMID=${VMID} ./install.sh first"
  # shellcheck disable=SC2016  # expands inside the container
  pct exec "$VMID" -- bash -c '
    n=$(ls /models/hf/glm-5.3-flash/*.verified 2>/dev/null | wc -l)
    [ "$n" -ge 7 ] || { echo "only ${n}/7 model files verified; run install.sh --download"; exit 1; }' \
    || die "model files not verified"
}

# GPU 1 is mounted at its REAL host node names: a different name inside the container
# makes RADV fail DRM auth, and llama.cpp then falls back to the CPU silently.
attach_gpu1() {
  local render card
  render="$(basename "$(readlink -f "${DRI_BY_PATH}/pci-${GPU1_PCI}-render")")"
  card="$(basename "$(readlink -f "${DRI_BY_PATH}/pci-${GPU1_PCI}-card")")"
  [[ "$render" =~ ^renderD[0-9]+$ && "$card" =~ ^card[0-9]+$ ]] \
    || die "GPU 1 by-path nodes missing or unexpected (${render}, ${card})"
  if grep -qE "dev/dri/(${render}|${card}) " "$CONF"; then
    die "CT ${VMID} already mounts dev/dri/${render} or dev/dri/${card} from another card"
  fi
  cp -a "$CONF" "${STATE_DIR}/123.conf.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  {
    printf 'lxc.mount.entry: %s/pci-%s-render dev/dri/%s none bind,optional,create=file\n' \
      "$DRI_BY_PATH" "$GPU1_PCI" "$render"
    printf 'lxc.mount.entry: %s/pci-%s-card dev/dri/%s none bind,optional,create=file\n' \
      "$DRI_BY_PATH" "$GPU1_PCI" "$card"
  } >>"$CONF"
  log "GPU 1 (${GPU1_PCI}) attached to CT ${VMID} as ${render}, ${card}"
}

detach_gpu1() {
  cp -a "$CONF" "${STATE_DIR}/123.conf.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  grep -v "pci-${GPU1_PCI}-\(render\|card\)" "$CONF" >"${STATE_DIR}/123.conf.new"
  cat "${STATE_DIR}/123.conf.new" >"$CONF"
  log "GPU 1 detached from CT ${VMID}"
}

# The CPUs a cpuset list such as 0-3,8,40-47 names, one per line; fails on a reversed range.
cpuset_cpus() {
  local part lo hi c
  for part in ${1//,/ }; do
    lo="${part%-*}"; hi="${part#*-}"
    (( lo <= hi )) || return 1
    for (( c = lo; c <= hi; c++ )); do echo "$c"; done
  done
}

# Physical cores a cpuset list covers, from the host's CPU-to-core map.
cpuset_cores() {
  local want
  want=" $(cpuset_cpus "$1" | tr '\n' ' ')"
  lscpu -p=CPU,CORE | awk -F, -v want="$want" '!/^#/ && index(want, " " $1 " ") { seen[$2] = 1 }
    END { print length(seen) }'
}

# TEST_CPUSET must name TEST_CORES CPUs, each once and each online on this host.
check_cpuset() {
  local cpus online twice missing
  [[ "$TEST_CPUSET" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] \
    || die "TEST_CPUSET '${TEST_CPUSET}' is not a CPU list such as 0-47"
  cpus="$(cpuset_cpus "$TEST_CPUSET")" || die "TEST_CPUSET '${TEST_CPUSET}' has a range that runs backwards"
  twice="$(sort -n <<<"$cpus" | uniq -d | tr '\n' ' ')"
  [ -z "$twice" ] || die "TEST_CPUSET '${TEST_CPUSET}' names CPUs more than once: ${twice% }"
  online="$(cpuset_cpus "$(cat "$CPU_ONLINE")")" || die "cannot read the host's online CPUs from ${CPU_ONLINE}"
  missing="$(comm -23 <(sort -u <<<"$cpus") <(sort -u <<<"$online") | sort -n | tr '\n' ' ')"
  [ -z "$missing" ] || die "TEST_CPUSET '${TEST_CPUSET}' names CPUs the host does not have online: ${missing% }"
  [ "$(wc -l <<<"$cpus")" -eq "$TEST_CORES" ] \
    || die "TEST_CPUSET names $(wc -l <<<"$cpus" | tr -d ' ') CPUs; CT ${VMID} gets ${TEST_CORES}"
}

# An explicit cpuset stops Proxmox picking CPUs at start; drop_cpuset gives that back.
set_cpuset() {
  cp -a "$CONF" "${STATE_DIR}/123.conf.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  grep -v "^${CPUSET_KEY}:" "$CONF" >"${STATE_DIR}/123.conf.new"
  printf '%s: %s\n' "$CPUSET_KEY" "$TEST_CPUSET" >>"${STATE_DIR}/123.conf.new"
  cat "${STATE_DIR}/123.conf.new" >"$CONF"
  log "CT ${VMID} cpuset -> ${TEST_CPUSET}"
}

drop_cpuset() {
  grep -q "^${CPUSET_KEY}:" "$CONF" || return 0
  cp -a "$CONF" "${STATE_DIR}/123.conf.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  grep -v "^${CPUSET_KEY}:" "$CONF" >"${STATE_DIR}/123.conf.new"
  cat "${STATE_DIR}/123.conf.new" >"$CONF"
  log "CT ${VMID} cpuset removed; Proxmox picks the CPUs again"
}

# CT 120 must not autostart onto GPU 1 while CT 123 holds it.
ct120_release_gpu1() {
  local v
  if [ ! -f "$CT120_ONBOOT_FILE" ]; then
    v="$(pct config 120 | awk -F': ' '$1 == "onboot" {print $2}')"
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

# The V620s llama-server sees in CT 123, with any device filter left out.
devices_offered() {
  # shellcheck disable=SC2016  # expands inside the container
  pct exec "$VMID" -- bash -c '
    D=$(. /etc/llamacpp-glm53f.env && printf "%s" "$LLAMACPP_DIR")
    LD_LIBRARY_PATH=$D $D/llama-server --list-devices 2>/dev/null | grep -c V620' 2>/dev/null || true
}

# Every check before the first change, so a refusal leaves the host as it was.
preflight() {  # [two-card]
  local st
  [ "$(ct_state "$VMID")" = "running" ] || die "CT ${VMID} is not running"
  require_glm_installed
  [ -z "$TEST_CPUSET" ] || check_cpuset
  if [ "${1:-}" = two-card ]; then
    st="$(ct_state 120)"
    [ "$st" = "stopped" ] || die "CT 120 is '${st}'; shut it down first (stop Hermes, CT 121, before it)"
    [ -e "${DRI_BY_PATH}/pci-${GPU1_PCI}-render" ] || die "GPU 1 by-path render node missing on the host"
  fi
}

prepare_ct123() {
  save_limits
  log "retiring ${PROD_UNIT} in CT ${VMID} for the test"
  retire_unit "$VMID" "$PROD_UNIT"
  retire_unit "$VMID" "$TEST_UNIT"
  pct set "$VMID" --memory "$TEST_MEMORY_MIB" --cores "$TEST_CORES"
  if [ -n "$TEST_CPUSET" ]; then set_cpuset; else drop_cpuset; fi
}

status() {
  echo "--- CT ${VMID} DRM entries ---"
  grep -n 'dev/dri' "$CONF" | sed 's/^/  /' || echo "  (none)"
  echo "--- CT ${VMID} limits ---"
  pct config "$VMID" | grep -E '^(cores|memory|swap|onboot)' | sed 's/^/  /'
  [ -f "$LIMITS_FILE" ] && echo "  (before the test: $(tr '\n' ' ' <"$LIMITS_FILE"))"
  if [ "$(ct_state "$VMID")" = "running" ]; then
    local cpus
    cpus="$(cat "/sys/fs/cgroup/lxc/${VMID}/cpuset.cpus.effective" 2>/dev/null || true)"
    echo "--- CT ${VMID} CPUs: ${cpus:-unknown} ($(grep -q "^${CPUSET_KEY}:" "$CONF" && echo fixed || echo "picked by Proxmox"))"
    [ -n "$cpus" ] && echo "    physical cores covered: $(cpuset_cores "$cpus") of $(lscpu -p=CORE | grep -v '^#' | sort -u | wc -l)"
    echo "--- V620s llama-server sees in CT ${VMID}: $(devices_offered) ---"
    for u in "$TEST_UNIT" "$PROD_UNIT"; do
      printf '  %-20s enabled=%-10s active=%s\n' "$u" \
        "$(pct exec "$VMID" -- systemctl is-enabled "$u" 2>&1 | head -1)" \
        "$(pct exec "$VMID" -- systemctl is-active "$u" 2>&1 | head -1)"
    done
  else
    echo "--- CT ${VMID} is $(ct_state "$VMID") ---"
  fi
  printf -- '--- CT 120: status=%s onboot=%s ---\n' "$(ct_state 120)" \
    "$(pct config 120 | awk -F': ' '$1 == "onboot" {print $2}')"
  if gpu1_attached && [ "$(pct config 120 | awk -F': ' '$1 == "onboot" {print $2}')" = "1" ]; then
    echo "  🔴 CT ${VMID} holds GPU 1 while CT 120 autostarts: a host reboot puts two servers"
    echo "     on one card. Run: pct set 120 --onboot 0"
  fi
  echo "--- watchdog map ---"
  grep -m1 '^GPU_SERVICE_MAP=' "$WATCHDOG_ENV" 2>/dev/null | sed 's/^/  /' || echo "  (unset)"
  echo "--- per-card VRAM / GTT ---"
  local pci d
  for pci in "$GPU1_PCI" "$GPU2_PCI"; do
    d="/sys/bus/pci/devices/${pci}"
    printf '  %s  vram=%5s MiB  gtt=%5s MiB\n' "$pci" \
      "$(( $(cat "${d}/mem_info_vram_used" 2>/dev/null || echo 0) / 1048576 ))" \
      "$(( $(cat "${d}/mem_info_gtt_used" 2>/dev/null || echo 0) / 1048576 ))"
  done
}

main() {
  case "${1:-status}" in
    one-card)
      require_root; mkdir -p "$STATE_DIR"
      preflight
      prepare_ct123
      gpu1_attached && detach_gpu1
      restart_ct
      ct120_restore
      set_watchdog_map "${GPU1_PCI}=120:${CT120_UNIT},${GPU2_PCI}=${VMID}:${TEST_UNIT}"
      [ "$(devices_offered)" -eq 1 ] || die "llama-server does not see exactly one V620 in CT ${VMID}"
      ;;
    two-card)
      require_root; mkdir -p "$STATE_DIR"
      preflight two-card
      ct120_release_gpu1
      prepare_ct123
      gpu1_attached || attach_gpu1
      restart_ct
      set_watchdog_map "${GPU1_PCI}=${VMID}:${TEST_UNIT},${GPU2_PCI}=${VMID}:${TEST_UNIT}"
      [ "$(devices_offered)" -eq 2 ] || die "llama-server does not see two V620s in CT ${VMID}"
      echo "Vulkan device order in CT ${VMID} (the index MODEL_VK_VISIBLE_DEVICES takes):"
      pct exec "$VMID" -- bash -c "vulkaninfo --summary 2>/dev/null | grep -E '^GPU[0-9]+:|deviceName|deviceUUID'" \
        | sed 's/^/  /' || true
      ;;
    restore)
      require_root; mkdir -p "$STATE_DIR"
      [ "$(ct_state "$VMID")" = "running" ] && retire_unit "$VMID" "$TEST_UNIT"
      gpu1_attached && detach_gpu1
      if [ -f "$LIMITS_FILE" ]; then
        local k v
        while read -r k v; do pct set "$VMID" "--${k}" "$v"; done <"$LIMITS_FILE"
        rm -f "$LIMITS_FILE"
      fi
      drop_cpuset
      restart_ct
      ct120_restore
      set_watchdog_map "${GPU1_PCI}=120:${CT120_UNIT},${GPU2_PCI}=${VMID}:${PROD_UNIT}"
      pct exec "$VMID" -- systemctl enable --now "$PROD_UNIT"
      log "${PROD_UNIT} enabled and loading; check its VRAM once it serves"
      ;;
    status) ;;
    *) die "usage: $0 {one-card|two-card|restore|status}" ;;
  esac
  status
}

main "$@"
