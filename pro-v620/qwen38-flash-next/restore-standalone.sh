#!/usr/bin/env bash
# Put the box back on the measured winning shape. Proxmox HOST, root.
#
# A separate file rather than an inline `bash -c` inside the finish chain: that needed three
# levels of nested quoting around an embedded python heredoc, which is exactly the shape of
# bug that has cost this pipeline two stages tonight.
#
# Runs LAST, because contextsweep and mtp both rewrite the model env, so part 2's own
# restore is stale by the time they are done.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
RUN="${RUN:?set RUN}"
RESULTS="${RUN}/RESULTS.md"
CT=120; ENVF=/etc/llamacpp-qwen38fn.env
SRC="${SRC:-./overnight-part2-fixed.sh}"
exec > >(tee -a "${RUN}/restore.log") 2>&1

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

eval "$(sed -n '/^s6_restore() {/,/^}/p' "$SRC")"
declare -F s6_restore >/dev/null || { echo "FATAL: s6_restore not extracted from $SRC"; exit 1; }
stage restore 2400 s6_restore
say "restore done"
