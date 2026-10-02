#!/usr/bin/env python3
"""Markdown tables from run-coder.sh's agent sessions.

    summarize-coder.py <results.jsonl>

Turns are grouped by the depth they start at. Prefill is read turns (a ~4k-token file read
at that depth); decode is write turns (the long answers) and read turns separately. Each
cell is the median over repetitions of that repetition's median, with the min-max range.
Session time is the sum of the server's own prompt and decode time over the whole session.
"""
import collections
import json
import statistics as st
import sys

BANDS = [(0, 32000, "0–32k"), (32000, 64000, "32–64k"), (64000, 96000, "64–96k"), (96000, 10**9, "96–128k")]


def band(depth):
    return next(label for lo, hi, label in BANDS if lo <= depth < hi)


def fmt(vals, d=1):
    if not vals:
        return "—"
    m = st.median(vals)
    return f"{m:.{d}f} [{min(vals):.{d}f}–{max(vals):.{d}f}]" if len(vals) > 1 else f"{m:.{d}f}"


def main():
    rows = [json.loads(l) for l in open(sys.argv[1])]
    arms = list(dict.fromkeys(r["arm"] for r in rows))
    by = collections.defaultdict(list)
    for r in rows:
        by[(r["arm"], r["rep"])].append(r)

    def per_rep(arm, pick, value):
        out = []
        for (a, _), rs in by.items():
            if a != arm:
                continue
            vals = [value(r) for r in rs if pick(r) and value(r)]
            if vals:
                out.append(st.median(vals))
        return out

    def table(title, pick_kind, value):
        print(f"\n{title}\n\n| Depth | " + " | ".join(arms) + " |\n| --- |" + " ---: |" * len(arms))
        for _, _, label in BANDS:
            cells = [fmt(per_rep(arm, lambda r: r["kind"] == pick_kind and band(r["depth_before"]) == label, value))
                     for arm in arms]
            print(f"| {label} | " + " | ".join(cells) + " |")

    table("Prefill of a ~4k-token file read, tok/s", "read", lambda r: r["prompt_tps"] if r["prompt_n"] > 1000 else None)
    table("Decode of a code-writing answer, tok/s", "write", lambda r: r["decode_tps"] if (r["predicted_n"] or 0) > 100 else None)
    table("Decode of a short read answer, tok/s", "read", lambda r: r["decode_tps"] if (r["predicted_n"] or 0) > 8 else None)

    print("\nWhole session\n\n| Arm | Session time, min | Turns | Prompt tokens | Generated | Draft acceptance |")
    print("| --- | ---: | ---: | ---: | ---: | ---: |")
    for arm in arms:
        reps = [rs for (a, _), rs in by.items() if a == arm]
        mins = [sum((r["prompt_ms"] or 0) + (r["predicted_ms"] or 0) for r in rs) / 60000 for rs in reps]
        turns = st.median(len(rs) for rs in reps)
        ptok = st.median(sum(r["prompt_n"] for r in rs) for rs in reps)
        gtok = st.median(sum(r["predicted_n"] or 0 for r in rs) for rs in reps)
        dn = sum(r["draft_n"] or 0 for rs in reps for r in rs)
        da = sum(r["draft_accepted"] or 0 for rs in reps for r in rs)
        acc = f"{100 * da / dn:.1f}%" if dn else "—"
        print(f"| {arm} | {fmt(mins)} | {turns:.0f} | {ptok:,.0f} | {gtok:,.0f} | {acc} |")

    print("\nCorrectness\n")
    for arm in arms:
        reps = sorted((rep, rs) for (a, rep), rs in by.items() if a == arm)
        same = sum(len({next((r["content_sha"] for r in rs if r["turn"] == t), None) for _, rs in reps}) == 1
                   for t in {r["turn"] for _, rs in reps for r in rs})
        total = len({r["turn"] for _, rs in reps for r in rs})
        stops = sum(r["finish"] == "stop" for _, rs in reps for r in rs)
        n = sum(len(rs) for _, rs in reps)
        print(f"- {arm}: greedy text identical across repetitions on {same}/{total} turns; "
              f"{stops}/{n} turns stopped on their own")
    backends = sorted({a.split("/")[0] for a in arms})
    if len(backends) == 2:
        for kind in sorted({a.split("/", 1)[1] for a in arms}):
            x = {r["turn"]: r["content_sha"] for r in rows if r["arm"] == f"{backends[0]}/{kind}" and r["rep"] == 1}
            y = {r["turn"]: r["content_sha"] for r in rows if r["arm"] == f"{backends[1]}/{kind}" and r["rep"] == 1}
            common = set(x) & set(y)
            print(f"- {kind}: {backends[0]} and {backends[1]} wrote identical text on "
                  f"{sum(x[t] == y[t] for t in common)}/{len(common)} turns (rep 1)")


if __name__ == "__main__":
    main()
