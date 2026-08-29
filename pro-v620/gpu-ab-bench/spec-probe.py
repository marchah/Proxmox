#!/usr/bin/env python3
"""Fire a fixed prompt set at a llama-server and report decode speed + draft acceptance.

Native /completion is used (not /v1/chat/completions) so no chat template sits between
the configs being compared, and llama.cpp's `timings` block comes back in full.
temperature 0 => speculative decoding is output-identical to non-speculative, so every
n-max produces the SAME tokens and tok/s is directly comparable.
"""
import json, sys, time, urllib.request

PROMPTS = [
    # Representative of the coding loop's real traffic: implement / explain / review.
    "Write a TypeScript function that debounces an async function, preserving the "
    "return value of the last call. Include JSDoc and explain the edge cases.\n\n",
    "Explain, step by step, how a write-ahead log guarantees durability in a database, "
    "and what happens during crash recovery.\n\n",
    "Review this function and list every defect you find:\n\n"
    "function sum(items) {\n  let t = 0;\n  for (let i = 0; i <= items.length; i++) {\n"
    "    t += items[i].value;\n  }\n  return t;\n}\n\n",
]


def post(url, body, timeout=900):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def main():
    base = sys.argv[1]                                  # e.g. http://127.0.0.1:5999
    n_max = sys.argv[2] if len(sys.argv) > 2 else None  # optional per-request override
    n_predict = int(sys.argv[3]) if len(sys.argv) > 3 else 512
    out = []
    for i, p in enumerate(PROMPTS):
        body = {
            "prompt": p,
            "n_predict": n_predict,
            "temperature": 0,
            "top_k": 1,
            "cache_prompt": False,
            "stream": False,
        }
        if n_max is not None and n_max != "-":
            body["speculative.n_max"] = int(n_max)
        t0 = time.time()
        r = post(base + "/completion", body)
        wall = time.time() - t0
        tm = r.get("timings", {})
        dn, da = tm.get("draft_n"), tm.get("draft_n_accepted")
        # Degeneracy gate: a high n-max can collapse the output into repetition, which
        # drafts almost perfectly and inflates BOTH acceptance and tok/s. Unique-8-gram
        # ratio near 0 means the "speedup" is an artifact, not a config win.
        words = (r.get("content") or "").split()
        shingles = {" ".join(words[j:j+8]) for j in range(max(0, len(words) - 7))}
        uniq = round(len(shingles) / max(1, len(words) - 7), 3)
        out.append({
            "prompt": i,
            "wall_s": round(wall, 2),
            "prompt_n": tm.get("prompt_n"),
            "prompt_tps": tm.get("prompt_per_second"),
            "predicted_n": tm.get("predicted_n"),
            "predicted_tps": tm.get("predicted_per_second"),
            "draft_n": dn,
            "draft_n_accepted": da,
            "accept_pct": (round(100.0 * da / dn, 1) if dn else None),
            "uniq_8gram": uniq,
            "degenerate": uniq < 0.7,
            "content_sha": __import__("hashlib").sha256(
                (r.get("content") or "").encode()).hexdigest()[:12],
            "stop_reason": ("eos" if r.get("stopped_eos") else
                            "limit" if r.get("stopped_limit") else "other"),
        })
    dec = [o["predicted_tps"] for o in out if o["predicted_tps"]]
    tot_d = sum(o["draft_n"] or 0 for o in out)
    tot_a = sum(o["draft_n_accepted"] or 0 for o in out)
    print(json.dumps({
        "per_prompt": out,
        "decode_tps_mean": round(sum(dec) / len(dec), 2) if dec else None,
        "decode_tps_min": round(min(dec), 2) if dec else None,
        "decode_tps_max": round(max(dec), 2) if dec else None,
        "draft_total": tot_d, "draft_accepted": tot_a,
        "accept_pct_overall": round(100.0 * tot_a / tot_d, 1) if tot_d else None,
        "outputs_sha": [o["content_sha"] for o in out],
        "uniq_8gram_min": min((o["uniq_8gram"] for o in out), default=None),
        "any_degenerate": any(o["degenerate"] for o in out),
    }, indent=1))


if __name__ == "__main__":
    main()
