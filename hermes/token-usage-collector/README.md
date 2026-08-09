# Token-usage collector (CT 121)

A systemd timer inside **CT 121** that turns llama.cpp's resettable Prometheus
counters into a durable daily series, so "how many tokens did we spend last month"
finally has an answer.

Runs **inside the Hermes LXC**, not on the Proxmox host — unlike the `pro-v620/`
services. It scrapes over HTTP (no `pct` needed) and writes where the weekly
online-model-pricing job can read it without extra plumbing.

## Why this is not just "curl /metrics"

CT 120 exposes `llamacpp:prompt_tokens_total` and `llamacpp:tokens_predicted_total`
(it needs `--metrics`; added in the same PR as this collector). Both are **counters
since process start**, and llama.cpp persists nothing. So:

- A single scrape means "tokens since `<uptime>`", never a monthly total.
- CT 120 **gets restarted** — restarting is the remedy for the prompt-cache
  corruption — and every restart zeroes the counters.

Two scrapes a month apart therefore cannot be subtracted. This collector samples
every 5 minutes and folds each delta into a monotonic running total, detecting
resets the way Prometheus' own `rate()` does.

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
pct exec 121 -- bash -lc 'token-usage-report'                 # last 30 days
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

Living under `/root/.hermes` is deliberate: `backup-automations.sh` rsyncs that
tree and this path is not deny-listed, so the ledger is backed up to the private
config-backup repo automatically. It is also the one place the Hermes pricing job
can read without extra plumbing. Day buckets use `TOKEN_USAGE_TZ`
(`America/New_York`), so a "day" here matches the Hermes cron schedules.

The ledger is **not rebuildable** — it is accumulated observation. Losing it loses
the history, which is why it sits somewhere backed up.

## Accuracy — every total is a floor

Read this before quoting a number.

- **Tokens served between the last scrape and a restart are lost.** Nothing
  persists them server-side, so no sampling collector can recover them. The loss
  is bounded by the scrape interval — that is the only reason the interval is
  5 minutes rather than an hour.
- **A reset can hide.** If llama-server restarts *and* the new counter climbs past
  the old value before the next scrape, the decrease never appears and that
  interval under-counts. Narrow at 5 minutes, not impossible.
- **The first sample attributes nothing.** llama.cpp's counter may already be
  non-zero when the collector starts; those tokens predate observation.

So the series is a lower bound. Good enough to answer "are we above or below the
~18M tokens/month hosted break-even", which is what it exists for; not an
accounting record.

## Why CT 123 (`gpu2`) is absent

`gpu2:8080/metrics` answers 200 but serves **llama-swap's own host telemetry** —
`llamaswap_cpu_util_percent`, `memory_*`, `swap_*`, `load_average`,
`network_bytes_total`. There are **no token or request counters at all**.

Adding `--metrics` to each model in `/etc/llama-swap/config.yaml` would give each
upstream llama.cpp its own `/metrics`, reachable through llama-swap at
`/upstream/<model>/metrics`. That was rejected: llama-swap unloads and reloads
models on demand, so those counters reset on **every swap** and the endpoint is
unreachable whenever the model is unloaded. A 5-minute sampler would miss any
model that loads, serves, and unloads between ticks. That is worse than not
measuring, because it looks like data.

Measuring CT 123 needs a different mechanism — parsing llama.cpp's
`print_timing` lines out of CT 123's journal, which requires running there rather
than scraping from here. Not built.

## Extending

`TOKEN_USAGE_SOURCES` takes space-separated `name=url` pairs, so a second
llama.cpp server is one env edit. The scrape rejects a 200 that lacks the two
counters, so pointing it at llama-swap fails loudly instead of silently recording
zeros.

⚠️ If you move `TOKEN_USAGE_DIR` outside `/root/.hermes`, add that path to
`ReadWritePaths=` in `token-usage-collect.service`. `ProtectSystem=strict` makes
everything else read-only, and systemd fails a unit with an opaque
`226/NAMESPACE` error when a `ReadWritePaths=` entry does not exist.
