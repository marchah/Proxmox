"""idea-capture Hermes plugin: Slack channel -> Project Planner board, without the agent.

A ``pre_gateway_dispatch`` hook. For a top-level message from an allowed user in
PROJECT_PLANNER_SLACK_CHANNEL it POSTs the text verbatim to ``<PROJECT_PLANNER_URL>/api/ideas``,
replies in the message's thread with the title and link the board returns, and tells the gateway
to skip the message so no agent turn runs. Everything else (thread replies, other channels, bots,
commands) passes through untouched.

Deterministic on purpose: an agent turn would have to rebuild arbitrary text inside a curl
command, takes 10-20 s, and dies with the local model when its prompt cache corrupts. The hook
runs synchronously on the gateway's inbound path, so the HTTP work happens on a thread.
"""

import json
import logging
import os
import re
import threading
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

logger = logging.getLogger("idea-capture")

BOARD_TIMEOUT_S = 20  # the board waits up to 10 s for a title, then saves untitled
SLACK_TIMEOUT_S = 10
SEEN_MAX = 500
# A plain message has no subtype; a message with an attachment is a file_share.
CAPTURED_SUBTYPES = {None, "file_share"}

_seen_lock = threading.Lock()


def _hermes_home() -> Path:
    return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


def _dotenv() -> dict:
    """Hermes' .env, for values the gateway keeps out of os.environ."""
    values = {}
    try:
        for line in (_hermes_home() / ".env").read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip().removeprefix("export ").strip()] = value.strip().strip("'\"")
    except OSError:
        pass
    return values


def _config() -> dict:
    env = {**_dotenv(), **{k: v for k, v in os.environ.items() if v}}
    return {
        "board_url": env.get("PROJECT_PLANNER_URL", "").rstrip("/"),
        "channel": env.get("PROJECT_PLANNER_SLACK_CHANNEL", ""),
        "bot_token": env.get("SLACK_BOT_TOKEN", ""),
        "allowed_users": {u.strip() for u in env.get("SLACK_ALLOWED_USERS", "").split(",") if u.strip()},
    }


def slack_to_plain(text: str) -> str:
    """Undo Slack's message encoding: ``<url|label>`` -> ``label (url)``, ``<url>`` -> ``url``."""
    text = re.sub(r"<((?:https?|mailto):[^|>]+)\|([^>]+)>", r"\2 (\1)", text)
    text = re.sub(r"<((?:https?|mailto):[^>]+)>", r"\1", text)
    text = text.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
    return text.strip()


def capture_target(event, config: dict):
    """The raw Slack message to capture, or None to let the gateway handle the event normally."""
    if not config["channel"] or not config["board_url"]:
        return None
    source = getattr(event, "source", None)
    raw = getattr(event, "raw_message", None)
    platform = getattr(getattr(source, "platform", None), "value", getattr(source, "platform", None))
    if str(platform).lower() != "slack" or not isinstance(raw, dict):
        return None
    if raw.get("channel", getattr(source, "chat_id", None)) != config["channel"]:
        return None
    if getattr(source, "is_bot", False) or raw.get("bot_id"):
        return None
    if raw.get("subtype") not in CAPTURED_SUBTYPES:
        return None  # joins, edits, deletions, bot posts…
    ts = raw.get("ts")
    if not ts or raw.get("thread_ts") not in (None, ts):
        return None  # thread replies go to the agent like anywhere else
    if str(getattr(getattr(event, "message_type", None), "value", "text")).lower() == "command":
        return None
    # The hook runs before Hermes' own authorization, so it has to apply the allowlist itself.
    if raw.get("user") not in config["allowed_users"]:
        return None
    return raw


def _seen_path() -> Path:
    return _hermes_home() / "idea-capture" / "seen.json"


