#!/usr/bin/env bash
# Mocked transition test for strata-dev-host.sh. Runs anywhere, touches no real host.
#
# Drives the real script against a mocked `pct`/`systemctl` and checks, after each step and
# after a simulated reboot, that one DeepSeek container at most holds GPU 2, that only the
# card's owner starts at boot (CT 123 keeps its passthrough, stopped with autostart off),
# that the watchdog map names the container on the card, and that `restore` puts CT 123
# back as found. Same approach as ../glm53-flash/ct123-test-host-test.sh.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/strata-dev-host.sh"
GPU1=0000:03:00.0
GPU2=0000:83:00.0
fails=0
ok()  { echo "    ✅ $*"; }
bad() { echo "    🔴 $*"; fails=$((fails + 1)); }

# ---------------------------------------------------------------- mock host
new_host() {
  # The physical path: readlink -f resolves /var to /private/var on macOS.
  T="$(cd "$(mktemp -d)" && pwd -P)"; export T
  mkdir -p "$T/lxc" "$T/bin" "$T/state" "$T/dri"
  printf 'memory: 16384\nonboot: 1\n' >"$T/lxc/120.conf"
  printf 'memory: 8192\nonboot: 1\n' >"$T/lxc/121.conf"
  cat >"$T/lxc/123.conf" <<EOF
memory: 122880
onboot: 1
lxc.mount.entry: /dev/dri/by-path/pci-${GPU2}-render dev/dri/renderD128 none bind,optional,create=file
EOF
  for ct in 124 125 126; do printf 'memory: 65536\nonboot: 0\n' >"$T/lxc/$ct.conf"; done
  echo running >"$T/status.120"; echo running >"$T/status.121"; echo running >"$T/status.123"
  echo running >"$T/status.124"; echo stopped >"$T/status.125"; echo stopped >"$T/status.126"
  echo "GPU_SERVICE_MAP=${GPU1}=120:llamacpp,${GPU2}=123:llamacpp-qwen38fn" >"$T/wd.env"
  echo 'MemTotal:       528014336 kB' >"$T/meminfo"   # 515,639 MiB, as pve
  # by-path links resolve to the real node names, as udev's do
  : >"$T/dri/renderD128"; : >"$T/dri/card1"; : >"$T/dri/renderD129"; : >"$T/dri/card2"
  ln -s renderD128 "$T/dri/pci-${GPU2}-render"; ln -s card1 "$T/dri/pci-${GPU2}-card"
  ln -s renderD129 "$T/dri/pci-${GPU1}-render"; ln -s card2 "$T/dri/pci-${GPU1}-card"
  : >"$T/kfd"
  # The mock nodes are files, read as character devices with the minors their names give.
  cat >"$T/bin/stat" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -L ] && shift
