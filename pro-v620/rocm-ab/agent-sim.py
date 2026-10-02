#!/usr/bin/env python3
"""A scripted coding-agent session against a running llama-server. Runs INSIDE the test VM.

The session grows one conversation turn by turn until the prompt reaches --target tokens,
the way a coding agent's context does:

  read   a tool result: the next --chunk-chars of repository text, then a short answer
         (what this part does, what to inspect next)
  write  every --write-every turns: a request to write code, a longer answer

The model's own replies are NOT appended to the history. A fixed reply of the same kind is,
so every backend and repetition prefills the identical context. The prompt cache stays on
(`cache_prompt: true`) as it would for an agent, so each turn prefills only what is new:
the canned reply plus the next user message, at the session's current depth.

Greedy decoding (temperature 0). One JSONL row per turn: depth before and after, new prompt
tokens and their rate, generated tokens and their rate, draft statistics, a hash of the text.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import time
import urllib.request

URL = "http://127.0.0.1:1234"
SYSTEM = ("You are a coding agent working in a homelab infrastructure repository (Proxmox, "
          "LXC containers, llama.cpp model servers, bash and Python tooling). You read files "
          "through tools and make precise, minimal changes.")
READ_Q = ("Tool result: contents of the next part of the repository.\n\n```\n{chunk}\n```\n\n"
          "In at most three sentences: what does this part do, and what would you inspect next?")
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
READ_REPLY = "This part sets up the components shown above. Next I will open the following file."


def post(body: dict, timeout: int = 3600) -> tuple[dict, float]:
    req = urllib.request.Request(URL + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        out = json.load(r)
    return out, time.monotonic() - t0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True)
    ap.add_argument("--rep", type=int, required=True)
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--target", type=int, default=126000, help="stop once the prompt reaches this many tokens")
    ap.add_argument("--chunk-chars", type=int, default=16000, help="~4k tokens of repository text per read")
    ap.add_argument("--write-every", type=int, default=3)
    ap.add_argument("--read-tokens", type=int, default=160)
    ap.add_argument("--write-tokens", type=int, default=512)
    a = ap.parse_args()

    corpus = open(a.corpus, encoding="utf-8").read()
    # Each write's canned reply is a fixed slice of real repository code, the same length every time.
    write_reply = "```bash\n" + corpus[:1600] + "\n```"
    msgs = [{"role": "system", "content": SYSTEM}]
    pos, turn, writes, prompt_tokens = 0, 0, 0, 0
    out = open(a.out, "a", encoding="utf-8")

    # Warm-up: first request after load pays shader/pipeline compilation. Not recorded.
    post({"messages": [{"role": "user", "content": "Say hello."}], "max_tokens": 8,
          "temperature": 0, "cache_prompt": False})

    while prompt_tokens < a.target:
        turn += 1
        kind = "write" if turn % a.write_every == 0 else "read"
        if kind == "read":
            chunk = corpus[pos:pos + a.chunk_chars]
            pos = (pos + a.chunk_chars) % max(1, len(corpus) - a.chunk_chars)
            msgs.append({"role": "user", "content": READ_Q.format(chunk=chunk)})
            max_tokens = a.read_tokens
        else:
            msgs.append({"role": "user", "content": WRITE_QS[writes % len(WRITE_QS)]})
            writes += 1
            max_tokens = a.write_tokens
        body = {"messages": msgs, "max_tokens": max_tokens, "temperature": 0, "top_k": 1,
                "cache_prompt": True, "stream": False}
        resp, wall = post(body)
        t = resp.get("timings", {})
        usage = resp.get("usage", {})
        content = resp["choices"][0]["message"].get("content") or ""
        prompt_tokens = usage.get("prompt_tokens") or prompt_tokens
        new = t.get("prompt_n") or 0
        row = {
            "arm": a.arm, "rep": a.rep, "turn": turn, "kind": kind, "ts": time.time(),
            "depth_before": prompt_tokens - new, "depth_after": prompt_tokens,
            "prompt_n": new, "prompt_ms": t.get("prompt_ms"), "prompt_tps": t.get("prompt_per_second"),
            "predicted_n": t.get("predicted_n"), "predicted_ms": t.get("predicted_ms"),
            "decode_tps": t.get("predicted_per_second"),
            "draft_n": t.get("draft_n"), "draft_accepted": t.get("draft_n_accepted"),
            "finish": resp["choices"][0].get("finish_reason"), "wall_s": round(wall, 3),
            "content_sha": hashlib.sha256(content.encode()).hexdigest()[:16],
        }
        out.write(json.dumps(row) + "\n"); out.flush()
        print(f"  t{turn:02d} {kind:5s} depth {row['depth_before']:6d}->{row['depth_after']:6d} "
              f"prefill {new:5d} @ {row['prompt_tps'] or 0:7.1f} t/s  decode {row['predicted_n']} @ "
              f"{row['decode_tps'] or 0:6.1f} t/s  draft {row['draft_accepted']}/{row['draft_n']}", flush=True)
        msgs.append({"role": "assistant", "content": READ_REPLY if kind == "read" else write_reply})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
