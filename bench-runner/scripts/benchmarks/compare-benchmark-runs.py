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


# Summary files the benchmarks write into their target directories.
SUMMARY_PATTERNS = ("openai-*-summary.json", "agent-summary.json", "ingest-summary.json")


def summaries(run_dir: Path) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for target in run_dir.iterdir():
        if not target.is_dir():
            continue
        if target.name in {"system-logs"}:
            continue
        summary = next((path for pattern in SUMMARY_PATTERNS for path in target.glob(pattern)), None)
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
    if metric == "prefill_median":
        return summary.get("prefill_tokens_per_second", {}).get("median")
    if metric == "decode_median":
        return summary.get("decode_tokens_per_second", {}).get("median")
    return None


def workload_metrics(summary: dict[str, Any]) -> dict[str, float | int | None]:
    """Per-preset and per-band (agent sessions) or per-depth (ingestion) figures."""
    metrics: dict[str, float | int | None] = {}
    for run in summary.get("runs") or []:
        label = run.get("spec")
        metrics[f"{label} session_wall_median"] = (run.get("session_wall_seconds") or {}).get("median")
        for band in run.get("bands") or []:
            metrics[f"{label} {band['band']} pp"] = band.get("prefill_tokens_per_second")
            metrics[f"{label} {band['band']} tg"] = band.get("decode_tokens_per_second")
    for depth in summary.get("by_depth") or []:
        label = depth.get("label")
        metrics[f"{label} pp_median"] = (depth.get("prefill_tokens_per_second") or {}).get("median")
        metrics[f"{label} prefill_s_median"] = (depth.get("prefill_seconds") or {}).get("median")
        metrics[f"{label} tg_median"] = (depth.get("decode_tokens_per_second") or {}).get("median")
    return metrics


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
    metrics = [
        "ok_count", "error_count", "wall_seconds", "throughput",
        "prefill_median", "decode_median", "latency_p95", "ttft_p95",
    ]
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
        old_detail = workload_metrics(base.get(name, {}))
        new_detail = workload_metrics(cand.get(name, {}))
        for metric in list(old_detail) + [key for key in new_detail if key not in old_detail]:
            old, new = old_detail.get(metric), new_detail.get(metric)
            lines.append(f"| {name} | {metric} | {fmt(old)} | {fmt(new)} | {fmt(pct_delta(old, new))} |")
    report = "\n".join(lines) + "\n"
    if args.output:
        Path(args.output).write_text(report, encoding="utf-8")
    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
