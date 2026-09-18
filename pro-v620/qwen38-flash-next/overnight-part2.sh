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

# ------------------------------------------------- 2b. the tensor-split correction
# 🔴 FOUND MID-RUN by an external sampler, and it invalidates the VRAM-hungry end of the
# curve. At -ncmoe 15 with this repo's documented split rule
#   c1 = ncmoe + (48 - ncmoe) / 2          -> 31,17
# card 1 sat at 30665 MiB with **39 MiB free and 2060 MiB spilled to GTT**, while card 2
# had 3280 MiB free. A GTT spill is a ~12x decode collapse that the startup loud-guard does
# NOT catch, so such a cell reads as "a slow placement" rather than "a broken one".
#
# The imbalance measures 1620 MiB and one heavy layer is ~1640 MiB — i.e. **exactly one
# layer**. The documented rule balances by WEIGHT alone, but three other things live on the
# card that owns a layer:
#   * the KV cache — 12 of the 48 layers are full-attention (QSA every 4th), and at c1=31
#     card 1 owns 7 of them against card 2's 5
#   * the vision projector, +1.11 GiB, which lands on a single device
#   * per-device compute buffers
#
# So the corrected rule is  c1 = ncmoe + (48 - ncmoe) / 2 - 1.  This stage tests it where it
# matters — the placements at or over the edge — and records VRAM headroom and GTT for both
# cards, which cell() does not.
split_cell() {  # <label> <ncmoe> <c1> [kv_type] [mmproj_on_cpu]
  local label="$1" nc="$2" c1="$3" kv="${4:-}" mp="${5:-}"
  setv MODEL_GPU_LAYERS 99; setv MODEL_EXPECTED_GPUS 2
  setv MODEL_CPU_MOE "$nc"; setv MODEL_TENSOR_SPLIT "${c1},$(( 48 - c1 ))"
  setv MODEL_THREADS 32; setv MODEL_PARALLEL 1; setv MODEL_CONTEXT_LENGTH 65536
  setv MODEL_KV_TYPE "$kv"; setv MODEL_MMPROJ_ON_CPU "$mp"
  setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"; setv MODEL_LOAD_MODE ""
  setv EXTRA_ARGS ""; setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
  if ! wait_up 1500; then note "| ${nc} | ${c1},$(( 48 - c1 )) | DIED | - | - | - | - |"; return 0; fi
  ./placement-probe.py "http://$(ip):1234" --reps 1 --n-predict 64 --depths 0,8000 \
    --classes code >/dev/null 2>&1 || true
  ./placement-probe.py "http://$(ip):1234" --reps 2 --n-predict 160 --depths 0,8000 \
    >"${RUN}/${label}.json" 2>/dev/null || true
  local A=/sys/bus/pci/devices/0000:03:00.0 B=/sys/bus/pci/devices/0000:83:00.0
  # FREE VRAM and GTT, not used VRAM: "used" looks healthy right up to the spill.
  local f1 g1 f2 g2
  f1=$(( ($(cat $A/mem_info_vram_total) - $(cat $A/mem_info_vram_used))/1048576 ))
  g1=$(( $(cat $A/mem_info_gtt_used)/1048576 ))
  f2=$(( ($(cat $B/mem_info_vram_total) - $(cat $B/mem_info_vram_used))/1048576 ))
  g2=$(( $(cat $B/mem_info_gtt_used)/1048576 ))
  python3 - "${RUN}/${label}.json" "$nc" "${c1},$(( 48 - c1 ))" "$f1" "$g1" "$f2" "$g2" \
          "${kv:-f16} / $([ "${mp:-}" = true ] && echo "proj CPU" || echo "proj GPU")" >>"$RESULTS" <<'PY'
import json, statistics as st, sys
_, path, nc, split, f1, g1, f2, g2, shape = sys.argv
try: s = json.load(open(path))["summary"]
except Exception:
    print("| %s | %s | %s | probe failed | - | - | - |" % (nc, split, shape)); raise SystemExit
def med(pre):
    v = [x["decode_tps_median"] for k, x in s.items()
         if k.startswith(pre) and x.get("decode_tps_median")]
    return st.median(v) if v else 0.0
# The verdict is HEADROOM, not throughput: under ~1 GiB free RADV spills silently, and a
# non-zero GTT on a card whose tensors should all be resident IS the spill.
free_min, gtt_max = min(int(f1), int(f2)), max(int(g1), int(g2))
if gtt_max > 256 or free_min < 1024: verdict = "**SPILLED**"
elif free_min < 2048:                verdict = "tight"
else:                                verdict = "fits"
# Recorded so the winner picker can refuse a spilled cell -- tok/s alone would crown one.
open(path.replace(".json", ".verdict"), "w").write(verdict.strip("*") + "\n")
print("| %s | %s | %s | %.2f | %.2f | %s / %s | %s / %s | %s |" % (
    nc, split, shape, med("d0/"), med("d8000/"), f1, f2, g1, g2, verdict))
PY
}

