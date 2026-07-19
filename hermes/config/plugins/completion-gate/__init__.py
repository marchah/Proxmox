"""completion-gate — preventive false-completion guard for the coding loop.

Ornith (and small local coders generally) sometimes edit files then call `kanban_complete` WITHOUT
running `verify-and-commit`, so the task is marked done with no commit. The reactive post-completion
audit can't fix that (Hermes won't `block` a task that's already `done`). This pre_tool_call hook stops
it at the source: it BLOCKS the `kanban_complete` tool call itself when the task's worktree branch has
0 commits ahead of main, returning a message that tells the coder to verify-and-commit first. The model
gets immediate feedback and retries in the SAME run — no re-queue thrash.

Scope: only fires for tasks that HAVE a worktree branch (coder tasks). Reviewer/dir-workspace tasks have
no HERMES_KANBAN_BRANCH, so they're never gated. Fails OPEN (returns None) on any error/uncertainty so it
can never wedge a legitimate completion.
"""
import os
import subprocess

_REPO = os.environ.get("COMPLETION_GATE_REPO", "/root/repos/mealdeal")


def _commits_ahead(branch: str) -> int:
    """Commits on `branch` not on main. -1 = unknown (→ fail open)."""
    try:
        out = subprocess.run(
            ["git", "-C", _REPO, "rev-list", "--count", f"main..{branch}"],
            capture_output=True, text=True, timeout=10,
        )
        if out.returncode != 0:
            return -1
        return int((out.stdout or "").strip() or "0")
    except Exception:
        return -1


def _on_pre_tool_call(tool_name: str = "", args=None, **_):
    if tool_name != "kanban_complete":
        return None
    branch = os.environ.get("HERMES_KANBAN_BRANCH", "").strip()
    if not branch:
        return None  # no worktree branch (reviewer / dir task) → not a coder commit gate
    if _commits_ahead(branch) == 0:
        return {
            "action": "block",
            "message": (
                f"BLOCKED: you cannot call kanban_complete yet — branch '{branch}' has 0 commits ahead "
                "of main, which means `verify-and-commit .` has NOT committed anything. Run "
                "`verify-and-commit .` now and wait for the '[verify-and-commit] committed <sha> on "
                "<branch>' line BEFORE calling kanban_complete. If verify-and-commit exits non-zero, read "
                "its output and fix the CODE (never fake done). If you genuinely cannot get it green, call "
                "kanban_block with the failing output instead."
            ),
        }
    return None  # real commit present, or unknown → allow


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
