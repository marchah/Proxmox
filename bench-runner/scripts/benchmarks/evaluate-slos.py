#!/usr/bin/env python3
"""Evaluate benchmark summaries and telemetry against JSON SLO thresholds."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


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
    if name == "latency_p95_seconds":
        return summary.get("latency_total_seconds", {}).get("p95")
    if name == "ttft_p95_seconds":
        return summary.get("ttft_seconds", {}).get("p95")
    if name == "aggregate_output_tokens_per_second":
        return summary.get("aggregate_output_tokens_per_second")
    return None


def temperature_sensor_name(group: str, item: dict[str, Any]) -> str:
    if group == "nvidia":
        name = item.get("name") or item.get("index") or "gpu"
        return f"nvidia {name} gpu"
    if group == "thermal_zone":
        return f"thermal {item.get('type') or item.get('name') or 'unknown'}"
    chip = item.get("chip") or "unknown"
    label = item.get("label") or item.get("sensor") or "temp"
    if chip == "amdgpu":
        return f"amdgpu {label}"
    if chip == "k10temp":
        return f"cpu {label}"
    if chip == "nvme":
        return f"nvme {label}"
    return f"{chip} {label}"


def collect_temperatures_by_sensor(record: dict[str, Any]) -> dict[str, float]:
    temps: dict[str, float] = {}
    for item in record.get("temperature", {}).get("thermal_zones", []):
        if isinstance(item.get("temp_c"), (int, float)):
            temps[temperature_sensor_name("thermal_zone", item)] = float(item["temp_c"])
    for item in record.get("temperature", {}).get("hwmon", []):
        if isinstance(item.get("temp_c"), (int, float)):
            temps[temperature_sensor_name("hwmon", item)] = float(item["temp_c"])
    for gpu in record.get("gpu", {}).get("nvidia_smi", []):
        temp = gpu.get("temperature_gpu")
        if isinstance(temp, (int, float)):
            temps[temperature_sensor_name("nvidia", gpu)] = float(temp)
    return temps


def telemetry_metrics(target_dir: Path, filename: str = "telemetry.jsonl") -> dict[str, Any]:
    records = iter_jsonl(target_dir / filename)
    temps: list[float] = []
    temps_by_sensor: dict[str, float] = {}
    mem_available: list[float] = []
    gpu_used: list[float] = []
    gpu_total: list[float] = []
    for record in records:
        for sensor, temp in collect_temperatures_by_sensor(record).items():
            temps.append(temp)
            temps_by_sensor[sensor] = max(temps_by_sensor.get(sensor, float("-inf")), temp)
        mem = record.get("memory", {}).get("meminfo_kb", {})
        if isinstance(mem.get("MemAvailable"), (int, float)):
            mem_available.append(float(mem["MemAvailable"]) / 1024 / 1024)
        for gpu in record.get("gpu", {}).get("nvidia_smi", []):
            if isinstance(gpu.get("memory_used"), (int, float)):
                gpu_used.append(float(gpu["memory_used"]))
            if isinstance(gpu.get("memory_total"), (int, float)):
                gpu_total.append(float(gpu["memory_total"]))
        for gpu in record.get("gpu", {}).get("drm", []):
            if isinstance(gpu.get("vram_used_bytes"), (int, float)):
                gpu_used.append(float(gpu["vram_used_bytes"]) / 1024 / 1024)
            if isinstance(gpu.get("vram_total_bytes"), (int, float)):
                gpu_total.append(float(gpu["vram_total_bytes"]) / 1024 / 1024)
    used_ratio = None
    if gpu_used and gpu_total and max(gpu_total) > 0:
        used_ratio = max(gpu_used) / max(gpu_total)
    return {
        "max_temp_c": max(temps) if temps else None,
        "temperature_max_c_by_sensor": {key: temps_by_sensor[key] for key in sorted(temps_by_sensor)},
        "min_memory_available_gib": min(mem_available) if mem_available else None,
        "gpu_memory_used_ratio": used_ratio,
    }


def status_rank(status: str) -> int:
    return {"pass": 0, "warn": 1, "fail": 2}.get(status, 0)


def worse(a: str, b: str) -> str:
    return a if status_rank(a) >= status_rank(b) else b


def evaluate_telemetry_checks(telemetry: dict[str, Any], telemetry_rules: dict[str, Any]) -> tuple[str, list[dict[str, Any]]]:
    """Evaluate temperature/memory/GPU thresholds against a telemetry summary.

    Shared by per-benchmark (client) and run-level (model server / target)
    evaluation so both apply the same rules.
    """
    status = "pass"
    checks: list[dict[str, Any]] = []

    sensor_thresholds = telemetry_rules.get("temperature_sensor_thresholds", {})
    temps_by_sensor = telemetry.get("temperature_max_c_by_sensor") or {}
    if sensor_thresholds and temps_by_sensor:
        for sensor, temp in temps_by_sensor.items():
            thresholds = sensor_thresholds.get(sensor, sensor_thresholds.get("default", {}))
            if not thresholds:
                continue
            if temp >= thresholds.get("fail", 10**9):
                check_status = "fail"
            elif temp >= thresholds.get("warn", 10**9):
                check_status = "warn"
            else:
                check_status = "pass"
            status = worse(status, check_status)
            checks.append(
                {
                    "name": f"temperature:{sensor}",
                    "value": temp,
                    "limit": thresholds,
                    "status": check_status,
                }
            )
    else:
        temp = telemetry.get("max_temp_c")
        if temp is not None:
            if temp >= telemetry_rules.get("max_temp_c_fail", 10**9):
                check_status = "fail"
            elif temp >= telemetry_rules.get("max_temp_c_warn", 10**9):
                check_status = "warn"
            else:
                check_status = "pass"
            status = worse(status, check_status)
            checks.append({"name": "max_temp_c", "value": temp, "status": check_status})

    memory = telemetry.get("min_memory_available_gib")
    if memory is not None:
        check_status = "warn" if memory <= telemetry_rules.get("min_memory_available_gib_warn", -1) else "pass"
        status = worse(status, check_status)
        checks.append({"name": "min_memory_available_gib", "value": memory, "status": check_status})

    gpu_ratio = telemetry.get("gpu_memory_used_ratio")
    if gpu_ratio is not None:
        if gpu_ratio >= telemetry_rules.get("gpu_memory_used_ratio_fail", 2):
            check_status = "fail"
        elif gpu_ratio >= telemetry_rules.get("gpu_memory_used_ratio_warn", 2):
            check_status = "warn"
        else:
            check_status = "pass"
        status = worse(status, check_status)
        checks.append({"name": "gpu_memory_used_ratio", "value": gpu_ratio, "status": check_status})

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


def find_summary(target_dir: Path) -> dict[str, Any] | None:
    for candidate in target_dir.glob("openai-*-summary.json"):
        if candidate.exists():
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
