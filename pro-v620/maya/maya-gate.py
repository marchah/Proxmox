#!/usr/bin/env python3
"""The quality gate's steps inside CT 123 (maya-gate.sh runs them): Maya's next-token
distributions against llama.cpp's, on the same GGUF and the same tokens.

    maya-gate.py tokens    --tokenize BIN --model GGUF --texts DIR --per N --out tokens.json
    maya-gate.py reference --dump BIN --model GGUF --tokens tokens.json --ctx C --k K --out PREFIX
    maya-gate.py check-ref --ref PREFIX --tokens tokens.json --ctx C --k K [--model GGUF --dump BIN]
    maya-gate.py score     --config CONFIG --pack PACK --tokens tokens.json --ctx C --topk FILE --out PREFIX
    maya-gate.py verdict   --ref PREFIX.json --score PREFIX.json [--kl 0.10 --same 90 --ppl 3]

- tokens: the first N tokens of each text, concatenated in file-name order (one sequence).
- reference: llama.cpp on the CPU (Maya's tools/llm_logits_dump.cpp) decodes the sequence one
  token at a time; this keeps, for every position after the first C tokens, the top K log-probs
  in the engine's compact form (an int32 K, then per position K int32 ids and K float32
  log-probs) and llama.cpp's own NLL on the same positions. PREFIX.manifest.json, written last,
  records what the reference was computed from: the model's shards (real path, size, mtime), the
  dumper and its llama.cpp libraries (SHA-256), the tokens (SHA-256), C, K and the top-K file's size.
- check-ref: exits 0 only if PREFIX's manifest matches these inputs, so a reference is reused only
  for the same model, build, tokens and settings (--model and --dump left out: the tokens and
  settings only, for a reference made from another model).
- score: Maya's engine scores the same tokens (STRATA_GLM_SCORE=C, STRATA_GLM_SCORE_TOPK) through
  its one-token decode path, on the first card of the server's last config, with the env file's
  STRATA_* switches. It runs as llamacpp under systemd-run with the RAM tier's memlock limit. The
  previous outputs are removed first; the score counts only if the engine exits 0 and scored every
  position.
- verdict: the plan's thresholds: mean KL below 0.10, the same top token at 90% of positions or
  more, perplexity within 3% of llama.cpp's.
"""
import argparse
import glob
import hashlib
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


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def write_json(path, obj):   # complete or absent: a reader never sees a partial file
    with open(path + ".tmp", "w") as f:
        json.dump(obj, f, indent=1)
    os.replace(path + ".tmp", path)


def ref_inputs(a, with_build):
    """What a reference is computed from. Shards by real path, size and mtime (hashing 150 GB per run
    is not practical); the dumper and the llama.cpp libraries it loads by SHA-256."""
    out = {"tokens_sha256": sha256(a.tokens), "ctx": a.ctx, "k": a.k}
    if with_build:
        first = os.path.realpath(a.model)
        m = re.match(r"(.*-)\d{5}(-of-\d{5}\.gguf)$", first)
        shards = sorted(glob.glob(glob.escape(m.group(1)) + "[0-9]" * 5 + glob.escape(m.group(2)))) if m else [first]
        out["model"] = [{"path": p, "size": os.stat(p).st_size, "mtime_ns": os.stat(p).st_mtime_ns} for p in shards]
        try:
            ldd = subprocess.run(["ldd", a.dump], capture_output=True, text=True).stdout
        except OSError:
            ldd = ""
        libs = sorted(set(re.findall(r"=> (\S*/lib(?:llama|ggml)[^/\s]*)", ldd)))
        out["build"] = {os.path.realpath(p): sha256(p) for p in [a.dump] + libs}
    return out


def topk_bytes(n_tokens, ctx, k):
    return 4 + (n_tokens - 1 - ctx) * k * 8


