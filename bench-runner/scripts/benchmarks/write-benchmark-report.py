#!/usr/bin/env python3
"""Create a human-readable benchmark report from a benchmark run directory."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

AMD_GPU_DEVICE_NAMES = {
    "0x73df": "AMD Radeon RX 6700 XT (Navi 22)",
}


def load_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def iter_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
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


def fmt(value: Any, digits: int = 2) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def first_present(*values: Any) -> Any:
    for value in values:
        if value is not None:
            return value
    return None


def md_escape(value: Any) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ").strip()


def command_stdout(versions: dict[str, Any], command_name: str) -> str:
    command = versions.get("os_commands", {}).get(command_name, {})
    stdout = command.get("stdout")
    return stdout if isinstance(stdout, str) else ""


def parse_labeled_lines(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip()
    return values


def first_tool_version_line(tool: dict[str, Any]) -> str | None:
    if not tool or not tool.get("available"):
        return None
    version = tool.get("version", {})
    stdout = version.get("stdout")
    stderr = version.get("stderr")
    for text in (stdout, stderr):
        if isinstance(text, str):
            for line in text.splitlines():
                line = line.strip()
                if line:
                    return line
    path = tool.get("path")
    return str(path) if path else None


def summarize_cpu(versions: dict[str, Any]) -> dict[str, str]:
    lscpu = parse_labeled_lines(command_stdout(versions, "lscpu"))
    return {
        "Model": lscpu.get("Model name", "n/a"),
        "Architecture": lscpu.get("Architecture", "n/a"),
        "Logical CPUs": lscpu.get("CPU(s)", "n/a"),
        "Cores": lscpu.get("Core(s) per socket", "n/a"),
        "Threads/Core": lscpu.get("Thread(s) per core", "n/a"),
        "Max MHz": lscpu.get("CPU max MHz", "n/a"),
        "Min MHz": lscpu.get("CPU min MHz", "n/a"),
    }


def summarize_memory(versions: dict[str, Any]) -> dict[str, str]:
    for line in command_stdout(versions, "free").splitlines():
        parts = line.split()
        if parts and parts[0].rstrip(":") == "Mem" and len(parts) >= 7:
            return {
                "Total": parts[1],
                "Used": parts[2],
                "Free": parts[3],
                "Available": parts[6],
            }
    return {"Total": "n/a", "Used": "n/a", "Free": "n/a", "Available": "n/a"}


def summarize_storage(versions: dict[str, Any]) -> list[str]:
    rows = []
    for line in command_stdout(versions, "lsblk").splitlines()[1:]:
        stripped = line.strip()
        if not stripped:
            continue
        name = stripped.split()[0].lstrip("├─└─│`-")
        if name.startswith("loop") or " loop " in f" {stripped} ":
            continue
        if any(token in f" {stripped} " for token in (" disk ", " part ")):
            rows.append(stripped)
    return rows[:8]


def summarize_gpu(versions: dict[str, Any], rows: list[dict[str, Any]]) -> list[str]:
    gpus: list[str] = []

    nvidia = versions.get("tools", {}).get("nvidia-smi", {})
    nvidia_stdout = nvidia.get("version", {}).get("stdout")
    if isinstance(nvidia_stdout, str):
        for line in nvidia_stdout.splitlines()[1:]:
            line = line.strip()
            if line:
                gpus.append(line)

    for line in command_stdout(versions, "lspci").splitlines():
        if any(kind in line for kind in ("VGA compatible controller", "3D controller", "Display controller")):
            gpus.append(line.strip())

    vulkan = command_stdout(versions, "vulkaninfo_summary")
    for line in vulkan.splitlines():
        stripped = line.strip()
        if stripped.startswith("deviceName") or stripped.startswith("GPU id"):
            gpus.append(stripped)

    for row in rows:
        for gpu in row.get("telemetry", {}).get("gpu_devices") or []:
            gpus.append(str(gpu))

    seen: set[str] = set()
    unique = []
    for gpu in gpus:
        if "RX 6700 XT" in gpu and any("RX 6700 XT" in existing for existing in unique):
            continue
        if gpu not in seen:
            seen.add(gpu)
            unique.append(gpu)
    return unique[:8]


def summarize_tools(versions: dict[str, Any]) -> list[tuple[str, str, str]]:
    tools = versions.get("tools", {})
    rows = []
    for name in [
        "lms",
        "llama-server",
        "llama-benchy",
        "llama_benchy_bin",
        "lm_eval",
        "python3",
        "curl",
        "rocm-smi",
        "nvidia-smi",
    ]:
        tool = tools.get(name, {})
        if not tool or not tool.get("available"):
            continue
        rows.append((name, str(tool.get("path") or "n/a"), first_tool_version_line(tool) or "n/a"))
    return rows


def render_snapshot_table(values: dict[str, str]) -> list[str]:
    lines = ["| Item | Value |", "| --- | --- |"]
    for key, value in values.items():
        lines.append(f"| {md_escape(key)} | {md_escape(value)} |")
    return lines


def render_hardware_software_snapshot(versions: dict[str, Any], rows: list[dict[str, Any]]) -> list[str]:
    host = versions.get("host", {})
    model = versions.get("model", {})
    os_release = parse_labeled_lines(command_stdout(versions, "os_release"))

    lines = [
        "## Hardware And Software Snapshot",
        "",
        "### System",
        "",
    ]
    lines.extend(
        render_snapshot_table(
            {
                "Host": host.get("hostname", "n/a"),
                "OS": os_release.get("PRETTY_NAME", f"{host.get('system', 'n/a')} {host.get('release', '')}".strip()),
                "Kernel": host.get("release", "n/a"),
                "Machine": host.get("machine", "n/a"),
                "Python": host.get("python", "n/a"),
            }
        )
    )

    lines.extend(["", "### CPU", ""])
    lines.extend(render_snapshot_table(summarize_cpu(versions)))

    lines.extend(["", "### Memory", ""])
    lines.extend(render_snapshot_table(summarize_memory(versions)))

    lines.extend(["", "### GPU", ""])
    gpu_rows = summarize_gpu(versions, rows)
    if gpu_rows:
        for gpu in gpu_rows:
            lines.append(f"- `{gpu}`")
    else:
        lines.append("- `n/a`")

    storage_rows = summarize_storage(versions)
    lines.extend(["", "### Storage", ""])
    if storage_rows:
        for storage in storage_rows:
            lines.append(f"- `{storage}`")
    else:
        lines.append("- `n/a`")

    lines.extend(["", "### Model Artifact", ""])
    lines.extend(
        render_snapshot_table(
            {
                "Path": model.get("path", "n/a"),
                "SHA-256": model.get("sha256", "n/a"),
            }
        )
    )

    tool_rows = summarize_tools(versions)
    lines.extend(["", "### Runtime Tools", ""])
    if tool_rows:
        lines.extend(["| Tool | Path | Version / First Line |", "| --- | --- | --- |"])
        for name, path, version in tool_rows:
            lines.append(f"| {md_escape(name)} | `{md_escape(path)}` | {md_escape(version)} |")
    else:
        lines.append("- `n/a`")

    lines.append("")
    return lines


def collect_temperature(snapshot: dict[str, Any]) -> list[float]:
    values: list[float] = []
    values.extend(collect_temperatures_by_sensor(snapshot).values())
    return values


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


def collect_temperatures_by_sensor(snapshot: dict[str, Any]) -> dict[str, float]:
    values: dict[str, float] = {}
    for item in snapshot.get("temperature", {}).get("thermal_zones", []):
        if isinstance(item.get("temp_c"), (int, float)):
            values[temperature_sensor_name("thermal_zone", item)] = float(item["temp_c"])
    for item in snapshot.get("temperature", {}).get("hwmon", []):
        if isinstance(item.get("temp_c"), (int, float)):
            values[temperature_sensor_name("hwmon", item)] = float(item["temp_c"])
    for gpu in snapshot.get("gpu", {}).get("nvidia_smi", []):
        temp = gpu.get("temperature_gpu")
        if isinstance(temp, (int, float)):
            values[temperature_sensor_name("nvidia", gpu)] = float(temp)
    return values


def update_max(mapping: dict[str, float], key: str, value: Any) -> None:
    if isinstance(value, (int, float)):
        mapping[key] = max(mapping.get(key, float("-inf")), float(value))


def update_min(mapping: dict[str, float], key: str, value: Any) -> None:
    if isinstance(value, (int, float)):
        mapping[key] = min(mapping.get(key, float("inf")), float(value))


def collect_gpu_clock_mhz(snapshot: dict[str, Any]) -> dict[str, float]:
    values: dict[str, float] = {}
    for gpu in snapshot.get("gpu", {}).get("nvidia_smi", []):
        index = gpu.get("index", "0")
        if isinstance(gpu.get("clocks_sm"), (int, float)):
            values[f"nvidia[{index}] sm"] = float(gpu["clocks_sm"])
        if isinstance(gpu.get("clocks_mem"), (int, float)):
            values[f"nvidia[{index}] memory"] = float(gpu["clocks_mem"])
    for gpu in snapshot.get("gpu", {}).get("drm", []):
        card = gpu.get("card") or "card?"
        for clock_name, clock in (gpu.get("clocks") or {}).items():
            current = clock.get("current_mhz")
            if isinstance(current, (int, float)):
                values[f"{card} {clock_name}"] = float(current)
    return values


def cpu_utilization(records: list[dict[str, Any]]) -> tuple[float | None, float | None]:
    """Derive CPU utilization % from consecutive /proc/stat (cpu total) samples.

    Excludes guest/guest_nice from the total: Linux already folds them into
    user/nice, so summing them again would inflate the denominator.
    """
    fields = ("user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal")
    utils: list[float] = []
    prev = None
    for record in records:
        total = record.get("cpu", {}).get("stat", {}).get("total")
        if not isinstance(total, dict):
            prev = None
            continue
        if prev is not None:
            idle = (total.get("idle", 0) + total.get("iowait", 0)) - (prev.get("idle", 0) + prev.get("iowait", 0))
            delta = sum(total.get(k, 0) for k in fields) - sum(prev.get(k, 0) for k in fields)
            if delta > 0:
                utils.append(max(0.0, min(100.0, 100.0 * (1.0 - idle / delta))))
        prev = total
    if not utils:
        return None, None
    return max(utils), sum(utils) / len(utils)


def telemetry_summary(target_dir: Path, filename: str = "telemetry.jsonl") -> dict[str, Any]:
    records = iter_jsonl(target_dir / filename)
    if not records:
        return {"samples": 0}

    temps = []
    mem_available = []
    mem_total = []
    gpu_power = []
    gpu_util = []
    gpu_mem_used = []
    gpu_mem_total = []
    process_rss = []
    process_names: set[str] = set()
    gpu_devices: set[str] = set()
    temp_max_by_sensor: dict[str, float] = {}
    gpu_clock_min_mhz_by_sensor: dict[str, float] = {}
    gpu_clock_max_mhz_by_sensor: dict[str, float] = {}
    gpu_clock_last_mhz_by_sensor: dict[str, float] = {}

    for record in records:
        temps.extend(collect_temperature(record))
        for sensor, value in collect_temperatures_by_sensor(record).items():
            update_max(temp_max_by_sensor, sensor, value)
        for clock, value in collect_gpu_clock_mhz(record).items():
            update_min(gpu_clock_min_mhz_by_sensor, clock, value)
            update_max(gpu_clock_max_mhz_by_sensor, clock, value)
            gpu_clock_last_mhz_by_sensor[clock] = value
        meminfo = record.get("memory", {}).get("meminfo_kb", {})
        if isinstance(meminfo.get("MemAvailable"), (int, float)):
            mem_available.append(float(meminfo["MemAvailable"]))
        if isinstance(meminfo.get("MemTotal"), (int, float)):
            mem_total.append(float(meminfo["MemTotal"]))
        for gpu in record.get("gpu", {}).get("nvidia_smi", []):
            if gpu.get("name"):
                gpu_devices.add(str(gpu["name"]))
            if isinstance(gpu.get("power_draw"), (int, float)):
                gpu_power.append(float(gpu["power_draw"]))
            if isinstance(gpu.get("utilization_gpu"), (int, float)):
                gpu_util.append(float(gpu["utilization_gpu"]))
            if isinstance(gpu.get("memory_used"), (int, float)):
                gpu_mem_used.append(float(gpu["memory_used"]))
            if isinstance(gpu.get("memory_total"), (int, float)):
                gpu_mem_total.append(float(gpu["memory_total"]))
        for gpu in record.get("gpu", {}).get("drm", []):
            drm_card = gpu.get("card") or "card?"
            drm_driver = gpu.get("driver") or "drm"
            drm_device = gpu.get("device")
            if drm_device:
                device_name = AMD_GPU_DEVICE_NAMES.get(str(drm_device).lower(), str(drm_device))
                gpu_devices.add(f"{device_name} ({drm_driver}, {drm_card})")
            if isinstance(gpu.get("gpu_busy_percent"), (int, float)):
                gpu_util.append(float(gpu["gpu_busy_percent"]))
            if isinstance(gpu.get("vram_used_bytes"), (int, float)):
                gpu_mem_used.append(float(gpu["vram_used_bytes"]) / 1024 / 1024)
            if isinstance(gpu.get("vram_total_bytes"), (int, float)):
                gpu_mem_total.append(float(gpu["vram_total_bytes"]) / 1024 / 1024)
        for process in record.get("processes", []):
            if process.get("comm"):
                process_names.add(str(process["comm"]))
            if isinstance(process.get("vmrss_kb"), (int, float)):
                process_rss.append(float(process["vmrss_kb"]) / 1024)

    used_mem_kb = []
    for total, available in zip(mem_total, mem_available):
        used_mem_kb.append(max(total - available, 0))

    max_cpu_util, mean_cpu_util = cpu_utilization(records)
    load1 = [
        record["loadavg"][0]
        for record in records
        if isinstance(record.get("loadavg"), list) and record["loadavg"]
        and isinstance(record["loadavg"][0], (int, float))
    ]

    return {
        "samples": len(records),
        "max_cpu_util_percent": max_cpu_util,
        "mean_cpu_util_percent": mean_cpu_util,
        "max_loadavg_1m": max(load1) if load1 else None,
        "first_timestamp": records[0].get("timestamp"),
        "last_timestamp": records[-1].get("timestamp"),
        "max_temp_c": max(temps) if temps else None,
        "temperature_max_c_by_sensor": {key: temp_max_by_sensor[key] for key in sorted(temp_max_by_sensor)},
        "max_memory_used_gib": (max(used_mem_kb) / 1024 / 1024) if used_mem_kb else None,
        "min_memory_available_gib": (min(mem_available) / 1024 / 1024) if mem_available else None,
        "max_gpu_power_w": max(gpu_power) if gpu_power else None,
        "max_gpu_util_percent": max(gpu_util) if gpu_util else None,
        "max_gpu_memory_used_mib": max(gpu_mem_used) if gpu_mem_used else None,
        "gpu_memory_total_mib": max(gpu_mem_total) if gpu_mem_total else None,
        "gpu_devices": sorted(gpu_devices),
        "gpu_clock_min_mhz_by_sensor": {key: gpu_clock_min_mhz_by_sensor[key] for key in sorted(gpu_clock_min_mhz_by_sensor)},
        "gpu_clock_max_mhz_by_sensor": {key: gpu_clock_max_mhz_by_sensor[key] for key in sorted(gpu_clock_max_mhz_by_sensor)},
        "gpu_clock_last_mhz_by_sensor": {key: gpu_clock_last_mhz_by_sensor[key] for key in sorted(gpu_clock_last_mhz_by_sensor)},
        "max_matched_process_rss_mib": max(process_rss) if process_rss else None,
        "matched_process_names": sorted(process_names),
    }


def benchmark_rows(run_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for target_dir in sorted(path for path in run_dir.iterdir() if path.is_dir()):
        if target_dir.name in {"system-logs"}:
            continue
        status = load_json(target_dir / "status.json") or {}
        telemetry = telemetry_summary(target_dir)

        openai_summary = next(target_dir.glob("openai-*-summary.json"), None)

        if openai_summary and (data := load_json(openai_summary)):
            latency = data.get("latency_total_seconds", {})
            ttft = data.get("ttft_seconds", {})
            rows.append(
                {
                    "name": target_dir.name,
                    "type": "OpenAI-compatible API",
                    "ok": f"{data.get('ok_count')}/{data.get('record_count')}",
                    "wall_seconds": data.get("wall_seconds"),
                    "throughput": data.get("aggregate_output_tokens_per_second"),
                    "latency_mean": latency.get("mean"),
                    "latency_p95": latency.get("p95"),
                    "ttft_mean": ttft.get("mean"),
                    "ttft_p95": ttft.get("p95"),
                    "status": status,
                    "telemetry": telemetry,
                }
            )
        else:
            rows.append(
                {
                    "name": target_dir.name,
                    "type": "external command",
                    "ok": "see status",
                    "wall_seconds": None,
                    "throughput": None,
                    "latency_mean": None,
                    "latency_p95": None,
                    "ttft_mean": None,
                    "ttft_p95": None,
                    "status": status,
                    "telemetry": telemetry,
                }
            )
    return rows


def infer_limits(rows: list[dict[str, Any]]) -> list[str]:
    limits = []
    for row in rows:
        telemetry = row.get("telemetry", {})
        temps = telemetry.get("temperature_max_c_by_sensor") or {}
        hot_sensors = []
        for sensor, value in temps.items():
            if not isinstance(value, (int, float)):
                continue
            threshold = 85
            if sensor == "amdgpu junction":
                threshold = 110
            elif sensor in {"amdgpu edge", "nvme Composite"}:
                threshold = 80
            if value >= threshold:
                hot_sensors.append(f"{sensor} {fmt(value)} C")
        if hot_sensors:
            limits.append(f"{row['name']}: high temperature observed on {', '.join(hot_sensors)}.")
        if telemetry.get("max_gpu_util_percent") and telemetry["max_gpu_util_percent"] >= 95:
            limits.append(f"{row['name']}: GPU utilization reached {fmt(telemetry['max_gpu_util_percent'])}%.")
        if telemetry.get("max_gpu_memory_used_mib") and telemetry.get("gpu_memory_total_mib"):
            used = telemetry["max_gpu_memory_used_mib"]
            total = telemetry["gpu_memory_total_mib"]
            if total and used / total >= 0.9:
                limits.append(f"{row['name']}: GPU memory reached {fmt(used)} MiB of {fmt(total)} MiB.")
        status = row.get("status", {})
        if status and not status.get("ok", True):
            limits.append(f"{row['name']}: benchmark exited with code {status.get('exit_code')}.")
    return limits


def render_key_value_table(values: dict[str, Any], value_label: str) -> list[str]:
    if not values:
        return []
    lines = [f"| Sensor | {value_label} |", "| --- | ---: |"]
    for key, value in values.items():
        lines.append(f"| {key} | {fmt(value)} |")
    return lines


def render_gpu_clock_table(telemetry: dict[str, Any]) -> list[str]:
    mins = telemetry.get("gpu_clock_min_mhz_by_sensor") or {}
    maxes = telemetry.get("gpu_clock_max_mhz_by_sensor") or {}
    lasts = telemetry.get("gpu_clock_last_mhz_by_sensor") or {}
    keys = sorted(set(mins) | set(maxes) | set(lasts))
    if not keys:
        return []
    lines = ["| Clock | Min MHz | Max MHz | Last MHz |", "| --- | ---: | ---: | ---: |"]
    for key in keys:
        lines.append(f"| {key} | {fmt(mins.get(key))} | {fmt(maxes.get(key))} | {fmt(lasts.get(key))} |")
    return lines


def infer_improvements(rows: list[dict[str, Any]]) -> list[str]:
    improvements = [
        "Repeat this same run after any hardware, driver, runtime, model, quantization, or context change.",
        "Add a longer soak run once the baseline is stable; short runs can miss thermal throttling and memory leaks.",
        "Add wall-power measurements if a smart plug or UPS can export watts/watt-hours.",
    ]
    return improvements


def render_report(run_dir: Path, description: str) -> str:
    manifest = load_json(run_dir / "manifest.json") or {}
    versions = load_json(run_dir / "versions.json") or {}
    slo = load_json(run_dir / "slo-report.json")
    rows = benchmark_rows(run_dir)
    timestamp = first_present(manifest.get("timestamp"), datetime.now(timezone.utc).isoformat())
    run_id = run_dir.name
    env = manifest.get("env", {})
    host = manifest.get("host", {})

    # Provenance: prefer the in-container `git` output, but it normally fails
    # (the deployed suite has no .git), so fall back to the build_info recorded
    # at ship time. For dirty/uncommitted trees the content digest pins what
    # actually ran better than `git_dirty: true` alone.
    repo = versions.get("repo", {})
    commit = (repo.get("git_commit") or {}).get("stdout")
    build_info = repo.get("build_info") or {}
    if not commit:
        commit = build_info.get("git_commit")
    dirty = build_info.get("git_dirty")
    content_sha = repo.get("content_sha256")
    commit_suffix = " (dirty)" if dirty else ""

    lines = [
        f"# Benchmark Run: {run_id}",
        "",
        "## Description",
        "",
        description or "No description provided yet.",
        "",
        "## Date",
        "",
        f"- Run timestamp: `{timestamp}`",
        f"- Report generated: `{datetime.now(timezone.utc).isoformat()}`",
        "",
        "## Current Configuration",
        "",
        f"- Host: `{host.get('hostname', 'unknown')}`",
        f"- System: `{host.get('system', 'unknown')} {host.get('release', '')}`",
        f"- Machine: `{host.get('machine', 'unknown')}`",
        f"- Processor: `{host.get('processor', 'unknown')}`",
        f"- Model API URL: `{env.get('MODEL_API_URL') or 'n/a'}`",
        f"- Model identifier: `{env.get('MODEL_IDENTIFIER') or 'n/a'}`",
        f"- Benchmark profile: `{env.get('BENCHMARK_PROFILE') or 'n/a'}`",
        f"- Promptset: `{env.get('BENCHMARK_PROMPTSET') or 'n/a'}`",
        f"- SLO file: `{env.get('BENCHMARK_SLO_FILE') or 'n/a'}`",
        f"- Process patterns: `{env.get('BENCHMARK_PROCESS_PATTERNS') or 'n/a'}`",
        f"- Runs per test: `{env.get('BENCHMARK_RUNS') or 'default'}`",
        f"- Scenarios: `{env.get('BENCHMARK_SCENARIOS') or 'default'}`",
        f"- Requests per scenario: `{env.get('BENCHMARK_REQUESTS') or 'default'}`",
        f"- Concurrency: `{env.get('BENCHMARK_CONCURRENCY') or 'default'}`",
        f"- llama-benchy enabled: `{env.get('RUN_LLAMA_BENCHY') or 'default'}`",
        f"- Git commit: `{commit or 'n/a'}`{commit_suffix}",
        f"- Suite content digest: `{content_sha or 'n/a'}`",
        "",
    ]

    lines.extend(render_hardware_software_snapshot(versions, rows))
    lines.extend(["## Overall Results", ""])

    if slo:
        lines.extend(["SLO status: `" + str(slo.get("status", "unknown")) + "`", ""])

    if rows:
        lines.extend(
            [
                "| Benchmark | Type | OK | Wall seconds | Output tok/s | Mean latency | p95 latency | Mean TTFT | p95 TTFT |",
                "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
            ]
        )
        for row in rows:
            lines.append(
                "| "
                + " | ".join(
                    [
                        row["name"],
                        row["type"],
                        row["ok"],
                        fmt(row["wall_seconds"]),
                        fmt(row["throughput"]),
                        fmt(row["latency_mean"]),
                        fmt(row["latency_p95"]),
                        fmt(row["ttft_mean"]),
                        fmt(row["ttft_p95"]),
                    ]
                )
                + " |"
            )
    else:
        lines.append("No benchmark summaries were found in this run directory.")

    lines.extend(["", "## Telemetry Highlights", ""])
    for row in rows:
        telemetry = row.get("telemetry", {})
        lines.append(f"### {row['name']}")
        lines.append("")
        lines.append(f"- Samples: `{telemetry.get('samples', 0)}`")
        lines.append(f"- Max / mean CPU utilization: `{fmt(telemetry.get('max_cpu_util_percent'))}% / {fmt(telemetry.get('mean_cpu_util_percent'))}%`")
        lines.append(f"- Max load average (1m): `{fmt(telemetry.get('max_loadavg_1m'))}`")
        lines.append(f"- Max temperature across sensors: `{fmt(telemetry.get('max_temp_c'))} C`")
        lines.append(f"- Max memory used: `{fmt(telemetry.get('max_memory_used_gib'))} GiB`")
        lines.append(f"- Min memory available: `{fmt(telemetry.get('min_memory_available_gib'))} GiB`")
        lines.append(f"- Max GPU utilization: `{fmt(telemetry.get('max_gpu_util_percent'))}%`")
        lines.append(f"- Max GPU memory used: `{fmt(telemetry.get('max_gpu_memory_used_mib'))} MiB`")
        lines.append(f"- Max GPU power: `{fmt(telemetry.get('max_gpu_power_w'))} W`")
        lines.append(f"- Max matched process RSS: `{fmt(telemetry.get('max_matched_process_rss_mib'))} MiB`")
        process_names = telemetry.get("matched_process_names") or []
        lines.append(f"- Matched processes: `{', '.join(process_names) if process_names else 'n/a'}`")
        lines.append("")
        temp_rows = render_key_value_table(telemetry.get("temperature_max_c_by_sensor") or {}, "Max C")
        if temp_rows:
            lines.append("Temperature sensors:")
            lines.append("")
            lines.extend(temp_rows)
            lines.append("")
        clock_rows = render_gpu_clock_table(telemetry)
        if clock_rows:
            lines.append("GPU clocks:")
            lines.append("")
            lines.extend(clock_rows)
            lines.append("")

    # Run-level telemetry sampled inside the model container (e.g. CT 120) by
    # host/run-with-target-telemetry.sh, merged in after the benchmark. Unlike
    # the per-benchmark telemetry above (the bench-runner client), its CPU/RAM/
    # process figures describe the model server itself.
    target = telemetry_summary(run_dir, "target-telemetry.jsonl")
    if target.get("samples"):
        lines.extend(
            [
                "## Model Server Telemetry (target container)",
                "",
                "Sampled inside the model container during the run, so CPU/RAM/process "
                "figures reflect the server itself, not the benchmark client.",
                "",
                f"- Samples: `{target.get('samples', 0)}`",
                f"- Max / mean CPU utilization: `{fmt(target.get('max_cpu_util_percent'))}% / {fmt(target.get('mean_cpu_util_percent'))}%`",
                f"- Max load average (1m): `{fmt(target.get('max_loadavg_1m'))}`",
                f"- Max temperature across sensors: `{fmt(target.get('max_temp_c'))} C`",
                f"- Max memory used: `{fmt(target.get('max_memory_used_gib'))} GiB`",
                f"- Min memory available: `{fmt(target.get('min_memory_available_gib'))} GiB`",
                f"- Max GPU utilization: `{fmt(target.get('max_gpu_util_percent'))}%`",
                f"- Max GPU memory used: `{fmt(target.get('max_gpu_memory_used_mib'))} MiB`",
                f"- Max GPU power: `{fmt(target.get('max_gpu_power_w'))} W`",
                f"- Max matched process RSS: `{fmt(target.get('max_matched_process_rss_mib'))} MiB`",
                f"- Matched processes: `{', '.join(target.get('matched_process_names') or []) or 'n/a'}`",
                "",
            ]
        )

    if slo:
        lines.extend(["## SLO Checks", ""])
        for benchmark in slo.get("benchmarks", []):
            lines.append(f"### {benchmark.get('name')}")
            lines.append("")
            lines.append(f"- Status: `{benchmark.get('status')}`")
            for check in benchmark.get("checks", []):
                lines.append(
                    f"- `{check.get('name')}`: `{check.get('value')}` against `{check.get('limit', 'threshold')}` -> `{check.get('status')}`"
                )
            lines.append("")

    lines.extend(["## Software And Hardware Limits Observed", ""])
    limits = infer_limits(rows)
    if limits:
        lines.extend(f"- {item}" for item in limits)
    else:
        lines.append("- No hard limit was automatically inferred. Review telemetry and stderr logs before treating this as clean.")

    lines.extend(["", "## Improvements To Try Next", ""])
    lines.extend(f"- {item}" for item in infer_improvements(rows))

    lines.extend(["", "## Benchmarks Used", ""])
    if rows:
        for row in rows:
            lines.append(f"- `{row['name']}`: {row['type']}.")
    else:
        lines.append("- None detected.")

    lines.extend(["", "## Raw Files", ""])
    lines.append("- `manifest.json` - run metadata.")
    lines.append("- `<benchmark>/telemetry.jsonl` - system telemetry samples.")
    lines.append("- `<benchmark>/stdout.log` and `<benchmark>/stderr.log` - command output.")
    lines.append("- `<benchmark>/*summary.json` and `<benchmark>/*requests.jsonl` - benchmark-specific results.")
    lines.append("- `versions.json` - software, hardware, Git, and model hash metadata.")
    lines.append("- `system-logs/before/` and `system-logs/after/` - system log snapshots.")
    lines.append("- `slo-report.json` and `SLO.md` - pass/warn/fail checks.")
    lines.append("")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", help="Benchmark run directory.")
    parser.add_argument("--description", default="", help="Human description of this configuration/run.")
    parser.add_argument("--output", default="REPORT.md", help="Report filename inside the run directory.")
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    if not run_dir.exists():
        raise SystemExit(f"Run directory not found: {run_dir}")

    report = render_report(run_dir, args.description)
    output_path = run_dir / args.output
    output_path.write_text(report + "\n", encoding="utf-8")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