def _claim(ts: str) -> bool:
    """Record ``ts`` as captured; False if it already was (Slack redelivers on reconnect)."""
    with _seen_lock:
        path = _seen_path()
        try:
            seen = json.loads(path.read_text())
        except (OSError, ValueError):
            seen = []
        if ts in seen:
            return False
        seen = (seen + [ts])[-SEEN_MAX:]
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(seen))
        tmp.replace(path)
        return True


def _http_json(url: str, *, data=None, headers=None, timeout: float):
    body = None if data is None else json.dumps(data).encode()
    request = urllib.request.Request(url, data=body, headers={"content-type": "application/json", **(headers or {})})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def _slack(method: str, token: str, **payload):
    result = _http_json(
        f"https://slack.com/api/{method}",
        data=payload,
        headers={"authorization": f"Bearer {token}", "content-type": "application/json; charset=utf-8"},
        timeout=SLACK_TIMEOUT_S,
    )
    if not result.get("ok"):
        raise RuntimeError(f"Slack {method}: {result.get('error')}")
    return result


def _permalink(token: str, channel: str, ts: str):
    try:
        query = urllib.parse.urlencode({"channel": channel, "message_ts": ts})
        request = urllib.request.Request(
            f"https://slack.com/api/chat.getPermalink?{query}", headers={"authorization": f"Bearer {token}"}
        )
        with urllib.request.urlopen(request, timeout=SLACK_TIMEOUT_S) as response:
            return json.load(response).get("permalink")
    except Exception:  # noqa: BLE001 - the link back to Slack is optional
        logger.warning("idea-capture: no permalink for %s", ts, exc_info=True)
        return None


def reply_text(idea=None, error=None) -> str:
    if error:
        return f":warning: Couldn't save this idea to the board ({error}). Repost it, or add it on the board."
    title = idea.get("title")
    link = f"<{idea['url']}|Open on the board>"
    if title:
        return f":pushpin: Saved: *{title}* · {link}"
    return f":pushpin: Saved, without a title for now (the title model didn't answer) · {link}"


def capture(raw: dict, config: dict, post=_http_json, slack=_slack, permalink=_permalink) -> None:
    channel, ts = config["channel"], raw["ts"]
    text = slack_to_plain(raw.get("text") or "")
    if not text:
        message = ":warning: Only text ideas can be saved for now."
    elif not _claim(ts):
        logger.info("idea-capture: %s already captured, skipping redelivery", ts)
        return
    else:
        try:
            payload = {"text": text, "source": "SLACK"}
            link = permalink(config["bot_token"], channel, ts)
            if link:
                payload["sourceUrl"] = link  # the board rejects null; absent means no link
            idea = post(f"{config['board_url']}/api/ideas", data=payload, timeout=BOARD_TIMEOUT_S)
            message = reply_text(idea=idea)
            logger.info("idea-capture: saved %s as idea %s", ts, idea.get("id"))
        except Exception as exc:  # noqa: BLE001 - every failure is reported in the thread
            reason = f"HTTP {exc.code}" if isinstance(exc, urllib.error.HTTPError) else type(exc).__name__
            logger.exception("idea-capture: saving %s failed", ts)
            message = reply_text(error=reason)
    try:
        slack("chat.postMessage", config["bot_token"], channel=channel, thread_ts=ts, text=message)
    except Exception:  # noqa: BLE001 - nothing else to tell; the log has it
        logger.exception("idea-capture: could not reply to %s", ts)


def _on_pre_gateway_dispatch(event=None, **_kwargs):
    try:
        config = _config()
        raw = capture_target(event, config)
    except Exception:  # noqa: BLE001 - never break the gateway's inbound path
        logger.exception("idea-capture: could not inspect event")
        return None
    if raw is None:
        return None
    threading.Thread(target=capture, args=(raw, config), name="idea-capture", daemon=True).start()
    return {"action": "skip", "reason": "idea-capture"}


def register(ctx) -> None:
    ctx.register_hook("pre_gateway_dispatch", _on_pre_gateway_dispatch)
