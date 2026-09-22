#!/usr/bin/env python3
"""One measurement pass against a running llama-server, for the speculative-decoding A/B.

Runs INSIDE CT 120 against localhost. The host driver (run-ab.sh) loads one arm, calls
this once per repetition, then swaps arms. Every request is written as one JSONL row.

Cells per pass:

  short/<class>/greedy     c1, temperature 0 — output is compared across arms
  short/<class>/default    c1, the GGUF's embedded sampling (what Hermes actually gets)
  c2/<class>               two different prompts at once, default sampling
  deep/<depth>             c1, a repository-text context of ~<depth> tokens, default sampling
  tool                     c1 greedy with a tool schema: must return a parseable tool call

⚠️ `cache_prompt: false` everywhere. A spec arm must not look faster because it reused a
prefix the control had to prefill.

⚠️ Speculative decoding can fake a speedup through degenerate repetition. Every row carries
`distinct4` (unique 4-grams / 4-grams); the report flags anything that collapses.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import sys
import time
import urllib.request

URL = "http://127.0.0.1:1234"
MAX_TOKENS = 512

SHORT = {
    "code": "Write a Python module implementing a thread-safe LRU cache with per-entry TTL. "
            "Include type hints, docstrings, and a pytest test file.",
    "prose": "Explain to a new engineer why a memory-bandwidth-bound workload stops getting "
             "faster when you add CPU cores. Use concrete numbers and an analogy.",
    "json": "Produce a JSON array of 12 fictional servers. Each object has hostname, ip, "
            "role, cpu_cores, ram_gb, disks (array of {device, size_gb}), and tags.",
}
# Second stream for c2, so the two concurrent requests never share a prefix.
SHORT_B = {
    "code": "Write a Go HTTP middleware that rate-limits per client IP with a token bucket, "
            "plus a table-driven test.",
    "prose": "Describe how a write-ahead log gives a database crash consistency. Walk through "
             "a crash in the middle of a transaction.",
    "json": "Produce a JSON object describing a CI pipeline with 8 jobs, each with name, image, "
            "script (array), needs (array), and artifacts.",
}
DEEP_Q = ("Using the repository files above, write a bash script that checks each Proxmox "
          "guest this repository provisions is running and prints a one-line status per "
          "guest. Explain each check briefly.")
TOOLS = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Current weather for a city",
        "parameters": {"type": "object", "properties": {
            "city": {"type": "string"}, "unit": {"type": "string", "enum": ["c", "f"]}},
            "required": ["city"]},
    },
}]


def post(body: dict, timeout: int = 1800) -> tuple[dict, float]:
    req = urllib.request.Request(URL + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        out = json.load(r)
    return out, time.monotonic() - t0


def distinct4(text: str) -> float:
    w = text.split()
    grams = [tuple(w[i:i + 4]) for i in range(len(w) - 3)]
    return round(len(set(grams)) / len(grams), 3) if grams else 1.0


def request(prompt: str, greedy: bool, tools: bool = False) -> dict:
    body = {"messages": [{"role": "user", "content": prompt}], "max_tokens": MAX_TOKENS,
            "cache_prompt": False, "stream": False}
    if greedy:
        body.update(temperature=0, top_k=1)
    if tools:
        body["tools"] = TOOLS
    out, wall = post(body)
    msg = out["choices"][0]["message"]
    content = msg.get("content") or ""
    t = out.get("timings", {})
    row = {
        "wall_s": round(wall, 3),
        "prompt_n": t.get("prompt_n"),
        "prompt_tps": t.get("prompt_per_second"),
        "predicted_n": t.get("predicted_n"),
        "decode_tps": t.get("predicted_per_second"),
        "draft_n": t.get("draft_n"),
        "draft_accepted": t.get("draft_n_accepted"),
        "finish": out["choices"][0].get("finish_reason"),
        "distinct4": distinct4(content),
        "content": content,
    }
    if tools:
        calls = msg.get("tool_calls") or []
        ok = False
        try:
            ok = bool(calls) and all(
                c["function"]["name"] == "get_weather"
                and "city" in json.loads(c["function"]["arguments"]) for c in calls)
        except (KeyError, TypeError, ValueError):
            ok = False
        row.update(tool_calls=len(calls), tool_ok=ok)
    return row


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True)
    ap.add_argument("--rep", type=int, required=True)
    ap.add_argument("--deep-file", required=True)
    ap.add_argument("--depths", default="16000,48000", help="approx tokens")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    corpus = open(a.deep_file, encoding="utf-8").read()
    rows = []

    def emit(cell: str, r: dict) -> None:
        r.update(arm=a.arm, rep=a.rep, cell=cell, ts=time.time())
        rows.append(r)
        print(f"  {cell:22s} decode={r['decode_tps']!s:>8} prefill={r['prompt_tps']!s:>8} "
              f"n={r['predicted_n']} draft={r.get('draft_accepted')}/{r.get('draft_n')} "
              f"d4={r['distinct4']}", flush=True)

    # Warm-up: first request after load pays shader/pipeline compilation.
    request("Say hello.", greedy=True)

    for cls, p in SHORT.items():
        emit(f"short/{cls}/greedy", request(p, greedy=True))
        emit(f"short/{cls}/default", request(p, greedy=False))

    for cls in SHORT:
        t0 = time.monotonic()
        with cf.ThreadPoolExecutor(2) as ex:
            fa = ex.submit(request, SHORT[cls], False)
            fb = ex.submit(request, SHORT_B[cls], False)
            ra, rb = fa.result(), fb.result()
        wall = time.monotonic() - t0
        agg = round(((ra["predicted_n"] or 0) + (rb["predicted_n"] or 0)) / wall, 2)
        for tag, r in (("a", ra), ("b", rb)):
            r["c2_aggregate_tps"] = agg
            emit(f"c2/{cls}/{tag}", r)

    for depth in (int(d) for d in a.depths.split(",")):
        # ~3.3 chars/token for this mix of shell, Python and Markdown.
        ctx = corpus[: int(depth * 3.3)]
        emit(f"deep/{depth}", request(ctx + "\n\n" + DEEP_Q, greedy=False))

    emit("tool", request("What is the weather in Paris and in Tokyo, in celsius?",
                         greedy=True, tools=True))

    with open(a.out, "a", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
