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
        threads: int | None = None,
        batch_size: int = 32,
        fake: bool | None = None,
    ):
        self.dim = dim
        self.query_prefix = query_prefix or ""
        # Small batches bound peak memory: at seq-len 512 the attention tensors scale with
        # batch_size, and the default (256) OOMs a small LXC. 32 keeps the peak well under 1 GB.
        self.batch_size = batch_size
        self.fake = os.environ.get("KB_FAKE_EMBED") == "1" if fake is None else fake
        self._model = None
        if not self.fake:
            # Cap OpenMP/BLAS threads BEFORE importing onnxruntime/numpy (they read these at
            # import). Without it they size to the HOST core count → excess threads + memory.
            if threads:
                for _var in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
                    os.environ.setdefault(_var, str(threads))
            from fastembed import TextEmbedding

            # threads=N sets onnxruntime intra_op_num_threads explicitly. In an LXC this is
            # essential: without it onnxruntime sizes its pool to the HOST core count and tries
            # to pin threads to cores outside the container's cpuset (pthread_setaffinity_np
            # errors). Setting it also disables that affinity attempt.
            self._model = TextEmbedding(model_name=model, threads=threads)

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
        # parallel default (None) = in-process, no data-parallel workers. Multiprocessing
        # (parallel=0 or >1) deadlocks in the LXC (fork-after-onnxruntime-threads via
        # forkserver). Memory is bounded instead by the onnxruntime `threads` limit.
        return [list(map(float, v)) for v in self._model.embed(list(texts), batch_size=self.batch_size)]

    def embed_query(self, text: str) -> list[float]:
        if self.fake:
            return self._fake_vec(text)
        vec = next(iter(self._model.embed([self.query_prefix + text])))
        return list(map(float, vec))