# Phase 1: load only, then read headroom. No inference -- "does it fit" is a memory
# question, and answering it with a 12-minute throughput probe is pure waste.
split_headroom() {  # <label> <ncmoe> <c1> [kv] [mmproj_on_cpu] -> verdict on stdout
  local label="$1" nc="$2" c1="$3" kv="${4:-}" mp="${5:-}"
  setv MODEL_GPU_LAYERS 99 >&2; setv MODEL_EXPECTED_GPUS 2 >&2
  setv MODEL_CPU_MOE "$nc" >&2; setv MODEL_TENSOR_SPLIT "${c1},$(( 48 - c1 ))" >&2
  setv MODEL_THREADS 32 >&2; setv MODEL_PARALLEL 1 >&2; setv MODEL_CONTEXT_LENGTH 65536 >&2
  setv MODEL_KV_TYPE "$kv" >&2; setv MODEL_MMPROJ_ON_CPU "$mp" >&2
  setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU" >&2; setv MODEL_LOAD_MODE "" >&2
  setv EXTRA_ARGS "" >&2; setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline >&2
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn >&2
  if ! wait_up 1500 >&2; then echo "DID-NOT-LOAD 0 0 0 0"; return 0; fi
  # One tiny request, so the compute buffers and the KV are really allocated. Reading
  # headroom straight after /health reports OK would miss buffers llama.cpp allocates lazily.
  curl -fsS -m 120 "http://$(ip):1234/completion" -H 'Content-Type: application/json' \
    -d '{"prompt":"hi","n_predict":8,"temperature":0,"cache_prompt":false}' >/dev/null 2>&1 || true
  local A=/sys/bus/pci/devices/0000:03:00.0 B=/sys/bus/pci/devices/0000:83:00.0
  local f1 g1 f2 g2
  f1=$(( ($(cat $A/mem_info_vram_total) - $(cat $A/mem_info_vram_used))/1048576 ))
  g1=$(( $(cat $A/mem_info_gtt_used)/1048576 ))
  f2=$(( ($(cat $B/mem_info_vram_total) - $(cat $B/mem_info_vram_used))/1048576 ))
  g2=$(( $(cat $B/mem_info_gtt_used)/1048576 ))
  local fm=$(( f1 < f2 ? f1 : f2 )) gm=$(( g1 > g2 ? g1 : g2 )) v
  if   [ "$gm" -gt 256 ] || [ "$fm" -lt 1024 ]; then v=SPILLED
  elif [ "$fm" -lt 2048 ]; then v=tight
  else v=fits; fi
  printf '%s %s %s %s %s\n' "$v" "$f1" "$f2" "$g1" "$g2"
}

