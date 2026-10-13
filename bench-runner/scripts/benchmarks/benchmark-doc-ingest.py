#!/usr/bin/env python3
"""Cold document ingestion against llama-server, the shape of a knowledge-base ingestion call.

Each request sends documents (this repository's Markdown at a pinned commit, then its code)
filling the prompt to --depths tokens, with the prompt cache off, and asks for a structured
note in three sections: five summary sentences, eight key facts and three open questions. The
prompt sets no length; --max-tokens caps the reply. Depths run interleaved, --reps times, each
rep starting at the next depth. A given depth sends the same text every time, so greedy output should repeat; the
summary records whether it did, and whether the note has the three requested sections.

--prompt concise asks for the same three sections with an overall word limit and limits per
sentence and bullet. Every row carries a quality check: the counts of summary sentences, key
facts and open questions against 5, 8 and 3, word counts, and how many key facts hold a
backticked name or a word with a digit that appears verbatim in the documents. A fact
without one is listed for reading by hand; it is not judged wrong.

Writes ingest-requests.jsonl (one row per request, with the note's full text) and
ingest-summary.json.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from bench_common import (
    REQUEST_ERRORS,
    acceptance,
    chat,
    corpus_info,
    count_tokens,
    http_error_text,
    is_garbage_output,
    long_text,
    server_props,
    spread,
    take_tokens,
    timing_fields,
)

INGEST_SYSTEM = (
    "You maintain the knowledge base of a Proxmox AI homelab. You turn source documents into "
    "structured notes, using only facts the documents state."
)
INGEST_TASK = (
    "Write a knowledge-base note about the documents above, in Markdown, with exactly these sections:\n\n"
    "## Summary\nFive sentences.\n\n"
    "## Key facts\nEight bullet points, each with a concrete value or name from the documents.\n\n"
    "## Open questions\nThree bullet points."
)
CONCISE_TASK = (
    "Write a knowledge-base note about the documents above, in Markdown, with exactly these "
    "sections. Keep the whole note under 400 words.\n\n"
    "## Summary\nFive sentences, each under 30 words.\n\n"
    "## Key facts\nEight bullet points, each under 25 words and each with a concrete value or "
    "name from the documents.\n\n"
    "## Open questions\nThree bullet points, each under 25 words."
)
TASKS = {"standard": INGEST_TASK, "concise": CONCISE_TASK}
SECTIONS = ("## Summary", "## Key facts", "## Open questions")
EXPECTED_COUNTS = (5, 8, 3)
BULLET = re.compile(r"(?m)^\s*(?:[-*+]|\d+[.)])\s+(.*\S)")
# A backticked name, or a whitespace-separated word holding a digit (a version, an ID, a size).
CONCRETE = re.compile(r"`([^`\n]{2,})`|(\S*\d\S*)")
# Chat-template tokens around the two messages, beyond their text.
TEMPLATE_TOKENS = 16


def user_message(documents: str, task: str = INGEST_TASK) -> str:
    return f"<documents>\n{documents}\n</documents>\n\n{task}"


def section(text: str, heading: str) -> str | None:
    """The text under a heading line, up to the next Markdown heading; None if absent."""
    match = re.search(r"(?m)^" + re.escape(heading) + r"[ \t]*$", text)
    if not match:
        return None
    rest = text[match.end():]
    following = re.search(r"(?m)^#{1,6} ", rest)
    return rest[:following.start()] if following else rest


def note_quality(output: str, documents: str) -> dict[str, Any]:
    """Structure and source checks for one note. Sentence splitting is approximate."""
    summary, facts, questions = (section(output, heading) for heading in SECTIONS)
    flat = " ".join((summary or "").split())
    sentences = [part for part in re.split(r"(?<=[.!?])\s+", flat) if part.strip()]
    fact_items = BULLET.findall(facts or "")
    question_items = BULLET.findall(questions or "")
    sourced = []
    for item in fact_items:
        tokens = [ticked or word.strip(".,;:()[]\"'") for ticked, word in CONCRETE.findall(item)]
        sourced.append(any(token and (token in documents or token.replace(",", "") in documents)
                           for token in tokens))
    counts = (len(sentences), len(fact_items), len(question_items))
    return {
        "summary_sentences": counts[0],
        "key_facts": counts[1],
        "open_questions": counts[2],
        "format_ok": counts == EXPECTED_COUNTS,
        "words": len(output.split()),
        "max_sentence_words": max((len(part.split()) for part in sentences), default=0),
        "max_bullet_words": max((len(item.split()) for item in fact_items + question_items), default=0),
        "facts_with_source_value": sum(sourced),
        "facts_without_source_value": [item for item, ok in zip(fact_items, sourced) if not ok],
    }


def depth_label(depth: int) -> str:
    return f"{depth // 1024}k" if depth % 1024 == 0 else str(depth)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", default=os.environ.get("MODEL_API_URL"))
    parser.add_argument("--model", default=os.environ.get("MODEL_IDENTIFIER"))
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--depths", type=int, nargs="+", default=[8192, 16384, 32768, 49152],
                        help="prompt sizes in tokens (default: 8192 16384 32768 49152)")
    parser.add_argument("--reps", type=int, default=3)
    parser.add_argument("--max-tokens", type=int, default=640)
    parser.add_argument("--prompt", choices=sorted(TASKS), default="standard",
                        help="standard, or concise: the same sections with word limits")
    parser.add_argument("--timeout", type=float, default=3600.0)
    args = parser.parse_args()
    if not args.base_url:
        parser.error("--base-url or MODEL_API_URL is required")
    if not args.model:
        parser.error("--model or MODEL_IDENTIFIER is required")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    props = server_props(args.base_url)
    n_ctx = props.get("n_ctx_per_slot")
    if n_ctx and max(args.depths) + args.max_tokens > n_ctx:
        sys.stderr.write(
            f"doc-ingest: a {max(args.depths)}-token prompt and a {args.max_tokens}-token answer need "
            f"{max(args.depths) + args.max_tokens} tokens per slot; the server has {n_ctx}.\n"
        )
        return 2

    task = TASKS[args.prompt]
    frame = INGEST_SYSTEM + user_message("", task)
    overhead = (count_tokens(args.base_url, frame) or len(frame) // 4) + TEMPLATE_TOKENS
    text = long_text()
    documents = {depth: take_tokens(args.base_url, text, depth - overhead) for depth in args.depths}

    # The first request after a model load pays shader compilation; not recorded.
    try:
        chat(args.base_url, {"model": args.model, "messages": [{"role": "user", "content": "Say hello."}],
                             "max_tokens": 8, "temperature": 0, "cache_prompt": False}, args.timeout)
    except REQUEST_ERRORS as exc:
        sys.stderr.write(f"doc-ingest: warm-up request failed: {http_error_text(exc)}\n")
        return 1

    rows: list[dict[str, Any]] = []
    started = time.time()
    with (output_dir / "ingest-requests.jsonl").open("w", encoding="utf-8") as handle:
        for rep in range(1, args.reps + 1):
            shift = (rep - 1) % len(args.depths)
            for depth in args.depths[shift:] + args.depths[:shift]:
                body = {
                    "model": args.model,
                    "messages": [
                        {"role": "system", "content": INGEST_SYSTEM},
                        {"role": "user", "content": user_message(documents[depth], task)},
                    ],
                    "max_tokens": args.max_tokens,
                    "temperature": 0,
                    "top_k": 1,
                    "cache_prompt": False,
                    "stream": False,
                }
                row: dict[str, Any] = {"rep": rep, "depth": depth, "depth_label": depth_label(depth), "t_start": time.time()}
                try:
                    response, wall = chat(args.base_url, body, args.timeout)
                except REQUEST_ERRORS as exc:
                    row.update(status="error", error=http_error_text(exc), t_end=time.time())
                else:
                    choice = (response.get("choices") or [{}])[0]
                    message = choice.get("message") or {}
                    output = message.get("content") or ""
                    prompt_tokens = (response.get("usage") or {}).get("prompt_tokens")
                    fields = timing_fields(response.get("timings"))
                    row.update(fields)
                    row.update(
                        t_end=time.time(),
                        wall_s=round(wall, 3),
                        prompt_tokens=prompt_tokens,
                        finish=choice.get("finish_reason"),
                        sections_ok=all(section in output for section in SECTIONS),
                        content_sha=hashlib.sha256(output.encode("utf-8")).hexdigest()[:16],
                        output=output,
                        quality=note_quality(output, documents[depth]),
                        reasoning=message.get("reasoning_content") or "",
                    )
                    if not output.strip():
                        row.update(status="invalid_output", error="empty response")
                    elif is_garbage_output(output):
                        row.update(status="invalid_output", error="non-text output (>50% '?'/replacement chars)")
                    elif prompt_tokens and fields["prompt_n"] is not None and fields["prompt_n"] < prompt_tokens - 64:
                        # The cache served part of the prompt, so this is not a cold prefill.
                        row.update(status="warm_cache", error=f"prefilled {fields['prompt_n']} of {prompt_tokens} tokens")
                    else:
                        row.update(status="ok", error=None)
                rows.append(row)
                handle.write(json.dumps(row, sort_keys=True) + "\n")
                handle.flush()
                if row["status"] == "ok":
                    print(f"rep {rep} {row['depth_label']:>4}: prefill {row['prompt_n']} @ {row['prompt_tps'] or 0:.1f} t/s, "
                          f"decode {row['predicted_n']} @ {row['decode_tps'] or 0:.1f} t/s, {row['finish']}", flush=True)
                else:
                    print(f"rep {rep} {row['depth_label']:>4}: {row['status']}: {row['error']}", flush=True)
    finished = time.time()

    ok = [row for row in rows if row["status"] == "ok"]
    by_depth = []
    for depth in args.depths:
        group = [row for row in ok if row["depth"] == depth]
        shas = {row["content_sha"] for row in group}
        by_depth.append({
            "label": depth_label(depth),
            "depth": depth,
            "count": len(group),
            "prompt_tokens": spread([row["prompt_tokens"] for row in group]),
            "prefill_tokens_per_second": spread([row["prompt_tps"] for row in group]),
            "prefill_seconds": spread([(row["prompt_ms"] or 0) / 1000 for row in group if row["prompt_ms"]]),
            "decode_tokens_per_second": spread([row["decode_tps"] for row in group]),
            "output_tokens": spread([row["predicted_n"] for row in group]),
            "draft_acceptance": acceptance([row["draft_n"] for row in group], [row["draft_accepted"] for row in group]),
            "finish_reasons": dict(collections.Counter(row["finish"] for row in group)),
            "sections_ok": sum(1 for row in group if row["sections_ok"]),
            "format_ok": sum(1 for row in group if row["quality"]["format_ok"]),
            "words": spread([row["quality"]["words"] for row in group]),
            "facts_with_source_value": spread([row["quality"]["facts_with_source_value"] for row in group]),
            "repeatable": len(group) == args.reps and len(shas) == 1,
        })
    output_tokens = sum(row.get("predicted_n") or 0 for row in ok)
    summary = {
        "label": "ingest",
        "workload": "doc-ingest",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "base_url": args.base_url,
        "model": args.model,
        "server": props,
        "corpus": corpus_info("docs", "code"),
        "depths": args.depths,
        "reps": args.reps,
        "max_tokens": args.max_tokens,
        "prompt": args.prompt,
        "record_count": len(rows),
        "ok_count": len(ok),
        "error_count": len(rows) - len(ok),
        "wall_seconds": finished - started,
        "aggregate_output_tokens": output_tokens,
        "aggregate_output_tokens_per_second": output_tokens / max(finished - started, 1e-6),
        "prefill_tokens_per_second": spread([row["prompt_tps"] for row in ok]),
        "decode_tokens_per_second": spread([row["decode_tps"] for row in ok]),
        "rate_sources": ["server"],
        "by_depth": by_depth,
    }
    (output_dir / "ingest-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({data["label"]: data["prefill_tokens_per_second"]["median"] for data in by_depth}, indent=2))
    return 0 if summary["error_count"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
