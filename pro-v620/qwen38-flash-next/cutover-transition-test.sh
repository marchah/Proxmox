#!/usr/bin/env bash
# Mocked transition test for ct120-cutover.sh. Runs anywhere, touches no real host.
#
# Why this exists rather than another end-of-script assertion: the two P1 safety defects in
# this folder were both in TRANSITION logic — a watchdog map pointing at a unit the same
# script had just disabled, and GPU exclusivity that held until the next reboot. An assertion
# that runs after the last mutation cannot see either. This drives the real script against a
# mocked `pct`/`systemctl` and checks the invariants at each step, including a failure
# injected between mutations and a simulated host reboot.
#
# THE INVARIANT, in one line: at no point may two containers be able to hold GPU 2 —
# not while running, and not after a reboot.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SCRIPT="$PWD/ct120-cutover.sh"
[ -x "$SCRIPT" ] || { echo "ct120-cutover.sh not found next to this test"; exit 1; }
GPU2=0000:83:00.0
fails=0
ok()   { printf '    ✅ %s\n' "$*"; }
bad()  { printf '    🔴 %s\n' "$*"; fails=$((fails + 1)); }

# ---------------------------------------------------------------- mock host
# State lives in files so the mocks and the assertions see the same thing.
new_host() {
  T="$(mktemp -d)"; export T
  mkdir -p "$T/lxc" "$T/bin" "$T/bak"
  printf 'lxc.mount.entry: /dev/dri/by-path/pci-0000:03:00.0-render dev/dri/renderD129 none bind,optional,create=file\n' >"$T/lxc/120.conf"
  printf 'lxc.mount.entry: /dev/dri/by-path/pci-%s-render dev/dri/renderD128 none bind,optional,create=file\n' "$GPU2" >"$T/lxc/123.conf"
  printf 'cores: 8\nmemory: 16384\nswap: 4096\nonboot: 1\n' >>"$T/lxc/120.conf"
  printf 'onboot: 1\n' >>"$T/lxc/123.conf"
  echo running >"$T/status.120"; echo running >"$T/status.123"
  echo "GPU_SERVICE_MAP=0000:03:00.0=120:llamacpp,${GPU2}=123:llamacpp-qwen38fn" >"$T/wd.env"
  : >"$T/units"                       # "<vmid> <unit> <enabled> <active>"
  set_unit 120 llamacpp enabled active
  set_unit 120 llamacpp-qwen38fn disabled inactive
  set_unit 123 llamacpp-qwen38fn enabled active
  mkdir -p "$T/dri"; : >"$T/dri/pci-${GPU2}-render"; : >"$T/dri/pci-${GPU2}-card"
  cat >"$T/bin/id" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && echo 0 || echo root
EOF
  cat >"$T/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  # `sed -i` is GNU-only; BSD/macOS needs `-i ''`. The script under test runs on Proxmox
  # (GNU), so this shim exists purely so the test is portable, as its header claims.
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
# minimal `pct` against $T. Records every mutation so ordering can be asserted.
set -u
echo "$*" >>"$T/pct.log"
sub="$1"; shift
case "$sub" in
  status)  echo "status: $(cat "$T/status.$1")" ;;
  config)  cat "$T/lxc/$1.conf" ;;
  stop)    echo stopped >"$T/status.$1" ;;
  start)   echo running >"$T/status.$1"
           # a started container brings its ENABLED units back — this is what makes
           # "still enabled" a real hazard rather than a bookkeeping detail
           sed -i.bak "s/^$1 \\([a-z0-9-]*\\) enabled .*/$1 \\1 enabled active/" "$T/units" ;;
  set)
    vm="$1"; shift
    [ "${FAIL_ON_PCT_SET:-}" = "$vm" ] && { echo "mock: pct set $vm failed on purpose" >&2; exit 1; }
    while [ $# -gt 0 ]; do
      case "$1" in
        --onboot) sed -i.bak "s/^onboot: .*/onboot: $2/" "$T/lxc/$vm.conf"; shift 2 ;;
        --cores|--memory|--swap)
          k="${1#--}"; grep -q "^$k: " "$T/lxc/$vm.conf" \
            && sed -i.bak "s/^$k: .*/$k: $2/" "$T/lxc/$vm.conf" \
            || printf '%s: %s\n' "$k" "$2" >>"$T/lxc/$vm.conf"; shift 2 ;;
        *) shift ;;
      esac
    done ;;
  exec)
    vm="$1"; shift; [ "${1:-}" = -- ] && shift
    [ "$(cat "$T/status.$vm")" = running ] || { echo "CT $vm is not running" >&2; exit 1; }
    [ "${1:-}" = systemctl ] || exit 0
    act="$2"; unit="${3:-}"
    case "$act" in
      is-enabled) grep -q "^$vm $unit enabled " "$T/units" ;;
      is-active)  grep -q "^$vm $unit .* active$" "$T/units" ;;
      enable)  [ "$unit" = --now ] && unit="$4"
               sed -i.bak "s/^$vm $unit [a-z]* /$vm $unit enabled /" "$T/units"
               [ "${3:-}" = --now ] && sed -i.bak "s/^$vm $unit \\([a-z]*\\) .*/$vm $unit \\1 active/" "$T/units"; : ;;
      disable) [ "$unit" = --now ] && unit="$4"
               [ "${FAIL_DISABLE:-}" = "$unit" ] && { echo "mock: disable $unit failed" >&2; exit 1; }
               sed -i.bak "s/^$vm $unit [a-z]* /$vm $unit disabled /" "$T/units"
               sed -i.bak "s/^$vm $unit \\([a-z]*\\) .*/$vm $unit \\1 inactive/" "$T/units"; : ;;
      *) : ;;
    esac ;;
  *) : ;;