s2b_split() {
  note ""
  note "## Tensor-split correction (\`c1 = ncmoe + (48-ncmoe)/2 - 1\`)"
  note ""
  note "The documented rule balances by WEIGHT alone, and the resulting imbalance is larger"
  note "than one layer and **grows with \`-ncmoe\`**. Measured, counting GTT as demand that"
  note "did not fit:"
  note ""
  note "| -ncmoe | split | card 1 | card 2 | total | spare of 65536 | imbalance |"
  note "| --- | --- | ---: | ---: | ---: | ---: | ---: |"
  note "| 15 | 31,17 | 34789 | 29506 | 64295 | 1241 | +5283 |"
  note "| 20 | 34,14 | 32046 | 24741 | 56787 | 8749 | +7305 |"
  note "| 28 | 38,10 | 26521 | 18254 | 44775 | 20761 | +8267 |"
  note ""
  note "At ~1500 MiB of expert weight per layer (derived from the 15→20 pair, against the"
  note "~1.56 GB the env file assumes) one moved layer shifts the imbalance by ~2×that, so the"
  note "correction is roughly **−2 layers**. What the weight-only rule misses: the KV cache"
  note "(12 of 48 blocks are full-attention, and card 1 owns more of them), the 1.11 GiB vision"
  note "projector landing on one device, and per-device compute buffers."
  note ""
  note "| -ncmoe | split | shape | d0 t/s | d8000 t/s | VRAM free c1/c2 | GTT c1/c2 | verdict |"
  note "| --- | --- | --- | ---: | ---: | ---: | ---: | --- |"
  # ---- phase 1: headroom for every candidate, load-only (~2 min each)
  note "### Phase 1 — does it fit? (load only)"
  note ""
  note "| -ncmoe | split | shape | VRAM free c1/c2 | GTT c1/c2 | verdict |"
  note "| --- | --- | --- | ---: | ---: | --- |"
  : >"${RUN}/split-candidates.txt"
  local spec lbl nc c1 kv mp res v f1 f2 g1 g2
  for spec in \
      "15 31 - -"   "15 30 - -"   "15 29 - -"   "16 30 - -" \
      "20 32 - -"   "28 36 - -" \
      "15 29 q8_0 true"  "14 29 q8_0 true"  "16 30 q8_0 true"; do
    read -r nc c1 kv mp <<<"$spec"
    [ "$kv" = "-" ] && kv=""; [ "$mp" = "-" ] && mp=""
    lbl="nc${nc}-c${c1}$([ -n "$kv" ] && echo "-q8")$([ "$mp" = true ] && echo "-projcpu")"
    res=$(split_headroom "$lbl" "$nc" "$c1" "$kv" "$mp")
    read -r v f1 f2 g1 g2 <<<"$res"
    note "| ${nc} | ${c1},$(( 48 - c1 )) | ${kv:-f16} / $([ "$mp" = true ] && echo "proj CPU" || echo "proj GPU") | ${f1} / ${f2} | ${g1} / ${g2} | ${v} |"
    echo "$nc $c1 ${kv:--} ${mp:--} $v" >>"${RUN}/split-candidates.txt"
  done
  note ""

  # ---- phase 2: measure ONLY what fits, lowest -ncmoe first (most experts on GPU = fastest)
  note "### Phase 2 — throughput of the shapes that fit"
  note ""
  note "| -ncmoe | split | shape | d0 t/s | d8000 t/s | VRAM free c1/c2 | GTT c1/c2 | verdict |"
  note "| --- | --- | --- | ---: | ---: | ---: | ---: | --- |"
  local n=0
  while read -r nc c1 kv mp v; do
    [ "$v" = "fits" ] || [ "$v" = "tight" ] || continue
    [ "$n" -lt 3 ] || break
    [ "$kv" = "-" ] && kv=""; [ "$mp" = "-" ] && mp=""
    split_cell "split-nc${nc}-c${c1}$([ -n "$kv" ] && echo "-q8")$([ "$mp" = true ] && echo "-projcpu")" \
               "$nc" "$c1" "$kv" "$mp"
    n=$(( n + 1 ))
  done < <(sort -k1,1n "${RUN}/split-candidates.txt")
  # And the documented split at 15 as the control that reproduces the spill, measured so the
  # cost of getting the split wrong is a number rather than an assertion.
  split_cell "split-nc15-c31-documented" 15 31
  note ""
  note "⚠️ Judge these by **headroom**, not tok/s. Below ~1 GiB of free VRAM RADV starts"
  note "spilling to GTT, and a spilled cell can still post a plausible-looking number."

  # Publish the fastest NON-SPILLING placement for every stage after this one.
  python3 - "$RUN" >"${RUN}/best_split.txt" <<'PY'
import glob, json, os, re, statistics as st, sys
run = sys.argv[1]
best = None
for f in glob.glob(os.path.join(run, "split-nc*-c*.json")):
    m = re.match(r"split-nc(\d+)-c(\d+)-", os.path.basename(f))
    if not m:
        continue
    try:
        d = json.load(open(f))
    except Exception:
        continue
    su = d.get("summary", {})
    a = [v["decode_tps_median"] for k, v in su.items()
         if k.startswith("d0/") and v.get("decode_tps_median")]
    if not a or d.get("any_degenerate"):   # never rank a degenerate cell
        continue
    # 🔴 And never rank a SPILLED one. A cell with its KV or weights in GTT can still post
    # a competitive number here, so throughput is not sufficient to pick a winner.
    try:
        verdict = open(f.replace(".json", ".verdict")).read().strip()
    except Exception:
        verdict = "unknown"
    if verdict == "SPILLED":
        continue
    # The shape is part of the answer: q8_0 / projector-on-CPU is what makes the tightest
    # placements fit at all, so it has to travel with the ncmoe/split pair.
    name = os.path.basename(f)
    kv = "q8_0" if "-q8" in name else ""
    mp = "true" if "projcpu" in name else ""
    v = st.median(a)
    if best is None or v > best[4]:
        best = (int(m.group(1)), int(m.group(2)), kv, mp, v)
# Fall back to the incumbent at the corrected split, production shape.
print("%d %d %s %s" % (best[0], best[1], best[2] or "-", best[3] or "-") if best else "20 32 - -")
PY
  echo "best non-spilling placement: $(cat "${RUN}/best_split.txt")"
}
stage splitfix 7200 s2b_split

