#!/usr/bin/env python3
"""Markdown tables from one phase of the Vulkan/ROCm A/B.

    summarize.py <results/phase-dir>

Each cell is the median over rounds, with the min-max range across rounds in brackets.
A round's value is llama-bench's own mean over its 3 repetitions. The delta compares the
two setups' medians.
"""
import csv
import glob
import json
import os
import re
import statistics as st
import sys

MODELS = {"Qwen3.6-35B-A3B-UD-Q5_K_XL": "Qwen3.6-35B-A3B (MoE)", "Qwen3.8-27B-UD-Q5_K_XL": "Qwen3.8-27B (dense)"}


def rounds(phase_dir):
    out = {}
    for d in sorted(glob.glob(os.path.join(phase_dir, "r*-*"))):
        m = re.fullmatch(r"r(\d+)-([ABC])", os.path.basename(d))
        if m:
            out.setdefault(m.group(2), {})[int(m.group(1))] = d
    return out


def jsonl(path, prefix="{"):
    rows = []
    for p in path if isinstance(path, list) else [path]:
        if os.path.exists(p):
            for line in open(p):
                line = line.strip()
                if line.startswith(prefix):
                    rows.append(json.loads(line))
    return rows


def fmt(vals, digits=1):
    if not vals:
        return "—"
    med = st.median(vals)
    if len(vals) == 1:
        return f"{med:.{digits}f}"
    return f"{med:.{digits}f} [{min(vals):.{digits}f}–{max(vals):.{digits}f}]"


def delta(a, b):
    if not a or not b:
        return "—"
    return f"{(st.median(b) / st.median(a) - 1) * 100:+.1f}%"


def bench_cells(dirs, model):
    cells = {}
    for d in dirs.values():
        for r in jsonl(os.path.join(d, f"{model}.bench.jsonl")):
            test = f"pp{r['n_prompt']}" if r["n_prompt"] else f"tg{r['n_gen']}"
            cells.setdefault((test, r["n_depth"]), []).append(r["avg_ts"])
    return cells


def batched_cells(dirs, model):
    cells = {}
    for d in dirs.values():
        rows = jsonl([os.path.join(d, f"{model}.batched.jsonl"), os.path.join(d, f"{model}.batched.log")], '{"n_kv_max"')
        for r in rows:
            cells.setdefault(("tg", r["pl"]), []).append(r["speed_tg"])
            cells.setdefault(("pp", r["pl"]), []).append(r["speed_pp"])
    return cells


def ppl(dirs, model):
    """'<ppl> ± <err>', 'NaN from chunk N', or None when the gate did not run."""
    for _, d in sorted(dirs.items()):
        p = os.path.join(d, f"{model}.ppl.log")
        if os.path.exists(p):
            s = open(p).read()
            m = re.search(r"Final estimate: PPL = ([\d.]+) \+/- ([\d.]+)", s)
            if m:
                return f"{float(m.group(1)):.4f} ± {float(m.group(2)):.4f}"
            bad = re.search(r"\[(\d+)\](?:nan|-?inf)", s)
            return f"NaN from chunk {bad.group(1)}" if bad else "failed"
    return None


def telemetry(dirs):
    peak_j, peak_m, power, sclk, gtt = [], [], [], [], []
    for d in dirs.values():
        p = os.path.join(d, "telemetry.csv")
        if not os.path.exists(p):
            continue
        rows = list(csv.DictReader(open(p)))
        num = lambda r, k: float(r[k]) if r.get(k) not in (None, "") else None
        js = [num(r, "junction") for r in rows if num(r, "junction") is not None]
        ms = [num(r, "mem") for r in rows if num(r, "mem") is not None]
        if js:
            peak_j.append(max(js) / 1000)
        if ms:
            peak_m.append(max(ms) / 1000)
        busy = [r for r in rows if (num(r, "busy") or 0) >= 90]
        pw = [num(r, "power_avg") or num(r, "power_in") for r in busy]
        pw = [x / 1e6 for x in pw if x]
        if pw:
            power.append(st.median(pw))
        sc = [num(r, "sclk") / 1e6 for r in busy if num(r, "sclk")]
        if sc:
            sclk.append(st.median(sc))
        gs = [num(r, "gtt_used") / 2**20 for r in rows if num(r, "gtt_used") is not None]
        if gs:
            gtt.append(max(gs) - min(gs))
    return peak_j, peak_m, power, sclk, gtt


def main():
    phase_dir = sys.argv[1]
    runs = rounds(phase_dir)
    setups = sorted(runs)
    if len(setups) != 2:
        sys.exit(f"expected two setups in {phase_dir}, found {setups}")
    x, y = setups
    print(f"# Phase {os.path.basename(phase_dir.rstrip('/'))}: {x} vs {y}\n")

    print("| | " + " | ".join(setups) + " |\n| --- | --- | --- |")
    metas = {s: json.load(open(os.path.join(runs[s][min(runs[s])], "meta.json"))) for s in setups}
    for k in ("host", "kernel", "amdgpu", "mesa", "rocm", "llamacpp", "device", "od_vddgfx_offset", "power_cap_w"):
        print(f"| {k} | " + " | ".join(str(metas[s].get(k, "")).replace("|", "/") for s in setups) + " |")
    print(f"| rounds | " + " | ".join(str(len(runs[s])) for s in setups) + " |\n")

    for model, label in MODELS.items():
        print(f"## {label}\n")
        bx, by = bench_cells(runs[x], model), bench_cells(runs[y], model)
        print(f"llama-bench, tok/s:\n\n| test | depth | {x} | {y} | {y} vs {x} |\n| --- | ---: | ---: | ---: | ---: |")
        for key in sorted(set(bx) | set(by), key=lambda k: (k[0][:2] != "pp", k[1])):
            print(f"| {key[0]} | {key[1]} | {fmt(bx.get(key))} | {fmt(by.get(key))} | {delta(bx.get(key), by.get(key))} |")
        cx, cy = batched_cells(runs[x], model), batched_cells(runs[y], model)
        print(f"\nllama-batched-bench (pp512 + tg128 per sequence), aggregate tok/s:\n\n"
              f"| phase | parallel | {x} | {y} | {y} vs {x} |\n| --- | ---: | ---: | ---: | ---: |")
        for key in sorted(set(cx) | set(cy), key=lambda k: (k[0] != "tg", k[1])):
            print(f"| {key[0]} | {key[1]} | {fmt(cx.get(key))} | {fmt(cy.get(key))} | {delta(cx.get(key), cy.get(key))} |")
        px, py = ppl(runs[x], model), ppl(runs[y], model)
        print(f"\nPerplexity, wikitext-2, 40 × 2048: {x} {px or '—'}, {y} {py or '—'}\n")

    print(f"## Card telemetry\n\nPer round: peak temps, then medians while the card is ≥90% busy.\n\n"
          f"| | {x} | {y} |\n| --- | ---: | ---: |")
    tx, ty = telemetry(runs[x]), telemetry(runs[y])
    for i, k in enumerate(("peak junction °C", "peak memory °C", "power W", "sclk MHz", "GTT growth MiB")):
        print(f"| {k} | {fmt(tx[i], 0)} | {fmt(ty[i], 0)} |")


if __name__ == "__main__":
    main()
