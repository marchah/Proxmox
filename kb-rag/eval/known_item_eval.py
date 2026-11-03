#!/usr/bin/env python3
"""Known-item retrieval test for kb-rag: does a question written from one chunk find that chunk?

    known_item_eval.py build     --corpus DIR --out DIR [--threads N]
    known_item_eval.py sample    --out DIR [--seed N] [--per-stratum N]
    known_item_eval.py questions --out DIR --llm URL [--model NAME]
    known_item_eval.py run       --out DIR [--threads N]
    known_item_eval.py fusion    --index DB --set NAME=QUESTIONS.json ... [--threads N]
    known_item_eval.py hidden-sample --index DB --out DIR [--cap N]
    known_item_eval.py compare   --old DB --new DB --set NAME=QUESTIONS.json ... [--threads N]

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
fusion     searches question sets against one index (capped Granite, as deployed) and fuses
           the vector and keyword candidate lists (100 each, as Store.search) with weighted
           reciprocal rank fusion, w_vector/(k + rank) + w_keyword/(k + rank), over a grid of
           k and keyword weights; k=60, weights 1 and 1 is kb-rag's search. Prints recall@8
           per set and stratum, and how much each set's questions share the passage's words.
hidden-sample  lists the table rows and list items (40+ characters) that sit past Granite token
           N (default 2,048) in every chunk of the index that holds them: the lines its
           vector search cannot see. Each becomes a `hidden` item into OUT/sample.json, with
           the line as `target_line` and, as passage, the section heading, the table header
           and the row (or the list item).
compare    searches question sets against two indexes (chunkers) with the deployed config's
           fusion (Store with rrf_k and keyword_weight), in hybrid and vector mode. An item
           with `target_line` counts as found if a top-8 chunk contains that line; any other
           counts only if its target chunk is unchanged in both indexes (same uid and
           content hash), and the others are counted as excluded.

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
    # bge's own query instruction, set here: index.config.yaml now holds Granite's empty prefix.
    "bge": {"model": "BAAI/bge-small-en-v1.5", "dim": 384,
            "query_prefix": "Represent this sentence for searching relevant passages: "},
    # Batch 2: at kb-rag's default 32, ONNX Runtime refuses the > 4 GiB tensor that Granite's
    # global attention mask (/model/global_attn_mask/Tile) needs for a batch of long chunks.
    # The batch size changes memory use, not the vectors.
    "granite": {"model": "ibm-granite/granite-embedding-small-english-r2", "dim": 384, "query_prefix": "",
                "batch_size": 2},
    # Granite as deployed on CT 140: input capped at 2,048 tokens to fit its 4 GB.
    "granite2k": {"model": "ibm-granite/granite-embedding-small-english-r2", "dim": 384, "query_prefix": "",
                  "batch_size": 2, "max_tokens": 2048},
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


PROMPT_REWORDED = """Here is a passage from a technical knowledge base about AI tools, models and infrastructure.

<passage>
{passage}
</passage>

Write one question that someone could type into a search box and that this passage answers.
- Ask about a specific fact stated in the passage.
- Use your own words: avoid the passage's distinctive terms and phrases. Keep names of
  products, models, companies and people as they are, since a searcher would type them.
- Do not mention "the passage", "the text" or "the document".
- Use at most 25 words.
Reply with the question only."""
PROMPT_PARAPHRASE = """Here is a passage from a technical knowledge base about AI tools, models and infrastructure.

<passage>
{passage}
</passage>

Write one question that someone could type into a search box and that this passage answers.
- Ask about a specific fact stated in the passage.
- Write it in different words from the passage. You may reuse names of products, models,
  companies and people, numbers and version strings, but no other word of four or more
  letters that appears in the passage: use synonyms, or describe the idea instead.
