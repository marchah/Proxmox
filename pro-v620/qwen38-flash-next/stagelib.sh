#!/usr/bin/env bash
# Shared stage runner for the overnight pipeline. Sourced, not executed.
#
# 🔴 WHY THIS FILE EXISTS. The obvious implementation —
#
#     timeout "$seconds" my_shell_function
#
# — does not work and does not fail loudly. `timeout(1)` execs a real program; handed the
# name of a shell function it exits **127 immediately**. Because each stage was wrapped to
# "never stall the night", all six stages reported a failure and the whole pipeline
# completed in 2 seconds having measured nothing. The failure-isolation that was supposed
# to make the night robust is exactly what hid it.
#
# So the deadline is enforced by a watchdog process instead, and `stage` additionally
# refuses to run a name that is not a defined function.

# Callers must define: say() and note().
stage() {  # stage <name> <timeout-seconds> <function> [args...]
  local name="$1" to="$2"; shift 2
  local fn="$1" t0 rc=0 pid wd mins

  # Loud guard for the bug above: a typo'd or missing stage function is now a named
  # failure in RESULTS, not six silent rc=127 lines.
  if ! declare -F "$fn" >/dev/null 2>&1; then
    say "STAGE ${name} SKIPPED — '${fn}' is not a defined function"
    note "- 🔴 **${name}** SKIPPED: no such stage function \`${fn}\`"
    return 0
  fi

  say "STAGE ${name} (timeout ${to}s)"
  t0=$(date +%s)

  # `set -m` puts the subshell in its own process group, so the watchdog's kill reaches the
  # pct/python/curl descendants rather than only the subshell that spawned them.
  set -m
  ( "$@" ) & pid=$!
  set +m

  ( sleep "$to"; kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null ) & wd=$!

  wait "$pid" || rc=$?
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true

  mins=$(( ($(date +%s) - t0) / 60 ))
  case "$rc" in
    0)
      say "STAGE ${name} OK (${mins} min)"
      note "- ✅ **${name}** completed in ${mins} min" ;;
    124|143)  # 143 = SIGTERM from the watchdog above
      say "STAGE ${name} TIMED OUT (${mins} min)"
      note "- ⏰ **${name}** TIMED OUT after ${mins} min" ;;
    *)
      say "STAGE ${name} FAILED rc=${rc} (${mins} min)"
      note "- 🔴 **${name}** FAILED (rc=${rc}) after ${mins} min" ;;
  esac
  return 0
}
