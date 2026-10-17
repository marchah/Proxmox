#!/usr/bin/env python3
"""Greedy-text repeatability per cell of a strata-sweep.sh run, and agreement between cells.

  text-repeat.py SWEEP_DIR [--against REF]

For each cell: how many of the sweep's probe rows (depth and prompt class) gave the same text in
every pass, and how many different texts each row gave across the passes. With --against REF,
also how many rows each cell shares with REF: a row counts when both cells repeated it and their
texts are the same. Texts are compared by the probe's content_sha.

A row counts only when every pass has a successful reading of it. The passes and cells are the
manifest's (1 to its reps), or without one every pass and cell any rows file shows; the rows are
every row any cell reported. A row missing from a pass, or failed there, is counted as missing,
not as a repeat, and the tool then exits 2.
"""
import argparse
import collections
import json
import pathlib
import re
import statistics
import sys


def readings(sweep_dir):
    """{cell: {(depth, class): {pass: {content_sha, ...}}}} from <cell>-r<pass>.rows.jsonl, with
    every row and pass seen. A failed request names its row but gives it no text."""
    cells = collections.defaultdict(lambda: collections.defaultdict(lambda: collections.defaultdict(set)))
    rows, passes = set(), set()
    for f in sorted(pathlib.Path(sweep_dir).glob("*-r*.rows.jsonl")):
        m = re.fullmatch(r"(.+)-r(\d+)\.rows\.jsonl", f.name)
        if not m:
            continue
        n = int(m.group(2))
        passes.add(n)
        cell = cells[m.group(1)]
        for line in f.read_text(errors="replace").splitlines():
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue   # the file is the probe's stderr, which can carry other lines
            if not isinstance(r, dict) or "depth_target" not in r or "class" not in r:
                continue
            k = (r["depth_target"], r["class"])
            rows.add(k)
            if r.get("content_sha") and not r.get("error"):
                cell[k][n].add(r["content_sha"])
    return cells, rows, passes


def expected(sweep_dir, cells, passes):
    """The passes and cells the sweep ran: its manifest's, else the ones its rows files show."""
    try:
        manifest = json.loads((pathlib.Path(sweep_dir) / "manifest.json").read_text())
        return (list(range(1, int(manifest["reps"]) + 1)),
                sorted(set(cells) | {c["label"] for c in json.loads(manifest["cells"])}))
    except (OSError, ValueError, KeyError, TypeError):
        return sorted(passes), sorted(cells)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("sweep_dir")
    ap.add_argument("--against", help="the cell every other cell's texts are compared with")
    a = ap.parse_args(argv)
    cells, rows, seen = readings(a.sweep_dir)
    if not rows:
        print("no rows in %s" % a.sweep_dir, file=sys.stderr)
        return 1
    if a.against and a.against not in cells:
        print("no cell %s in %s" % (a.against, a.sweep_dir), file=sys.stderr)
        return 1
    passes, labels = expected(a.sweep_dir, cells, seen)

    def complete(cell):
        """{row: its texts over the passes}, for the rows with a reading in every pass."""
        got = cells.get(cell, {})
        return {k: set().union(*(got[k][n] for n in passes)) for k in rows
                if k in got and all(got[k].get(n) for n in passes)}

    ref = complete(a.against) if a.against else None
    print("| cell | rows with one text in every pass | different texts per row, median / most "
          "| rows missing from a pass |%s" % (" same text as `%s` |" % a.against if ref is not None else ""))
    print("|---|---:|---:|---:|%s" % ("---:|" if ref is not None else ""))
    short = False
    for cell in labels:
        texts = complete(cell)
        counts = [len(v) for v in texts.values()]
        missing = len(rows) - len(texts)
        short = short or missing > 0
        spread = "%g / %d" % (statistics.median(counts), max(counts)) if counts else "—"
        line = "| `%s` | %d of %d | %s | %d |" % (cell, sum(c == 1 for c in counts), len(rows), spread, missing)
        if ref is not None:
            same = sum(1 for k, v in texts.items() if len(v) == 1 and ref.get(k) == v)
            line += " %d of %d |" % (same, len(rows))
        print(line)
    return 2 if short else 0


if __name__ == "__main__":
    sys.exit(main())
