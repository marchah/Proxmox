#!/usr/bin/env bash
# Finish the night: MTP, then restore, then the report. Proxmox HOST, root.
#
# 🔴 Why this exists rather than chain-finish.sh continuing: my contextsweep trimmer ran
# `kill -TERM -<pgid>` on the pgid it read from the contextsweep process — which was the
# CHAIN'S OWN process group, because chain-finish.sh invoked the stage as a plain command and
# it therefore inherited the chain's group. That killed the supervisor along with the stage,
# so MTP, restore and the report never ran.
#
# The revalidate trimmer did the same thing safely, and the difference is instructive:
# `stage` wraps its function in `set -m` + `( ... ) &`, which puts it in its OWN process
# group, so a group-kill there hits only the stage. A plainly-invoked child shares the
# parent's group.
#
# ⚠️ Rule: before `kill -TERM -<pgid>`, check the pgid is not the supervisor's own.
# `ps -o pgid= -p $$` in the supervisor is the value that must NOT match.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
RUN="${RUN:?set RUN}"
export RUN
LOG="${RUN}/chain-finish.log"
MYPGID=$(ps -o pgid= -p $$ | tr -d ' ')
printf '\n########## %s  FINISH2 armed (supervisor pgid %s — never group-kill this)\n' \
  "$(date -u +%FT%TZ)" "$MYPGID" | tee -a "$LOG"

step() {
  printf '\n########## %s  FINISH-STEP %s\n' "$(date -u +%FT%TZ)" "$1" | tee -a "$LOG"
  shift
  "$@" >>"$LOG" 2>&1 || printf '%s  ^ that step exited %d; continuing\n' "$(date -u +%FT%TZ)" "$?" | tee -a "$LOG"
}

step mtp     ./mtp-standalone.sh
step restore ./restore-standalone.sh
step report  ./morning-report.sh "$RUN"
systemctl stop qwen38fn-sampler 2>/dev/null || true
printf '\n%s  NIGHT COMPLETE — %s/RESULTS.md\n' "$(date -u +%FT%TZ)" "$RUN" | tee -a "$LOG"
