#!/usr/bin/env python3
"""Report accumulated token usage over a period.

Reads the ledger written by token-usage-collect.py. This is what the weekly
online-model-pricing job calls instead of scraping raw counters, and what a human
runs to answer "what did we spend last month".

  token-usage-report                     # last 30 days
  token-usage-report --days 7
  token-usage-report --month 2026-08
  token-usage-report --since 2026-08-01 --until 2026-08-31
  token-usage-report --json              # machine-readable

Every total is a FLOOR: tokens served between the last scrape and a llama-server
restart are unrecoverable, so the ledger under-counts by an unknown but bounded
amount. The output says so rather than implying precision it does not have.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover
    ZoneInfo = None  # type: ignore


def load_state(path: str) -> dict:
    if not os.path.exists(path):
        raise SystemExit(
            f"no ledger at {path} — is token-usage-collect.timer enabled?\n"
            "  systemctl status token-usage-collect.timer"
        )
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def main() -> int:
    ap = argparse.ArgumentParser(description="Report accumulated llama.cpp token usage.")
    ap.add_argument("--dir", default=os.environ.get("TOKEN_USAGE_DIR", "/root/.hermes/token-usage"))
    ap.add_argument("--days", type=int, help="last N days, ending today")
    ap.add_argument("--month", help="calendar month, YYYY-MM")
    ap.add_argument("--since", help="inclusive start date, YYYY-MM-DD")
    ap.add_argument("--until", help="inclusive end date, YYYY-MM-DD")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of text")
    args = ap.parse_args()

    state = load_state(os.path.join(args.dir, "state.json"))
    daily = state.get("daily", {})

    tz = ZoneInfo(os.environ.get("TOKEN_USAGE_TZ", "America/New_York")) if ZoneInfo else None
    today = datetime.now(tz).date()

    if args.month:
        since = f"{args.month}-01"
        year, month = (int(p) for p in args.month.split("-"))
        last = (datetime(year + month // 12, month % 12 + 1, 1) - timedelta(days=1)).date()
        until = last.isoformat()
        label = f"month {args.month}"
    elif args.since or args.until:
        since = args.since or min(daily, default=today.isoformat())
        until = args.until or today.isoformat()
        label = f"{since} .. {until}"
    else:
        days = args.days or 30
        since = (today - timedelta(days=days - 1)).isoformat()
        until = today.isoformat()
        label = f"last {days} days"

    per_source: dict[str, dict[str, int]] = {}
    days_seen = 0
    for date in sorted(daily):
        if not (since <= date <= until):
            continue
        days_seen += 1
        for source, bucket in daily[date].items():
            acc = per_source.setdefault(source, {"prompt": 0, "predicted": 0, "resets": 0})
            acc["prompt"] += bucket.get("prompt", 0)
            acc["predicted"] += bucket.get("predicted", 0)
            acc["resets"] += bucket.get("resets", 0)

    total = sum(v["prompt"] + v["predicted"] for v in per_source.values())
    payload = {
        "period": {"label": label, "since": since, "until": until, "days_with_data": days_seen},
        "sources": {
            name: {
                "prompt_tokens": v["prompt"],
                "predicted_tokens": v["predicted"],
                "total_tokens": v["prompt"] + v["predicted"],
                "counter_resets": v["resets"],
            }
            for name, v in sorted(per_source.items())
        },
        "total_tokens": total,
        "caveat": (
            "floor, not an exact count: tokens served between the last scrape and a "
            "llama-server restart are unrecoverable"
        ),
    }

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0

    print(f"Token usage — {label}  ({days_seen} day(s) with data)")
    if not per_source:
        print("  no samples in this period")
        first = state.get("sources", {})
        for name, entry in sorted(first.items()):
            print(f"  {name}: collector first saw this source at {entry.get('first_seen') or 'never'}")
        return 0
    for name, v in sorted(per_source.items()):
        tot = v["prompt"] + v["predicted"]
        print(
            f"  {name:12s} prompt {v['prompt']:>14,}  predicted {v['predicted']:>14,}"
            f"  total {tot:>14,}"
            + (f"  ({v['resets']} counter reset(s))" if v["resets"] else "")
        )
    print(f"  {'TOTAL':12s} {total:>60,}")
    print("  floor, not exact — a restart between scrapes loses the tokens since the last scrape")
    return 0


if __name__ == "__main__":
    sys.exit(main())