esac
PCT
  chmod +x "$T/bin"/*
}
set_unit() { sed -i.bak "/^$1 $2 /d" "$T/units" 2>/dev/null || true; printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$T/units"; }
run_cutover() {
  PATH="$T/bin:$PATH" CONF="$T/lxc/120.conf" BAK_DIR="$T/bak" WATCHDOG_ENV="$T/wd.env" \
    LXC_CONF_DIR="$T/lxc" DRI_BY_PATH="$T/dri" VMID=120 FAIL_DISABLE="${FAIL_DISABLE:-}" "$SCRIPT" "$1" >>"$T/out.log" 2>&1
}
gpu2_on_120() { grep -q "pci-${GPU2}-render" "$T/lxc/120.conf"; }
onboot_123()  { awk '/^onboot:/{print $2}' "$T/lxc/123.conf"; }
map()         { sed -n 's/^GPU_SERVICE_MAP=//p' "$T/wd.env"; }
# The thing that actually matters: could two containers end up on GPU 2?
double_binding_possible() {
  gpu2_on_120 && [ "$(onboot_123)" = 1 ] && grep -q "pci-${GPU2}-render" "$T/lxc/123.conf"
}

echo "=== 0. it must REFUSE while CT 123 is still running ==="
new_host
run_cutover to-qwen38fn && bad "cut over while CT 123 was running — two servers, one card" \
  || ok "refused to cut over while CT 123 was running"
gpu2_on_120 && bad "GPU 2 was attached despite the refusal" || ok "no mutation on refusal"
rm -rf "$T"

echo "=== 1. forward cutover: CT 123 must be released BEFORE GPU 2 is attached ==="
new_host
pct_stop_123() { echo stopped >"$T/status.123"; }   # what the operator does first
pct_stop_123
run_cutover to-qwen38fn || { bad "forward cutover exited non-zero"; echo "--- tail of out.log ---"; tail -12 "$T/out.log" | sed "s/^/      /"; }
gpu2_on_120 && ok "GPU 2 attached to CT 120" || bad "GPU 2 not attached"
[ "$(onboot_123)" = 0 ] && ok "CT 123 autostart cleared" || bad "CT 123 onboot is $(onboot_123), a reboot would re-take GPU 2"
[ "$(cat "$T/status.123")" = stopped ] && ok "CT 123 stopped" || bad "CT 123 still running"
case "$(map)" in
  *"0000:03:00.0=120:llamacpp-qwen38fn"*) ok "GPU 1 mapped to the unit that runs" ;;
  *) bad "GPU 1 map is '$(map)'" ;;
esac
case "$(map)" in
  *"${GPU2}=120:llamacpp-qwen38fn"*) ok "GPU 2 mapped to the unit that runs" ;;
  *) bad "GPU 2 map is '$(map)'" ;;
esac
grep -q "^120 llamacpp-qwen38fn enabled active$" "$T/units" && ok "qwen38fn unit is live" || bad "qwen38fn unit not live"
# 🔴 The outgoing unit must be GONE, not merely unmentioned. If it survives enabled it comes
# back with the container, fights the incoming server for the card and port 1234, and the
# watchdog — mapped to the incoming unit — would shed the wrong load on a trip.
grep -q "^120 llamacpp disabled inactive$" "$T/units" \
  && ok "outgoing qwen3.6 unit retired (disabled AND inactive)" \
  || bad "outgoing unit survived: $(grep '^120 llamacpp ' "$T/units")"
# ordering: the release must be logged before the attach
# ⚠️ `|| true` is load-bearing. With no match, grep exits 1, pipefail propagates it, the
# assignment inherits that status and `set -e` KILLS THIS TEST instead of reporting a
# failure — which is how a mutation that removed the release read as "not caught". Same
# trap the harness in this folder already hit once.
rel="$(grep -n 'set 123 --onboot 0' "$T/pct.log" | head -1 | cut -d: -f1 || true)"
att="$(grep -n 'set 120 --cores' "$T/pct.log" | head -1 | cut -d: -f1 || true)"
if [ -n "$rel" ] && [ -n "$att" ] && [ "$rel" -lt "$att" ]; then
  ok "CT 123 released before CT 120 was reconfigured"
else
  bad "ordering: CT 120 was reconfigured before CT 123 was released"
fi
double_binding_possible && bad "TWO CONTAINERS COULD HOLD GPU 2" || ok "exclusivity holds"
rm -rf "$T"

echo "=== 2. simulated host reboot while forward ==="
new_host; echo stopped >"$T/status.123"; run_cutover to-qwen38fn || true
# reboot: every container with onboot=1 starts
for vm in 120 123; do [ "$(awk '/^onboot:/{print $2}' "$T/lxc/$vm.conf")" = 1 ] && echo running >"$T/status.$vm"; done
[ "$(cat "$T/status.123")" = stopped ] && ok "CT 123 did NOT autostart after reboot" \
  || bad "CT 123 autostarted onto a card CT 120 holds"
double_binding_possible && bad "TWO CONTAINERS ON GPU 2 AFTER REBOOT" || ok "exclusivity survives reboot"
rm -rf "$T"

echo "=== 3a. failure DURING the release of CT 123 ==="
new_host; echo stopped >"$T/status.123"
FAIL_ON_PCT_SET=123 run_cutover to-qwen38fn && bad "reported success despite a failed mutation" \
  || ok "failed loudly"
gpu2_on_120 && bad "GPU 2 was attached even though releasing CT 123 failed" \
  || ok "GPU 2 not attached — the release is a precondition, not a parallel step"
double_binding_possible && bad "partial state allows two containers on GPU 2" || ok "no double-binding"
rm -rf "$T"

echo "=== 3b. failure AFTER the release, while reconfiguring CT 120 ==="
new_host; echo stopped >"$T/status.123"
FAIL_ON_PCT_SET=120 run_cutover to-qwen38fn && bad "reported success despite a failed mutation" \
  || ok "failed loudly"
[ "$(onboot_123)" = 0 ] && ok "CT 123 stayed released through the failure" \
  || bad "CT 123 autostart came back while CT 120 may hold GPU 2"
double_binding_possible && bad "partial state allows two containers on GPU 2" || ok "no double-binding"
# and the operator can still get back: the reverse path must work from the partial state
run_cutover to-qwen36 || bad "rollback from the partial state failed"
gpu2_on_120 && bad "GPU 2 still attached after rollback from a partial state" \
  || ok "rollback recovers the partial state"
[ "$(onboot_123)" = 1 ] && ok "CT 123 autostart restored by the rollback" || bad "CT 123 onboot is $(onboot_123)"
rm -rf "$T"

echo "=== 3c. the OUTGOING service cannot be retired ==="
new_host; echo stopped >"$T/status.123"
FAIL_DISABLE=llamacpp run_cutover to-qwen38fn \
  && bad "cut over while the old model server was still enabled — two servers, one card" \
  || ok "refused to proceed when the outgoing unit could not be retired"
gpu2_on_120 && bad "GPU 2 was attached despite the failed retirement" \
  || ok "GPU 2 untouched — retirement is a precondition, not a cleanup step"
grep -q "^120 llamacpp-qwen38fn enabled" "$T/units" \
  && bad "the incoming unit was enabled alongside a surviving outgoing unit" \
  || ok "incoming unit not enabled, so the two can never both be live"
rm -rf "$T"

echo "=== 4. reverse cutover, with CT 123 deliberately left stopped ==="
new_host; echo stopped >"$T/status.123"; run_cutover to-qwen38fn || true
run_cutover to-qwen36 || bad "rollback exited non-zero (the false protection alarm regression)"
gpu2_on_120 && bad "GPU 2 still attached to CT 120" || ok "GPU 2 detached"
[ "$(onboot_123)" = 1 ] && ok "CT 123 autostart restored" || bad "CT 123 onboot is $(onboot_123)"
case "$(map)" in
  *"${GPU2}=123:llamacpp-qwen38fn"*) ok "map handed GPU 2 back to CT 123" ;;
  *) bad "map is '$(map)'" ;;
esac
grep -q "^120 llamacpp enabled active$" "$T/units" && ok "qwen3.6 unit is live again" || bad "qwen3.6 unit not live"
grep -q "^120 llamacpp-qwen38fn disabled inactive$" "$T/units" \
  && ok "outgoing qwen4exp unit retired (disabled AND inactive)" \
  || bad "outgoing unit survived: $(grep '^120 llamacpp-qwen38fn ' "$T/units")"
rm -rf "$T"

echo
if [ "$fails" -gt 0 ]; then echo "🔴 ${fails} transition check(s) FAILED"; exit 1; fi
echo "✅ all cutover transition checks passed"