- Do not mention "the passage", "the text" or "the document".
- Use at most 25 words.
Reply with the question only."""
PROMPTS = {"standard": PROMPT, "reworded": PROMPT_REWORDED, "paraphrase": PROMPT_PARAPHRASE}
FUSION_GRID = [(k, w) for k in (60, 10) for w in (1, 1.5, 2, 3, 5)]
STOP = set("what which when where with that this from does have into about their there they them than then "
           "these those were been being will would could should also only more most such over used uses using "
           "much many make made each other some your".split())


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
    report = _load(a.out, "build.json") if os.path.exists(_path(a.out, "build.json")) else {}
    for arm in a.arms.split(","):
        spec = ARMS[arm]
        if not spec.get("max_tokens"):
            os.environ.pop("KB_EMBED_MAX_TOKENS", None)
        db = _path(a.out, f"{arm}.sqlite")
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(db + suffix):
                os.remove(db + suffix)
        os.environ.update({
            "KB_REPO_DIR": os.path.abspath(a.corpus), "KB_DB_PATH": db, "KB_EMBED_MODEL": spec["model"],
            "KB_EMBED_DIM": str(spec["dim"]), "KB_EMBED_THREADS": str(a.threads),
            "KB_EMBED_BATCH_SIZE": str(spec.get("batch_size", DEPLOYED["embed_batch_size"])),
            "KB_EMBED_MAX_TOKENS": str(spec.get("max_tokens", 0)),
        })
        start = time.time()
        summary = reindex.run(full=True, no_git=True, config_path=CONFIG)
        report[arm] = {**spec, **summary, "seconds": round(time.time() - start, 1)}
        print(f"{arm}: {report[arm]['seconds']} s")
    _save(a.out, "build.json", report)


def cmd_sample(a):
    con = sqlite3.connect(_path(a.out, a.index))
    con.row_factory = sqlite3.Row
    rows = con.execute(
        "SELECT chunk_uid, path, title, section, content, token_count FROM chunks ORDER BY chunk_uid"
    ).fetchall()
    skip = set()
    for f in a.exclude or []:
        with open(f, encoding="utf-8") as fh:
            skip |= {it["chunk_uid"] for it in json.load(fh)["items"]}
    rows = [r for r in rows if r["chunk_uid"] not in skip]
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
    _save(a.out, "sample.json", {"seed": a.seed, "chunks_in_index": len(rows) + len(skip),
                                 "excluded": len(skip), "items": items})
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
                "messages": [{"role": "user", "content": PROMPTS[a.style].format(passage=it["passage"])}]}
        req = urllib.request.Request(a.llm.rstrip("/") + "/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=300) as resp:
            text = json.loads(resp.read())["choices"][0]["message"]["content"] or ""
        it["question"] = text.strip().strip('"').strip()
        it["copied_words"] = _longest_copy(it["question"], it["passage"])
        _save(a.out, "questions.json", {**data, "llm": a.llm, "llm_model": a.model, "style": a.style,
                                        "prompt": PROMPTS[a.style]})
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
    rerankers = {} if a.no_rerank else {
        name: TextCrossEncoder(model_name=m, threads=a.threads) for name, m in RERANKERS.items()}
    rows, timing = [], {}
    for arm in a.arms.split(","):
        spec = ARMS[arm]
        store = Store(_path(a.out, f"{arm}.sqlite"), spec["dim"])
        emb = Embedder(spec["model"], spec["dim"], spec["query_prefix"], threads=a.threads,
                       max_tokens=spec.get("max_tokens", 0))
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
            pool = [r["chunk_uid"] for r in store.search(vec, q, top_k=RERANK_POOL, mode="hybrid")] if rerankers else []
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


def _content_overlap(question, passage):
    """Share of the question's content words (4+ letters, not stopwords) found in the passage."""
    words = [w for w in _words(question) if len(w) >= 4 and w not in STOP]
    if not words:
        return 0.0
    have = set(_words(passage))
    return sum(1 for w in words if w in have) / len(words)


