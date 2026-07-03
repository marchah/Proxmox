#!/usr/bin/env python3
"""Reindex the knowledge base into the hybrid store.

``kb-reindex``          -> git pull (if a checkout), incremental reindex (only changed chunks).
``kb-reindex --full``   -> drop + rebuild (use after an embedding-model / dimension change).
``kb-reindex --no-git`` -> index whatever is on disk without touching git (local dev).

Incremental diffing is by ``content_hash``, so routine reindexes only re-embed what changed.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import os
import subprocess
import sys

import pathspec

from chunker import chunk_markdown
from config import load_config
from embedder import Embedder
from store import Store


def _git(repo_dir: str, *args: str) -> str:
    out = subprocess.run(
        ["git", "-C", repo_dir, *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return out.stdout.strip()


def _sync_repo(cfg: dict) -> None:
    repo = cfg["repo_dir"]
    if os.path.isdir(os.path.join(repo, ".git")):
        _git(repo, "pull", "--ff-only")
    else:
        os.makedirs(os.path.dirname(repo) or ".", exist_ok=True)
        subprocess.run(
            ["git", "clone", "--branch", cfg["branch"], cfg["repo_url"], repo],
            check=True,
        )


def _iter_md(repo_dir: str, inc: pathspec.PathSpec, exc: pathspec.PathSpec):
    for root, dirs, files in os.walk(repo_dir):
        if ".git" in dirs:
            dirs.remove(".git")
        for fn in files:
            if not fn.endswith(".md"):
                continue
            full = os.path.join(root, fn)
            rel = os.path.relpath(full, repo_dir).replace(os.sep, "/")
            if inc.match_file(rel) and not exc.match_file(rel):
                yield rel, full


def run(full: bool = False, no_git: bool = False, config_path: str | None = None) -> dict:
    cfg = load_config(config_path)
    repo = cfg["repo_dir"]

    if not no_git:
        _sync_repo(cfg)
    commit = "unknown"
    if os.path.isdir(os.path.join(repo, ".git")):
        commit = _git(repo, "rev-parse", "HEAD")

    inc = pathspec.PathSpec.from_lines("gitwildmatch", cfg["include"])
    exc = pathspec.PathSpec.from_lines("gitwildmatch", cfg["exclude"])

    chunks = []
    for rel, full_path in _iter_md(repo, inc, exc):
        with open(full_path, encoding="utf-8") as f:
            chunks.extend(chunk_markdown(rel, f.read()))

    embedder = Embedder(cfg["embed_model"], cfg["embed_dim"], cfg["query_prefix"])
    store = Store(cfg["db_path"], cfg["embed_dim"])
    if full:
        store.drop_all()

    existing = store.get_hashes()
    keep = {c.chunk_uid for c in chunks}
    changed = [c for c in chunks if existing.get(c.chunk_uid) != c.content_hash]

    if changed:
        vectors = embedder.embed_documents([c.embed_text() for c in changed])
        for chunk, vec in zip(changed, vectors):
            store.upsert(chunk, vec)
    removed = store.prune(keep)

    store.set_meta(
        index_commit=commit,
        embed_model=cfg["embed_model"],
        embed_dim=cfg["embed_dim"],
        built_at=_dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
    )
    store.commit()
    stats = store.stats()
    store.close()

    summary = {
        "files": len({c.path for c in chunks}),
        "chunks": len(chunks),
        "changed": len(changed),
        "pruned": removed,
        "commit": commit,
        "total": stats["chunk_count"],
    }
    print(
        f"reindex: {summary['files']} files, {summary['chunks']} chunks, "
        f"{summary['changed']} changed, {summary['pruned']} pruned, "
        f"commit {commit[:8]}, total {summary['total']}"
    )
    return summary


def main() -> int:
    ap = argparse.ArgumentParser(description="Reindex the knowledge base.")
    ap.add_argument("--full", action="store_true", help="drop + rebuild from scratch")
    ap.add_argument("--no-git", action="store_true", help="index on-disk files, skip git")
    ap.add_argument("--config", help="path to index.config.yaml")
    args = ap.parse_args()
    try:
        run(full=args.full, no_git=args.no_git, config_path=args.config)
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(f"git failed: {exc.stderr or exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
