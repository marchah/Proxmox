#!/usr/bin/env bash
# Overnight pipeline part 2: MTP, --parallel, the graph-split diagnostic, and restore.
# Proxmox HOST, root. Chained after overnight.sh. Same failure-isolation rule: a dead stage
# must not stall the queue.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

CT=120; BUILDER=201; ENVF=/etc/llamacpp-qwen38fn.env
RUN="${RUN:?set RUN to the part-1 run directory}"
RESULTS="${RUN}/RESULTS.md"
MODELDIR=/models/hf/qwen3.8-flash-next
exec > >(tee -a "${RUN}/pipeline2.log") 2>&1

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

# BEST config from part 2's re-validation, read back rather than assumed.
best_ncmoe() { python3 - "$RUN" <<'PY'
import glob, json, os, re, statistics as st, sys
d = sorted(glob.glob("/root/qwen38-flash-next/reval-*/"), key=os.path.getmtime)
best, bv = 20, -1.0
if d:
    agg = {}
    for f in glob.glob(os.path.join(d[-1], "ncmoe*-t32-r*.json")):
        m = re.match(r"ncmoe(\d+)-t32-r\d+\.json$", os.path.basename(f))
        if not m: continue
        try: s = json.load(open(f)).get("summary", {})
        except Exception: continue
        a = [v["decode_tps_median"] for k, v in s.items() if k.startswith("d0/")]
        if a: agg.setdefault(int(m.group(1)), []).append(st.median(a))
    for n, vals in agg.items():
        mv = st.median(vals)
        if mv > bv: best, bv = n, mv
print(best)
PY
}

# ---------------------------------------------------------------- 3. MTP
# ---------------------------------------------------------------- 3. MTP
# ⚠️ ONE branch, not two cherry-picks. PR #28097 already CONTAINS #27836's three commits
# (same subjects, rebased SHAs), and #28097 is the one that teaches the loader the
# draft-head-only GGUF layout unsloth actually ships. Both report mergeable:false against
# current master, so cherry-picking them onto b11018 was the wrong shape — checking out
# #28097 directly is both simpler and the only combination its author tested.
#
# Because that binary is NOT b11018, a no-speculation control is run ON THE SAME BINARY.
# This repo's own rule: comparing two speculative configs measures agreement, not
# correctness. The control row also prices master drift against b11018-baseline for free.
MTPDIR=/opt/llamacpp/pr28097-mtp
DRAFT_PLAIN="${MODELDIR}/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf"
DRAFT_SHARED="${MODELDIR}/mtp-Qwen3.8-Flash-Next-shared-Q4_K_M.gguf"

mtp_set_placement() {  # <ncmoe>
  local nc="$1" c1=$(( $1 + (48 - $1) / 2 ))
  setv MODEL_CPU_MOE "$nc"; setv MODEL_TENSOR_SPLIT "${c1},$(( 48 - c1 ))"
  setv MODEL_THREADS 32; setv MODEL_PARALLEL 1; setv MODEL_GPU_LAYERS 99
  setv MODEL_EXPECTED_GPUS 2; setv MODEL_KV_TYPE ""; setv MODEL_MMPROJ_ON_CPU ""
  setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"; setv MODEL_LOAD_MODE ""
}

# Measure one arm. Writes its JSON and echoes "<d0> <accept>" or "DIED".
mtp_cell() {  # <label> <extra-args>
  local label="$1" extra="$2"
  setv EXTRA_ARGS "$extra" >&2
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn >&2
  # ⚠️ stdout of this function IS its return value (it is read with $(...)), so wait_up's
  # progress line has to go to stderr or "$r" starts with whitespace and every parse of it
  # silently yields the empty string.
  if ! wait_up 1500 >&2; then echo "DIED"; return 0; fi
  ./placement-probe.py "http://$(ip):1234" --reps 1 --n-predict 64 --depths 0,8000 >/dev/null 2>&1 || true
  ./placement-probe.py "http://$(ip):1234" --reps 2 --n-predict 160 --depths 0,8000 \
    >"${RUN}/${label}.json" 2>/dev/null || true
  python3 - "${RUN}/${label}.json" <<'PY'
import json, statistics as st, sys
try: s = json.load(open(sys.argv[1]))["summary"]
except Exception: print("DIED"); raise SystemExit
a = [v["decode_tps_median"] for v in s.values() if v.get("decode_tps_median")]
ac = [v.get("accept_pct_median") for v in s.values() if v.get("accept_pct_median") is not None]
print("%.2f %s" % (st.median(a) if a else 0.0, ("%.1f" % st.median(ac)) if ac else "none"))
PY
}