# ------------------------------------------------- 2c. how much CONTEXT can it hold
# "Versatile" is not only VRAM left for another model — it is also how long a window this
# thing can serve. That is now a computable question rather than a guess:
#
#   48 blocks, `full_attention_interval 4` -> only **12 layers hold a KV cache** (the other
#   36 are Gated DeltaNet, whose state is fixed-size and context-independent).
#   head_count_kv 2, key_length 256, value_length 256
#     => 2 * 12 * 2 * (256 + 256) * 2 B = **24.0 KiB/token at f16**, 12.0 at q8_0
#
#   ctx      f16        q8_0
#   65536    1.50 GiB   0.75 GiB
#   131072   3.00 GiB   1.50 GiB
#   262144   6.00 GiB   3.00 GiB     <- the model's native maximum
#
# ⚠️ Those are metadata estimates. This stage CONFIRMS them with a VRAM delta, which is the
# only trustworthy method: flat VRAM between two context sizes can mean the KV moved to
# host memory, not that it got cheaper — so GTT is read alongside it every time.
ctx_cell() {  # <label> <ncmoe> <c1> <ctx> <kvtype>
  local label="$1" nc="$2" c1="$3" ctx="$4" kv="$5"
  setv MODEL_GPU_LAYERS 99; setv MODEL_EXPECTED_GPUS 2
  setv MODEL_CPU_MOE "$nc"; setv MODEL_TENSOR_SPLIT "${c1},$(( 48 - c1 ))"
  setv MODEL_THREADS 32; setv MODEL_PARALLEL 1; setv MODEL_CONTEXT_LENGTH "$ctx"
  setv MODEL_KV_TYPE "$kv"; setv MODEL_MMPROJ_ON_CPU ""
  setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"; setv MODEL_LOAD_MODE ""
  setv EXTRA_ARGS ""; setv LLAMACPP_DIR /opt/llamacpp/b11018-baseline
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn
  if ! wait_up 1800; then
    note "| ${ctx} | ${kv:-f16} | ${nc} / ${c1},$(( 48 - c1 )) | **DID NOT LOAD** | - | - | - |"
    return 0
  fi
  ./placement-probe.py "http://$(ip):1234" --reps 1 --n-predict 64 --depths 0,8000 \
    --classes code >/dev/null 2>&1 || true
  # A deep probe as well: a long window is pointless if throughput collapses in it. 32k is
  # the deepest that still fits every configuration tested here.
  ./placement-probe.py "http://$(ip):1234" --reps 1 --n-predict 160 --depths 0,8000,32000 \
    >"${RUN}/${label}.json" 2>/dev/null || true
  local A=/sys/bus/pci/devices/0000:03:00.0 B=/sys/bus/pci/devices/0000:83:00.0
  local u1 f1 g1 u2 f2 g2
  u1=$(( $(cat $A/mem_info_vram_used)/1048576 )); g1=$(( $(cat $A/mem_info_gtt_used)/1048576 ))
  f1=$(( ($(cat $A/mem_info_vram_total) - $(cat $A/mem_info_vram_used))/1048576 ))
  u2=$(( $(cat $B/mem_info_vram_used)/1048576 )); g2=$(( $(cat $B/mem_info_gtt_used)/1048576 ))
  f2=$(( ($(cat $B/mem_info_vram_total) - $(cat $B/mem_info_vram_used))/1048576 ))
  echo "$(( u1 + u2 ))" >"${RUN}/${label}.vramtotal"
  python3 - "${RUN}/${label}.json" "$ctx" "${kv:-f16}" "${nc} / ${c1},$(( 48 - c1 ))" \
           "$(( u1 + u2 ))" "$f1" "$f2" "$g1" "$g2" >>"$RESULTS" <<'PY'
import json, statistics as st, sys
_, path, ctx, kv, place, vram, f1, f2, g1, g2 = sys.argv
try: s = json.load(open(path))["summary"]
except Exception:
    print("| %s | %s | %s | probe failed | - | - | - |" % (ctx, kv, place)); raise SystemExit
def med(pre):
    v = [x["decode_tps_median"] for k, x in s.items()
         if k.startswith(pre) and x.get("decode_tps_median")]
    return st.median(v) if v else 0.0
free_min, gtt_max = min(int(f1), int(f2)), max(int(g1), int(g2))
flag = " **SPILLED**" if (gtt_max > 256 or free_min < 1024) else (" tight" if free_min < 2048 else "")
print("| %s | %s | %s | %.2f | %.2f | %.2f | %s MiB, free %s/%s, gtt %s/%s%s |" % (
    ctx, kv, place, med("d0/"), med("d8000/"), med("d32000/"), vram, f1, f2, g1, g2, flag))
PY
}

