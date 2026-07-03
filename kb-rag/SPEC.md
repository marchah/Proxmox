# CT 140 `kb-rag` — Knowledge-base RAG retrieval service (design spec)

Status: **proposed** (design doc; `create-lxc-kb-rag.sh` + `README.md` to follow this spec).

A single, always-on retrieval service that indexes the **CognitiveStack** Markdown
knowledge base and exposes semantic + keyword search to every agent on the server
(Hermes / CT 121 today, future agents later) over one network endpoint — REST **and**
MCP-over-HTTP.

## Guiding principle (read this first)

**Markdown-in-git stays the source of truth. This container holds only a derived,
rebuildable index.** Nothing here is authoritative: wipe `/opt/kb-rag/data` and a reindex
reconstructs it from the git repo. This keeps the KB diffable, reviewable, and greppable in
git, and lets us swap embedding models / re-chunk / re-rank without touching the agents that
consume it. If the vector store ever becomes the place where knowledge lives, we've regressed.

Consequence: the whole service is disposable. The rootfs uses `backup=0` — back up the
CognitiveStack git repo, not this container.

## Identity & placement

| Field | Value | Rationale |
| --- | --- | --- |
| VMID | `140` | Databases range `140-159` — the durable artifact is a vector+FTS **database**. (Alt: `122` in the AI range `120-139` since agents consume it. Decision flagged below.) |
| Hostname | `kb-rag` | Reachable by name from the NAT LAN via dnsmasq, like `llamacpp`. |
| Template | Debian 12 standard (`pveam`, latest) | Same as `hermes` / `bench-runner`. |
| Privilege | **unprivileged** | No hardware access needed. |
| GPU | **none** | Embeddings run on CPU (see below). No `/dev/dri` passthrough. |
| Cores | `4` | Parallel embedding during reindex; idle otherwise. |
| Memory | `4096` MB (bge-small) / `8192` MB (bge-m3 or reranker on) | ONNX runtime + model + FastAPI. |
| Root size | `12` GB | venv + ONNX model cache + git checkout + sqlite index. All rebuildable. |
| Net | `vmbr0`, `ip=dhcp` | Gets `10.10.10.140` behind the host WiFi-NAT; agents reach it by hostname. |
| On boot | yes | Persistent service. |
| Backup | rootfs `backup=0` | Index is rebuildable from git. |

## Corpus policy (include / exclude)

Configured as gitignore-style globs in `index.config.yaml` (NOT hardcoded), so the policy is
editable without touching the reindexer. Only `*.md` files are ever eligible; everything else
(`.stl`, `.png`, `.scad`, `.py`, `.DS_Store`) is ignored by construction.

**Included** — the reusable knowledge catalogs + patterns/architectures:

```
agent-skills.md              ai-coding-agent-plugins.md   ai-tools.md
chatgpt-apps.md              cloud-native-tools.md        local-ai-models.md
mcp.md                       model-reference-sources.md   software-libraries.md
coding-architectures/*.md    coding-paradigms-and-patterns/*.md
```

**Excluded**:

| Path | Why |
| --- | --- |
| `jobs/**` | Daily automation reports — separated for now, per your instruction. (Easy to add later as its own corpus/namespace.) |
| `hardware.md`, `hardware/**` | Personal hardware/build notes. |
| `gpu-llm-upgrade-guide.md` | Personal purchasing/upgrade planning. |
| `claude-gpu-recommendation.md` | Personal GPU purchasing rec (the "couple others" — same class as the two above). **Confirm.** |
| `hermes/**` | Agent config/automation, not knowledge. |
| `README.md`, `INDEX.md`, `SCHEMA.md`, `AGENT_GUIDE.md` | KB navigation/meta, not domain knowledge — excluding keeps retrieval from returning "how the KB works" instead of answers. |
| `**/README.md` (in subfolders) | Folder nav (`coding-architectures/README.md`, etc.). |

Default `index.config.yaml`:

```yaml
repo_url: git@github.com:marchah/CognitiveStack.git
branch: main
include:
  - "*.md"
  - "coding-architectures/*.md"
  - "coding-paradigms-and-patterns/*.md"
exclude:
  - "jobs/**"
  - "hardware.md"
  - "hardware/**"
  - "gpu-llm-upgrade-guide.md"
  - "claude-gpu-recommendation.md"
  - "hermes/**"
  - "README.md"
  - "INDEX.md"
  - "SCHEMA.md"
  - "AGENT_GUIDE.md"
  - "**/README.md"
```

## Architecture / data flow

