#!/usr/bin/env bash
# Stages 2 and 3 of the baseline record back to back, then the restore, so they need no one
# between them. Runs on the Proxmox HOST as root, from a harness staged by ../push-harness.sh,
# after stage 1 in the two-card setup:
#
#   systemd-run --unit=mimo-stages-2-3 --collect $H/mimo-v26-pro/run-rest.sh
#
# Stage 2's screen picks stage 3's n-max by the record's rule (pick-nmax.py). A failure in
# either stage, a thermal trip included, stops here: the test setup stays in place and the
# server stays down. After stage 3 it stops the thermal guard and restores CT 123: Flash-Next
# back on GPU 2 and CT 120's autostart as it was. It starts no other guest.
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
log() { printf '%s ==> %s\n' "$(date -u +%FT%TZ)" "$*"; }

"${HERE}/run-stage.sh" mtp
screen="$(ls -d /root/mimo/sweep-mtp-*/ | sort | tail -n 1)"
nmax="$("${HERE}/pick-nmax.py" "$screen")"
log "stage 2 picked n-max ${nmax} (${screen})"

NMAX="$nmax" "${HERE}/run-stage.sh" timed

log "restoring CT 123"
systemctl stop mimo-guard
(cd "${HERE}/../glm53-flash" && ./ct123-test-host.sh restore)
log "done; CT 120 and the other guests stay stopped for the owner"
