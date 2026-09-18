#!/usr/bin/env bash
# Run the MTP / NextN speculation stage on its own. Proxmox HOST, root.
#
# Runs the MTP stage on its own, so a retry does not mean re-running the whole night. With
# MTP_SKIP_BUILD=true it reuses an existing /root/builds/mtp-b11018 on the builder instead
# of rebuilding, which is what you want when only the measurement needs repeating.
#
# 🔴 As of 2026-09-18 this stage CANNOT succeed: the rebased PR #28097 builds and serves but
# its MTP graph aborts on a shape mismatch against b11018's reshaped hyper-connection
# tensors. See the README. Re-try when #28097 rebases upstream.
#
# ⚠️ MTP_SKIP_BUILD re-asserts both guards against the existing artifact before trusting
# it — reusing a build is only safe if it still has the flag and the backend it was built for.
#
# The stage logic is EXTRACTED from the canonical script, not copied, so they cannot drift.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

RUN="${RUN:?set RUN to the overnight run directory}"
RESULTS="${RUN}/RESULTS.md"
CT=120; BUILDER=201; ENVF=/etc/llamacpp-qwen38fn.env
MODELDIR=/models/hf/qwen3.8-flash-next
MTPDIR=/opt/llamacpp/mtp-b11018
DRAFT_PLAIN="${MODELDIR}/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf"
DRAFT_SHARED="${MODELDIR}/mtp-Qwen3.8-Flash-Next-shared-Q4_K_M.gguf"
SRC="${SRC:-./overnight-part2.sh}"
export MTP_SKIP_BUILD=true
[ -r "$SRC" ] || { echo "FATAL: $SRC not readable"; exit 1; }
exec > >(tee -a "${RUN}/mtp.log") 2>&1

say()  { printf '\n########## %s  %s\n' "$(date -u +%FT%TZ)" "$*"; }
note() { printf '%s\n' "$*" >>"$RESULTS"; }
# shellcheck source=stagelib.sh
. ./stagelib.sh

setv() { pct exec "$CT" -- python3 -c '
import json, os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
line = key + "=" + json.dumps(val)
src = open(path).read() if os.path.exists(path) else ""
src, n = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", lambda m: line, src)
if not n: src = src.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(src)' "$ENVF" "$1" "$2"; }

ip() { pct exec "$CT" -- hostname -I | awk '{print $1}'; }
wait_up() { local t=0; until curl -fsS -m 4 "http://$(ip):1234/health" >/dev/null 2>&1; do
  pct exec "$CT" -- systemctl is-active --quiet llamacpp-qwen38fn || return 1
  sleep 5; t=$((t+5)); [ "$t" -ge "${1:-1200}" ] && return 1; done; echo "    up in ${t}s"; }

best_ncmoe() { cat "${RUN}/best_ncmoe.txt" 2>/dev/null || echo 16; }

for fn in mtp_set_placement mtp_cell mtp_row s3_mtp; do
  eval "$(sed -n "/^${fn}() {/,/^}/p" "$SRC")"
  declare -F "$fn" >/dev/null || { echo "FATAL: $fn not extracted from $SRC"; exit 1; }
done

stage mtp 14400 s3_mtp
say "MTP stage done — ${RESULTS}"
