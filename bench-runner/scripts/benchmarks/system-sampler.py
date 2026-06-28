#!/usr/bin/env python3
"""Sample host telemetry as JSON or JSONL.

The sampler intentionally depends only on the Python standard library. It uses
Linux procfs/sysfs first, then optional vendor tools when they are installed.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import signal
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_text(path: str | Path) -> str | None:
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return None


def read_key_value_file(path: str | Path, separator: str = ":") -> dict[str, Any]:
    values: dict[str, Any] = {}
    text = read_text(path)
    if not text:
        return values
    for line in text.splitlines():
        if separator not in line:
            continue
        key, value = line.split(separator, 1)
        values[key.strip()] = value.strip()
    return values


def parse_numeric_prefix(value: str) -> int | float | str:
    parts = value.split()
    if not parts:
        return value
    token = parts[0]
    try:
        if "." in token:
            return float(token)
        return int(token)
    except ValueError:
        return value


def parse_sysfs_int(path: str | Path, scale: float = 1.0) -> int | float | None:
    value = read_text(path)
    if value is None:
        return None
    try:
        return int(value) / scale
    except ValueError:
        return None


def collect_meminfo() -> dict[str, Any]:
    raw = read_key_value_file("/proc/meminfo")
    return {key: parse_numeric_prefix(value) for key, value in raw.items()}


def collect_cpu_stat() -> dict[str, Any]:
    text = read_text("/proc/stat")
    if not text:
        return {}
    stats: dict[str, Any] = {}
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "cpu":
            names = [
                "user",
                "nice",
                "system",
                "idle",
                "iowait",
                "irq",
                "softirq",
                "steal",
                "guest",
                "guest_nice",
            ]
            stats["total"] = {
                name: int(value)
                for name, value in zip(names, parts[1:])
            }
        elif parts[0].startswith("cpu") and parts[0][3:].isdigit():
            stats.setdefault("per_cpu_count", 0)
            stats["per_cpu_count"] += 1
    return stats


def collect_pressure() -> dict[str, Any]:
    result: dict[str, Any] = {}
    for name in ("cpu", "memory", "io"):
        text = read_text(f"/proc/pressure/{name}")
        if text:
            result[name] = text
    return result


def collect_cpu_freq() -> dict[str, Any]:
    freqs = []
    for path in Path("/sys/devices/system/cpu").glob("cpu[0-9]*/cpufreq/scaling_cur_freq"):
        value = read_text(path)
        if value and value.isdigit():
            freqs.append(int(value))
    if not freqs:
        return {}
    return {
        "count": len(freqs),
        "min_khz": min(freqs),
        "max_khz": max(freqs),
        "avg_khz": sum(freqs) / len(freqs),
    }


def collect_temperatures() -> dict[str, Any]:
    temps: dict[str, Any] = {"thermal_zones": [], "hwmon": []}
    for zone in Path("/sys/class/thermal").glob("thermal_zone*"):
        raw = read_text(zone / "temp")
        if not raw:
            continue
        try:
            millideg = int(raw)
        except ValueError:
            continue
        temps["thermal_zones"].append(
            {
                "name": zone.name,
                "type": read_text(zone / "type"),
                "temp_c": millideg / 1000,
            }
        )

    for hwmon in Path("/sys/class/hwmon").glob("hwmon*"):
        chip = read_text(hwmon / "name")
        for temp_input in hwmon.glob("temp*_input"):
            raw = read_text(temp_input)
            if not raw:
                continue
            try:
                millideg = int(raw)
            except ValueError:
                continue
            stem = temp_input.name.removesuffix("_input")
            temps["hwmon"].append(
                {
                    "chip": chip,
                    "sensor": stem,
                    "label": read_text(hwmon / f"{stem}_label"),
                    "temp_c": millideg / 1000,
                }
            )
    return temps


def collect_netdev() -> dict[str, Any]:
    text = read_text("/proc/net/dev")
    if not text:
        return {}
    result: dict[str, Any] = {}
    for line in text.splitlines()[2:]:
        if ":" not in line:
            continue
        iface, rest = line.split(":", 1)
        values = rest.split()
        if len(values) < 16:
            continue
        result[iface.strip()] = {
            "rx_bytes": int(values[0]),
            "rx_packets": int(values[1]),
            "rx_drop": int(values[3]),
            "tx_bytes": int(values[8]),
            "tx_packets": int(values[9]),
            "tx_drop": int(values[11]),
        }
    return result


def collect_diskstats() -> dict[str, Any]:
    text = read_text("/proc/diskstats")
    if not text:
        return {}
    result: dict[str, Any] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 14:
            continue
        device = parts[2]
        if device.startswith(("loop", "ram")):
            continue
        result[device] = {
            "reads_completed": int(parts[3]),
            "sectors_read": int(parts[5]),
            "writes_completed": int(parts[7]),
            "sectors_written": int(parts[9]),
            "io_ms": int(parts[12]),
        }
    return result


def run_json_command(command: list[str], timeout: float = 2.0) -> Any:
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"error": str(exc)}
    if completed.returncode != 0:
        return {
            "error": "command_failed",
            "returncode": completed.returncode,
            "stderr": completed.stderr.strip()[-2000:],
        }
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError:
        return {"raw": completed.stdout.strip()}


def collect_nvidia_smi() -> list[dict[str, Any]]:
    if not shutil.which("nvidia-smi"):
        return []
    fields = [
        "index",
        "name",
        "uuid",
        "temperature.gpu",
        "utilization.gpu",
        "utilization.memory",
        "memory.used",
        "memory.total",
        "power.draw",
        "clocks.sm",
        "clocks.mem",
        "pcie.link.gen.current",
        "pcie.link.width.current",
    ]
    command = [
        "nvidia-smi",
        f"--query-gpu={','.join(fields)}",
        "--format=csv,noheader,nounits",
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if completed.returncode != 0:
        return [{"error": completed.stderr.strip()[-2000:]}]
    rows = []
    for line in completed.stdout.splitlines():
        values = [value.strip() for value in line.split(",")]
        row: dict[str, Any] = {}
        for key, value in zip(fields, values):
            row[key.replace(".", "_")] = parse_numeric_prefix(value)
        rows.append(row)
    return rows


def parse_dpm_clock_file(path: Path) -> dict[str, Any] | None:
    text = read_text(path)
    if not text:
        return None

    levels = []
    current_mhz = None
    current_level = None
    for line in text.splitlines():
        parts = line.strip().split()
        if len(parts) < 2 or not parts[0].rstrip(":").isdigit():
            continue
        level = int(parts[0].rstrip(":"))
        raw_clock = parts[1]
        multiplier = 1.0
        lowered = raw_clock.lower()
        if lowered.endswith("ghz"):
            multiplier = 1000.0
            raw_clock = raw_clock[:-3]
        elif lowered.endswith("mhz"):
            raw_clock = raw_clock[:-3]
        try:
            mhz = float(raw_clock) * multiplier
        except ValueError:
            continue
        active = "*" in parts
        levels.append({"level": level, "mhz": mhz, "active": active})
        if active:
            current_mhz = mhz
            current_level = level

    if not levels:
        return None
    return {
        "current_mhz": current_mhz,
        "current_level": current_level,
        "levels": levels,
    }


def collect_drm_gpus() -> list[dict[str, Any]]:
    gpus = []
    for card in sorted(Path("/sys/class/drm").glob("card[0-9]*")):
        device = card / "device"
        if not device.exists():
            continue

        clocks: dict[str, Any] = {}
        for name, filename in {
            "sclk": "pp_dpm_sclk",
            "mclk": "pp_dpm_mclk",
            "fclk": "pp_dpm_fclk",
            "socclk": "pp_dpm_socclk",
            "dcefclk": "pp_dpm_dcefclk",
        }.items():
            parsed = parse_dpm_clock_file(device / filename)
            if parsed:
                clocks[name] = parsed

        record: dict[str, Any] = {
            "card": card.name,
            "vendor": read_text(device / "vendor"),
            "device": read_text(device / "device"),
            "driver": Path(os.path.realpath(device / "driver")).name if (device / "driver").exists() else None,
            "gpu_busy_percent": parse_sysfs_int(device / "gpu_busy_percent"),
            "power_dpm_force_performance_level": read_text(device / "power_dpm_force_performance_level"),
            "power_profile_mode": read_text(device / "pp_power_profile_mode"),
            "vram_used_bytes": parse_sysfs_int(device / "mem_info_vram_used"),
            "vram_total_bytes": parse_sysfs_int(device / "mem_info_vram_total"),
            "gtt_used_bytes": parse_sysfs_int(device / "mem_info_gtt_used"),
            "gtt_total_bytes": parse_sysfs_int(device / "mem_info_gtt_total"),
            "clocks": clocks,
        }
        gpus.append(record)
    return gpus


def collect_rocm_smi() -> Any:
    if not shutil.which("rocm-smi"):
        return {}
    return run_json_command(
        [
            "rocm-smi",
            "--showtemp",
            "--showuse",
            "--showmemuse",
            "--showpower",
            "--showclocks",
            "--json",
        ],
        timeout=3,
    )


def collect_sensors() -> Any:
    if not shutil.which("sensors"):
        return {}
    return run_json_command(["sensors", "-j"], timeout=2)


def split_patterns(values: list[str]) -> list[str]:
    patterns: list[str] = []
    for value in values:
        for item in value.split(","):
            item = item.strip()
            if item:
                patterns.append(item)
    return patterns


def parse_proc_status(path: Path) -> dict[str, Any]:
    result: dict[str, Any] = {}
    text = read_text(path)
    if not text:
        return result
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        result[key.strip()] = value.strip()
    return result


def collect_processes(patterns: list[str]) -> list[dict[str, Any]]:
    if not patterns:
        return []
    lower_patterns = [pattern.lower() for pattern in patterns]
    processes: list[dict[str, Any]] = []
    proc_root = Path("/proc")
    if not proc_root.exists():
        return processes

    for entry in proc_root.iterdir():
        if not entry.name.isdigit():
            continue
        cmdline_raw = read_text(entry / "cmdline")
        comm = read_text(entry / "comm") or ""
        cmdline = (cmdline_raw or "").replace("\x00", " ").strip()
        haystack = f"{comm} {cmdline}".lower()
        matched = [pattern for pattern in patterns if pattern.lower() in haystack]
        if not matched:
            continue

        stat = (read_text(entry / "stat") or "").split()
        status = parse_proc_status(entry / "status")
        io = read_key_value_file(entry / "io")
        record: dict[str, Any] = {
            "pid": int(entry.name),
            "comm": comm,
            "cmdline": cmdline[:1000],
            "matched_patterns": matched,
            "state": status.get("State"),
            "threads": parse_numeric_prefix(status.get("Threads", "")),
            "vmrss_kb": parse_numeric_prefix(status.get("VmRSS", "")),
            "vmsize_kb": parse_numeric_prefix(status.get("VmSize", "")),
            "voluntary_ctxt_switches": parse_numeric_prefix(status.get("voluntary_ctxt_switches", "")),
            "nonvoluntary_ctxt_switches": parse_numeric_prefix(status.get("nonvoluntary_ctxt_switches", "")),
            "io": {key: parse_numeric_prefix(value) for key, value in io.items()},
        }
        if len(stat) >= 24:
            record["utime_ticks"] = parse_numeric_prefix(stat[13])
            record["stime_ticks"] = parse_numeric_prefix(stat[14])
            record["rss_pages"] = parse_numeric_prefix(stat[23])
        processes.append(record)
    return sorted(processes, key=lambda item: item["pid"])


def collect_snapshot(process_patterns: list[str] | None = None) -> dict[str, Any]:
    loadavg = os.getloadavg() if hasattr(os, "getloadavg") else None
    return {
        "timestamp": now_iso(),
        "host": {
            "hostname": platform.node(),
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "python": platform.python_version(),
        },
        "loadavg": loadavg,
        "uptime_seconds": parse_numeric_prefix(read_text("/proc/uptime") or ""),
        "cpu": {
            "count": os.cpu_count(),
            "stat": collect_cpu_stat(),
            "frequency": collect_cpu_freq(),
            "pressure": collect_pressure().get("cpu"),
        },
        "memory": {
            "meminfo_kb": collect_meminfo(),
            "pressure": collect_pressure().get("memory"),
        },
        "io_pressure": collect_pressure().get("io"),
        "temperature": collect_temperatures(),
        "network": collect_netdev(),
        "disk": collect_diskstats(),
        "gpu": {
            "nvidia_smi": collect_nvidia_smi(),
            "drm": collect_drm_gpus(),
            "rocm_smi": collect_rocm_smi(),
        },
        "processes": collect_processes(process_patterns or []),
        "sensors": collect_sensors(),
    }


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def write_record(handle: Any, record: dict[str, Any]) -> None:
    handle.write(json.dumps(record, sort_keys=True) + "\n")
    handle.flush()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="-", help="Output JSONL path, or '-' for stdout.")
    parser.add_argument("--interval", type=float, default=1.0, help="Seconds between samples.")
    parser.add_argument("--duration", type=float, default=0.0, help="Stop after N seconds; 0 means no duration limit.")
    parser.add_argument("--until-pid", type=int, help="Stop once this process exits.")
    parser.add_argument("--once", action="store_true", help="Collect one JSON object instead of JSONL loop.")
    parser.add_argument(
        "--process-pattern",
        action="append",
        default=[],
        help="Process command/name substring to sample; comma-separated values are accepted.",
    )
    args = parser.parse_args()
    process_patterns = split_patterns(args.process_pattern)

    deadline = time.monotonic() + args.duration if args.duration > 0 else None

    if args.output == "-":
        handle = os.sys.stdout
        close_handle = False
    else:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        # Truncate, not append: one sampler invocation owns its telemetry file.
        # Appending would accumulate stale samples if a run id / output path is
        # reused (e.g. a re-run context sweep's ctx-<n> ids).
        handle = Path(args.output).open("w", encoding="utf-8")
        close_handle = True

    stop = False

    def handle_signal(signum: int, _frame: Any) -> None:
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    try:
        if args.once:
            if args.output == "-":
                json.dump(collect_snapshot(process_patterns), handle, sort_keys=True, indent=2)
                handle.write("\n")
            else:
                write_record(handle, collect_snapshot(process_patterns))
            return 0

        while not stop:
            write_record(handle, collect_snapshot(process_patterns))
            if deadline is not None and time.monotonic() >= deadline:
                break
            if args.until_pid is not None and not process_exists(args.until_pid):
                break
            time.sleep(max(args.interval, 0.1))
    finally:
        if close_handle:
            handle.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
