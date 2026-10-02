"""Run with: python3 -m unittest discover -s hermes/idea-capture/plugin"""

import json
import os
import tempfile
import unittest
import urllib.error
from types import SimpleNamespace

import __init__ as plugin

CHANNEL = "C0IDEAS"
CONFIG = {
    "board_url": "http://board:4200",
    "channel": CHANNEL,
    "bot_token": "xoxb-test",
    "allowed_users": {"U1"},
}


def event(*, channel=CHANNEL, user="U1", ts="100.1", thread_ts=None, text="an idea", platform="slack", **raw_extra):
    raw = {"channel": channel, "user": user, "ts": ts, "text": text, **raw_extra}
    if thread_ts:
        raw["thread_ts"] = thread_ts
    source = SimpleNamespace(platform=SimpleNamespace(value=platform), chat_id=channel, is_bot=False)
    return SimpleNamespace(source=source, raw_message=raw, message_type=SimpleNamespace(value="text"))


class CaptureTargetTest(unittest.TestCase):
    def test_captures_a_top_level_message_from_an_allowed_user(self):
        self.assertEqual(plugin.capture_target(event(), CONFIG)["ts"], "100.1")

    def test_captures_a_thread_root_and_a_message_with_an_attachment(self):
        self.assertIsNotNone(plugin.capture_target(event(thread_ts="100.1"), CONFIG))
        self.assertIsNotNone(plugin.capture_target(event(subtype="file_share"), CONFIG))

    def test_passes_everything_else_through(self):
        cases = {
            "thread reply": event(thread_ts="99.0"),
            "other channel": event(channel="C0OTHER"),
            "other platform": event(platform="discord"),
            "user not allowed": event(user="U2"),
            "bot post": event(bot_id="B1"),
            "edit": event(subtype="message_changed"),
            "join": event(subtype="channel_join"),
        }
        for name, ev in cases.items():
            with self.subTest(name):
                self.assertIsNone(plugin.capture_target(ev, CONFIG))
        command = event()
        command.message_type = SimpleNamespace(value="command")
        self.assertIsNone(plugin.capture_target(command, CONFIG))

    def test_is_off_until_configured_and_fails_closed_without_an_allowlist(self):
        self.assertIsNone(plugin.capture_target(event(), {**CONFIG, "channel": ""}))
        self.assertIsNone(plugin.capture_target(event(), {**CONFIG, "board_url": ""}))
        self.assertIsNone(plugin.capture_target(event(), {**CONFIG, "allowed_users": set()}))


class SlackToPlainTest(unittest.TestCase):
    def test_unwraps_links_and_entities(self):
        self.assertEqual(
            plugin.slack_to_plain("see <https://x.dev/a|the docs> and <https://y.dev> &amp; a &lt;tag&gt;"),
            "see the docs (https://x.dev/a) and https://y.dev & a <tag>",
        )


class CaptureTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        os.environ["HERMES_HOME"] = self.home.name
        self.posts, self.replies = [], []

    def tearDown(self):
        self.home.cleanup()
        del os.environ["HERMES_HOME"]

    def run_capture(self, raw, post_result=None, post_error=None, link="https://slack/p100"):
        def post(url, *, data, timeout):
            self.posts.append((url, data))
            if post_error:
                raise post_error
            return post_result

        def slack(method, token, **payload):
            self.replies.append((method, payload))

        plugin.capture(raw, CONFIG, post=post, slack=slack, permalink=lambda *_: link)

    def test_posts_the_text_and_replies_with_title_and_link(self):
        raw = event(text="ping me when <https://shop.dev|groceries> get cheaper").raw_message
        self.run_capture(raw, post_result={"id": "i1", "title": "Grocery Price Alerts", "url": "http://b/?idea=i1"})
        self.assertEqual(self.posts, [(
            "http://board:4200/api/ideas",
            {"text": "ping me when groceries (https://shop.dev) get cheaper", "source": "SLACK", "sourceUrl": "https://slack/p100"},
        )])
        method, payload = self.replies[0]
        self.assertEqual((method, payload["channel"], payload["thread_ts"]), ("chat.postMessage", CHANNEL, "100.1"))
        self.assertIn("*Grocery Price Alerts*", payload["text"])
        self.assertIn("<http://b/?idea=i1|Open on the board>", payload["text"])

    def test_leaves_out_the_slack_link_when_there_is_none(self):
        self.run_capture(event().raw_message, post_result={"id": "i1", "title": "T", "url": "u"}, link=None)
        self.assertEqual(self.posts[0][1], {"text": "an idea", "source": "SLACK"})

    def test_says_so_when_the_idea_has_no_title(self):
        self.run_capture(event().raw_message, post_result={"id": "i1", "title": None, "url": "http://b/?idea=i1"})
        self.assertIn("without a title", self.replies[0][1]["text"])

    def test_reports_a_board_failure_in_the_thread(self):
        error = urllib.error.HTTPError("http://board", 503, "down", {}, None)
        self.run_capture(event().raw_message, post_error=error)
        self.assertIn("Couldn't save", self.replies[0][1]["text"])
        self.assertIn("HTTP 503", self.replies[0][1]["text"])

    def test_a_redelivered_message_is_saved_once(self):
        raw = event().raw_message
        result = {"id": "i1", "title": "T", "url": "u"}
        self.run_capture(raw, post_result=result)
        self.run_capture(raw, post_result=result)
        self.assertEqual(len(self.posts), 1)
        self.assertEqual(len(self.replies), 1)
        self.assertEqual(json.loads((plugin._seen_path()).read_text()), ["100.1"])

    def test_an_attachment_without_text_is_not_posted(self):
        self.run_capture(event(text="", subtype="file_share").raw_message)
        self.assertEqual(self.posts, [])
        self.assertIn("Only text ideas", self.replies[0][1]["text"])


class HookTest(unittest.TestCase):
    def test_skips_dispatch_only_for_captured_messages(self):
        started = []
        original_config, original_thread = plugin._config, plugin.threading.Thread
        plugin._config = lambda: CONFIG
        plugin.threading.Thread = lambda target, args, **_: SimpleNamespace(start=lambda: started.append(args))
        try:
            self.assertEqual(plugin._on_pre_gateway_dispatch(event=event())["action"], "skip")
            self.assertIsNone(plugin._on_pre_gateway_dispatch(event=event(thread_ts="99.0")))
            self.assertIsNone(plugin._on_pre_gateway_dispatch(event=None))
        finally:
            plugin._config, plugin.threading.Thread = original_config, original_thread
        self.assertEqual(len(started), 1)


if __name__ == "__main__":
    unittest.main()
