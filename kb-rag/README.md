# kb-rag — knowledge-base retrieval service (CT 140)

An unprivileged Debian LXC that indexes the **CognitiveStack** Markdown knowledge base and
serves hybrid (keyword + semantic) search to every agent on the server over one endpoint —
REST **and** MCP-over-HTTP. See [`SPEC.md`](SPEC.md) for the full design and rationale.

**Markdown-in-git stays the source of truth.** This container holds only a derived,
rebuildable index (`sqlite-vec` + FTS5); the rootfs is `backup=0` and a wipe + reindex
reconstructs everything. Embeddings run on **CPU** (`fastembed`/ONNX) — no GPU, no load on
CT 120.

## Provision (on the Proxmox host, as root)

A **read-only deploy key** for the KB repo is required:

```bash
# 1. Make a deploy key and add the .pub as a read-only Deploy Key on the CognitiveStack repo
#    (GitHub -> repo Settings -> Deploy keys -> Add, leave "Allow write access" OFF).
ssh-keygen -t ed25519 -f ./cognitivestack-deploy -N ''

# 2. Provision (auto-generates + prints the API bearer key once)
DEPLOY_KEY_FILE=./cognitivestack-deploy ./kb-rag/create-lxc-kb-rag.sh
```

The script resolves a Debian 12 template, creates CT 140, installs a venv with pinned deps,
ships `app/`, clones the KB, builds the initial index (warming the ONNX model cache), installs
the systemd service + reindex timer, and **health-polls** until the API answers with a
non-empty index (else it dumps the journal and exits non-zero).

### Useful overrides

```bash
VMID=140 LXC_HOSTNAME=kb-rag ./kb-rag/create-lxc-kb-rag.sh
KB_REPO_URL=git@github.com:you/KB.git KB_BRANCH=main ...     # a different KB
EMBED_MODEL=BAAI/bge-m3 EMBED_DIM=1024 MEMORY_MB=8192 ...    # stronger recall (bigger model)
API_KEY=my-secret ...                                        # else auto-generated + printed
API_PORT=8770 REINDEX_INTERVAL=10min ...
```

Changing `EMBED_MODEL`/`EMBED_DIM` later requires a full rebuild (`kb-reindex --full`) — the
vector dimension must match the stored index.

## Operate

```bash
pct exec 140 -- kb-reindex          # git pull + incremental reindex now
pct exec 140 -- kb-reindex --full   # drop + rebuild (after a model change)
pct exec 140 -- kb-stats            # index commit, embed model, chunk/doc counts
pct exec 140 -- systemctl status kb-rag
pct exec 140 -- journalctl -u kb-rag -n 100 --no-pager
pct exec 140 -- systemctl list-timers kb-reindex.timer
```

A `kb-reindex.timer` pulls + reindexes every 10 min; reindex is incremental (only chunks whose
content hash changed are re-embedded) and stamps the source commit into the index.

## Consume

### REST

```bash
KEY=<bearer key from provisioning>
curl -s http://kb-rag:8770/v1/search -H "Authorization: Bearer $KEY" \
  -H 'content-type: application/json' \
  -d '{"query":"just in time agent access","top_k":5,
       "mode":"hybrid","filters":{"tags":["agents"],"max_age_days":30}}' | jq .

curl -s "http://kb-rag:8770/v1/doc?chunk_uid=ai-tools.md%23github-spec-kit" -H "Authorization: Bearer $KEY"
curl -s http://kb-rag:8770/v1/stats -H "Authorization: Bearer $KEY"
curl -s http://kb-rag:8770/health   # no auth
```

- `mode`: `hybrid` (default) | `vector` | `keyword`
- `filters`: `type` (list), `tags` (list, any-match), `min_confidence` (`low`/`medium`/`high`),
  `max_age_days` (drops entries whose `last_verified` is older)
- results carry `path`, `section`, `score`, `snippet`, `type`, `tags`, `confidence`,
  `last_verified` — enough for an agent to decide whether to open the full item.

### MCP (agents)

Register `http://kb-rag:8770/mcp/` (trailing slash — `/mcp` 307-redirects to it) as a
streamable-HTTP MCP server, header `Authorization: Bearer <key>`. Tools: `kb_search`, `kb_get`,
`kb_stats`.

## Layout

```
kb-rag/
  SPEC.md               # design doc
  README.md             # this file
  create-lxc-kb-rag.sh  # provisioning (run on the Proxmox host)
  app/
    chunker.py          # markdown -> chunks + metadata + freshness
    config.py           # index.config.yaml + env overrides
    embedder.py         # fastembed (CPU); KB_FAKE_EMBED=1 for dep-free plumbing tests
    store.py            # sqlite-vec + FTS5 + RRF hybrid search
    reindex.py          # kb-reindex CLI (git pull + incremental embed/upsert/prune)
    server.py           # FastAPI: REST + MCP-over-HTTP
    index.config.yaml   # corpus include/exclude globs, model, defaults
```

⚠️ When adding/renaming a file under `app/`, also update the `APP_FILES=(…)` array in
`create-lxc-kb-rag.sh` — the standalone (`wget | bash`) install path downloads exactly that list.

## Corpus policy

Glob-driven in `app/index.config.yaml` (gitignore-style; a file is indexed if it matches
`include` and not `exclude`). The KB stores knowledge as per-item files in topic folders
(`ai-tools/`, `mcp/`, …) with all personal/non-knowledge content under `personal/`, so the
policy is `include: ["**/*.md"]` and `exclude: ["personal/**", "**/README.md", "INDEX.md",
"SCHEMA.md", "AGENT_GUIDE.md"]`. Adding a new item file or topic folder indexes it
automatically on the next reindex.

## Notes

- Local dev: index a checkout without a container —
  `KB_REPO_DIR=~/workspace/CognitiveStack KB_DB_PATH=/tmp/kb.sqlite python app/reindex.py --no-git`.
- If the service is down, agents can still `git clone`/grep the KB — retrieval degrades, it
  doesn't disappear. Don't make it a hard dependency for an agent's core loop.
