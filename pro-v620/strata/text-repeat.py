#!/usr/bin/env python3
"""Greedy-text repeatability per cell of a strata-sweep.sh run, and agreement between cells.

  text-repeat.py SWEEP_DIR [--against REF]

For each cell: how many of its probe rows (depth and prompt class) gave the same text in every
pass, and how many different texts each row gave across the passes. With --against REF, also
how many rows each cell shares with REF: a row counts when both cells repeated it and their
texts are the same. Texts are compared by the probe's content_sha.
"""
import argparse
import collections
import json
import pathlib
import re
import statistics
import sys


def texts(sweep_dir):
    """{cell: {(depth, class): {content_sha, ...}}} from <cell>-r<pass>.rows.jsonl."""
    cells = collections.defaultdict(lambda: collections.defaultdict(set))
    for f in sorted(pathlib.Path(sweep_dir).glob("*-r*.rows.jsonl")):
        m = re.fullmatch(r"(.+)-r(\d+)\.rows\.jsonl", f.name)
        if not m:
            continue
        for line in f.read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                cells[m.group(1)][(r["depth_target"], r["class"])].add(r["content_sha"])
    return cells


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("sweep_dir")
    ap.add_argument("--against", help="the cell every other cell's texts are compared with")
    a = ap.parse_args(argv)
    cells = texts(a.sweep_dir)
    if not cells:
        print("no rows in %s" % a.sweep_dir, file=sys.stderr)
        return 1
    if a.against and a.against not in cells:
        print("no cell %s in %s" % (a.against, a.sweep_dir), file=sys.stderr)
        return 1
    ref = cells.get(a.against) if a.against else None
    print("| cell | rows with one text in every pass | different texts per row, median / most |%s"
          % (" same text as `%s` |" % a.against if ref else ""))
    print("|---|---:|---:|%s" % ("---:|" if ref else ""))
    for cell in sorted(cells):
        rows = cells[cell]
        counts = [len(v) for v in rows.values()]
        line = "| `%s` | %d of %d | %g / %d |" % (cell, sum(c == 1 for c in counts), len(rows),
                                                 statistics.median(counts), max(counts))
        if ref:
            same = sum(1 for k, v in rows.items() if len(v) == 1 and ref.get(k) == v)
            line += " %d of %d |" % (same, len(rows))
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
