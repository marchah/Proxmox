# `hermes/config/` — the CT-121 autonomous-coding-loop / orchestrator config

This folder captures the config that drives the homelab's **autonomous coder↔reviewer loop**, which runs inside
**CT 121 `hermes`** (the Hermes Agent LXC). It used to live only on the running container; this is the documented,
version-controlled, re-deployable snapshot. Scope is the **loop/orchestrator only** — the box's unrelated
KB/homelab automations are intentionally not tracked here.

It mirrors the repo's host-service idiom (`pro-v620/gpu-thermal-watchdog/` et al.): an idempotent `install.sh` +
committed files + a `*.env.example` template + this README. The difference is the deploy **target is CT 121**, not
the Proxmox host — run `install.sh` inside the container (`git clone` the repo there, or `pct push` this folder in).

> This is **operator config for a self-driving loop**, not an app. It assumes CT 121 (`hermes/create-lxc-hermes-agent.sh`),
> CT 122 `coder-runner` (`coder-runner/`), and CT 123 `gpu2` (`pro-v620/create-lxc-llama-swap-gpu2.sh`) already exist.

## The loop, end to end

```
 Slack #planning ──scope-and-plan──▶ plan PR + blocked feature backlog (finalize-plan / release-backlog)
                                            │
        backlog-tick (timer, 3 min) ── releases a feature task once its deps' PRs are merged
                                            │
                                            ▼
   ┌── coder profile (qwen3-instruct-2507) ── implement ONE task on a branch
   │      edits locally on CT 121, runs checks/build/tests on CT 122 over ssh+rsync (run-on-runner/checks-on-runner)
   │      commits deterministically via verify-and-commit (Hermes won't auto-commit; the model won't run git)
   │      ⇢ completion-gate blocks "done" if the branch has 0 commits ahead of main
   │      ⇢ coder-commit-audit hook re-checks after completion
   ▼
   reviewer profile (qwen3-coder-30b-a3b) ── run tests+lint+review a coder branch
          PASS ⇒ open-pr (PR-ready notice to #coding)   FAIL ⇒ file a linked fix task with findings
                                            │
             /codex-review <pr#> ── on-demand Codex (ChatGPT) review; verdict → #coding + the PR
             pr-revise-tick (timer, 3 min) ── PRs labeled loop:revise ⇒ file a coder fix task from the comments
                                            │
             loop-watchdog (timer, 2 min) ── reaps stalled/runaway workers (idle-limit primary, per-role hard cap)
```

The dispatcher runs **one task at a time** (`kanban.max_in_progress: 1`) because the single GPU-2 card holds one
model resident at a time and llama-swap hot-swaps coder⇄reviewer at role handoffs. **No auto-merge to public `main`** —
PRs are human-reviewed. See the `autonomous-coding-loop` memory for the full design + hard-won gotchas.

## Layout

```
install.sh            Idempotent deploy into CT 121 (bin→/usr/local/bin, profiles/skills/plugins→/root/.hermes,
                      the 3 timers→/etc/systemd/system). NEVER writes /root/.hermes/.env.
hermes.env.example    The loop vars to add to /root/.hermes/.env — MEALDEAL_GITHUB_TOKEN + the SLACK_*_CHANNEL
                      IDs that were parameterized out of the committed scripts.
config-snippets.md    The loop-relevant blocks of the SHARED /root/.hermes/config.yaml to merge by hand
                      (kanban serialization, plugins.enabled, channel routing, model pointers).
loop-watchdog.env     Non-secret watchdog thresholds (idle limit + per-role hard caps). Channel falls back to
                      SLACK_AUTOMATION_CHANNEL from .env.

bin/                  Loop helpers → /usr/local/bin. Execution offload (run-on-runner, checks-on-runner,
                      regen-on-runner), commit gate (verify-and-commit), audit (coder-commit-audit[-check]),
                      review/PR (review-branch, request-review, open-pr, pr-comments, resolve-pr-comments,
                      codex-review), planning/backlog (finalize-plan, release-backlog, backlog-tick,
                      free-feature-branch, file-fix), the tick drivers (backlog-tick, pr-revise-tick) and
                      loop-watchdog.
profiles/coder/       coder lane: config.yaml (model qwen3-instruct-2507, trimmed toolset, audit hook),
                      profile.yaml, .no-bundled-skills, SOUL.md, skills/implement-and-verify/.
profiles/reviewer/    reviewer lane: config.yaml (model qwen3-coder-30b-a3b), profile.yaml, .no-bundled-skills,
                      SOUL.md, skills/review-and-rework/.
skills/               The loop's custom skills: scope-and-plan (planner), review-pr (reviewer).
plugins/              completion-gate (pre_tool_call false-completion guard), codex-review (/codex-review command).
systemd/              The 3 loop timers (loop-watchdog / backlog-tick / pr-revise-tick, each .service + .timer).
planner-SOUL.md       Reference copy of the planner persona used in the #planning channel (no dedicated profile).
```

