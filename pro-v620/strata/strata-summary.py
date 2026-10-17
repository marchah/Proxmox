#!/usr/bin/env python3
"""The Strata part of a strata-sweep.sh summary: per cell, what the engine reported.

summarize-sweep.py prints the speed tables; this adds, as medians across passes, the
engine's expert cache (slots on every card it uses, decode hit rate, the share of routed
experts the GPU read over PCIe), the VRAM it left free, any VRAM-requested memory outside
VRAM, its load time, and the stall, non-finite and warning lines its log holds. The hit rate
climbs within a load as the adaptive tier learns the requests, so the last request's rate is
shown beside the median.
"""
import json, pathlib, statistics, sys


def med(xs, fmt="%.1f"):
    xs = [x for x in xs if x is not None]
    return fmt % statistics.median(xs) if xs else "—"


def cache_slots(runs):
    """Median expert-cache slots per run, summed over the cards: `16220 (8227 + 7993)`.

    strata-cell.py records each device's cache. Results from before it kept only the first
    card's, and read as that number alone.
    """
    totals, per_dev = [], {}
    for e in runs:
        caches = e.get("expert_caches")
        if caches:
            totals.append(sum(c["slots"] for c in caches.values()))
            for dev, c in caches.items():
                per_dev.setdefault(dev, []).append(c["slots"])
        elif e.get("expert_cache_slots"):
            totals.append(e["expert_cache_slots"][0])
    if not totals:
        return "—"
    text = "%.0f" % statistics.median(totals)
    if len(per_dev) > 1:
        text += " (%s)" % " + ".join("%.0f" % statistics.median(per_dev[d]) for d in sorted(per_dev))
    return text


def outside_vram(runs):
    """Median VRAM-requested memory outside VRAM, or how many runs had no reading."""
    missing = sum(bool(pl.get("residency_missing")) for pl in runs)
    if missing:
        return "unmeasured in %d" % missing
    return med([pl.get("vram_outside_mib") for pl in runs], "%.0f")


def main():
    d = pathlib.Path(sys.argv[1])
    manifest = json.loads((d / "manifest.json").read_text()) if (d / "manifest.json").exists() else {}
    order = [c["label"] for c in manifest.get("cells") or []]
    by = {}
    for f in sorted(d.glob("*-r*.json")):
        try:
            j = json.loads(f.read_text())
        except Exception:
            continue
        pl = j.get("placement") or {}
        if not pl.get("label") or pl.get("load_failed"):
            continue
        by.setdefault(pl["label"], []).append((pl, j.get("contract") or {}))
    if not by:
        return
    if any((pl.get("strata") or {}).get("engine") == "maya" for runs in by.values() for pl, _ in runs):
        maya_table(by, order, d)
        return
    print("## Strata engine\n")
    print("Medians across passes. Cache slots: summed over the cards the engine uses, each card's in "
          "brackets. Hit rate: decode lookups served by the VRAM expert cache, per "
          "request, median and the last request of a pass; PCIe: routed experts the GPU read from "
          "RAM instead of the CPU computing them. Outside VRAM: memory the engine asked to have in "
          "VRAM that sat elsewhere, at load or after the probe (0 is expected).\n")
    print("| cell | cards | load, s | cache slots | VRAM free at load, MiB | free after probe, MiB "
          "| outside VRAM, MiB | hit % (median / last) | PCIe % | draft MiB | stalls / non-finite / warnings "
          "| tool calls ok |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|")
    for label in sorted(by, key=lambda k: (order.index(k) if k in order else len(order), k)):
        runs = by[label]
        s = [pl.get("strata") or {} for pl, _ in runs]
        cards = sorted({c for pl, _ in runs for c in pl.get("cards_held") or []})
        tools = sum(bool(c.get("tool_call", {}).get("ok") and c.get("tool_call_stream", {}).get("ok"))
                    for _, c in runs if c)
        print("| %s | %s | %s | %s | %s | %s | %s | %s / %s | %s | %s | %d / %d / %d | %d/%d |" % (
            label, ", ".join("`%s`" % c[5:] for c in cards) or "—",
            med([pl.get("load_s") for pl, _ in runs], "%.0f"),
            cache_slots(s),
            med([x for e in s for x in e.get("vram_free_loaded_mib") or []], "%.0f"),
            med([pl.get("vram_free_after_probe_mib") for pl, _ in runs], "%.0f"),
            outside_vram([pl for pl, _ in runs]),
            med([e.get("decode_hit_pct_median") for e in s]), med([e.get("decode_hit_pct_last") for e in s]),
            med([e.get("pcie_share_pct_median") for e in s]),
            med([e.get("draft_layer_mib") for e in s], "%.0f"),
            sum(e.get("stall_lines") or 0 for e in s), sum(e.get("nonfinite_lines") or 0 for e in s),
            sum(len(e.get("warning_lines") or []) for e in s),
            tools, len(runs)))
    warn = [(label, w) for label, runs in by.items() for pl, _ in runs
            for w in (pl.get("strata") or {}).get("warning_lines") or []]
    if warn:
        print("\nEngine warnings:\n")
        for label, w in warn[:20]:
            print("- `%s`: %s" % (label, w.strip()[:200]))
    print("\n*Generated by `strata-summary.py` from `%s`.*" % d)


