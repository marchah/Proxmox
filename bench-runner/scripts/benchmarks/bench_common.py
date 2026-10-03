#!/usr/bin/env python3
"""Shared helpers for the benchmarks: a real-text corpus and llama-server calls.

The corpus is this repository's own text at a pinned commit, so every run sends the
same words. It is built on first use from the commit's GitHub archive and cached under
cache/. Run this file directly to build it ahead of time, or from a local archive:

  python3 scripts/benchmarks/bench_common.py
  git archive --format=tar.gz <commit> | python3 scripts/benchmarks/bench_common.py --source -

It produces two texts, each file behind a "===== FILE: <path> =====" line, sorted by path:

  docs  every *.md file
  code  every *.sh, *.py and *.md file

BENCHMARK_CORPUS_DIR points at another directory holding docs.txt and code.txt; such a
corpus is used as is, and its checksums go into the results.
"""

from __future__ import annotations

import argparse
import functools
import hashlib
import io
import json
import os
import statistics
import sys
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

PROJECT_DIR = Path(__file__).resolve().parents[2]
CORPUS_REPO = "marchah/Proxmox"
CORPUS_COMMIT = "f7e762c53388be0ba06751dd210aacef3e30b7c5"
CORPUS_SUFFIXES = {"docs": (".md",), "code": (".sh", ".py", ".md")}
CORPUS_SHA256 = {
    "docs": "3487eaabf6a1832154fe30c06119a1d00f76d4a25f0f6f0bcc7151770c46cb8b",
    "code": "26d5030f936c08f07eb8fbee83f508d8c5a387125a491d06ba55ecc424cd4df3",
}
FILE_MARKER = "===== FILE: {path} =====\n"

# Errors a request to the model server can raise. HTTPError is a URLError.
REQUEST_ERRORS = (urllib.error.URLError, TimeoutError, ConnectionError, ValueError)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def corpus_dir() -> Path:
    override = os.environ.get("BENCHMARK_CORPUS_DIR")
    if override:
        return Path(override)
    return PROJECT_DIR / "cache" / f"corpus-{CORPUS_COMMIT[:12]}"


def archive_url() -> str:
    return f"https://github.com/{CORPUS_REPO}/archive/{CORPUS_COMMIT}.tar.gz"


def build_corpus(out_dir: Path, source: str | None = None) -> dict[str, str]:
    """Write docs.txt and code.txt from a tar archive of the repository; return their sha256."""
    if source == "-":
        data = sys.stdin.buffer.read()
    elif source:
        data = Path(source).read_bytes()
    else:
        with urllib.request.urlopen(archive_url(), timeout=120) as response:
            data = response.read()

    files: dict[str, bytes] = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tar:
        members = [member for member in tar.getmembers() if member.isfile()]
        names = [member.name.removeprefix("./") for member in members]
        # GitHub's archive nests everything under "<repo>-<commit>/"; git archive does not.
        nested = all("/" in name for name in names) and len({name.split("/", 1)[0] for name in names}) == 1
        for member, name in zip(members, names):
            path = name.split("/", 1)[1] if nested else name
            if path.endswith(CORPUS_SUFFIXES["code"]):
                handle = tar.extractfile(member)
                if handle is not None:
                    files[path] = handle.read()

    out_dir.mkdir(parents=True, exist_ok=True)
    digests = {}
    for kind, suffixes in CORPUS_SUFFIXES.items():
        text = "".join(
            FILE_MARKER.format(path=path) + files[path].decode("utf-8", errors="replace") + "\n"
            for path in sorted(files)
            if path.endswith(suffixes)
        )
        partial = out_dir / f".{kind}.txt.partial"
        partial.write_text(text, encoding="utf-8")
        partial.replace(out_dir / f"{kind}.txt")
        digests[kind] = sha256_text(text)
    return digests


@functools.lru_cache(maxsize=None)
def corpus(kind: str) -> str:
    directory = corpus_dir()
    path = directory / f"{kind}.txt"
    pinned = not os.environ.get("BENCHMARK_CORPUS_DIR")
    if not path.exists():
        if not pinned:
            raise SystemExit(f"Corpus file missing: {path}")
        sys.stderr.write(f"Building the benchmark corpus from {archive_url()}\n")
        build_corpus(directory)
    text = path.read_text(encoding="utf-8")
    if pinned and sha256_text(text) != CORPUS_SHA256[kind]:
        raise SystemExit(f"{path} does not match the pinned corpus. Delete {directory} to rebuild it.")
    return text


def long_text() -> str:
    """docs then code: enough text for any prompt length the benchmarks ask for."""
    return corpus("docs") + corpus("code")


def corpus_info(*kinds: str) -> dict[str, Any]:
    return {
        "commit": CORPUS_COMMIT,
        "dir": str(corpus_dir()),
        "sha256": {kind: sha256_text(corpus(kind)) for kind in kinds},
    }


def file_text(kind: str, path: str, chars: int) -> str:
    """`chars` characters of the corpus, starting with the content of `path`."""
    text = corpus(kind)
    marker = FILE_MARKER.format(path=path)
    start = text.find(marker)
    if start < 0:
        raise ValueError(f"{path} is not in the {kind} corpus")
    start += len(marker)
    return text[start:start + chars]


def server_root(base_url: str) -> str:
    root = base_url.rstrip("/")
    return root.removesuffix("/v1")


