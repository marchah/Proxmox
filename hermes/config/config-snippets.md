# `config.yaml` snippets — merge these into the SHARED `/root/.hermes/config.yaml` by hand

`install.sh` deploys the **per-profile** `config.yaml` (coder / reviewer) but deliberately does **not** touch
the top-level `/root/.hermes/config.yaml` — that file is owned by the gateway and also holds your Discord/Slack/KB
wiring, `api_key`s, and other unrelated settings. The blocks below are the **loop-relevant parts only**; add/merge
them into your existing `config.yaml`, then `systemctl restart hermes`.

Channel IDs are shown as `<SLACK_..._CHANNEL>` placeholders — substitute your real `C0…` IDs (the same ones you
put in `/root/.hermes/.env`; see `hermes.env.example`). Unlike the `bin/` scripts, `config.yaml` is **not committed**,
so its `channel_prompts` keys are literal IDs in your live file — the placeholders here are just so this doc stays
secret-free.

## 1. Serialize the dispatcher (one worker at a time)

The single 32 GB GPU-2 card holds **one** model resident at a time (llama-swap hot-swaps coder⇄reviewer), so the
kanban dispatcher must run strictly one task at a time — otherwise a coder and reviewer would fight over the GPU and
thrash the swap. This is the linchpin of the whole loop.

```yaml
kanban:
  max_in_progress: 1
  max_spawn: 1
```

## 2. Enable the two loop plugins

```yaml
plugins:
  enabled:
    - codex-review        # /codex-review <pr#> slash command (see plugins/codex-review/)
    - completion-gate     # preventive false-completion guard (see plugins/completion-gate/)
  disabled: []
  entries:
    codex-review:
      allow_tool_override: false
    completion-gate:
      allow_tool_override: false
```

## 3. Slack channel routing (`channel_prompts`)

The planner lane lives in Slack: a project-planning channel drives the `scope-and-plan` skill; the coding channel is
where PR-ready notices + Codex verdicts land; the automation channel is where the watchdog + KB crons report. Only the
three loop/automation channels are shown here — keep your other channels' prompts as they are.

```yaml
slack:
  require_mention: false
  channel_prompts:
    <SLACK_PLANNING_CHANNEL>: 'Purpose: project planning. When a user gives a project idea and rough features,
      act as the project planner using the scope-and-plan skill: read the target repo AGENTS.md, ask clarifying
      questions, then write the plan plus backlog and run finalize-plan to open a plan PR and file the blocked
      feature backlog. Do not release the backlog until the user approves; then run release-backlog. Never write
      feature code yourself.'
    <SLACK_CODING_CHANNEL>: 'Purpose: software engineering and code review. Inspect existing code first, follow
      repository conventions, make focused changes, and verify results.'
    <SLACK_AUTOMATION_CHANNEL>: 'Purpose: recurring jobs, scripts, and agent workflows. Prioritize reliability,
      observability, idempotency, and clear failure reporting.'
```

## 4. Model pointers (already in the committed per-profile `config.yaml`)

For reference — `install.sh` deploys these, no hand-merge needed. Both point at the GPU-2 llama-swap server
(`http://gpu2:8080/v1`), which serves the aliases by name (provisioned by
`pro-v620/create-lxc-llama-swap-gpu2.sh`):

| Profile  | `model.default`        | ctx     | Notes |
|----------|------------------------|---------|-------|
| coder    | `qwen3-instruct-2507`  | 65536   | Qwen3-30B-A3B-Instruct-2507; trimmed toolset (terminal/kanban/skills/file/todo) |
| reviewer | `qwen3-coder-reviewer` | 65536   | Qwen3-Coder-30B-A3B-Instruct; non-thinking, so no runaway-reasoning budget exhaustion |
| planner  | (default ops model)    | —       | runs the `scope-and-plan` skill in the planning channel; no dedicated profile |

The coder profile also wires the false-completion audit hook (`kanban_task_completed → coder-commit-audit`) and the
completion-gate plugin covers the preventive side; see `profiles/coder/config.yaml`.