## Install

```bash
# inside CT 121, as root
./install.sh
```

It deploys everything above (rsync **without** `--delete`, so it never removes stock Hermes bundles or your secret
files), reloads systemd, and enables the three loop timers. It is idempotent. Then do the three manual steps it
prints — they touch secrets / shared config it deliberately won't:

1. **Secrets** — add the loop vars from `hermes.env.example` to `/root/.hermes/.env` (the
   `MEALDEAL_GITHUB_TOKEN` + the `SLACK_*_CHANNEL` IDs). `install.sh` **never** writes this file.
2. **Shared config** — merge the blocks from `config-snippets.md` into `/root/.hermes/config.yaml`.
3. **Restart the gateway** — `systemctl restart hermes` so the plugins + config load.

Verify: `systemctl list-timers 'loop-watchdog*' 'backlog-tick*' 'pr-revise-tick*'`.

## Env vars (why they exist)

`marchah/Proxmox` is a **public** repo, so the committed loop scripts must not carry the private Slack channel IDs.
Those were parameterized to env vars sourced from `/root/.hermes/.env` (every affected script already does
`. /root/.hermes/.env`):

| Var | What it holds | Used by |
|-----|---------------|---------|
| `MEALDEAL_GITHUB_TOKEN`    | fine-grained PAT (Contents + PR: write) for the loop's target repo | open-pr, backlog-tick, pr-revise-tick, codex-review |
| `SLACK_CODING_CHANNEL`     | Slack channel ID for PR-ready notices + Codex/loop verdicts | codex-review, open-pr, coder-commit-audit-check, loop-watchdog, codex-review plugin |
| `SLACK_AUTOMATION_CHANNEL` | Slack channel ID for watchdog reap notifications | loop-watchdog (fallback) |
| `SLACK_PLANNING_CHANNEL`   | Slack channel ID that drives the scope-and-plan planner | `config.yaml` channel routing (planner) |

(The real token/IDs live only in `/root/.hermes/.env`, never in the repo.) The gateway's own Slack/Discord/API
credentials also live in that file but are set up by the base Hermes container, not by this loop config.

## Secrets & the public repo

- Never commit `/root/.hermes/.env`, per-profile `.env`, `dashboard-auth.env`, `auth.json`, or `/root/.ssh/coder-runner*`.
- `.gitignore` excludes `.env`/`.env.*` (keeps `!.env.example`); the committed profile `config.yaml`s use
  `api_key: ''` (no inline secret — the model server needs no key).
- Do **not** run `gh auth login` on CT 121 (it would clobber the box's existing gh login); the loop uses the
  fine-grained `MEALDEAL_GITHUB_TOKEN` from `.env`.

## The systemd timers

| Timer | Cadence | What it does |
|-------|---------|--------------|
| `loop-watchdog.timer`   | 2 min | Reap stalled/runaway kanban workers. Idle-limit (log mtime) is the primary signal; per-role hard caps (`loop-watchdog.env`) are backstops. Notifies `SLACK_AUTOMATION_CHANNEL`. |
| `backlog-tick.timer`    | 3 min | Merge-gated backlog: release a blocked feature task once the PRs of its deps are merged. |
| `pr-revise-tick.timer`  | 3 min | Poll PRs labeled `loop:revise` and file a coder fix task from the review comments. |

## Relationship to the rest of the repo

- **CT 122 `coder-runner`** (`coder-runner/`) is the execution sandbox these `*-on-runner` helpers drive over ssh+rsync.
- **CT 123 `gpu2`** (`pro-v620/create-lxc-llama-swap-gpu2.sh`) serves the coder/reviewer models the profiles point at.
- **CT 121 `hermes`** itself is provisioned by `hermes/create-lxc-hermes-agent.sh`; this folder is the loop config
  layered on top of that base container.
