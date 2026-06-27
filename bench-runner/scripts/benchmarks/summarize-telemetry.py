#!/usr/bin/env python3
"""Reduce a telemetry.jsonl into peak/bottleneck signals.

Reads samples produced by system-sampler.py and reports the peaks that answer
"was the GPU (or memory, or thermals) the bottleneck during this load?":

  - GPU utilization (AMD gpu_busy_percent or NVIDIA utilization.gpu)
  - VRAM used / total / ratio
  - GPU core clock range (a drop under sustained load suggests throttling)
  - max temperature per sensor
  - minimum free system RAM

GPU fields are populated whenever the sampler could read the GPU's sysfs — which
includes the unprivileged bench-runner LXC, since it reads the host's
/sys/class/drm. They stay null only when no GPU sysfs was readable at all, or when
every sample happened to catch the GPU idle (LM Studio frees VRAM between requests).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def iter_jsonl(path: Path) -> list[dict[str, Any]]:
    records = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return records


def is_num(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def temps_by_sensor(record: dict[str, Any]) -> dict[str, float]:
    out: dict[str, float] = {}
    temperature = record.get("temperature", {})
    for item in temperature.get("thermal_zones", []) or []:
        if is_num(item.get("temp_c")):
            out[f"thermal {item.get('type') or item.get('name') or 'zone'}"] = float(item["temp_c"])
    for item in temperature.get("hwmon", []) or []:
        if is_num(item.get("temp_c")):
            chip = item.get("chip") or "hwmon"
            label = item.get("label") or item.get("sensor") or "temp"
            out[f"{chip} {label}"] = float(item["temp_c"])
    for gpu in record.get("gpu", {}).get("nvidia_smi", []) or []:
        if is_num(gpu.get("temperature_gpu")):
            out[f"nvidia {gpu.get('index', 'gpu')}"] = float(gpu["temperature_gpu"])
    return out


def gpu_sample(record: dict[str, Any]) -> dict[str, float | None]:
    gpu = record.get("gpu", {})
    busy = vram_used = vram_total = sclk = None
    for card in gpu.get("drm", []) or []:
        if is_num(card.get("gpu_busy_percent")):
            busy = max(busy or 0.0, float(card["gpu_busy_percent"]))
        if is_num(card.get("vram_used_bytes")):
            vram_used = max(vram_used or 0.0, float(card["vram_used_bytes"]) / 1024 / 1024)
        if is_num(card.get("vram_total_bytes")):
            vram_total = max(vram_total or 0.0, float(card["vram_total_bytes"]) / 1024 / 1024)
        cur = card.get("clocks", {}).get("sclk", {}).get("current_mhz")
        if is_num(cur):
            sclk = float(cur) if sclk is None else max(sclk, float(cur))
    for card in gpu.get("nvidia_smi", []) or []:
        if is_num(card.get("utilization_gpu")):
            busy = max(busy or 0.0, float(card["utilization_gpu"]))
        if is_num(card.get("memory_used")):
            vram_used = max(vram_used or 0.0, float(card["memory_used"]))
        if is_num(card.get("memory_total")):
            vram_total = max(vram_total or 0.0, float(card["memory_total"]))
        if is_num(card.get("clocks_sm")):
            sclk = float(card["clocks_sm"]) if sclk is None else max(sclk, float(card["clocks_sm"]))
    return {"busy": busy, "vram_used": vram_used, "vram_total": vram_total, "sclk": sclk}


def summarize(records: list[dict[str, Any]]) -> dict[str, Any]:
    max_busy = max_vram_used = vram_total = None
    sclk_values: list[float] = []
    temps_max: dict[str, float] = {}
    mem_avail: list[float] = []

    for record in records:
        g = gpu_sample(record)
        if g["busy"] is not None:
            max_busy = g["busy"] if max_busy is None else max(max_busy, g["busy"])
        if g["vram_used"] is not None:
            max_vram_used = g["vram_used"] if max_vram_used is None else max(max_vram_used, g["vram_used"])
        if g["vram_total"] is not None:
            vram_total = g["vram_total"] if vram_total is None else max(vram_total, g["vram_total"])
        if g["sclk"] is not None:
            sclk_values.append(g["sclk"])
        for sensor, temp in temps_by_sensor(record).items():
            temps_max[sensor] = max(temps_max.get(sensor, float("-inf")), temp)
        mem = record.get("memory", {}).get("meminfo_kb", {})
        if is_num(mem.get("MemAvailable")):
            mem_avail.append(float(mem["MemAvailable"]) / 1024 / 1024)

    ratio = None
    if max_vram_used is not None and vram_total:
        ratio = max_vram_used / vram_total
    return {
        "samples": len(records),
        "gpu": {
            "max_busy_percent": max_busy,
            "max_vram_used_mib": max_vram_used,
            "vram_total_mib": vram_total,
            "max_vram_used_ratio": ratio,
            "sclk_min_mhz": min(sclk_values) if sclk_values else None,
            "sclk_max_mhz": max(sclk_values) if sclk_values else None,
        },
        "temperatures_max_c": {key: temps_max[key] for key in sorted(temps_max)},
        "system": {"min_mem_available_gib": min(mem_avail) if mem_avail else None},
    }


def fmt(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.1f}"
    return str(value)


def human_lines(summary: dict[str, Any]) -> list[str]:
    g = summary["gpu"]
    lines = [f"samples: {summary['samples']}"]
    if g["max_busy_percent"] is None and not summary["temperatures_max_c"]:
        lines.append("No GPU/thermal data in this telemetry (no GPU sysfs was readable, or the GPU was idle for every sample).")
    if g["max_busy_percent"] is not None:
        lines.append(f"GPU peak utilization: {fmt(g['max_busy_percent'])}%")
    if g["max_vram_used_mib"] is not None:
        ratio = g["max_vram_used_ratio"]
        ratio_str = f" ({fmt(ratio * 100)}%)" if ratio is not None else ""
        lines.append(f"VRAM peak: {fmt(g['max_vram_used_mib'])} / {fmt(g['vram_total_mib'])} MiB{ratio_str}")
    if g["sclk_min_mhz"] is not None:
        lines.append(f"GPU core clock range: {fmt(g['sclk_min_mhz'])} - {fmt(g['sclk_max_mhz'])} MHz (a drop under load suggests throttling)")
    for sensor, temp in summary["temperatures_max_c"].items():
        lines.append(f"max temp [{sensor}]: {fmt(temp)} C")
    if summary["system"]["min_mem_available_gib"] is not None:
        lines.append(f"min free system RAM: {fmt(summary['system']['min_mem_available_gib'])} GiB")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("telemetry", help="Path to a telemetry.jsonl file.")
    parser.add_argument("--json-out", help="Optional path to write the JSON summary.")
    args = parser.parse_args()

    path = Path(args.telemetry)
    if not path.exists():
        print(f"Telemetry file not found: {path}", file=sys.stderr)
        return 2

    summary = summarize(iter_jsonl(path))
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("\n".join(human_lines(summary)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
