#!/usr/bin/env python3
"""Offline checks for strata-cell.py and strata-summary.py; no GPU or lab services required."""
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


cell = load("strata_cell", HERE / "strata-cell.py")
strata_summary = load("strata_summary", HERE / "strata-summary.py")
text_repeat = load("text_repeat", HERE / "text-repeat.py")

GPU1, GPU2 = "0000:03:00.0", "0000:83:00.0"
# Start lines as the engine prints them (stage 2's split21 and helper cells).
SPLIT_LOG = (
    "strata generate: expert cache 8227 slots, 24.05 GiB of VRAM; policy is\n"
    "strata generate: layer split: CUDA1 runs layers 24-47, expert cache 7993 slots (23.32 GiB), "
    "7993 of its 12288 profiled pairs; slot 0 verified\n"
    "strata generate: token graph hit path: 16220 resident experts, decided on the device\n")
# The line Strata's server writes into the engine log for each engine it starts.
START = ("[strata] 2026-10-17 13:39:08 engine started: /opt/strata/strata-v0.1.44.1/build-hip/strata --serve "
         "--pack /models/strata/packs/ud-q4_k_xl\n")
HELPER_LOG = (
    "strata generate: expert cache 7921 slots, 23.12 GiB of VRAM; policy is\n"
    "strata generate: CUDA1: 10086 additional experts, 29.43 GiB; results return through pinned host rows\n")

# Maya's lines as its engine prints them (issue #156's report, one card; a split's second card).
MAYA_LOG = (
    "glm fast: CUDA0 layers [0,45) expert pool 7.04 GB, 25-32 slots/layer (1063 total)\n"
    "glm fast: CUDA0 RAM tier 78.03 GB pinned, 11779 slots\n"
    "glm fast: CUDA0 CPU lane: 16 threads, an expert 0.211 ms on the CPU vs 0.061 ms over PCIe -> of 0..8\n"
    "maya serve: CUDA0: 3114 MiB of VRAM free with everything loaded\n"
    "glm stat: decode 93.52 ms/tok (10.69 tok/s) | vram hit 50.39% | ram fetches 141.66/tok | disk 0.00 reads/tok "
    "in 7.41 waits/tok, 0.02 ms/tok | promotions 59.75/tok | cpu lane 14.05/tok in 6.04 ms/tok | prompt 123.8 "
    "ms/tok | vram 999/1063 ram 11045/11779\n"
    "glm stat: decode 106.49 ms/tok (9.39 tok/s) | vram hit 32.30% | ram fetches 187.46/tok | disk 0.00 reads/tok "
    "in 9.94 waits/tok, 0.02 ms/tok | promotions 62.65/tok | cpu lane 27.82/tok in 11.11 ms/tok | prompt 110.3 "
    "ms/tok | vram 1002/1063 ram 11039/11779\n"
    "glm spec: 120 of 160 drafts accepted (75.0%)\n")
MAYA_SPLIT_LOG = MAYA_LOG + (
    "glm fast: CUDA1 layers [24,45) expert pool 21.50 GB, 90-120 slots/layer (2310 total)\n"
    "glm fast: CUDA1 RAM tier 60.00 GB pinned, 9000 slots\n")


def reading(requested=29726, resident=29726):
    return {"requested": requested, "resident": resident, "evicted": 0}


def run_cell(engine_log="", res_load=None, res_probe=None, cards=(GPU2,), active=GPU2):
    """strata-cell.py on one cell, as strata-sweep.sh calls it; returns the cell's JSON."""
    res_load = {GPU2: reading()} if res_load is None else res_load
    res_probe = {GPU2: reading()} if res_probe is None else res_probe
    with tempfile.TemporaryDirectory() as directory:
        d = Path(directory)
        (d / "cell.json").write_text(json.dumps({"probe_ok": True, "summary": {}, "rows": []}))
        (d / "engine.log").write_text(engine_log)
        n = len(cards)
        argv = ["strata-cell.py", str(d / "cell.json"), "ctl", "{}", "25", ",".join(cards),
                " ".join(["29862"] * n), " ".join(["20"] * n), " ".join(["30704"] * n),
                " ".join(["29870"] * n), " ".join(["20"] * n), json.dumps(res_load), json.dumps(res_probe),
                "76000 73000 2000", "", str(d / "dimm"), str(d / "gpu"), str(d / "rows"), str(d / "conc"),
                "", str(d / "engine.log"), active]
        assert cell.main(argv) == 0
        return json.loads((d / "cell.json").read_text())