mtp_row() {  # <label> <json> -> one RESULTS table row
  python3 - "${RUN}/${2}.json" "$1" "${RUN}/mtp-control.json" >>"$RESULTS" <<'PY'
import json, os, statistics as st, sys
def rd(p):
    try: return json.load(open(p))
    except Exception: return None
d, lbl, cp = rd(sys.argv[1]), sys.argv[2], sys.argv[3]
if not d:
    print("| %s | DIED / no data | — | — | — | — |" % lbl); raise SystemExit
s = d.get("summary", {})
def med(pre, key="decode_tps_median"):
    v = [x[key] for k, x in s.items() if k.startswith(pre) and x.get(key)]
    return st.median(v) if v else None
a, b = med("d0/"), med("d8000/")
ac = [x.get("accept_pct_median") for x in s.values() if x.get("accept_pct_median") is not None]
c = rd(cp)
rel = "—"
if c and a:
    ca = [x["decode_tps_median"] for k, x in c.get("summary", {}).items()
          if k.startswith("d0/") and x.get("decode_tps_median")]
    if ca: rel = "%+.1f%%" % (100 * (a / st.median(ca) - 1))
# ⚠️ An output hash change IS the finding — speculation is not argmax-lossless on this
# stack, so a divergence has to be reported next to the speedup, never instead of it.
# 🔴 But compare at d0 ONLY. Measured on this box: reps at d0 always agree, while a d8000
# cell disagrees with ITSELF intermittently at temperature 0 (hybrid CPU/GPU reduction
# order varies with thread scheduling, and ~5.8k tokens of accumulated state is enough to
# flip a token). Hashing at depth would report that noise as speculation divergence.
def shas(summary):
    return sorted({x.get("sha") for k, x in summary.items()
                   if k.startswith("d0/") and x.get("sha")})
sha = shas(s)
same = "—"
if c:
    csha = shas(c.get("summary", {}))
    same = "identical" if (sha and sha == csha) else "**DIVERGED**"
gate = []
if d.get("any_degenerate"): gate.append("DEGENERATE")
# d0 only: a d8000 cell is not bit-reproducible here even at temperature 0.
z = [x for k, x in s.items() if k.startswith("d0/")]
if z and not all(x.get("reps_agree", True) for x in z): gate.append("d0 reps disagree")
print("| %s | %s | %s | %s | %s | %s%s |" % (
    lbl, ("%.2f" % a) if a else "—", ("%.2f" % b) if b else "—",
    ("%.1f" % st.median(ac)) if ac else "—", rel, same,
    (" ⚠️ " + ", ".join(gate)) if gate else ""))
PY
}

