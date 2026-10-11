#!/usr/bin/env bash
# Mocked transition test for ct123-test-host.sh. Runs anywhere, touches no real host.
#
# Drives the real script against a mocked `pct`/`systemctl` and checks, after each step and
# after a simulated reboot, that no two containers can hold one card, that the watchdog map
# names the unit on each card, and that `restore` puts CT 123 and CT 120 back as found.
# Same approach as ../qwen38-flash-next/cutover-transition-test.sh.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SCRIPT="$PWD/ct123-test-host.sh"
[ -x "$SCRIPT" ] || { echo "ct123-test-host.sh not found next to this test"; exit 1; }
GPU1=0000:03:00.0
GPU2=0000:83:00.0
fails=0
ok()  { printf '    ✅ %s\n' "$*"; }
bad() { printf '    🔴 %s\n' "$*"; fails=$((fails + 1)); }

# ---------------------------------------------------------------- mock host
new_host() {
  T="$(mktemp -d)"; export T
  mkdir -p "$T/lxc" "$T/bin" "$T/state" "$T/dri"
  cat >"$T/lxc/120.conf" <<EOF
cores: 8
memory: 16384
onboot: 1
swap: 4096
lxc.mount.entry: /dev/dri/by-path/pci-${GPU1}-render dev/dri/renderD129 none bind,optional,create=file
lxc.mount.entry: /dev/dri/by-path/pci-${GPU1}-card dev/dri/card2 none bind,optional,create=file
EOF
  cat >"$T/lxc/123.conf" <<EOF
cores: 24
memory: 122880
onboot: 1
swap: 4096
lxc.mount.entry: /dev/dri/by-path/pci-${GPU2}-render dev/dri/renderD128 none bind,optional,create=file
lxc.mount.entry: /dev/dri/by-path/pci-${GPU2}-card dev/dri/card1 none bind,optional,create=file
EOF
  cp "$T/lxc/123.conf" "$T/123.conf.orig"
  echo stopped >"$T/status.120"; echo running >"$T/status.123"
  echo "GPU_SERVICE_MAP=${GPU1}=120:llamacpp,${GPU2}=123:llamacpp-qwen38fn" >"$T/wd.env"
  : >"$T/units"
  set_unit 120 llamacpp enabled inactive
  set_unit 123 llamacpp-qwen38fn enabled active
  set_unit 123 llamacpp-glm53f disabled inactive
  # by-path links resolve to the real node names, as udev's do
  : >"$T/dri/renderD128"; : >"$T/dri/card1"; : >"$T/dri/renderD129"; : >"$T/dri/card2"
  ln -s renderD128 "$T/dri/pci-${GPU2}-render"; ln -s card1 "$T/dri/pci-${GPU2}-card"
  ln -s renderD129 "$T/dri/pci-${GPU1}-render"; ln -s card2 "$T/dri/pci-${GPU1}-card"
  cat >"$T/bin/id" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && echo 0 || echo root
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/sleep"
  printf '#!/usr/bin/env bash\necho "$*" >>"$T/host-systemctl.log"\n' >"$T/bin/systemctl"
  # GNU `sed -i` on the host; BSD/macOS needs `-i ''`.
  cat >"$T/bin/sed" <<'EOF'
#!/usr/bin/env bash
for c in /usr/bin/sed /bin/sed; do [ -x "$c" ] && { REAL="$c"; break; }; done
if [ "${1:-}" = "-i" ]; then
  shift
  if "$REAL" --version >/dev/null 2>&1; then exec "$REAL" -i "$@"; else exec "$REAL" -i '' "$@"; fi
fi
exec "$REAL" "$@"
EOF
  cat >"$T/bin/pct" <<'PCT'
#!/usr/bin/env bash
set -u
echo "$*" >>"$T/pct.log"
sub="$1"; shift
case "$sub" in
  status) echo "status: $(cat "$T/status.$1")" ;;
  config) cat "$T/lxc/$1.conf" ;;
  stop)   [ "$(cat "$T/status.$1")" = running ] || { echo "CT $1 not running" >&2; exit 1; }
          echo stopped >"$T/status.$1" ;;
  start)  echo running >"$T/status.$1"
          # enabled units come back with the container
          sed -i "s/^$1 \([a-z0-9-]*\) enabled .*/$1 \1 enabled active/" "$T/units" ;;
  set)
    vm="$1"; shift
    [ "${FAIL_ON_PCT_SET:-}" = "$vm" ] && { echo "mock: pct set $vm failed on purpose" >&2; exit 1; }
    while [ $# -gt 0 ]; do
      k="${1#--}"
      if grep -q "^$k: " "$T/lxc/$vm.conf"; then sed -i "s/^$k: .*/$k: $2/" "$T/lxc/$vm.conf"
      else printf '%s: %s\n' "$k" "$2" >>"$T/lxc/$vm.conf"; fi
      shift 2
    done ;;
  exec)
    vm="$1"; shift; [ "${1:-}" = -- ] && shift
    [ "$(cat "$T/status.$vm")" = running ] || { echo "CT $vm is not running" >&2; exit 1; }
    case "${1:-}" in
      test) [ -z "${MOCK_NO_GLM:-}" ] ;;
      bash)
        case "$*" in
          *list-devices*) grep -c -- '-render dev/dri' "$T/lxc/$vm.conf" ;;
          *verified*)     [ -z "${MOCK_UNVERIFIED:-}" ] ;;
          *vulkaninfo*)   echo "GPU0:"; echo "GPU1:" ;;
          *) : ;;
        esac ;;
      systemctl)
        act="$2"; unit="${3:-}"
        case "$act" in
          is-system-running) exit 0 ;;
          is-enabled) grep -q "^$vm $unit enabled " "$T/units" ;;
          is-active)  grep -q "^$vm $unit .* active$" "$T/units" ;;
          enable)  [ "$unit" = --now ] && unit="$4"
                   sed -i "s/^$vm $unit [a-z]* /$vm $unit enabled /" "$T/units"
                   [ "$3" = --now ] && sed -i "s/^$vm $unit \([a-z]*\) .*/$vm $unit \1 active/" "$T/units"; : ;;
          disable) [ "$unit" = --now ] && unit="$4"
                   sed -i "s/^$vm $unit [a-z]* /$vm $unit disabled /" "$T/units"
                   sed -i "s/^$vm $unit \([a-z]*\) .*/$vm $unit \1 inactive/" "$T/units"; : ;;
          *) : ;;
        esac ;;
      *) : ;;
    esac ;;
  *) : ;;
