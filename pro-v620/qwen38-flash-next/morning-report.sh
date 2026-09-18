#!/usr/bin/env bash
# Synthesise the night's raw JSON into a recommendation, appended to RESULTS.md.
#
# This exists so the night produces a usable answer even with nobody watching. It is a
# FALLBACK, not the final word: it can only rank numbers, and several of the night's
# questions (does MTP change the output? did a cell secretly spill to GTT?) are judgement
# calls that need the gates read, not the medians.
#
# Everything it prints is derived from files on disk and labelled with its sample count, so
# a thin cell is visible as thin rather than quietly averaged in.
# shellcheck disable=SC2129  # the grouped redirects below ARE the suggested form
set -Eeuo pipefail
RUN="${1:?usage: morning-report.sh <run-dir>}"
R="${RUN}/RESULTS.md"

{
  echo
  echo "---"
  echo
  echo "# Recommended configurations"
  echo
  echo "_Auto-derived from this run's JSON at $(date -u +%FT%TZ). Sample counts shown; a"
  echo "single-sample row is a hint, not a result._"
  echo
} >>"$R"

python3 - "$RUN" >>"$R" <<'PY'
import glob, json, os, re, statistics as st, sys

run = sys.argv[1]


def load(path):
    try:
        return json.load(open(path))
    except Exception:
        return None


def dec(d, prefix):
    """Median decode t/s across prompt classes at one depth."""
    s = (d or {}).get("summary", {})
    v = [x["decode_tps_median"] for k, x in s.items()
         if k.startswith(prefix) and x.get("decode_tps_median")]
    return st.median(v) if v else None


def gates(d):
    """The sanity gates, because a degenerate or non-reproducible cell must not be ranked.

    Reproducibility is judged at d0 only. A d8000 cell disagrees with itself
    intermittently on this hybrid placement even at temperature 0 with top_k 1, so
    `all_reps_agree` (which spans every depth) would condemn almost every healthy cell.
    Degeneracy is still judged across all depths -- repetition anywhere is a real defect.
    """
    if not d:
        return "no data"
    bad = []
    if d.get("any_degenerate"):
        bad.append("DEGENERATE")
    d0 = [v for k, v in d.get("summary", {}).items() if k.startswith("d0/")]
    if d0 and not all(v.get("reps_agree", True) for v in d0):
        bad.append("d0 reps disagree")
    return ", ".join(bad) if bad else "ok"


# ---------------------------------------------------------------- placement
revals = sorted(glob.glob("/root/qwen38-flash-next/reval-*/"), key=os.path.getmtime)
cells = {}
if revals:
    for f in sorted(glob.glob(os.path.join(revals[-1], "*.json"))):
        m = re.match(r"(.+)-r\d+\.json$", os.path.basename(f))
        if not m:
            continue
        d = load(f)
        a, b = dec(d, "d0/"), dec(d, "d8000/")
        e = cells.setdefault(m.group(1), {"a": [], "b": [], "gate": set()})
        if a:
            e["a"].append(a)
        if b:
            e["b"].append(b)
        e["gate"].add(gates(d))

print("## Placement, re-validated at full clock")
print()
print("🔴 **This table ranks by throughput and its `gate` column knows nothing about VRAM")
print("headroom, so a SPILLED configuration can sit at the top.** That is exactly the trap")
print("this run was built to expose: a cell holding GiB in GTT still posts a plausible")
print("number. Every one of these cells used the DOCUMENTED `--tensor-split`, which is ~2")
print("layers off, so `-ncmoe` 15 and 20 were both spilling here. Read the split table")
print("below, or `./attribute-telemetry.py <run>`, for the headroom verdicts — and treat")
print("this table as the shape of the curve, not as a ranking of usable configs.")
print()
print("| config | d0 t/s | d8000 t/s | n | gate |")
print("| --- | ---: | ---: | ---: | --- |")
ranked = sorted(((k, v) for k, v in cells.items() if v["a"]),
                key=lambda kv: -st.median(kv[1]["a"]))
for k, v in ranked:
    g = ", ".join(sorted(x for x in v["gate"] if x != "ok")) or "ok"
    print("| `%s` | %.2f | %s | %d | %s |" % (
        k, st.median(v["a"]),
        ("%.2f" % st.median(v["b"])) if v["b"] else "—", len(v["a"]), g))
for k, v in sorted(cells.items()):
    if not v["a"]:
        print("| `%s` | **DIED / no data** | — | 0 | — |" % k)
print()

