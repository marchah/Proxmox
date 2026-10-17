#!/usr/bin/env python3
"""Offline checks for maya-gate.py's score and check-ref steps; no GPU, engine or systemd required."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
GATE = HERE / "maya-gate.py"
spec = importlib.util.spec_from_file_location("maya_gate", GATE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

N, CTX, K = 100, 10, 4
SCORE = ("SCORE %d tokens: nll 1.79 ppl 6.01 top1 60.0%% | vs ref: KL 0.030000 (max 1.0), same top token "
         "92.00%% | 90.0 ms/token | cpu lane 100 experts, vram hit 50.00%%\n")
# systemd-run as the score step calls it: writes STUB_TEXT to its StandardOutput target and exits
# STUB_RC. It opens the target without truncating, as systemd's file: does.
STUB = """#!%s
import os, sys
for a in sys.argv:
    if a.startswith("StandardOutput="):
        path = a.split(":", 1)[1]
        fd = os.open(path, os.O_WRONLY | os.O_CREAT)
        os.write(fd, os.environ["STUB_TEXT"].encode())
        os.close(fd)
sys.exit(int(os.environ["STUB_RC"]))
""" % sys.executable


class Score(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        (self.d / "bin").mkdir()
        stub = self.d / "bin" / "systemd-run"
        stub.write_text(STUB)
        stub.chmod(0o755)
        (self.d / "config.json").write_text(json.dumps(
            {"exe": "/bin/true", "args": ["--glm-pack", "x"], "gpu": [0], "cwd": ".", "lib_dirs": []}))
        (self.d / "tokens.json").write_text(json.dumps({"tokens": list(range(N))}))
        self.out = self.d / "ud-maya"
        # an earlier run that passed
        Path(str(self.out) + ".out").write_text("INFO a longer header line from the earlier run\n" + SCORE % (N - 1 - CTX))
        Path(str(self.out) + ".json").write_text(json.dumps({"kl": 0.03}))
        self.addCleanup(shutil.rmtree, self.d)

    def score(self, rc, text):
        env = dict(os.environ, PATH="%s:%s" % (self.d / "bin", os.environ["PATH"]), STUB_RC=str(rc), STUB_TEXT=text)
        return subprocess.run([sys.executable, str(GATE), "score", "--config", str(self.d / "config.json"),
                               "--pack", "p", "--tokens", str(self.d / "tokens.json"), "--ctx", str(CTX),
                               "--topk", "t", "--out", str(self.out)], env=env, capture_output=True, text=True)

    def result(self):
        p = Path(str(self.out) + ".json")
        return json.loads(p.read_text()) if p.exists() else None

    def test_failed_launch_does_not_reuse_an_earlier_score(self):
        r = self.score(1, "")
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(self.result())

    def test_crash_before_the_score_does_not_reuse_an_earlier_score(self):
        r = self.score(0, "INFO\n")
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(self.result())

    def test_engine_failure_after_the_score_line_fails(self):
        r = self.score(2, SCORE % (N - 1 - CTX))
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(self.result())

    def test_a_short_score_fails(self):
        r = self.score(0, SCORE % (N - 2 - CTX))
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(self.result())

    def test_a_complete_score_is_written(self):
        r = self.score(0, SCORE % (N - 1 - CTX))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.result()["positions"], N - 1 - CTX)


class CheckRef(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.d)
        self.shards = [self.d / ("m-%05d-of-00002.gguf" % i) for i in (1, 2)]
        for s in self.shards:
            s.write_bytes(b"weights")
        self.dump = self.d / "llm_logits_dump"
        self.dump.write_bytes(b"build 1")
        self.tokens = self.d / "tokens.json"
        self.tokens.write_text(json.dumps({"tokens": list(range(N))}))
        self.ref = str(self.d / "ud-ref")
        # a reference as gate.reference leaves it
        Path(self.ref + ".topk").write_bytes(b"\0" * gate.topk_bytes(N, CTX, K))
        Path(self.ref + ".json").write_text("{}")
        m = gate.ref_inputs(self.args(), with_build=True)
        m["topk_bytes"] = gate.topk_bytes(N, CTX, K)
        gate.write_json(self.ref + ".manifest.json", m)

    def args(self, **kw):
        a = dict(model=str(self.shards[0]), dump=str(self.dump), tokens=str(self.tokens), ctx=CTX, k=K)
        a.update(kw)
        return argparse.Namespace(**a)

    def check(self, build=True, ctx=CTX):
        cmd = [sys.executable, str(GATE), "check-ref", "--ref", self.ref, "--tokens", str(self.tokens),
               "--ctx", str(ctx), "--k", str(K)]
        if build:
            cmd += ["--model", str(self.shards[0]), "--dump", str(self.dump)]
        return subprocess.run(cmd, capture_output=True, text=True).returncode

    def test_the_same_inputs_reuse_it(self):
        self.assertEqual(self.check(), 0)

    def test_another_shard_with_the_same_tokens_invalidates_it(self):
        self.shards[1].write_bytes(b"other weights")
        self.assertNotEqual(self.check(), 0)

    def test_a_rebuilt_dumper_with_the_same_tokens_invalidates_it(self):
        self.dump.write_bytes(b"build 2")
        self.assertNotEqual(self.check(), 0)

    def test_other_tokens_or_ctx_invalidate_it(self):
        self.assertNotEqual(self.check(ctx=CTX + 1), 0)
        self.tokens.write_text(json.dumps({"tokens": list(range(1, N + 1))}))
        self.assertNotEqual(self.check(), 0)

    def test_a_partial_topk_file_invalidates_it(self):
        Path(self.ref + ".topk").write_bytes(b"\0" * 12)
        self.assertNotEqual(self.check(), 0)

    def test_a_missing_manifest_invalidates_it(self):
        os.unlink(self.ref + ".manifest.json")
        self.assertNotEqual(self.check(), 0)

    def test_the_cross_check_compares_tokens_and_settings_only(self):
        self.shards[1].write_bytes(b"other weights")
        self.assertEqual(self.check(build=False), 0)
        self.assertNotEqual(self.check(build=False, ctx=CTX + 1), 0)


if __name__ == "__main__":
    unittest.main()