esac
PCT
  chmod +x "$T/bin"/*
}
set_unit() { printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$T/units"; }
run() {  # <action>
  PATH="$T/bin:$PATH" CONF="$T/lxc/123.conf" STATE_DIR="$T/state" WATCHDOG_ENV="$T/wd.env" \
    DRI_BY_PATH="$T/dri" "$SCRIPT" "$1" >>"$T/out.log" 2>&1
}
tail_log() { echo "--- tail of out.log ---"; tail -12 "$T/out.log" | sed 's/^/      /'; }
onboot()   { awk -F': ' '$1 == "onboot" {print $2}' "$T/lxc/$1.conf"; }
limit()    { awk -F': ' -v k="$2" '$1 == k {print $2}' "$T/lxc/$1.conf"; }
map()      { sed -n 's/^GPU_SERVICE_MAP=//p' "$T/wd.env"; }
unit()     { grep "^$1 $2 " "$T/units" | cut -d' ' -f3-4; }
gpu1_on_123() { grep -q "pci-${GPU1}-render" "$T/lxc/123.conf"; }
# Could a reboot, or a start, put two containers on GPU 1?
double_binding_possible() { gpu1_on_123 && [ "$(onboot 120)" = 1 ]; }

echo "=== 0. two-card must refuse while CT 120 runs, and change nothing ==="
new_host; echo running >"$T/status.120"
run two-card && bad "took GPU 1 while CT 120 was running" || ok "refused"
gpu1_on_123 && bad "GPU 1 attached despite the refusal" || ok "GPU 1 not attached"
[ "$(onboot 120)" = 1 ] && ok "CT 120 autostart untouched" || bad "CT 120 onboot changed on a refusal"
[ "$(unit 123 llamacpp-qwen38fn)" = "enabled active" ] && ok "Flash-Next untouched" || bad "Flash-Next changed on a refusal"
rm -rf "$T"

echo "=== 1. one-card refuses without the GLM unit, and changes nothing ==="
new_host
MOCK_NO_GLM=1 run one-card && bad "set up a test without the GLM unit" || ok "refused"
[ "$(unit 123 llamacpp-qwen38fn)" = "enabled active" ] && ok "Flash-Next untouched" || bad "Flash-Next retired anyway"
[ "$(limit 123 memory)" = 122880 ] && ok "limits untouched" || bad "memory changed on a refusal"
rm -rf "$T"

echo "=== 2. one-card, two-card, reboot, restore ==="
new_host
run one-card || { bad "one-card exited non-zero"; tail_log; }
[ "$(unit 123 llamacpp-qwen38fn)" = "disabled inactive" ] && ok "Flash-Next retired" || bad "Flash-Next is $(unit 123 llamacpp-qwen38fn)"
[ "$(limit 123 memory)/$(limit 123 cores)" = "245760/48" ] && ok "CT 123 at 240 GiB, 48 cores" || bad "limits $(limit 123 memory)/$(limit 123 cores)"
[ "$(map)" = "${GPU1}=120:llamacpp,${GPU2}=123:llamacpp-glm53f" ] && ok "watchdog: GPU 2 -> GLM unit" || bad "map is $(map)"
gpu1_on_123 && bad "GPU 1 attached in one-card" || ok "GPU 1 not attached"

run two-card || { bad "two-card exited non-zero"; tail_log; }
gpu1_on_123 && ok "GPU 1 attached" || bad "GPU 1 not attached"
grep -q "pci-${GPU1}-render dev/dri/renderD129 " "$T/lxc/123.conf" \
  && grep -q "pci-${GPU1}-card dev/dri/card2 " "$T/lxc/123.conf" \
  && ok "mounted at the real node names" || bad "GPU 1 mounted under other names"
[ "$(onboot 120)" = 0 ] && ok "CT 120 autostart off" || bad "CT 120 onboot is $(onboot 120)"
[ "$(map)" = "${GPU1}=123:llamacpp-glm53f,${GPU2}=123:llamacpp-glm53f" ] && ok "watchdog: both cards -> GLM unit" || bad "map is $(map)"
double_binding_possible && bad "TWO CONTAINERS COULD HOLD GPU 1" || ok "exclusivity holds"

for vm in 120 123; do [ "$(onboot "$vm")" = 1 ] && echo running >"$T/status.$vm"; done
[ "$(cat "$T/status.120")" = stopped ] && ok "CT 120 did not autostart after a reboot" || bad "CT 120 autostarted onto GPU 1"
[ "$(unit 123 llamacpp-qwen38fn)" = "disabled inactive" ] && ok "Flash-Next stayed off after the reboot" || bad "Flash-Next came back: $(unit 123 llamacpp-qwen38fn)"

run restore || { bad "restore exited non-zero"; tail_log; }
diff -q "$T/123.conf.orig" "$T/lxc/123.conf" >/dev/null && ok "CT 123 config exactly as found" \
  || { bad "CT 123 config differs:"; diff "$T/123.conf.orig" "$T/lxc/123.conf" | sed 's/^/      /'; }
[ "$(onboot 120)" = 1 ] && ok "CT 120 autostart restored" || bad "CT 120 onboot is $(onboot 120)"
[ "$(cat "$T/status.120")" = stopped ] && ok "CT 120 left stopped" || bad "restore started CT 120"
[ "$(map)" = "${GPU1}=120:llamacpp,${GPU2}=123:llamacpp-qwen38fn" ] && ok "watchdog map as found" || bad "map is $(map)"
[ "$(unit 123 llamacpp-qwen38fn)" = "enabled active" ] && ok "Flash-Next serving again" || bad "Flash-Next is $(unit 123 llamacpp-qwen38fn)"
[ "$(unit 123 llamacpp-glm53f)" = "disabled inactive" ] && ok "GLM unit off" || bad "GLM unit is $(unit 123 llamacpp-glm53f)"
ls "$T/state"/*.before-test >/dev/null 2>&1 && bad "saved state left behind" || ok "saved state cleared"
rm -rf "$T"

echo "=== 3. one-card straight from two-card gives GPU 1 back ==="
new_host
run two-card || { bad "two-card exited non-zero"; tail_log; }
run one-card || { bad "one-card exited non-zero"; tail_log; }
gpu1_on_123 && bad "GPU 1 still attached" || ok "GPU 1 detached"
[ "$(onboot 120)" = 1 ] && ok "CT 120 autostart restored" || bad "CT 120 onboot is $(onboot 120)"
[ "$(map)" = "${GPU1}=120:llamacpp,${GPU2}=123:llamacpp-glm53f" ] && ok "watchdog: GPU 1 back to CT 120" || bad "map is $(map)"
run restore >/dev/null || true
[ "$(limit 123 memory)/$(limit 123 cores)" = "122880/24" ] && ok "limits from before the first change" || bad "limits $(limit 123 memory)/$(limit 123 cores)"
rm -rf "$T"

echo "=== 4. a failure while releasing CT 120 attaches nothing ==="
new_host
FAIL_ON_PCT_SET=120 run two-card && bad "reported success despite a failed mutation" || ok "failed loudly"
gpu1_on_123 && bad "GPU 1 attached although CT 120 was not released" || ok "GPU 1 not attached"
double_binding_possible && bad "partial state allows two containers on GPU 1" || ok "no double binding"
run restore || { bad "restore from the partial state failed"; tail_log; }
[ "$(onboot 120)" = 1 ] && ok "restore recovers CT 120's autostart" || bad "CT 120 onboot is $(onboot 120)"
rm -rf "$T"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "${fails} FAILED"; exit 1; fi
