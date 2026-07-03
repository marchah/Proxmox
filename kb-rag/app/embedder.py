"""CPU embeddings via fastembed (ONNX Runtime) — no torch, no GPU.

``KB_FAKE_EMBED=1`` swaps in a deterministic hash-based embedder for plumbing tests that
must not download a model. Fake vectors validate the chunk -> store -> search mechanics
(and keyword search) but NOT semantic ranking; use the real model to judge relevance.
"""

from __future__ import annotations

import hashlib
import math
import os


class Embedder:
    def __init__(
        self,
        model: str,
        dim: int,
        query_prefix: str = "",
        fake: bool | None = None,
    ):
        self.dim = dim
        self.query_prefix = query_prefix or ""
        self.fake = os.environ.get("KB_FAKE_EMBED") == "1" if fake is None else fake
        self._model = None
        if not self.fake:
            from fastembed import TextEmbedding

            self._model = TextEmbedding(model_name=model)

    def _fake_vec(self, text: str) -> list[float]:
        vals: list[float] = []
        i = 0
        while len(vals) < self.dim:
            digest = hashlib.sha256(f"{i}:{text}".encode("utf-8")).digest()
            vals.extend((b / 255.0) - 0.5 for b in digest)
            i += 1
        vals = vals[: self.dim]
        norm = math.sqrt(sum(v * v for v in vals)) or 1.0
        return [v / norm for v in vals]

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        if self.fake:
            return [self._fake_vec(t) for t in texts]
        return [list(map(float, v)) for v in self._model.embed(list(texts))]

    def embed_query(self, text: str) -> list[float]:
        if self.fake:
            return self._fake_vec(text)
        vec = next(iter(self._model.embed([self.query_prefix + text])))
        return list(map(float, vec))
