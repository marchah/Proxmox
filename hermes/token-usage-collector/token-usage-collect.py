#!/usr/bin/env python3
"""Accumulate llama.cpp token counters into a restart-proof ledger.

Runs inside CT 121 on a systemd timer. Scrapes each configured llama.cpp
`/metrics` endpoint and folds the delta since the previous scrape into a
monotonic running total, so the result survives the counter resets that a
llama-server restart causes.

Why this exists: llama.cpp returns a `usage` object per response and exposes
`llamacpp:prompt_tokens_total` / `llamacpp:tokens_predicted_total` at /metrics,
but nothing persists either. Both are counters SINCE PROCESS START, so a single
scrape can never answer "how many tokens did we spend last month" — and CT 120
gets restarted (the prompt-cache corruption remedy is a restart). This turns a
sequence of resettable readings into a durable daily series.

Storage (all under TOKEN_USAGE_DIR):
  state.json  authoritative — per-source cursors, running totals, daily buckets
  daily.jsonl derived on every write — one line per (date, source), for consumers
              that would rather grep than parse nested JSON

Delta rule (standard Prometheus counter semantics, as `rate()` uses):
  first ever sample -> delta 0, record the baseline. Tokens generated before the
                       collector existed are not ours to claim.
  raw <  previous   -> restart. delta = raw (everything since the process began).
  raw >= previous   -> delta = raw - previous.

Known, deliberate limitations — read before trusting a number:
  * Tokens served between the last scrape and a restart are LOST. Nothing
    persists them server-side, so a sampling collector cannot recover them. The
    loss is bounded by the scrape interval; that is the reason for 5 minutes.
  * If a restart happens AND the new counter climbs past the old value before the
    next scrape, the reset is invisible and that interval under-counts. Narrow at
    a 5-minute interval, impossible to rule out entirely.
  * Therefore every total here is a FLOOR, not an exact count.

Exit status is always 0 on scrape failure: a missed sample is normal operation
(the model server restarts, the network blips) and must not mark the timer
failed. Genuine misconfiguration — an unwritable directory, an unparseable state
file — still exits non-zero.
"""
from __future__ import annotations

import fcntl
import json
import os
import sqlite3
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python < 3.9
    ZoneInfo = None  # type: ignore

STATE_VERSION = 1

