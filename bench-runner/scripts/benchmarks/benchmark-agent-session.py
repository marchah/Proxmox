#!/usr/bin/env python3
"""Scripted agent sessions against llama-server: the context grows turn by turn, as an agent's does.

Each --presets entry is PRESET[:SESSIONS], e.g. `hermes` or `coding:2`. A session is one
conversation that grows until its prompt reaches the preset's target depth. Every turn adds a
user message (a tool result and a request), and the model's reply stays in the history, as an
agent's does. The prompt cache stays on, so a turn prefills only the new message. Greedy
decoding makes the replies, and so the whole session, repeat on the same model and build.
Each session opens with its own id, so no session or repetition can reuse another's cache,
in a slot or in llama-server's host-memory prompt cache.

  hermes  the shape of CT 120's Hermes traffic since 2026-09-22: a ~9k-token cold start, then
          tool results of ~100 to ~4,000 tokens and replies capped at 20 to 750 tokens, to 64k.
  coding  a coding agent, as in pro-v620/rocm-ab/agent-sim.py: ~4.7k-token file reads with
          short answers and a code-writing request every third turn, to 124k.

SESSIONS > 1 runs that many sessions at once, each starting at a different part of the corpus,
so the server needs that many slots of the preset's size. Presets run interleaved, --reps
times. Greedy decoding. Writes agent-requests.jsonl (one row per turn) and agent-summary.json.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import math
import os
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator

from bench_common import (
    REQUEST_ERRORS,
    acceptance,
    chat,
    corpus,
    corpus_info,
    count_tokens,
    file_text,
    http_error_text,
    is_garbage_output,
    rate,
    server_props,
    spread,
    timing_fields,
)

CODING_SYSTEM = (
    "You are a coding agent working in a homelab infrastructure repository (Proxmox, "
    "LXC containers, llama.cpp model servers, bash and Python tooling). You read files "
    "through tools and make precise, minimal changes."
)
READ_Q = (
    "Tool result: contents of the next part of the repository.\n\n```\n{chunk}\n```\n\n"
    "In at most three sentences: what does this part do, and what would you inspect next?"
)
WRITE_QS = [
    "Write a bash function `wait_for_health URL TIMEOUT` that polls a llama-server /health "
    "endpoint until it answers or the timeout expires. Output only the code.",
    "Write a Python function that parses llama-server `print_timing` log lines into dicts "
    "with prompt and eval token counts and rates. Output only the code.",
    "Write a bash script that checks every Proxmox container listed in a file is running and "
    "restarts the ones that are not, logging each action. Output only the code.",
    "Write a Python function that reads amdgpu hwmon junction and memory temperatures for a "
    "given PCI address and returns them in Celsius. Output only the code.",
]

HERMES_SYSTEM = (
    "You are Hermes, the operator's assistant for a Proxmox AI homelab, answering in Slack. "
    "You call tools (web search, page extraction, the knowledge base, shell access to the lab) "
    "and answer from their results. Be accurate and concise.\n\n## Notes on the lab\n\n{notes}"
)
HERMES_NOTES_CHARS = 32000
HERMES_TOOL = "Tool result:\n\n```\n{chunk}\n```\n\n{request}"
# (tool-result characters, reply cap in tokens, request), cycled. At ~3.55 characters per
# token (Qwen3.6, Markdown) the results run ~100 to ~4,000 tokens. The sizes and caps aim
# at CT 120's Hermes requests since 2026-09-22: 564 new prompt tokens at the median and
# 4,326 at the 90th percentile, 184 generated tokens at the median.
HERMES_STEPS = [
    (1100, 200, "Answer the operator's question from this result in two or three sentences."),
    (400, 30, "Acknowledge this result in one short line."),
    (14200, 750, "Write the operator a full answer from this result: a few short sections, then a list of next steps."),
    (1250, 200, "Summarize what this result changes, in four or five sentences."),
    (550, 20, "Reply with one word: done or blocked."),
    (3900, 400, "Explain this result to the operator in two short paragraphs."),
    (900, 200, "List the three most important points in this result."),
    (8200, 200, "Answer the operator in one short paragraph."),
    (450, 60, "Reply with one sentence."),
    (1800, 180, "Say what you would check next, and why, in two sentences."),
]

Turn = tuple[str, str, int]  # kind, user message, reply cap


def coding_turns(text: str, offset: int) -> Iterator[Turn]:
    doubled = text + text
    position, turn, writes = offset % len(text), 0, 0
    while True:
        turn += 1
        if turn % 3 == 0:
            yield "write", WRITE_QS[writes % len(WRITE_QS)], 512
            writes += 1
        else:
            chunk = doubled[position:position + 16000]
            position = (position + 16000) % len(text)
            yield "read", READ_Q.format(chunk=chunk), 160


def hermes_turns(text: str, offset: int) -> Iterator[Turn]:
    doubled = text + text
    position, step = offset % len(text), 0
    while True:
        chars, cap, request = HERMES_STEPS[step % len(HERMES_STEPS)]
        step += 1
        chunk = doubled[position:position + chars]
        position = (position + chars) % len(text)
        yield "tool", HERMES_TOOL.format(chunk=chunk, request=request), cap


PRESETS: dict[str, dict[str, Any]] = {
    "hermes": {
        "corpus": "docs",
        "target": 64000,
        "system": lambda: HERMES_SYSTEM.format(notes=file_text("docs", "CLAUDE.md", HERMES_NOTES_CHARS)),
        "turns": hermes_turns,
        # Tool results start after the text the system prompt already holds.
        "first_offset": HERMES_NOTES_CHARS,
        # (characters a turn's message adds, its reply cap) for each kind of turn.
        "turn_sizes": [(chars + len(HERMES_TOOL) + len(request), cap) for chars, cap, request in HERMES_STEPS],
    },
    "coding": {
        "corpus": "code",
        # The last turn can start just under the target after a 512-token write and add a
        # ~4.7k-token read: 124k keeps that inside a 128k slot.
        "target": 124000,
        "system": lambda: CODING_SYSTEM,
        "turns": coding_turns,
        "first_offset": 0,
        "turn_sizes": [(16000 + len(READ_Q), 160), (max(map(len, WRITE_QS)), 512)],
    },
}

# Depth bands for the per-band rates, by the depth a turn prefills at.
BANDS = [
    (0, 16384, "0-16k"),
    (16384, 32768, "16-32k"),
    (32768, 65536, "32-64k"),
    (65536, 98304, "64-96k"),
    (98304, 131072, "96-128k"),
    (131072, math.inf, "128k+"),
]
# A warm turn re-prefills a few template tokens where the last reply joins the history;
# more than this means the slot lost the session's cache (another client took the slot,
# or the cache was evicted).
CACHE_SLACK = 64
MAX_TURNS = 400


def parse_spec(value: str) -> tuple[str, int]:
    preset, _, sessions = value.partition(":")
    if preset not in PRESETS:
        raise argparse.ArgumentTypeError(f"unknown preset {preset!r}; choose from {', '.join(PRESETS)}")
    try:
        count = int(sessions or 1)
    except ValueError:
        raise argparse.ArgumentTypeError(f"bad session count in {value!r}") from None
    if count < 1:
        raise argparse.ArgumentTypeError(f"bad session count in {value!r}")
    return preset, count


def spec_label(preset: str, sessions: int) -> str:
    return f"{preset}:{sessions}"


def run_session(
    args: argparse.Namespace,
    preset: str,
    sessions: int,
    rep: int,
    session: int,
    sink: Callable[[dict[str, Any]], None],
) -> None:
    config = PRESETS[preset]
    target = args.depth or config["target"]
    text = corpus(config["corpus"])
    # Session s reads from a different eighth of the corpus, as concurrent agents work on
    # different files.
    offset = config["first_offset"] + session * len(text) // 8
    turns = config["turns"](text, offset)
    session_id = uuid.uuid4().hex[:12]
    messages: list[dict[str, str]] = [
        {"role": "system", "content": f"Session {session_id}.\n\n{config['system']()}"}
    ]
    prompt_tokens = previous_prompt = 0

    for turn in range(1, MAX_TURNS + 1):
        if prompt_tokens >= target:
            return
        kind, content, max_tokens = next(turns)
        messages.append({"role": "user", "content": content})
        body = {
            "model": args.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": 0,
            "top_k": 1,
            "cache_prompt": True,
            "stream": False,
        }
        row: dict[str, Any] = {
            "spec": spec_label(preset, sessions),
            "preset": preset,
            "sessions": sessions,
            "rep": rep,
            "session": session,
            "session_id": session_id,
            "turn": turn,
            "kind": kind,
            "max_tokens": max_tokens,
            "t_start": time.time(),
        }
        try:
            response, wall = chat(args.base_url, body, args.timeout)
        except REQUEST_ERRORS as exc:
            # The history after a failed turn is not the one the next turn expects.
            row.update(status="error", error=http_error_text(exc), t_end=time.time())
            sink(row)
            return

        choice = (response.get("choices") or [{}])[0]
        output = (choice.get("message") or {}).get("content") or ""
        usage_prompt = (response.get("usage") or {}).get("prompt_tokens")
        fields = timing_fields(response.get("timings"))
        row.update(fields)
        row.update(
            t_end=time.time(),
            wall_s=round(wall, 3),
            finish=choice.get("finish_reason"),
            output_tokens=(response.get("usage") or {}).get("completion_tokens"),
            output_preview=output[:200],
        )
        if not usage_prompt or fields["prompt_n"] is None:
            row.update(status="error", error="response has no usage.prompt_tokens or timings.prompt_n")
            sink(row)
            return
        prompt_tokens = usage_prompt
        row["depth_before"] = prompt_tokens - fields["prompt_n"]
        row["depth_after"] = prompt_tokens
        row["cache_miss"] = turn > 1 and row["depth_before"] < previous_prompt - CACHE_SLACK
        if not output.strip():
            row.update(status="invalid_output", error="empty response")
        elif is_garbage_output(output):
            row.update(status="invalid_output", error="non-text output (>50% '?'/replacement chars)")
        else:
            row.update(status="ok", error=None)
        sink(row)
        previous_prompt = prompt_tokens
        messages.append({"role": "assistant", "content": output})

    if prompt_tokens >= target:
        return
    sink({"spec": spec_label(preset, sessions), "preset": preset, "sessions": sessions, "rep": rep,
          "session": session, "turn": MAX_TURNS + 1, "status": "error",
          "error": f"no {target}-token depth after {MAX_TURNS} turns", "t_start": time.time(),
          "t_end": time.time()})


def check_fit(args: argparse.Namespace, specs: list[tuple[str, int]], props: dict[str, Any]) -> list[str]:
    """Problems that would make a preset overflow its slot or queue behind itself."""
    n_ctx, slots = props.get("n_ctx_per_slot"), props.get("total_slots")
    problems = []
    for preset, sessions in specs:
        config = PRESETS[preset]
        sample = corpus(config["corpus"])[:65536]
        tokens = count_tokens(args.base_url, sample)
        chars_per_token = len(sample) / tokens if tokens else 3.5
        # The last turn starts just below the target, after the largest reply, and adds one
        # more message and its reply.
        largest_reply = max(cap for _, cap in config["turn_sizes"])
        largest_turn = max(math.ceil(chars / chars_per_token) + cap for chars, cap in config["turn_sizes"])
        headroom = largest_reply + largest_turn + 64
        need = (args.depth or config["target"]) + headroom
        if n_ctx and need > n_ctx:
            problems.append(
                f"{spec_label(preset, sessions)} needs ~{need} tokens per slot; the server has {n_ctx}. "
                f"Reload with fewer slots, or stop sessions at --depth {(n_ctx - headroom) // 1000 * 1000} "
                "(BENCHMARK_AGENT_DEPTH) or less."
            )
        if slots and sessions > slots:
            problems.append(f"{spec_label(preset, sessions)} runs {sessions} sessions at once; the server has {slots} slots.")
    return problems


def summarize_spec(label: str, target: int, rows: list[dict[str, Any]], reps: int) -> dict[str, Any]:
    ok = [row for row in rows if row["status"] == "ok"]
    first = [row for row in ok if row["turn"] == 1]
    warm = [row for row in ok if row["turn"] > 1 and not row.get("cache_miss")]

    walls, prefilled, generated = [], [], []
    for rep in sorted({row["rep"] for row in rows}):
        rep_rows = [row for row in rows if row["rep"] == rep]
        walls.append(max(row["t_end"] for row in rep_rows) - min(row["t_start"] for row in rep_rows))
        prefilled.append(sum(row.get("prompt_n") or 0 for row in rep_rows))
        generated.append(sum(row.get("predicted_n") or 0 for row in rep_rows))
    final_depths = {}
    for row in ok:
        key = (row["rep"], row["session"])
        final_depths[key] = max(final_depths.get(key, 0), row["depth_after"])

    bands = []
    for low, high, band_label in BANDS:
        band = [row for row in warm if low <= row["depth_before"] < high]
        if not band:
            continue
        bands.append({
            "band": band_label,
            "turns": len(band),
            "prefill_tokens": sum(row["prompt_n"] or 0 for row in band),
            "prefill_tokens_per_second": rate([r["prompt_n"] for r in band], [r["prompt_ms"] for r in band]),
            "decode_tokens": sum(row["predicted_n"] or 0 for row in band),
            "decode_tokens_per_second": rate([r["predicted_n"] for r in band], [r["predicted_ms"] for r in band]),
            "draft_acceptance": acceptance([r["draft_n"] for r in band], [r["draft_accepted"] for r in band]),
        })

    return {
        "spec": label,
        "target_tokens": target,
        "reps": reps,
        "turns": len(rows),
        "ok_turns": len(ok),
        "errors": len(rows) - len(ok),
        "cache_misses": sum(1 for row in ok if row.get("cache_miss")),
        "session_wall_seconds": spread(walls),
        "final_depth": spread(list(final_depths.values())),
        "prefill_tokens_per_rep": spread(prefilled),
        "decode_tokens_per_rep": spread(generated),
        "first_turn": {
            "prefill_tokens": spread([row["prompt_n"] for row in first]),
            "prefill_tokens_per_second": spread([row["prompt_tps"] for row in first]),
            "decode_tokens_per_second": spread([row["decode_tps"] for row in first]),
        },
        "bands": bands,
        "draft_acceptance": acceptance([r["draft_n"] for r in warm], [r["draft_accepted"] for r in warm]),
        "finish_length": sum(1 for row in ok if row.get("finish") == "length"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", default=os.environ.get("MODEL_API_URL"))
    parser.add_argument("--model", default=os.environ.get("MODEL_IDENTIFIER"))
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--presets", nargs="+", type=parse_spec, default=[("hermes", 1), ("coding", 1)],
                        metavar="PRESET[:SESSIONS]", help="default: hermes coding")
    parser.add_argument("--reps", type=int, default=3)
    parser.add_argument("--depth", type=int, default=0, help="stop every session at this many tokens instead "
                        "of its preset's depth (0, the default, keeps the preset's)")
    parser.add_argument("--timeout", type=float, default=3600.0)
    args = parser.parse_args()
    if not args.base_url:
        parser.error("--base-url or MODEL_API_URL is required")
    if not args.model:
        parser.error("--model or MODEL_IDENTIFIER is required")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    props = server_props(args.base_url)
    problems = check_fit(args, args.presets, props)
    if problems:
        for problem in problems:
            sys.stderr.write(f"agent-sessions: {problem}\n")
        return 2

    # The first request after a model load pays shader compilation; not recorded.
    try:
        chat(args.base_url, {"model": args.model, "messages": [{"role": "user", "content": "Say hello."}],
                             "max_tokens": 8, "temperature": 0, "cache_prompt": False}, args.timeout)
    except REQUEST_ERRORS as exc:
        sys.stderr.write(f"agent-sessions: warm-up request failed: {http_error_text(exc)}\n")
        return 1

    rows: list[dict[str, Any]] = []
    lock = threading.Lock()
    records_path = output_dir / "agent-requests.jsonl"
    started = time.time()
    with records_path.open("w", encoding="utf-8") as handle:
        def sink(row: dict[str, Any]) -> None:
            with lock:
                rows.append(row)
                handle.write(json.dumps(row, sort_keys=True) + "\n")
                handle.flush()
            if row.get("status") == "ok":
                print(f"{row['spec']} rep {row['rep']} s{row['session']} turn {row['turn']:3d} "
                      f"depth {row['depth_before']:6d}->{row['depth_after']:6d} "
                      f"prefill {row['prompt_n']:5d} @ {row['prompt_tps'] or 0:7.1f} t/s "
                      f"decode {row['predicted_n']} @ {row['decode_tps'] or 0:5.1f} t/s", flush=True)
            else:
                print(f"{row['spec']} rep {row['rep']} s{row['session']} turn {row['turn']}: "
                      f"{row['status']}: {row.get('error')}", flush=True)

        for rep in range(1, args.reps + 1):
            for preset, sessions in args.presets:
                with concurrent.futures.ThreadPoolExecutor(max_workers=sessions) as pool:
                    futures = [pool.submit(run_session, args, preset, sessions, rep, session, sink)
                               for session in range(sessions)]
                    for future in futures:
                        future.result()
    finished = time.time()

    ok = [row for row in rows if row["status"] == "ok"]
    warm = [row for row in ok if row["turn"] > 1 and not row.get("cache_miss")]
    output_tokens = sum(row.get("predicted_n") or 0 for row in ok)
    labels = [spec_label(preset, sessions) for preset, sessions in args.presets]
    summary = {
        "label": "agent",
        "workload": "agent-sessions",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "base_url": args.base_url,
        "model": args.model,
        "server": props,
        "corpus": corpus_info(*sorted({PRESETS[preset]["corpus"] for preset, _ in args.presets})),
        "presets": labels,
        "reps": args.reps,
        "record_count": len(rows),
        "ok_count": len(ok),
        "error_count": len(rows) - len(ok),
        "wall_seconds": finished - started,
        "aggregate_output_tokens": output_tokens,
        "aggregate_output_tokens_per_second": output_tokens / max(finished - started, 1e-6),
        "prefill_tokens_per_second": spread([row["prompt_tps"] for row in warm]),
        "decode_tokens_per_second": spread([row["decode_tps"] for row in ok]),
        "rate_sources": ["server"],
        "runs": [
            summarize_spec(spec_label(preset, sessions), args.depth or PRESETS[preset]["target"],
                           [row for row in rows if row["spec"] == spec_label(preset, sessions)], args.reps)
            for preset, sessions in args.presets
        ],
    }
    (output_dir / "agent-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({run["spec"]: run["session_wall_seconds"] for run in summary["runs"]}, indent=2))
    return 0 if summary["error_count"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
