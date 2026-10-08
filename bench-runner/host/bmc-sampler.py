#!/usr/bin/env python3
"""Sample the BMC's temperature sensors (CPU, DIMM A-H) on the Proxmox host.

The BMC caps memory bandwidth to about a third when the hottest DIMM reads 66 °C,
and logs nothing; the OS cannot read the DIMM sensors itself. A benchmark whose
model keeps experts in system RAM (GPU 2) slows down with it, so the benchmark
wrappers run this beside every run:

  bmc-sampler.py --output bmc-telemetry.jsonl [--interval 10]    # until SIGTERM
  bmc-sampler.py --summarize bmc-telemetry.jsonl [--json-out summary.json]

One JSON line per sample: timestamp, epoch and every sensor with a reading, in °C.
`ipmitool sdr type temperature` takes ~3 s on the ROMED8-2T, so keep the interval
above that.
"""

from __future__ import annotations

import argparse
import json
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts" / "benchmarks"))
from bench_common import dimm_summary  # noqa: E402

stopping = False


def read_temperatures() -> dict[str, float]:
    try:
        output = subprocess.run(
            ["ipmitool", "sdr", "type", "temperature"],
            capture_output=True, text=True, timeout=30, check=False,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    temperatures = {}
    for line in output.splitlines():
        # "TEMP_CPU1_DDR4A  | 48h | ok  |  7.0 | 39 degrees C"
        fields = [field.strip() for field in line.split("|")]
        if len(fields) == 5 and fields[4].endswith("degrees C"):
            try:
                temperatures[fields[0]] = float(fields[4].split()[0])
            except ValueError:
                continue
    return temperatures


def sample(output: Path, interval: float) -> int:
    def stop(*_: object) -> None:
        global stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with output.open("a", encoding="utf-8") as handle:
        while not stopping:
            started = time.time()
            temperatures = read_temperatures()
            if temperatures:
                handle.write(json.dumps({
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "epoch": started,
                    "temperatures_c": temperatures,
                }, sort_keys=True) + "\n")
                handle.flush()
            while not stopping and time.time() - started < interval:
                time.sleep(0.2)
    return 0


def summarize(path: Path, json_out: Path | None) -> int:
    records = []
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    summary = dimm_summary(records)
    if json_out:
        json_out.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if summary["hottest_dimm"]:
        print(f"DIMM peak: {summary['hottest_dimm']} {summary['hottest_dimm_max_c']:.0f} °C over "
              f"{summary['samples']} samples; bandwidth cap on for ~{summary['capped_seconds_estimate']:.0f} s")
    else:
        print("DIMM peak: no BMC samples")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--output", type=Path, help="JSONL file to append samples to until SIGTERM")
    mode.add_argument("--summarize", type=Path, help="JSONL file to summarize")
    parser.add_argument("--interval", type=float, default=10.0)
    parser.add_argument("--json-out", type=Path, help="with --summarize: also write the summary here")
    args = parser.parse_args()
    if args.summarize:
        return summarize(args.summarize, args.json_out)
    return sample(args.output, args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
