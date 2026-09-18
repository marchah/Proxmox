#!/usr/bin/env python3
"""Attribute `placement-telemetry.jsonl` rows to the cell that was running at the time.

The sweep scripts record a cell's throughput but not its VRAM headroom or GTT, and that
gap is not cosmetic: **below roughly 1 GiB of free VRAM, RADV spills to GTT, and the
startup loud-guard does not catch it.** A spilled cell posts a plausible number and reads
as "a slow placement" rather than "a broken one". This joins the two so every cell gets a
fits / tight / SPILLED verdict next to its tok/s.

⚠️ Read FREE VRAM, not used VRAM. Used looks healthy right up to the cliff — the first
cell measured here sat at 30665 MiB used, which is unremarkable, while having 39 MiB free
and 2060 MiB already in GTT.

How the join works: each cell writes its JSON when it FINISHES, so cell N's window is
(mtime of N-1, mtime of N]. The first cell's window opens at the earliest sample. That is
approximate at the boundaries — a restart and model load sit inside each window — so the
statistics taken are MIN free / MAX gtt over the window, which are dominated by the
steady-state serving part rather than the load ramp.

Usage:
    ./attribute-telemetry.py <overnight-run-dir> [cell-dir ...]

With no cell-dir it uses the newest reval-*/ plus the run dir itself (for the split-*,
mtp-* and par* cells).
"""
from __future__ import annotations

import glob
import json
import os
import statistics as st
import sys
from datetime import datetime, timezone

GPUS = ("gpu03", "gpu83")
SPILL_GTT_MIB = 256      # a resident-only placement should be at ~0
SPILL_FREE_MIB = 1024    # RADV starts spilling below roughly this
TIGHT_FREE_MIB = 2048