s2c_context() {
  local NC C1
  if [ -s "${RUN}/best_split.txt" ]; then read -r NC C1 < "${RUN}/best_split.txt"
  else NC=20; C1=33; fi
  note ""
  note "## Context: how long a window, and what it costs"
  note ""
  note "\`full_attention_interval 4\` means only **12 of the 48 blocks hold a KV cache** — the"
  note "other 36 are Gated DeltaNet, whose state is fixed-size and context-independent. With"
  note "\`head_count_kv 2\` and key/value length 256 that is **24.0 KiB/token at f16**:"
  note "1.50 GiB at 65536, 3.00 at 131072, **6.00 at the native 262144** — or half of each at"
  note "\`q8_0\`, which is safe here only because the server runs \`--reasoning off\`."
  note ""
  note "| ctx | KV type | -ncmoe / split | d0 t/s | d8k t/s | d32k t/s | VRAM |"
  note "| --- | --- | --- | ---: | ---: | ---: | --- |"
  # At the fastest placement: double the window, then go for the full native one on q8_0.
  ctx_cell "ctx131072-f16-best"   "$NC" "$C1" 131072 ""
  ctx_cell "ctx262144-q8-best"    "$NC" "$C1" 262144 "q8_0"
  # And the full native window at f16 on a roomier placement, to price the alternative of
  # giving up GPU-resident experts instead of quantising the cache.
  ctx_cell "ctx262144-f16-ncmoe28" 28 37 262144 ""
  note ""
  note "⚠️ Compare against the 65536 rows in the split table above for the delta. A context"
  note "change that leaves VRAM FLAT has not got cheaper — the KV has moved to host memory,"
  note "which is why GTT is printed on every row."
}
stage contextsweep 7200 s2c_context

