#!/usr/bin/env bash
# Put CT 123 into a model test's configurations and back: GLM-5.3-Flash by default, or
# MiMo-V2.6-Pro-RL with TEST_MODEL=mimo; GLM on llama.cpp by default, or on Project Maya with
# TEST_ENGINE=maya. Runs on the Proxmox HOST as root, from this directory, after the model's
# install.sh (and ../maya/install.sh for Maya).
#
#   ./ct123-test-host.sh one-card   # the GLM unit owns GPU 2; Flash-Next disabled; 240 GiB, 48 cores
#   ./ct123-test-host.sh two-card   # also GPU 1, while CT 120 stays stopped with autostart off
#   ./ct123-test-host.sh restore    # Flash-Next on GPU 2 alone; CT 120's autostart restored
#   ./ct123-test-host.sh status
#
#   TEST_CPUSET=0-47 ./ct123-test-host.sh one-card   # also fix CT 123's CPUs; a run without
#                                                    # it, and restore, drop the fixed set
#   TEST_MODEL=mimo ./ct123-test-host.sh two-card    # the MiMo unit on both cards; 488 GiB
#   TEST_ENGINE=maya ./ct123-test-host.sh two-card   # GLM's Maya unit; /dev/kfd passed through
#   TEST_ENGINE=llamacpp ./ct123-test-host.sh engine # in a test setup, hand the cards to the other
#                                                    # GLM engine: the watchdog map follows, no restart
#
# restore retires every test unit, whichever TEST_MODEL set the container up, and gives the
# card back to the Flash-Next engine that was enabled before the test (llama.cpp or Strata).
# State is kept in one directory for every model, so a switch from one test to another
# restores the limits from before the first.
#
# HIP (Strata, Maya) needs a DRM cgroup rule that allows only the bound cards' minors
# (../strata/README.md). Once the config carries such a rule, or with TEST_ENGINE=maya, every
# card change rewrites it to the cards CT 123 then binds; llama.cpp serves under it too.
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
readonly KFD_NODE="${KFD_NODE:-/dev/kfd}"

readonly GPU1_PCI='0000:03:00.0'
readonly GPU2_PCI='0000:83:00.0'
# Flash-Next's engines; restore enables the one that was enabled before the test.
readonly PROD_UNITS='llamacpp-qwen38fn strata-qwen38fn'
readonly PROD_DEFAULT=llamacpp-qwen38fn
readonly CT120_UNIT=llamacpp
# Every model unit a test installs in CT 123; restore retires all of them.
readonly TEST_UNITS='llamacpp-glm53f llamacpp-mimo maya-glm53f'

# Each test's unit, model files and memory limit. Room for 32 threads without the
# threads = cores collapse seen on CT 123 at 24/24 sets the cores for both.
# - glm53f: the model under auto page cache or dio pinning (~200 GB).
# - mimo: 480.5 GiB of experts at -ncmoe 68 in anonymous memory, 482.9 GiB in all, out of
#   503.6 GiB on the host; the baseline record measured 2.9 GiB left under the CT's limit.
#   488 GiB leaves the host 15.5 GiB, with every other guest shut down.
# - maya (GLM only): the same files, every expert outside VRAM pinned in RAM (~160 GiB).
# VK_UNIT is the model's llama.cpp unit, whose llama-server counts the cards CT 123 offers.
readonly TEST_MODEL="${TEST_MODEL:-glm53f}"
readonly TEST_ENGINE="${TEST_ENGINE:-llamacpp}"
case "$TEST_MODEL" in
  glm53f)
    readonly VK_UNIT=llamacpp-glm53f TEST_MEMORY_MIB=245760
    readonly MODEL_DIR=/models/hf/glm-5.3-flash MODEL_FILES=7 ;;
  mimo)
    readonly VK_UNIT=llamacpp-mimo TEST_MEMORY_MIB=499712
    readonly MODEL_DIR=/models/hf/mimo-v2.6-pro-rl MODEL_FILES=9 ;;
  *) echo "ERROR: TEST_MODEL must be glm53f or mimo" >&2; exit 1 ;;
