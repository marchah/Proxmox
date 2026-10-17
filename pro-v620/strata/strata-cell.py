#!/usr/bin/env python3
"""One strata-sweep.sh cell's result: adds a `placement` block to the probe's JSON.

strata-sweep.sh calls it after each loaded cell with the readings it took: VRAM, GTT and the
engine's per-card residency at load and after the probe, the container's memory, and the
paths of the cell's DIMM, GPU, row, concurrency and engine logs. It adds to the JSON:
- `vram_outside_mib`, the memory the engine asked to have in VRAM that sits elsewhere;
- `residency_missing`, the cards the cell runs on that had no requested and resident reading
  at a checkpoint (no evidence, so not a fit: the cell fails);
- `engine_faults`, the engine log's stall and non-finite lines (the cell fails);
- the expert cache per device, the decode hit rate and PCIe share, and phase utilization.

    strata-cell.py CELL.json LABEL SETTINGS LOAD_S CARDS VRAM GTT TOTAL VRAM_AFTER GTT_AFTER \\
        RES_LOAD RES_PROBE MEM CMDLINE DIMM_LOG GPU_LOG ROWS_LOG CONC_JSON CONC_SPAN ENGINE_LOG \\
        ACTIVE_GPUS
"""
import json
import pathlib
import re
import statistics
import sys


def residency_check(expected, readings):
    """(outside MiB or None, missing). `readings` is [(checkpoint, {pci: {requested, resident}})].

    Each card the cell runs on needs both counters at every checkpoint. A card without them is
    listed as missing and the outside figure is unknown (None), never a clean 0.
    """
    missing, outside = [], 0
    for checkpoint, res in readings:
        for card in expected:
            r = res.get(card) or {}
            if "requested" not in r or "resident" not in r:
                missing.append("%s at %s" % (card, checkpoint))
        for r in res.values():
            if "requested" in r and "resident" in r:
                outside = max(outside, r["requested"] - r["resident"])
    return (None if missing else outside), missing


def expert_caches(text):
    """{device: {"slots", "gib", "role"}} from the engine's start lines.

    The first card prints `expert cache N slots, G GiB of VRAM`. A layer split's later stage
    prints `layer split: CUDA1 runs layers a-b, expert cache N slots (G GiB)`, and an expert
    helper `CUDA1: N additional experts, G GiB`.
    """
    caches = {}
    m = re.search(r"expert cache (\d+) slots, ([\d.]+) GiB of VRAM", text)
    if m:
        caches["CUDA0"] = {"slots": int(m.group(1)), "gib": float(m.group(2)), "role": "first card"}
    for dev, slots, gib in re.findall(
            r"layer split: (CUDA\d+) runs layers \d+-\d+, expert cache (\d+) slots \(([\d.]+) GiB\)", text):
        caches[dev] = {"slots": int(slots), "gib": float(gib), "role": "layer split"}
    for dev, slots, gib in re.findall(r"(CUDA\d+): (\d+) additional experts, ([\d.]+) GiB", text):
        caches[dev] = {"slots": int(slots), "gib": float(gib), "role": "helper"}
    return caches


def maya_account(text):
    """Project Maya's account (../maya/), from the `glm fast:`, `glm stat:` and `glm spec:` lines.

    Each card prints `glm fast: CUDA<n> layers [a,b) expert pool G GB, x-y slots/layer (N total)`
    and `glm fast: CUDA<n> RAM tier G GB pinned, N slots`; each request with tokens prints one
    `glm stat:` line and, while drafting, one `glm spec:` line.
    """
    caches, ram = {}, {}
    for dev, a, b, gb, total in re.findall(
            r"glm fast: (CUDA\d+) layers \[(\d+),(\d+)\) expert pool ([\d.]+) GB, [^\n]*?\((\d+) total\)", text):
        caches[dev] = {"slots": int(total), "gb": float(gb), "role": "layers %s-%s" % (a, int(b) - 1)}
    for dev, gb, slots in re.findall(r"glm fast: (CUDA\d+) RAM tier ([\d.]+) GB pinned, (\d+) slots", text):
        ram[dev] = {"gb": float(gb), "slots": int(slots)}
    stats = [tuple(float(x) for x in m) for m in re.findall(
        r"glm stat: decode [\d.]+ ms/tok \(([\d.]+) tok/s\) \| vram hit ([\d.]+)% \| ram fetches ([\d.]+)/tok \| "
        r"disk ([\d.]+) reads/tok[^|]*\|[^|]*\| cpu lane ([\d.]+)/tok", text)]
    spec = [float(x) for x in re.findall(r"glm spec: \d+ of \d+ drafts accepted \(([\d.]+)%\)", text)]

    def median(i):
        xs = [s[i] for s in stats]
        return round(statistics.median(xs), 2) if xs else None
    return {
        "engine": "maya",
        "expert_caches": caches,
        "expert_cache_slots_total": sum(c["slots"] for c in caches.values()) if caches else None,
        "ram_tier": ram,
        "vram_free_loaded_mib": [int(x) for x in re.findall(r"(\d+) MiB of VRAM free with everything loaded", text)],
        "cpu_lane": re.findall(r"glm fast: (CUDA\d+ CPU lane: [^\n]{0,160})", text)[:2],
        "layer_split": re.findall(r"(glm split[^\n]{0,160})", text)[:4],
        "requests": len(stats),
        "decode_hit_pct_median": median(1),
        "decode_hit_pct_last": stats[-1][1] if stats else None,
        "ram_fetches_per_tok_median": median(2),
        "disk_reads_per_tok_max": max((s[3] for s in stats), default=None),
        "cpu_lane_per_tok_median": median(4),
        "spec_accept_pct_median": round(statistics.median(spec), 1) if spec else None,
        "pcie_share_pct_median": None,
        "draft_layer_mib": None,
        "stall_lines": len(re.findall(r"stall report|timed out at layer|no progress for", text)),
        "nonfinite_lines": len(re.findall(r"non-finite (?:logits|score)", text)),
        "warning_lines": [l for l in text.splitlines() if "WARNING" in l][:10],
    }


