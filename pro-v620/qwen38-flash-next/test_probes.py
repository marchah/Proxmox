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


def row(rate=14):
    return {"decode_tps": rate, "prefill_tps": 300, "prompt_n": 30,
            "predicted_n": 256, "content_sha": "same", "degenerate": False,
            "accept_pct": None}


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