def load_samples(path: str) -> list[dict]:
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
                d["_t"] = datetime.strptime(d["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(
                    tzinfo=timezone.utc).timestamp()
                rows.append(d)
            except Exception:
                continue          # a torn last line is normal while the sampler runs
    return sorted(rows, key=lambda r: r["_t"])


def cell_files(run: str, dirs: list[str]) -> list[tuple[str, str, float]]:
    out = []
    for d in dirs:
        for f in sorted(glob.glob(os.path.join(d, "*.json"))):
            name = os.path.basename(f)[:-len(".json")]
            # Skip the pipeline's own bookkeeping files, which are not cells.
            if name in ("manifest", "versions", "status"):
                continue
            out.append((name, f, os.path.getmtime(f)))
    return sorted(out, key=lambda x: x[2])


def decode_median(path: str, prefix: str = "d0/") -> float | None:
    try:
        s = json.load(open(path)).get("summary", {})
    except Exception:
        return None
    v = [x["decode_tps_median"] for k, x in s.items()
         if k.startswith(prefix) and x.get("decode_tps_median")]
    return st.median(v) if v else None


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    run = sys.argv[1].rstrip("/")
    tel = os.path.join(run, "placement-telemetry.jsonl")
    if not os.path.exists(tel):
        print("no placement-telemetry.jsonl in %s — was the sampler running?" % run)
        return 1
    samples = load_samples(tel)
    if not samples:
        print("telemetry file is empty")
        return 1

    dirs = sys.argv[2:]
    if not dirs:
        revals = sorted(glob.glob("/root/qwen38-flash-next/reval-*/"), key=os.path.getmtime)
        dirs = ([revals[-1]] if revals else []) + [run]
    cells = cell_files(run, dirs)
    if not cells:
        print("no cell JSON found under: %s" % ", ".join(dirs))
        return 1

    print("telemetry: %d samples, %s .. %s" % (len(samples), samples[0]["ts"], samples[-1]["ts"]))
    print()
    hdr = ("%-30s %7s %7s %9s %9s %7s %7s %7s  %s"
           % ("cell", "d0 t/s", "d8k t/s", "free c1", "free c2", "gtt c1", "gtt c2", "maxJ C", "verdict"))
    print(hdr)
    print("-" * len(hdr))

    prev = samples[0]["_t"] - 1
    for name, path, mt in cells:
        win = [r for r in samples if prev < r["_t"] <= mt]
        prev = mt
        if not win:
            print("%-30s %7s %7s %9s %9s %7s %7s %7s  %s"
                  % (name, "-", "-", "-", "-", "-", "-", "-", "no samples in window"))
            continue
        f1 = min(r["gpu03_vram_free"] for r in win)
        f2 = min(r["gpu83_vram_free"] for r in win)
        g1 = max(r["gpu03_gtt"] for r in win)
        g2 = max(r["gpu83_gtt"] for r in win)
        jm = max(max(r["gpu03_junction"], r["gpu83_junction"]) for r in win)

        # A CPU-only cell is not "spilled" just because its cards are empty, so judge
        # only the cards that are actually holding model tensors.
        active = [(f, g) for f, g in ((f1, g1), (f2, g2)) if f < 30000]
        if not active:
            verdict = "cards idle (CPU-only)"
        else:
            free_min = min(f for f, _ in active)
            gtt_max = max(g for _, g in active)
            if gtt_max > SPILL_GTT_MIB or free_min < SPILL_FREE_MIB:
                verdict = "SPILLED (%d MiB in GTT, %d MiB free)" % (gtt_max, free_min)
            elif free_min < TIGHT_FREE_MIB:
                verdict = "tight"
            else:
                verdict = "fits"

        d0, d8 = decode_median(path, "d0/"), decode_median(path, "d8000/")
        print("%-30s %7s %7s %9d %9d %7d %7d %7d  %s" % (
            name,
            ("%.2f" % d0) if d0 else "-",
            ("%.2f" % d8) if d8 else "-",
            f1, f2, g1, g2, jm, verdict))

    print()
    # Thermals and clock, over the whole run rather than per cell: the point is whether
    # anything came near a limit, and a per-cell breakdown of a flat signal is noise.
    print("Whole-run envelope:")
    for g in GPUS:
        print("  %s  junction %d-%d C   mem %d-%d C   %d-%d W   busy %d-%d %%" % (
            g,
            min(r[g + "_junction"] for r in samples), max(r[g + "_junction"] for r in samples),
            min(r[g + "_mem_temp"] for r in samples), max(r[g + "_mem_temp"] for r in samples),
            min(r[g + "_watts"] for r in samples), max(r[g + "_watts"] for r in samples),
            min(r[g + "_busy"] for r in samples), max(r[g + "_busy"] for r in samples)))
    print("  busy-core p90 clock %d-%d MHz" % (
        min(r["busy_clk_mhz"] for r in samples), max(r["busy_clk_mhz"] for r in samples)))
    dim = [r for r in samples if r.get("dimm")]
    if dim:
        keys = sorted(dim[-1]["dimm"])
        print("  DIMM channels (populated only): " + "  ".join(
            "%s %d-%d C" % (k.replace("TEMP_CPU1_DDR4", ""),
                            min(r["dimm"].get(k, 0) for r in dim if k in r["dimm"]),
                            max(r["dimm"].get(k, 0) for r in dim if k in r["dimm"]))
            for k in keys))
    print("  CPU package %d-%d C" % (
        min(r["cpu_temp"] for r in samples), max(r["cpu_temp"] for r in samples)))
    # RAPL is a monotonic microjoule counter that WRAPS, so a negative delta means wrapped,
    # not 0 W. Report the average over the run from the first non-wrapping span.
    e = [(r["_t"], r["rapl_uj"]) for r in samples if r.get("rapl_uj")]
    if len(e) > 1:
        spans = [((t1 - t0), (u1 - u0)) for (t0, u0), (t1, u1) in zip(e, e[1:]) if u1 >= u0 and t1 > t0]
        if spans:
            w = sum(u for _, u in spans) / 1e6 / sum(t for t, _ in spans)
            print("  CPU package power (RAPL, mean over run): %.1f W" % w)
    return 0


if __name__ == "__main__":
    sys.exit(main())
