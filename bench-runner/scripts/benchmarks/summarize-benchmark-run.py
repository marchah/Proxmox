#!/usr/bin/env python3
"""Print a compact summary for one benchmark run directory."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def print_openai(run_dir: Path) -> None:
    for summary_path in run_dir.glob("*/openai-*-summary.json"):
        data = load_json(summary_path)
        if not data:
            continue
        label = data.get("label") or summary_path.parent.name
        latency = data.get("latency_total_seconds", {})
        ttft = data.get("ttft_seconds", {})
        print(f"{label}: ok={data.get('ok_count')}/{data.get('record_count')}")
        print(f"  wall={data.get('wall_seconds'):.2f}s aggregate_out_tok_s={data.get('aggregate_output_tokens_per_second'):.2f}")
        print(f"  latency_mean={latency.get('mean')} p95={latency.get('p95')}")
        print(f"  ttft_mean={ttft.get('mean')} p95={ttft.get('p95')}")
        pp = data.get("prefill_tokens_per_second", {})
        tg = data.get("decode_tokens_per_second", {})
        print(f"  pp_median_tok_s={pp.get('median')} tg_median_tok_s={tg.get('median')} source={data.get('rate_sources')}")


def print_workloads(run_dir: Path) -> None:
    for summary_path in sorted(run_dir.glob("*/agent-summary.json")):
        data = load_json(summary_path) or {}
        print(f"{summary_path.parent.name}: ok={data.get('ok_count')}/{data.get('record_count')} turns")
        for run in data.get("runs") or []:
            wall = run.get("session_wall_seconds") or {}
            print(f"  {run.get('spec')}: session wall median={wall.get('median')} s, cache misses={run.get('cache_misses')}")
            for band in run.get("bands") or []:
                print(f"    {band['band']}: pp={band.get('prefill_tokens_per_second')} tg={band.get('decode_tokens_per_second')} tok/s")
    for summary_path in sorted(run_dir.glob("*/ingest-summary.json")):
        data = load_json(summary_path) or {}
        print(f"{summary_path.parent.name}: ok={data.get('ok_count')}/{data.get('record_count')} requests")
        for depth in data.get("by_depth") or []:
            pp = depth.get("prefill_tokens_per_second") or {}
            tg = depth.get("decode_tokens_per_second") or {}
            print(f"  {depth.get('label')}: pp_median={pp.get('median')} tg_median={tg.get('median')} tok/s")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir")
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    if not run_dir.exists():
        raise SystemExit(f"Run directory not found: {run_dir}")

    print(f"Run: {run_dir}")
    print_openai(run_dir)
    print_workloads(run_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
