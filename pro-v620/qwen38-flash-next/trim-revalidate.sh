#!/usr/bin/env bash
# Stop the re-validation after ROUND 1 and let the pipeline move on.
#
# 🔴 Why, and why this is not a rigor cut. Cells are running ~12-16 min and rising (the
# CPU-heavy end is slower), so 2 rounds + a 6-cell confirm pass is ~7.5 h -- past the
# stage's own 6 h timeout, which would kill it mid-round-2 and lose the confirm pass
# anyway, and push MTP and --parallel past morning entirely.
#
# What round 2 would refine is a curve measured at the DOCUMENTED --tensor-split, and that
# split has since been shown to overload card 1 by ~2 layers: -ncmoe 15 and 20 both spill
# to GTT there. So round 2 is a second sample of configs now known to be mis-split. The
# splitfix stage measures the same placements at CORRECTED splits with reps 2, which is
# where the placement conclusion actually comes from. Spending the night's remaining hours
# there, on contextsweep and on MTP is strictly more information than a second sample of
# invalid cells.
set -Eeuo pipefail
RUN="${RUN:?set RUN}"
LOG="${RUN}/pipeline.log"

while :; do
  grep -q '^======== round 2' "$LOG" 2>/dev/null && break
  pgrep -f 'revalidate\.sh' >/dev/null 2>&1 || { echo "revalidate already gone; nothing to trim"; exit 0; }
  sleep 30
done

pid=$(pgrep -f 'revalidate\.sh' | head -1) || true
[ -n "${pid:-}" ] || { echo "revalidate gone between check and kill"; exit 0; }
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')

{
  echo ""
  echo "⚠️ **Re-validation was stopped after round 1, deliberately.** Cells ran 12-16 min and"
  echo "rising, so two rounds plus the confirmation pass came to ~7.5 h — past this stage's own"
  echo "6 h timeout, which would have killed it mid-round-2 and lost the confirmation pass"
  echo "regardless, while pushing MTP and \`--parallel\` past morning."
  echo ""
  echo "Round 2 would have been a second sample of a curve measured at the **documented**"
  echo "\`--tensor-split\`, and that split is now known to overload card 1 by ~2 layers —"
  echo "\`-ncmoe\` 15 and 20 both spill to GTT there. The split-correction stage re-measures the"
  echo "same placements at corrected splits with 2 reps each, so that is where the placement"
  echo "conclusion comes from. Round 1 stands as single-sample context, not as the answer."
} >>"${RUN}/RESULTS.md"

echo "$(date -u +%FT%TZ) trimming revalidate after round 1 (pid ${pid}, pgid ${pgid})"
kill -TERM "-${pgid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