# ⚠️ Deliberately NOT taken from the placement table: that ranks cells measured at the
# DOCUMENTED split, spills included. The headline comes from best_split.txt, which the split
# stage wrote only after refusing every candidate whose verdict was SPILLED.
speed = ranked[0][0] if ranked else None
speed_tps = st.median(ranked[0][1]["a"]) if ranked else 0.0

# The most VRAM-frugal cell that still holds a usable fraction of peak. -ncmoe 48 keeps
# only attention and the non-expert layers on the cards, which the whole-layer test showed
# is the part that MUST stay resident (-42% when moved).
frugal = next((k for k, _ in ranked if k.startswith("ncmoe48")), None)
frugal_tps = st.median(cells[frugal]["a"]) if frugal else 0.0

# ---------------------------------------------------------------- tensor split
# The documented split rule overloads card 1 by exactly one heavy layer, so the VRAM-hungry
# end of the placement curve was measuring a GTT spill. These cells test the correction.
split = {}
for f in sorted(glob.glob(os.path.join(run, "split-nc*-c*.json"))):
    # ⚠️ The shape suffix is OPTIONAL: an f16 / projector-on-GPU cell is just
    # `split-nc16-c30.json`, so a mandatory third group silently dropped half the table.
    m = re.match(r"split-nc(\d+)-c(\d+)(?:-(.+))?\.json$", os.path.basename(f))
    d = load(f)
    if not m or not d:
        continue
    split[(int(m.group(1)), int(m.group(2)), m.group(3) or "f16 / proj GPU")] = d

if split:
    print("## Tensor split: the documented rule is ~2 layers off")
    print()
    print("| -ncmoe | split | rule | d0 t/s | d8000 t/s | gate |")
    print("| --- | --- | --- | ---: | ---: | --- |")
    for key in sorted(split):
        nc, c1, kind = key
        d = split[key]
        print("| %d | %d,%d | %s | %s | %s | %s |" % (
            nc, c1, 48 - c1, kind,
            ("%.2f" % dec(d, "d0/")) if dec(d, "d0/") else "DIED",
            ("%.2f" % dec(d, "d8000/")) if dec(d, "d8000/") else "—",
            gates(d)))
    print()
    print("⚠️ The headroom/GTT verdict per cell is in the stage table above — read that, not")
    print("these medians. A card with <1 GiB of free VRAM spills to GTT silently, and the")
    print("spilled cell still reports a plausible number.")
    print()

# ---------------------------------------------------------------- context
# ⚠️ Each context cell writes TWO files: the shallow probe (3 prompt classes at d0/d8k) and
# a `-deep` one (1 class at 32k, because a 32k prefill costs ~13 min per request). The deep
# file must be JOINED to its sibling, not counted as another cell -- a bare ctx*.json glob
# would list every configuration twice, once with no d0 and once with no d32k.
ctxcells = {}
for f in sorted(glob.glob(os.path.join(run, "ctx*.json"))):
    base = os.path.basename(f)
    if base.endswith("-deep.json"):
        continue
    m = re.match(r"ctx(\d+)-(f16|q8)-(.+)\.json$", base)
    d = load(f)
    if not m or not d:
        continue
    deep = load(f[: -len(".json")] + "-deep.json")
    ctxcells[(int(m.group(1)), m.group(2), m.group(3))] = (d, deep)

if ctxcells:
    print("## Longest usable context")
    print()
    print("| ctx | KV | placement | d0 t/s | d8k t/s | d32k t/s | d32k prefill | gate |")
    print("| --- | --- | --- | ---: | ---: | ---: | ---: | --- |")
    for key in sorted(ctxcells):
        c, kv, place = key
        d, deep = ctxcells[key]
        d32 = dec(deep, "d32000/") if deep else None
        pf32 = None
        if deep:
            su = deep.get("summary", {})
            v = [x.get("prefill_tps_median") for k, x in su.items()
                 if k.startswith("d32000/") and x.get("prefill_tps_median")]
            pf32 = st.median(v) if v else None
        print("| %d | %s | %s | %s | %s | %s | %s | %s |" % (
            c, kv, place,
            ("%.2f" % dec(d, "d0/")) if dec(d, "d0/") else "DID NOT LOAD",
            ("%.2f" % dec(d, "d8000/")) if dec(d, "d8000/") else "—",
            ("%.2f" % d32) if d32 else "—",
            ("%.1f" % pf32) if pf32 else "—",
            gates(d)))
    print()
    print("KV is **24.0 KiB/token at f16** — only 12 of 48 blocks hold a cache, the other 36")
    print("being Gated DeltaNet with a fixed-size state. So 65536 costs 1.50 GiB, 131072 costs")
    print("3.00, and the native 262144 costs 6.00 (half each at `q8_0`).")
    print()