s3_mtp() {
  local NC; NC=$(best_ncmoe); echo "best -ncmoe from re-validation: ${NC}"
  echo "$NC" >"${RUN}/best_ncmoe.txt"

  pct start "$BUILDER" >/dev/null 2>&1 || true; sleep 15
  pct exec "$BUILDER" -- bash -s <<'BUILD'
set -Eeuo pipefail
cd /root/llama.cpp
git fetch --quiet origin
# #28097 supersedes #27836: it carries the same three NextN/MTP commits rebased, plus the
# draft-head-only (unsloth) layout support and the -md path fix. One checkout, no picks.
git fetch --quiet origin pull/28097/head:pr-28097 --force
git checkout --quiet --force pr-28097
git clean -qfd
git log --oneline -4
rm -rf build
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON -DGGML_NATIVE=ON \
  -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF >/dev/null
cmake --build build -j "$(nproc)" 2>&1 | tail -3
d=/root/builds/pr28097-mtp; rm -rf "$d"; mkdir -p "$d"
find build/bin -maxdepth 1 -type f -exec cp {} "$d/" \; 2>/dev/null || true
find build -name "*.so*" -exec cp -P {} "$d/" \; 2>/dev/null || true
chmod +x "$d"/llama-* 2>/dev/null || true
# Loud check: the whole point of this build is that flag value existing.
"$d/llama-server" --help 2>&1 | grep -q 'draft-mtp' \
  && echo "OK: --spec-type draft-mtp is present" \
  || { echo "🔴 draft-mtp ABSENT from the built server"; exit 4; }
BUILD
  local brc=$?
  if [ "$brc" -ne 0 ]; then
    note ""; note "## MTP — NOT TESTED"; note ""
    note "🔴 The build failed (rc=${brc}). \`--spec-type draft-mtp\` for \`qwen4exp\` comes from"
    note "llama.cpp PR **#28097** (which already contains #27836). Both are **open** and report"
    note "\`mergeable: false\` against master, so this may need the PR to be rebased upstream."
    note "The 4.70 GB of drafters are downloaded and waiting at \`${MODELDIR}/mtp-*.gguf\`."
    pct stop "$BUILDER" >/dev/null 2>&1 || true
    return 3
  fi
  pct exec "$BUILDER" -- bash -lc "cd /root/builds && tar czf /root/mtp.tgz pr28097-mtp"
  pct pull "$BUILDER" /root/mtp.tgz /tmp/mtp.tgz
  pct push "$CT" /tmp/mtp.tgz /tmp/mtp.tgz
  pct exec "$CT" -- bash -lc "tar xzf /tmp/mtp.tgz -C /opt/llamacpp/ && rm -f /tmp/mtp.tgz"
  rm -f /tmp/mtp.tgz; pct stop "$BUILDER" >/dev/null 2>&1 || true

  mtp_set_placement "$NC"
  setv LLAMACPP_DIR "$MTPDIR"

  note ""
  note "## Speculation — MTP / NextN (at \`-ncmoe ${NC}\`, llama.cpp PR #28097)"
  note ""
  note "| arm | d0 t/s | d8000 t/s | accept % | vs control | output |"
  note "| --- | ---: | ---: | ---: | ---: | --- |"

  # 1. Control FIRST, on this same binary, so every later row has something honest to
  #    divide by and a hash to compare against.
  local ctrl; ctrl=$(mtp_cell "mtp-control" "")
  echo "control: ${ctrl}"
  mtp_row "**none (control, same binary)**" "mtp-control"

  # 2. Which drafter does the loader accept? Two layouts shipped; the -shared- one declares
  #    qwen4exp.nextn_shared_target_tensors and expects the target to supply the rest.
  #    Decide by measurement — a guess here costs four dead cells.
  local best_draft="" best_v=0 r v
  for pair in "shared:${DRAFT_SHARED}" "plain:${DRAFT_PLAIN}"; do
    local tag="${pair%%:*}" path="${pair#*:}"
    r=$(mtp_cell "mtp-${tag}-nmax3" "--spec-type draft-mtp --model-draft ${path} --spec-draft-n-max 3 --spec-draft-ngl 99")
    echo "drafter ${tag}: ${r}"
    mtp_row "\`${tag}\` drafter, n-max 3" "mtp-${tag}-nmax3"
    v="${r%% *}"
    if [ "$r" != "DIED" ] && awk "BEGIN{exit !($v > $best_v)}"; then best_v="$v"; best_draft="$path"; fi
  done

  if [ -z "$best_draft" ]; then
    note ""
    note "🔴 **Neither drafter loaded.** The build is fine (\`--spec-type draft-mtp\` present),"
    note "so this is a GGUF-layout mismatch, which is exactly what PR #28097 claims to fix —"
    note "worth reporting upstream with both file listings."
    setv EXTRA_ARGS ""; setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline
    return 0
  fi
  note ""
  note "Drafter chosen by measurement: \`$(basename "$best_draft")\`."
  note ""
  note "| n-max | d0 t/s | d8000 t/s | accept % | vs control | output |"
  note "| --- | ---: | ---: | ---: | ---: | --- |"

  # 3. Sweep n-max on the drafter that works. ⚠️ n-max NEVER transfers between drafters or
  #    backends, so it has to be swept here even though other models on this box have a
  #    known-good value.
  for nmax in 2 4 6; do
    r=$(mtp_cell "mtp-nmax${nmax}" "--spec-type draft-mtp --model-draft ${best_draft} --spec-draft-n-max ${nmax} --spec-draft-ngl 99")
    echo "n-max ${nmax}: ${r}"
    mtp_row "n-max ${nmax}" "mtp-nmax${nmax}"
  done

  setv EXTRA_ARGS ""; setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline
}
stage mtp 18000 s3_mtp

