#!/usr/bin/env python3
"""Sweep one load parameter and report the resulting curve.

Modes:
  concurrency   Fixed synthetic prompt, vary --concurrency. Finds the
                throughput saturation knee and where tail latency blows up.
  input-length  Fixed concurrency, vary synthetic input-token count. Maps how
                prefill / TTFT scales with prompt size.

Each sweep point shells out to benchmark-openai-api.py; the per-point summaries
are collected into curve.json and curve.md under --output-dir.

This is a client-side load curve. To see the hardware cause (GPU util, VRAM,
clock throttle, temps) behind a knee, wrap the sweep with the GPU host with
host/run-with-host-telemetry.sh.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
PYTHON_BIN = os.environ.get("PYTHON_BIN", sys.executable or "python3")

DEFAULT_POINTS = {
    "concurrency": [1, 2, 4, 8],
    "input-length": [128, 512, 2048, 8192],
}


def run_point(args: argparse.Namespace, point: int) -> dict[str, Any] | None:
    point_dir = Path(args.output_dir) / f"point-{point}"
    label = f"p{point}"

    if args.mode == "concurrency":
        input_tokens = args.input_tokens
        concurrency = point
    else:
        input_tokens = point
        concurrency = args.concurrency

    command = [
        PYTHON_BIN,
        str(SCRIPT_DIR / "benchmark-openai-api.py"),
        "--base-url", args.base_url,
        "--model", args.model,
        "--label", label,
        "--output-dir", str(point_dir),
        "--synthetic-input-tokens", str(input_tokens),
        "--synthetic-output-tokens", str(args.output_tokens),
        "--requests", str(args.requests),
        "--concurrency", str(concurrency),
        "--timeout", str(args.timeout),
    ]
    print(f"[sweep] {args.mode}={point} (input~{input_tokens} tok, concurrency {concurrency})", file=sys.stderr)
    subprocess.run(command, check=False, stdout=subprocess.DEVNULL)

    summary_path = point_dir / f"openai-{label}-summary.json"
    if not summary_path.exists():
        print(f"[sweep] no summary for point {point}", file=sys.stderr)
        return None
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    latency = summary.get("latency_total_seconds", {})
    ttft = summary.get("ttft_seconds", {})
    return {
        "point": point,
        "input_tokens_approx": input_tokens,
        "concurrency": concurrency,
        "ok": summary.get("ok_count"),
        "total": summary.get("record_count"),
        "errors": summary.get("error_count"),
        "throughput_tok_s": summary.get("aggregate_output_tokens_per_second"),
        "latency_p50_s": latency.get("median"),
        "latency_p95_s": latency.get("p95"),
        "ttft_p50_s": ttft.get("median"),
        "ttft_p95_s": ttft.get("p95"),
    }


def fmt(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.3f}"
    return str(value)


def analyze_concurrency(rows: list[dict[str, Any]]) -> list[str]:
    notes: list[str] = []
    usable = [r for r in rows if r.get("throughput_tok_s") is not None]
    if len(usable) < 2:
        return notes
    peak = max(usable, key=lambda r: r["throughput_tok_s"])
    notes.append(f"Peak aggregate throughput {fmt(peak['throughput_tok_s'])} tok/s at concurrency {peak['concurrency']}.")
    # Saturation knee: first point whose throughput gain over the previous point is < 10%.
    for prev, cur in zip(usable, usable[1:]):
        prev_tp = prev["throughput_tok_s"] or 0
        cur_tp = cur["throughput_tok_s"] or 0
        if prev_tp > 0 and (cur_tp - prev_tp) / prev_tp < 0.10:
            notes.append(
                f"Saturation knee near concurrency {prev['concurrency']}: "
                f"throughput changes only {fmt(100 * (cur_tp - prev_tp) / prev_tp)}% past it "
                f"while p95 latency moves {fmt(prev.get('latency_p95_s'))}s -> {fmt(cur.get('latency_p95_s'))}s."
            )
            break
    return notes


def render_markdown(args: argparse.Namespace, rows: list[dict[str, Any]], notes: list[str]) -> str:
    if args.mode == "concurrency":
        title = "Concurrency Sweep"
        point_col = "Concurrency"
        point_key = "concurrency"
        fixed = f"Fixed: ~{args.input_tokens} input tokens, {args.output_tokens} output tokens, {args.requests} requests/point."
    else:
        title = "Input-Length (Prefill / TTFT) Sweep"
        point_col = "Input tokens (approx)"
        point_key = "input_tokens_approx"
        fixed = f"Fixed: concurrency {args.concurrency}, {args.output_tokens} output tokens, {args.requests} requests/point."

    lines = [
        f"# {title}",
        "",
        f"- Endpoint: `{args.base_url}`",
        f"- Model: `{args.model}`",
        f"- {fixed}",
        "",
        f"| {point_col} | OK | Aggregate tok/s | Latency p50 (s) | Latency p95 (s) | TTFT p50 (s) | TTFT p95 (s) |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        lines.append(
            f"| {row[point_key]} | {fmt(row.get('ok'))}/{fmt(row.get('total'))} | "
            f"{fmt(row.get('throughput_tok_s'))} | {fmt(row.get('latency_p50_s'))} | "
            f"{fmt(row.get('latency_p95_s'))} | {fmt(row.get('ttft_p50_s'))} | {fmt(row.get('ttft_p95_s'))} |"
        )
    if notes:
        lines += ["", "## Observations", ""]
        lines += [f"- {note}" for note in notes]
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=sorted(DEFAULT_POINTS), required=True)
    parser.add_argument("--base-url", default=os.environ.get("MODEL_API_URL"))
    parser.add_argument("--model", default=os.environ.get("MODEL_IDENTIFIER"))
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--points", type=int, nargs="+", help="Sweep points; defaults depend on mode.")
    parser.add_argument("--requests", type=int, default=8, help="Requests per sweep point.")
    parser.add_argument("--input-tokens", type=int, default=512, help="Fixed input tokens (concurrency mode).")
    parser.add_argument("--output-tokens", type=int, default=128, help="Synthetic output tokens (max_tokens).")
    parser.add_argument("--concurrency", type=int, default=1, help="Fixed concurrency (input-length mode).")
    parser.add_argument("--timeout", type=float, default=600.0)
    args = parser.parse_args()

    if not args.base_url:
        parser.error("--base-url or MODEL_API_URL is required")
    if not args.model:
        parser.error("--model or MODEL_IDENTIFIER is required")

    points = args.points or DEFAULT_POINTS[args.mode]
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    rows = [row for row in (run_point(args, point) for point in points) if row]
    notes = analyze_concurrency(rows) if args.mode == "concurrency" else []

    curve = {
        "mode": args.mode,
        "base_url": args.base_url,
        "model": args.model,
        "fixed": {
            "input_tokens": args.input_tokens,
            "output_tokens": args.output_tokens,
            "concurrency": args.concurrency,
            "requests_per_point": args.requests,
        },
        "points": rows,
        "notes": notes,
    }
    (output_dir / "curve.json").write_text(json.dumps(curve, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    markdown = render_markdown(args, rows, notes)
    (output_dir / "curve.md").write_text(markdown, encoding="utf-8")
    print(markdown)

    # A sweep is only successful if every requested point produced a summary and
    # none of them recorded request errors. An empty `rows` (all points failed
    # to produce output) must fail, not pass via all([]) == True.
    missing = len(points) - len(rows)
    if missing > 0:
        print(f"[sweep] {missing} of {len(points)} requested point(s) produced no summary", file=sys.stderr)
    all_points_ok = bool(rows) and missing == 0 and all(r.get("errors") == 0 for r in rows)
    return 0 if all_points_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
