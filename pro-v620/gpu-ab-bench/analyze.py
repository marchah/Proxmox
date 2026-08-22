#!/usr/bin/env python3
"""Join llama-bench results with the per-phase slice of the host GPU telemetry."""
import glob, json, os, statistics as st, sys

OUT = os.environ.get("BENCH_DIR", "/root/gpu-ab-bench")
LBL = {"gpu1": "GPU 1  2d:00.0 PCIe-1/CPU  CT120", "gpu2": "GPU 2  06:00.0 PCIe-3/chipset CT123"}


def load_phases():
    with open("%s/phases.jsonl" % OUT) as fh:
        return [json.loads(l) for l in fh if l.strip()]


def load_telemetry():
    rows = []
    with open("%s/telemetry.jsonl" % OUT) as fh:
        for l in fh:
            try:
                rows.append(json.loads(l))
            except Exception:
                pass
    return rows


def slice_tel(tel, gpu, t0, t1):
    return [r[gpu] for r in tel if t0 <= r["ts"] <= t1], [r["fan_hub"] for r in tel if t0 <= r["ts"] <= t1]


def peaks(samples, fans):
    busy = [s["busy_pct"] for s in samples if s.get("busy_pct") is not None]
    hot = [s for s in samples if (s.get("busy_pct") or 0) > 50]  # only loaded samples
    src = hot or samples
    def mx(k):
        v = [s[k] for s in src if s.get(k) is not None]
        return max(v) if v else None
    def av(k):
        v = [s[k] for s in src if s.get(k) is not None]
        return round(st.mean(v), 1) if v else None
    return {
        "edge_max": mx("edge_c"), "junction_max": mx("junction_c"), "mem_max": mx("mem_c"),
        "power_max": mx("power_w"), "power_avg": av("power_w"),
        "sclk_max": mx("sclk_mhz"), "sclk_avg": av("sclk_mhz"), "mclk_max": mx("mclk_mhz"),
        "busy_max": max(busy) if busy else None,
        "vram_max_gib": round(mx("vram_used") / 1024**3, 2) if mx("vram_used") else None,
        "gtt_max_gib": round(mx("gtt_used") / 1024**3, 2) if mx("gtt_used") else None,
        "link": "%s x%s" % (src[-1].get("link_speed"), src[-1].get("link_width")) if src else None,
        "fan_pwm_max": max([f["pwm_pct"] for f in fans], default=None),
        "fan_rpm_max": max([f["rpm"] for f in fans if f["rpm"] is not None], default=None),
        "loaded_samples": len(hot),
    }


def bench_rows(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return []
    with open(path) as fh:
        try:
            data = json.load(fh)
        except Exception:
            return []
    rows = []
    for e in data:
        name = "pp%d" % e["n_prompt"] if e["n_prompt"] else "tg%d" % e["n_gen"]
        if e.get("n_depth"):
            name += "@d%d" % e["n_depth"]
        rows.append({
            "test": name, "tps": e["avg_ts"], "stddev": e["stddev_ts"],
            "samples": len(e.get("samples_ns", [])) or e.get("reps"),
            "build": "%s(%s)" % (e.get("build_number"), (e.get("build_commit") or "")[:9]),
        })
    return rows


def main():
    phases, tel = load_phases(), load_telemetry()
    results = {}   # (phase_group, test) -> {gpu: [tps,...]}
    print("PER-PHASE DETAIL")
    print("=" * 108)
    for p in phases:
        tag = "%s.%s" % (p["phase"], p["gpu"])
        rows = bench_rows("%s/%s.json" % (OUT, tag))
        s, f = slice_tel(tel, p["gpu"], p["start"], p["end"])
        pk = peaks(s, f)
        dur = p["end"] - p["start"]
        print("\n%-14s %-42s  rc=%s  %.0fs" % (p["phase"], LBL[p["gpu"]], p["rc"], dur))
        if not rows:
            print("   (no results — see %s.err)" % tag)
        for r in rows:
            print("   %-14s %8.2f t/s  ± %5.2f   n=%s" % (r["test"], r["tps"], r["stddev"], r["samples"]))
            group = p["phase"].split("-r")[0]
            results.setdefault((group, r["test"]), {}).setdefault(p["gpu"], []).append(r["tps"])
        print("   temps  edge %.0f / junction %.0f / mem %.0f C   power %.0f W peak (%.0f avg)"
              % (pk["edge_max"] or 0, pk["junction_max"] or 0, pk["mem_max"] or 0,
                 pk["power_max"] or 0, pk["power_avg"] or 0))
        print("   clocks sclk %.0f MHz peak (%.0f avg) / mclk %.0f   busy %s%%   vram %.2f GiB   gtt %.2f GiB"
              % (pk["sclk_max"] or 0, pk["sclk_avg"] or 0, pk["mclk_max"] or 0,
                 pk["busy_max"], pk["vram_max_gib"] or 0, pk["gtt_max_gib"] or 0))
        print("   link   %s      fan hub %.0f%% / %s RPM" % (pk["link"], pk["fan_pwm_max"] or 0, pk["fan_rpm_max"]))

    print("\n\nA/B SUMMARY  (mean of round means; GPU2 relative to GPU1)")
    print("=" * 108)
    print("%-22s %14s %14s %12s   %s" % ("test", "GPU 1 t/s", "GPU 2 t/s", "delta", "rounds (g1 | g2)"))
    print("-" * 108)
    for (group, test), by in sorted(results.items()):
        g1, g2 = by.get("gpu1", []), by.get("gpu2", [])
        if not (g1 and g2):
            continue
        m1, m2 = st.mean(g1), st.mean(g2)
        d = (m2 - m1) / m1 * 100.0
        print("%-22s %14.2f %14.2f %+11.1f%%   %s | %s"
              % ("%s %s" % (group, test), m1, m2, d,
                 ",".join("%.1f" % x for x in g1), ",".join("%.1f" % x for x in g2)))


if __name__ == "__main__":
    main()