# ---------------------------------------------------------------- 4. --parallel
s4_parallel() {
  local NC; NC=$(cat "${RUN}/best_ncmoe.txt" 2>/dev/null || echo 20)
  local c1=$(( NC + (48 - NC) / 2 ))
  note ""
  note "## Concurrency (\`--parallel\`) at \`-ncmoe ${NC}\`"
  note ""
  note "⚠️ \`--ctx-size\` is the TOTAL KV budget and \`--parallel\` divides it into slots, so VRAM"
  note "does not change and the placement dial does not need re-deriving. \`--threads\` IS"
  note "re-swept, because concurrency changes which term dominates."
  note ""
  note "| parallel | threads | ctx/slot | per-stream t/s | aggregate t/s | wall-clock agg |"
  note "| --- | ---: | ---: | ---: | ---: | ---: |"
  # 16 threads is swept alongside 32 because concurrency changes which term dominates:
  # with four streams the CPU-side expert FFN is contended, and the best thread count for
  # one stream need not be the best for four.
  # The last entry raises TOTAL ctx instead of threads. At 65536 total, --parallel 4 leaves
  # only 16k per slot, too small for real work -- so the VRAM cost of a usable slot size is
  # priced rather than assumed affordable.
  local spec par th ctx
  for spec in "1 32 65536" "1 16 65536" "2 32 65536" "2 16 65536" \
              "4 32 65536" "4 16 65536" "4 32 131072"; do
    read -r par th ctx <<<"$spec"
    setv MODEL_CPU_MOE "$NC"; setv MODEL_TENSOR_SPLIT "${c1},$(( 48 - c1 ))"
    setv MODEL_THREADS "$th"; setv MODEL_PARALLEL "$par"
    setv MODEL_CONTEXT_LENGTH "$ctx"
    setv MODEL_KV_TYPE ""; setv MODEL_MMPROJ_ON_CPU ""
    setv MODEL_GPU_LAYERS 99; setv MODEL_EXPECTED_GPUS 2; setv EXTRA_ARGS ""
    setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"
    setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline
    # This repo's own rule: the model MUST be reloaded at the target --parallel N or the
    # concurrency numbers are contaminated (p1 read ~53 t/s flat where p4 peaked ~92).
    pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
    if ! wait_up 1500; then note "| ${par} | ${th} | ${ctx} | DIED | - | - |"; continue; fi
    ./placement-probe.py "http://$(ip):1234" --reps 1 --n-predict 64 --depths 0 >/dev/null 2>&1 || true
    ./concurrency-probe.py "http://$(ip):1234" "$par" \
      >"${RUN}/par${par}-t${th}-c${ctx}.json" 2>/dev/null || true
    python3 - "${RUN}/par${par}-t${th}-c${ctx}.json" "$par" "$th" >>"$RESULTS" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception:
    print("| %s | %s | - | probe failed | - | - |" % (sys.argv[2], sys.argv[3])); raise SystemExit
warn = " QUEUED-NOT-CONCURRENT" if d.get("slot_warning") else ""
print("| %s | %s | %s | %.2f | %.2f | %.2f%s |" % (
    sys.argv[2], sys.argv[3], d.get("n_ctx_per_slot", "?"),
    d.get("per_stream_tps", 0), d.get("aggregate_tps", 0),
    d.get("wall_aggregate_tps", 0), warn))
PY
  done
  setv MODEL_PARALLEL 1; setv MODEL_CONTEXT_LENGTH 65536
}
stage parallel 18000 s4_parallel

