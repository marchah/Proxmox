#!/usr/bin/env python3
"""Offline regression checks for benchmark gates; no GPU or lab services required."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


probe = load("placement_probe", HERE / "placement-probe.py")
concurrency = load("concurrency_probe", HERE / "concurrency-probe.py")
summary = load("sweep_summary", HERE / "summarize-sweep.py")
turns = load("turn_probe", HERE / "turn-probe.py")


def row(rate=14):
    return {"decode_tps": rate, "prefill_tps": 300, "prompt_n": 30,
            "predicted_n": 256, "content_sha": "same", "degenerate": False,
            "accept_pct": None}


def char_tokenizer(url, body, *args):
    """/tokenize and /detokenize at one token per character."""
    if url.endswith("/tokenize"):
        return {"tokens": [ord(c) for c in body["content"]]}
    if url.endswith("/detokenize"):
        return {"content": "".join(chr(t) for t in body["tokens"])}
    raise AssertionError("unexpected request to " + url)


def run_probe(*args):
    out = io.StringIO()
    with patch.object(sys, "argv", ["probe", "http://unused", *args]), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        status = probe.main()
    return status, json.loads(out.getvalue())


class ProbeTests(unittest.TestCase):
    def test_even_overall_median(self):
        rates = [19.39, 19.56, 16.68, 20.97, 16.35, 16.25]
        with patch.object(probe, "one", side_effect=[row(r) for r in rates]):
            status, data = run_probe("--reps", "1", "--depths", "0,8000")
        self.assertEqual(status, 0)
        self.assertEqual(data["decode_tps_overall_median"], 18.04)

    def test_even_rep_median(self):
        with patch.object(probe, "one", side_effect=[row(10), row(20)]):
            status, data = run_probe("--reps", "2", "--classes", "code")
        self.assertEqual(status, 0)
        self.assertEqual(data["summary"]["d0/code"]["decode_tps_median"], 15)

    def test_failed_request_preserves_rows_and_fails_gate(self):
        with patch.object(probe, "one", side_effect=[row(), TimeoutError("timeout"), row()]):
            status, data = run_probe("--reps", "1")
        self.assertEqual(status, 1)
        self.assertEqual(data["failed_requests"], 1)
        self.assertEqual(len(data["rows"]), 3)
        self.assertFalse(data["probe_ok"])
        self.assertFalse(data["all_reps_agree"])

    def test_all_failed_requests_cannot_pass(self):
        with patch.object(probe, "one", side_effect=TimeoutError("timeout")):
            status, data = run_probe("--reps", "1")
        self.assertEqual(status, 1)
        self.assertEqual(data["failed_requests"], 3)
        self.assertFalse(data["all_reps_agree"])
        self.assertIsNone(data["decode_tps_overall_median"])

    def test_reasoning_leak_fails_contract(self):
        contract = {"bare_chat": {"ok": True, "reasoning_chars": 12}}
        with patch.object(probe, "one", return_value=row()), \
                patch.object(probe, "contract_check", return_value=contract):
            status, data = run_probe("--reps", "1", "--contract")
        self.assertEqual(status, 1)
        self.assertFalse(data["contract_ok"])

    def test_cached_context_runs_deepest_first_and_nests(self):
        calls = []

        def record(base, prompt, n_predict, *args):
            calls.append(prompt)
            return row()

        with tempfile.NamedTemporaryFile("w", suffix=".txt") as ctx:
            ctx.write("".join("line %05d of the repository text\n" % i for i in range(20000)))
            ctx.flush()
            with patch.object(probe, "one", side_effect=record), \
                    patch.object(probe, "post", side_effect=char_tokenizer):
                status, data = run_probe("--reps", "1", "--classes", "code", "--cache",
                                         "--depths", "8000,32000", "--context-file", ctx.name)
        self.assertEqual(status, 0)
        self.assertEqual(len(calls), 2)
        deep, shallow = (c.split("\n</documents>")[0] for c in calls)
        self.assertGreater(len(deep), len(shallow))
        self.assertTrue(deep.startswith(shallow))
        self.assertEqual([r["depth_target"] for r in data["rows"]], [32000, 8000])
        self.assertEqual(len(shallow) - len("<documents>\n"), 8000)

    def test_context_shorter_than_depth_stops_the_probe(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt") as ctx:
            ctx.write("short text")
            ctx.flush()
            with patch.object(probe, "post", side_effect=char_tokenizer), \
                    self.assertRaises(SystemExit):
                run_probe("--reps", "1", "--depths", "8000", "--context-file", ctx.name)

    def test_n_predict_list_gives_one_key_per_length(self):
        with patch.object(probe, "one", side_effect=[row(), row()]):
            status, data = run_probe("--reps", "1", "--classes", "code", "--n-predict", "256,640")
        self.assertEqual(status, 0)
        self.assertEqual(sorted(data["summary"]), ["d0/code/n256", "d0/code/n640"])

    def test_cached_rows_do_not_count_as_prefill(self):
        cached = dict(row(), prefill_tps=5000, prompt_n=20, cache_n=8000)
        with patch.object(probe, "one", side_effect=[cached]):
            status, data = run_probe("--reps", "1", "--classes", "code", "--cache")
        self.assertEqual(status, 0)
        self.assertIsNone(data["summary"]["d0/code"]["prefill_tps_median"])
        self.assertEqual(data["summary"]["d0/code"]["prompt_n"], 8020)

    def test_greedy_and_server_sampling_bodies(self):
        bodies = []

        def capture(url, body):
            bodies.append(body)
            return {"choices": [{"message": {"content": "some answer text"}, "finish_reason": "length"}],
                    "timings": {"predicted_per_second": 9}}

        with patch.object(probe, "post", side_effect=capture):
            probe.one("http://unused", "p", 16, chat=True)
            probe.one("http://unused", "p", 16, chat=True, cache=True, sampling="server", seed=7)
        self.assertEqual((bodies[0]["temperature"], bodies[0]["top_k"]), (0, 1))
        self.assertFalse(bodies[0]["cache_prompt"])
        self.assertNotIn("temperature", bodies[1])
        self.assertNotIn("top_k", bodies[1])
        self.assertEqual(bodies[1]["seed"], 7)
        self.assertTrue(bodies[1]["cache_prompt"])

    def test_server_sampling_may_differ_across_reps_but_greedy_may_not(self):
        rows = [dict(row(), content_sha="a"), dict(row(), content_sha="b")]
        with patch.object(probe, "one", side_effect=list(rows)):
            status, data = run_probe("--reps", "2", "--classes", "code", "--sampling", "server")
        self.assertEqual(status, 0)
        self.assertFalse(data["all_reps_agree"])
        with patch.object(probe, "one", side_effect=list(rows)):
            status, data = run_probe("--reps", "2", "--classes", "code")
        self.assertEqual(status, 1)

    def run_turns(self, responder, *args):
        with tempfile.NamedTemporaryFile("w", suffix=".txt") as ctx:
            ctx.write("".join("line %05d of the repository text\n" % i for i in range(20000)))
            ctx.flush()
            out = io.StringIO()
            with patch.object(turns, "request", side_effect=responder), \
                    patch.object(turns, "post", side_effect=char_tokenizer), \
                    patch.object(sys, "argv", ["turns", "http://unused", "--context-file", ctx.name,
                                               "--depth", "2000", "--sizes", "32,256", *args]), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                status = turns.main()
        return status, json.loads(out.getvalue())

    def test_turn_fit_separates_fixed_and_per_token_cost(self):
        self.assertEqual(turns.fit([(100, 7.0), (200, 7.5), (300, 8.0)]),
                         {"fixed_s": 6.5, "per_token_ms": 5.0})
        self.assertIsNone(turns.fit([(100, 7.0), (100, 7.2)]))

    def test_turn_chunks_rotate_and_never_repeat(self):
        prompts, caches = [], []

        def responder(base, prompt, n_predict, chat, cache=True):
            prompts.append(prompt)
            caches.append(cache)
            new = 2000 if len(prompts) == 1 else 40
            return {"prompt_n": new, "cache_n": 0 if len(prompts) == 1 else 2000,
                    "prompt_ms": 7000.0, "prefill_tps": 5.0}

        status, data = self.run_turns(responder, "--reps", "2")
        self.assertEqual(status, 0)
        self.assertEqual([r["size_target"] for r in data["rows"]], [32, 256, 256, 32])
        self.assertEqual(len(set(prompts)), len(prompts))
        self.assertTrue(all(p.startswith(prompts[0].split("\n</documents>")[0]) for p in prompts))
        # The prime prefills cold, whatever an earlier probe left in the slot; turns reuse it.
        self.assertEqual(caches, [False, True, True, True, True])

    def test_turn_cache_miss_fails_the_probe(self):
        def responder(base, prompt, n_predict, chat, cache=True):
            return {"prompt_n": 2000, "cache_n": 0, "prompt_ms": 30000.0, "prefill_tps": 66.0}

        status, data = self.run_turns(responder, "--reps", "1")
        self.assertEqual(status, 1)
        self.assertEqual(data["failed_requests"], 2)
        self.assertIn("cache served", data["rows"][0]["error"])

    def test_empty_output_and_nonfinite_timing_are_errors(self):
        for content, rate in [("", 14), ("valid text", float("inf"))]:
            response = {"content": content, "timings": {"predicted_per_second": rate}}
            for module in (probe, concurrency):
                with self.subTest(module=module.__name__, content=content), \
                        patch.object(module, "post", return_value=response):
                    self.assertIn("error", module.one("http://unused", "prompt", 256))

    def test_empty_stream_is_not_a_complete_round(self):
        def response(url, body):
            content = "" if "stream 1" in body["prompt"] else "one two three four five six seven eight nine"
            return {"content": content, "timings": {
                "predicted_per_second": 14, "predicted_n": 256}}

        out = io.StringIO()
        with patch.object(concurrency, "post", side_effect=response), \
                patch.object(concurrency, "server_props", return_value={"total_slots": 2}), \
                patch.object(sys, "argv", ["probe", "http://unused", "2", "--reps", "1"]), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            status = concurrency.main()
        data = json.loads(out.getvalue())
        self.assertEqual(status, 1)
        self.assertEqual(data["complete_rounds"], 0)
        self.assertEqual(data["total_failed"], 1)
        self.assertEqual(data["aggregate_tps"], 0)
        self.assertIsNone(data["accept_pct"])

    def test_summary_reports_later_contract_failure_and_legacy_row_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for label, contract in [("control", {"bare_chat": {"ok": True}}),
                                    ("mtp", {"bare_chat": {"ok": False}}),
                                    ("valid", {"bare_chat": {"ok": True}})]:
                (root / (label + "-r1.json")).write_text(json.dumps({
                    "placement": {"label": label}, "summary": {"d0/code": {
                        "decode_tps_median": 99 if label == "mtp" else 14}}, "contract": contract}))
            (root / "legacy-r1.json").write_text(json.dumps({
                "placement": {"label": "legacy"}, "rows": [{"error": "timeout"}],
                "summary": {}, "all_reps_agree": True}))
            out = io.StringIO()
            with patch.object(sys, "argv", ["summary", directory]), contextlib.redirect_stdout(out):
                summary.main()
            report = out.getvalue()
        self.assertIn("chat contract failed in 1 pass(es)", report)
        self.assertIn("1 probe error(s)", report)
        self.assertIn("| mtp | 1/1 | 0 | `mtp-r1.json`: bare_chat |", report)
        self.assertIn("| legacy | 0/1 | 0 | not checked |", report)
        self.assertIn("Reference: `control`", report)
        self.assertNotIn("Reference: `mtp`", report)

    def test_summary_prints_turns_and_flags_uncached_passes(self):
        turn = {"context_tokens": 30000, "summary": {"32": {"prompt_s_median": 2.3},
                                                     "256": {"prompt_s_median": 7.6}},
                "fit": {"fixed_s": 6.8, "per_token_ms": 6.2}, "failed_requests": 0}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for label, t in [("thr32", turn), ("thr256", dict(turn, failed_requests=2))]:
                (root / (label + "-r1.json")).write_text(json.dumps({
                    "placement": {"label": label, "turns": t},
                    "summary": {"d0/code": {"decode_tps_median": 9}}}))
            out = io.StringIO()
            with patch.object(sys, "argv", ["summary", directory]), contextlib.redirect_stdout(out):
                summary.main()
            report = out.getvalue()
        self.assertIn("## Turns", report)
        self.assertIn("| thr32 | 30000 | 2.30 | 7.60 | 6.80 | 6.20 | ok |", report)
        self.assertIn("🔴 2 failed or uncached request(s)", report)

    def test_fixed_salt_pairs_cold_chat_requests_across_runs(self):
        scripts = HERE.parents[1] / "bench-runner/scripts/benchmarks"
        with patch.object(sys, "path", [str(scripts), *sys.path]):
            api = load("openai_api", scripts / "benchmark-openai-api.py")
        requests = []

        def response(request, **kwargs):
            requests.append(json.loads(request.data))
            payload = {"choices": [{"message": {"content": "Hello!"}}],
                       "usage": {"prompt_tokens": 30, "completion_tokens": 3},
                       "timings": {"prompt_n": 30, "prompt_ms": 100,
                                   "predicted_n": 3, "predicted_ms": 200}}
            result = io.BytesIO(json.dumps(payload).encode())
            result.status = 200
            return result

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(api.urllib.request, "urlopen", side_effect=response):
            for label in ("control", "mtp"):
                args = ["api", "--base-url", "http://unused/v1", "--model", "qwen",
                        "--output-dir", str(Path(directory) / label), "--scenario", "smoke",
                        "--requests", "2", "--prompt-salt", "paired", "--no-stream"]
                with patch.object(sys, "argv", args), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(api.main(), 0)
                manifest = json.loads((Path(directory) / label / "openai-direct-manifest.json").read_text())
                self.assertEqual(manifest["prompt_salt"], "paired")
                self.assertFalse(manifest["cache_prompt"])
            # The default path stays compatible with providers that reject extensions.
            with patch.dict(api.os.environ, {}, clear=True), \
                    patch.object(sys, "argv", args[:-3] + ["--no-stream"]), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(api.main(), 0)
        self.assertEqual([r["messages"] for r in requests[:2]], [r["messages"] for r in requests[2:4]])
        self.assertNotEqual(requests[0]["messages"], requests[1]["messages"])
        self.assertTrue(all(r["cache_prompt"] is False for r in requests[:4]))
        self.assertTrue(all("cache_prompt" not in r for r in requests[4:]))


if __name__ == "__main__":
    unittest.main()
