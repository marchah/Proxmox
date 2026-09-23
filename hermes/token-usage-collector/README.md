# Token-usage collector (CT 121)

A five-minute systemd timer inside CT 121 accumulates token usage in a daily ledger.
It reads two sources, reported separately:

| Source | Coverage | Limitation |
| --- | --- | --- |
| `endpoint` | All clients of CT 120's llama.cpp `/metrics` | Counters reset on server restart; totals are a lower bound |
| `hermes_accounted` | Hermes `session_model_usage`, filtered by provider | Only Hermes calls observed after the collector baseline |

The default database provider is `openai-codex`. Exclude `custom`, `auto` and empty
providers: they overlap CT 120's endpoint totals. Do not sum overlapping sources.
CT 123 exposes llama.cpp metrics on `:1234` but is not in the configured source list.

## Install

Run **inside CT 121** as root. Idempotent.

```bash
cd hermes/token-usage-collector && ./install.sh
```

It installs `token-usage-collect` + `token-usage-report` into `/usr/local/bin`,
`/etc/token-usage.env` (kept if it already exists), the service + timer, then
primes the baseline. From the Proxmox host:

```bash
tar -czf /tmp/tuc.tgz -C hermes token-usage-collector
pct push 121 /tmp/tuc.tgz /tmp/tuc.tgz
pct exec 121 -- bash -lc 'tar -xzf /tmp/tuc.tgz -C /tmp && cd /tmp/token-usage-collector && ./install.sh'
```

## Use

```bash
pct exec 121 -- bash -lc 'token-usage-report'                 # last 30 days, both families
pct exec 121 -- bash -lc 'token-usage-report --month 2026-08'
pct exec 121 -- bash -lc 'token-usage-report --days 7 --json'
pct exec 121 -- systemctl list-timers token-usage-collect.timer
pct exec 121 -- journalctl -u token-usage-collect.service -n 20
```

(`bash -lc` is required — bare `pct exec` omits `/usr/local/bin` from `PATH`.)

## Storage

Under `TOKEN_USAGE_DIR`, default `/root/.hermes/token-usage/`:

| File | Role |
| --- | --- |
| `state.json` | **authoritative** — per-source cursor, running totals, reset count, daily buckets |
| `daily.jsonl` | derived on every write — one line per `(date, source)`, for consumers that would rather grep |

The ledger is readable from Hermes. Day buckets use `TOKEN_USAGE_TZ`
(default `America/New_York`). It is excluded from the git config backup; the
weekly CT 121 vzdump is its off-box copy. The accumulated history cannot be rebuilt.

## Endpoint accuracy

- **Tokens served between the last scrape and a restart are lost.** Nothing
  persists them server-side, so no sampling collector can recover them. The loss
  is bounded by the scrape interval — that is the only reason the interval is
  5 minutes rather than an hour.
- **A reset can hide.** If llama-server restarts *and* the new counter climbs past
  the old value before the next scrape, the decrease never appears and that
  interval under-counts. Narrow at 5 minutes, not impossible.
- **The first sample attributes nothing.** llama.cpp's counter may already be
  non-zero when the collector starts; those tokens predate observation.

## Provider accounting

The collector reads per-row deltas from `session_model_usage`, keyed by
`session_id|model|billing_provider|task`. The task distinguishes conversation calls
from title generation, compression and approvals. It also records cache reads,
reasoning tokens, call counts and the provider's billing metadata.

The first pass establishes a baseline without attributing prior usage. Row decreases
are clamped to zero. Session deletion can remove rows, so the ledger retains observed
deltas independently of the database.

`token-usage-report` keeps endpoint and provider families separate. The JSON
`total_tokens` is meaningful only when the configured populations are disjoint.

## Extending

`TOKEN_USAGE_SOURCES` takes space-separated `name=url` pairs, so a second
llama.cpp server is one env edit. The scrape rejects a 200 that lacks the two
counters, so pointing it at llama-swap fails loudly instead of silently recording
zeros.

⚠️ If you move `TOKEN_USAGE_DIR` outside `/root/.hermes`, add that path to
`ReadWritePaths=` in `token-usage-collect.service`. `ProtectSystem=strict` makes
everything else read-only, and systemd fails a unit with an opaque
`226/NAMESPACE` error when a `ReadWritePaths=` entry does not exist.
