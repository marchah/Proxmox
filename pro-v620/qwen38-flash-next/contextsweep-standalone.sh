#!/usr/bin/env bash
# Run the context sweep on its own. Proxmox HOST, root.
#
# Why this exists: contextsweep failed in part 2 because `read -r NC C1 < best_split.txt`
# consumed only two of that file's four fields, so C1 became "30 q8_0 true" and
# $(( 48 - c1 )) was an arithmetic syntax error. The fix is in overnight-part2.sh, but that
# file was mid-execution (MTP) when the bug was found, and **bash reads a script
# incrementally — rewriting one while it runs shifts byte offsets and can corrupt
# execution.** So the fixed copy went to overnight-part2-fixed.sh and this runs the stage
# from there once part 2 is done.
#
# The stage logic is EXTRACTED from the canonical script rather than copied, so the two
# cannot drift apart.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

RUN="${RUN:?set RUN to the overnight run directory}"
RESULTS="${RUN}/RESULTS.md"
CT=120; ENVF=/etc/llamacpp-qwen38fn.env
MODELDIR=/models/hf/qwen3.8-flash-next
SRC="${SRC:-./overnight-part2-fixed.sh}"
[ -r "$SRC" ] || { echo "FATAL: $SRC not readable"; exit 1; }
exec > >(tee -a "${RUN}/contextsweep.log") 2>&1

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

# Pull the two functions out of the canonical script.
eval "$(sed -n '/^ctx_cell() {/,/^}/p'    "$SRC")"
eval "$(sed -n '/^s2c_context() {/,/^}/p' "$SRC")"
declare -F ctx_cell    >/dev/null || { echo "FATAL: ctx_cell not extracted from $SRC"; exit 1; }
declare -F s2c_context >/dev/null || { echo "FATAL: s2c_context not extracted from $SRC"; exit 1; }

stage contextsweep 10800 s2c_context
say "context sweep done — ${RESULTS}"
