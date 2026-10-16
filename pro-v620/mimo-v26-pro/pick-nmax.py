#!/usr/bin/env python3
"""Stage 2's rule from the baseline record: the MTP draft length stage 3 times.

    ./pick-nmax.py <stage 2 sweep OUT_DIR>      # prints the n-max; the reasoning on stderr

Each screen cell is `mtp-n<N>`. Its score is the median d0 decode over the prompt classes;
a cell with a failed or degenerate request, or a failed contract, is left out. The best
score wins. Every cell within 2% of it is a tie, and the tie goes to the higher two-stream
aggregate decode. n-max 4 counts only when n-max 3 beats n-max 1 and 2, as the record's
plan has it.
"""
import json, pathlib, re, statistics, sys


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = pathlib.Path(sys.argv[1])
    cells = {}
    for f in sorted(out.glob("mtp-n*-r1.json")):
        n = int(re.match(r"mtp-n(\d+)-r1\.json$", f.name).group(1))
        j = json.loads(f.read_text())
        # A failed load has no rows, and a failed request's row no decode_tps.
        d0 = [r["decode_tps"] for r in j.get("rows", [])
              if r.get("depth_target") == 0 and r.get("decode_tps") is not None]
        conc = f.with_name(f"mtp-n{n}-r1.concurrency.json")
        agg = json.loads(conc.read_text()).get("aggregate_tps") if conc.exists() else None
        ok = (j.get("probe_ok") and not j.get("failed_requests") and not j.get("any_degenerate")
              and j.get("contract_ok") is not False and d0)
        cells[n] = {"ok": bool(ok), "d0": statistics.median(d0) if d0 else None, "agg": agg or 0.0}
        print(f"n-max {n}: d0 median {cells[n]['d0']}, two streams {agg}, "
              f"{'ok' if ok else 'LEFT OUT'}", file=sys.stderr)

    valid = {n: c for n, c in cells.items() if c["ok"]}
    if 4 in valid:
        first3 = {n: c for n, c in valid.items() if n <= 3}
        if not first3 or max(first3, key=lambda n: first3[n]["d0"]) != 3:
            print("n-max 4 left out: n-max 3 is not the fastest of 1-3", file=sys.stderr)
            del valid[4]
    if not valid:
        sys.exit("no screen cell is usable")
    best = max(c["d0"] for c in valid.values())
    tied = [n for n, c in valid.items() if c["d0"] >= 0.98 * best]
    pick = max(tied, key=lambda n: (valid[n]["agg"], valid[n]["d0"]))
    print(f"within 2% of {best:.3f}: {sorted(tied)}; picked n-max {pick}", file=sys.stderr)
    print(pick)


if __name__ == "__main__":
    main()
