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
            acc = per_source.setdefault(source, {"prompt": 0, "predicted": 0, "resets": 0,
                                                 "cache_read": 0, "reasoning": 0, "calls": 0})
            for f in ("prompt", "predicted", "resets", "cache_read", "reasoning", "calls"):
                acc[f] += bucket.get(f, 0)

    # A source name containing "/" is `<billing_provider>/<model>` from Hermes'
    # accounting table; anything else is a scraped endpoint. The two count
    # overlapping populations (see token-usage.env), so they are never summed into
    # one figure — only within a family.
    def family(name: str) -> str:
        return "hermes_accounted" if "/" in name else "endpoint"

    fam_totals = {"endpoint": 0, "hermes_accounted": 0}
    for name, v in per_source.items():
        fam_totals[family(name)] += v["prompt"] + v["predicted"]

    payload = {
        "period": {"label": label, "since": since, "until": until, "days_with_data": days_seen},
        "sources": {
            name: {
                "family": family(name),
                "prompt_tokens": v["prompt"],
                "predicted_tokens": v["predicted"],
                "total_tokens": v["prompt"] + v["predicted"],
                "counter_resets": v["resets"],
                **({"cache_read_tokens": v["cache_read"]} if v["cache_read"] else {}),
                **({"reasoning_tokens": v["reasoning"]} if v["reasoning"] else {}),
                **({"api_calls": v["calls"]} if v["calls"] else {}),
            }
            for name, v in sorted(per_source.items())
        },
        "family_totals": fam_totals,
        "total_tokens": fam_totals["endpoint"] + fam_totals["hermes_accounted"],
        "caveat": (
            "floor, not an exact count: tokens served between the last scrape and a "
            "llama-server restart are unrecoverable. 'endpoint' counts everything "
            "hitting that server (any client); 'hermes_accounted' counts what Hermes "
            "itself spent per model. They overlap for local models, so total_tokens is "
            "only meaningful when the two families cover disjoint model sets — which "
            "is the shipped default (endpoint=CT 120, accounted=cloud providers only)."
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
    width = max(len(n) for n in per_source) + 1
    for fam, title in (("endpoint", "Server endpoints (all clients of that server)"),
                       ("hermes_accounted", "Hermes-accounted per model (incl. cloud providers)")):
        members = {n: v for n, v in per_source.items() if family(n) == fam}
        if not members:
            continue
        print(f"\n  {title}")
        for name, v in sorted(members.items()):
            tot = v["prompt"] + v["predicted"]
            extra = ""
            if v["cache_read"]:
                extra += f"  cache_read {v['cache_read']:,}"
            if v["reasoning"]:
                extra += f"  reasoning {v['reasoning']:,}"
            if v["calls"]:
                extra += f"  calls {v['calls']:,}"
            if v["resets"]:
                extra += f"  ({v['resets']} counter reset(s))"
            print(f"    {name:{width}s} in {v['prompt']:>12,}  out {v['predicted']:>10,}"
                  f"  total {tot:>12,}{extra}")
        print(f"    {'subtotal':{width}s} {fam_totals[fam]:>44,}")

    print("\n  floor, not exact — a restart between scrapes loses the tokens since the last scrape")
    print("  the two families count overlapping populations for local models and are not summed")
    print("  here; by default they are disjoint (endpoint = CT 120, accounted = cloud only).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
