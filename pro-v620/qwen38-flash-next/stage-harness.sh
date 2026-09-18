#!/usr/bin/env bash
# Exercises stagelib.sh against deliberately broken stages, to catch the `set -u`/exit-status
# bugs that `bash -n` and shellcheck cannot see. Safe: it touches no model service.
# The stage bodies are pulled in with `eval` below, so the fixture variables are referenced
# by code shellcheck cannot see. Genuine false positives, not unused assignments — hence a
# file-scoped disable with its reason, rather than deleting the fixtures. A directive only
# scopes to the whole file if it precedes the first command, so it sits here.
# shellcheck disable=SC2034
set -Eeuo pipefail
RUN=/tmp/tstg; rm -rf "$RUN"; mkdir -p "$RUN"; RESULTS="$RUN/R.md"; : >"$RESULTS"
CT=120; BUILDER=201; ENVF=/dev/null
MODELDIR=/models/hf/qwen3.8-flash-next
MTPDIR=/opt/llamacpp/mtp-b11018
DRAFT_PLAIN="$MODELDIR/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf"
DRAFT_SHARED="$MODELDIR/mtp-Qwen3.8-Flash-Next-shared-Q4_K_M.gguf"
export MTP_SKIP_BUILD=true
printf '16 30 q8_0 true\n' >"$RUN/best_split.txt"
printf '16\n' >"$RUN/best_ncmoe.txt"; printf '30\n' >"$RUN/best_c1.txt"
printf 'q8_0 true\n' >"$RUN/best_shape.txt"; printf '16\n' >"$RUN/best_threads.txt"
note() { printf '%s\n' "$*" >>"$RESULTS"; }
say()  { printf '[say] %s\n' "$*"; }
setv() { :; }
ip() { echo 127.0.0.1; }
wait_up() { return 0; }
sleep() { :; }
pct() { case "$*" in *"test -x"*) return 0;; *"--help"*) return 0;; esac; return 0; }
curl() { return 0; }
best_ncmoe() { echo 16; }
mtp_cell() { echo "12.00 45.0"; }
mtp_row()  { echo "  [row $1]"; }
ctx_cell() { echo "  [ctx_cell $*]"; }
split_cell() { echo "  [split_cell $*]"; }
split_headroom() { echo "fits 4000 4000 71 15"; }
# 🔴 THIS HARNESS USED TO REPORT FAILURES AND STILL EXIT 0. The if/else swallowed every
# non-zero status, so a human saw "🔴 FAIL" while any caller checking $? saw success — a
# false green in the one tool whose entire job is catching failures. It now counts failures
# and exits non-zero.
# 🔴 It also could not tell "the stage is broken" from "I failed to load the stage": an
# extraction that matched nothing made `eval ""` succeed, leaving the function undefined, so
# the stage later reported rc=127 as if it were a stage bug. Both are checked separately now.
fails=0
for fn in mtp_set_placement s2c_context s3_mtp s2b_split s4_parallel; do
  body="$(sed -n "/^${fn}() {/,/^}/p" overnight-part2.sh)"
  if [ -z "$body" ]; then
    echo "  🔴 EXTRACT FAIL ${fn} — sed matched nothing (HARNESS bug, not a stage bug)"
    fails=$((fails + 1)); continue
  fi
  if ! eval "$body"; then
    echo "  🔴 EVAL FAIL ${fn}"; fails=$((fails + 1)); continue
  fi
  if ! declare -F "$fn" >/dev/null; then
    echo "  🔴 ${fn} undefined after eval (extraction captured a partial body?)"
    fails=$((fails + 1)); continue
  fi
done
for fn in s2c_context s3_mtp s2b_split; do
  if ( "$fn" >/dev/null 2>&1 ); then
    echo "  OK   $fn"
  else
    echo "  🔴 FAIL $fn (rc=$?)"; fails=$((fails + 1))
  fi
done
if [ "$fails" -gt 0 ]; then
  echo "🔴 ${fails} harness check(s) FAILED"
  exit 1
fi
echo "✅ all harness checks passed"
