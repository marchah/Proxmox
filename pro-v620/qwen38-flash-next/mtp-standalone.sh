#!/usr/bin/env bash
# Run the MTP / NextN speculation stage on its own. Proxmox HOST, root.
#
# Why: the stage BUILT successfully (585 targets, `--spec-type draft-mtp` and ggml-vulkan
# both asserted present) and then failed rc=2 copying its own output, because the build
# directory had been renamed to mtp-b11018 while the tar still said pr28097-mtp. The
# artifact is intact on the builder, so this re-runs the stage with MTP_SKIP_BUILD=true and
# spends the time on measurement instead of a rebuild.
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
SRC="${SRC:-./overnight-part2-fixed.sh}"
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
