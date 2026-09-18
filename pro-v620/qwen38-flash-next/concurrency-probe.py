#!/usr/bin/env python3
"""Concurrency probe for the qwen4exp placement work.

Answers the one question `placement-probe.py` cannot: what does `--parallel N` actually
buy on a hybrid CPU+GPU MoE placement, where the bottleneck is engine submission
overhead rather than compute?

Reports three numbers per run:

  per_stream_tps   median decode t/s that ONE of the concurrent streams sees
  aggregate_tps    sum of all streams' decode t/s — the throughput of the box
  n_ctx_per_slot   read back from /props, never assumed

⚠️ `per_stream_tps` is what an interactive user feels and `aggregate_tps` is what a batch
consumer gets. They move in opposite directions, so quoting one alone is how a concurrency
change gets mis-sold. Both are reported, always.

⚠️ The model MUST already be running at the target `--parallel N`. This repo's own rule:
measuring concurrency against a server loaded at a different slot count contaminates the
numbers (p1 read ~53 t/s flat where p4 peaked ~92). This probe therefore *reads* the slot
count back from the server and records it — it never sets it.

⚠️ `cache_prompt: false` on every request. With caching on, N identical concurrent prompts
collapse onto one cached prefix and the run measures cache hits, not concurrency.

Each stream gets a DIFFERENT prompt for the same reason, and the degeneracy gate from
`placement-probe.py` is applied here too: repetition is cheap to generate and would read
as a throughput win.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import json
import statistics as st
import sys
import time
import urllib.error
import urllib.request

# Distinct prompts, one per stream, so no two streams share a prefix. Padded at runtime to
# a common depth so the streams are comparable to each other.
PROMPTS = [
    "Write a Python function that merges two sorted lists without using sorted().",
    "Explain why a memory-bound kernel does not speed up when you add CPU cores.",
    "List six things to check when an LXC container cannot see a GPU render node.",
    "Summarise the trade-off between KV-cache quantisation and thinking termination.",
    "Write a bash function that retries a curl download and actually resumes it.",
    "Describe what a graph split costs in a hybrid CPU/GPU inference engine.",
    "Give a short checklist for validating a speculative-decoding benchmark.",
    "Explain the difference between a counter since process start and a durable ledger.",
]
FILLER = ("The quick brown fox jumps over the lazy dog while the engine schedules yet "
          "another graph split across the PCIe bus. ")


def post(url: str, body: dict, timeout: int = 900) -> dict:
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def get(url: str, timeout: int = 30) -> dict:
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode())


def one(base: str, prompt: str, n_predict: int) -> dict:
    t0 = time.time()
    r = post(base + "/completion",
             {"prompt": prompt, "n_predict": n_predict, "temperature": 0, "top_k": 1,
              "cache_prompt": False, "stream": False})
    wall = time.time() - t0
    tm = r.get("timings", {})
    content = r.get("content") or ""
    words = content.split()
    shingles = {" ".join(words[j:j + 8]) for j in range(max(0, len(words) - 7))}
    uniq = round(len(shingles) / max(1, len(words) - 7), 3)
    return {
        "wall_s": round(wall, 2),
        "prompt_n": tm.get("prompt_n"),
        "prefill_tps": tm.get("prompt_per_second"),
        "predicted_n": tm.get("predicted_n"),
        "decode_tps": tm.get("predicted_per_second"),
        "uniq_8gram": uniq,
        "degenerate": uniq < 0.7,
        "content_sha": hashlib.sha256(content.encode()).hexdigest()[:12],
        "stop": ("eos" if r.get("stopped_eos") else
                 "limit" if r.get("stopped_limit") else "other"),
    }


def server_props(base: str) -> dict:
    """Read the slot geometry back rather than trusting the env file."""
    out = {}
    try:
        p = get(base + "/props")
        # llama.cpp reports the per-slot context under default_generation_settings.
        dgs = p.get("default_generation_settings") or {}
        out["n_ctx_per_slot"] = dgs.get("n_ctx") or p.get("n_ctx")
        out["total_slots"] = p.get("total_slots")
    except Exception as e:  # /props is advisory; a missing one must not fail the run
        out["props_error"] = repr(e)[:160]
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("base", help="e.g. http://192.168.1.x:1234")
    ap.add_argument("streams", type=int, help="concurrent streams to launch")
    ap.add_argument("--reps", type=int, default=2,
                    help="rounds of `streams` concurrent requests (median across rounds)")
    ap.add_argument("--n-predict", type=int, default=160)
    ap.add_argument("--depth", type=int, default=0,
                    help="approximate prompt-token depth to pad every stream to")
    a = ap.parse_args()

    result: dict = {"base": a.base, "streams": a.streams, "reps": a.reps,
                    "n_predict": a.n_predict, "depth_target": a.depth}
    result.update(server_props(a.base))

    # ⚠️ Loud, not silent. A server loaded with fewer slots than the requested stream count
    # will serialise the extras in its queue, and the run would look like perfect scaling
    # failure rather than a misconfiguration.
    slots = result.get("total_slots")
    if isinstance(slots, int) and slots < a.streams:
        result["slot_warning"] = (
            "server reports %d slot(s) but %d streams requested — extra requests QUEUE, "
            "so these numbers describe a queue, not concurrency" % (slots, a.streams))
        print(result["slot_warning"], file=sys.stderr)

    pad = FILLER * max(0, (a.depth * 4) // len(FILLER)) if a.depth else ""
    rounds = []
    for rep in range(a.reps):
        prompts = [pad + PROMPTS[i % len(PROMPTS)] + " (stream %d)" % i
                   for i in range(a.streams)]
        t0 = time.time()
        with cf.ThreadPoolExecutor(max_workers=a.streams) as ex:
            futs = [ex.submit(one, a.base, p, a.n_predict) for p in prompts]
            rows = []
            for i, f in enumerate(futs):
                try:
                    m = f.result()
                except Exception as e:
                    m = {"error": repr(e)[:200]}
                m.update({"stream": i, "rep": rep})
                rows.append(m)
        wall = time.time() - t0

        ok = [r for r in rows if r.get("decode_tps")]
        tokens = sum(r.get("predicted_n") or 0 for r in ok)
        rounds.append({
            "rep": rep,
            "wall_s": round(wall, 2),
            # Per-stream is the median of what each stream individually reported.
            "per_stream_tps": round(st.median([r["decode_tps"] for r in ok]), 2) if ok else 0.0,
            # Aggregate from the engine's own per-stream rates, so a straggler's idle tail
            # is not charged against the streams that finished.
            "aggregate_tps": round(sum(r["decode_tps"] for r in ok), 2) if ok else 0.0,
            # And the honest wall-clock view, which INCLUDES that tail. Both are kept
            # because they answer different questions and can disagree by a lot.
            "wall_aggregate_tps": round(tokens / wall, 2) if wall > 0 else 0.0,
            "completed": len(ok),
            "failed": len(rows) - len(ok),
            "any_degenerate": any(r.get("degenerate") for r in rows),
            "rows": rows,
        })
        print(json.dumps({k: v for k, v in rounds[-1].items() if k != "rows"}),
              file=sys.stderr)

    good = [r for r in rounds if r["completed"]]
    result["rounds"] = rounds
    result["per_stream_tps"] = round(st.median([r["per_stream_tps"] for r in good]), 2) if good else 0.0
    result["aggregate_tps"] = round(st.median([r["aggregate_tps"] for r in good]), 2) if good else 0.0
    result["wall_aggregate_tps"] = round(st.median([r["wall_aggregate_tps"] for r in good]), 2) if good else 0.0
    result["any_degenerate"] = any(r["any_degenerate"] for r in rounds)
    result["total_failed"] = sum(r["failed"] for r in rounds)
    print(json.dumps(result, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
