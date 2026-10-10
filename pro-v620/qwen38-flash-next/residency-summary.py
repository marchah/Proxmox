#!/usr/bin/env python3
"""Match each request's prefill window to vram-residency-sampler.py samples.

    ./residency-summary.py --residency residency.jsonl REQUESTS.jsonl [...]

REQUESTS files are the batch's agent-session and ingestion records (`t_start`,
`prompt_ms`, `prompt_n`, `prompt_tps`) or placement-probe rows (`t0`, `prompt_ms`,
`prompt_n`, `prefill_tps`). For every request with at least --min-prompt new tokens it
prints, beside the prefill rate and over the prefill window:

- the share of busy samples at the card's lowest memory clock;
- the most memory llama-server asked to have in VRAM that was not resident there
  (`amd-requested-vram` minus `drm-resident-vram`). This covers a buffer created in GTT
  because VRAM was full at that moment, which `amd-evicted-vram` does not count: that
  counter only covers buffers moved out of VRAM after they were created;
- the most memory the kernel counted as evicted from VRAM (`amd-evicted-vram`);
- the most GTT in use above the run's floor, the least GTT in use during any listed
  prefill (the pinned `dio` weights);
- the median power and the least free VRAM.

It then counts slow and fast prefills with and without VRAM-requested memory outside VRAM
(at least --outside-mib), with and without eviction, and with and without extra GTT at or
above --extra-gtt-mib.

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


def fix_units(proc, card):
    """Samples from the sampler before 2026-10-10's unit fix stored fdinfo sizes without
    their unit, and the kernel prints a size in MiB when it divides evenly. A value under
    1/100 of the card's own reading for that memory is such a MiB figure."""
    for key, ref in (("resident_vram_kib", "vram_used_mib"), ("requested_vram_kib", "vram_used_mib"),
                     ("resident_gtt_kib", "gtt_used_mib"), ("requested_gtt_kib", "gtt_used_mib")):
        v, r = proc.get(key), card.get(ref)
        if v and r and v < r * 1024 / 100:
            proc[key] = v * 1024


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--residency", required=True)
    ap.add_argument("requests", nargs="+")
    ap.add_argument("--min-prompt", type=int, default=1500)
    ap.add_argument("--slow", type=float, default=110.0, help="prefill t/s below which a prefill is slow")
    ap.add_argument("--extra-gtt-mib", type=float, default=1000.0)
    ap.add_argument("--outside-mib", type=float, default=64.0,
                    help="VRAM-requested memory outside VRAM that counts as present")
    ap.add_argument("--vram-total-mib", type=float, default=30704.0)
    args = ap.parse_args()

    samples = []
    for rec in load_jsonl(args.residency):
        if not rec["procs"]:
            continue
        card = rec["card"]
        for p in rec["procs"]:
            fix_units(p, card)
        evicted = sum((p.get("evicted_vram_kib") or 0) for p in rec["procs"]) / 1024
        outside = sum(max(0, (p.get("requested_vram_kib") or 0) - (p.get("resident_vram_kib") or 0))
                      for p in rec["procs"]) / 1024
        samples.append((rec["t"], card, evicted, outside))
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
                "outside": max(s[3] for s in win),
                "outside_share": sum(1 for s in busy if s[3] >= args.outside_mib) / len(busy),
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
    print("| Start | Request | Prompt tokens | Prefill (t/s) | Busy samples at lowest memory clock | VRAM-requested memory outside VRAM, max (MiB) | Busy samples with it | Evicted (MiB) | GTT above floor (MiB) | Power (W) | Least VRAM free (MiB) |")
    print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for x in rows:
        w = f"{x['watts']:.0f}" if x["watts"] is not None else "n/a"
        print(f"| {datetime.fromtimestamp(x['t']).strftime('%H:%M:%S')} | {x['label']} | {x['n']:,} | {x['rate']:.1f} | "
              f"{x['low_mclk']:.0%} | {x['outside']:,.0f} | {x['outside_share']:.0%} | {x['evicted']:,.0f} | "
              f"{x['extra_gtt']:,.0f} | {w} | {x['free']:,.0f} |")
    print()
    for name, test in ((f"{args.outside_mib:g}+ MiB of VRAM-requested memory outside VRAM",
                        lambda x: x["outside"] >= args.outside_mib),
                       ("eviction", lambda x: x["evicted"] > 0),
                       (f"GTT {args.extra_gtt_mib:g}+ MiB above floor", lambda x: x["extra_gtt"] >= args.extra_gtt_mib)):
        for slow in (True, False):
            for flag in (True, False):
                sel = [x for x in rows if (x["rate"] < args.slow) == slow and test(x) == flag]
                share = f", mean share at lowest memory clock {statistics.mean(x['low_mclk'] for x in sel):.0%}" if sel else ""
                print(f"{'slow' if slow else 'fast'} prefills {'with' if flag else 'without'} {name}: {len(sel)}{share}")


if __name__ == "__main__":
    main()
