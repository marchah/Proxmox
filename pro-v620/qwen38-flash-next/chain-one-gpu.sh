#!/usr/bin/env bash
# Wait for a running two-GPU placement sweep, then run the ONE-GPU control.
# Runs on the Proxmox HOST as root, from this directory.
#
# Why this control matters. During the two-GPU run the cards ALTERNATE (6-83% each) and
# nothing saturates — the signature llama.cpp #28699 describes, where the QSA indexer's
# pooled summary rows cross the inter-GPU link every layer, measured upstream at **2x decode
# cost on a layer split**. That fix is an open draft. So:
#   one card >= two cards at the same placement  -> the penalty is real here, and the second
#                                                   card buys CAPACITY only, not speed
#   one card <  two cards                        -> the split is working; the shortfall vs the
#                                                   sizing note is elsewhere
# Either way the answer changes what a third card is worth, which is the purchase question
# `large-moe-build-shapes.md` exists to settle.
#
# ncmoe 34 and 48 are the two values the two-GPU sweep also ran AND that fit a single ~30 GiB
# card, so they compare directly. 40 is there for curve shape. Below 34 a single card cannot
# hold the non-CPU share at all.
set -Eeuo pipefail
cd "$(dirname "$0")"

LOG="${LOG:-/root/qwen38-flash-next/sweep-onegpu.log}"

while pgrep -f "placement-sweep.sh" >/dev/null 2>&1; do sleep 60; done
printf '%s two-GPU sweep finished; starting the ONE_GPU control\n' "$(date -u +%FT%TZ)"

ONE_GPU=true NCMOE_LIST="${NCMOE_LIST:-34 40 48}" REPS="${REPS:-2}" \
  DEPTHS="${DEPTHS:-0,8000}" N_PREDICT="${N_PREDICT:-192}" \
  ./placement-sweep.sh >"$LOG" 2>&1
printf '%s ONE_GPU control finished -> %s\n' "$(date -u +%FT%TZ)" "$LOG"
