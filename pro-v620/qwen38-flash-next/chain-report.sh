#!/usr/bin/env bash
# overnight-all.sh was killed to re-order part 2, so the report generation it would have
# run at the end has to be re-armed separately.
set -Eeuo pipefail
RUN="${RUN:?set RUN}"
cd "$(dirname "$(readlink -f "$0")")"
while systemctl is-active --quiet qwen38fn-part2; do sleep 60; done
sleep 10
./morning-report.sh "$RUN" || echo "report generation failed; raw RESULTS.md still valid"
# The sampler has no natural end; stop it so its telemetry file is closed for analysis.
systemctl stop qwen38fn-sampler 2>/dev/null || true
echo "$(date -u +%FT%TZ) NIGHT COMPLETE — ${RUN}/RESULTS.md"