PROMPT_METRIC = "llamacpp:prompt_tokens_total"
PREDICTED_METRIC = "llamacpp:tokens_predicted_total"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def env(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value if value else default


def parse_sources(raw: str) -> list[tuple[str, str]]:
    """Parse `name=url name=url` into pairs, preserving order."""
    sources = []
    for token in raw.split():
        if "=" not in token:
            log(f"ignoring malformed source (want name=url): {token!r}")
            continue
        name, url = token.split("=", 1)
        name, url = name.strip(), url.strip()
        if name and url:
            sources.append((name, url))
    return sources


def scrape(url: str, timeout: float) -> dict[str, int]:
    """Return the two counters we care about from a Prometheus text response.

    Values are floats on the wire (Prometheus has no integer type) but are whole
    numbers here, so they are truncated to int for exact arithmetic — accumulating
    floats over years of samples would drift.
    """
    req = urllib.request.Request(url, headers={"Accept": "text/plain"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if resp.status != 200:
            raise RuntimeError(f"HTTP {resp.status}")
        body = resp.read().decode("utf-8", "replace")

    found: dict[str, int] = {}
    for line in body.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        metric, value = parts[0], parts[-1]
        if metric == PROMPT_METRIC:
            found["prompt"] = int(float(value))
        elif metric == PREDICTED_METRIC:
            found["predicted"] = int(float(value))

    missing = {"prompt", "predicted"} - found.keys()
    if missing:
        # A 200 that lacks these means --metrics is on but this is not llama.cpp
        # (llama-swap's /metrics answers 200 with host gauges only, no counters).
        raise RuntimeError(f"response lacks {sorted(missing)} counters")
    return found


def read_db_usage(db_path: str, providers: set[str]) -> dict[str, dict]:
    """Per-row cumulative usage from Hermes' own `session_model_usage` table.

    This is the only place cloud-provider usage exists: a model reached over
    `openai-codex` never touches CT 120, so the /metrics scrape above cannot see
    it. Hermes records every call here regardless of provider.

    Returned keys are `session_id|model|billing_provider|task`, which is unique
    across the table (verified: 0 duplicate groups in 972 rows, where the
    3-tuple without `task` has 39). `task` separates the sub-calls Hermes makes
    on its own account — `title_generation`, `compression`, `approval` — from the
    main conversation, so they are attributed rather than silently folded in.

    Read-only (`mode=ro`): the gateway is writing this database concurrently.
    """
    usage: dict[str, dict] = {}
    uri = f"file:{db_path}?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=5.0)
    try:
        rows = con.execute("""
            SELECT session_id, model, billing_provider, task,
                   COALESCE(input_tokens,0)       AS input_tokens,
                   COALESCE(output_tokens,0)      AS output_tokens,
                   COALESCE(cache_read_tokens,0)  AS cache_read_tokens,
                   COALESCE(reasoning_tokens,0)   AS reasoning_tokens,
                   COALESCE(api_call_count,0)     AS api_call_count
            FROM session_model_usage
        """).fetchall()
    finally:
        con.close()

    for sid, model, provider, task, inp, out, cread, reas, calls in rows:
        if (provider or "") not in providers:
            continue
        key = f"{sid}|{model}|{provider}|{task or ''}"
        usage[key] = {
            "series": f"{provider}/{model}",
            "prompt": int(inp),
            "predicted": int(out),
            "cache_read": int(cread),
            "reasoning": int(reas),
            "calls": int(calls),
        }
    return usage


def load_state(path: str) -> dict:
    if not os.path.exists(path):
        return {"version": STATE_VERSION, "sources": {}, "daily": {}, "db_rows": {}}
    with open(path, encoding="utf-8") as fh:
        state = json.load(fh)
    state.setdefault("version", STATE_VERSION)
    state.setdefault("sources", {})
    state.setdefault("daily", {})
    state.setdefault("db_rows", {})
    return state


def write_atomic(path: str, payload: str) -> None:
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-", suffix=".swap")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def render_daily_jsonl(state: dict) -> str:
    """Flatten state['daily'] into a stable, sorted, one-line-per-bucket view."""
    lines = []
    for date in sorted(state["daily"]):
        for source in sorted(state["daily"][date]):
            bucket = state["daily"][date][source]
            row = {
                "date": date,
                "source": source,
                "prompt_tokens": bucket.get("prompt", 0),
                "predicted_tokens": bucket.get("predicted", 0),
                "total_tokens": bucket.get("prompt", 0) + bucket.get("predicted", 0),
                "samples": bucket.get("samples", 0),
                "resets": bucket.get("resets", 0),
            }
            # Only the DB source carries these, so emit them only where real.
            for extra in ("cache_read", "reasoning", "calls"):
                if extra in bucket:
                    row[f"{extra}_tokens" if extra != "calls" else "api_calls"] = bucket[extra]
            lines.append(json.dumps(row, sort_keys=True))
    return "\n".join(lines) + ("\n" if lines else "")


def main() -> int:
    data_dir = env("TOKEN_USAGE_DIR", "/root/.hermes/token-usage")
    sources = parse_sources(env("TOKEN_USAGE_SOURCES", "llamacpp=http://llamacpp:1234/metrics"))
    timeout = float(env("TOKEN_USAGE_TIMEOUT", "5"))
    tz_name = env("TOKEN_USAGE_TZ", "America/New_York")
    db_path = env("TOKEN_USAGE_DB", "/root/.hermes/state.db")
    db_providers = {p for p in env("TOKEN_USAGE_DB_PROVIDERS", "openai-codex").split() if p}

    if not sources and not db_providers:
        log("nothing configured (TOKEN_USAGE_SOURCES / TOKEN_USAGE_DB_PROVIDERS)")
        return 2

    tz = ZoneInfo(tz_name) if ZoneInfo else None
    now = datetime.now(tz)
    today = now.strftime("%Y-%m-%d")
    stamp = now.isoformat(timespec="seconds")

    os.makedirs(data_dir, exist_ok=True)
    state_path = os.path.join(data_dir, "state.json")
    daily_path = os.path.join(data_dir, "daily.jsonl")

    # Serialise against a concurrent run (a slow scrape overlapping the next tick)
    # so two processes cannot both read-modify-write the ledger and lose a delta.
    lock_path = os.path.join(data_dir, ".lock")
    with open(lock_path, "w", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("another collection is in progress; skipping this tick")
            return 0

        state = load_state(state_path)

        for name, url in sources:
            entry = state["sources"].setdefault(name, {
                "url": url,
                "last_raw": None,
                "cumulative": {"prompt": 0, "predicted": 0},
                "resets": 0,
                "samples": 0,
                "first_seen": None,
                "last_ok": None,
                "last_error": None,
            })
            entry["url"] = url

            try:
                raw = scrape(url, timeout)
            except (urllib.error.URLError, OSError, RuntimeError, ValueError) as exc:
                entry["last_error"] = f"{stamp}: {exc}"
                log(f"{name}: scrape failed: {exc}")
                continue

            previous = entry.get("last_raw")
            reset = False
            if previous is None:
                # Baseline only. The counter may already be non-zero; those tokens
                # predate observation and are not attributed to any day.
                delta = {"prompt": 0, "predicted": 0}
                entry["first_seen"] = stamp
            elif raw["prompt"] < previous["prompt"] or raw["predicted"] < previous["predicted"]:
                reset = True
                entry["resets"] = entry.get("resets", 0) + 1
                delta = {"prompt": raw["prompt"], "predicted": raw["predicted"]}
            else:
                delta = {
                    "prompt": raw["prompt"] - previous["prompt"],
                    "predicted": raw["predicted"] - previous["predicted"],
                }

            entry["last_raw"] = raw
            entry["last_ok"] = stamp
            entry["last_error"] = None
            entry["samples"] = entry.get("samples", 0) + 1
            for key in ("prompt", "predicted"):
                entry["cumulative"][key] = entry["cumulative"].get(key, 0) + delta[key]

            bucket = state["daily"].setdefault(today, {}).setdefault(
                name, {"prompt": 0, "predicted": 0, "samples": 0, "resets": 0}
            )
            bucket["prompt"] += delta["prompt"]
            bucket["predicted"] += delta["predicted"]
            bucket["samples"] += 1
            if reset:
                bucket["resets"] += 1

            note = " (counter reset detected)" if reset else ""
            log(f"{name}: +{delta['prompt']} prompt, +{delta['predicted']} predicted{note}")

        # ── Cloud/provider usage from Hermes' own accounting ─────────────────
        # Separate mechanism, separate semantics: these are per-row cumulative
        # totals, not a process counter, so a DECREASE means the session row was
        # pruned (sessions cascade-delete), NOT a restart. Deltas are therefore
        # clamped at zero — never re-attributed like an endpoint reset.
        if db_providers:
            try:
                current = read_db_usage(db_path, db_providers)
            except (sqlite3.Error, OSError) as exc:
                log(f"db: read failed: {exc}")
                current = None
            if current is not None:
                seen = state["db_rows"]
                # First pass ever: record cursors for everything already in the table
                # and attribute NOTHING. Those calls happened before the collector
                # existed — the endpoint source baselines the same way. Without this,
                # day one absorbs the entire history (the initial run attributed
                # 216k gpt-5.6-terra tokens dating back to 2026-07-18 to that day).
                baseline = not state.get("db_baselined")
                totals: dict[str, dict[str, int]] = {}
                for key, row in current.items():
                    prev = seen.get(key) or {}
                    if not baseline:
                        acc = totals.setdefault(row["series"], {})
                        for field in ("prompt", "predicted", "cache_read", "reasoning", "calls"):
                            delta = row[field] - int(prev.get(field, 0))
                            if delta > 0:
                                acc[field] = acc.get(field, 0) + delta
                    seen[key] = {k: row[k] for k in
                                 ("prompt", "predicted", "cache_read", "reasoning", "calls")}
                if baseline:
                    state["db_baselined"] = True
                    log(f"db: baselined {len(current)} existing row(s); "
                        "pre-existing history not attributed to today")
                # A pruned row simply stops contributing; drop its cursor so the
                # state file does not grow without bound.
                for stale in set(seen) - set(current):
                    del seen[stale]

                for series, acc in sorted(totals.items()):
                    if not any(acc.values()):
                        continue
                    bucket = state["daily"].setdefault(today, {}).setdefault(
                        series, {"prompt": 0, "predicted": 0, "samples": 0, "resets": 0})
                    for field, value in acc.items():
                        bucket[field] = bucket.get(field, 0) + value
                    bucket["samples"] += 1
                    log(f"{series}: +{acc.get('prompt', 0)} in, +{acc.get('predicted', 0)} out"
                        f" ({acc.get('calls', 0)} call(s))")

        write_atomic(state_path, json.dumps(state, indent=2, sort_keys=True) + "\n")
        write_atomic(daily_path, render_daily_jsonl(state))

    return 0


if __name__ == "__main__":
    sys.exit(main())
