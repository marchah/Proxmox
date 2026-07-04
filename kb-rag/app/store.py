"""SQLite-backed hybrid store: sqlite-vec (vector KNN) + FTS5 (BM25), fused with RRF.

One ``kb.sqlite`` file holds everything — a ``chunks`` metadata table, a ``vec_chunks``
vector index (``vec0``, rowid == chunks.id), a standalone ``fts_chunks`` FTS5 index
(rowid == chunks.id), and a ``meta`` key/value table. No server; concurrent reads are fine.

Search runs BM25 and vector KNN independently, merges their rank lists with Reciprocal
Rank Fusion (RRF), then applies metadata filters (type / tags / confidence / freshness).
Hybrid beats pure-vector on this structured corpus: vectors add recall, BM25 + filters
supply precision.
"""

from __future__ import annotations

import datetime as _dt
import json
import re
import sqlite3

import sqlite_vec

from chunker import Chunk

_RRF_K = 60
_CANDIDATES = 100  # per source (vector, keyword) before fusion + filtering
_CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2}


def _confidence_rank(value: str) -> int:
    return _CONFIDENCE_RANK.get((value or "").strip().lower(), 0)


def _fts_query(text: str) -> str:
    """Turn free text into a safe FTS5 MATCH string: quoted tokens OR'd for recall."""
    tokens = [t for t in re.findall(r"[A-Za-z0-9]+", text) if len(t) >= 2]
    return " OR ".join(f'"{t}"' for t in tokens)


def _rrf(rank_lists: list[list[int]], k: int = _RRF_K) -> list[tuple[int, float]]:
    scores: dict[int, float] = {}
    for rl in rank_lists:
        for rank, cid in enumerate(rl):
            scores[cid] = scores.get(cid, 0.0) + 1.0 / (k + rank + 1)
    return sorted(scores.items(), key=lambda kv: kv[1], reverse=True)


