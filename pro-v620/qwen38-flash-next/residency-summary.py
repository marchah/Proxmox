#!/usr/bin/env python3
"""Match each request's prefill window to vram-residency-sampler.py samples.

    ./residency-summary.py --residency residency.jsonl REQUESTS.jsonl [...]

REQUESTS files are the batch's agent-session and ingestion records (`t_start`,
`prompt_ms`, `prompt_n`, `prompt_tps`) or placement-probe rows (`t0`, `prompt_ms`,
`prompt_n`, `prefill_tps`). For every request with at least --min-prompt new tokens it
prints, beside the prefill rate and over the prefill window:

- the share of busy samples at the card's lowest memory clock;
- the most memory the kernel counted as evicted from VRAM (`amd-evicted-vram`);
- the most GTT in use above the run's floor, the least GTT in use during any listed
  prefill (the pinned `dio` weights);
- the median power and the least free VRAM.

It then counts slow and fast prefills with and without eviction, and with and without
extra GTT at or above --extra-gtt-mib.

Per-buffer moves in the samples are not used: GEM handles are reused, so a buffer freed
and another created under its handle between two samples reads as a move.
"""
import argparse
import json
import statistics
from datetime import datetime


def load_jsonl(path):
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--residency", required=True)
    ap.add_argument("requests", nargs="+")
    ap.add_argument("--min-prompt", type=int, default=1500)
    ap.add_argument("--slow", type=float, default=110.0, help="prefill t/s below which a prefill is slow")
    ap.add_argument("--extra-gtt-mib", type=float, default=1000.0)
    ap.add_argument("--vram-total-mib", type=float, default=30704.0)
    args = ap.parse_args()

    samples = []
    for rec in load_jsonl(args.residency):
        if not rec["procs"]:
            continue
        card = rec["card"]
        evicted = sum((p.get("evicted_vram_kib") or 0) for p in rec["procs"]) / 1024
        samples.append((rec["t"], card, evicted))
    low_mclk = min((s[1]["mclk_mhz"] for s in samples if s[1].get("mclk_mhz")), default=None)

    rows = []
    for path in args.requests:
        for r in load_jsonl(path):
            start = r.get("t_start", r.get("t0"))
            n = r.get("prompt_n") or 0
            rate = r.get("prompt_tps", r.get("prefill_tps"))
            if start is None or not r.get("prompt_ms") or n < args.min_prompt or rate is None:
                continue
            end = start + r["prompt_ms"] / 1000
            win = [s for s in samples if start <= s[0] <= end]
            if not win:
                continue
            busy = [s for s in win if (s[1].get("gpu_busy") or 0) >= 50] or win
            watts = [s[1]["power_w"] for s in busy if s[1].get("power_w") is not None]
            rows.append({
                "t": start, "label": r.get("preset") or r.get("depth_label") or r.get("class") or "",
                "n": n, "rate": rate,
                "low_mclk": sum(1 for s in busy if s[1].get("mclk_mhz") == low_mclk) / len(busy),
                "evicted": max(s[2] for s in win),
                "gtt_max": max(s[1]["gtt_used_mib"] for s in win),
                "gtt_min": min(s[1]["gtt_used_mib"] for s in win),
                "watts": statistics.median(watts) if watts else None,
                "free": min(args.vram_total_mib - s[1]["vram_used_mib"] for s in win),
            })
    rows.sort(key=lambda x: x["t"])
    floor = min((x["gtt_min"] for x in rows), default=0.0)
    for x in rows:
        x["extra_gtt"] = x["gtt_max"] - floor
    print(f"lowest memory clock seen: {low_mclk} MHz; GTT floor {floor:,.0f} MiB; "
          f"slow prefill: below {args.slow:g} t/s\n")
    print("| Start | Request | Prompt tokens | Prefill (t/s) | Busy samples at lowest memory clock | Evicted from VRAM (MiB) | GTT above floor (MiB) | Power (W) | Least VRAM free (MiB) |")
    print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for x in rows:
        w = f"{x['watts']:.0f}" if x["watts"] is not None else "n/a"
        print(f"| {datetime.fromtimestamp(x['t']).strftime('%H:%M:%S')} | {x['label']} | {x['n']:,} | {x['rate']:.1f} | "
              f"{x['low_mclk']:.0%} | {x['evicted']:,.0f} | {x['extra_gtt']:,.0f} | {w} | {x['free']:,.0f} |")
    print()
    for name, test in (("eviction", lambda x: x["evicted"] > 0),
                       (f"GTT {args.extra_gtt_mib:g}+ MiB above floor", lambda x: x["extra_gtt"] >= args.extra_gtt_mib)):
        for slow in (True, False):
            for flag in (True, False):
                sel = [x for x in rows if (x["rate"] < args.slow) == slow and test(x) == flag]
                share = f", mean share at lowest memory clock {statistics.mean(x['low_mclk'] for x in sel):.0%}" if sel else ""
                print(f"{'slow' if slow else 'fast'} prefills {'with' if flag else 'without'} {name}: {len(sel)}{share}")


if __name__ == "__main__":
    main()