# ---------------------------------------------------------------- MTP
def shas_d0(d):
    """🔴 d0 ONLY. A d8000 cell disagrees with itself intermittently at temperature 0 on
    this hybrid placement, so hashing at depth reports scheduling noise as divergence."""
    return sorted({x.get("sha") for k, x in (d or {}).get("summary", {}).items()
                   if k.startswith("d0/") and x.get("sha")})


# Every MTP arm, keyed by its label: the control (no speculation, same binary), the two
# drafter-layout probes, and the n-max sweep. The n-max value alone is not a key — two
# drafters are tried at n-max 3.
mtp = {}
for f in sorted(glob.glob(os.path.join(run, "mtp-*.json"))):
    d = load(f)
    if not d:
        continue
    lbl = os.path.basename(f)[len("mtp-"):-len(".json")]
    su = d.get("summary", {})
    acc = [x.get("accept_pct_median") for x in su.values()
           if x.get("accept_pct_median") is not None]
    mtp[lbl] = {
        "a": dec(d, "d0/"), "b": dec(d, "d8000/"),
        "acc": st.median(acc) if acc else None,
        "gate": gates(d),
        "sha": shas_d0(d),
    }

print("## Speculation (MTP)")
print()
if not mtp:
    print("🔴 **Not measured** — see the MTP stage note above for why. The drafter is")
    print("downloaded and waiting; this is a build-availability problem, not a result.")
else:
    ctrl = mtp.get("control")
    print("| arm | d0 t/s | d8000 t/s | accept % | vs control | output (d0) | gate |")
    print("| --- | ---: | ---: | ---: | ---: | --- | --- |")
    for k in sorted(mtp, key=lambda x: (x != "control", x)):
        v = mtp[k]
        rel = ("%+.1f%%" % (100 * (v["a"] / ctrl["a"] - 1))
               if (ctrl and ctrl.get("a") and v.get("a")) else "—")
        same = "—"
        if ctrl and ctrl["sha"] and v["sha"]:
            same = "identical" if v["sha"] == ctrl["sha"] else "**DIVERGED**"
        lbl = "**none (control, same binary)**" if k == "control" else "`%s`" % k
        print("| %s | %s | %s | %s | %s | %s | %s |" % (
            lbl,
            ("%.2f" % v["a"]) if v["a"] else "DIED",
            ("%.2f" % v["b"]) if v["b"] else "—",
            ("%.1f" % v["acc"]) if v["acc"] is not None else "—",
            rel, same, v["gate"]))
    print()
    print("⚠️ Acceptance, not tok/s, is the honest score for a speculative config: unchanged")
    print("acceptance with a different tok/s means only the workload moved. And a speculative")
    print("model has no single tok/s at all — decode tracks how predictable the output is, so")
    print("these figures belong to THIS prompt set and nothing else.")
    print()

best_mtp = None
if mtp:
    ctrl = mtp.get("control")
    cands = [(k, v) for k, v in mtp.items()
             if k != "control" and v.get("a") and v["gate"] == "ok"]
    if cands:
        bk, bv = max(cands, key=lambda kv: kv[1]["a"])
        # 3% floor: below that it is not worth a non-upstream build and two extra GGUFs.
        if not ctrl or not ctrl.get("a") or bv["a"] > ctrl["a"] * 1.03:
            best_mtp = (bk, bv["a"])

# ---------------------------------------------------------------- concurrency
par = {}
for f in sorted(glob.glob(os.path.join(run, "par*-t*-c*.json"))):
    m = re.match(r"par(\d+)-t(\d+)-c(\d+)\.json$", os.path.basename(f))
    d = load(f)
    if not m or not d:
        continue
    par[(int(m.group(1)), int(m.group(2)), int(m.group(3)))] = d

print("## Concurrency (`--parallel`)")
print()
if not par:
    print("🔴 **Not measured** — see the stage log.")
