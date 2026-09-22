#!/usr/bin/env python3
"""Summarize a spec-ab results.jsonl into Markdown tables.

Per arm and cell: median decode (tg) and prefill (pp) across repetitions, with the
min-max spread so run-to-run noise is visible next to any difference.

Correctness, per arm:
  tool_ok      every tool cell returned a parseable get_weather call
  degenerate   cells whose distinct-4-gram ratio fell below 0.5 (repetition)
  greedy_same  share of greedy cells whose text matches the reference arm's greedy
               text for the same prompt and repetition. Speculation verifies drafts
               against the target, so a spec arm should match the non-spec arm with
               the SAME KV type. It is not exact: batched verification changes
               float order, so near-ties can flip.
"""
from __future__ import annotations

import argparse
import json
import statistics as st
from collections import defaultdict


def reference_for(arm: str, arms: set[str]) -> str | None:
    if arm.startswith("base"):
        return "base" if arm != "base" and "base" in arms else None
    ref = "base-q8" if arm.endswith("-q8") else "base"
    return ref if ref in arms else None


def fmt(values: list[float]) -> str:
    if not values:
        return "n/a"
    med = st.median(values)
    return f"{med:.1f} ({min(values):.0f}–{max(values):.0f})" if len(values) > 1 else f"{med:.1f}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    a = ap.parse_args()
    rows = [json.loads(line) for line in open(a.results, encoding="utf-8")]
    arms = list(dict.fromkeys(r["arm"] for r in rows))
    cells = list(dict.fromkeys(r["cell"] for r in rows))
    by = defaultdict(list)
    for r in rows:
        by[(r["arm"], r["cell"])].append(r)

    print("## Decode (tg) t/s — median (min–max) over repetitions\n")
    print("| Cell | " + " | ".join(arms) + " |")
    print("| --- |" + " ---: |" * len(arms))
    for c in cells:
        vals = [fmt([r["decode_tps"] for r in by[(arm, c)] if r.get("decode_tps")]) for arm in arms]
        print(f"| {c} | " + " | ".join(vals) + " |")

    print("\n## c2 aggregate t/s (both streams)\n")
    print("| Cell | " + " | ".join(arms) + " |")
    print("| --- |" + " ---: |" * len(arms))
    for c in (c for c in cells if c.startswith("c2/") and c.endswith("/a")):
        vals = [fmt([r["c2_aggregate_tps"] for r in by[(arm, c)] if r.get("c2_aggregate_tps")]) for arm in arms]
        print(f"| {c[:-2]} | " + " | ".join(vals) + " |")

    print("\n## Prefill (pp) t/s — deep cells\n")
    print("| Cell | " + " | ".join(arms) + " |")
    print("| --- |" + " ---: |" * len(arms))
    for c in (c for c in cells if c.startswith("deep/")):
        vals = [fmt([r["prompt_tps"] for r in by[(arm, c)] if r.get("prompt_tps")]) for arm in arms]
        print(f"| {c} | " + " | ".join(vals) + " |")

    print("\n## Speculation and correctness\n")
    print("| Arm | Draft acceptance | tool_ok | degenerate | greedy_same (vs) |")
    print("| --- | ---: | --- | ---: | --- |")
    arm_set = set(arms)
    for arm in arms:
        mine = [r for r in rows if r["arm"] == arm]
        drafted = sum(r.get("draft_n") or 0 for r in mine)
        accepted = sum(r.get("draft_accepted") or 0 for r in mine)
        acc = f"{100 * accepted / drafted:.1f}%" if drafted else "—"
        tools = [r.get("tool_ok") for r in mine if r["cell"] == "tool"]
        tool = f"{sum(bool(t) for t in tools)}/{len(tools)}"
        degen = sum(1 for r in mine if r.get("distinct4", 1) < 0.5)
        ref = reference_for(arm, arm_set)
        same = "—"
        if ref:
            refs = {(r["cell"], r["rep"]): r["content"] for r in rows
                    if r["arm"] == ref and r["cell"].endswith("/greedy")}
            pairs = [(r["content"], refs.get((r["cell"], r["rep"]))) for r in mine
                     if r["cell"].endswith("/greedy")]
            pairs = [p for p in pairs if p[1] is not None]
            if pairs:
                same = f"{sum(x == y for x, y in pairs)}/{len(pairs)} ({ref})"
        print(f"| {arm} | {acc} | {tool} | {degen} | {same} |")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
