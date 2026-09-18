#!/usr/bin/env bash
# Single entry point for the unattended night. Proxmox HOST, root.
#
# Runs part 1 (governor -> persist -> re-validate placement at full clock) then part 2
# (MTP -> --parallel -> graph splits -> restore), sharing one RUN directory so both halves
# append to the same RESULTS.md.
#
# DESIGN RULE: part 2 runs even if part 1 failed or timed out. Part 1's stages are already
# failure-isolated and always exit 0, and part 2 falls back to a sane -ncmoe if part 1's
# winner file is missing — so an unsupervised failure costs one stage, never the night.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

RUN="${RUN:-/root/qwen38-flash-next/overnight-$(date -u +%Y%m%dT%H%M%SZ)}"
export RUN
mkdir -p "$RUN"
echo "RUN=${RUN}"

# A lock, because a second copy of this would fight the first over one model server and
# one env file, and the damage would be silent: interleaved restarts read as noise.
exec 9>/var/lock/qwen38fn-overnight.lock
flock -n 9 || { echo "another overnight pipeline holds the lock — refusing to start"; exit 1; }

# The thermal guard must be alive for the whole night: a dense-style CPU+GPU load is the
# worst case on this box and the watchdog cannot protect a hand-driven benchmark.
if ! pgrep -f "thermal-guard.sh" >/dev/null 2>&1; then
  echo "thermal guard was NOT running — starting it"
  setsid ./thermal-guard.sh >>/root/qwen38-flash-next/thermal-guard.log 2>&1 &
  sleep 2
fi
pgrep -f "thermal-guard.sh" >/dev/null || { echo "FATAL: no thermal guard"; exit 1; }

./overnight.sh      || echo "part 1 exited non-zero (rc=$?) — continuing to part 2 anyway"
./overnight-part2.sh || echo "part 2 exited non-zero (rc=$?)"

./morning-report.sh "$RUN" || echo "report generation failed; raw RESULTS.md still valid"
echo "NIGHT COMPLETE — ${RUN}/RESULTS.md"