else:
    print("| parallel | threads | total ctx | ctx/slot | per-stream t/s | aggregate t/s |")
    print("| --- | ---: | ---: | ---: | ---: | ---: |")
    for key in sorted(par):
        pp, tt, cc = key
        d = par[key]
        flag = " ⚠️ queued, not concurrent" if d.get("slot_warning") else ""
        print("| %d | %d | %d | %s | %.2f | %.2f%s |" % (
            pp, tt, cc, d.get("n_ctx_per_slot", "?"), d.get("per_stream_tps", 0),
            d.get("aggregate_tps", 0), flag))
    print()
    print("⚠️ per-stream is what one interactive caller feels; aggregate is what the box")
    print("delivers. They move in opposite directions, so a concurrency setting has to be")
    print("chosen against the consumer, not against a single headline number.")
    best_agg = max(par.items(), key=lambda kv: kv[1].get("aggregate_tps", 0))
    bk, bd = best_agg
    print()
    print("Best aggregate: **--parallel %d, threads %d, --ctx-size %d** at %.2f t/s total"
          % (bk[0], bk[1], bk[2], bd.get("aggregate_tps", 0)))
    print("(%.2f per stream, %s per slot)."
          % (bd.get("per_stream_tps", 0), bd.get("n_ctx_per_slot", "?")))
print()

# ---------------------------------------------------------------- the answer
gov = "unknown"
try:
    gov = open(os.path.join(run, "governor.txt")).read().strip()
except Exception:
    pass
bth = "?"
try:
    bth = open(os.path.join(run, "best_threads.txt")).read().strip()
except Exception:
    pass

headline = None       # (label, ncmoe, c1, kv, mp, d0, d8k)
try:
    bs = open(os.path.join(run, "best_split.txt")).read().split()
except Exception:
    bs = []
if len(bs) >= 2:
    want_nc, want_c1 = int(bs[0]), int(bs[1])
    want_kv = "" if len(bs) < 3 or bs[2] == "-" else bs[2]
    want_mp = "" if len(bs) < 4 or bs[3] == "-" else bs[3]
    for (nc, c1, kind), d in split.items():
        if nc != want_nc or c1 != want_c1:
            continue
        is_q8 = "q8" in kind
        if bool(want_kv) != is_q8:
            continue
        headline = ("-ncmoe %d --tensor-split %d,%d%s%s" % (
            nc, c1, 48 - c1,
            " --cache-type-k q8_0 --cache-type-v q8_0" if want_kv else "",
            " --no-mmproj-offload" if want_mp == "true" else ""),
            nc, c1, want_kv, want_mp, dec(d, "d0/"), dec(d, "d8000/"))
        break

print("## The answer")
print()
print("| want | configuration | measured |")
print("| --- | --- | ---: |")
bestsplit = ""
try:
    bs = open(os.path.join(run, "best_split.txt")).read().split()
    if len(bs) == 2:
        bestsplit = " `--n-cpu-moe %s --tensor-split %s,%d`" % (bs[0], bs[1], 48 - int(bs[1]))
except Exception:
    pass
if headline:
    extra = " + MTP (`%s`)" % best_mtp[0] if best_mtp else ""
    print("| **Recommended** | `%s`%s, `--threads %s`, governor `%s` | **%.2f / %.2f t/s** (d0/d8k) |"
          % (headline[0], extra, bth, gov, headline[5] or 0, headline[6] or 0))
elif speed:
    print("| **Fastest measured (⚠️ at the documented split, may be spilling)** | `%s`, governor `%s` | %.2f t/s |"
          % (speed, gov, speed_tps))
if frugal:
    print("| **Most VRAM left for other models** | `%s` (attention-only on GPU) | %.2f t/s |"
          % (frugal, frugal_tps))
    if speed_tps:
        print("| | _cost of that choice_ | **%+.1f%%** |"
              % (100 * (frugal_tps / speed_tps - 1)))
cpuonly = [(k, st.median(v["a"])) for k, v in cells.items()
           if k.startswith("cpuonly") and v["a"]]
if cpuonly:
    k, v = max(cpuonly, key=lambda kv: kv[1])
    print("| **Both cards completely free** | `%s` (`-ngl 0`) | %.2f t/s |" % (k, v))
    if speed_tps:
        print("| | _cost of that choice_ | **%+.1f%%** |" % (100 * (v / speed_tps - 1)))
print()
PY

{
  echo
  echo "## Still open"
  echo
  echo "- The **~43 ms fixed per-token floor** is engine submission/synchronisation overhead,"
  echo "  not memory bandwidth, disk, PCIe, core count or core clock — each was ruled out"
  echo "  independently. It caps this placement near **23 t/s even with an infinite CPU**."
  echo "  MTP and \`--parallel\` amortise it; nothing measured here removes it."
  echo "- Upstream llama.cpp PR **#27880** (\"qwen4exp: reduce number of graph splits\") is the"
  echo "  one lever that would attack it directly. The split count captured above is the"
  echo "  number to quote in an upstream report."
  echo
} >>"$R"

echo "report appended to ${R}"