# ---------------------------------------------------------------- 5. graph splits
s5_splits() {
  setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline; setv MODEL_PARALLEL 1
  pct exec "$CT" -- bash -lc "mkdir -p /etc/systemd/system/llamacpp-qwen38fn.service.d
cat >/etc/systemd/system/llamacpp-qwen38fn.service.d/sched-debug.conf <<D
[Service]
Environment=GGML_SCHED_DEBUG=2
D
systemctl daemon-reload; systemctl restart llamacpp-qwen38fn"
  wait_up 1200 || true
  curl -fsS -m 120 "http://$(ip):1234/completion" -H 'Content-Type: application/json' \
    -d '{"prompt":"hi","n_predict":2,"temperature":0,"cache_prompt":false}' >/dev/null 2>&1 || true
  pct exec "$CT" -- bash -lc "journalctl -u llamacpp-qwen38fn --no-pager -o cat | grep -ciE 'split|graph_compute' || true" \
    >"${RUN}/splits.txt" 2>/dev/null || true
  local n; n=$(cat "${RUN}/splits.txt" 2>/dev/null | tail -1 || echo "?")
  note ""
  note "## Graph splits (diagnostic for the ~43 ms floor)"
  note ""
  note "\`GGML_SCHED_DEBUG=2\` split-related log lines for a 2-token completion: **${n}**."
  note "PCIe is ruled out arithmetically — activations are only ~400 KB/token (16 µs at Gen4"
  note "x16) while each CPU↔GPU crossing measured **1.07 ms**, 535× the PCIe latency. The floor"
  note "is engine submission/synchronisation overhead, which is why llama.cpp PR #27880"
  note "(\"qwen4exp: reduce number of graph splits\") exists and why it did not go far enough."
  pct exec "$CT" -- bash -lc "rm -f /etc/systemd/system/llamacpp-qwen38fn.service.d/sched-debug.conf; systemctl daemon-reload" || true
}
stage graphsplits 3600 s5_splits

# ---------------------------------------------------------------- 6. restore
s6_restore() {
  local NC; NC=$(cat "${RUN}/best_ncmoe.txt" 2>/dev/null || echo 20)
  local c1=$(( NC + (48 - NC) / 2 ))
  setv MODEL_CPU_MOE "$NC"; setv MODEL_TENSOR_SPLIT "${c1},$(( 48 - c1 ))"
  setv MODEL_THREADS 32; setv MODEL_PARALLEL 1; setv MODEL_GPU_LAYERS 99
  setv MODEL_EXPECTED_GPUS 2; setv EXTRA_ARGS ""; setv MODEL_KV_TYPE ""
  setv MODEL_MMPROJ_ON_CPU ""; setv MODEL_LOAD_MODE ""
  setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"
  setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn; wait_up 1200 || true
  # Hermes back up. CT 123 stays stopped: it holds GPU 2 with no device selector and would
  # fight CT 120 for a card.
  pct start 121 >/dev/null 2>&1 || true; sleep 25
  note ""
  note "## Final state"
  note ""
  note "- CT 120 serving \`-ncmoe ${NC}\`, threads 32, parallel 1, b11018-baseline"
  note "- CT 121 (Hermes) **started** — ⚠️ its 22:00 backup cron was missed tonight, trigger by hand"
  note "- CT 123 left **stopped** (it would grab a card from CT 120)"
  note "- CT 201 (builder) stopped; destroy with \`pct destroy 201\` when done"
  note "- Governor: **$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)**, persistent via \`cpu-governor.service\`"
}
stage restore 2400 s6_restore

say "OVERNIGHT PIPELINE COMPLETE — ${RESULTS}"
