#!/usr/bin/env python3
"""The quality gate's steps inside CT 123 (maya-gate.sh runs them): Maya's next-token
distributions against llama.cpp's, on the same GGUF and the same tokens.

    maya-gate.py tokens    --tokenize BIN --model GGUF --texts DIR --per N --out tokens.json
    maya-gate.py reference --dump BIN --model GGUF --tokens tokens.json --ctx C --k K --out PREFIX
    maya-gate.py score     --config CONFIG --pack PACK --tokens tokens.json --ctx C --topk FILE --out PREFIX
    maya-gate.py verdict   --ref PREFIX.json --score PREFIX.json [--kl 0.10 --same 90 --ppl 3]

- tokens: the first N tokens of each text, concatenated in file-name order (one sequence).
- reference: llama.cpp on the CPU (Maya's tools/llm_logits_dump.cpp) decodes the sequence one
  token at a time; this keeps, for every position after the first C tokens, the top K log-probs
  in the engine's compact form (an int32 K, then per position K int32 ids and K float32
  log-probs) and llama.cpp's own NLL on the same positions.
- score: Maya's engine scores the same tokens (STRATA_GLM_SCORE=C, STRATA_GLM_SCORE_TOPK) through
  its one-token decode path, on the first card of the server's last config, with the env file's
  STRATA_* switches. It runs as llamacpp under systemd-run with the RAM tier's memlock limit.
- verdict: the plan's thresholds: mean KL below 0.10, the same top token at 90% of positions or
  more, perplexity within 3% of llama.cpp's.
"""
import argparse
import json
import math
import os
import pathlib
import re
import subprocess
import sys


def tokens(a):
    files = sorted(p for p in pathlib.Path(a.texts).iterdir() if p.is_file())
    ids, used = [], []
    for f in files:
        out = subprocess.run([a.tokenize, "-m", a.model, "-f", str(f), "--ids", "--log-disable", "--no-bos"],
                             capture_output=True, text=True, check=True).stdout
        line = [l for l in out.splitlines() if l.startswith("[")][-1]
        t = json.loads(line)
        if len(t) < a.per:
            sys.exit("%s has %d tokens, fewer than %d" % (f.name, len(t), a.per))
        ids += t[:a.per]
        used.append({"file": f.name, "tokens": len(t)})
    json.dump({"texts": used, "per_text": a.per, "tokens": ids}, open(a.out, "w"))
    print("tokens: %d from %d texts" % (len(ids), len(used)))


def reference(a):
    import numpy as np
    toks = json.load(open(a.tokens))["tokens"]
    raw = a.out + ".logits"
    env = dict(os.environ, DUMP_THREADS=str(a.threads))
    with open(a.out + ".dump.log", "w") as log:
        subprocess.run([a.dump, a.model, raw] + [str(t) for t in toks], stdout=log, stderr=subprocess.STDOUT,
                       env=env, check=True)
    n = len(toks)
    lg = np.memmap(raw, dtype=np.float32, mode="r")
    vocab = lg.size // n
    lg = lg.reshape(n, vocab)
    nll, top1 = 0.0, 0
    with open(a.out + ".topk", "wb") as f:
        f.write(np.int32(a.k).tobytes())
        for i in range(a.ctx, n - 1):   # row i: the distribution after token i, as the engine scores it
            row = lg[i].astype(np.float64)
            ls = row - (row.max() + np.log(np.exp(row - row.max()).sum()))
            top = np.argsort(-ls)[:a.k]
            f.write(top.astype(np.int32).tobytes())
            f.write(ls[top].astype(np.float32).tobytes())
            nll -= ls[toks[i + 1]]
            top1 += int(top[0] == toks[i + 1])
    m = n - 1 - a.ctx
    out = {"positions": m, "vocab": vocab, "k": a.k, "ctx": a.ctx, "nll": nll / m, "ppl": math.exp(nll / m),
           "top1_pct": 100.0 * top1 / m}
    json.dump(out, open(a.out + ".json", "w"), indent=1)
    os.unlink(raw)
    print("reference: %d positions, ppl %.4f, top1 %.2f%%" % (m, out["ppl"], out["top1_pct"]))


