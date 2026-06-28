#!/usr/bin/env python3
"""Collect reproducibility metadata for a benchmark run."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def run(command: list[str], timeout: float = 5.0, cwd: str | None = None) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=cwd,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "error": str(exc), "command": command}
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "command": command,
        "stdout": completed.stdout.strip()[-8000:],
        "stderr": completed.stderr.strip()[-4000:],
    }


def command_version(command: str, args: list[str] | None = None) -> dict[str, Any]:
    path = shutil.which(command)
    if not path:
        return {"available": False}
    return {"available": True, "path": path, "version": run([path] + (args or ["--version"]))}


def executable_version(path: str | None, args: list[str] | None = None) -> dict[str, Any]:
    if not path:
        return {"available": False}
    executable = Path(path)
    if not executable.exists():
        return {"available": False, "path": path}
    return {"available": True, "path": str(executable), "version": run([str(executable)] + (args or ["--version"]))}


def content_digest(project_dir: Path) -> str | None:
    """Stable sha256 over the deployed suite (scripts/ + config/).

    Pins what actually ran for dirty/uncommitted trees, where git_commit alone
    is ambiguous. Excludes the generated build-info.json and Python caches so
    the digest depends only on source.
    """
    digest = hashlib.sha256()
    files: list[Path] = []
    for sub in ("scripts", "config"):
        base = project_dir / sub
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if not path.is_file():
                continue
            if path.name == "build-info.json" or path.suffix == ".pyc" or "__pycache__" in path.parts:
                continue
            files.append(path)
    if not files:
        return None
    for path in sorted(files, key=lambda p: str(p.relative_to(project_dir))):
        digest.update(str(path.relative_to(project_dir)).encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def load_build_info(project_dir: Path) -> dict[str, Any] | None:
    """Read build-info.json, written when the suite is shipped into the LXC.

    The deployed suite under /opt/bench-runner is a tar-extracted copy with no
    .git, so `git rev-parse` there reports nothing. Whoever ships the suite
    (the Ansible playbook or the create script) records the source commit in
    config/build-info.json so the run still captures it.
    """
    path = project_dir / "config" / "build-info.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return {"error": f"unreadable build-info.json: {exc}"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--project-dir", default=".")
    args = parser.parse_args()

    project_dir = Path(args.project_dir)
    data = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "host": {
            "hostname": platform.node(),
            "system": platform.system(),
            "release": platform.release(),
            "version": platform.version(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "python": platform.python_version(),
        },
        "env": {
            key: os.environ.get(key)
            for key in [
                "MODEL_API_URL",
                "MODEL_IDENTIFIER",
                "BENCHMARK_PROFILE",
                "BENCHMARK_PROMPTSET",
                "BENCHMARK_RUNS",
                "BENCHMARK_SCENARIOS",
                "BENCHMARK_REQUESTS",
                "BENCHMARK_CONCURRENCY",
                "BENCHMARK_SLO_FILE",
                "BENCHMARK_PROCESS_PATTERNS",
                "RUN_OPENAI_DIRECT",
                "RUN_LLAMA_BENCHY",
                "RUN_LM_EVAL",
                "LLAMA_BENCHY_BIN",
                "LLAMA_BENCHY_ARGS",
                "LM_EVAL_ARGS",
            ]
        },
        "repo": {
            "git_commit": run(["git", "rev-parse", "HEAD"], timeout=2, cwd=str(project_dir)),
            "git_status_short": run(["git", "status", "--short"], timeout=2, cwd=str(project_dir)),
            "build_info": load_build_info(project_dir),
            "content_sha256": content_digest(project_dir),
        },
        "os_commands": {
            "uname": run(["uname", "-a"]),
            "os_release": run(["sh", "-c", "cat /etc/os-release"], timeout=2),
            "lscpu": run(["lscpu"], timeout=3),
            "free": run(["free", "-h"], timeout=2),
            "lsblk": run(["lsblk", "-o", "NAME,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINTS"], timeout=3),
            "df": run(["df", "-h"], timeout=3),
            "lspci": run(["sh", "-c", "command -v lspci >/dev/null && lspci -nnk || true"], timeout=3),
            "lsusb": run(["sh", "-c", "command -v lsusb >/dev/null && lsusb || true"], timeout=3),
            "sensors": run(["sh", "-c", "command -v sensors >/dev/null && sensors || true"], timeout=3),
            "vulkaninfo_summary": run(["sh", "-c", "command -v vulkaninfo >/dev/null && vulkaninfo --summary || true"], timeout=5),
            "glxinfo": run(["sh", "-c", "command -v glxinfo >/dev/null && glxinfo -B || true"], timeout=3),
            "kernel_modules_gpu": run(["sh", "-c", "lsmod | grep -E '^(amdgpu|radeon|nvidia|i915|drm)' || true"], timeout=2),
            "relevant_packages": run(
                [
                    "sh",
                    "-c",
                    "command -v dpkg-query >/dev/null && dpkg-query -W -f='${binary:Package}\t${Version}\n' "
                    "'linux-image*' 'linux-modules*' 'mesa*' 'vulkan*' 'libvulkan*' "
                    "'glslc' 'glslang-tools' 'spirv*' 'cmake' 'ninja-build' 'gcc' 'g++' 'python3' 2>/dev/null || true",
                ],
                timeout=5,
            ),
            "python_packages": run(["sh", "-c", "python3 -m pip freeze 2>/dev/null || true"], timeout=5),
            "uv_tools": run(["sh", "-c", "command -v uv >/dev/null && uv tool list || true"], timeout=5),
            "lms_ps": run(["sh", "-c", "command -v lms >/dev/null && lms ps || true"], timeout=5),
        },
        "tools": {
            "python3": command_version("python3", ["--version"]),
            "curl": command_version("curl", ["--version"]),
            # The model-server binary (lms / llama-server) runs on the GPU
            # container, not in this unprivileged runner, so this probe is
            # usually empty here. The engine and its version are recorded via
            # build-info instead (the Ansible batch captures runtime +
            # engine_version from the model container).
            "lms": command_version("lms", ["--version"]),
            "llama-benchy": command_version("llama-benchy", ["--help"]),
            "lm_eval": command_version("lm_eval", ["--help"]),
            "rocm-smi": command_version("rocm-smi", ["--showdriverversion", "--json"]),
            "nvidia-smi": command_version("nvidia-smi", ["--query-gpu=name,driver_version,vbios_version", "--format=csv"]),
            "llama_benchy_bin": executable_version(os.environ.get("LLAMA_BENCHY_BIN"), ["--help"]),
        },
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
