#!/usr/bin/env python3
"""Evaluate benchmark summaries and telemetry against JSON SLO thresholds."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from bench_common import dimm_summary


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def iter_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def metric(summary: dict[str, Any], name: str) -> float | int | None:
    if name == "error_count":
        return summary.get("error_count")
    return None


def telemetry_metrics(target_dir: Path, filename: str = "telemetry.jsonl") -> dict[str, Any]:
    mem_available: list[float] = []
    for record in iter_jsonl(target_dir / filename):
        mem = record.get("memory", {}).get("meminfo_kb", {})
        if isinstance(mem.get("MemAvailable"), (int, float)):
            mem_available.append(float(mem["MemAvailable"]) / 1024 / 1024)
    return {"min_memory_available_gib": min(mem_available) if mem_available else None}


def status_rank(status: str) -> int:
    return {"pass": 0, "warn": 1, "fail": 2}.get(status, 0)


def worse(a: str, b: str) -> str:
    return a if status_rank(a) >= status_rank(b) else b


def evaluate_telemetry_checks(telemetry: dict[str, Any], telemetry_rules: dict[str, Any]) -> tuple[str, list[dict[str, Any]]]:
    """Evaluate the free-memory warning against a telemetry summary.

    Shared by per-benchmark (client) and run-level (model server / target)
    evaluation so both apply the same rules.
    """
    status = "pass"
    checks: list[dict[str, Any]] = []

    memory = telemetry.get("min_memory_available_gib")
    if memory is not None:
        check_status = "warn" if memory <= telemetry_rules.get("min_memory_available_gib_warn", -1) else "pass"
        status = worse(status, check_status)
        checks.append({"name": "min_memory_available_gib", "value": memory, "status": check_status})

    return status, checks


def evaluate_benchmark(target_dir: Path, summary: dict[str, Any], rules: dict[str, Any], telemetry_rules: dict[str, Any]) -> dict[str, Any]:
    checks = []
    status = "pass"

    for key, limit in rules.items():
        if key.endswith("_max"):
            metric_name = key.removesuffix("_max")
            value = metric(summary, metric_name)
            check_status = "pass" if value is not None and value <= limit else "fail"
        elif key.endswith("_min"):
            metric_name = key.removesuffix("_min")
            value = metric(summary, metric_name)
            check_status = "pass" if value is not None and value >= limit else "fail"
        else:
            continue
        status = worse(status, check_status)
        checks.append({"name": key, "value": value, "limit": limit, "status": check_status})

    telemetry = telemetry_metrics(target_dir)
    tele_status, tele_checks = evaluate_telemetry_checks(telemetry, telemetry_rules)
    status = worse(status, tele_status)
    checks.extend(tele_checks)

    return {"name": target_dir.name, "status": status, "checks": checks, "telemetry": telemetry}


def evaluate_target_telemetry(run_dir: Path, telemetry_rules: dict[str, Any]) -> dict[str, Any]:
    """Evaluate the run-level model-server telemetry merged in by the host wrapper."""
    telemetry = telemetry_metrics(run_dir, "target-telemetry.jsonl")
    status, checks = evaluate_telemetry_checks(telemetry, telemetry_rules)
    return {"name": "model-server-target", "status": status, "checks": checks, "telemetry": telemetry}


# Summary files the benchmarks write into their target directories.
SUMMARY_PATTERNS = ("openai-*-summary.json", "agent-summary.json", "ingest-summary.json")


def evaluate_dimm_temperature(run_dir: Path, telemetry_rules: dict[str, Any]) -> dict[str, Any] | None:
    """The hottest DIMM against `dimm_temperature_c`: at 66 °C the BMC silently caps
    memory bandwidth, so a model with weights in system RAM runs slow."""
    records = iter_jsonl(run_dir / "bmc-telemetry.jsonl")
    if not records:
        return None
    dimm = dimm_summary(records)
    thresholds = telemetry_rules.get("dimm_temperature_c", {})
    value = dimm["hottest_dimm_max_c"]
    status = "pass"
    if value is not None and thresholds:
        if value >= thresholds.get("fail", 10**9):
            status = "fail"
        elif value >= thresholds.get("warn", 10**9):
            status = "warn"
    check = {"name": f"dimm_temperature:{dimm['hottest_dimm']}", "value": value, "limit": thresholds, "status": status}
    return {"name": "memory-dimms", "status": status, "checks": [check], "telemetry": dimm}


def find_summary(target_dir: Path) -> dict[str, Any] | None:
    for pattern in SUMMARY_PATTERNS:
        for candidate in target_dir.glob(pattern):
            return load_json(candidate)
    return None


def render_markdown(result: dict[str, Any]) -> str:
    lines = ["# SLO Report", "", f"Overall status: `{result['status']}`", ""]
    for bench in result["benchmarks"]:
        lines.append(f"## {bench['name']}")
        lines.append("")
        lines.append(f"Status: `{bench['status']}`")
        lines.append("")
        for check in bench["checks"]:
            lines.append(f"- `{check['name']}`: `{check.get('value')}` against `{check.get('limit', 'threshold')}` -> `{check['status']}`")
        lines.append("")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir")
    parser.add_argument("--slo-file", required=True)
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    slo = load_json(Path(args.slo_file))
    telemetry_rules = slo.get("telemetry", {})
    benchmarks = []
    overall = "pass"

    for target_dir in sorted(path for path in run_dir.iterdir() if path.is_dir()):
        summary = find_summary(target_dir)
        if not summary:
            continue
        rules = slo.get("benchmarks", {}).get(target_dir.name, {})
        result = evaluate_benchmark(target_dir, summary, rules, telemetry_rules)
        overall = worse(overall, result["status"])
        benchmarks.append(result)

    summary_count = len(benchmarks)

    # Run-level model-server telemetry, merged in by the host wrapper after the
    # benchmark finishes (absent during the suite's own in-container pass).
    if iter_jsonl(run_dir / "target-telemetry.jsonl"):
        target_result = evaluate_target_telemetry(run_dir, telemetry_rules)
        overall = worse(overall, target_result["status"])
        benchmarks.append(target_result)

    dimm_result = evaluate_dimm_temperature(run_dir, telemetry_rules)
    if dimm_result:
        overall = worse(overall, dimm_result["status"])
        benchmarks.append(dimm_result)

    # No benchmark summaries means nothing was actually benchmarked. Report that
    # as a failure rather than silently passing on an empty result set (target
    # telemetry alone does not count as a benchmark having run).
    if summary_count == 0:
        overall = "fail"

    output = {"status": overall, "slo_file": str(Path(args.slo_file)), "benchmarks": benchmarks}
    if summary_count == 0:
        output["error"] = "no benchmark summaries found to evaluate"
    (run_dir / "slo-report.json").write_text(json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (run_dir / "SLO.md").write_text(render_markdown(output), encoding="utf-8")
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0 if overall != "fail" else 1


if __name__ == "__main__":
    raise SystemExit(main())
