#!/usr/bin/env bash
# Finish the night: run the two stages that failed on script bugs, then restore and report.
# Proxmox HOST, root.
#
# Part 2's own contextsweep and mtp stages both died on bugs of mine rather than on
# measurements (a two-field `read` of a four-field file; a build directory renamed without
# updating its tar). Both are fixed in overnight-part2-fixed.sh. Part 2 is still running its
# remaining stages, and bash reads a script incrementally, so the fixes could not be applied
# in place — hence these run afterwards, from the fixed copy.
#
# ORDER MATTERS: restore comes last, because contextsweep and mtp both rewrite the model
# env. Part 2's own restore will have run before these, so this re-runs it at the true end.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
RUN="${RUN:?set RUN}"
export RUN
LOG="${RUN}/chain-finish.log"

step() {  # step <name> <command...>
  printf '\n########## %s  FINISH-STEP %s\n' "$(date -u +%FT%TZ)" "$1" | tee -a "$LOG"
  shift
  "$@" >>"$LOG" 2>&1 || printf '%s  ^ that step exited %d; continuing\n' "$(date -u +%FT%TZ)" "$?" | tee -a "$LOG"
}

while systemctl is-active --quiet qwen38fn-part2; do sleep 60; done
sleep 15
step contextsweep ./contextsweep-standalone.sh
step mtp          ./mtp-standalone.sh

# Final restore -- its own file, because inlining it needed three levels of nested quoting
# around an embedded python heredoc, which is precisely the shape of bug that cost this
# pipeline two stages tonight.
step restore ./restore-standalone.sh

step report ./morning-report.sh "$RUN"
systemctl stop qwen38fn-sampler 2>/dev/null || true
printf '\n%s  NIGHT COMPLETE — %s/RESULTS.md\n' "$(date -u +%FT%TZ)" "$RUN" | tee -a "$LOG"
