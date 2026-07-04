"""Load ``index.config.yaml`` with env overrides.

Process env wins over the file (so a systemd EnvironmentFile / per-run override takes
effect), matching the layered-config idiom used elsewhere in this repo.
"""

from __future__ import annotations

import os

import yaml

_HERE = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_CONFIG = os.path.join(_HERE, "index.config.yaml")

_DEFAULTS = {
    "repo_url": "git@github.com:marchah/CognitiveStack.git",
    "branch": "main",
    "repo_dir": "/opt/kb-rag/data/repo",
    "db_path": "/opt/kb-rag/data/kb.sqlite",
    "embed_model": "BAAI/bge-small-en-v1.5",
    "embed_dim": 384,
    # onnxruntime intra-op threads — set explicitly so it doesn't size to the host core count
    # and try to pin threads outside the LXC cpuset. Keep small; embedding is a background job.
    "embed_threads": 2,
    # Embedding batch size — bounds peak memory (attention tensors scale with it at seq 512);
    # the fastembed default (256) OOMs a small LXC.
    "embed_batch_size": 32,
    # bge-* retrieval asymmetry: queries get an instruction prefix, passages do not.
    "query_prefix": "Represent this sentence for searching relevant passages: ",
    "include": ["*.md"],
    "exclude": [],
    "defaults": {"top_k": 8, "mode": "hybrid"},
}

# env var -> (config key, caster)
_ENV = {
    "KB_REPO_URL": ("repo_url", str),
    "KB_BRANCH": ("branch", str),
    "KB_REPO_DIR": ("repo_dir", str),
    "KB_DB_PATH": ("db_path", str),
    "KB_EMBED_MODEL": ("embed_model", str),
    "KB_EMBED_DIM": ("embed_dim", int),
    "KB_EMBED_THREADS": ("embed_threads", int),
    "KB_EMBED_BATCH_SIZE": ("embed_batch_size", int),
    "KB_QUERY_PREFIX": ("query_prefix", str),
}


def load_config(path: str | None = None) -> dict:
    path = path or os.environ.get("KB_CONFIG") or _DEFAULT_CONFIG
    cfg = dict(_DEFAULTS)
    try:
        with open(path, encoding="utf-8") as f:
            loaded = yaml.safe_load(f) or {}
        cfg.update({k: v for k, v in loaded.items() if v is not None})
    except FileNotFoundError:
        pass  # defaults + env are enough to run

    for env_key, (cfg_key, cast) in _ENV.items():
        raw = os.environ.get(env_key)
        if raw:
            cfg[cfg_key] = cast(raw)

    cfg["embed_dim"] = int(cfg["embed_dim"])
    cfg["embed_threads"] = int(cfg["embed_threads"])
    cfg["embed_batch_size"] = int(cfg["embed_batch_size"])
    cfg.setdefault("defaults", {})
    return cfg
