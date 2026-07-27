# host-notifications — make Proxmox notifications loud

Host-side only (runs on the Proxmox host, not in a guest), same idempotent-`install.sh` spirit as
`host-net/` and `pro-v620/`.

## Why

Proxmox's weekly backup job failed **four Sundays in a row** (2026-07-05 → 07-19) and nobody
noticed. Proxmox *did* notify, every time — to the builtin `mail-to-root` target, which delivers
to root's local mailbox via postfix. A notification nobody reads is not a notification.

## What it sets up

```bash
./setup-slack-notifications.sh 'https://hooks.slack.com/services/T…/B…/…'
```

- a **webhook** notification endpoint named `slack`, posting Slack-flavoured mrkdwn
- a matcher named `slack-all` (`mode=all`, no rules → matches everything) targeting it

The matcher is **additional** to the builtin `default-matcher`, so `mail-to-root` keeps working —
Proxmox delivers to the union of every matching matcher's targets.

Get the URL from **api.slack.com/apps → your app → Incoming Webhooks → Add New Webhook to
Workspace**. The webhook is bound to the channel you pick there, so the script has no channel
setting.

Only forward the noisy stuff? `MIN_SEVERITY=warning ./setup-slack-notifications.sh <url>`.

## The URL is stored as a secret

It goes in as a Proxmox notification **secret**, referenced from the URL template as
`{{ secrets.token }}`. The API returns only the secret's *name*:

```console
$ pvesh get /cluster/notifications/endpoints/webhook/slack
  "secret": [ "name=token" ],
  "url": "https://hooks.slack.com/services/{{ secrets.token }}"
```

So the live token is not in `notifications.cfg` and not in `pvesh` output. The host is kept
visible in the URL field on purpose — a glance still shows *where* notifications go.

Re-running the script replaces both objects, so it is also how you **rotate** the URL.

## Verify

```bash
pvesh create /cluster/notifications/targets/slack/test   # synthetic test message
vzdump 200 --storage Synology-Backup --mode stop         # a REAL job that notifies
```

Prefer the second: a real job proves the delivery path. Look for both lines in its output —

```
INFO: notified via target `mail-to-root`
INFO: notified via target `slack`
```

## Gotchas

- **The body is a template, and a malformed one fails silently** — exactly the failure class this
  directory exists to prevent. The script wraps the message in `{{ escape message }}` so quotes
  and newlines can't produce invalid JSON.
- **Notifications are not monitoring.** This tells you when Proxmox *emits* something. It won't
  tell you a service died quietly, or that a backup job stopped being scheduled at all.
- Template/secret syntax reference: `/usr/share/pve-docs/chapter-notifications.html` on the host
  (version-matched — prefer it over the web docs).