esac
case "${TEST_ENGINE}/${TEST_MODEL}" in
  llamacpp/*) readonly TEST_UNIT="$VK_UNIT" ;;
  maya/glm53f) readonly TEST_UNIT=maya-glm53f ;;
  *) echo "ERROR: TEST_ENGINE must be llamacpp, or maya with TEST_MODEL=glm53f" >&2; exit 1 ;;
esac
readonly TEST_CORES=48
readonly TEST_CPUSET="${TEST_CPUSET:-}"

readonly LIMITS_FILE="${STATE_DIR}/123.limits.before-test"
readonly CT120_ONBOOT_FILE="${STATE_DIR}/120.onboot.before-test"
readonly PROD_FILE="${STATE_DIR}/123.engine.before-test"
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

require_model_installed() {
  local u
  for u in $(printf '%s\n' "$TEST_UNIT" "$VK_UNIT" | sort -u); do
    pct exec "$VMID" -- test -f "/etc/systemd/system/${u}.service" \
      || die "${u} not installed in CT ${VMID}; run VMID=${VMID} ./install.sh first"
  done
  # shellcheck disable=SC2016  # expands inside the container
  pct exec "$VMID" -- bash -c '
    n=$(ls "$1"/*.verified 2>/dev/null | wc -l)
    [ "$n" -ge "$2" ] || { echo "only ${n}/$2 model files verified; run install.sh --download"; exit 1; }' \
    _ "$MODEL_DIR" "$MODEL_FILES" \
    || die "model files not verified"
}

retire_test_units() {
  local u
  for u in $TEST_UNITS; do retire_unit "$VMID" "$u"; done
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
    D=$(. "/etc/$1.env" && printf "%s" "$LLAMACPP_DIR")
    LD_LIBRARY_PATH=$D $D/llama-server --list-devices 2>/dev/null | grep -c V620' _ "$VK_UNIT" 2>/dev/null || true
}

# Every check before the first change, so a refusal leaves the host as it was.
preflight() {  # [two-card]
  local st
  [ "$(ct_state "$VMID")" = "running" ] || die "CT ${VMID} is not running"
  require_model_installed
  [ -z "$TEST_CPUSET" ] || check_cpuset
  if [ "${1:-}" = two-card ]; then
    st="$(ct_state 120)"
    [ "$st" = "stopped" ] || die "CT 120 is '${st}'; shut it down first (stop Hermes, CT 121, before it)"
    [ -e "${DRI_BY_PATH}/pci-${GPU1_PCI}-render" ] || die "GPU 1 by-path render node missing on the host"
  fi
}

# The Flash-Next engine enabled before the first change, which restore enables again.
save_prod_unit() {
  local u
  [ -f "$PROD_FILE" ] && return 0
  for u in $PROD_UNITS; do
    if pct exec "$VMID" -- systemctl is-enabled "$u" >/dev/null 2>&1; then echo "$u" >"$PROD_FILE"; break; fi
  done
  [ -f "$PROD_FILE" ] || echo "$PROD_DEFAULT" >"$PROD_FILE"
  log "Flash-Next engine before the test: $(cat "$PROD_FILE")"
}

prod_unit() { if [ -f "$PROD_FILE" ]; then cat "$PROD_FILE"; else echo "$PROD_DEFAULT"; fi; }

is_chardev() { [ "$(stat -L -c %F "$1" 2>/dev/null)" = "character special file" ]; }

# HIP needs /dev/kfd. Proxmox's passthrough resolves its dynamic major at every start.
ensure_kfd() {
  local n=0 gid
  grep -qE '^dev[0-9]+: /dev/kfd' "$CONF" && return 0
  is_chardev "$KFD_NODE" || die "the host has no ${KFD_NODE}"
  while grep -q "^dev${n}:" "$CONF"; do n=$((n + 1)); done
  gid="$(stat -L -c %g "$KFD_NODE")"
  pct set "$VMID" "--dev${n}" "/dev/kfd,gid=${gid},mode=0660" || die "pct set --dev${n} failed"
  log "/dev/kfd passed into CT ${VMID} as dev${n} (gid ${gid})"
}

drm_minor() {  # <node>: its minor number; fails unless it is a character device
  is_chardev "$1" || return 1
  echo $((16#$(stat -L -c %T "$1")))
}

# KFD shows a process every GPU whose render node its device cgroup allows; with `c 226:*`
# that includes a card CT 123 has no node for, and HIP then finds no device. Allow exactly the
# minors of the cards CT 123 binds (as ../strata/use-engine.sh does). Applied once the config
# carries such a rule, or for Maya; a config without one is left as it is.
sync_drm_cgroup() {
  local rules=() link minor have
  [ "$TEST_ENGINE" = maya ] || grep -qE '^lxc.cgroup2.devices.allow: c 226:[0-9]+ ' "$CONF" || return 0
  while read -r link; do
    minor="$(drm_minor "${DRI_BY_PATH}/${link}")" || die "${DRI_BY_PATH}/${link} does not resolve to a device node"
    rules+=("lxc.cgroup2.devices.allow: c 226:${minor} rwm")
  done < <(grep -oE 'pci-0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]-(card|render)' "$CONF" | sort -u)
  [ "${#rules[@]}" -ge 2 ] || die "CT ${VMID} binds no card and render node"
  have="$(grep '^lxc.cgroup2.devices.allow: c 226:' "$CONF" | sort || true)"
  [ "$have" = "$(printf '%s\n' "${rules[@]}" | sort)" ] && return 0
  cp -a "$CONF" "${STATE_DIR}/123.conf.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  {
    grep -v '^lxc.cgroup2.devices.allow: c 226:' "$CONF" || true
    printf '%s\n' "${rules[@]}"
  } >"${STATE_DIR}/123.conf.new"
  cat "${STATE_DIR}/123.conf.new" >"$CONF"
  log "CT ${VMID} DRM cgroup -> $(printf '%s\n' "${rules[@]}" | awk '{print $3}' | paste -sd' ' -)"
}

prepare_ct123() {
  save_limits
  save_prod_unit
  log "retiring Flash-Next's engines (${PROD_UNITS}) in CT ${VMID} for the test"
  local u
  for u in $PROD_UNITS; do retire_unit "$VMID" "$u"; done
  retire_test_units
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
    for u in $(printf '%s\n' "$TEST_UNIT" "$VK_UNIT" $PROD_UNITS | awk '!seen[$0]++'); do
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
      [ "$TEST_ENGINE" = maya ] && ensure_kfd
      sync_drm_cgroup
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
      [ "$TEST_ENGINE" = maya ] && ensure_kfd
      sync_drm_cgroup
      restart_ct
      set_watchdog_map "${GPU1_PCI}=${VMID}:${TEST_UNIT},${GPU2_PCI}=${VMID}:${TEST_UNIT}"
      [ "$(devices_offered)" -eq 2 ] || die "llama-server does not see two V620s in CT ${VMID}"
      echo "Vulkan device order in CT ${VMID} (the index MODEL_VK_VISIBLE_DEVICES takes):"
      pct exec "$VMID" -- bash -c "vulkaninfo --summary 2>/dev/null | grep -E '^GPU[0-9]+:|deviceName|deviceUUID'" \
        | sed 's/^/  /' || true
      ;;
    engine)
      # Within a test setup: stop the other test units and point the watchdog at TEST_UNIT for
      # the cards CT 123 holds. The sweep that follows starts TEST_UNIT itself.
      require_root
      [ -f "$LIMITS_FILE" ] || die "CT ${VMID} is not in a test setup; run one-card or two-card first"
      require_model_installed
      local u
      for u in $TEST_UNITS; do
        [ "$u" = "$TEST_UNIT" ] || pct exec "$VMID" -- systemctl stop "$u" 2>/dev/null || true
      done
      if gpu1_attached; then
        set_watchdog_map "${GPU1_PCI}=${VMID}:${TEST_UNIT},${GPU2_PCI}=${VMID}:${TEST_UNIT}"
      else
        set_watchdog_map "${GPU1_PCI}=120:${CT120_UNIT},${GPU2_PCI}=${VMID}:${TEST_UNIT}"
      fi
      ;;
    restore)
      require_root; mkdir -p "$STATE_DIR"
      [ "$(ct_state "$VMID")" = "running" ] && retire_test_units
      gpu1_attached && detach_gpu1
      sync_drm_cgroup
      if [ -f "$LIMITS_FILE" ]; then
        local k v
        while read -r k v; do pct set "$VMID" "--${k}" "$v"; done <"$LIMITS_FILE"
        rm -f "$LIMITS_FILE"
      fi
      drop_cpuset
      restart_ct
      ct120_restore
      local prod
      prod="$(prod_unit)"
      set_watchdog_map "${GPU1_PCI}=120:${CT120_UNIT},${GPU2_PCI}=${VMID}:${prod}"
      pct exec "$VMID" -- systemctl enable --now "$prod"
      rm -f "$PROD_FILE"
      log "${prod} enabled and loading; check its VRAM once it serves"
      ;;
    status) ;;
    *) die "usage: $0 {one-card|two-card|engine|restore|status}" ;;
  esac
  status
}

main "$@"
