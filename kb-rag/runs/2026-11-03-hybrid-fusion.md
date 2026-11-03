# Weighting keyword results in hybrid search (2026-11-03)

## Question

Does hybrid search find the right chunk more often if its fusion weights the keyword list
above the vector list? Does the gain hold for questions that share less wording with the
text?

## Why

kb-rag's hybrid search fuses the vector and keyword lists (100 candidates each) with
reciprocal rank fusion, `1/(60 + rank)` from each, with equal weights. In
[2026-11-03-granite-embedding.md](2026-11-03-granite-embedding.md), keyword search alone
found 87 of 120 questions, and Granite's hybrid search 84. Those questions were written
from their chunks and share their wording, which favors keyword search.

## Configuration

- **Index:** the capped Granite index from the embedding record (`granite2k`: CognitiveStack
  `b4c8a655`, Granite capped at 2,048 tokens, batch 2). This is CT 140's configuration; its
  live API returned the same counts for set A as this index on the Mac.
- **Code:** [`../eval/known_item_eval.py`](../eval/known_item_eval.py) `fusion` at the commit
  that adds this plan, on the Mac (fastembed 0.9.1, sqlite-vec 0.1.9, Python 3.11, 8
  threads). It takes the same 100 vector and 100 keyword candidates as `Store.search` and
  fuses them as `w_vector/(k + rank) + w_keyword/(k + rank)`, with `w_vector` = 1:

  | k | keyword weights |
  | --- | --- |
  | 60 (kb-rag's) | 1 (kb-rag's), 1.5, 2, 3, 5 |
  | 10 (top ranks count more) | 1, 1.5, 2, 3, 5 |

  Keyword only and vector only are reported beside them. For the first 20 questions the
  harness checks that `k=60`, weight 1 returns `Store.search`'s top 8, and stops if not.
- **Question sets** (60 `uniform` and 60 `long` chunks each, as in the embedding record):
  - **A:** the embedding record's 120 questions. The configuration is chosen on A.
  - **B:** 120 new chunks (seed 20261104, none of A's), questions from the same prompt: the
    held-out check.
  - **C:** B's chunks, with a prompt that asks for the searcher's own words: avoid the
    passage's distinctive terms, keep product, model, company and people's names. It tests
    queries that share less wording with the text.
- Questions from CT 120 (`qwen3.6-35b-a3b`, temperature 0, reasoning off). The harness
  reports, per set, the median longest phrase copied from the passage and the median share
  of the question's content words found in it.
- The sets and results are generated data, kept with the embedding record's data on CT 140
  in `/opt/kb-rag/eval/2026-11-03/`.

## What answers it

- **Choice:** the configuration with the most set-A questions in its top 8 (a tie goes to
  `k=60`, then to the smaller weight).
- **It answers the question** if, against kb-rag's fusion (`k=60`, weight 1), it finds at
  least 6 more of set B's 120 questions and at most 2 fewer of set C's.
- **Also reported:** every configuration on every set and stratum, keyword-only and
  vector-only.
- Whether to deploy is decided separately.

## Not tested

- Hermes's real queries (not logged).
- Other fusion methods (score normalization, a learned mix), and the FTS query itself (it ORs
  every word of two letters or more).

## Safety

The run is on the Mac and measures ranking; CT 140 and every other guest keep running. CT 120
answers 240 short requests at temperature 0.

## Deviations

- Set C did not do what it was for. Its questions share more of the passage's content words
  than set B's (median 71% against 60%): the model kept most of the wording. Set C2 asks for
  the same chunks with a stricter prompt (`--style paraphrase`): no word of four or more
  letters from the passage except names, numbers and version strings. It is held to set C's
  bar, at most 2 fewer than kb-rag's fusion, for the configuration already chosen on set A.
  The prompt was added after the first run (harness commit after the plan).

## Results

Appended after the run.
