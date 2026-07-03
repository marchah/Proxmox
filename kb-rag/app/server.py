"""kb-rag API: REST + MCP-over-HTTP from one FastAPI app.

REST (bearer auth on everything except /health):
    POST /v1/search   GET /v1/doc   GET /v1/stats   GET /health
MCP (streamable HTTP at /mcp): tools kb_search / kb_get / kb_stats.

Run from the app directory:  uvicorn server:app --host 0.0.0.0 --port 8770
(systemd sets WorkingDirectory=/opt/kb-rag/app so the bare module imports resolve.)
"""

from __future__ import annotations

import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from mcp.server.fastmcp import FastMCP
from pydantic import BaseModel

from config import load_config
from embedder import Embedder
from store import Store

CFG = load_config()
API_KEY = os.environ.get("KB_API_KEY", "")
_VALID_MODES = ("hybrid", "vector", "keyword")

_store: Store | None = None
_embedder: Embedder | None = None


def store() -> Store:
    global _store
    if _store is None:
        _store = Store(CFG["db_path"], CFG["embed_dim"])
    return _store


def embedder() -> Embedder:
    global _embedder
    if _embedder is None:
        _embedder = Embedder(CFG["embed_model"], CFG["embed_dim"], CFG["query_prefix"])
    return _embedder


def _filters(type=None, tags=None, min_confidence=None, max_age_days=None) -> dict:
    return {
        k: v
        for k, v in {
            "type": type,
            "tags": tags,
            "min_confidence": min_confidence,
            "max_age_days": max_age_days,
        }.items()
        if v
    }


def do_search(query, top_k, mode, filters) -> list[dict]:
    mode = mode if mode in _VALID_MODES else "hybrid"
    emb = embedder().embed_query(query) if mode in ("hybrid", "vector") else None
    return store().search(emb, query, top_k=top_k, mode=mode, filters=filters)


# --- MCP ------------------------------------------------------------------
mcp = FastMCP("kb-rag", stateless_http=True)


@mcp.tool()
def kb_search(
    query: str,
    top_k: int = 8,
    mode: str = "hybrid",
    type: list[str] | None = None,
    tags: list[str] | None = None,
    min_confidence: str | None = None,
    max_age_days: int | None = None,
) -> list[dict]:
    """Hybrid (keyword+semantic) search over the knowledge base. Returns ranked chunks."""
    return do_search(query, top_k, mode, _filters(type, tags, min_confidence, max_age_days))


@mcp.tool()
def kb_get(chunk_uid: str | None = None, path: str | None = None):
    """Fetch full chunk content by chunk_uid, or all chunks of a file by path."""
    return store().get(chunk_uid=chunk_uid, path=path)


@mcp.tool()
def kb_stats() -> dict:
    """Index metadata: source commit, embed model, chunk/doc counts, build time."""
    return store().stats()


# --- REST -----------------------------------------------------------------
class SearchFilters(BaseModel):
    type: list[str] | None = None
    tags: list[str] | None = None
    min_confidence: str | None = None
    max_age_days: int | None = None


class SearchRequest(BaseModel):
    query: str
    top_k: int = 8
    mode: str = "hybrid"
    filters: SearchFilters | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    # FastMCP's streamable-HTTP transport needs its session manager running.
    async with mcp.session_manager.run():
        yield


app = FastAPI(title="kb-rag", lifespan=lifespan)


@app.middleware("http")
async def require_bearer(request, call_next):
    if API_KEY and request.url.path != "/health":
        if request.headers.get("authorization", "") != f"Bearer {API_KEY}":
            return JSONResponse({"detail": "unauthorized"}, status_code=401)
    return await call_next(request)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/v1/stats")
def v1_stats():
    return store().stats()


@app.post("/v1/search")
def v1_search(req: SearchRequest):
    f = req.filters.model_dump(exclude_none=True) if req.filters else {}
    return do_search(req.query, req.top_k, req.mode, f)


@app.get("/v1/doc")
def v1_doc(chunk_uid: str | None = None, path: str | None = None):
    if not chunk_uid and not path:
        raise HTTPException(status_code=400, detail="pass chunk_uid or path")
    result = store().get(chunk_uid=chunk_uid, path=path)
    if not result:
        raise HTTPException(status_code=404, detail="not found")
    return result


app.mount("/mcp", mcp.streamable_http_app())
