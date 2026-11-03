#!/usr/bin/env python3
"""Known-item retrieval test for kb-rag: does a question written from one chunk find that chunk?

    known_item_eval.py build     --corpus DIR --out DIR [--threads N]
    known_item_eval.py sample    --out DIR [--seed N] [--per-stratum N]
    known_item_eval.py questions --out DIR --llm URL [--model NAME]
    known_item_eval.py run       --out DIR [--threads N]

build      indexes a CognitiveStack export twice with kb-rag's own reindex (full rebuild, no
           git), into OUT/bge.sqlite and OUT/granite.sqlite, and writes OUT/build.json.
sample     picks chunks from the bge index with a fixed seed into OUT/sample.json: `uniform`
           over chunks of at least 40 estimated tokens, and `long` over chunks of more than
           512, whose question is written from the text after the first 2,048 characters of
           the chunk body (about token 512 at the chunker's 4 characters a token): the part
           bge-small-en-v1.5 does not embed.
questions  asks an OpenAI-compatible chat endpoint for one search question per chunk, at
           temperature 0, into OUT/questions.json (resumable).
run        searches every question in each configuration through kb-rag's Embedder and
           Store, as the API's do_search does, and writes OUT/results.json and
           OUT/summary.md. Rerankers rescore the hybrid top 30 and keep 8; kb-rag has no
           reranker, so those rows exist only here.

Run with kb-rag's packages (fastembed, sqlite-vec, pathspec, PyYAML). Set FASTEMBED_CACHE_PATH
to keep the model downloads out of the default cache. The generated files stay out of git.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import sqlite3
import statistics
import sys
import time
import urllib.request

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app")
CONFIG = os.path.join(APP, "index.config.yaml")
sys.path.insert(0, APP)

from config import load_config  # noqa: E402

DEPLOYED = load_config(CONFIG)
ARMS = {
    "bge": {"model": "BAAI/bge-small-en-v1.5", "dim": 384, "query_prefix": DEPLOYED["query_prefix"]},
    "granite": {"model": "ibm-granite/granite-embedding-small-english-r2", "dim": 384, "query_prefix": ""},
}
RERANKERS = {"minilm": "Xenova/ms-marco-MiniLM-L-6-v2", "jina-turbo": "jinaai/jina-reranker-v1-turbo-en"}
LONG_OFFSET = 2048
PASSAGE_CHARS = 8000
TOP_K = 8
RERANK_POOL = 30
PROMPT = """Here is a passage from a technical knowledge base about AI tools, models and infrastructure.

<passage>
{passage}
</passage>

