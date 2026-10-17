#!/usr/bin/env bash
# Mocked test for strata-yardstick.sh's thermal-trip handling. Runs anywhere, touches no host:
# a stub `pct` logs every call, and can play a thermal trip or a failed restart.
#
# Checks that the server is restarted after a clean run, and never after a trip: one recorded
# before the start, one during an engine run, or one between engine runs. A failed restart must
# fail the script.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SCRIPT="$PWD/strata-yardstick.sh"
[ -x "$SCRIPT" ] || { echo "strata-yardstick.sh not found next to this test"; exit 1; }
fails=0
ok()  { printf '    ✅ %s\n' "$*"; }
bad() { printf '    🔴 %s\n' "$*"; fails=$((fails + 1)); }
# check DESCRIPTION COMMAND...: one assertion, reported with the script's output on failure.
check() {
  local what="$1"; shift
  if "$@"; then ok "$what"; else bad "${what} (exit ${STATUS}; pct calls: $(tr '\n' ';' <"$T/calls"); output: ${OUT})"; fi
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# STUB_TRIP: trip during the first engine run, which fails (`run`), or after it, which succeeds
# (`after-run`). STUB_START_FAIL=1: `systemctl start` fails.
cat >"$T/bin/pct" <<'EOF'
#!/usr/bin/env bash
echo "pct $*" >>"$STUB_LOG"
case "$*" in
  *"quant_quality.py run"*)
    case "${STUB_TRIP:-}" in
      run) touch "$TRIP_FILE"; exit 1 ;;
      after-run) touch "$TRIP_FILE" ;;
    esac ;;
  *"systemctl start strata-qwen38fn"*) [ "${STUB_START_FAIL:-0}" = 1 ] && exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/bin/pct"

# run CASE [ENV=VALUE ...]: a fresh trip file and call log, then the script; sets STATUS, OUT.
run() {
  local name="$1"; shift
  rm -f "$T/trip" "$T/calls"; : >"$T/calls"
  [ "${PRE_TRIP:-0}" = 1 ] && touch "$T/trip"
  echo "  ${name}"
  STATUS=0
  OUT="$(env "$@" PATH="$T/bin:$PATH" STUB_LOG="$T/calls" TRIP_FILE="$T/trip" bash "$SCRIPT" 2>&1)" || STATUS=$?
}
starts() { [ "$(grep -c "systemctl start strata-qwen38fn" "$T/calls")" -eq "$1" ]; }
engine_runs() { [ "$(grep -c "quant_quality.py run\|quant_quality.py prompt" "$T/calls")" -eq "$1" ]; }
says() { grep -q "$1" <<<"$OUT"; }
never_says() { ! grep -q "$1" <<<"$OUT"; }
no_pct_call() { [ ! -s "$T/calls" ]; }

run "a clean run restarts the server"
check "exit 0" [ "$STATUS" -eq 0 ]
check "one restart" starts 1
check "four engine runs" engine_runs 4

run "a trip during an engine run leaves the server stopped" STUB_TRIP=run
check "fails" [ "$STATUS" -ne 0 ]
check "no restart" starts 0
check "says the server stays stopped" says "stays stopped"

run "a trip between engine runs stops before the next one" STUB_TRIP=after-run
check "fails" [ "$STATUS" -ne 0 ]
check "no engine run after the trip" engine_runs 1
check "no restart" starts 0

PRE_TRIP=1 run "a trip recorded before the start touches nothing"
PRE_TRIP=0
check "fails" [ "$STATUS" -ne 0 ]
check "no pct call" no_pct_call

run "a failed restart fails the script" STUB_START_FAIL=1
check "fails" [ "$STATUS" -ne 0 ]
check "says the server did not start" says "did not start"
check "does not claim a restart" never_says "restarted"

if [ "$fails" -eq 0 ]; then
  echo "strata-yardstick-test: all passed"
else
  echo "strata-yardstick-test: ${fails} failed"
  exit 1
fi