# ---------------------------------------------------------------- 3. MTP
# 🔴 A PLAIN CHECKOUT OF PR #28097 WOULD BUILD A BINARY THAT CANNOT RUN THIS MODEL.
# #28097 already contains #27836's three commits rebased, so one branch is the right
# shape — but its base is **307 commits behind b11018**, and what it lacks includes
# `35822afe5 vulkan: support qwen4exp hc ops (#28988)`, which is the commit that makes
# qwen4exp's hyper-connection ops work on Vulkan at all. Building the PR as-is produces a
# server that cannot offload this architecture, so the measurement would be meaningless.
# (It also lacks #25483 "skip unneeded MoE work in mul_mm coopmat1" and #28996, both
# directly relevant to a Vulkan MoE.)
#
# So the four MTP commits are REBASED ONTO b11018 instead, as branch `mtp-b11018` on the
# builder, with the conflict resolution saved under mtp-patches/. Two files conflicted
# because b11018 moved on underneath the PR:
#   * n_ff_exp became a per-layer array (n_ff_exp_arr + an n_ff_exp(il) accessor)
#   * every hc_*_norm / ple_norm_* / hc_head_norm gamma was reshaped from {hc_dim} to
#     {n_embd, hc} with TENSOR_ALLOW_RESHAPE, so the grouped norm needs no graph reshape
#   * b11018's PLE row-count block became a strict superset of the PR's, so only the PR's
#     `!mtp_only` guard was taken from it
# Resolution rule throughout: keep b11018's shapes and logic, OR in the PR's flags.
#
# A no-speculation control still runs ON THE SAME BINARY — comparing two speculative
# configs measures agreement, not correctness — and it doubles as a check that the rebase
# did not change anything: it should land on top of b11018-baseline.
MTPDIR=/opt/llamacpp/mtp-b11018
DRAFT_PLAIN="${MODELDIR}/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf"
DRAFT_SHARED="${MODELDIR}/mtp-Qwen3.8-Flash-Next-shared-Q4_K_M.gguf"

mtp_set_placement() {  # <ncmoe> [c1] [kv] [mmproj_on_cpu]
  # c1 defaults to the CORRECTED rule (documented minus two layers -- see the split stage).
  local nc="$1" c1="${2:-$(( $1 + (48 - $1) / 2 - 2 ))}" kv="${3:-}" mp="${4:-}"
  setv MODEL_CPU_MOE "$nc"; setv MODEL_TENSOR_SPLIT "${c1},$(( 48 - c1 ))"
  setv MODEL_THREADS 32; setv MODEL_PARALLEL 1; setv MODEL_GPU_LAYERS 99
  setv MODEL_EXPECTED_GPUS 2; setv MODEL_KV_TYPE "$kv"; setv MODEL_MMPROJ_ON_CPU "$mp"
  setv MODEL_OT_OVERRIDE "per_layer_token_embd=CPU"; setv MODEL_LOAD_MODE ""
}