class CellTests(unittest.TestCase):
    def test_clean_cell_passes(self):
        out = run_cell()
        self.assertTrue(out["probe_ok"])
        self.assertEqual(out["placement"]["vram_outside_mib"], 0)
        self.assertEqual(out["placement"]["residency_missing"], [])
        self.assertEqual(out["placement"]["engine_faults"], 0)

    def test_stall_fails_the_cell(self):
        out = run_cell("strata serve: stall report: layer 12, 3 workers waiting\n")
        self.assertFalse(out["probe_ok"])
        self.assertEqual(out["placement"]["engine_faults"], 1)

    def test_a_hung_pipelined_window_fails_the_cell(self):
        out = run_cell(START + SPLIT_LOG +
                       "strata serve: pipelined decode: verify: the window never finished; its GPU waits were "
                       "released but the GPU did not finish within 5 s (#267)\n")
        self.assertFalse(out["probe_ok"])
        self.assertEqual(out["placement"]["engine_faults"], 1)

    def test_an_engine_restart_fails_the_cell(self):
        # The server replaced an engine that died: a second start line in the cell's engine log.
        # Its "the engine had stopped" goes to the journal, which strata-cell.py does not read.
        out = run_cell(START + SPLIT_LOG + START + SPLIT_LOG)
        self.assertFalse(out["probe_ok"])
        self.assertEqual(out["placement"]["strata"]["engine_restarts"], 1)
        self.assertEqual(out["placement"]["engine_faults"], 1)

    def test_one_engine_start_is_not_a_restart(self):
        out = run_cell(START + SPLIT_LOG)
        self.assertTrue(out["probe_ok"])
        self.assertEqual(out["placement"]["engine_faults"], 0)

    def test_pipeline_lines_are_kept(self):
        on = ("strata generate: --pipeline-windows 2: 160 MiB of CUDA0 kept out of the expert cache\n"
              "strata serve: --pipeline-windows 2: two verifiers per stage, 2 stages overlap across windows\n")
        account = cell.engine_account(SPLIT_LOG + on)
        self.assertEqual(len(account["pipeline_lines"]), 2)
        self.assertTrue(account["pipeline_lines"][1].startswith("--pipeline-windows 2: two verifiers"))
        self.assertEqual(account["stall_lines"], 0)

    def test_nonfinite_logits_fail_the_cell(self):
        out = run_cell("strata: non-finite logits at position 812\n")
        self.assertFalse(out["probe_ok"])
        self.assertEqual(out["placement"]["engine_faults"], 1)

    def test_no_residency_reading_is_unmeasured_not_zero(self):
        out = run_cell(res_load={}, res_probe={})
        pl = out["placement"]
        self.assertIsNone(pl["vram_outside_mib"])
        self.assertEqual(pl["residency_missing"], [GPU2 + " at load", GPU2 + " at probe"])
        self.assertFalse(out["probe_ok"])

    def test_a_counter_missing_at_one_checkpoint_is_unmeasured(self):
        out = run_cell(res_probe={GPU2: {"requested": 29726}})
        self.assertIsNone(out["placement"]["vram_outside_mib"])
        self.assertEqual(out["placement"]["residency_missing"], [GPU2 + " at probe"])
        self.assertFalse(out["probe_ok"])

    def test_a_passed_through_card_the_cell_leaves_unused_needs_no_reading(self):
        out = run_cell(cards=(GPU1, GPU2), active=GPU2)
        self.assertEqual(out["placement"]["residency_missing"], [])
        self.assertTrue(out["probe_ok"])

    def test_a_two_card_cell_needs_a_reading_from_each_card(self):
        out = run_cell(cards=(GPU1, GPU2), active="%s,%s" % (GPU2, GPU1))
        self.assertEqual(out["placement"]["residency_missing"], [GPU1 + " at load", GPU1 + " at probe"])
        self.assertFalse(out["probe_ok"])

    def test_requested_vram_outside_vram_is_a_spill(self):
        out = run_cell(res_probe={GPU2: reading(resident=29000)})
        self.assertEqual(out["placement"]["vram_outside_mib"], 726)
        self.assertTrue(out["placement"]["possible_gtt_spill"])

    def test_layer_split_cache_counts_both_cards(self):
        account = cell.engine_account(SPLIT_LOG)
        self.assertEqual({d: c["slots"] for d, c in account["expert_caches"].items()},
                         {"CUDA0": 8227, "CUDA1": 7993})
        self.assertEqual(account["expert_cache_slots_total"], 16220)

    def test_helper_cache_counts_the_helper_card(self):
        account = cell.engine_account(HELPER_LOG)
        self.assertEqual({d: c["slots"] for d, c in account["expert_caches"].items()},
                         {"CUDA0": 7921, "CUDA1": 10086})

    def test_maya_account(self):
        account = cell.engine_account(MAYA_LOG)
        self.assertEqual(account["engine"], "maya")
        self.assertEqual(account["expert_caches"], {"CUDA0": {"slots": 1063, "gb": 7.04, "role": "layers 0-44"}})
        self.assertEqual(account["ram_tier"], {"CUDA0": {"gb": 78.03, "slots": 11779}})
        self.assertEqual(account["vram_free_loaded_mib"], [3114])
        self.assertEqual(account["requests"], 2)
        self.assertEqual(account["decode_hit_pct_last"], 32.3)
        self.assertEqual(account["ram_fetches_per_tok_median"], 164.56)
        self.assertAlmostEqual(account["cpu_lane_per_tok_median"], 20.935, delta=0.006)
        self.assertEqual(account["disk_reads_per_tok_max"], 0.0)
        self.assertEqual(account["spec_accept_pct_median"], 75.0)

    def test_maya_split_counts_both_cards(self):
        account = cell.engine_account(MAYA_SPLIT_LOG)
        self.assertEqual(account["expert_cache_slots_total"], 3373)

    def test_maya_stall_and_nonfinite_fail_the_cell(self):
        out = run_cell(MAYA_LOG + "maya serve: stall report (engine 1234): stage \"layer 12\" for 95 s\n"
                       "glm router: layer 7 decode invalid expert ID or non-finite score\n")
        self.assertFalse(out["probe_ok"])
        self.assertEqual(out["placement"]["engine_faults"], 2)