def cmd_fusion(a):
    from embedder import Embedder
    from store import Store, _CANDIDATES

    spec = ARMS["granite2k"]
    store = Store(a.index, spec["dim"])
    emb = Embedder(spec["model"], spec["dim"], spec["query_prefix"], threads=a.threads,
                   max_tokens=spec["max_tokens"])
    uid_of = {r["id"]: r["chunk_uid"] for r in store.conn.execute("SELECT id, chunk_uid FROM chunks")}
    sets = {}
    for arg in a.set:
        name, path = arg.split("=", 1)
        with open(path, encoding="utf-8") as f:
            sets[name] = [it for it in json.load(f)["items"] if it.get("question")]
    configs = [f"k{k} kw{w:g}" for k, w in FUSION_GRID] + ["keyword", "vector"]
    hits = {c: {} for c in configs}
    checked = 0
    lines = ["| set | questions | longest copy, median words | content words in the passage, median |",
             "| --- | --- | --- | --- |"]
    for name, items in sets.items():
        lines.append(f"| {name} | {len(items)} | {statistics.median(_longest_copy(i['question'], i['passage']) for i in items)} | "
                     f"{100 * statistics.median(_content_overlap(i['question'], i['passage']) for i in items):.0f}% |")
        for it in items:
            q, uid = it["question"], it["chunk_uid"]
            vec = emb.embed_query(q)
            v_ids = store._vector_ids(vec, _CANDIDATES)
            k_ids = store._keyword_ids(q, _CANDIDATES)
            ranked = {"keyword": k_ids[:TOP_K], "vector": v_ids[:TOP_K]}
            for k, w in FUSION_GRID:
                scores = {}
                for weight, ids in ((1.0, v_ids), (w, k_ids)):
                    for rank, cid in enumerate(ids):
                        scores[cid] = scores.get(cid, 0.0) + weight / (k + rank + 1)
                ranked[f"k{k} kw{w:g}"] = [cid for cid, _ in sorted(scores.items(), key=lambda kv: kv[1],
                                                                   reverse=True)[:TOP_K]]
            if checked < 20:  # the k=60, equal-weight row must be kb-rag's own search
                live = [r["chunk_uid"] for r in store.search(vec, q, top_k=TOP_K, mode="hybrid")]
                assert [uid_of[c] for c in ranked["k60 kw1"]] == live, "fusion grid does not match Store.search"
                checked += 1
            for c in configs:
                key = (name, it["stratum"])
                h = hits[c].setdefault(key, [0, 0])
                h[0] += any(uid_of[cid] == uid for cid in ranked[c])
                h[1] += 1
    cols = [(n, st) for n in sets for st in ("uniform", "long")]
    lines += ["", "| fusion | " + " | ".join(f"{n} {st}" for n, st in cols) + " | " +
              " | ".join(f"{n} all" for n in sets) + " |",
              "| --- |" + " --- |" * (len(cols) + len(sets))]
    for c in configs:
        cells = [f"{hits[c][col][0]}/{hits[c][col][1]}" for col in cols]
        alls = [f"{sum(hits[c][(n, st)][0] for st in ('uniform', 'long'))}" for n in sets]
        lines.append(f"| `{c}` | " + " | ".join(cells) + " | " + " | ".join(alls) + " |")
    text = "\n".join(lines) + "\n"
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text)
    print(text)


def cmd_hidden_sample(a):
    from fastembed import TextEmbedding

    tok = TextEmbedding(ARMS["granite"]["model"], threads=8).model.tokenizer
    tok.no_truncation()
    tok.no_padding()
    con = sqlite3.connect(a.index)
    rows = con.execute("SELECT chunk_uid, path, title, section, content FROM chunks ORDER BY chunk_uid").fetchall()
    visible, where = {}, {}
    for uid, path, title, section, body in rows:
        text = (" — ".join(p for p in (title, section) if p) + "\n\n" + body) if (title or section) else body
        enc = tok.encode(text)
        cut = len(text) if len(enc.ids) <= a.cap else enc.offsets[a.cap - 1][1]
        lines, pos, header = text.splitlines(keepends=True), 0, ""
        for i, ln in enumerate(lines):
            line = ln.strip()
            nxt = lines[i + 1].strip() if i + 1 < len(lines) else ""
            if line.startswith("|") and re.match(r"^\|?\s*:?-{3,}", nxt):
                header = line + "\n" + nxt
            is_row = line.startswith("|") and not re.match(r"^\|?\s*:?-{3,}", line) and line != header.split("\n")[0]
            if (is_row or line.startswith("- ")) and len(line) >= 40:
                where.setdefault(line, (uid, path, section, header if is_row else ""))
                visible[line] = visible.get(line, False) or pos + len(ln) <= cut
            pos += len(ln)
    items = []
    for line, (uid, path, section, header) in sorted(where.items()):
        if visible[line]:
            continue
        passage = "\n".join(x for x in (f"Section: {section}" if section else "", header, line) if x)
        items.append({"stratum": "hidden", "chunk_uid": uid, "path": path, "token_count": 0,
                      "target_line": line, "passage": passage})
    os.makedirs(a.out, exist_ok=True)
    _save(a.out, "sample.json", {"cap": a.cap, "chunks_in_index": len(rows), "items": items})
    print(f"{len(items)} lines hidden past token {a.cap}")