# Measure one arm. Writes its JSON and echoes "<d0> <accept>" or "DIED".
mtp_cell() {  # <label> <extra-args> [reps]
  local label="$1" extra="$2" reps="${3:-2}"
  setv EXTRA_ARGS "$extra" >&2
  pct exec "$CT" -- systemctl restart llamacpp-qwen38fn >&2
  # ⚠️ stdout of this function IS its return value (it is read with $(...)), so wait_up's
  # progress line has to go to stderr or "$r" starts with whitespace and every parse of it
  # silently yields the empty string.
  if ! wait_up 1500 >&2; then echo "DIED"; return 0; fi
  ./placement-probe.py "http://$(ip):1234" --reps 1 --n-predict 64 --depths 0,8000 \
    --classes code >/dev/null 2>&1 || true
  ./placement-probe.py "http://$(ip):1234" --reps "$reps" --n-predict 160 --depths 0,8000 \
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
  # Prefer stage 2b's winner: the fastest placement VERIFIED not to be spilling to GTT.
  # best_ncmoe() ranks the re-validation data, which was taken before the spill was found,
  # so at the VRAM-hungry end it can rank a broken cell first.
  local NC C1 KV MP
  if [ -s "${RUN}/best_split.txt" ]; then
    read -r NC C1 KV MP < "${RUN}/best_split.txt"
    [ "$KV" = "-" ] && KV=""; [ "$MP" = "-" ] && MP=""
    echo "placement from the split stage: -ncmoe ${NC}, split ${C1},$(( 48 - C1 )), KV ${KV:-f16}, projector $([ "$MP" = true ] && echo CPU || echo GPU)"
  else
    NC=$(best_ncmoe); C1=$(( NC + (48 - NC) / 2 - 2 )); KV=""; MP=""
    echo "no split-stage result; falling back to -ncmoe ${NC} at the corrected split ${C1}"
  fi
  echo "$NC" >"${RUN}/best_ncmoe.txt"
  echo "$C1" >"${RUN}/best_c1.txt"
  printf '%s %s\n' "${KV:--}" "${MP:--}" >"${RUN}/best_shape.txt"

  pct start "$BUILDER" >/dev/null 2>&1 || true; sleep 15
  pct exec "$BUILDER" -- bash -s <<'BUILD'
set -Eeuo pipefail
cd /root/llama.cpp

# The rebase was done and syntax-checked ahead of time (see mtp-patches/). Do NOT re-create
# it here: a fresh `git checkout pr-28097` would silently discard it and build a binary
# that cannot offload qwen4exp to Vulkan.
git rev-parse --verify mtp-b11018 >/dev/null 2>&1 || {
  echo "🔴 branch mtp-b11018 is missing — re-apply mtp-patches/*.patch onto b11018"; exit 5; }
git checkout --quiet --force mtp-b11018
git clean -qfd
# Assert the shape rather than trusting the branch name: exactly 4 commits on top of
# b11018, and b11018 itself an ancestor.
n=$(git rev-list --count b11018..mtp-b11018)
[ "$n" = 4 ] || { echo "🔴 mtp-b11018 has $n commits over b11018, expected 4"; exit 5; }
git merge-base --is-ancestor b11018 mtp-b11018 || { echo "🔴 b11018 is not an ancestor"; exit 5; }
git log --oneline -4

rm -rf build
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON -DGGML_NATIVE=ON \
  -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF >/dev/null
cmake --build build -j "$(nproc)" 2>&1 | tail -3
d=/root/builds/mtp-b11018; rm -rf "$d"; mkdir -p "$d"
find build/bin -maxdepth 1 -type f -exec cp {} "$d/" \; 2>/dev/null || true
find build -name "*.so*" -exec cp -P {} "$d/" \; 2>/dev/null || true
chmod +x "$d"/llama-* 2>/dev/null || true
# Two loud checks: the new flag exists, and the Vulkan backend the whole rebase was for is
# actually in the binary.
"$d/llama-server" --help 2>&1 | grep -q 'draft-mtp' \
  || { echo "🔴 draft-mtp ABSENT from the built server"; exit 4; }
ls "$d" | grep -q 'ggml-vulkan' \
  || { echo "🔴 no ggml-vulkan in the build output"; exit 4; }
echo "OK: --spec-type draft-mtp present, Vulkan backend present"
BUILD
  local brc=$?
  if [ "$brc" -ne 0 ]; then
    note ""; note "## MTP — NOT TESTED"; note ""
    note "🔴 The build failed (rc=${brc})."
    note ""
    note "\`--spec-type draft-mtp\` for \`qwen4exp\` comes from llama.cpp PR **#28097** (which"
    note "already contains #27836's commits rebased). Both are still **open**, and #28097's base"
    note "is **307 commits behind b11018** — critically it predates"
    note "\`vulkan: support qwen4exp hc ops\` (#28988), so the PR as published cannot run this"
    note "architecture on Vulkan at all. The four commits were therefore rebased onto b11018 by"
    note "hand (resolution saved as \`mtp-patches/*.patch\`) and that rebase passed a"
    note "syntax check, so a failure here is a **build or runtime** problem, not a merge one."
    note "The 4.70 GB of drafters are downloaded and waiting at \`${MODELDIR}/mtp-*.gguf\`."
    pct stop "$BUILDER" >/dev/null 2>&1 || true
    return 3
  fi
  pct exec "$BUILDER" -- bash -lc "cd /root/builds && tar czf /root/mtp.tgz pr28097-mtp"
  pct pull "$BUILDER" /root/mtp.tgz /tmp/mtp.tgz
  pct push "$CT" /tmp/mtp.tgz /tmp/mtp.tgz
  pct exec "$CT" -- bash -lc "tar xzf /tmp/mtp.tgz -C /opt/llamacpp/ && rm -f /tmp/mtp.tgz"
  rm -f /tmp/mtp.tgz; pct stop "$BUILDER" >/dev/null 2>&1 || true

  mtp_set_placement "$NC" "$C1" "$KV" "$MP"
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
    r=$(mtp_cell "mtp-${tag}-nmax3" "--spec-type draft-mtp --model-draft ${path} --spec-draft-n-max 3 --spec-draft-ngl 99" 1)
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
  # The CORRECTED split and the winning SHAPE, read back from the split stage when it ran.
  local c1; c1=$(cat "${RUN}/best_c1.txt" 2>/dev/null || echo $(( NC + (48 - NC) / 2 - 2 )))
  local BKV="" BMP=""
  if [ -s "${RUN}/best_shape.txt" ]; then
    read -r BKV BMP < "${RUN}/best_shape.txt"
    [ "$BKV" = "-" ] && BKV=""; [ "$BMP" = "-" ] && BMP=""
  fi
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
    setv MODEL_KV_TYPE "$BKV"; setv MODEL_MMPROJ_ON_CPU "$BMP"
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
  # The CORRECTED split and the winning SHAPE, read back from the split stage when it ran.
  local c1; c1=$(cat "${RUN}/best_c1.txt" 2>/dev/null || echo $(( NC + (48 - NC) / 2 - 2 )))
  local BKV="" BMP=""
  if [ -s "${RUN}/best_shape.txt" ]; then
    read -r BKV BMP < "${RUN}/best_shape.txt"
    [ "$BKV" = "-" ] && BKV=""; [ "$BMP" = "-" ] && BMP=""
  fi
  setv MODEL_CPU_MOE "$NC"; setv MODEL_TENSOR_SPLIT "${c1},$(( 48 - c1 ))"
  setv MODEL_THREADS 32; setv MODEL_PARALLEL 1; setv MODEL_GPU_LAYERS 99
  setv MODEL_EXPECTED_GPUS 2; setv EXTRA_ARGS ""; setv MODEL_KV_TYPE "$BKV"
  setv MODEL_MMPROJ_ON_CPU "$BMP"; setv MODEL_LOAD_MODE ""
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
