#!/usr/bin/env python3
"""Compare two benchmark run directories."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def summaries(run_dir: Path) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for target in run_dir.iterdir():
        if not target.is_dir():
            continue
        if target.name in {"system-logs"}:
            continue
        summary = next(target.glob("openai-*-summary.json"), None)
        data = load_json(summary) if summary else None
        if data:
            result[target.name] = data
    return result


def get_metric(summary: dict[str, Any], metric: str) -> float | int | None:
    if metric == "ok_count":
        return summary.get("ok_count")
    if metric == "error_count":
        return summary.get("error_count")
    if metric == "wall_seconds":
        return summary.get("wall_seconds")
    if metric == "throughput":
        return summary.get("aggregate_output_tokens_per_second")
    if metric == "latency_p95":
        return summary.get("latency_total_seconds", {}).get("p95")
    if metric == "ttft_p95":
        return summary.get("ttft_seconds", {}).get("p95")
    return None


def pct_delta(old: float | int | None, new: float | int | None) -> float | None:
    if old in (None, 0) or new is None:
        return None
    return ((float(new) - float(old)) / float(old)) * 100


def fmt(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    parser.add_argument("--output", help="Optional Markdown output path.")
    args = parser.parse_args()

    baseline = Path(args.baseline)
    candidate = Path(args.candidate)
    base = summaries(baseline)
    cand = summaries(candidate)
    metrics = ["ok_count", "error_count", "wall_seconds", "throughput", "latency_p95", "ttft_p95"]
    lines = [
        f"# Benchmark Comparison",
        "",
        f"- Baseline: `{baseline}`",
        f"- Candidate: `{candidate}`",
        "",
        "| Benchmark | Metric | Baseline | Candidate | Delta % |",
        "| --- | --- | ---: | ---: | ---: |",
    ]
    for name in sorted(set(base) | set(cand)):
        for metric in metrics:
            old = get_metric(base.get(name, {}), metric)
            new = get_metric(cand.get(name, {}), metric)
            lines.append(f"| {name} | {metric} | {fmt(old)} | {fmt(new)} | {fmt(pct_delta(old, new))} |")
    report = "\n".join(lines) + "\n"
    if args.output:
        Path(args.output).write_text(report, encoding="utf-8")
    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
