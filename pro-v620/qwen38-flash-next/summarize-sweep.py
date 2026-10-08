#!/usr/bin/env python3
"""Reduce a placement-sweep output directory to one Markdown table.

Rows are configs: an n_cpu_moe placement, plus a --moe-cache-mib size when the sweep set
one. The point of the table is the trade the sweep exists to settle: VRAM handed back to a
second model versus decode lost. So "free VRAM" sits next to the decode medians, and the
versatility column is decode per GB given up. Cache rows add the decode hit rate, and every
row its hottest DIMM, since the BMC caps memory bandwidth at 66 °C.
"""
import json, pathlib, statistics, sys


def med(xs):
    return round(statistics.median(xs), 1) if xs else None


def main():
    d = pathlib.Path(sys.argv[1])
    manifest, manifest_error = {}, None
    mp = d / "manifest.json"
    if mp.exists():
        try:
            manifest = json.loads(mp.read_text())
        except Exception as e:
            manifest_error = e

    # Group the per-round files by cell: its label, or for sweeps that predate labels its
    # placement plus cache spec.
    by, prompt_tokens = {}, {}
    contract = None
    for f in sorted(d.glob("*-r*.json")):
        try:
            j = json.loads(f.read_text())
        except Exception:
            continue
        pl = j.get("placement") or {}
        if pl.get("label"):
            key = pl["label"]
        elif pl.get("n_cpu_moe") is not None:
            key = (pl["n_cpu_moe"], pl.get("moe_cache_spec") or "")
        else:
            continue
        g = by.setdefault(key, {"decode": {}, "prefill": {}, "vram": [], "free": [],
                                "gtt": [], "spill": False, "degen": False,
                                "disagree": False, "errors": 0, "cache_mib": [],
                                "hit": [], "dimm": [], "capped": 0, "cache_inactive": 0,
                                "shas": {}, "load_failed": 0, "load_s": [], "gpus": None,
                                "cell": pl.get("cell"), "conc": [], "mem": []})
        if pl.get("load_failed"):
            g["load_failed"] += 1
            continue
        if j.get("error"):
            g["errors"] += 1
        if pl.get("load_s") is not None:
            g["load_s"].append(pl["load_s"])
        g["gpus"] = pl.get("gpus", g["gpus"])
        if pl.get("ct_mem_mib"):
            g["mem"].append((pl["ct_mem_mib"], pl["ct_anon_mib"], pl["ct_file_mib"]))
        if pl.get("concurrency"):
            g["conc"].append(pl["concurrency"])
        g["vram"].append(pl.get("vram_total_mib") or 0)
        g["free"].append(pl.get("vram_free_for_a_guest_mib") or 0)
        g["gtt"].append(max(pl.get("gpu1_gtt_mib") or 0, pl.get("gpu2_gtt_mib") or 0))
        g["spill"] |= bool(pl.get("possible_gtt_spill"))
        g["degen"] |= bool(j.get("any_degenerate"))
        g["disagree"] |= (j.get("all_reps_agree") is False)
        if pl.get("moe_cache_spec"):
            mc = pl.get("moe_cache") or {}
            g["cache_mib"].append(pl.get("moe_cache_mib") or 0)
            if (mc.get("small") or {}).get("hit_rate_pct") is not None:
                g["hit"].append(mc["small"]["hit_rate_pct"])
            # The size line is printed only when the cache is allocated.
            if (pl.get("moe_cache_mib") or 0) > 0 and "size_mib" not in mc:
                g["cache_inactive"] += 1
        if pl.get("dimm_max_c"):
            g["dimm"].append(pl["dimm_max_c"])
        g["capped"] += pl.get("dimm_samples_at_cap") or 0
        for k, v in (j.get("summary") or {}).items():
            if v.get("prompt_n"):
                prompt_tokens.setdefault(k.split("/")[0], []).append(v["prompt_n"])
            # Each pass is one rep; the reps of a cell are its passes.
            if v.get("sha"):
                g["shas"].setdefault(k, set()).add(v["sha"])
            if v.get("decode_tps_median"):
                g["decode"].setdefault(k, []).append(v["decode_tps_median"])
            if v.get("prefill_tps_median"):
                g["prefill"].setdefault(k, []).append(v["prefill_tps_median"])
        if contract is None and j.get("contract"):
            contract = j["contract"]

    if not by:
        print("No parsable sweep results in %s" % d)
        return

    order = [c["label"] for c in manifest.get("cells") or []]
    def sort_key(key):
        if isinstance(key, str):
            return (0, order.index(key) if key in order else len(order), key)
        return (1, key)
    keys = sorted(by, key=sort_key)
    cells = sorted({k for g in by.values() for k in g["decode"]})
    depths = sorted({c.split("/")[0] for c in cells},
                    key=lambda s: int(s.lstrip("d")))

    print("# Qwen3.8-Flash-Next placement sweep\n")
    if manifest_error:
        print("⚠️ `manifest.json` is unreadable (%s), so the run header is missing.\n" % manifest_error)
    if manifest:
        print("`ctx %s` · `parallel %s` · `%s reps` · `n_predict %s` · depths `%s` · "
              "%s · %s GiB host RAM · llama.cpp `%s`\n" % (
                  manifest.get("ctx"), manifest.get("parallel"), manifest.get("reps"),
                  manifest.get("n_predict"), manifest.get("depths"),
                  ("%d cells" % len(manifest["cells"])) if manifest.get("cells")
                  else ("ONE GPU" if manifest.get("one_gpu") else "two GPUs"),
                  manifest.get("host_ram_gib"),
                  str(manifest.get("llamacpp_dir", "")).rsplit("/", 1)[-1]))
        if manifest.get("drop_caches"):
            print("Every load was cold: the host page cache was dropped before each one.\n")
        if manifest.get("probe_classes"):
            print("Prompt classes: `%s` only.\n" % manifest["probe_classes"])
    # A depth label is the probe's target; the filler tokenizes at about 5.5 characters per
    # token, so d8000 is a ~5,800-token prompt. Quote the measured size, not the label.
    if any(dep != "d0" for dep in prompt_tokens):
        print("Measured prompt tokens per depth label, median: " + " · ".join(
            "%s = %d" % (dep, statistics.median(prompt_tokens[dep]))
            for dep in depths if dep in prompt_tokens) + "\n")

    def label(key):
        if isinstance(key, str):
            mib = med(by[key]["cache_mib"])
            return key + (" (cache %d MiB)" % mib if mib else "")
        n, spec = key
        if not spec:
            return "%d" % n
        mib = med(by[key]["cache_mib"])
        how = {"auto": " (auto)"}.get(spec, " (leaves %s MiB free)" % spec[5:] if spec.startswith("leave") else "")
        return "%d + cache %s MiB%s" % (n, "%d" % mib if mib is not None else "?", how)

    # --- the cells ----------------------------------------------------------------
    if any(isinstance(k, str) for k in keys):
        print("Load time to `/health`; container memory after load, median GiB: total "
              "(anonymous / page cache).\n")
        print("| cell | settings | GPUs | load, s | container memory, GiB |")
        print("|---|---|---:|---:|---:|")
        for key in keys:
            g = by[key]
            settings = " ".join("%s=%s" % kv for kv in (g["cell"] or {}).items())
            mem = "—"
            if g["mem"]:
                cur, anon, fil = (med([m[i] / 1024 for m in g["mem"]]) for i in range(3))
                mem = "%.1f (%.1f / %.1f)" % (cur, anon, fil)
            print("| %s | `%s` | %s | %s | %s |" % (key, settings or "-", g["gpus"] if g["gpus"] is not None else "—",
                                                  "%.0f" % med(g["load_s"]) if g["load_s"] else "—", mem))
        print()

    # --- the decision table -------------------------------------------------------
    hdr = (["config", "VRAM used", "free for a guest", "max GTT", "decode hit rate",
            "hottest DIMM"] + ["decode " + c for c in cells] + ["flags"])
    print("| " + " | ".join(hdr) + " |")
    print("|" + "|".join(["---"] * len(hdr)) + "|")

    base_free = None
    rows_for_tradeoff = []
    for key in keys:
        g = by[key]
        vram = med(g["vram"]) or 0
        free = med(g["free"]) or 0
        flags = []
        if g["spill"]:
            flags.append("⚠️ GTT spill")
        if g["degen"]:
            flags.append("🔴 degenerate output")
        split = sorted(k for k, s in g["shas"].items() if len(s) > 1)
        if g["disagree"] or split:
            flags.append("⚠️ reps disagree" + (" (%s)" % ", ".join(split) if split else ""))
        if g["errors"]:
            flags.append("🔴 %d probe error(s)" % g["errors"])
        if g["load_failed"]:
            flags.append("🔴 load failed in %d run(s)" % g["load_failed"])
        if g["cache_inactive"]:
            flags.append("🔴 cache not active in %d run(s)" % g["cache_inactive"])
        if g["capped"]:
            flags.append("🔴 DIMM at 66 °C in %d sample(s): bandwidth capped, row invalid" % g["capped"])
        cellvals = [med(g["decode"].get(c, [])) for c in cells]
        hit = med(g["hit"])
        print("| %s | %.1f GiB | **%.1f GiB** | %d MiB | %s | %s | %s | %s |" % (
            label(key), vram / 1024, free / 1024, med(g["gtt"]) or 0,
            ("%.1f%%" % hit) if hit is not None else "—",
            ("%d °C" % max(g["dimm"])) if g["dimm"] else "—",
            " | ".join("%.1f" % v if v else "—" for v in cellvals),
            ", ".join(flags) or "ok"))
        overall = [v for v in cellvals if v]
        if overall:
            rows_for_tradeoff.append((label(key), free / 1024, med(overall)))

    # --- what it decides ----------------------------------------------------------
    if len(rows_for_tradeoff) >= 2:
        # the fastest placement is the reference; everything else trades decode for VRAM
        ref = max(rows_for_tradeoff, key=lambda r: r[2])
        print("\n## The trade, against the fastest placement\n")
        print("Reference: `%s` at **%.1f t/s** with %.1f GiB free.\n"
              % (ref[0], ref[2], ref[1]))
        print("| config | decode | vs fastest | extra VRAM freed | cost per GB freed |")
        print("|---|---:|---:|---:|---:|")
        for n, free, dec in rows_for_tradeoff:
            dgb = free - ref[1]
            loss = dec - ref[2]
            per = ("%.2f t/s per GiB" % (abs(loss) / dgb)) if dgb > 0.05 else "—"
            print("| %s | %.1f t/s | %+.1f%% | %+.1f GiB | %s |" % (
                n, dec, 100.0 * loss / ref[2] if ref[2] else 0, dgb, per))

    # --- depth effect -------------------------------------------------------------
    if len(depths) > 1:
        print("\n## Decode versus context depth\n")
        print("The QSA indexer rescored block summaries over the whole cached context "
              "every token until llama.cpp #28699 (an open draft), so depth is a real "
              "axis here — a short-prompt number is not this model's throughput.\n")
        print("| config | " + " | ".join(depths) + " |")
        print("|" + "|".join(["---"] * (len(depths) + 1)) + "|")
        for key in keys:
            g = by[key]
            vals = []
            for dep in depths:
                xs = [v for c, vv in g["decode"].items() if c.startswith(dep + "/") for v in vv]
                vals.append("%.1f" % med(xs) if xs else "—")
            print("| %s | %s |" % (label(key), " | ".join(vals)))

    # --- prefill ------------------------------------------------------------------
    deep = [dep for dep in depths if dep != "d0"]
    if deep:
        print("\n## Prefill versus context depth\n")
        print("Prefill is this model's binding constraint. The MoE cache serves only batches "
              "of up to 32 tokens, so a cache row's prefill shows what its extra CPU layers "
              "cost.\n")
        print("| config | " + " | ".join("prefill " + dep for dep in deep) + " |")
        print("|" + "|".join(["---"] * (len(deep) + 1)) + "|")
        for key in keys:
            g = by[key]
            vals = []
            for dep in deep:
                xs = [v for c, vv in g["prefill"].items() if c.startswith(dep + "/") for v in vv]
                vals.append("%.1f" % med(xs) if xs else "—")
            print("| %s | %s |" % (label(key), " | ".join(vals)))

    # --- concurrency --------------------------------------------------------------
    if any(by[k]["conc"] for k in keys):
        print("\n## Concurrency\n")
        print("Medians across passes. Per-stream is what one user sees; aggregate is the "
              "box's throughput; wall aggregate includes the slowest stream's tail.\n")
        print("| cell | streams | slots | ctx/slot | per-stream t/s | aggregate t/s | wall aggregate t/s | flags |")
        print("|---|---:|---:|---:|---:|---:|---:|---|")
        for key in keys:
            c = [x for x in by[key]["conc"] if "error" not in x]
            failed = len(by[key]["conc"]) - len(c)
            if not by[key]["conc"]:
                continue
            if not c:
                print("| %s | | | | | | | 🔴 probe failed in %d pass(es) |" % (label(key), failed))
                continue
            f = ["🔴 probe failed in %d pass(es)" % failed] if failed else []
            if any(x.get("any_degenerate") for x in c):
                f.append("🔴 degenerate")
            if any(x.get("total_failed") for x in c):
                f.append("🔴 failed requests")
            if any((x.get("total_slots") or 0) < (x.get("streams") or 0) for x in c):
                f.append("⚠️ fewer slots than streams")
            print("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
                label(key), c[0].get("streams"), c[0].get("total_slots"), c[0].get("n_ctx_per_slot"),
                med([x["per_stream_tps"] for x in c if x.get("per_stream_tps")]),
                med([x["aggregate_tps"] for x in c if x.get("aggregate_tps")]),
                med([x["wall_aggregate_tps"] for x in c if x.get("wall_aggregate_tps")]),
                ", ".join(f) or "ok"))

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
