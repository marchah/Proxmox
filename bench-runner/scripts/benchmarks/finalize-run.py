#!/usr/bin/env python3
"""Regenerate a run's SLO + report after run-level target telemetry is merged.

The benchmark suite writes SLO.md / REPORT.md inside the bench-runner *before*
the host wrapper merges target-telemetry.jsonl (the model-server telemetry from
CT 120). This re-runs the evaluators for a finished run directory so those
artifacts reflect the merged target telemetry.

It is idempotent and no-ops on a run dir with no manifest.json (e.g. a parameter
sweep, which produces curve.json/curve.md but no report). Its exit code reflects
the regenerated SLO outcome (non-zero on a hard SLO fail) so the caller can
propagate a target-telemetry-induced breach.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent.parent
PYTHON_BIN = sys.executable or "python3"


def resolve_project_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else PROJECT_DIR / path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir")
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    manifest_path = run_dir / "manifest.json"
    if not manifest_path.exists():
        print(f"finalize-run: {run_dir} has no manifest.json; nothing to regenerate.")
        return 0

    env = json.loads(manifest_path.read_text(encoding="utf-8")).get("env", {})
    description = env.get("BENCHMARK_DESCRIPTION") or "Server-side benchmark run."

    slo_status = 0
    slo_file_value = env.get("BENCHMARK_SLO_FILE")
    if slo_file_value:
        slo_file = resolve_project_path(slo_file_value)
        if slo_file.exists():
            with (run_dir / "slo-evaluation.stdout.log").open("w", encoding="utf-8") as out, \
                 (run_dir / "slo-evaluation.stderr.log").open("w", encoding="utf-8") as err:
                completed = subprocess.run(
                    [PYTHON_BIN, str(SCRIPT_DIR / "evaluate-slos.py"), str(run_dir), "--slo-file", str(slo_file)],
                    stdout=out,
                    stderr=err,
                    check=False,
                )
            slo_status = completed.returncode
            (run_dir / "slo-evaluation.status.json").write_text(
                json.dumps({"exit_code": slo_status, "ok": slo_status == 0}) + "\n",
                encoding="utf-8",
            )
        else:
            sys.stderr.write(f"finalize-run: SLO file not found: {slo_file}\n")

    subprocess.run(
        [PYTHON_BIN, str(SCRIPT_DIR / "write-benchmark-report.py"), str(run_dir), "--description", description],
        check=False,
    )

    print(f"finalize-run: regenerated SLO/report for {run_dir} (slo exit {slo_status})")
    return 0 if slo_status == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
