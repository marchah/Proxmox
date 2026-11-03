# Splitting oversized tables and lists (2026-11-03)

## Question

With oversized tables and lists split into pieces of their own, does every chunk fit
Granite's 2,048-token input cap, does search find the table rows and list items the cap
hid, and do the other questions keep their results?

## Why

- Granite's input is capped at 2,048 tokens on CT 140
  ([2026-11-03-granite-embedding.md](2026-11-03-granite-embedding.md)). On CognitiveStack
  `b4c8a655`, 22 chunks were longer: 18 hold a large table and 4 a long list.
- The chunker splits an oversized section by blank lines, and a table or list has none, so it
  stays one block. The 1-paragraph overlap between windows then repeats that block in the
  next chunk: each oversized block appears in two chunks (`... ` and `... (2)`).
- 64 table rows and list items of 40 characters or more sit past token 2,048 in every chunk
  that holds them. Vector search cannot see them; keyword search can.

## Change

[`../app/chunker.py`](../app/chunker.py): inside a section that is sub-split, a block (no
blank line) estimated above 500 tokens is split into pieces of at most 500, each its own
window, with no overlap carried into or out of it. A table splits into row groups that each
repeat the header row and separator; a list splits by top-level item, with nested lines kept
with their item; anything else splits by line. A single row or item over 500 stays whole.
The estimate counts table lines at 2.25 characters a token, since Granite reads 1.77 tokens
per 4 characters of a table at the median (2.13 at p90), and other lines at 4.

Measured on the corpus before the run, with Granite's tokenizer:

| | old chunker | new chunker |
| --- | --- | --- |
| chunks | 7,435 | 7,655 |
| longest, Granite tokens | 4,013 | 1,854 |
| over 2,048 tokens | 22 | 0 |
| over 1,024 tokens | 212 | 111 |
| chunks unchanged (same uid and content hash) | | 7,261 of the old 7,435, in 46 files changed |

## Configuration

- **Old index:** `granite2k` from the embedding record (old chunker), as CT 140 serves.
- **New index:** `granite2k` built with this branch's chunker at the commit that adds this
  plan: CognitiveStack `b4c8a655`, Granite capped at 2,048 tokens, batch 2.
- **Search:** kb-rag's `Store.search` with the deployed fusion (`rrf_k` 10,
  `keyword_weight` 1.5), in `hybrid` and `vector` mode, top 8, through
  [`../eval/known_item_eval.py`](../eval/known_item_eval.py) `compare`, on the Mac (fastembed
  0.9.1, sqlite-vec 0.1.9, Python 3.11, 8 threads).
- **Question sets:**
  - **T:** one question for each hidden row or item (`hidden-sample` on the old index), from
    CT 120 (`qwen3.6-35b-a3b`, temperature 0, the standard prompt). The passage is the
    section heading, the table header and the row (or the list item). A question counts as
    found if one of the top 8 chunks contains that row or item.
  - **A, B and C2** from the fusion record. A question counts only if its target chunk is
    the same in both indexes (same uid and content hash); the others are reported as
    excluded.

## What answers it

The split answers the question if:

- no chunk of the new index is over 2,048 Granite tokens;
- on set T, `vector` mode finds at least a quarter of the questions more with the new index
  than with the old, and `hybrid` mode finds at least as many;
- on each of sets A, B and C2, `hybrid` mode finds at most 2 fewer with the new index.

Whether to deploy is decided separately.

## Not tested

- Hermes's real queries (not logged).
- Splitting long prose paragraphs, or changing the section windows themselves.

## Safety

The run is on the Mac; CT 140 and every other guest keep running. CT 120 answers about 64
short requests at temperature 0.

## Results

Appended after the run.