def post_json(url: str, body: dict[str, Any], timeout: float) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def chat(base_url: str, body: dict[str, Any], timeout: float) -> tuple[dict[str, Any], float]:
    """POST a chat completion; return the response and the seconds it took."""
    started = time.monotonic()
    response = post_json(base_url.rstrip("/") + "/chat/completions", body, timeout)
    return response, time.monotonic() - started


def http_error_text(exc: Exception) -> str:
    if isinstance(exc, urllib.error.HTTPError):
        body = exc.read().decode("utf-8", errors="replace")[-2000:]
        return f"HTTP {exc.code}: {body}"
    return f"{type(exc).__name__}: {exc}"


def server_props(base_url: str) -> dict[str, Any]:
    """Slot layout and build from llama-server's /props; empty for other servers."""
    try:
        with urllib.request.urlopen(server_root(base_url) + "/props", timeout=15) as response:
            props = json.loads(response.read().decode("utf-8"))
    except REQUEST_ERRORS:
        return {}
    return {
        "n_ctx_per_slot": (props.get("default_generation_settings") or {}).get("n_ctx"),
        "total_slots": props.get("total_slots"),
        "model_path": props.get("model_path"),
        "build_info": props.get("build_info"),
    }


def count_tokens(base_url: str, text: str) -> int | None:
    """Tokens in `text` by the server's own tokenizer, or None without llama-server's /tokenize."""
    try:
        return len(post_json(server_root(base_url) + "/tokenize", {"content": text}, 120)["tokens"])
    except (*REQUEST_ERRORS, KeyError, TypeError):
        return None


def take_tokens(base_url: str, text: str, n_tokens: int) -> str:
    """The longest prefix of `text` holding at most `n_tokens` tokens.

    Uses the server's tokenizer, so the same depth means the same token count on any
    model. Falls back to 4 characters per token without /tokenize.
    """
    if n_tokens <= 0:
        return ""
    total = count_tokens(base_url, text)
    if total is None:
        if n_tokens * 4 > len(text):
            raise ValueError(f"the corpus holds about {len(text) // 4} tokens; {n_tokens} requested")
        return text[:n_tokens * 4]
    if total <= n_tokens:
        raise ValueError(f"the corpus holds {total} tokens; {n_tokens} requested")
    # Interpolation search on the character cut; the count is close to linear in it.
    lo, lo_tokens, hi, hi_tokens = 0, 0, len(text), total
    tolerance = max(4, n_tokens // 1000)
    while hi - lo > 1 and n_tokens - lo_tokens > tolerance:
        guess = lo + int((hi - lo) * (n_tokens - lo_tokens) / max(1, hi_tokens - lo_tokens))
        guess = min(max(guess, lo + 1), hi - 1)
        tokens = count_tokens(base_url, text[:guess])
        if tokens is None:
            raise ValueError("/tokenize stopped answering")
        if tokens <= n_tokens:
            lo, lo_tokens = guess, tokens
        else:
            hi, hi_tokens = guess, tokens
    return text[:lo]


def is_garbage_output(text: str) -> bool:
    """Heuristic: a non-trivial response that is mostly '?' / replacement chars.

    The Vulkan cold-prefill cliff returns HTTP 200 with all-'?' output, which
    would otherwise count as a successful request and publish throughput for
    invalid output. Conservative — needs >50% bad chars on an 8+ char response —
    so normal text (including a trailing '?') is never flagged.
    """
    stripped = text.strip()
    if len(stripped) < 8:
        return False
    bad = sum(1 for ch in stripped if ch in "?�")
    return bad / len(stripped) > 0.5


def timing_fields(timings: dict[str, Any] | None) -> dict[str, Any]:
    """The llama-server `timings` fields a workload row records."""
    timings = timings or {}
    return {
        "prompt_n": timings.get("prompt_n"),
        "cache_n": timings.get("cache_n"),
        "prompt_ms": timings.get("prompt_ms"),
        "prompt_tps": timings.get("prompt_per_second"),
        "predicted_n": timings.get("predicted_n"),
        "predicted_ms": timings.get("predicted_ms"),
        "decode_tps": timings.get("predicted_per_second"),
        "draft_n": timings.get("draft_n"),
        "draft_accepted": timings.get("draft_n_accepted"),
    }


def spread(values: list[float]) -> dict[str, float | None]:
    values = [value for value in values if value is not None]
    if not values:
        return {"median": None, "min": None, "max": None}
    return {"median": statistics.median(values), "min": min(values), "max": max(values)}


def rate(tokens: list[int | None], milliseconds: list[float | None]) -> float | None:
    """Token-weighted rate: all tokens over all time, so a few large prefills are not
    outvoted by many small ones."""
    pairs = [(t, ms) for t, ms in zip(tokens, milliseconds) if t and ms]
    total_ms = sum(ms for _, ms in pairs)
    return sum(t for t, _ in pairs) / (total_ms / 1000) if total_ms else None


def acceptance(drafted: list[int | None], accepted: list[int | None]) -> float | None:
    total = sum(d or 0 for d in drafted)
    return sum(a or 0 for a in accepted) / total if total else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", help="tar(.gz) archive of the repository at the pinned commit; '-' reads stdin")
    parser.add_argument("--out", type=Path, default=None, help="output directory (default: the cache directory)")
    args = parser.parse_args()
    digests = build_corpus(args.out or corpus_dir(), args.source)
    print(json.dumps({"commit": CORPUS_COMMIT, "sha256": digests}, indent=2))
    mismatched = [kind for kind, digest in digests.items() if digest != CORPUS_SHA256[kind]]
    if mismatched:
        sys.stderr.write(f"Checksum differs from the pinned corpus: {', '.join(mismatched)}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
