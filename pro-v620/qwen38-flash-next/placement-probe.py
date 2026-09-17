#!/usr/bin/env python3
"""Measure Qwen3.8-Flash-Next decode/prefill at a fixed placement, by prompt class and depth.

Run from the Proxmox host against CT 120's llama-server.

Why /completion and not /v1/chat/completions for the throughput rows: no chat template
sits between configs, and llama.cpp returns the full `timings` block. The chat path is
still exercised once, by --contract, because this model's template is the one thing that
can turn a working server into 500s (see below).

⚠️ Three things this model breaks that others here do not:

  1. Its template resolves `reasoning_effort|default('xhigh')` and RAISES on "none" and
     "high". Qwen3.8-27B is the exact opposite — there "none" is the off switch. So the
     server runs --reasoning off and no caller should send reasoning_effort at all.
     --contract asserts that end of it.
  2. Decode cost grows with CONTEXT DEPTH, not just with placement: the QSA indexer
     rescored every block summary over the whole cached context every token until
     llama.cpp #28699 (still an open draft). A single short-prompt number is therefore
     not a throughput figure for this model. Hence --depths.
  3. Speculation is NOT in play. The MTP head is not deployed, so draft_n is absent and
     tok/s is a plain bandwidth number — unlike CT 123's coder, where it is
     prompt-dependent.
"""
import argparse, hashlib, json, sys, time, urllib.error, urllib.request

# Three classes, because a speculative-free bandwidth number still moves with how much
# the tokenizer packs per token. Named in the output so a range is never quoted bare.
PROMPTS = {
    "code": (
        "Write a TypeScript function that debounces an async function, preserving the "
        "return value of the last call. Include JSDoc and explain the edge cases.\n\n"),
    "prose": (
        "Explain, step by step, how a write-ahead log guarantees durability in a "
        "database, and what happens during crash recovery.\n\n"),
    "list": (
        "List 20 distinct failure modes of a distributed message queue. One line each, "
        "no preamble.\n\n"),
}

# Filler that is prose-like rather than repetitive: a degenerate filler would be
# compressed by the indexer's block summaries and understate the depth cost.
FILLER = (
    "The storage engine appends each mutation to a durable log before acknowledging the "
    "write, so a crash mid-transaction leaves a prefix that recovery can replay. "
    "Checkpoints bound replay time by recording which segments are already applied. "
)


def post(url, body, timeout=1800):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def contract_check(base):
    """The template traps, asserted rather than assumed."""
    out = {}
    msgs = [{"role": "user", "content": "Reply with exactly: OK"}]

    # Server has --reasoning off, so a bare chat request must answer with non-empty
    # content. If this fails the server is up but useless.
    try:
        r = post(base + "/v1/chat/completions",
                 {"model": "qwen3.8-flash-next", "messages": msgs,
                  "max_tokens": 64, "temperature": 0})
        ch = r["choices"][0]["message"]
        content = ch.get("content") or ""
        out["bare_chat"] = {
            "ok": bool(content.strip()),
            "content": content[:80],
            # What matters is that `content` is CLEAN. An absent reasoning_content is not a
            # failure — it just means no thought block was emitted, which is the point of
            # --reasoning off. A <think> tag leaking into content is the real defect, and it
            # silently corrupts every generated file (a KB run once produced frontmatter
            # starting "<think>\n\n</think>\n\n---").
            "think_leaked_into_content": "<think>" in content,
            "reasoning_content_present": ch.get("reasoning_content") is not None,
        }
    except Exception as e:
        out["bare_chat"] = {"ok": False, "error": repr(e)[:200]}

    # 🔴 MEASURED 2026-09-17, and it is the opposite of what the template alone implies.
    # The raw template raises on "none" and "high". But with --reasoning off set on the
    # server, llama.cpp does not hand the effort through to the template, so BOTH values
    # come back HTTP 200 with clean content. That is the desired outcome: the server flag
    # NEUTRALISES the caller-side trap rather than exposing it.
    # So the assertion is "a caller cannot break this", not "the template rejects it".
    # A non-200, or empty content, means the protection has regressed.
    for val in ("none", "high", "low", "medium", "xhigh"):
        try:
            r = post(base + "/v1/chat/completions",
                     {"model": "qwen3.8-flash-next", "messages": msgs,
                      "max_tokens": 32, "temperature": 0, "reasoning_effort": val})
            ch = r["choices"][0]["message"]
            ok = bool((ch.get("content") or "").strip())
            out["effort_" + val] = {
                "harmless": ok,
                "content": (ch.get("content") or "")[:40],
                "note": "" if ok else "200 but EMPTY content — --reasoning off may have stopped working",
            }
        except urllib.error.HTTPError as e:
            out["effort_" + val] = {
                "harmless": False, "http": e.code,
                "note": "rejected — --reasoning off is no longer shielding callers",
            }
        except Exception as e:
            out["effort_" + val] = {"harmless": False, "error": repr(e)[:120]}
    return out


