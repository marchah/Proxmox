#!/usr/bin/env python3
"""Sum up a strata-community-bench.sh run: Strata's report table per cell, over every load.

  strata-bench-summary.py OUT_DIR

OUT_DIR/<cell>-r<pass>/ holds one load: the results folder tools/strata_bench.py wrote
(<date>-community-.../results.json) and, on the first pass, needles.json from
tools/needle_bench.py. Per cell it prints:
- the table of Strata's report template (docs/COMMUNITY_BENCHMARKS.md), pooled over every
  request of every load: median and the lowest and highest request;
- each load's medians, so the spread between engine starts shows;
- the agent session's conversation-cache numbers, the MTP draft acceptance of the short chats,
  the needles, and every failed or skipped test.
"""
import json
import pathlib
import re
import statistics
import sys


def stat(values):
    v = [x for x in values if isinstance(x, (int, float))]
    return {"median": statistics.median(v), "min": min(v), "max": max(v), "n": len(v)} if v else None


def fmt(s, digits=1, unit=""):
    if not s:
        return "not measured"
    return "%.*f%s (%.*f-%.*f)" % (digits, s["median"], unit, digits, s["min"], digits, s["max"])


def med(s, digits=1):
    return "%.*f" % (digits, s["median"]) if s else "—"


def loads(out_dir):
    """{cell: [(pass, the suite's results, needles)]}, passes in order; a load with no results.json is left
    out."""
    cells = {}
    for d in sorted(pathlib.Path(out_dir).iterdir()):
        m = re.fullmatch(r"(.+)-r(\d+)", d.name)
        if not (d.is_dir() and m):
            continue
        found = sorted(d.glob("*/results.json"))
        if not found:
            continue
        needles = d / "needles.json"
        cells.setdefault(m.group(1), []).append((int(m.group(2)), json.loads(found[0].read_text())["results"],
                                                 json.loads(needles.read_text()) if needles.exists() else None))
    for v in cells.values():
        v.sort(key=lambda x: x[0])
    return cells


def ok(rows):
    return [r for r in rows if r.get("ok")]


def follow_turns(results):
    return [d for s in results["agent"].get("sessions") or [] for d in s if d.get("ok") and d.get("turn", 0) > 0]


def acceptance(rows):
    return [100.0 * r["drafts_accepted"] / r["drafts_offered"] for r in rows
            if r.get("drafts_offered") and r.get("drafts_accepted") is not None]


def cell_report(cell, runs):
    res = [r for _, r, _ in runs]
    chat = [d for r in res for d in ok(r["chat"].get("requests") or [])]
    labels = list(dict.fromkeys(k for r in res for k in r["prompts"]))
    turns = [d for r in res for d in follow_turns(r)]
    sessions = [s for r in res for s in r["agent"].get("sessions") or []]
    L = ["## `%s`: %d loads" % (cell, len(runs)), "",
         "| Configuration | Actual prompt tokens | Reused tokens | Generated tokens | Runs | Prompt tok/s median and range "
         "| Decode tok/s median and range | TTFT seconds median and range |",
         "| --- | ---: | ---: | ---: | ---: | --- | --- | --- |"]
    if chat:
        L.append("| short chat | %s | 0 | %s | %d | not measured | %s | %s |" % (
            fmt(stat(d["prompt_tokens"] for d in chat), 0), fmt(stat(d["generated_tokens"] for d in chat), 0), len(chat),
            fmt(stat(d["decode_tps"] for d in chat)), fmt(stat(d["ttft_s"] for d in chat), 2)))
    for k in labels:
        rows = [d for r in res for d in ok((r["prompts"].get(k) or {}).get("requests") or [])]
        L.append("| %s prompt, fresh | %s | %s | 24 cap | %d | %s | not measured | %s |" % (
            k, fmt(stat(d["prompt_tokens"] for d in rows), 0), fmt(stat(d["reused_tokens"] or 0 for d in rows), 0), len(rows),
            fmt(stat(d["prompt_tps"] for d in rows)), fmt(stat(d["ttft_s"] for d in rows), 2)))
    if turns:
        last = [[d for d in s if d.get("ok")][-1]["prompt_tokens"] for s in sessions if len([d for d in s if d.get("ok")]) > 1]
        L.append("| agent session, follow-up turns | %s at the last turn | see below | up to 64 | %d | see below | %s | %s |" % (
            fmt(stat(last), 0), len(turns), fmt(stat(d["decode_tps"] for d in turns)), fmt(stat(d["ttft_s"] for d in turns), 2)))
    L += ["", "Pooled over every request of the %d loads; ranges are the lowest and highest request." % len(runs), "",
          "Per load, the medians of its requests:", "",
          "| Load | Chat decode tok/s | Chat MTP acceptance %% | %s | Agent cache hit %% | Agent turn TTFT s |"
          % " | ".join("%s prompt tok/s" % k for k in labels),
          "| --- | ---: | ---: | %s---: | ---: |" % ("---: | " * len(labels))]
    for p, r, _ in runs:
        c = ok(r["chat"].get("requests") or [])
        L.append("| r%d | %s | %s | %s | %s | %s |" % (
            p, med(stat(d["decode_tps"] for d in c)), med(stat(acceptance(c))),
            " | ".join(med(stat(d["prompt_tps"] for d in ok((r["prompts"].get(k) or {}).get("requests") or []))) for k in labels),
            med(r["agent"].get("hit_pct")), med(stat(d["ttft_s"] for d in follow_turns(r)), 2)))
    hits = [x for r in res for x in [r["agent"].get("hit_pct")] if x]
    if hits:
        L += ["", "Agent session, per load (median over its sessions): cache hit over the follow-up turns %s; earlier-turn tokens "
              "read again per session %s; first turn (nothing cached) TTFT %s." % (
                  ", ".join(med(h) + " %" for h in hits),
                  ", ".join(med(r["agent"].get("reread_tokens"), 0) for r in res),
                  ", ".join(med(r["agent"].get("first_turn_ttft_s"), 2) + " s" for r in res))]
    acc = acceptance(chat)
    if acc:
        L += ["", "Short-chat MTP acceptance (accepted / offered drafts), pooled: %s." % fmt(stat(acc), 1, " %")]
    for p, _, needles in runs:
        if needles is None:
            continue
        done = [n for n in needles if "found" in n]
        L += ["", "Needles (load r%d): %d of %d found." % (p, sum(n["found"] for n in done), len(done)), "",
              "| Length | Depth % | Prompt tokens | Found | Seconds |", "| --- | ---: | ---: | --- | ---: |"]
        L += ["| %s | %s | %s | %s | %s |" % (n["length"], n["depth"], n.get("prompt_tokens", "—"),
                                             ("yes" if n["found"] else "no") if "found" in n else "error: " + n.get("error", "")[:60],
                                             n.get("seconds", "—")) for n in needles]
    bad = ["- r%d: skipped %s: %s" % (p, k, v) for p, r, _ in runs for k, v in r["skipped"].items()]
    bad += ["- r%d: failed %s: %s" % (p, f["where"], f["error"]) for p, r, _ in runs for f in r["failures"]]
    L += ["", "Failed and skipped:" if bad else "Failed and skipped: none."] + bad
    return L


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    cells = loads(argv[1])
    if not cells:
        print("no loads with results.json in %s" % argv[1], file=sys.stderr)
        return 1
    L = ["# Strata's benchmark suite: %s" % pathlib.Path(argv[1]).name, ""]
    for cell, runs in cells.items():
        L += cell_report(cell, runs) + [""]
    print("\n".join(L).rstrip())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