def score(a):
    cfg = json.load(open(a.config))
    toks = json.load(open(a.tokens))["tokens"]
    args = list(cfg["args"])
    args[args.index("--glm-pack") + 1] = a.pack
    gpu = cfg["gpu"][0] if isinstance(cfg["gpu"], list) else cfg["gpu"]
    setenv = {"HIP_VISIBLE_DEVICES": str(gpu), "STRATA_GLM_SPLIT": "0", "STRATA_GLM_SCORE": str(a.ctx),
              "STRATA_GLM_SCORE_TOPK": a.topk, "LD_LIBRARY_PATH": ":".join(cfg.get("lib_dirs") or [])}
    for kv in a.env:
        k, _, v = kv.partition("=")
        setenv[k] = v
    out, err = a.out + ".out", a.out + ".err"
    cmd = ["systemd-run", "--wait", "--collect", "-q", "-p", "User=llamacpp", "-p", "SupplementaryGroups=render",
           "-p", "LimitMEMLOCK=infinity", "-p", "EnvironmentFile=/etc/maya-glm53f.env",
           "-p", "WorkingDirectory=" + cfg["cwd"], "-p", "StandardOutput=file:" + out,
           "-p", "StandardError=file:" + err]
    cmd += ["--setenv=%s=%s" % kv for kv in setenv.items()]
    cmd += [cfg["exe"]] + args + ["--greedy", "--tokens", ",".join(map(str, toks))]
    rc = subprocess.run(cmd).returncode
    text = open(out).read() if os.path.exists(out) else ""
    m = re.search(r"SCORE (\d+) tokens: nll ([\d.]+) ppl ([\d.]+) top1 ([\d.]+)% \| vs ref: KL ([\d.]+) "
                  r"\(max ([\d.]+)\), same top token ([\d.]+)% \| ([\d.]+) ms/token \| cpu lane (\d+) experts, "
                  r"vram hit ([\d.]+)%", text)
    if not m:
        sys.exit("score: no SCORE line (exit %d); see %s and %s" % (rc, out, err))
    keys = ("positions", "nll", "ppl", "top1_pct", "kl", "kl_max", "same_top_pct", "ms_per_token", "cpu_experts",
            "vram_hit_pct")
    res = {k: (int if k in ("positions", "cpu_experts") else float)(v) for k, v in zip(keys, m.groups())}
    res.update(pack=a.pack, env=setenv)
    json.dump(res, open(a.out + ".json", "w"), indent=1)
    print("score: KL %.5f (max %.3f), same top %.2f%%, ppl %.4f, %.1f ms/token" % (
        res["kl"], res["kl_max"], res["same_top_pct"], res["ppl"], res["ms_per_token"]))


def verdict(a):
    ref, sc = json.load(open(a.ref)), json.load(open(a.score))
    ppl_diff = 100.0 * (sc["ppl"] / ref["ppl"] - 1.0)
    checks = {"kl": sc["kl"] < a.kl, "same_top": sc["same_top_pct"] >= a.same,
              "ppl": abs(ppl_diff) <= a.ppl, "positions": sc["positions"] == ref["positions"]}
    out = {"kl": sc["kl"], "kl_max": sc["kl_max"], "same_top_pct": sc["same_top_pct"], "ppl_maya": sc["ppl"],
           "ppl_llamacpp": ref["ppl"], "ppl_diff_pct": round(ppl_diff, 2), "positions": sc["positions"],
           "checks": checks, "pass": all(checks.values())}
    print(json.dumps(out, indent=1))
    sys.exit(0 if out["pass"] else 3)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("tokens")
    for k in ("tokenize", "model", "texts", "out"):
        p.add_argument("--" + k, required=True)
    p.add_argument("--per", type=int, default=512)
    p = sub.add_parser("reference")
    for k in ("dump", "model", "tokens", "out"):
        p.add_argument("--" + k, required=True)
    p.add_argument("--ctx", type=int, default=64)
    p.add_argument("--k", type=int, default=64)
    p.add_argument("--threads", type=int, default=32)
    p = sub.add_parser("score")
    for k in ("config", "pack", "tokens", "topk", "out"):
        p.add_argument("--" + k, required=True)
    p.add_argument("--ctx", type=int, default=64)
    p.add_argument("--env", action="append", default=[], help="KEY=VALUE for the engine, repeatable")
    p = sub.add_parser("verdict")
    p.add_argument("--ref", required=True)
    p.add_argument("--score", required=True)
    p.add_argument("--kl", type=float, default=0.10)
    p.add_argument("--same", type=float, default=90.0)
    p.add_argument("--ppl", type=float, default=3.0)
    a = ap.parse_args()
    {"tokens": tokens, "reference": reference, "score": score, "verdict": verdict}[a.cmd](a)


if __name__ == "__main__":
    main()
