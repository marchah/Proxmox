#!/usr/bin/env bash
# Wait for the whole-layer test, then run #2 (PR 28699) without an idle gap.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
while pgrep -f "structural-tests.sh wholelayer" >/dev/null 2>&1; do sleep 30; done
printf '%s whole-layer test finished; starting PR 28699\n' "$(date -u +%FT%TZ)"
exec ./structural-tests.sh pr28699
