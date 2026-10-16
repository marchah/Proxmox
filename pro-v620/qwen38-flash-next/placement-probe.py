#!/usr/bin/env python3
"""Measure Qwen3.8-Flash-Next decode/prefill at a fixed placement, by prompt class and depth.

Run from the Proxmox host against CT 120's llama-server.

Why /completion and not /v1/chat/completions for the throughput rows by default: no chat
template sits between configs, and llama.cpp returns the full `timings` block. The chat
path is exercised by --contract after every cell load in placement-sweep.sh. Raw completion
rows can generate reasoning even when the chat server has --reasoning off; validate
the chosen configuration on chat workloads before treating it as a serving optimum.
--chat (PROBE_CHAT=true in placement-sweep.sh) sends the throughput rows through
/v1/chat/completions instead, which also returns `timings`; the GLM-5.3-Flash records
use it from stage 3 on, because GLM continued the raw d8000 filler instead of answering.

⚠️ Three things this model breaks that others here do not:

  1. Its template resolves `reasoning_effort|default('xhigh')` and RAISES on "none" and
     "high". Qwen3.8-27B is the exact opposite — there "none" is the off switch. So the
     server runs --reasoning off and no caller should send reasoning_effort at all.
     --contract asserts that end of it.
  2. Decode cost grows with CONTEXT DEPTH, not just with placement: the QSA indexer
     rescored every block summary over the whole cached context every token until
     llama.cpp #28699 (still an open draft). A single short-prompt number is therefore
     not a throughput figure for this model. Hence --depths.
  3. With the MTP head (CT 123's deployed env), decode depends on how many drafted tokens
     the prompt gets accepted, so each row records draft_n and draft_n_accepted. Without
     it, draft_n is absent and tok/s is a plain bandwidth number.
"""
import argparse, hashlib, json, math, pathlib, statistics, sys, time, urllib.error, urllib.request

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


# Long enough for a ~120k-token prefill on the hybrid CPU+GPU placements.
def post(url, body, timeout=3600):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def context_prefixes(base, text, depths):
    """{depth: the first `depth` tokens of text}, cut with the server's own tokenizer.

    One /tokenize call covers the deepest depth; each depth is /detokenize of a prefix of
    those tokens, so a shallower context is a prefix of a deeper one.
    """
    want = [d for d in depths if d]
    if not want:
        return {}
    # ~6 chars per token is more than any tokenizer here packs, so the slice holds enough.
    tokens = post(base + "/tokenize", {"content": text[:max(want) * 6]})["tokens"]
    if len(tokens) < max(want):
        raise SystemExit("the context file holds %d tokens; --depths needs %d" % (len(tokens), max(want)))
    return {d: post(base + "/detokenize", {"tokens": tokens[:d]})["content"] for d in want}


