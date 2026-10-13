#!/usr/bin/env python3
"""Measure the prefill an agent turn pays: new text appended to a cached deep context.

Run from the Proxmox host against a llama-server, alone or from placement-sweep.sh (cell
key TURNS):

    ./turn-probe.py http://<ct>:1234 --chat --context-file corpus.txt --depth 30000 \\
        --sizes 32,64,128,256,512,1024,2048 --reps 3

Every request sends the same context (the first --depth tokens of --context-file), then a
chunk of SIZE tokens the server has not seen, then a one-line instruction. Context and
chunks are cut with the server's own tokenizer (/tokenize, /detokenize). The prompt
cache serves the context, so prompt_n is the new tokens and prompt_ms their prefill: the
cost one agent turn pays, which on a model with experts in host RAM is not proportional to
its size. A first request fills the cache with the context alone. Sizes then run
interleaved, rotating their order each rep, and each chunk is a different slice of the
text so that no chunk is ever served from the cache.

The JSON on stdout has every row, the median per size and a straight-line fit
prompt_s = fixed + per_token * prompt_n over all rows. One row per request also goes to
stderr. The exit status is 1 when a request fails or the cache did not serve the context.
"""
import argparse
import json
import math
import pathlib
import statistics
import sys
import time
import urllib.request

INSTRUCTION = "\n</documents>\n\nReply with exactly: OK"


def post(url, body, timeout=3600):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def request(base, prompt, n_predict, chat):
    if chat:
        body = {"messages": [{"role": "user", "content": prompt}], "max_tokens": n_predict,
                "temperature": 0, "top_k": 1, "cache_prompt": True, "stream": False}
        path = "/v1/chat/completions"
    else:
        body = {"prompt": prompt, "n_predict": n_predict, "temperature": 0, "top_k": 1,
                "cache_prompt": True, "stream": False}
        path = "/completion"
    t0 = time.time()
    r = post(base + path, body)
    tm = r.get("timings", {})
    content = (r["choices"][0].get("message") or {}).get("content") if chat else r.get("content")
    return {
        "t0": round(t0, 3),
        "wall_s": round(time.time() - t0, 2),
        "prompt_n": tm.get("prompt_n"),
        "cache_n": tm.get("cache_n"),
        "prompt_ms": tm.get("prompt_ms"),
        "prefill_tps": tm.get("prompt_per_second"),
        "predicted_ms": tm.get("predicted_ms"),
        "content": (content or "")[:40],
    }


def fit(points):
    """Least-squares (fixed, per_token) for prompt_s against prompt_n; None below 2 sizes."""
    if len({n for n, _ in points}) < 2:
        return None
    mx = statistics.mean(n for n, _ in points)
    my = statistics.mean(s for _, s in points)
    sxx = sum((n - mx) ** 2 for n, _ in points)
    slope = sum((n - mx) * (s - my) for n, s in points) / sxx
    return {"fixed_s": round(my - slope * mx, 3), "per_token_ms": round(slope * 1000, 3)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("base")
    ap.add_argument("--context-file", required=True)
    ap.add_argument("--depth", type=int, default=30000,
                    help="approximate tokens of cached context before each chunk")
    ap.add_argument("--sizes", default="32,64,128,256,512,1024,2048",
                    help="comma-separated approximate chunk sizes, in tokens")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--n-predict", type=int, default=8)
    ap.add_argument("--chat", action="store_true",
                    help="send the prompts through /v1/chat/completions")
    a = ap.parse_args()
    sizes = [int(s) for s in a.sizes.split(",") if s.strip()]
    if a.reps < 1 or a.depth < 1 or not sizes or min(sizes) < 1:
        ap.error("--depth, --sizes and --reps must be positive")

    text = pathlib.Path(a.context_file).read_text(errors="replace")
    result = {"base": a.base, "depth_target": a.depth, "sizes": sizes, "reps": a.reps,
              "chat": a.chat, "context_file": a.context_file}
    # ~6 chars per token is more than any tokenizer here packs, so the slice holds enough.
    tokens = post(a.base + "/tokenize",
                  {"content": text[:(a.depth + sum(sizes) * a.reps) * 6]})["tokens"]
    if len(tokens) < a.depth + max(sizes):
        sys.exit("%s holds %d tokens; --depth and the largest size need %d"
                 % (a.context_file, len(tokens), a.depth + max(sizes)))
    context = post(a.base + "/detokenize", {"tokens": tokens[:a.depth]})["content"]
    rest = tokens[a.depth:]
    try:
        prime = request(a.base, "<documents>\n" + context + INSTRUCTION, a.n_predict, a.chat)
    except Exception as e:
        result.update(error="priming request failed: %r" % (e,), probe_ok=False)
        print(json.dumps(result, indent=1))
        return 1
    result["prime"] = prime
    context_n = (prime.get("prompt_n") or 0) + (prime.get("cache_n") or 0)

    rows, offset = [], 0
    for rep in range(a.reps):
        shift = rep % len(sizes)
        for size in sizes[shift:] + sizes[:shift]:
            if offset + size > len(rest):
                offset = 0
            chunk = post(a.base + "/detokenize", {"tokens": rest[offset:offset + size]})["content"]
            offset += size
            try:
                m = request(a.base, "<documents>\n" + context + chunk + INSTRUCTION,
                            a.n_predict, a.chat)
            except Exception as e:
                m = {"error": repr(e)[:200]}
            m.update(size_target=size, rep=rep)
            # The turn's cost is only measured if the cache served the context; otherwise
            # this row timed a deep prefill.
            if "error" not in m and (m.get("cache_n") or 0) < 0.9 * context_n:
                m["error"] = "cache served %s of the %d context tokens" % (m.get("cache_n"), context_n)
            if "error" not in m and not (isinstance(m.get("prompt_ms"), (int, float))
                                         and math.isfinite(m["prompt_ms"])):
                m["error"] = "missing prompt timing"
            rows.append(m)
            print(json.dumps(m), file=sys.stderr)
    result["context_tokens"] = context_n
    result["rows"] = rows

    ok = [r for r in rows if "error" not in r]
    by = {}
    for r in ok:
        by.setdefault(r["size_target"], []).append(r)
    result["summary"] = {
        str(size): {"prompt_n_median": statistics.median(r["prompt_n"] for r in rs),
                    "prompt_s_median": round(statistics.median(r["prompt_ms"] for r in rs) / 1000, 3),
                    "prefill_tps_median": round(statistics.median(r["prefill_tps"] for r in rs), 1),
                    "count": len(rs)}
        for size, rs in sorted(by.items())
    }
    result["fit"] = fit([(r["prompt_n"], r["prompt_ms"] / 1000) for r in ok])
    result["failed_requests"] = len(rows) - len(ok)
    result["probe_ok"] = bool(ok) and not result["failed_requests"]
    print(json.dumps(result, indent=1))
    return 0 if result["probe_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
