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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir")
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    if not run_dir.exists():
        raise SystemExit(f"Run directory not found: {run_dir}")

    print(f"Run: {run_dir}")
    print_openai(run_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