def cmd_compare(a):
    from embedder import Embedder
    from store import Store

    spec = ARMS["granite2k"]
    emb = Embedder(spec["model"], spec["dim"], spec["query_prefix"], threads=a.threads,
                   max_tokens=spec["max_tokens"])
    stores = {name: Store(path, spec["dim"], rrf_k=DEPLOYED["rrf_k"], keyword_weight=DEPLOYED["keyword_weight"])
              for name, path in (("old", a.old), ("new", a.new))}
    meta = {name: {r["chunk_uid"]: (r["content_hash"], r["content"])
                   for r in st.conn.execute("SELECT chunk_uid, content_hash, content FROM chunks")}
            for name, st in stores.items()}
    lines = [f"Fusion: rrf_k {DEPLOYED['rrf_k']}, keyword_weight {DEPLOYED['keyword_weight']}. Chunks: "
             f"old {len(meta['old'])}, new {len(meta['new'])}.", "",
             "| set | stratum | questions | excluded | old hybrid | new hybrid | old vector | new vector |",
             "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for arg in a.set:
        name, path = arg.split("=", 1)
        with open(path, encoding="utf-8") as f:
            items = [it for it in json.load(f)["items"] if it.get("question")]
        tally = {}
        for it in items:
            t = tally.setdefault(it["stratum"], {"n": 0, "excluded": 0})
            line = it.get("target_line")
            uid = it["chunk_uid"]
            if not line and not (uid in meta["old"] and meta["old"][uid][0] == meta["new"].get(uid, ("",))[0]):
                t["excluded"] += 1
                continue
            t["n"] += 1
            vec = emb.embed_query(it["question"])
            for side, st in stores.items():
                for mode in ("hybrid", "vector"):
                    res = st.search(vec, it["question"], top_k=TOP_K, mode=mode)
                    if line:
                        hit = any(line in meta[side][r["chunk_uid"]][1] for r in res)
                    else:
                        hit = any(r["chunk_uid"] == uid for r in res)
                    t[f"{side} {mode}"] = t.get(f"{side} {mode}", 0) + hit
        for stratum, t in tally.items():
            lines.append(f"| {name} | {stratum} | {t['n']} | {t['excluded']} | " + " | ".join(
                str(t.get(k, 0)) for k in ("old hybrid", "new hybrid", "old vector", "new vector")) + " |")
    text = "\n".join(lines) + "\n"
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text)
    print(text)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build"); b.add_argument("--corpus", required=True); b.add_argument("--out", required=True)
    b.add_argument("--threads", type=int, default=8)
    b.add_argument("--arms", default=",".join(ARMS), help="comma-separated arms to (re)build")
    s = sub.add_parser("sample"); s.add_argument("--out", required=True)
    s.add_argument("--seed", type=int, default=20261103); s.add_argument("--per-stratum", type=int, default=60)
    s.add_argument("--index", default="bge.sqlite", help="index file in OUT to sample from")
    s.add_argument("--exclude", action="append", help="questions or sample JSON whose chunks to skip")
    q = sub.add_parser("questions"); q.add_argument("--out", required=True); q.add_argument("--llm", required=True)
    q.add_argument("--model", default="qwen3.6-35b-a3b")
    q.add_argument("--style", choices=sorted(PROMPTS), default="standard")
    f = sub.add_parser("fusion"); f.add_argument("--index", required=True)
    f.add_argument("--set", action="append", required=True, help="NAME=questions.json")
    f.add_argument("--out", help="also write the tables here"); f.add_argument("--threads", type=int, default=8)
    h = sub.add_parser("hidden-sample"); h.add_argument("--index", required=True); h.add_argument("--out", required=True)
    h.add_argument("--cap", type=int, default=2048)
    c = sub.add_parser("compare"); c.add_argument("--old", required=True); c.add_argument("--new", required=True)
    c.add_argument("--set", action="append", required=True, help="NAME=questions.json")
    c.add_argument("--out", help="also write the table here"); c.add_argument("--threads", type=int, default=8)
    r = sub.add_parser("run"); r.add_argument("--out", required=True); r.add_argument("--threads", type=int, default=8)
    r.add_argument("--arms", default="bge,granite", help="comma-separated arms to search")
    r.add_argument("--no-rerank", action="store_true", help="skip the rerankers")
    a = ap.parse_args()
    {"build": cmd_build, "sample": cmd_sample, "questions": cmd_questions, "run": cmd_run,
     "fusion": cmd_fusion, "hidden-sample": cmd_hidden_sample, "compare": cmd_compare}[a.cmd](a)


if __name__ == "__main__":
    main()
