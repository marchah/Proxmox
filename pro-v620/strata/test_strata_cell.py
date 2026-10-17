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

GPU1, GPU2 = "0000:03:00.0", "0000:83:00.0"
# Start lines as the engine prints them (stage 2's split21 and helper cells).
SPLIT_LOG = (
    "strata generate: expert cache 8227 slots, 24.05 GiB of VRAM; policy is\n"
    "strata generate: layer split: CUDA1 runs layers 24-47, expert cache 7993 slots (23.32 GiB), "
    "7993 of its 12288 profiled pairs; slot 0 verified\n"
    "strata generate: token graph hit path: 16220 resident experts, decided on the device\n")
HELPER_LOG = (
    "strata generate: expert cache 7921 slots, 23.12 GiB of VRAM; policy is\n"
    "strata generate: CUDA1: 10086 additional experts, 29.43 GiB; results return through pinned host rows\n")


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


if __name__ == "__main__":
    unittest.main()
