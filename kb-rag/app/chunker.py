"""Markdown -> retrieval chunks.

Splits each knowledge-base file into one chunk per ``## `` (H2) section — which maps a
catalog megafile (``ai-tools.md``: one H2 per tool) onto one chunk per item, while a
short one-concept pattern note (no H2) becomes a single chunk. Oversized sections are
sub-split on ``### `` (H3) then by paragraph windows.

Each chunk carries the file's frontmatter (title/type/status/tags/source/confidence)
plus the section heading and per-entry freshness (``Added:`` / ``Last verified:`` lines
in the catalog body, falling back to frontmatter ``created`` / ``last_verified``). This
is deliberately dependency-free (no PyYAML) so it can be unit-tested against a plain
checkout; the frontmatter in this repo is simple and regular.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import asdict, dataclass, field

# ~1000 tokens; sections larger than this are sub-split. Rough 4-chars/token heuristic.
MAX_CHUNK_TOKENS = 1000
_CHARS_PER_TOKEN = 4

_DATE_RE = r"(\d{4}-\d{2}-\d{2})"


@dataclass
class Chunk:
    chunk_uid: str          # stable: "<repo-relative-path>#<section-slug>"
    path: str               # repo-relative
    title: str              # frontmatter title (or filename stem)
    section: str            # H2/H3 heading ("" for a headingless note)
    type: str = ""
    status: str = ""
    source: str = ""
    confidence: str = ""
    tags: list[str] = field(default_factory=list)
    added: str = ""          # YYYY-MM-DD or ""
    last_verified: str = ""  # YYYY-MM-DD or ""
    content: str = ""
    content_hash: str = ""
    token_count: int = 0

    def embed_text(self) -> str:
        """Text handed to the embedder — title + section give the body context."""
        head = " — ".join(p for p in (self.title, self.section) if p)
        return f"{head}\n\n{self.content}" if head else self.content

    def snippet(self, limit: int = 320) -> str:
        s = " ".join(self.content.split())
        return s[:limit] + ("…" if len(s) > limit else "")

    def as_dict(self) -> dict:
        return asdict(self)


def _est_tokens(text: str) -> int:
    return max(1, len(text) // _CHARS_PER_TOKEN)


def _slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s or "body"


def _parse_inline_list(raw: str) -> list[str]:
    raw = raw.strip()
    if raw.startswith("[") and raw.endswith("]"):
        raw = raw[1:-1]
    return [t.strip().strip("\"'") for t in raw.split(",") if t.strip()]


def parse_frontmatter(text: str) -> tuple[dict, str]:
    """Return (frontmatter dict, body). Tolerant of files with no frontmatter."""
    if not text.startswith("---"):
        return {}, text
    lines = text.splitlines()
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return {}, text
    fm: dict = {}
    for ln in lines[1:end]:
        if ":" not in ln:
            continue
        key, _, val = ln.partition(":")
        key, val = key.strip(), val.strip()
        if not key:
            continue
        if key == "tags":
            fm["tags"] = _parse_inline_list(val)
        else:
            fm[key] = val.strip("\"'")
    body = "\n".join(lines[end + 1:])
    return fm, body


def _split_h2(body: str) -> list[tuple[str, str]]:
    """Split on top-level '## ' headings. Returns [(heading, text)]; heading '' = preamble."""
    sections: list[tuple[str, str]] = []
    heading = ""
    buf: list[str] = []

    def flush() -> None:
        text = "\n".join(buf).strip()
        if heading or text:
            sections.append((heading, text))

    for ln in body.splitlines():
        # '## x' but not '### x' (the latter's 3rd char is '#', not ' ').
        if ln.startswith("## ") and not ln.startswith("###"):
            flush()
            heading = ln[3:].strip()
            buf = []
        else:
            buf.append(ln)
    flush()
    return sections


def _split_h3(text: str) -> list[tuple[str, str]]:
    parts: list[tuple[str, str]] = []
    heading = ""
    buf: list[str] = []

    def flush() -> None:
        t = "\n".join(buf).strip()
        if heading or t:
            parts.append((heading, t))

    for ln in text.splitlines():
        if ln.startswith("### ") and not ln.startswith("####"):
            flush()
            heading = ln[4:].strip()
            buf = []
        else:
            buf.append(ln)
    flush()
    return parts


def _window_paragraphs(text: str) -> list[str]:
    """Last-resort split of a too-large block into overlapping paragraph windows."""
    paras = [p for p in re.split(r"\n\s*\n", text) if p.strip()]
    windows: list[str] = []
    cur: list[str] = []
    for p in paras:
        cur.append(p)
        if _est_tokens("\n\n".join(cur)) >= MAX_CHUNK_TOKENS:
            windows.append("\n\n".join(cur))
            cur = cur[-1:]  # 1-paragraph overlap keeps context across the seam
    if cur:
        windows.append("\n\n".join(cur))
    return windows or [text]


def _find_date(text: str, label: str) -> str:
    m = re.search(rf"{re.escape(label)}\s*:\s*`?{_DATE_RE}", text)
    return m.group(1) if m else ""


def _explode(heading: str, text: str) -> list[tuple[str, str]]:
    """Split one H2 section into <=MAX_CHUNK_TOKENS pieces, preserving sub-headings."""
    if _est_tokens(text) <= MAX_CHUNK_TOKENS:
        return [(heading, text)]
    out: list[tuple[str, str]] = []
    subs = _split_h3(text)
    if len(subs) > 1 or (subs and subs[0][0]):
        for sub_head, sub_text in subs:
            label = f"{heading} / {sub_head}".strip(" /") if heading else sub_head
            for i, win in enumerate(_window_paragraphs(sub_text)):
                out.append((f"{label} ({i + 1})" if i else label, win))
    else:
        for i, win in enumerate(_window_paragraphs(text)):
            out.append((f"{heading} ({i + 1})" if i else heading, win))
    return out


def chunk_markdown(path: str, text: str) -> list[Chunk]:
    """Turn one markdown file's text into retrieval chunks."""
    fm, body = parse_frontmatter(text)
    stem = path.rsplit("/", 1)[-1].removesuffix(".md")
    title = fm.get("title") or stem.replace("-", " ").title()

    chunks: list[Chunk] = []
    seen: dict[str, int] = {}
    for heading, sect in _split_h2(body):
        if not sect.strip():
            continue
        for sub_head, piece in _explode(heading, sect):
            if not piece.strip():
                continue
            base = _slug(sub_head) if sub_head else "body"
            n = seen.get(base, 0)
            seen[base] = n + 1
            slug = base if n == 0 else f"{base}-{n + 1}"
            uid = f"{path}#{slug}"
            content_hash = hashlib.sha256(piece.encode("utf-8")).hexdigest()[:16]
            chunks.append(
                Chunk(
                    chunk_uid=uid,
                    path=path,
                    title=title,
                    section=sub_head,
                    type=fm.get("type", ""),
                    status=fm.get("status", ""),
                    source=fm.get("source", ""),
                    confidence=fm.get("confidence", ""),
                    tags=fm.get("tags", []),
                    added=_find_date(piece, "Added") or fm.get("created", ""),
                    last_verified=(
                        _find_date(piece, "Last verified") or fm.get("last_verified", "")
                    ),
                    content=piece,
                    content_hash=content_hash,
                    token_count=_est_tokens(piece),
                )
            )
    return chunks
