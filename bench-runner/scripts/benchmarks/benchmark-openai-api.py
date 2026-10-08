#!/usr/bin/env python3
"""Benchmark an OpenAI-compatible chat completions endpoint."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import statistics
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from bench_common import corpus_info, file_text, is_garbage_output, long_text, take_tokens

# A scenario with "context" gets real text appended to its prompt: (corpus, first file,
# characters) from the pinned corpus in bench_common.py, about 4 characters per token.
# Every request is sent with a unique leading id (prompt_for).
SCENARIOS = {
    "smoke": {
        "max_tokens": 32,
        "prompt": "Reply with only: Hello!",
    },
    "short": {
        "max_tokens": 128,
        "prompt": (
            "In five concise bullets, explain what metrics matter most when "
            "benchmarking a local AI homelab."
        ),
    },
    "medium": {
        "max_tokens": 256,
        "prompt": (
            "You are evaluating a local AI homelab. Summarize the tradeoffs "
            "between CPU inference, GPU inference, quantization, context "
            "length, and concurrency, using the notes below. Keep the answer practical.\n\n"
        ),
        "context": ("docs", "README.md", 3600),
    },
    "long": {
        "max_tokens": 512,
        "prompt": (
            "Analyze the following operations notes from a homelab repository and "
            "produce a short bottleneck report with upgrade recommendations.\n\n"
        ),
        "context": ("docs", "pro-v620/README.md", 36000),
    },
}
SYNTHETIC_HEADER = "Read the following text, then continue writing about it.\n\n"
# The leading "[<salt>-<index>] " id and the header, in tokens.
SYNTHETIC_OVERHEAD_TOKENS = 24


def load_promptset(path: Path) -> dict[str, dict[str, Any]]:
    scenarios: dict[str, dict[str, Any]] = {}
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            record = json.loads(line)
            scenario_id = record.get("id") or f"prompt_{line_number}"
            if "prompt" not in record:
                raise ValueError(f"{path}:{line_number} is missing 'prompt'")
            scenarios[scenario_id] = {
                "prompt": record["prompt"],
                "max_tokens": int(record.get("max_tokens", 256)),
                "group": record.get("group"),
                "tags": record.get("tags", []),
                "expected": record.get("expected", {}),
            }
    if not scenarios:
        raise ValueError(f"Promptset is empty: {path}")
    return scenarios


def synthetic_prompt(base_url: str, approx_input_tokens: int) -> str:
    """A prompt of about N input tokens of real text, for controlled sweeps.

    The text is cut by the server's tokenizer when it has one (see take_tokens), so a
    sweep point means the same token count on any model.
    """
    body = take_tokens(base_url, long_text(), max(1, approx_input_tokens - SYNTHETIC_OVERHEAD_TOKENS))
    return SYNTHETIC_HEADER + body


def prompt_for(scenario: dict[str, Any], run_salt: str, index: int) -> str:
    """Per-request prompt, led by a unique id so every request is a cold prefill.

    A repeated prompt is otherwise served from the server's prompt cache: on CT 120
    (b11475) the second of three identical 32-token requests prefilled 4 tokens, and
    its prefill rate and TTFT measured the cache. The id also keeps shorter sweep points
    from being prefixes of longer ones. It adds ~11 tokens.
    """
    return f"[{run_salt}-{index}] {scenario['prompt']}"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = int(round((len(ordered) - 1) * pct))
    return ordered[index]


def stats(values: list[float]) -> dict[str, float | None]:
    if not values:
        return {"min": None, "mean": None, "median": None, "p95": None, "p99": None, "max": None}
    return {
        "min": min(values),
        "mean": statistics.fmean(values),
        "median": statistics.median(values),
        "p95": percentile(values, 0.95),
        "p99": percentile(values, 0.99),
        "max": max(values),
    }


def expected_substrings(expected: Any) -> list[str]:
    """Normalize a promptset 'expected' field to a list of required substrings.

    Accepts a bare string or a list, either at the top level or under a
    `contains` key. A string is treated as one substring (not split into chars).
    """
    def as_list(value: Any) -> list[str]:
        if isinstance(value, str):
            return [value] if value else []
        if isinstance(value, (list, tuple)):
            return [str(x) for x in value]
        return []

    if isinstance(expected, dict):
        return as_list(expected.get("contains"))
    return as_list(expected)


def parse_stream_line(line: bytes) -> dict[str, Any] | None:
    line = line.strip()
    if not line or not line.startswith(b"data:"):
        return None
    payload = line[5:].strip()
    if payload == b"[DONE]":
        return {"done": True}
    try:
        return json.loads(payload)
    except json.JSONDecodeError:
        return {"parse_error": payload.decode("utf-8", errors="replace")}


def token_rates(
    *,
    timings: dict[str, Any] | None,
    prompt_tokens: int | None,
    output_tokens: int,
    started: float,
    first_token_at: float | None,
    finished: float,
    stream: bool,
) -> dict[str, Any]:
    """Prefill (pp) and decode (tg) rates for one request, kept apart.

    `output_tokens_per_second` divides by the whole request, so a long prompt reads
    as slow decode. llama-server reports both phases in `timings`; prefer those.
    Otherwise estimate from a stream: pp = prompt tokens / TTFT, tg = tokens after
    the first / time after the first. The client estimate includes network and
    queueing, so `rate_source` records which one a row holds.
    """
    if timings and timings.get("predicted_per_second") is not None:
        return {
            "rate_source": "server",
            "prefill_tokens": timings.get("prompt_n"),
            "prefill_cached_tokens": timings.get("cache_n"),
            "prefill_tokens_per_second": timings.get("prompt_per_second"),
            "decode_tokens_per_second": timings.get("predicted_per_second"),
            "draft_tokens": timings.get("draft_n"),
            "draft_accepted_tokens": timings.get("draft_n_accepted"),
        }
    rates: dict[str, Any] = {
        "rate_source": None,
        "prefill_tokens": prompt_tokens,
        "prefill_cached_tokens": None,
        "prefill_tokens_per_second": None,
        "decode_tokens_per_second": None,
        "draft_tokens": None,
        "draft_accepted_tokens": None,
    }
    if stream and first_token_at is not None:
        rates["rate_source"] = "client"
        ttft = first_token_at - started
        if prompt_tokens and ttft > 0:
            rates["prefill_tokens_per_second"] = prompt_tokens / ttft
        decode_seconds = finished - first_token_at
        if output_tokens > 1 and decode_seconds > 0:
            rates["decode_tokens_per_second"] = (output_tokens - 1) / decode_seconds
    return rates


def phase_stats(records: list[dict[str, Any]]) -> dict[str, Any]:
    """pp / tg stats for a set of ok records. Only compare pp between scenarios
    with the same prompt length: prefill rate rises with batch size."""
    return {
        "prefill_tokens_per_second": stats(
            [r["prefill_tokens_per_second"] for r in records if r.get("prefill_tokens_per_second") is not None]
        ),
        "decode_tokens_per_second": stats(
            [r["decode_tokens_per_second"] for r in records if r.get("decode_tokens_per_second") is not None]
        ),
        "rate_sources": sorted({r["rate_source"] for r in records if r.get("rate_source")}),
    }


def request_chat(
    *,
    endpoint: str,
    model: str,
    prompt: str,
    max_tokens: int,
    temperature: float,
    stream: bool,
    timeout: float,
    request_id: str,
    label: str,
    scenario: str,
    scenario_group: str | None,
    scenario_tags: list[str],
    expected_contains: list[str] | None = None,
) -> dict[str, Any]:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": stream,
    }
    if stream:
        body["stream_options"] = {"include_usage": True}

    encoded = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        endpoint,
        data=encoded,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    started = time.perf_counter()
    first_token_at: float | None = None
    output_parts: list[str] = []
    usage: dict[str, Any] | None = None
    timings: dict[str, Any] | None = None
    status = "ok"
    error: str | None = None
    http_status: int | None = None

    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            http_status = response.status
            if stream:
                for raw_line in response:
                    event = parse_stream_line(raw_line)
                    if not event:
                        continue
                    if event.get("done"):
                        break
                    if "usage" in event and event["usage"]:
                        usage = event["usage"]
                    if event.get("timings"):
                        timings = event["timings"]
                    for choice in event.get("choices", []):
                        delta = choice.get("delta", {})
                        content = delta.get("content")
                        if content:
                            if first_token_at is None:
                                first_token_at = time.perf_counter()
                            output_parts.append(content)
            else:
                payload = json.loads(response.read().decode("utf-8"))
                usage = payload.get("usage")
                timings = payload.get("timings")
                for choice in payload.get("choices", []):
                    content = choice.get("message", {}).get("content", "")
                    if content:
                        first_token_at = first_token_at or time.perf_counter()
                        output_parts.append(content)
    except urllib.error.HTTPError as exc:
        status = "http_error"
        http_status = exc.code
        error = exc.read().decode("utf-8", errors="replace")[-4000:]
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        status = "error"
        error = str(exc)

    finished = time.perf_counter()
    output_text = "".join(output_parts)
    completion_tokens = None
    prompt_tokens = None
    if usage:
        completion_tokens = usage.get("completion_tokens")
        prompt_tokens = usage.get("prompt_tokens")
    estimated_output_tokens = max(1, round(len(output_text.split()) * 1.25)) if output_text else 0
    output_tokens = completion_tokens or estimated_output_tokens
    total_seconds = finished - started
    rates = token_rates(
        timings=timings,
        prompt_tokens=prompt_tokens,
        output_tokens=output_tokens,
        started=started,
        first_token_at=first_token_at,
        finished=finished,
        stream=stream,
    )

    # A 200 with garbage (the cold-prefill cliff) or output missing required
    # content is not a successful request — demote it so it lands in error_count
    # and is excluded from latency/throughput stats.
    if status == "ok":
        if not output_text.strip():
            status = "invalid_output"
            error = "empty response (HTTP 200 but no generated text)"
        elif is_garbage_output(output_text):
            status = "invalid_output"
            error = "non-text output (>50% '?'/replacement chars) — likely the cold-prefill cliff"
        elif expected_contains:
            missing = [s for s in expected_contains if s.lower() not in output_text.lower()]
            if missing:
                status = "invalid_output"
                error = f"expected substring(s) not found: {missing}"

    return {
        "timestamp": now_iso(),
        "label": label,
        "request_id": request_id,
        "scenario": scenario,
        "scenario_group": scenario_group,
        "scenario_tags": scenario_tags,
        "status": status,
        "error": error,
        "http_status": http_status,
        "stream": stream,
        "model": model,
        "prompt_chars": len(prompt),
        "output_chars": len(output_text),
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "estimated_output_tokens": estimated_output_tokens,
        "output_tokens_for_rate": output_tokens,
        "latency_total_seconds": total_seconds,
        "ttft_seconds": (first_token_at - started) if first_token_at is not None else None,
        "output_tokens_per_second": (output_tokens / total_seconds) if total_seconds > 0 else None,
        **rates,
        "usage": usage,
        "timings": timings,
        "output_preview": output_text[:500],
    }


def summarize(records: list[dict[str, Any]], started_at: float, finished_at: float) -> dict[str, Any]:
    ok = [record for record in records if record["status"] == "ok"]
    total_output_tokens = sum(record.get("output_tokens_for_rate") or 0 for record in ok)
    wall_seconds = max(finished_at - started_at, 0.000001)
    return {
        "record_count": len(records),
        "ok_count": len(ok),
        "error_count": len(records) - len(ok),
        "wall_seconds": wall_seconds,
        "aggregate_output_tokens": total_output_tokens,
        "aggregate_output_tokens_per_second": total_output_tokens / wall_seconds,
        "latency_total_seconds": stats([r["latency_total_seconds"] for r in ok]),
        "ttft_seconds": stats([r["ttft_seconds"] for r in ok if r["ttft_seconds"] is not None]),
        "per_request_output_tokens_per_second": stats(
            [r["output_tokens_per_second"] for r in ok if r["output_tokens_per_second"] is not None]
        ),
        **phase_stats(ok),
        "by_scenario": {
            scenario: {
                "count": len([r for r in ok if r["scenario"] == scenario]),
                "latency_total_seconds": stats(
                    [r["latency_total_seconds"] for r in ok if r["scenario"] == scenario]
                ),
                "ttft_seconds": stats(
                    [
                        r["ttft_seconds"]
                        for r in ok
                        if r["scenario"] == scenario and r["ttft_seconds"] is not None
                    ]
                ),
                **phase_stats([r for r in ok if r["scenario"] == scenario]),
            }
            for scenario in sorted({r["scenario"] for r in records})
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=os.environ.get("MODEL_API_URL"))
    parser.add_argument("--model", default=os.environ.get("MODEL_IDENTIFIER"))
    parser.add_argument("--label", default="direct")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--scenario", action="append", choices=sorted(SCENARIOS), help="Scenario to run; repeatable.")
    parser.add_argument("--prompt-file", help="Use a custom prompt file as a single 'custom' scenario.")
    parser.add_argument("--promptset", help="JSONL promptset; each line needs id, prompt, and optional max_tokens/tags.")
    parser.add_argument("--synthetic-input-tokens", type=int, help="Run a single synthetic scenario with ~N input tokens (overrides scenarios/promptset).")
    parser.add_argument("--synthetic-output-tokens", type=int, default=128, help="max_tokens for the synthetic scenario.")
    parser.add_argument("--requests", type=int, default=3, help="Requests per scenario.")
    parser.add_argument("--concurrency", type=int, default=1)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--no-stream", action="store_true")
    args = parser.parse_args()

    if not args.base_url:
        parser.error("--base-url or MODEL_API_URL is required")
    if not args.model:
        parser.error("--model or MODEL_IDENTIFIER is required")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    endpoint = args.base_url.rstrip("/") + "/chat/completions"

    scenarios: dict[str, dict[str, Any]]
    if args.synthetic_input_tokens is not None:
        scenarios = {
            "synthetic": {
                "prompt": synthetic_prompt(args.base_url, args.synthetic_input_tokens),
                "corpus_text": True,
                "max_tokens": args.synthetic_output_tokens,
                "group": "synthetic",
                "tags": ["synthetic"],
            }
        }
    elif args.promptset:
        scenarios = load_promptset(Path(args.promptset))
    elif args.prompt_file:
        prompt = Path(args.prompt_file).read_text(encoding="utf-8")
        scenarios = {"custom": {"prompt": prompt, "max_tokens": 256}}
    else:
        names = args.scenario or ["smoke", "short", "medium"]
        scenarios = {
            name: (
                {**SCENARIOS[name], "prompt": SCENARIOS[name]["prompt"] + file_text(*SCENARIOS[name]["context"]), "corpus_text": True}
                if "context" in SCENARIOS[name]
                else SCENARIOS[name]
            )
            for name in names
        }

    records_path = output_dir / f"openai-{args.label}-requests.jsonl"
    summary_path = output_dir / f"openai-{args.label}-summary.json"
    manifest_path = output_dir / f"openai-{args.label}-manifest.json"

    manifest = {
        "timestamp": now_iso(),
        "label": args.label,
        "base_url": args.base_url,
        "endpoint": endpoint,
        "model": args.model,
        "scenarios": list(scenarios),
        "promptset": args.promptset,
        "synthetic_input_tokens_approx": args.synthetic_input_tokens,
        "corpus": corpus_info("docs", "code") if any(s.get("corpus_text") for s in scenarios.values()) else None,
        "synthetic_output_tokens": args.synthetic_output_tokens if args.synthetic_input_tokens is not None else None,
        "requests_per_scenario": args.requests,
        "concurrency": args.concurrency,
        "stream": not args.no_stream,
        "temperature": args.temperature,
        # Each prompt led by a unique id (prompt_for); earlier runs repeated prompts verbatim.
        "cold_requests": True,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    # One salt per process, so every request id is unique across requests and sweep
    # points (each point is a separate invocation), and differs on reruns too.
    run_salt = uuid.uuid4().hex[:8]

    jobs = []
    for scenario_name, scenario in scenarios.items():
        for index in range(args.requests):
            jobs.append((scenario_name, scenario, index))

    records: list[dict[str, Any]] = []
    started = time.perf_counter()
    with records_path.open("w", encoding="utf-8") as handle:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.concurrency)) as executor:
            futures = [
                executor.submit(
                    request_chat,
                    endpoint=endpoint,
                    model=args.model,
                    prompt=prompt_for(scenario, run_salt, index),
                    max_tokens=int(scenario["max_tokens"]),
                    temperature=args.temperature,
                    stream=not args.no_stream,
                    timeout=args.timeout,
                    request_id=f"{scenario_name}-{index + 1}",
                    label=args.label,
                    scenario=scenario_name,
                    scenario_group=scenario.get("group"),
                    scenario_tags=list(scenario.get("tags", [])),
                    expected_contains=expected_substrings(scenario.get("expected")),
                )
                for scenario_name, scenario, index in jobs
            ]
            for future in concurrent.futures.as_completed(futures):
                record = future.result()
                records.append(record)
                handle.write(json.dumps(record, sort_keys=True) + "\n")
                handle.flush()
    finished = time.perf_counter()

    summary = summarize(records, started, finished)
    summary.update(manifest)
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["error_count"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