def one(base, prompt, n_predict):
    body = {"prompt": prompt, "n_predict": n_predict, "temperature": 0, "top_k": 1,
            # ⚠️ Without this, a repeated identical request reports prompt_n ~4 and every
            # config looks the same — you measure cache hits, not the model.
            "cache_prompt": False, "stream": False}
    t0 = time.time()
    r = post(base + "/completion", body)
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
        # Degeneracy gate. Repetition is cheap to generate and would read as a win.
        "degenerate": uniq < 0.7,
        "content_sha": hashlib.sha256(content.encode()).hexdigest()[:12],
        "stop": ("eos" if r.get("stopped_eos") else
                 "limit" if r.get("stopped_limit") else "other"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--n-predict", type=int, default=256)
    ap.add_argument("--depths", default="0",
                    help="comma-separated approximate prompt-token depths, e.g. 0,8000,32000")
    ap.add_argument("--contract", action="store_true")
    a = ap.parse_args()

    result = {"base": a.base, "reps": a.reps, "n_predict": a.n_predict}
    if a.contract:
        result["contract"] = contract_check(a.base)

    rows = []
    for depth in [int(d) for d in a.depths.split(",")]:
        # ~4 chars/token is close enough; the measured prompt_n is what gets reported.
        pad = FILLER * max(0, (depth * 4) // len(FILLER)) if depth else ""
        for cls, p in PROMPTS.items():
            for rep in range(a.reps):
                try:
                    m = one(a.base, pad + p, a.n_predict)
                except Exception as e:
                    m = {"error": repr(e)[:200]}
                m.update({"class": cls, "depth_target": depth, "rep": rep})
                rows.append(m)
                print(json.dumps(m), file=sys.stderr)
    result["rows"] = rows

    # Aggregate per (depth, class) — the median of reps, because one rep per cell has
    # already been actively misleading in this homelab.
    agg = {}
    for r in rows:
        if "decode_tps" not in r or r.get("decode_tps") is None:
            continue
        k = "d%d/%s" % (r["depth_target"], r["class"])
        agg.setdefault(k, {"decode": [], "prefill": [], "sha": set(), "degen": False,
                           "prompt_n": r.get("prompt_n")})
        agg[k]["decode"].append(r["decode_tps"])
        if r.get("prefill_tps"):
            agg[k]["prefill"].append(r["prefill_tps"])
        agg[k]["sha"].add(r["content_sha"])
        agg[k]["degen"] |= bool(r.get("degenerate"))

    def med(xs):
        xs = sorted(xs)
        return round(xs[len(xs) // 2], 2) if xs else None

    result["summary"] = {
        k: {"prompt_n": v["prompt_n"],
            "decode_tps_median": med(v["decode"]),
            "decode_tps_min": round(min(v["decode"]), 2),
            "decode_tps_max": round(max(v["decode"]), 2),
            "prefill_tps_median": med(v["prefill"]),
            # >1 sha across reps at temperature 0 means the run is not reproducible;
            # comparing placements on it would be measuring noise.
            "reps_agree": len(v["sha"]) == 1,
            "sha": sorted(v["sha"])[0],
            "any_degenerate": v["degen"]}
        for k, v in sorted(agg.items())
    }
    dec = [s["decode_tps_median"] for s in result["summary"].values()
           if s["decode_tps_median"]]
    result["decode_tps_overall_median"] = med(dec)
    result["any_degenerate"] = any(s["any_degenerate"] for s in result["summary"].values())
    result["all_reps_agree"] = all(s["reps_agree"] for s in result["summary"].values())
    print(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()
