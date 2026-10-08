import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from code_coverage import source_hashes
from coverage_report import downloaded_inputs, main, policy_hash, write_reports


class ScopedCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = "Sources/ReplicatorApply/Apply.swift"
        self.harness = "Sources/ReplicatorLabCore/Lab.swift"
        for path in [self.runtime, self.harness]:
            target = self.root / path
            target.parent.mkdir(parents=True)
            target.write_text("one\ntwo\nthree\n")
        self.output = self.root / "reports"

    def report(self, name, files, labels=None):
        labels = labels or [name]
        report = dict(version=1, sources=source_hashes(self.root), files=files, inputs=labels,
                      covered_by={p: {n: labels for n, count in lines.items() if count} for p, lines in files.items()})
        path = self.root / f"{name}.json"
        path.write_text(json.dumps(report))
        return path

    def test_scopes_preserve_union_and_exclude_integration_harness_hits(self):
        unit = self.report("unit", {self.runtime: {"1": 1, "2": 0}, self.harness: {"1": 1, "2": 0}})
        integration = self.report("integration", {self.runtime: {"1": 0, "2": 1}, self.harness: {"1": 0, "2": 9}})
        metrics = write_reports(self.root, self.output, [unit, integration], "success", "success", 1)
        self.assertTrue(metrics["complete"])
        self.assertEqual(metrics["scopes"]["runtime"], {"covered": 2, "total": 2})
        self.assertEqual(metrics["scopes"]["harness"], {"covered": 1, "total": 2})
        for scope in ["runtime", "runtime-unit", "runtime-integration"]:
            self.assertNotIn(self.harness, (self.output / scope / "coverage.lcov").read_text())
        self.assertNotIn(self.runtime, (self.output / "harness/coverage.lcov").read_text())
        report = json.loads((self.output / "runtime/coverage.json").read_text())
        self.assertEqual(report["covered_by"][self.runtime], {"1": ["unit"], "2": ["integration"]})
        self.assertIn("100.00%", (self.output / "runtime.svg").read_text())

    def test_metadata_cannot_override_measured_results(self):
        unit = self.report("unit", {self.runtime: {"1": 1}, self.harness: {"1": 1}})
        metadata = dict(version=999, complete=True, policy="wrong", unit_result="success",
                        integration_result="success", integration_reports=100, scopes=None,
                        commit="a" * 40, run_id="123")
        metrics = write_reports(self.root, self.output, [unit], "failure", "unknown", metadata=metadata)
        self.assertEqual(metrics["version"], 1)
        self.assertFalse(metrics["complete"])
        self.assertEqual(metrics["policy"], policy_hash(self.root))
        self.assertEqual((metrics["unit_result"], metrics["integration_result"]), ("failure", "unknown"))
        self.assertEqual(metrics["integration_reports"], 0)
        self.assertEqual(metrics["scopes"]["runtime"], {"covered": 1, "total": 1})
        self.assertEqual((metrics["commit"], metrics["run_id"]), ("a" * 40, "123"))

    def test_missing_failed_and_unverified_suites_are_partial(self):
        unit = self.report("unit", {self.runtime: {"1": 1}, self.harness: {"1": 1}})
        integration = self.report("integration", {self.runtime: {"2": 1}})
        for paths, unit_status, integration_status, expected in [
            ([unit], "success", "success", 1),
            ([integration], "success", "success", 1),
            ([unit, integration], "failure", "success", 1),
            ([unit, integration], "success", "failure", 1),
            ([unit, integration], "unknown", "unknown", None),
            ([unit, integration], "success", "success", 3),
        ]:
            with self.subTest(paths=paths, statuses=(unit_status, integration_status)):
                metrics = write_reports(self.root, self.output, paths, unit_status, integration_status, expected)
                self.assertFalse(metrics["complete"])
                self.assertIn("partial", (self.output / "runtime.svg").read_text())
        metrics = write_reports(self.root, self.output, [integration])
        self.assertEqual(metrics["scopes"]["harness"], {"covered": 0, "total": 0})
        self.assertIn("unavailable", (self.output / "harness/summary.md").read_text())

    def test_stale_duplicate_and_mixed_reports_are_rejected(self):
        unit = self.report("unit", {self.runtime: {"1": 1}})
        mixed = self.report("mixed", {self.runtime: {"1": 1}}, ["unit", "integration"])
        with self.assertRaisesRegex(ValueError, "already mixed"):
            write_reports(self.root, self.output, [mixed])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            write_reports(self.root, self.output, [unit, unit])
        (self.root / self.harness).write_text("changed")
        with self.assertRaisesRegex(ValueError, "source mismatch"):
            write_reports(self.root, self.output, [unit])

    def test_downloaded_collections_exclude_demo_snapshots_but_reject_duplicate_originals(self):
        downloaded = self.root / "downloaded"
        unit = downloaded / "coverage-unit/coverage.json"
        unit.parent.mkdir(parents=True)
        unit.write_bytes(self.report("unit", {self.runtime: {"1": 1}, self.harness: {"1": 1}}).read_bytes())
        originals = [unit]
        for i in range(12):
            fixture = downloaded / f"coverage-integration/run-{i}/fixture"
            original = fixture / "code-coverage/combined/coverage.json"
            original.parent.mkdir(parents=True)
            original.write_bytes(self.report(f"apply-{i}", {self.runtime: {"2": 1}}).read_bytes())
            originals.append(original)
            if i >= 3:  # Nine demo sessions also retain an evidence snapshot.
                snapshot = fixture / "evidence-saved/code-coverage/combined/coverage.json"
                snapshot.parent.mkdir(parents=True)
                snapshot.write_bytes(original.read_bytes())
        with self.assertRaisesRegex(ValueError, "duplicate coverage inputs"):
            write_reports(self.root, self.output, sorted(downloaded.rglob("coverage.json")))
        inputs = downloaded_inputs(downloaded)
        self.assertEqual(inputs, sorted(originals))
        args = ["coverage_report.py", "--root", str(self.root), "--output", str(self.output),
                "--downloaded", str(downloaded), "--unit-result", "success", "--integration-result", "success",
                "--expected-integration", "12"]
        with patch("sys.argv", args):
            main()
        metrics = json.loads((self.output / "metrics.json").read_text())
        self.assertTrue(metrics["complete"])
        self.assertEqual(metrics["integration_reports"], 12)
        originals[-1].unlink()
        metrics = write_reports(self.root, self.output, downloaded_inputs(downloaded), "success", "success", 12)
        self.assertFalse(metrics["complete"])  # A snapshot cannot replace a missing original.
        duplicate = downloaded / "duplicate/coverage.json"
        duplicate.parent.mkdir()
        duplicate.write_bytes(originals[1].read_bytes())
        with self.assertRaisesRegex(ValueError, "duplicate coverage inputs"):
            write_reports(self.root, self.output, downloaded_inputs(downloaded))

    def test_ci_records_tested_merge_head_base_and_run_identity(self):
        unit = self.report("unit", {self.runtime: {"1": 1}, self.harness: {"1": 1}})
        integration = self.report("integration", {self.runtime: {"2": 1}})
        event = self.root / "event.json"
        event.write_text(json.dumps({"pull_request": {"head": {"sha": "b" * 40}, "base": {"sha": "c" * 40}}}))
        summary = self.root / "job-summary.md"
        environment = dict(GITHUB_EVENT_PATH=str(event), GITHUB_SHA="a" * 40,
                           GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="2", GITHUB_STEP_SUMMARY=str(summary))
        args = ["coverage_report.py", "--root", str(self.root), "--output", str(self.output), "--ci",
                "--unit-result", "success", "--integration-result", "success", "--expected-integration", "1",
                str(unit), str(integration)]
        with patch.dict(os.environ, environment), patch("sys.argv", args):
            main()
        metrics = json.loads((self.output / "metrics.json").read_text())
        self.assertTrue(metrics["complete"])
        self.assertEqual((metrics["commit"], metrics["head_sha"], metrics["base_sha"]), ("a" * 40, "b" * 40, "c" * 40))
        self.assertEqual((metrics["run_id"], metrics["run_attempt"]), ("123", "2"))
        self.assertIn("Complete selected suites", summary.read_text())


if __name__ == "__main__":
    unittest.main()