class Store:
    def __init__(self, db_path: str, dim: int):
        self.dim = dim
        # check_same_thread=False: the FastAPI server runs sync handlers in a threadpool
        # sharing this connection for reads (SQLite serialized mode + WAL make that safe).
        self.conn = sqlite3.connect(db_path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.enable_load_extension(True)
        sqlite_vec.load(self.conn)
        self.conn.enable_load_extension(False)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self._create_schema()

    # --- schema -----------------------------------------------------------
    def _create_schema(self) -> None:
        c = self.conn
        c.execute(
            """
            CREATE TABLE IF NOT EXISTS chunks (
                id            INTEGER PRIMARY KEY,
                chunk_uid     TEXT UNIQUE,
                path          TEXT,
                title         TEXT,
                section       TEXT,
                type          TEXT,
                status        TEXT,
                source        TEXT,
                confidence    TEXT,
                tags          TEXT,
                added         TEXT,
                last_verified TEXT,
                content       TEXT,
                content_hash  TEXT,
                token_count   INTEGER
            )
            """
        )
        c.execute(
            f"CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(embedding float[{self.dim}])"
        )
        c.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_chunks USING fts5(
                chunk_uid UNINDEXED, title, section, content, tags
            )
            """
        )
        c.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
        c.execute("CREATE INDEX IF NOT EXISTS idx_chunks_path ON chunks(path)")
        self.conn.commit()

    def drop_all(self) -> None:
        """Full-rebuild path (e.g. after an embedding-model / dimension change)."""
        for tbl in ("chunks", "vec_chunks", "fts_chunks", "meta"):
            self.conn.execute(f"DROP TABLE IF EXISTS {tbl}")
        self.conn.commit()
        self._create_schema()

    # --- writes -----------------------------------------------------------
    def get_hashes(self) -> dict[str, str]:
        rows = self.conn.execute("SELECT chunk_uid, content_hash FROM chunks").fetchall()
        return {r["chunk_uid"]: r["content_hash"] for r in rows}

    def upsert(self, chunk: Chunk, embedding: list[float]) -> None:
        c = self.conn
        emb = sqlite_vec.serialize_float32(embedding)
        tags_json = json.dumps(chunk.tags)
        row = c.execute(
            "SELECT id FROM chunks WHERE chunk_uid = ?", (chunk.chunk_uid,)
        ).fetchone()
        cols = (
            chunk.path, chunk.title, chunk.section, chunk.type, chunk.status,
            chunk.source, chunk.confidence, tags_json, chunk.added,
            chunk.last_verified, chunk.content, chunk.content_hash, chunk.token_count,
        )
        if row:
            cid = row["id"]
            c.execute(
                """UPDATE chunks SET path=?, title=?, section=?, type=?, status=?,
                   source=?, confidence=?, tags=?, added=?, last_verified=?, content=?,
                   content_hash=?, token_count=? WHERE id=?""",
                (*cols, cid),
            )
            c.execute("DELETE FROM vec_chunks WHERE rowid=?", (cid,))
            c.execute("DELETE FROM fts_chunks WHERE rowid=?", (cid,))
        else:
            cur = c.execute(
                """INSERT INTO chunks (chunk_uid, path, title, section, type, status,
                   source, confidence, tags, added, last_verified, content, content_hash,
                   token_count) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (chunk.chunk_uid, *cols),
            )
            cid = cur.lastrowid
        c.execute("INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?)", (cid, emb))
        c.execute(
            "INSERT INTO fts_chunks(rowid, chunk_uid, title, section, content, tags) "
            "VALUES (?,?,?,?,?,?)",
            (cid, chunk.chunk_uid, chunk.title, chunk.section, chunk.content,
             " ".join(chunk.tags)),
        )

    def prune(self, keep_uids: set[str]) -> int:
        rows = self.conn.execute("SELECT id, chunk_uid FROM chunks").fetchall()
        removed = 0
        for r in rows:
            if r["chunk_uid"] not in keep_uids:
                cid = r["id"]
                self.conn.execute("DELETE FROM chunks WHERE id=?", (cid,))
                self.conn.execute("DELETE FROM vec_chunks WHERE rowid=?", (cid,))
                self.conn.execute("DELETE FROM fts_chunks WHERE rowid=?", (cid,))
                removed += 1
        return removed

    def commit(self) -> None:
        self.conn.commit()

    def set_meta(self, **kv: str) -> None:
        for k, v in kv.items():
            self.conn.execute(
                "INSERT INTO meta(key, value) VALUES(?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (k, str(v)),
            )
        self.conn.commit()

    # --- reads ------------------------------------------------------------
    def get_meta(self) -> dict:
        rows = self.conn.execute("SELECT key, value FROM meta").fetchall()
        return {r["key"]: r["value"] for r in rows}

    def stats(self) -> dict:
        chunk_count = self.conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        doc_count = self.conn.execute(
            "SELECT COUNT(DISTINCT path) FROM chunks"
        ).fetchone()[0]
        return {"chunk_count": chunk_count, "doc_count": doc_count, **self.get_meta()}

    def _vector_ids(self, embedding: list[float], limit: int) -> list[int]:
        emb = sqlite_vec.serialize_float32(embedding)
        # Use the `k = ?` KNN form, not `LIMIT ?`: on older SQLite (Debian 12) a bound LIMIT
        # isn't propagated to the vec0 vtable, which then errors ("a LIMIT or 'k = ?' ...").
        rows = self.conn.execute(
            "SELECT rowid FROM vec_chunks WHERE embedding MATCH ? AND k = ? "
            "ORDER BY distance",
            (emb, limit),
        ).fetchall()
        return [r["rowid"] for r in rows]

    def _keyword_ids(self, query: str, limit: int) -> list[int]:
        match = _fts_query(query)
        if not match:
            return []
        try:
            rows = self.conn.execute(
                "SELECT rowid FROM fts_chunks WHERE fts_chunks MATCH ? "
                "ORDER BY bm25(fts_chunks) LIMIT ?",
                (match, limit),
            ).fetchall()
        except sqlite3.OperationalError:
            return []
        return [r["rowid"] for r in rows]

    def _passes(self, row: sqlite3.Row, filters: dict) -> bool:
        if not filters:
            return True
        types = filters.get("type")
        if types and row["type"] not in types:
            return False
        want_tags = filters.get("tags")
        if want_tags:
            have = set(json.loads(row["tags"] or "[]"))
            if not have.intersection(want_tags):
                return False
        min_conf = filters.get("min_confidence")
        if min_conf and _confidence_rank(row["confidence"]) < _confidence_rank(min_conf):
            return False
        max_age = filters.get("max_age_days")
        if max_age and row["last_verified"]:
            try:
                lv = _dt.date.fromisoformat(row["last_verified"])
                if (_dt.date.today() - lv).days > int(max_age):
                    return False
            except ValueError:
                pass  # unparseable date -> don't filter it out
        return True

    def search(
        self,
        embedding: list[float] | None,
        query: str,
        top_k: int = 8,
        mode: str = "hybrid",
        filters: dict | None = None,
    ) -> list[dict]:
        filters = filters or {}
        rank_lists: list[list[int]] = []
        if mode in ("hybrid", "vector") and embedding is not None:
            rank_lists.append(self._vector_ids(embedding, _CANDIDATES))
        if mode in ("hybrid", "keyword"):
            rank_lists.append(self._keyword_ids(query, _CANDIDATES))
        if not rank_lists:
            return []

        fused = _rrf(rank_lists)
        results: list[dict] = []
        for cid, score in fused:
            row = self.conn.execute(
                "SELECT * FROM chunks WHERE id=?", (cid,)
            ).fetchone()
            if row is None or not self._passes(row, filters):
                continue
            results.append(self._row_to_result(row, score))
            if len(results) >= top_k:
                break
        return results

    def get(self, chunk_uid: str | None = None, path: str | None = None):
        if chunk_uid:
            row = self.conn.execute(
                "SELECT * FROM chunks WHERE chunk_uid=?", (chunk_uid,)
            ).fetchone()
            return self._row_to_full(row) if row else None
        if path:
            rows = self.conn.execute(
                "SELECT * FROM chunks WHERE path=? ORDER BY id", (path,)
            ).fetchall()
            return [self._row_to_full(r) for r in rows]
        return None

    @staticmethod
    def _snippet(content: str, limit: int = 320) -> str:
        s = " ".join((content or "").split())
        return s[:limit] + ("…" if len(s) > limit else "")

    def _row_to_result(self, row: sqlite3.Row, score: float) -> dict:
        return {
            "chunk_uid": row["chunk_uid"],
            "path": row["path"],
            "title": row["title"],
            "section": row["section"],
            "score": round(score, 6),
            "snippet": self._snippet(row["content"]),
            "type": row["type"],
            "tags": json.loads(row["tags"] or "[]"),
            "confidence": row["confidence"],
            "last_verified": row["last_verified"],
            "added": row["added"],
        }

    def _row_to_full(self, row: sqlite3.Row) -> dict:
        d = self._row_to_result(row, 0.0)
        d.pop("score", None)
        d["content"] = row["content"]
        return d

    def close(self) -> None:
        self.conn.close()