def reference(a):
    import numpy as np
    toks = json.load(open(a.tokens))["tokens"]
    for p in (a.out + ".manifest.json", a.out + ".json", a.out + ".topk"):
        if os.path.exists(p):
            os.unlink(p)
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
    write_json(a.out + ".json", out)
    os.unlink(raw)
    manifest = ref_inputs(a, with_build=True)
    manifest["topk_bytes"] = os.path.getsize(a.out + ".topk")
    write_json(a.out + ".manifest.json", manifest)
    print("reference: %d positions, ppl %.4f, top1 %.2f%%" % (m, out["ppl"], out["top1_pct"]))


def check_ref(a):
    path = a.ref + ".manifest.json"
    if not os.path.exists(path):
        sys.exit("check-ref: no %s" % path)
    have = json.load(open(path))
    want = ref_inputs(a, with_build=a.model is not None)
    diff = [k for k in want if have.get(k) != want[k]]
    n = len(json.load(open(a.tokens))["tokens"])
    size = os.path.getsize(a.ref + ".topk") if os.path.exists(a.ref + ".topk") else -1
    if size != have.get("topk_bytes") or size != topk_bytes(n, a.ctx, a.k) or not os.path.exists(a.ref + ".json"):
        diff.append("top-K file")
    if diff:
        sys.exit("check-ref: %s differs from these inputs: %s" % (a.ref, ", ".join(diff)))
    print("check-ref: %s matches" % a.ref)


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
    out, err, res_path = a.out + ".out", a.out + ".err", a.out + ".json"
    # A previous run's files would otherwise be read as this run's: systemd's file: does not
    # truncate, and a launch that fails never opens them.
    for p in (out, err, res_path):
        if os.path.exists(p):
            os.unlink(p)
    cmd = ["systemd-run", "--wait", "--collect", "-q", "-p", "User=llamacpp", "-p", "SupplementaryGroups=render",
           "-p", "LimitMEMLOCK=infinity", "-p", "EnvironmentFile=/etc/maya-glm53f.env",
           "-p", "WorkingDirectory=" + cfg["cwd"], "-p", "StandardOutput=truncate:" + out,
           "-p", "StandardError=truncate:" + err]
    cmd += ["--setenv=%s=%s" % kv for kv in setenv.items()]
    cmd += [cfg["exe"]] + args + ["--greedy", "--tokens", ",".join(map(str, toks))]
    rc = subprocess.run(cmd).returncode
    if rc != 0:
        sys.exit("score: the engine exited %d; see %s and %s" % (rc, out, err))
    text = open(out).read() if os.path.exists(out) else ""
    m = re.search(r"SCORE (\d+) tokens: nll ([\d.]+) ppl ([\d.]+) top1 ([\d.]+)% \| vs ref: KL ([\d.]+) "
                  r"\(max ([\d.]+)\), same top token ([\d.]+)% \| ([\d.]+) ms/token \| cpu lane (\d+) experts, "
                  r"vram hit ([\d.]+)%", text)
    if not m:
        sys.exit("score: no SCORE line (exit %d); see %s and %s" % (rc, out, err))
    keys = ("positions", "nll", "ppl", "top1_pct", "kl", "kl_max", "same_top_pct", "ms_per_token", "cpu_experts",
            "vram_hit_pct")
    res = {k: (int if k in ("positions", "cpu_experts") else float)(v) for k, v in zip(keys, m.groups())}
    if res["positions"] != len(toks) - 1 - a.ctx:
        sys.exit("score: %d positions scored, %d expected" % (res["positions"], len(toks) - 1 - a.ctx))
    res.update(pack=a.pack, env=setenv)
    write_json(res_path, res)
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
    p = sub.add_parser("check-ref")
    for k in ("ref", "tokens"):
        p.add_argument("--" + k, required=True)
    p.add_argument("--model")
    p.add_argument("--dump")
    p.add_argument("--ctx", type=int, default=64)
    p.add_argument("--k", type=int, default=64)
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
    if a.cmd == "check-ref" and (a.model is None) != (a.dump is None):
        ap.error("check-ref takes --model and --dump together")
    {"tokens": tokens, "reference": reference, "check-ref": check_ref, "score": score, "verdict": verdict}[a.cmd](a)


if __name__ == "__main__":
    main()
