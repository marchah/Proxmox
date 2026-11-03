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

## Deviations

- The first Granite build, at kb-rag's default batch of 32 chunks, stopped: ONNX Runtime
  refused a tensor over 4 GiB in Granite's global attention mask
  (`/model/global_attn_mask/Tile`) for a batch of long chunks. By Granite's tokenizer the
  chunks run to 4,013 tokens (median 169, p99 1,544; 883, or 11.9%, over 512). The Granite
  index was built again at batch 2 (harness commit after the plan); the batch size changes
  memory use, not the vectors. The bge index, built at batch 32 before the failure, was kept.

## Results

Run 2026-11-03, 12:09–12:29 EST, harness `c7a268a`, on the Mac at 8 threads. Both indexes
hold 873 files and 7,435 chunks. bge-small built in 343 s at batch 32, Granite in 318 s at
batch 2.

Recall@8 is the share of questions whose source chunk is in the top 8; 60 questions per
stratum.

| configuration | uniform R@8 | long R@8 | all R@8 | all R@1 | all MRR@8 | all doc R@8 |
| --- | --- | --- | --- | --- | --- | --- |
| `bge/hybrid` (deployed) | 78.3 | 43.3 | 60.8 | 35.8 | 0.442 | 70.8 |
| `bge/vector` | 70.0 | 20.0 | 45.0 | 21.7 | 0.305 | 63.3 |
| `granite/hybrid` | 81.7 | 58.3 | 70.0 | 40.0 | 0.498 | 75.8 |
| `granite/vector` | 63.3 | 35.0 | 49.2 | 25.8 | 0.338 | 59.2 |
| `keyword` (both indexes) | 85.0 | 60.0 | 72.5 | 42.5 | 0.534 | 76.7 |
| `bge/hybrid` + MiniLM rerank | 83.3 | 31.7 | 57.5 | 37.5 | 0.442 | 73.3 |
| `bge/hybrid` + Jina turbo rerank | 86.7 | 30.0 | 58.3 | 37.5 | 0.441 | 72.5 |
| `granite/hybrid` + MiniLM rerank | 83.3 | 30.0 | 56.7 | 37.5 | 0.442 | 70.8 |
| `granite/hybrid` + Jina turbo rerank | 83.3 | 28.3 | 55.8 | 36.7 | 0.429 | 70.8 |

Paired, source chunk in the top 8 (both / bge only / Granite only / neither):

| mode | uniform | long |
| --- | --- | --- |
| hybrid | 45 / 2 / 4 / 9 | 24 / 2 / 11 / 23 |
| vector | 36 / 6 / 2 / 16 | 9 / 3 / 12 / 36 |

- **Questions:** the longest phrase a question copies from its passage is 3 words at the
  median. 26 questions (11 uniform, 15 long) copy four words or more, against the prompt.
  Without them, hybrid recall@8 is 37/49 uniform and 17/45 long for bge, 38/49 and 25/45
  for Granite, and 40/49 and 26/45 for keyword search.
- **Rerankers:** the hybrid top 30 they rescore holds the source chunk for 54 of 60 uniform
  questions with either embedder, and for 38 (bge) and 44 (Granite) of 60 long questions.
  After reranking, the top 8 keeps 50 (MiniLM) and 52 (Jina) uniform chunks on bge, but 19
  and 18 long ones; on Granite, 18 and 17 long ones.
- **Time, Mac, median per query:** embedding the query 6.7 ms (bge) and 6.8 ms (Granite);
  reranking 30 candidates 0.64 s (MiniLM) and 0.86 s (Jina turbo).
- The sample, questions, per-question results and logs are on CT 140 in
  `/opt/kb-rag/eval/2026-11-03/`.

## Conclusion

- **Granite meets the plan's bar.** In hybrid mode it finds 49 of the 60 uniform questions
  against bge's 47 (the bar: at most 2 fewer), and 35 of the 60 long ones against 26 (the
  bar: at least 6 more). Paired, 15 questions are found only by Granite and 4 only by bge.
  The gain is in the text past token 512: in vector mode Granite finds 21 long questions to
  bge's 12, and 4 fewer uniform ones.
- **Neither reranker meets its bar.** On bge they add 3 (MiniLM) and 5 (Jina turbo) uniform
  questions and lose 7 and 8 long ones, 4 and 3 fewer overall. On Granite they find 68 and
  67 of the 120 questions, against 84 without them.
- **Keyword search alone** finds 87 of the 120 questions, more than bge hybrid (73) or
  Granite hybrid (84), and still more without the 26 copying questions (66 of 94, against
  54 and 63). Questions written by a model from the passage share its wording, which
  favors keyword search; how close Hermes's own queries are is not measured.
- Whether to deploy is decided separately. A switch also needs the rebuild time and peak
  memory on CT 140 at a batch size that fits (batch 2 ran here).