class StrataSummaryTests(unittest.TestCase):
    def report(self, cells):
        with tempfile.TemporaryDirectory() as directory:
            for label, pl in cells:
                (Path(directory) / (label + "-r1.json")).write_text(json.dumps({"placement": dict(pl, label=label)}))
            out = io.StringIO()
            with patch.object(sys, "argv", ["strata-summary", directory]), contextlib.redirect_stdout(out):
                strata_summary.main()
            return out.getvalue()

    def test_two_card_cache_is_the_sum_of_both_cards(self):
        report = self.report([("split21", {"strata": cell.engine_account(SPLIT_LOG), "vram_outside_mib": 0})])
        self.assertIn("| 16220 (8227 + 7993) |", report)

    def test_missing_residency_reads_unmeasured(self):
        report = self.report([("ctl", {"strata": cell.engine_account(""), "vram_outside_mib": None,
                                       "residency_missing": [GPU2 + " at load"]})])
        self.assertIn("| unmeasured in 1 |", report)

    def test_maya_table(self):
        report = self.report([("2c", {"strata": cell.engine_account(MAYA_SPLIT_LOG), "vram_outside_mib": 0})])
        self.assertIn("## Maya engine", report)
        self.assertIn("| 3373 (1063 + 2310) |", report)
        self.assertIn("| 138.0 |", report)


class TextRepeatTests(unittest.TestCase):
    def run_tool(self, passes, against=None):
        """text-repeat.py over {cell: [[(depth, class, sha), ...] per pass]}; returns its table rows."""
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            for c, runs in passes.items():
                for n, rows in enumerate(runs, 1):
                    (d / ("%s-r%d.rows.jsonl" % (c, n))).write_text("".join(
                        json.dumps({"depth_target": depth, "class": cls, "content_sha": sha}) + "\n"
                        for depth, cls, sha in rows))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(text_repeat.main([str(d)] + (["--against", against] if against else [])), 0)
            return {line.split("|")[1].strip(): line for line in out.getvalue().splitlines()[2:]}

    def test_repeats_and_agreement(self):
        same = [(0, "code", "a"), (0, "list", "b")]
        table = self.run_tool({
            "miss": [same, same, same],
            "pw2": [[(0, "code", "a"), (0, "list", "b")], [(0, "code", "a"), (0, "list", "c")],
                    [(0, "code", "a"), (0, "list", "d")]],
            "pw2-frozen": [same, same, same],
        }, against="miss")
        self.assertIn("| 2 of 2 | 1 / 1 | 2 of 2 |", table["`pw2-frozen`"])
        # list varies in every pass: code still repeats and matches the reference, list counts for neither
        self.assertIn("| 1 of 2 | 2 / 3 | 1 of 2 |", table["`pw2`"])

    def test_a_cell_whose_label_contains_r_and_digits_keeps_its_passes(self):
        row = [(8000, "prose", "x")]
        table = self.run_tool({"s4p7-pw2-r2x": [row, row], "s4p7-pw2": [row, [(8000, "prose", "y")]]})
        self.assertIn("| 1 of 1 | 1 / 1 |", table["`s4p7-pw2-r2x`"])
        self.assertIn("| 0 of 1 | 2 / 2 |", table["`s4p7-pw2`"])


if __name__ == "__main__":
    unittest.main()
