#!/usr/bin/env python3
"""Report regression checks using synthetic traces. No app, build or UI is involved."""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("scroll_lab", Path(__file__).with_name("scroll-lab.py"))
LAB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LAB)


class ScrollLabReportTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)

    def run_record(self, name, *, trace=True, finished=True, exit_status=0, metadata=True):
        directory = self.root / name
        directory.mkdir()
        if metadata:
            (directory / "run.meta.json").write_text(json.dumps({"build": name, "exitStatus": exit_status}))
        if trace:
            records = [{"kind": "boot"}]
            if finished:
                records.append({"kind": "end"})
            (directory / "run.ndjson").write_text("\n".join(json.dumps(record) for record in records))

    def report(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return LAB.report(self.root)

    def test_a_missing_trace_fails_even_when_another_build_finished(self):
        self.run_record("baseline")
        self.run_record("candidate", trace=False)
        self.assertEqual(self.report(), 1)
        report = (self.root / "report.md").read_text()
        self.assertIn("baseline, candidate", report)
        self.assertIn("Runs : 2 (1 interrompus)", report)

    def test_a_failed_launch_fails_even_when_the_trace_has_an_end(self):
        self.run_record("candidate", exit_status=124)
        self.assertEqual(self.report(), 1)

    def test_an_interrupted_trace_fails(self):
        self.run_record("candidate", finished=False)
        self.assertEqual(self.report(), 1)

    def test_a_completed_run_succeeds(self):
        self.run_record("candidate")
        self.assertEqual(self.report(), 0)

    def test_old_trace_only_runs_remain_readable(self):
        self.run_record("candidate", metadata=False)
        self.assertEqual(self.report(), 0)


class LiveEndJudgementTests(unittest.TestCase):
    MOVED = {"stillResidue": 0.5, "residue": 0.5, "shift": 0}

    def judge(self, label, kind, *, from_end=0, stable=True, pixels=None):
        record = {"step": {"kind": kind, "label": label}, "t0": 0, "t1": 1, "frames": [],
                  "place": {"fromEnd": from_end}, "result": {"stable": stable, "pixels": pixels}}
        return LAB.judge(record, {})["failures"]

    def test_a_chat_reopened_while_its_agent_writes_follows_the_end(self):
        self.assertEqual(self.judge("vivant-espace/longue/back", "select", stable=False), [])
        self.assertEqual(self.judge("vivant-onglet/neuve/rest-back", "rest", pixels=self.MOVED), [])
        self.assertEqual(self.judge("vivant-onglet/neuve/after", "rest", pixels=self.MOVED), [])

    def test_a_chat_reopened_while_its_agent_writes_fails_when_it_leaves_the_end(self):
        for label, kind in [("vivant-espace/longue/back", "select"), ("vivant-onglet/neuve/rest-back", "rest")]:
            self.assertEqual(self.judge(label, kind, from_end=120, stable=False), ["décroche du direct (120 pt du bas)"])
        self.assertEqual(self.judge("vivant-onglet/neuve/after", "rest", from_end=120, pixels=self.MOVED),
                         ["bouge au repos : change (résidu 0.50)"])

    def test_quiet_steps_of_a_live_scenario_stay_strict(self):
        self.assertEqual(self.judge("vivant-espace/longue/select", "select", stable=False), ["jamais au repos"])
        for phase in ("read", "working"):
            self.assertEqual(self.judge(f"vivant-espace/longue/{phase}", "rest", pixels=self.MOVED),
                             ["bouge au repos : change (résidu 0.50)"])


if __name__ == "__main__":
    unittest.main()
