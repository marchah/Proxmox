#!/usr/bin/env python3
"""Reduce a placement-sweep output directory to one Markdown table.

Rows are placements (n_cpu_moe). The point of the table is the trade the sweep exists to
settle: VRAM handed back to a second model versus decode lost. So "free VRAM" sits next
to the decode medians, and the versatility column is decode per GB given up.
"""
import json, pathlib, statistics, sys


def med(xs):
    return round(statistics.median(xs), 1) if xs else None


def main():
    d = pathlib.Path(sys.argv[1])
    manifest = {}
    mp = d / "manifest.json"
    if mp.exists():
        try:
            manifest = json.loads(mp.read_text())
        except Exception:
            pass

    # group the per-round files by n_cpu_moe
    by = {}
    contract = None
    for f in sorted(d.glob("ncmoe*-r*.json")):
        try:
            j = json.loads(f.read_text())
        except Exception:
            continue
        pl = j.get("placement") or {}
        n = pl.get("n_cpu_moe")
        if n is None:
            continue
        g = by.setdefault(n, {"decode": {}, "prefill": {}, "vram": [], "free": [],
                              "gtt": [], "spill": False, "degen": False,
                              "disagree": False, "errors": 0})
        if j.get("error"):
            g["errors"] += 1
        g["vram"].append(pl.get("vram_total_mib") or 0)
        g["free"].append(pl.get("vram_free_for_a_guest_mib") or 0)
        g["gtt"].append(max(pl.get("gpu1_gtt_mib") or 0, pl.get("gpu2_gtt_mib") or 0))
        g["spill"] |= bool(pl.get("possible_gtt_spill"))
        g["degen"] |= bool(j.get("any_degenerate"))
        g["disagree"] |= (j.get("all_reps_agree") is False)
        for k, v in (j.get("summary") or {}).items():
            if v.get("decode_tps_median"):
                g["decode"].setdefault(k, []).append(v["decode_tps_median"])
            if v.get("prefill_tps_median"):
                g["prefill"].setdefault(k, []).append(v["prefill_tps_median"])
        if contract is None and j.get("contract"):
            contract = j["contract"]

    if not by:
        print("No parsable sweep results in %s" % d)
        return

    cells = sorted({k for g in by.values() for k in g["decode"]})
    depths = sorted({c.split("/")[0] for c in cells},
                    key=lambda s: int(s.lstrip("d")))

    print("# Qwen3.8-Flash-Next placement sweep\n")
    if manifest:
        print("`ctx %s` · `parallel %s` · `%s reps` · `n_predict %s` · depths `%s` · "
              "%s · %s GiB host RAM · llama.cpp `%s`\n" % (
                  manifest.get("ctx"), manifest.get("parallel"), manifest.get("reps"),
                  manifest.get("n_predict"), manifest.get("depths"),
                  "ONE GPU" if manifest.get("one_gpu") else "two GPUs",
                  manifest.get("host_ram_gib"),
                  str(manifest.get("llamacpp_dir", "")).rsplit("/", 1)[-1]))

    # --- the decision table -------------------------------------------------------
    hdr = (["n_cpu_moe", "VRAM used", "free for a guest", "max GTT"]
           + ["decode " + c for c in cells] + ["flags"])
    print("| " + " | ".join(hdr) + " |")
    print("|" + "|".join(["---"] * len(hdr)) + "|")

    base_free = None
    rows_for_tradeoff = []
    for n in sorted(by):
        g = by[n]
        vram = med(g["vram"]) or 0
        free = med(g["free"]) or 0
        flags = []
        if g["spill"]:
            flags.append("⚠️ GTT spill")
        if g["degen"]:
            flags.append("🔴 degenerate output")
        if g["disagree"]:
            flags.append("⚠️ reps disagree")
        if g["errors"]:
            flags.append("🔴 %d probe error(s)" % g["errors"])
        cellvals = [med(g["decode"].get(c, [])) for c in cells]
        print("| %d | %.1f GiB | **%.1f GiB** | %d MiB | %s | %s |" % (
            n, vram / 1024, free / 1024, med(g["gtt"]) or 0,
            " | ".join("%.1f" % v if v else "—" for v in cellvals),
            ", ".join(flags) or "ok"))
        overall = [v for v in cellvals if v]
        if overall:
            rows_for_tradeoff.append((n, free / 1024, med(overall)))

    # --- what it decides ----------------------------------------------------------
    if len(rows_for_tradeoff) >= 2:
        # the fastest placement is the reference; everything else trades decode for VRAM
        ref = max(rows_for_tradeoff, key=lambda r: r[2])
        print("\n## The trade, against the fastest placement\n")
        print("Reference: `n_cpu_moe %d` at **%.1f t/s** with %.1f GiB free.\n"
              % (ref[0], ref[2], ref[1]))
        print("| n_cpu_moe | decode | vs fastest | extra VRAM freed | cost per GB freed |")
        print("|---|---:|---:|---:|---:|")
        for n, free, dec in rows_for_tradeoff:
            dgb = free - ref[1]
            loss = dec - ref[2]
            per = ("%.2f t/s per GiB" % (abs(loss) / dgb)) if dgb > 0.05 else "—"
            print("| %d | %.1f t/s | %+.1f%% | %+.1f GiB | %s |" % (
                n, dec, 100.0 * loss / ref[2] if ref[2] else 0, dgb, per))

    # --- depth effect -------------------------------------------------------------
    if len(depths) > 1:
        print("\n## Decode versus context depth\n")
        print("The QSA indexer rescored block summaries over the whole cached context "
              "every token until llama.cpp #28699 (an open draft), so depth is a real "
              "axis here — a short-prompt number is not this model's throughput.\n")
        print("| n_cpu_moe | " + " | ".join(depths) + " |")
        print("|" + "|".join(["---"] * (len(depths) + 1)) + "|")
        for n in sorted(by):
            g = by[n]
            vals = []
            for dep in depths:
                xs = [v for c, vv in g["decode"].items() if c.startswith(dep + "/") for v in vv]
                vals.append("%.1f" % med(xs) if xs else "—")
            print("| %d | %s |" % (n, " | ".join(vals)))

    # --- the template contract ----------------------------------------------------
    if contract:
        print("\n## Template contract\n")
        print("This model's raw template resolves `reasoning_effort|default('xhigh')` and RAISES "
              "on `\"none\"` and `\"high\"` — the two values that work on CT 123's coder. The "
              "server runs `--reasoning off`, which stops those values reaching the template at "
              "all. So the assertion is **a caller cannot break this server**, NOT that the "
              "template rejects anything.\n")
        bc = contract.get("bare_chat", {})
        ok = bool(bc.get("ok"))
        print("- Bare chat request answers: **%s**%s" % (
            "yes" if ok else "NO — server is up but useless",
            "" if ok else " — `%s`" % bc.get("error", bc.get("content", ""))))
        # `content` must be clean. reasoning_content being absent is NOT a failure — it only
        # means llama.cpp emitted no thought block at all, which is the point of --reasoning
        # off. What would be broken is a <think> tag leaking into content.
        leaked = [k for k, v in contract.items()
                  if isinstance(v, dict) and "<think>" in (v.get("content") or "")]
        print("- No `<think>` leaked into `content`: **%s**%s" % (
            "yes" if not leaked else "NO", "" if not leaked else " — %s" % ", ".join(leaked)))
        efforts = sorted(k[len("effort_"):] for k in contract if k.startswith("effort_"))
        for val in efforts:
            e = contract.get("effort_" + val, {})
            h = bool(e.get("harmless"))
            print("- `reasoning_effort: \"%s\"` handled safely: **%s**%s" % (
                val, "yes" if h else "NO",
                "" if h else " — %s" % (e.get("note") or e.get("error") or e.get("http", ""))))

    print("\n---\n*Generated by `summarize-sweep.py` from `%s`.*" % d)


if __name__ == "__main__":
    main()
