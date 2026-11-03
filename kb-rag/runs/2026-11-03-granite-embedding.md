# Granite Embedding Small English R2 against bge-small-en-v1.5 (2026-11-03)

## Question

Does `ibm-granite/granite-embedding-small-english-r2` find the right chunk more often than
the deployed `BAAI/bge-small-en-v1.5`, in the search mode Hermes uses? Does a small
cross-encoder reranker over the hybrid results help more than changing the embedder?

## Why

- bge-small-en-v1.5 embeds the first 512 tokens of a chunk, and the chunker makes chunks of
  up to about 1,000 estimated tokens, some larger. On CognitiveStack `b4c8a655`, the commit
  CT 140 indexes (873 files, 7,435 chunks), 653 chunks (8.8%) are over 512 estimated tokens,
  the longest 2,083, and the text past token 512 is 10.5% of all chunk text. The keyword
  index has that text; the vector index does not.
- Granite embeds up to 8,192 tokens. IBM's model cards give the two models the same English
  retrieval score (MTEB v2, 10 tasks: 53.9) and Granite higher scores on code (CoIR 53.4
  against 45.8), tables (75.5 against 69.9), long documents (MLDR 40.1 against 31.4;
  LongEmbed 61.9 against 32.1) and multi-turn RAG (MTRAG 48.9 against 38.2).
- fastembed added Granite in 0.9.0; CT 140 runs 0.9.1. Its entry: 384 dimensions (as
  bge-small), no query or document prefix, output not normalized, ONNX weights from
  `onnx-community/granite-embedding-small-english-r2-ONNX`.

## Configuration

- **Corpus:** CognitiveStack `b4c8a655` (`main`, 2026-11-02; CT 140's index is built from it), exported
  with `git archive`.
- **Code:** this branch's kb-rag chunker, reindex, store and embedder, at the commit that adds
  this plan, driven by [`../eval/known_item_eval.py`](../eval/known_item_eval.py). The
  branch makes the embedder L2-normalize every vector. Granite needs it: fastembed returns
  its vectors unnormalized, and `vec0` ranks by L2 distance, which matches cosine only for
  unit vectors. bge-small's vectors already have unit length, so the bge arm ranks as the
  deployed index does.
- **Packages:** CT 140's pins (`fastembed==0.9.1`, `sqlite-vec==0.1.9`, `pathspec==1.1.1`,
  `PyYAML==6.0.3`) on Python 3.11.
- **Machine:** the owner's Mac (Apple M3 Max, ONNX Runtime on the CPU, 8 threads). Which
  chunk ranks where does not depend on the machine; speeds quoted from this run are the
  Mac's, not CT 140's. CT 140 is not touched.
- **Embedders:**

  | arm | model | query prefix | embeds |
  | --- | --- | --- | --- |
  | `bge` | `BAAI/bge-small-en-v1.5` (deployed) | the deployed bge instruction | 512 tokens |
  | `granite` | `ibm-granite/granite-embedding-small-english-r2` | none | 8,192 tokens |

- **Search:** each arm in `hybrid` mode (deployed default: vector and FTS5 results fused by
  reciprocal rank, top 8) and `vector` mode (the embedder alone); `keyword` mode once, since
  both indexes hold the same FTS5 table. Searches go through kb-rag's `Embedder.embed_query`
  and `Store.search`, as the API's `do_search` does.
- **Rerankers, in this test only:** kb-rag has no reranker (specced and never built, #58).
  Each arm's hybrid top 30 is rescored and the top 8 kept, with
  `Xenova/ms-marco-MiniLM-L-6-v2` (0.08 GB, reads 512 tokens) and
  `jinaai/jina-reranker-v1-turbo-en` (0.15 GB, reads 8K tokens). Both are small enough for
  CT 140's CPU. They score the text the embedder sees: title, section and chunk body.

## Questions

- 120 chunks sampled from the bge index with seed 20261103:
  - `uniform`: 60 chunks of at least 40 estimated tokens, uniform over the index.
  - `long`: 60 chunks over 512 estimated tokens. The question is written from the chunk body
    after its first 2,048 characters (about token 512 at the chunker's 4 characters a
    token), the part bge-small does not embed.
- One question per chunk from CT 120 (`qwen3.6-35b-a3b`, llama.cpp b12052, temperature 0,
  reasoning off), with the harness's prompt: a question someone could type into a search
  box that the passage answers, paraphrased (no phrase of four or more words copied), at
  most 25 words. The summary reports how many questions copy a phrase anyway.
- A question's answer is the chunk it was written from. Another chunk that carries the
  same fact counts as a miss, for both arms alike; the doc-level column counts any chunk
  of the same file as a hit.
- The sample, questions and per-question results are generated data and stay out of git.
  They are kept on CT 140 in `/opt/kb-rag/eval/2026-11-03/` for reruns.

## What answers it

- **Measurement:** recall@8 in `hybrid` mode (the source chunk is in the top 8), per
  stratum, with paired counts of the questions only one arm finds.
- **Granite** answers the question if, in `hybrid` mode, it misses at most 2 more of the 60
  `uniform` questions than bge does, and finds at least 6 more of the 60 `long` questions
  (10 points).
- **A reranker** answers its question if it adds at least 6 of the 120 questions to its
  arm's hybrid recall@8 and loses at most 2 in either stratum.
- **Also reported, not judged:** `vector` and `keyword` recall@8, recall@1, MRR@8,
  doc-level recall@8, and the Mac's median query-embedding and reranking times.
- Whether to deploy is decided separately. A switch would also measure the rebuild time
  and peak memory on CT 140 (batches of 32 chunks, now cut at 512 tokens, of up to about
  2,100).

## Not tested

- Hermes's real queries: the server logs no query text.
- CT 140's rebuild time and memory with Granite.
- Larger embedders (bge-m3, Granite 149M), and chunking changed to use Granite's 8K input.

## Safety

The run is on the Mac and measures ranking, not lab speed, so no guest is stopped or
started. CT 140 keeps serving. CT 120 answers 120 short requests at temperature 0 beside
its usual traffic.

## Results

Appended after the run.
