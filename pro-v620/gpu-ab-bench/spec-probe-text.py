#!/usr/bin/env python3
"""Same prompts as spec-probe.py, but SAVES the generated text so a suspicious
"speedup" can be checked for degenerate/repetitive output."""
import json, sys, time, urllib.request
sys.path.insert(0, "/root")
from importlib.machinery import SourceFileLoader
P = SourceFileLoader("p", "/root/spec-probe.py").load_module()


def main():
    base, out_path = sys.argv[1], sys.argv[2]
    n_predict = int(sys.argv[3]) if len(sys.argv) > 3 else 512
    recs = []
    for i, p in enumerate(P.PROMPTS):
        r = P.post(base + "/completion", {"prompt": p, "n_predict": n_predict,
                                          "temperature": 0, "top_k": 1,
                                          "cache_prompt": False, "stream": False})
        tm = r.get("timings", {})
        recs.append({"prompt": i, "tps": tm.get("predicted_per_second"),
                     "n": tm.get("predicted_n"), "text": r.get("content")})
    with open(out_path, "w") as fh:
        json.dump(recs, fh, indent=1)
    for rec in recs:
        t = rec["text"] or ""
        # crude degeneracy signal: how much of the output is unique 8-word shingles
        w = t.split()
        sh = {" ".join(w[j:j+8]) for j in range(max(0, len(w)-7))}
        uniq = (len(sh) / max(1, len(w)-7))
        print("  prompt %d: %6.2f t/s  n=%s  words=%d  unique-8gram-ratio=%.2f%s"
              % (rec["prompt"], rec["tps"] or 0, rec["n"], len(w), uniq,
                 "   <-- DEGENERATE/REPETITIVE" if uniq < 0.7 else ""))


if __name__ == "__main__":
    main()