```
CognitiveStack (GitHub, private)          ── source of truth ──
        │  git pull (read-only deploy key)
        ▼
  /opt/kb-rag/data/repo  ──►  reindex.py  ──►  chunker.py  ──►  embedder (fastembed, CPU)
                                                                      │
                                                            /opt/kb-rag/data/kb.sqlite
                                                            (sqlite-vec + FTS5 + metadata)
                                                                      │
                              server.py (FastAPI)  ◄───────── query ──┘
                              ├─ REST   /v1/search /v1/doc /v1/stats /health
                              └─ MCP    /mcp  (kb_search, kb_get, kb_stats)
                                        ▲
              ┌─────────────────────────┼─────────────────────────┐
        Hermes / CT 121          future agent            any HTTP client
        (adds it as an MCP server)                       (curl, scripts)
```

Reindex is driven by a systemd timer (pull every 10 min, reindex only if `HEAD` changed) plus
an on-demand `kb-reindex` command. Incremental: only chunks whose `content_hash` changed are
re-embedded, so routine reindexes are cheap.

## Component choices

Kept deliberately light for a ~29k-line / ~800–1500-chunk corpus. Alternatives noted; the
justification for a dedicated container is **shared multi-agent access**, not corpus size.

- **Store: SQLite + [`sqlite-vec`](https://github.com/asg017/sqlite-vec) + FTS5.** One file,
  no server, trivial backup/reset, concurrent reads are fine. Hybrid search = FTS5 **BM25**
  (keyword/exact) ⊕ `sqlite-vec` **KNN** (semantic), merged with **Reciprocal Rank Fusion**
  (RRF, k=60). Hybrid beats pure-vector on a structured technical corpus — vectors add recall,
  BM25 + metadata filters supply precision. (Alt: LanceDB if the corpus 10×'s; Qdrant only if
  concurrency demands a real server. Not now.)
- **Embeddings: [`fastembed`](https://github.com/qdrant/fastembed) (ONNX Runtime, CPU).** No
  torch, no CUDA, prebuilt quantized models — one Python process does embed + store + serve.
  Default model **`BAAI/bge-small-en-v1.5`** (384-dim, fast, English technical text). Pin
  `model` **and** `revision` in config. (Alt: `BAAI/bge-m3` — 1024-dim, multilingual, stronger
  recall, ~2 GB RAM; `Qwen3-Embedding-0.6B`.) **Changing the model requires a full reindex** —
  the `sqlite-vec` vector dimension must match. Do **not** run embeddings on CT 120's GPU: it's
  busy serving the 35B model, and query-time embedding of one short query is milliseconds on
  CPU; batch indexing is offline.
- **Reranker (optional, `RERANK=1`): `BAAI/bge-reranker-v2-m3` via fastembed.** Reorders the
  top-30 hybrid candidates → top-`k`. Best precision, but +latency and +~2 GB RAM. Default
  **off**; turn on once the corpus is large enough that ranking matters.
- **API: FastAPI + uvicorn.** Serves REST and the MCP-over-HTTP transport from one app/port.
- **MCP: streamable-HTTP MCP server** (Python `mcp` SDK) at `/mcp`, so agents in *other*
  containers connect over the network (stdio MCP can't cross containers). Hermes registers it
  as an MCP server; the same app also answers plain REST for non-MCP clients.

## Chunking & metadata

The corpus is currently **mixed** — big catalog files where each `## Heading` is one item
(`ai-tools.md`: 80 items) *and* one-concept-per-file pattern notes. The chunker handles both,
so **splitting the megafiles (the earlier "Phase 1") is NOT a prerequisite** — do it later to
improve `related:` links; it isn't a blocker.

Rules:

1. Split every file on `## ` (H2). Each section = one chunk (a tool, a model, a pattern).
2. If a section still exceeds ~1000 tokens, sub-split on `### ` (H3), then by paragraph window
   with overlap.
3. Files with no H2 (short pattern notes) = one chunk.
4. Each chunk carries file-level frontmatter (`title`, `type`, `status`, `tags`, `source`,
   `confidence`) **plus** the section heading as `section`, **plus** per-entry freshness
   parsed from the catalog body (`Added:` / `Last verified:` lines) — falling back to
   frontmatter `created` / `last_verified`. This exploits the existing SCHEMA so retrieval can
   filter/down-rank stale items (>14 days unverified) per your freshness convention.

SQLite schema:

```sql
CREATE TABLE chunks (
  id           INTEGER PRIMARY KEY,
  chunk_uid    TEXT UNIQUE,      -- stable: "<path>#<section-slug>"
  path         TEXT,             -- repo-relative
  title        TEXT,             -- frontmatter title
  section      TEXT,             -- H2/H3 heading
  type         TEXT, status TEXT, source TEXT, confidence TEXT,
  tags         TEXT,             -- JSON array
  added        TEXT, last_verified TEXT,
  content      TEXT,
  content_hash TEXT,             -- for incremental reindex
  commit_sha   TEXT,
  token_count  INTEGER
);
CREATE VIRTUAL TABLE vec_chunks USING vec0(embedding float[384]);   -- rowid = chunks.id
CREATE VIRTUAL TABLE fts_chunks USING fts5(                          -- external content
  title, section, content, tags, content='chunks', content_rowid='id'
);
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);   -- index_commit, model, revision, built_at, chunk_count
```

## API contract

All endpoints except `/health` require `Authorization: Bearer <KB_API_KEY>`.

**REST**

```
POST /v1/search
  { "query": "how do agents get just-in-time access",
    "top_k": 8,
    "mode": "hybrid|vector|keyword",      // default hybrid
    "filters": { "type": ["research"], "tags": ["agents"],
                 "min_confidence": "medium", "max_age_days": 30 } }
→ [ { "chunk_uid", "path", "title", "section", "score",
      "snippet", "type", "tags", "confidence", "last_verified" }, ... ]

GET  /v1/doc?chunk_uid=ai-tools.md%23github-spec-kit   # or ?path=...  → full chunk/file
GET  /v1/stats     → { index_commit, model, revision, built_at, chunk_count, doc_count }
GET  /health       → 200 (no auth) — used by the provisioning health poll
```

**MCP** (`/mcp`, streamable HTTP) — same capabilities as tools:

- `kb_search(query, top_k?, mode?, type?, tags?, min_confidence?, max_age_days?)`
- `kb_get(chunk_uid | path)`
- `kb_stats()`

Returned rows include `last_verified` so an agent can decide whether to trust or re-verify a
changeable fact before acting on it.

## Sync / reindex

- **Access:** read-only GitHub **deploy key** for `marchah/CognitiveStack`. Pushed to the
  container as a mode-600 file using the same secret-handling idiom as `hermes` (never through
  argv/env). `GIT_SSH_COMMAND` pins the key + `StrictHostKeyChecking=accept-new`.
- **Trigger:** `kb-reindex.timer` (OnBootSec + `OnUnitActiveSec=10min`) runs `kb-reindex`,
  which `git pull`s and reindexes **only if `HEAD` changed**. `meta.index_commit` stamps which
  commit the live index was built from (surfaced via `/v1/stats`).
- **Incremental:** chunk `content_hash` diff → only changed chunks are re-embedded; deletions
  prune rows whose `chunk_uid` no longer appears. Full rebuild on model/revision change.
- **Manual:** `kb-reindex` (immediate) and `kb-reindex --full` (from scratch).

## Provisioning script (`create-lxc-kb-rag.sh`)

Follows the repo idiom exactly: top-of-file `readonly`/env-default config → `die`/`log`/
`require_root`/`require_command` → `main()` ordered pipeline → heredoc `CONTAINER_SCRIPT`
pushed via `pct exec ... bash -s`.

Env-overridable config block:

```
VMID=140  LXC_HOSTNAME=kb-rag  TEMPLATE_STORAGE=local  ROOT_STORAGE=local-lvm
ROOT_SIZE_GB=12  MEMORY_MB=4096  SWAP_MB=1024  CORES=4  BRIDGE=vmbr0  IP_CONFIG=dhcp
START_ON_BOOT=1
KB_REPO_URL=git@github.com:marchah/CognitiveStack.git   KB_BRANCH=main
EMBED_MODEL=BAAI/bge-small-en-v1.5   EMBED_REVISION=<pinned>   EMBED_DIM=384
RERANK=0   RERANK_MODEL=BAAI/bge-reranker-v2-m3
API_PORT=8770   API_KEY=            # empty → auto-generate + print once (like hermes)
DEPLOY_KEY_FILE=                    # path to a read-only deploy private key (required)
REINDEX_INTERVAL=10min
# pinned python deps (versions pinned in the script, like hermes pins its installer):
#   fastapi uvicorn[standard] sqlite-vec fastembed pydantic pyyaml python-frontmatter
#   markdown-it-py httpx mcp
```

`main()` pipeline:

```
require_root → require_command pct/pveam/openssl → assert_vmid_available
→ resolve_template → download_template_if_missing → require_deploy_key
→ maybe_generate_api_key → create_container → start_container → wait_for_container
→ install_and_configure  (heredoc)  → print_summary
```

Inside `CONTAINER_SCRIPT`:

1. `apt-get install -y ca-certificates curl git python3 python3-venv python3-pip build-essential`
2. Read the pushed deploy key + API key from mode-600 files, install key to
   `/root/.ssh/kb-rag-deploy`, delete the provision copies.
3. Create `/opt/kb-rag/venv`; `pip install` the pinned deps.
4. Deploy app code (`server.py`, `reindex.py`, `chunker.py`, `store.py`) — see dual-mode note.
5. Write `index.config.yaml`, `/etc/kb-rag.env`, and the `kb-reindex` / `kb-stats` wrappers in
   `/usr/local/bin`.
6. `git clone` the KB repo to `/opt/kb-rag/data/repo`.
7. Run the initial `kb-reindex --full` (also pre-downloads the ONNX model into the cache).
8. Install systemd units, enable + start.
9. **Health poll** (~120s): `GET /health` then `GET /v1/stats` and assert `chunk_count > 0`.
   On timeout dump `systemctl status` + journal and `exit 1` (never print "Done" over a dead
   or empty index) — same guard as hermes.

⚠️ **Dual-mode install gotcha** (mirror `bench-runner`): the script installs `kb-rag/app/`
two ways — (a) local checkout present → tar `app/` + configs and `pct push`; (b) standalone
`wget | bash` → curl each file from GitHub raw using a **hardcoded file list**. When you add
or rename a file under `kb-rag/app/`, you MUST also add it to that `files=(…)` array or the
standalone path ships an incomplete service.

systemd units:

```
kb-rag.service      Type=simple  EnvironmentFile=/etc/kb-rag.env
                    ExecStart=/opt/kb-rag/venv/bin/uvicorn app.server:app --host 0.0.0.0 --port ${API_PORT}
                    Restart=on-failure  RestartSec=10
kb-reindex.service  Type=oneshot  ExecStart=/usr/local/bin/kb-reindex
kb-reindex.timer    OnBootSec=2min  OnUnitActiveSec=${REINDEX_INTERVAL}
```

## Security

- **Bearer key mandatory** on all data endpoints even on the LAN (auto-generated, printed once,
  stored mode-600 in `/etc/kb-rag.env`). Lower blast radius than Hermes (read-only knowledge,
  no terminal), but still gated.
- **Read-only deploy key** — the container can only *pull* the KB, never push.
- **Secrets never in argv/env** — deploy key + API key pushed as mode-600 files, read with
  `cat`, deleted; host copies removed immediately (the hermes idiom).
- **Network scope:** internal NAT (`10.10.10.0/24`); agents reach it by hostname. No nft
  port-forward by default. Add one (like the `:9119` dashboard forward) only if you want to
  query it from the wider LAN.

## Operations & consumption

```bash
# On the Proxmox host
pct exec 140 -- kb-reindex            # pull + reindex now
pct exec 140 -- kb-reindex --full     # rebuild from scratch (after a model change)
pct exec 140 -- kb-stats              # index commit, model, chunk count

# From any agent container (curl)
curl -s http://kb-rag:8770/v1/search -H "Authorization: Bearer $KB_API_KEY" \
  -H 'content-type: application/json' \
  -d '{"query":"just in time agent access","top_k":5}' | jq .

# Hermes (CT 121): register the MCP server so the agent gets kb_search/kb_get/kb_stats
#   base_url: http://kb-rag:8770/mcp   auth: Bearer <KB_API_KEY>
```

**Fallback:** if `kb-rag` is down, agents can still `git clone`/grep the CognitiveStack repo —
retrieval degrades, it doesn't disappear. Don't make this a hard dependency for any agent's
core loop.

## Repo layout (to be created under `kb-rag/`)

```
kb-rag/
  SPEC.md                     # this file
  README.md                   # usage + overrides (to follow, hermes-style)
  create-lxc-kb-rag.sh        # provisioning script (to follow)
  app/
    chunker.py                # markdown → chunks + metadata + freshness
    config.py                 # index.config.yaml + env overrides
    embedder.py               # fastembed (CPU); KB_FAKE_EMBED=1 for plumbing tests
    store.py                  # sqlite-vec + FTS5 + RRF (+ optional rerank)
    reindex.py                # git pull + orchestrate chunk/embed/upsert
    server.py                 # FastAPI: REST + MCP-over-HTTP
    index.config.yaml         # include/exclude globs, model, defaults
```

## Open decisions (confirm before the script is written)

1. **VMID / placement** — `140` (databases range; recommended) vs `122` (AI range).
2. **Embedding model** — `bge-small-en-v1.5` (fast, 384d; recommended) vs `bge-m3`
   (multilingual, 1024d, ~2 GB, better recall).
3. **Reranker** — off (lean; recommended) vs on.
4. **Extra exclude** — confirm `claude-gpu-recommendation.md` is excluded (personal), alongside
   the meta/nav files.

## Milestones

1. App code (`chunker` → `store` → `reindex` → `server`) validated locally against a
   CognitiveStack checkout (no container).
2. `create-lxc-kb-rag.sh` provisions CT 140; health poll green; `/v1/stats` shows chunks.
3. Wire Hermes to the MCP endpoint; confirm `kb_search` returns from the agent.
4. (Later) split the catalog megafiles for cleaner chunks + `related:` links; add `jobs/` as a
   second namespace if wanted.
```