def maya_table(by, order, d):
    """The same per-cell account for Project Maya's engine (strata-cell.py maya_account)."""
    print("## Maya engine\n")
    print("Medians across passes. Expert pool slots: summed over the cards, each card's in brackets. "
          "Hit %: decode lookups served by the VRAM pool, per request, median and the last request of a "
          "pass. RAM fetches and CPU lane: RAM-tier experts per token copied over PCIe and computed on "
          "the CPU. Disk: the most experts per token any request read from the SSD (0 expected with "
          "every expert in RAM). Outside VRAM as in the Strata table (0 is expected).\n")
    print("| cell | cards | load, s | pool slots | RAM tier, GB | VRAM free at load, MiB | free after probe, MiB "
          "| outside VRAM, MiB | hit % (median / last) | RAM fetches / CPU lane per token | disk reads/token "
          "| drafts accepted % | stalls / non-finite / warnings | tool calls ok |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|")
    for label in sorted(by, key=lambda k: (order.index(k) if k in order else len(order), k)):
        runs = by[label]
        s = [pl.get("strata") or {} for pl, _ in runs]
        cards = sorted({c for pl, _ in runs for c in pl.get("cards_held") or []})
        tools = sum(bool(c.get("tool_call", {}).get("ok") and c.get("tool_call_stream", {}).get("ok"))
                    for _, c in runs if c)
        disk = [e.get("disk_reads_per_tok_max") for e in s if e.get("disk_reads_per_tok_max") is not None]
        print("| %s | %s | %s | %s | %s | %s | %s | %s | %s / %s | %s / %s | %s | %s | %d / %d / %d | %d/%d |" % (
            label, ", ".join("`%s`" % c[5:] for c in cards) or "—",
            med([pl.get("load_s") for pl, _ in runs], "%.0f"),
            cache_slots(s),
            med([sum(t["gb"] for t in (e.get("ram_tier") or {}).values()) or None for e in s]),
            med([x for e in s for x in e.get("vram_free_loaded_mib") or []], "%.0f"),
            med([pl.get("vram_free_after_probe_mib") for pl, _ in runs], "%.0f"),
            outside_vram([pl for pl, _ in runs]),
            med([e.get("decode_hit_pct_median") for e in s]), med([e.get("decode_hit_pct_last") for e in s]),
            med([e.get("ram_fetches_per_tok_median") for e in s]), med([e.get("cpu_lane_per_tok_median") for e in s]),
            "%.2f" % max(disk) if disk else "—",
            med([e.get("spec_accept_pct_median") for e in s]),
            sum(e.get("stall_lines") or 0 for e in s), sum(e.get("nonfinite_lines") or 0 for e in s),
            sum(len(e.get("warning_lines") or []) for e in s),
            tools, len(runs)))
    warn = [(label, w) for label, runs in by.items() for pl, _ in runs
            for w in (pl.get("strata") or {}).get("warning_lines") or []]
    if warn:
        print("\nEngine warnings:\n")
        for label, w in warn[:20]:
            print("- `%s`: %s" % (label, w.strip()[:200]))
    print("\n*Generated by `strata-summary.py` from `%s`.*" % d)


if __name__ == "__main__":
    main()
