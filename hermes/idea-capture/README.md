# idea-capture — Slack `#ideas` → Project Planner (CT 121)

A Hermes plugin that turns every top-level message in the private `#ideas` Slack channel into an
idea on the [Project Planner](https://github.com/marchah/project-planner) board on VM 300, then
replies in that message's thread with the title the board wrote and a link to the note. No agent
turn runs: the gateway is told to skip the message.

```
#ideas message ──▶ Slack gateway (CT 121) ──pre_gateway_dispatch──▶ idea-capture
                                                                     │ POST /api/ideas {text, source: SLACK, sourceUrl}
                                                                     ▼
                                    thread reply ◀── title + link ── board (VM 300) ── title model (CT 120)
```

## Why a plugin, not a channel prompt

The obvious version is a `channel_prompts` entry asking the agent to `curl` each message to the
board. It was rejected for three reasons:

- **The text arrives verbatim.** The agent would have to rebuild arbitrary user text (quotes,
  newlines, code) inside a shell command. The plugin sends Slack's raw message text, with only
  Slack's own link and `&amp;` encoding undone. Hermes' enriched `event.text` is not used, because
  it can carry link-unfurl and attached-file content that is not part of the idea.
- **About a second, not an agent turn** (10–20 s on the local model).
- **It does not depend on CT 120's chat model.** A prompt-cache corruption on CT 120 kills the
  in-flight agent turn; the plugin only needs the board, which saves the idea even when its own
  title model is down.

## What it captures

| Message in `#ideas` | Result |
| --- | --- |
| Top-level message from a user in `SLACK_ALLOWED_USERS` | Saved; thread reply with title + link |
| …with an attachment and text (`file_share`) | Saved (text only) |
| …with only an attachment | Not saved; thread reply says only text ideas can be saved |
| Thread reply | Passed to the agent, as in any other channel |
| Bot posts, edits, joins, commands | Passed through untouched |
| Any user not in `SLACK_ALLOWED_USERS` | Passed through — Hermes' own authorization then applies |

⚠️ The hook runs **before** Hermes' authorization, so the plugin applies `SLACK_ALLOWED_USERS`
itself, and an empty allowlist captures nothing.

Slack redelivers events after a gateway reconnect; captured message timestamps are recorded in
`/root/.hermes/idea-capture/seen.json` (last 500) so a redelivered message is saved once.

## Install

Inside CT 121, from a checkout of this repo:

```bash
# 1. add PROJECT_PLANNER_URL and PROJECT_PLANNER_SLACK_CHANNEL to /root/.hermes/.env
#    (see idea-capture.env.example)
pct exec 121 -- bash -lc 'cd /path/to/Proxmox/hermes/idea-capture && ./install.sh'
# 2. restart the gateway when no agent turn is running
pct exec 121 -- systemctl restart hermes
```

The Slack bot must be a member of the channel; with `require_mention: false` and an empty
`allowed_channels`, the gateway already receives its messages.

## Verify and operate

- Post an idea in `#ideas`: the thread reply arrives within a second or two.
- Logs: `pct exec 121 -- journalctl -u hermes --since -10min | grep idea-capture`.
- Board unreachable: the thread reply says so with the HTTP status or error type, and the message
  stays in Slack to repost. The plugin does not retry.
- Disable: `hermes plugins disable idea-capture`, then restart the gateway. `#ideas` messages then
  reach the agent like any other channel.

## Tests

```bash
python3 -m unittest discover -s hermes/idea-capture/plugin
```
