#!/usr/bin/env python3
"""Merge one probe result file into results.jsonl. Kept as a real file (not an inline
heredoc) because `python3 - args <<HEREDOC` consumes stdin for the PROGRAM, so piped
data never reaches sys.stdin.read() — that silently emptied a whole sweep."""
import json, os, sys

tag, gpu, cfg, nmax, t0, t1, t2, placed, probe_path, results = sys.argv[1:11]
row = {"tag": tag, "gpu": gpu, "config": cfg, "n_max": nmax, "placed_on": placed,
       "load_s": round(float(t1) - float(t0), 1),
       "probe_s": round(float(t2) - float(t1), 1)}
try:
    with open(probe_path) as fh:
        row.update(json.load(fh))
except Exception as e:
    row["probe_error"] = "%s: %s" % (type(e).__name__, e)
    if os.path.exists(probe_path):
        row["probe_raw_head"] = open(probe_path, errors="replace").read()[:200]
with open(results, "a") as fh:
    fh.write(json.dumps(row) + "\n")
print("    placed_on=%s  decode=%s t/s  accept=%s%%  %s" % (
    placed, row.get("decode_tps_mean"), row.get("accept_pct_overall"),
    row.get("probe_error", "")))
