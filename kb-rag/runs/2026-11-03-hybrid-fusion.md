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

Run 2026-11-03, 14:15–14:20 EST: sets A, B and C at harness `48c2cd1`, then C2 at `021a0fd`
(the fusion grid unchanged between them). The `k=60`, weight 1 rows matched `Store.search`
for the first 20 questions.

| set | longest phrase copied, median words | content words found in the passage, median |
| --- | --- | --- |
| A | 3 | 60% |
| B | 3 | 60% |
| C | 3 | 71% |
| C2 | 2 | 50% |

Questions with the source chunk in the top 8, of 60 per stratum and 120 per set:

| fusion | A uniform | A long | B uniform | B long | C uniform | C long | C2 uniform | C2 long | A | B | C | C2 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `k60 kw1` (kb-rag) | 49 | 35 | 49 | 22 | 55 | 35 | 40 | 18 | 84 | 71 | 90 | 58 |
| `k60 kw1.5` | 51 | 39 | 49 | 26 | 56 | 38 | 42 | 21 | 90 | 75 | 94 | 63 |
| `k60 kw2` | 50 | 38 | 50 | 28 | 56 | 40 | 41 | 22 | 88 | 78 | 96 | 63 |
| `k60 kw3` | 51 | 39 | 53 | 35 | 56 | 39 | 41 | 24 | 90 | 88 | 95 | 65 |
| `k60 kw5` | 52 | 39 | 54 | 37 | 57 | 43 | 39 | 23 | 91 | 91 | 100 | 62 |
| `k10 kw1` | 50 | 37 | 51 | 29 | 57 | 41 | 41 | 24 | 87 | 80 | 98 | 65 |
| `k10 kw1.5` | 52 | 40 | 53 | 36 | 57 | 44 | 40 | 24 | 92 | 89 | 101 | 64 |
| `k10 kw2` | 52 | 39 | 54 | 38 | 57 | 44 | 41 | 25 | 91 | 92 | 101 | 66 |
| `k10 kw3` | 52 | 37 | 54 | 39 | 57 | 44 | 40 | 25 | 89 | 93 | 101 | 65 |
| `k10 kw5` | 52 | 38 | 55 | 40 | 57 | 43 | 40 | 24 | 90 | 95 | 100 | 64 |
| keyword only | 51 | 36 | 55 | 41 | 57 | 43 | 37 | 24 | 87 | 96 | 100 | 61 |
| vector only | 38 | 21 | 38 | 10 | 51 | 19 | 29 | 10 | 59 | 48 | 70 | 39 |

- Some C2 questions append an answer to the question, and at least one asks about a
  different figure than its chunk gives; C2's counts carry that noise.
- The sets, questions and tables are on CT 140 in `/opt/kb-rag/eval/2026-11-03/fusion/`.

## Conclusion

- **The choice on set A** is `k=10`, keyword weight 1.5: 92 of 120, against 84 for kb-rag's
  fusion.
- **It meets the plan's bar.** On the held-out set B it finds 89 against 71 (the bar: at
  least 6 more), on set C 101 against 90 and on set C2 64 against 58 (the bar: at most 2
  fewer). No stratum of any set finds fewer than with kb-rag's fusion.
- **Keyword search alone** finds more than the choice on set B (96 against 89) and fewer on
  sets A and C2 (87 and 61, against 92 and 64): on the questions that share the least of the
  passage's wording, fusion keeps an advantage over keyword search.
- **The vector list alone** finds the fewest on every set (39 to 70).
- Whether to deploy is decided separately.