def engine_account(text):
    """The engine's own account of this start and of each request, from its log."""
    if "glm fast:" in text or "maya serve:" in text:
        return maya_account(text)

    def num(pattern, cast=float):
        m = re.search(pattern, text)
        return cast(m.group(1).replace(",", "")) if m else None
    hits = [float(x) for x in re.findall(r"decode expert cache hit rate: ([\d.]+)%", text)]
    pcie = [float(x) for x in re.findall(r"more read by the GPU over PCIe or from another GPU \(([\d.]+)% of all", text)]
    caches = expert_caches(text)
    return {
        "expert_caches": caches,
        "expert_cache_slots_total": sum(c["slots"] for c in caches.values()) if caches else None,
        "vram_free_loaded_mib": [int(x) for x in re.findall(r"(\d+) MiB of VRAM free with everything loaded", text)],
        "draft_layer_mib": num(r"draft layer loaded, (\d+) MiB of VRAM", int),
        "arena_load": (re.search(r"loaded ([\d.]+ GiB at [\d.]+ GiB/s)", text) or [None, None])[1],
        "pool": (re.search(r"(\d+ pool workers on logical processors [\d,]+)", text) or [None, None])[1],
        "layer_split": re.findall(r"(?i)(layers? \d+-\d+ on [^\n]{0,80})", text)[:4],
        "tail_skip_on": "STRATA_ROUTE_TAIL_SKIP=" in text and "is ON" in text,
        "requests": len(hits),
        "decode_hit_pct_median": round(statistics.median(hits), 1) if hits else None,
        "decode_hit_pct_last": hits[-1] if hits else None,
        "pcie_share_pct_median": round(statistics.median(pcie), 1) if pcie else None,
        "stall_lines": len(re.findall(r"stall report|timed out at layer|no progress for", text)),
        "nonfinite_lines": len(re.findall(r"non-finite logits", text)),
        "warning_lines": [l for l in text.splitlines() if "WARNING" in l][:10],
    }


def utilization(gpu_log, rows_log, conc_span, cards):
    """Medians of the 1 s GPU samples per phase: prefill, decode and concurrent streams."""
    samples = []
    if pathlib.Path(gpu_log).exists():
        for line in pathlib.Path(gpu_log).read_text().splitlines():
            f = line.split("\t")
            if len(f) == 8:
                samples.append((float(f[0]), f[1], *(int(x) for x in f[2:8])))
    windows = {"prefill": [], "decode": [], "streams": []}
    if pathlib.Path(rows_log).exists():
        for line in pathlib.Path(rows_log).read_text().splitlines():
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not (r.get("t0") and r.get("prompt_ms") is not None and r.get("predicted_ms") is not None):
                continue
            a, b = r["t0"], r["t0"] + r["prompt_ms"] / 1000
            if r.get("depth_target"):
                windows["prefill"].append((a, b))
            windows["decode"].append((b, b + r["predicted_ms"] / 1000))
    if len(conc_span.split()) == 2:
        windows["streams"].append(tuple(float(x) for x in conc_span.split()))
    util = {}
    for phase, wins in windows.items():
        inside = [s for s in samples if any(a <= s[0] <= b for a, b in wins)]
        if not inside:
            continue
        u = {"samples": len(inside)}
        for card in sorted({s[1] for s in inside} & set(cards)):
            cs = [s for s in inside if s[1] == card]
            busy = [s[2] for s in cs if s[2] >= 0]
            mbusy = [s[3] for s in cs if s[3] >= 0]
            u[card] = {"busy_pct": statistics.median(busy) if busy else None,
                       "mem_busy_pct": statistics.median(mbusy) if mbusy else None,
                       "sclk_mhz": statistics.median(s[4] for s in cs),
                       "power_w": statistics.median(s[5] for s in cs),
                       "junction_max_c": max(s[6] for s in cs)}
        first = inside[0][1]
        seq = sorted((s[0], s[7]) for s in samples if s[1] == first)
        rates = [(c2 - c1) / 1e6 / (t2 - t1) for (t1, c1), (t2, c2) in zip(seq, seq[1:])
                 if t2 > t1 and any(a <= t2 <= b for a, b in wins)]
        u["cpu_cores"] = round(statistics.median(rates), 1) if rates else None
        util[phase] = u
    return util