def contract_check(base, efforts):
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
        reasoning = ch.get("reasoning_content") or ""
        out["bare_chat"] = {
            "ok": bool(content.strip()),
            "content": content[:80],
            # What matters is that `content` is CLEAN. An absent reasoning_content is not a
            # failure — it just means no thought block was emitted, which is the point of
            # --reasoning off. A <think> tag leaking into content is the real defect, and it
            # silently corrupts every generated file (a KB run once produced frontmatter
            # starting "<think>\n\n</think>\n\n---").
            "think_leaked_into_content": "<think>" in content or "</think>" in content,
            "reasoning_content_present": ch.get("reasoning_content") is not None,
            # A reasoning block despite --reasoning off: GLM-5.3-Flash's template opens
            # <think> on every turn and has no switch of its own to close it.
            "reasoning_chars": len(reasoning),
            "finish_reason": r["choices"][0].get("finish_reason"),
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
    for val in efforts:
        try:
            r = post(base + "/v1/chat/completions",
                     {"model": "qwen3.8-flash-next", "messages": msgs,
                      "max_tokens": 32, "temperature": 0, "reasoning_effort": val})
            ch = r["choices"][0]["message"]
            content = ch.get("content") or ""
            ok = bool(content.strip())
            # On the whole reply: GLM-5.3-Flash's tag follows the reasoning, past the stored prefix.
            leaked = "<think>" in content or "</think>" in content
            out["effort_" + val] = {
                "harmless": ok and not leaked,
                "content": content[:40],
                "think_leaked_into_content": leaked,
                "reasoning_chars": len(ch.get("reasoning_content") or ""),
                "note": ("200 but EMPTY content — --reasoning off may have stopped working" if not ok
                         else "think tag in content — the reasoning block reached the answer"
                         if leaked else ""),
            }
        except urllib.error.HTTPError as e:
            out["effort_" + val] = {
                "harmless": False, "http": e.code,
                "note": "rejected — --reasoning off is no longer shielding callers",
            }
        except Exception as e:
            out["effort_" + val] = {"harmless": False, "error": repr(e)[:120]}
    return out


def one(base, prompt, n_predict, chat=False, cache=False, sampling="greedy", seed=None):
    # ⚠️ cache_prompt false by default: without it, a repeated identical request reports
    # prompt_n ~4 and every config looks the same — you measure cache hits, not the model.
    # --cache turns it on deliberately, to reuse a deep shared context; rows then carry
    # cache_n and only cold rows count towards prefill.
    if chat:
        # The same text as one user turn through the chat template. GLM-5.3-Flash reads the
        # raw depth prompt (filler, then the instruction) as a document and continues the
        # filler; as a question it answers. llama-server returns the same timings block.
        body = {"messages": [{"role": "user", "content": prompt}], "max_tokens": n_predict,
                "cache_prompt": cache, "stream": False}
        path = "/v1/chat/completions"
    else:
        body = {"prompt": prompt, "n_predict": n_predict, "cache_prompt": cache, "stream": False}
        path = "/completion"
    # greedy pins the target's choices; server sends no sampler settings, so the server's
    # defaults (the GGUF's generation_config, where present) apply, as for a client that
    # sets none. A fixed seed keeps server sampling repeatable.
    if sampling == "greedy":
        body.update(temperature=0, top_k=1)
    if seed is not None:
        body["seed"] = seed
    t0 = time.time()
    r = post(base + path, body)
    wall = time.time() - t0
    tm = r.get("timings", {})
    if chat:
        choice = r["choices"][0]
        msg = choice.get("message") or {}
        content = msg.get("content") or ""
        reasoning_chars = len(msg.get("reasoning_content") or "")
        stop = {"length": "limit", "stop": "eos"}.get(choice.get("finish_reason"),
                                                      choice.get("finish_reason") or "other")
    else:
        content = r.get("content") or ""
        reasoning_chars = None
        # b11505 reports `stop_type`; older builds set stopped_eos / stopped_limit.
        stop = r.get("stop_type") or ("eos" if r.get("stopped_eos") else
                                      "limit" if r.get("stopped_limit") else "other")
    words = content.split()
    shingles = {" ".join(words[j:j + 8]) for j in range(max(0, len(words) - 7))}
    uniq = round(len(shingles) / max(1, len(words) - 7), 3)
    # Report acceptance alongside speed: the same acceptance can still have a different
    # cost when placement, scheduling or the verification batch changes.
    dn, da = tm.get("draft_n"), tm.get("draft_n_accepted")
    accept = round(100.0 * da / dn, 1) if (dn and da is not None) else None
    row = {
        "wall_s": round(wall, 2),
        # When the request started and how its time split, so the sweep can place its
        # telemetry samples in the prefill or the decode phase.
        "t0": round(t0, 3),
        "prompt_ms": tm.get("prompt_ms"),
        "predicted_ms": tm.get("predicted_ms"),
        "prompt_n": tm.get("prompt_n"),
        # Tokens the prompt cache served; 0 or absent with cache_prompt off.
        "cache_n": tm.get("cache_n"),
        "prefill_tps": tm.get("prompt_per_second"),
        "predicted_n": tm.get("predicted_n"),
        "decode_tps": tm.get("predicted_per_second"),
        "draft_n": dn,
        "draft_n_accepted": da,
        "accept_pct": accept,
        "uniq_8gram": uniq,
        # Degeneracy gate. Repetition is cheap to generate and would read as a win.
        "degenerate": uniq < 0.7,
        "content_sha": hashlib.sha256(content.encode()).hexdigest()[:12],
        # The text itself, so a response that differs from its control can be read.
        "content": content,
        "stop": stop,
        # Chat requests only: tokens spent in a reasoning block count toward predicted_n.
        "reasoning_chars": reasoning_chars,
    }
    if not content.strip():
        row["error"] = "empty completion"
    elif not isinstance(row["decode_tps"], (int, float)) or not math.isfinite(row["decode_tps"]) or row["decode_tps"] <= 0:
        row["error"] = "missing or invalid decode timing"
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--n-predict", default="256",
                    help="tokens to generate, or a comma-separated list run per prompt")
    ap.add_argument("--depths", default="0",
                    help="comma-separated approximate prompt-token depths, e.g. 0,8000,32000")
    ap.add_argument("--context-file", default="",
                    help="text for the depth context instead of the built-in filler: each "
                         "depth is that many tokens of it, cut with the server's tokenizer, so a "
                         "shallower context is a prefix of a deeper one")
    ap.add_argument("--cache", action="store_true",
                    help="cache_prompt on; depths run deepest first so shallower prompts reuse "
                         "the deeper context, and only rows with an uncached prompt count as prefill")
    ap.add_argument("--sampling", choices=("greedy", "server"), default="greedy",
                    help="greedy (temperature 0, top-k 1) or server: send no sampler settings")
    ap.add_argument("--seed", type=int, default=None, help="request seed, for server sampling")
    ap.add_argument("--contract", action="store_true")
    ap.add_argument("--chat", action="store_true",
                    help="send the throughput prompts through /v1/chat/completions")
    # Flash-Next's template takes low, medium and xhigh and raises on none and high;
    # GLM-5.3-Flash's takes low, high and max and reads anything else as max.
    ap.add_argument("--efforts", default="none,high,low,medium,xhigh",
                    help="comma-separated reasoning_effort values --contract sends")
    # Limit which prompt classes run. The WARM pass does not need all three -- warming is
    # about weights, the graph and the deep-prefill indexer state, none of which is
    # prompt-class specific -- and at depth each class costs a full 8k prefill, which is
    # more than half a cell's wall-clock. The MEASURE pass must keep all three: decode
    # speed is prompt-dependent, so a single class is not this model's throughput.
    ap.add_argument("--classes", default="",
                    help="comma-separated subset of %s (default: all)" % ",".join(PROMPTS))
    a = ap.parse_args()
    try:
        n_predicts = [int(n) for n in str(a.n_predict).split(",") if n.strip()]
    except ValueError:
        ap.error("--n-predict takes integers")
    if a.reps < 1 or not n_predicts or min(n_predicts) < 1:
        ap.error("--reps and --n-predict must be positive")
    context = pathlib.Path(a.context_file).read_text(errors="replace") if a.context_file else ""

    result = {"base": a.base, "reps": a.reps,
              "n_predict": n_predicts[0] if len(n_predicts) == 1 else n_predicts,
              "classes": a.classes or "all", "chat": a.chat, "cache": a.cache,
              "sampling": a.sampling, "seed": a.seed}
    if a.context_file:
        result["context_file"] = {"path": a.context_file, "chars": len(context),
                                  "sha256": hashlib.sha256(context.encode()).hexdigest()}
    if a.contract:
        result["contract"] = contract_check(
            a.base, [e.strip() for e in a.efforts.split(",") if e.strip()])

    rows = []
    depths = [int(d) for d in a.depths.split(",")]
    if a.cache:
        # Deepest first: its context is prefilled cold, and every shallower context is a
        # prefix of it, so later requests reuse the cache instead of prefilling again.
        depths = sorted(depths, reverse=True)
    prefixes = context_prefixes(a.base, context, depths) if context else {}
    want = [c.strip() for c in a.classes.split(",") if c.strip()] or list(PROMPTS)
    unknown = [c for c in want if c not in PROMPTS]
    if unknown:
        raise SystemExit("unknown prompt class(es) %s; have %s"
                         % (",".join(unknown), ",".join(PROMPTS)))
    for depth in depths:
        if not depth:
            pad = ""
        elif context:
            pad = "<documents>\n%s\n</documents>\n\n" % prefixes[depth]
        else:
            # ~4 chars/token is close enough; the measured prompt_n is what gets reported.
            pad = FILLER * max(0, (depth * 4) // len(FILLER))
        for cls, p in ((c, PROMPTS[c]) for c in want):
            for n_predict in n_predicts:
                for rep in range(a.reps):
                    try:
                        m = one(a.base, pad + p, n_predict, a.chat, a.cache, a.sampling, a.seed)
                    except Exception as e:
                        m = {"error": repr(e)[:200]}
                    m.update({"class": cls, "depth_target": depth, "rep": rep,
                              "n_predict": n_predict})
                    rows.append(m)
                    print(json.dumps(m), file=sys.stderr)
    result["rows"] = rows

    # Aggregate per (depth, class) — the median of reps, because one rep per cell has
    # already been actively misleading in this homelab.
    agg = {}
    for r in rows:
        if r.get("error") or r.get("decode_tps") is None:
            continue
        k = "d%d/%s" % (r["depth_target"], r["class"])
        if len(n_predicts) > 1:
            k += "/n%d" % r["n_predict"]
        total = (r.get("prompt_n") or 0) + (r.get("cache_n") or 0)
        agg.setdefault(k, {"decode": [], "prefill": [], "accept": [], "sha": set(),
                           "degen": False, "prompt_n": total or r.get("prompt_n")})
        agg[k]["decode"].append(r["decode_tps"])
        # A row whose prompt the cache mostly served measures the cache, not prefill.
        cold = not r.get("cache_n") or (r.get("prompt_n") or 0) >= 0.9 * total
        if r.get("prefill_tps") and cold:
            agg[k]["prefill"].append(r["prefill_tps"])
        if r.get("accept_pct") is not None:
            agg[k]["accept"].append(r["accept_pct"])
        agg[k]["sha"].add(r["content_sha"])
        agg[k]["degen"] |= bool(r.get("degenerate"))

    def med(xs):
        return round(statistics.median(xs), 2) if xs else None

    result["summary"] = {
        k: {"prompt_n": v["prompt_n"],
            "decode_tps_median": med(v["decode"]),
            "decode_tps_min": round(min(v["decode"]), 2),
            "decode_tps_max": round(max(v["decode"]), 2),
            "prefill_tps_median": med(v["prefill"]),
            # Per-class, because acceptance is PROMPT-DEPENDENT — code drafts far better
            # than prose, and that spread can exceed the effect being measured.
            "accept_pct_median": med(v["accept"]),
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
    result["failed_requests"] = sum(bool(r.get("error")) for r in rows)
    result["all_reps_agree"] = bool(agg) and not result["failed_requests"] and all(
        s["reps_agree"] for s in result["summary"].values())
    result["contract_ok"] = all(
        v.get("ok", v.get("harmless", False)) and not v.get("think_leaked_into_content")
        and not v.get("reasoning_chars") for v in result["contract"].values()
    ) if a.contract else None
    # Under server sampling, reps that differ are reported, not failed: a seeded sampler
    # repeats on one load, but that is what the field shows rather than what it assumes.
    agree_ok = result["all_reps_agree"] or (
        a.sampling == "server" and bool(agg) and not result["failed_requests"])
    result["probe_ok"] = (agree_ok and not result["any_degenerate"]
                          and result["contract_ok"] is not False)
    print(json.dumps(result, indent=1))
    return 0 if result["probe_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
