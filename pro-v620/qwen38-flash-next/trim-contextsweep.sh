#!/usr/bin/env bash
# Stop the context sweep after its first cell and let the chain move on to MTP.
#
# 🔴 Why, and it is a flaw in the sweep's DESIGN rather than bad luck. It tests long
# contexts at the placement with the LEAST headroom (the fastest one, -ncmoe 16), which is
# exactly where a bigger KV cannot fit. Measured on cell 1 (ctx 131072, f16): 226 MiB free
# with 183 MiB in GTT on card 1 and 573 MiB on card 2 — spilling, and therefore slow, which
# is why one cell took 45 min instead of 22.
#
# The arithmetic says cell 2 (262144 at q8_0, +2.25 GiB of KV over the 65536 baseline) will
# spill too. Only cell 3 (262144 at -ncmoe 28, which has 9.3/11.1 GiB spare) can fit.
#
# ✅ And the question the sweep existed to answer is already answered from elsewhere: the
# --parallel stage ran `--parallel 4 --ctx-size 131072` at the winning q8_0 shape and got
# 30.52 t/s aggregate with no spill. So 131072 fits at the recommended placement; it is only
# the f16 variant that does not. Spending another ~100 min re-discovering that at the cost
# of the MTP stage would be the wrong trade.
#
# Cell 1's shallow probe is kept (it is the evidence that f16 at 131072 spills). Its 32k deep
# arm is dropped: a 32k prefill on a spilling config is ~20 min for a number that describes
# a configuration nobody should run.
set -Eeuo pipefail
RUN="${RUN:?set RUN}"

# Wait for cell 1's shallow JSON to be complete (non-empty), then stop the stage.
while :; do
  f="${RUN}/ctx131072-f16-best.json"
  [ -s "$f" ] && break
  pgrep -f 'contextsweep-standalone' >/dev/null 2>&1 || { echo "contextsweep already gone"; exit 0; }
  sleep 20
done

{
  echo ""
  echo "⚠️ **The context sweep was stopped after its first cell, deliberately.** Its design was"
  echo "wrong: it tested long contexts at the placement with the LEAST headroom (\`-ncmoe 16\`),"
  echo "which is where a bigger KV cache cannot fit. Cell 1 (\`ctx 131072\`, f16) measured"
  echo "**226 MiB free with 183 MiB in GTT** on card 1 — spilling, and so slow that one cell took"
  echo "45 minutes."
  echo ""
  echo "✅ The question it existed to answer was already answered elsewhere: the \`--parallel\`"
  echo "stage ran \`--parallel 4 --ctx-size 131072\` at the winning \`q8_0\` shape and got 30.52 t/s"
  echo "aggregate with **no spill**. So **131072 fits at the recommended placement** — it is only"
  echo "the f16 variant that does not, because f16 KV costs 24 KiB/token against q8_0's 12."
  echo ""
  echo "What remains genuinely unmeasured is the full native **262144** window, which needs a"
  echo "roomier placement (\`-ncmoe 28\` has 9.3/11.1 GiB spare). That is one cell, and it was"
  echo "traded for the MTP stage rather than dropped on principle."
} >>"${RUN}/RESULTS.md"

pid=$(pgrep -f 'contextsweep-standalone' | head -1) || true
[ -n "${pid:-}" ] || { echo "gone between check and kill"; exit 0; }
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
echo "$(date -u +%FT%TZ) stopping contextsweep after cell 1 (pid ${pid}, pgid ${pgid})"
kill -TERM "-${pgid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