def main(argv):
    (path, label, settings, load_s, cards, vs, gs, ts, pvs, pgs, res_load, res_probe, mem, cmdline,
     dimm_log, gpu_log, rows_log, conc_path, conc_span, engine_log, active_gpus) = argv[1:22]
    cards = cards.split(",")
    vs, gs, ts, pvs, pgs = ([int(x) for x in s.split()] for s in (vs, gs, ts, pvs, pgs))
    res_load, res_probe = json.loads(res_load or "{}"), json.loads(res_probe or "{}")
    p = pathlib.Path(path)
    try:
        d = json.loads(p.read_text())
    except Exception as e:
        d = {"error": "probe produced no parsable output: %r" % (e,)}
    cell = json.loads(settings)
    # The cards the cell runs on (its MODEL_GPUS); a passed-through card it leaves unused
    # needs no reading. Without MODEL_GPUS, every card the container holds.
    expected = [c.strip().lower() for c in active_gpus.split(",") if c.strip()] or cards
    held = [c for c in cards if (res_load.get(c) or {}).get("requested", 0) > 1024]
    outside, missing = residency_check(expected, [("load", res_load), ("probe", res_probe)])
    pl = {
        "label": label, "cell": cell, "gpus": len(held), "load_s": int(load_s), "cards": cards,
        "cards_held": held, "cards_expected": expected,
        "vram_total_mib": sum(vs), "vram_free_for_a_guest_mib": sum(t - v for t, v in zip(ts, vs)),
        "vram_free_after_probe_mib": sum(t - v for t, v in zip(ts, pvs)),
        "vram_outside_mib": outside,
        "residency_missing": missing,
        "possible_gtt_spill": (outside is not None and outside > 64) or any(b - a > 256 for a, b in zip(gs, pgs)),
        "residency_at_load": res_load, "residency_after_probe": res_probe,
        "server_cmdline": cmdline.strip() or None,
    }
    if len(held) == 1:
        pl["active_card"] = held[0]
    pl["ct_mem_mib"], pl["ct_anon_mib"], pl["ct_file_mib"] = (int(x) for x in mem.split())
    for i, name in enumerate(("gpu1", "gpu2")):
        if i < len(cards):
            pl[name + "_vram_mib"], pl[name + "_gtt_mib"], pl[name + "_card_mib"] = vs[i], gs[i], ts[i]
            pl[name + "_vram_after_probe_mib"], pl[name + "_gtt_after_probe_mib"] = pvs[i], pgs[i]
    temps = []
    if pathlib.Path(dimm_log).exists():
        for line in pathlib.Path(dimm_log).read_text().splitlines():
            f = line.split("\t")
            if len(f) == 2 and f[1].strip().isdigit() and int(f[1]) > 0:
                temps.append(int(f[1]))
    pl["dimm_max_c"] = max(temps) if temps else None
    pl["dimm_samples"] = len(temps)
    pl["dimm_samples_at_cap"] = sum(1 for t in temps if t >= 66)
    conc = pathlib.Path(conc_path)
    if conc.exists():
        try:
            c = json.loads(conc.read_text())
            pl["concurrency"] = {k: c.get(k) for k in ("streams", "total_slots", "n_ctx_per_slot",
                                 "per_stream_tps", "aggregate_tps", "wall_aggregate_tps",
                                 "any_degenerate", "total_failed", "accept_pct", "reps", "complete_rounds")}
        except Exception as e:
            pl["concurrency"] = {"error": "unparsable: %r" % (e,)}
    text = pathlib.Path(engine_log).read_text(errors="replace") if pathlib.Path(engine_log).exists() else ""
    pl["strata"] = engine_account(text)
    pl["engine_faults"] = pl["strata"]["stall_lines"] + pl["strata"]["nonfinite_lines"]
    pl["utilization"] = utilization(gpu_log, rows_log, conc_span, held or cards)
    # A stalled or non-finite engine, or a fit nobody measured, is not a usable result: the
    # measurements stay in the file, the cell does not pass.
    if pl["engine_faults"] or missing:
        d["probe_ok"] = False
    d["placement"] = pl
    p.write_text(json.dumps(d, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
