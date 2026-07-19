"""codex-review Hermes plugin — registers the /codex-review slash command.

Deterministic, zero-LLM: the slash handler simply spawns /usr/local/bin/codex-review <pr#> detached
(a real Codex review takes minutes, longer than the 120s ephemeral-reply TTL) and returns an immediate
ephemeral ack. The engine posts the verdict to #coding + the PR itself when it finishes.
"""

import os
import subprocess

CODEX_REVIEW_BIN = "/usr/local/bin/codex-review"


def _handle_codex_review(raw_args: str):
    # Pass tokens straight through as argv: <pr#|branch> [repo]. codex-review defaults repo to mealdeal.
    parts = (raw_args or "").strip().split()
    if not parts:
        return (
            "Usage: `/hermes codex-review <pr#|branch> [repo]` "
            "(e.g. `/hermes codex-review 9`, or `/hermes codex-review 12 otherapp`)."
        )
    parts[0] = parts[0].lstrip("#") or parts[0]
    argv = parts[:2]
    try:
        subprocess.Popen(
            [CODEX_REVIEW_BIN, *argv],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,  # detach: survive the handler returning; no TTL race
        )
    except Exception as exc:  # noqa: BLE001 - surface any spawn failure to the user
        return f"❌ Failed to start Codex review for `{' '.join(argv)}`: {exc}"
    ch = os.environ.get("SLACK_CODING_CHANNEL", "")
    where = f"<#{ch}>" if ch else "#coding"
    return (
        f"🔎 Codex review started for `{' '.join(argv)}` — the verdict will post to {where} "
        "in a few minutes."
    )


def register(ctx) -> None:
    ctx.register_command(
        "codex-review",
        handler=_handle_codex_review,
        description="Run an on-demand Codex (ChatGPT) review of a PR (default repo mealdeal); verdict posts to #coding.",
        args_hint="<pr#> [repo]",
    )