fmt="$2"; f="$3"
case "$f" in "$T"/dri/* | "$T"/kfd) ;; *) echo "mock stat: unexpected $*" >&2; exit 1 ;; esac
[ -e "$f" ] || exit 1
name="$(basename "$(readlink "$f" || echo "$f")")"
case "$fmt" in
  %F) echo "character special file" ;;
  %T) printf '%x\n' "${name//[!0-9]/}" ;;
esac
EOF
  printf '#!/usr/bin/env bash\necho 0\n' >"$T/bin/id"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/sleep"
  printf '#!/usr/bin/env bash\necho "$*" >>"$T/systemctl.log"\n' >"$T/bin/systemctl"
  printf '#!/usr/bin/env bash\necho "VMID NAME STATUS"\n' >"$T/bin/qm"
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
  list) echo "VMID Status Lock Name"
        for f in "$T"/status.*; do echo "${f##*.} $(cat "$f") ct"; done ;;
  status) [ -f "$T/status.$1" ] || { echo "CT $1 does not exist" >&2; exit 2; }
          echo "status: $(cat "$T/status.$1")" ;;
  config) cat "$T/lxc/$1.conf" ;;
  shutdown|stop) echo stopped >"$T/status.$1" ;;
  start)  [ "$(cat "$T/status.$1")" = stopped ] || { echo "CT $1 already running" >&2; exit 1; }
          echo running >"$T/status.$1" ;;
  set)
    vm="$1"; shift
    while [ $# -gt 0 ]; do
      k="${1#--}"
      if [ "$k" = delete ]; then
        for d in ${2//,/ }; do grep -v "^$d: " "$T/lxc/$vm.conf" >"$T/c.new"; cat "$T/c.new" >"$T/lxc/$vm.conf"; done
      else
        grep -v "^$k: " "$T/lxc/$vm.conf" >"$T/c.new"; printf '%s: %s\n' "$k" "$2" >>"$T/c.new"
        cat "$T/c.new" >"$T/lxc/$vm.conf"
      fi
      shift 2
    done ;;
  exec)
    vm="$1"; shift; [ "${1:-}" = -- ] && shift
    [ "$(cat "$T/status.$vm")" = running ] || { echo "CT $vm is not running" >&2; exit 1; }
    case "$*" in
      "getent group render") echo "render:x:993:agent" ;;
      "getent group video") echo "video:x:44:agent" ;;
      *rocminfo*)
        # KFD lists GPU 2 when it is passed in, and GPU 1 too unless its nodes are denied
        grep -q '^dev1: /dev/dri/renderD128,' "$T/lxc/$vm.conf" || exit 0
        echo "  Name:                    gfx1030"
        grep -q '^lxc.cgroup2.devices.deny: c 226:129 rwm$' "$T/lxc/$vm.conf" \
          || echo "  Name:                    gfx1030" ;;
      *) : ;;
    esac ;;
  *) : ;;
esac
PCT
  chmod +x "$T/bin"/*
}
run() {  # <args...>
  PATH="$T/bin:$PATH" LXC_CONF_DIR="$T/lxc" STATE_DIR="$T/state" WATCHDOG_ENV="$T/wd.env" \
    DRI_BY_PATH="$T/dri" KFD_NODE="$T/kfd" MEMINFO="$T/meminfo" "$SCRIPT" "$@" >>"$T/out.log" 2>&1
}
tail_log() { echo "--- tail of out.log ---"; tail -12 "$T/out.log" | sed 's/^/      /'; }
onboot() { awk -F': ' '$1 == "onboot" {print $2}' "$T/lxc/$1.conf"; }
memory() { awk -F': ' '$1 == "memory" {print $2}' "$T/lxc/$1.conf"; }
map() { grep '^GPU_SERVICE_MAP=' "$T/wd.env" | cut -d= -f2-; }
gpu_holders() {  # the DeepSeek containers whose config passes GPU 2 through
  local ct
  for ct in 124 125 126; do
    grep -qE '^dev[0-9]+: /dev/dri/renderD128,' "$T/lxc/$ct.conf" && printf '%s ' "$ct"
  done
}
autostart() {  # the containers among 123-126 that start at boot
  local ct
  for ct in 123 124 125 126; do [ "$(onboot "$ct")" = 1 ] && printf '%s ' "$ct"; done
}
owns_alone() {  # <ct>: the one GPU 2 holder, the one that autostarts, and the map's entry
  local ct="$1" other
  [ "$(gpu_holders)" = "$ct " ] && ok "only CT $ct holds GPU 2 of CT 124-126" || bad "GPU 2 holders: $(gpu_holders)"
  [ "$(cat "$T/status.123")/$(onboot 123)" = stopped/0 ] && ok "CT 123 stopped, autostart off" \
    || bad "CT 123: $(cat "$T/status.123"), onboot $(onboot 123)"
  [ "$(autostart)" = "$ct " ] && ok "only CT $ct starts at boot" || bad "autostart: $(autostart)"
  [ "$(map)" = "${GPU1}=120:llamacpp,${GPU2}=${ct}:@container" ] && ok "watchdog: GPU 2 -> CT $ct" || bad "map is $(map)"
  grep -q '^lxc.cgroup2.devices.deny: c 226:129 rwm$' "$T/lxc/$ct.conf" \
    && grep -q '^lxc.cgroup2.devices.deny: c 226:2 rwm$' "$T/lxc/$ct.conf" \
    && ok "CT $ct denies GPU 1's nodes" || bad "CT $ct lacks GPU 1's deny rules"
  for other in 124 125 126; do
    [ "$other" = "$ct" ] && continue
    [ "$(cat "$T/status.$other")/$(memory "$other")" = stopped/65536 ] \
      && ! grep -q '^lxc.cgroup2.devices.deny: c 226:' "$T/lxc/$other.conf" \
      && ok "CT $other released: stopped, 64 GiB, no deny rules" \
      || bad "CT $other: $(cat "$T/status.$other"), $(memory "$other") MiB, $(grep -c 'deny: c 226:' "$T/lxc/$other.conf") deny rules"
  done
}

# ---------------------------------------------------------------- scenarios
echo "=== 1. dev (CT 124) from Flash-Next on CT 123 ==="
new_host
run dev || { bad "dev exited non-zero"; tail_log; }
[ "$(cat "$T/status.123")/$(onboot 123)" = stopped/0 ] && ok "CT 123 stopped, autostart off" || bad "CT 123: $(cat "$T/status.123"), onboot $(onboot 123)"
owns_alone 124
[ "$(memory 124)" = 474679 ] && ok "CT 124 gets what the running guests leave (474,679 MiB)" || bad "CT 124 memory $(memory 124)"
grep -q '^dev0: '"$T"'/kfd,gid=993,mode=0660$' "$T/lxc/124.conf" && ok "/dev/kfd with render's group" || bad "no kfd entry"

echo "=== 2. dev 125 moves the card from CT 124 ==="
run dev 125 || { bad "dev 125 exited non-zero"; tail_log; }
owns_alone 125
[ "$(cat "$T/status.125")" = running ] && ok "CT 125 started" || bad "CT 125 is $(cat "$T/status.125")"
[ "$(memory 125)" = 474679 ] && ok "CT 125 memory 474,679 MiB" || bad "CT 125 memory $(memory 125)"

echo "=== 3. simulated host reboot: only the owner comes back ==="
for ct in 123 124 125 126; do
  echo stopped >"$T/status.$ct"
  [ "$(onboot "$ct")" = 1 ] && echo running >"$T/status.$ct"
done
running=""; for ct in 123 124 125 126; do [ "$(cat "$T/status.$ct")" = running ] && running+="$ct "; done
[ "$running" = "125 " ] && ok "only CT 125 runs after the reboot" || bad "running after reboot: $running"

echo "=== 4. dev on the live state of 2026-11-02: all three hold GPU 2 ==="
for ct in 124 126; do
  { printf 'dev0: %s/kfd,gid=993,mode=0660\ndev1: /dev/dri/renderD128,gid=993,mode=0660\n' "$T"
    printf 'dev2: /dev/dri/card1,gid=44,mode=0660\nlxc.cgroup2.devices.deny: c 226:129 rwm\n'
    printf 'lxc.cgroup2.devices.deny: c 226:2 rwm\n'; } >>"$T/lxc/$ct.conf"
done
printf 'onboot: 1\n' >>"$T/lxc/124.conf"
run dev 125 || { bad "dev 125 exited non-zero"; tail_log; }
owns_alone 125

echo "=== 5. refusals change nothing ==="
cp -R "$T/lxc" "$T/lxc.before"; cp "$T/wd.env" "$T/wd.before"
run dev 127 && bad "accepted CT 127" || ok "refused CT 127"
echo "lxc.mount.entry: /dev/dri/by-path/pci-${GPU2}-render dev/dri/renderD128 none bind,optional,create=file" >>"$T/lxc/120.conf"
cp "$T/lxc/120.conf" "$T/lxc.before/120.conf"
run dev 126 && bad "took GPU 2 while CT 120 held it" || ok "refused while CT 120 holds GPU 2"
diff -r "$T/lxc.before" "$T/lxc" >/dev/null && diff -q "$T/wd.before" "$T/wd.env" >/dev/null \
  && ok "configs and map untouched" || bad "a refusal changed the host"
grep -v "pci-${GPU2}-render" "$T/lxc/120.conf" >"$T/c.new"; cat "$T/c.new" >"$T/lxc/120.conf"
echo 'dev3: /dev/dri/renderD129,gid=993,mode=0660' >>"$T/lxc/125.conf"
run dev 126 && bad "moved GPU 2 while CT 125 held GPU 1" || ok "refused a two-card setup"
sed_out="$(grep -v '^dev3: ' "$T/lxc/125.conf")"; printf '%s\n' "$sed_out" >"$T/lxc/125.conf"

echo "=== 6. restore gives the card back to Flash-Next ==="
run restore || { bad "restore exited non-zero"; tail_log; }
[ -z "$(gpu_holders)" ] && ok "CT 124-126 hold no card" || bad "GPU 2 holders: $(gpu_holders)"
[ "$(autostart)" = "123 " ] && ok "only CT 123 starts at boot" || bad "autostart: $(autostart)"
[ "$(map)" = "${GPU1}=120:llamacpp,${GPU2}=123:llamacpp-qwen38fn" ] && ok "watchdog map restored" || bad "map is $(map)"
[ "$(cat "$T/status.123")" = running ] && ok "CT 123 started" || bad "CT 123 is $(cat "$T/status.123")"
[ ! -e "$T/state/123.onboot.before-dev" ] && [ ! -e "$T/state/watchdog-map.before-dev" ] \
  && ok "saved state removed" || bad "saved state left behind"
rm -rf "$T"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "${fails} FAILED"; exit 1; fi