Write one question that someone could type into a search box and that this passage answers.
- Ask about a specific fact stated in the passage.
- Paraphrase: do not copy any phrase of four or more consecutive words from the passage.
- Do not mention "the passage", "the text" or "the document".
- Use at most 25 words.
Reply with the question only."""


def _path(out, name):
    return os.path.join(out, name)


def _load(out, name):
    with open(_path(out, name), encoding="utf-8") as f:
        return json.load(f)


def _save(out, name, data):
    tmp = _path(out, name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, ensure_ascii=False)
    os.replace(tmp, _path(out, name))


def cmd_build(a):
    import reindex

    os.makedirs(a.out, exist_ok=True)
    report = {}
    for arm, spec in ARMS.items():
        db = _path(a.out, f"{arm}.sqlite")
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(db + suffix):
                os.remove(db + suffix)
        os.environ.update({
            "KB_REPO_DIR": os.path.abspath(a.corpus), "KB_DB_PATH": db, "KB_EMBED_MODEL": spec["model"],
            "KB_EMBED_DIM": str(spec["dim"]), "KB_EMBED_THREADS": str(a.threads),
        })
        start = time.time()
        summary = reindex.run(full=True, no_git=True, config_path=CONFIG)
        report[arm] = {**spec, **summary, "seconds": round(time.time() - start, 1)}
        print(f"{arm}: {report[arm]['seconds']} s")
    _save(a.out, "build.json", report)


def cmd_sample(a):
    con = sqlite3.connect(_path(a.out, "bge.sqlite"))
    con.row_factory = sqlite3.Row
    rows = con.execute(
        "SELECT chunk_uid, path, title, section, content, token_count FROM chunks ORDER BY chunk_uid"
    ).fetchall()
    rng = random.Random(a.seed)
    long_pick = rng.sample([r for r in rows if r["token_count"] > 512], a.per_stratum)
    taken = {r["chunk_uid"] for r in long_pick}
    uniform_pick = rng.sample([r for r in rows if r["token_count"] >= 40 and r["chunk_uid"] not in taken],
                              a.per_stratum)
    items = []
    for stratum, picks in (("uniform", uniform_pick), ("long", long_pick)):
        for r in picks:
            passage = r["content"][LONG_OFFSET:] if stratum == "long" else r["content"]
            items.append({"stratum": stratum, "chunk_uid": r["chunk_uid"], "path": r["path"],
                          "token_count": r["token_count"], "passage": passage[:PASSAGE_CHARS]})
    _save(a.out, "sample.json", {"seed": a.seed, "chunks_in_index": len(rows), "items": items})
    print(f"{len(items)} chunks sampled from {len(rows)}")


def _words(text):
    return re.findall(r"[a-z0-9]+", text.lower())


def _longest_copy(question, passage):
    """Longest run of consecutive question words that also appears in the passage."""
    q, p = _words(question), " " + " ".join(_words(passage)) + " "
    best = 0
    for i in range(len(q)):
        for j in range(i + best + 1, len(q) + 1):
            if " " + " ".join(q[i:j]) + " " in p:
                best = j - i
            else:
                break
    return best


def cmd_questions(a):
    qpath = _path(a.out, "questions.json")
    data = _load(a.out, "questions.json") if os.path.exists(qpath) else _load(a.out, "sample.json")
    for n, it in enumerate(data["items"], 1):
        if it.get("question"):
            continue
        body = {"model": a.model, "temperature": 0, "max_tokens": 80,
                "messages": [{"role": "user", "content": PROMPT.format(passage=it["passage"])}]}
        req = urllib.request.Request(a.llm.rstrip("/") + "/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=300) as resp:
            text = json.loads(resp.read())["choices"][0]["message"]["content"] or ""
        it["question"] = text.strip().strip('"').strip()
        it["copied_words"] = _longest_copy(it["question"], it["passage"])
        _save(a.out, "questions.json", {**data, "llm": a.llm, "llm_model": a.model, "prompt": PROMPT})
        print(f"{n}/{len(data['items'])} [{it['stratum']}] {it['question']}")


def _rank(results, uid):
    for i, r in enumerate(results, 1):
        if r == uid:
            return i
    return None


def cmd_run(a):
    from embedder import Embedder
    from fastembed.rerank.cross_encoder import TextCrossEncoder
    from store import Store

    items = [it for it in _load(a.out, "questions.json")["items"] if it.get("question")]
    rerankers = {name: TextCrossEncoder(model_name=m, threads=a.threads) for name, m in RERANKERS.items()}
    rows, timing = [], {}
    for arm, spec in ARMS.items():
        store = Store(_path(a.out, f"{arm}.sqlite"), spec["dim"])
        emb = Embedder(spec["model"], spec["dim"], spec["query_prefix"], threads=a.threads)
        doc_of = {r["chunk_uid"]: r["path"] for r in store.conn.execute("SELECT chunk_uid, path FROM chunks")}
        text_of = {r["chunk_uid"]: (" — ".join(p for p in (r["title"], r["section"]) if p) + "\n\n" + r["content"])
                   for r in store.conn.execute("SELECT chunk_uid, title, section, content FROM chunks")}
        missing = [it["chunk_uid"] for it in items if it["chunk_uid"] not in doc_of]
        if missing:
            sys.exit(f"{arm}: {len(missing)} sampled chunks are not in the index")
        t_emb, t_rr = [], {k: [] for k in rerankers}
        for it in items:
            q, uid = it["question"], it["chunk_uid"]
            start = time.perf_counter()
            vec = emb.embed_query(q)
            t_emb.append(time.perf_counter() - start)
            ranked = {}
            for mode in ("hybrid", "vector") + (("keyword",) if arm == "bge" else ()):
                res = store.search(vec if mode != "keyword" else None, q, top_k=TOP_K, mode=mode)
                ranked[f"{arm}/{mode}" if mode != "keyword" else "keyword"] = [r["chunk_uid"] for r in res]
            pool = [r["chunk_uid"] for r in store.search(vec, q, top_k=RERANK_POOL, mode="hybrid")]
            for name, rr in rerankers.items():
                start = time.perf_counter()
                scores = list(rr.rerank(q, [text_of[u] for u in pool]))
                t_rr[name].append(time.perf_counter() - start)
                order = sorted(range(len(pool)), key=lambda i: -scores[i])[:TOP_K]
                ranked[f"{arm}/hybrid+{name}"] = [pool[i] for i in order]
            for config, uids in ranked.items():
                rank = _rank(uids, uid)
                doc_rank = next((i for i, u in enumerate(uids, 1) if doc_of.get(u) == it["path"]), None)
                rows.append({"config": config, "stratum": it["stratum"], "chunk_uid": uid,
                             "rank": rank, "doc_rank": doc_rank, "in_pool": uid in pool})
        timing[arm] = {"query_embed_ms_median": round(1000 * statistics.median(t_emb), 1),
                       **{f"rerank_{k}_ms_median": round(1000 * statistics.median(v), 1) for k, v in t_rr.items()}}
        store.close()
    _save(a.out, "results.json", {"timing": timing, "rows": rows})
    _summary(a.out, items, rows, timing)


def _metrics(rows):
    n = len(rows)
    if not n:
        return {}
    return {"n": n,
            "r1": 100 * sum(1 for r in rows if r["rank"] == 1) / n,
            "r8": 100 * sum(1 for r in rows if r["rank"]) / n,
            "mrr": sum(1 / r["rank"] for r in rows if r["rank"]) / n,
            "doc8": 100 * sum(1 for r in rows if r["doc_rank"]) / n}


def _summary(out, items, rows, timing):
    configs = list(dict.fromkeys(r["config"] for r in rows))
    lines = ["| configuration | uniform R@8 | long R@8 | all R@8 | all R@1 | all MRR@8 | all doc R@8 |",
             "|---|---|---|---|---|---|---|"]
    for c in configs:
        sel = [r for r in rows if r["config"] == c]
        u = _metrics([r for r in sel if r["stratum"] == "uniform"])
        lg = _metrics([r for r in sel if r["stratum"] == "long"])
        al = _metrics(sel)
        lines.append(f"| `{c}` | {u['r8']:.1f} | {lg['r8']:.1f} | {al['r8']:.1f} | {al['r1']:.1f} | "
                     f"{al['mrr']:.3f} | {al['doc8']:.1f} |")
    lines += ["", "Paired, chunk in the top 8 (both / bge only / granite only / neither):"]
    for mode in ("hybrid", "vector", "hybrid+minilm", "hybrid+jina-turbo"):
        for stratum in ("uniform", "long"):
            hit = {}
            for r in rows:
                if r["stratum"] == stratum and r["config"] in (f"bge/{mode}", f"granite/{mode}"):
                    hit.setdefault(r["chunk_uid"], {})[r["config"].split("/")[0]] = bool(r["rank"])
            both = sum(1 for h in hit.values() if h.get("bge") and h.get("granite"))
            bge = sum(1 for h in hit.values() if h.get("bge") and not h.get("granite"))
            gr = sum(1 for h in hit.values() if h.get("granite") and not h.get("bge"))
            neither = sum(1 for h in hit.values() if not h.get("bge") and not h.get("granite"))
            lines.append(f"- {mode}, {stratum}: {both} / {bge} / {gr} / {neither}")
    copied = [it.get("copied_words", 0) for it in items]
    lines += ["", f"Questions: {len(items)}; longest phrase copied from the passage: median "
              f"{statistics.median(copied)} words, {sum(1 for c in copied if c >= 4)} with 4 or more.",
              f"Timing (median, this machine): {json.dumps(timing)}"]
    text = "\n".join(lines) + "\n"
    with open(_path(out, "summary.md"), "w", encoding="utf-8") as f:
        f.write(text)
    print(text)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build"); b.add_argument("--corpus", required=True); b.add_argument("--out", required=True)
    b.add_argument("--threads", type=int, default=8)
    s = sub.add_parser("sample"); s.add_argument("--out", required=True)
    s.add_argument("--seed", type=int, default=20261103); s.add_argument("--per-stratum", type=int, default=60)
    q = sub.add_parser("questions"); q.add_argument("--out", required=True); q.add_argument("--llm", required=True)
    q.add_argument("--model", default="qwen3.6-35b-a3b")
    r = sub.add_parser("run"); r.add_argument("--out", required=True); r.add_argument("--threads", type=int, default=8)
    a = ap.parse_args()
    {"build": cmd_build, "sample": cmd_sample, "questions": cmd_questions, "run": cmd_run}[a.cmd](a)


if __name__ == "__main__":
    main()
