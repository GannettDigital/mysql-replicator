import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import code_coverage as coverage


class CoverageTests(unittest.TestCase):
    def test_cached_unit_build_keeps_objects_but_discards_counters_and_relinks(self):
        debug = self.root / '.build/code-coverage/debug'
        debug.mkdir(parents=True)
        cached = debug / 'cached.o'
        cached.write_bytes(b'compiler intermediate')
        (debug / 'old.profraw').write_bytes(b'old counters')
        products = [debug / name for name in ['mysql-replicator', 'replicator-lab', 'Suite.xctest']]
        for product in products:
            product.write_bytes(b'old executable')
        output = self.root / 'artifacts/coverage/unit'
        output.mkdir(parents=True)
        (output / 'old.profraw').write_bytes(b'old subprocess counters')

        def rebuild(args, **kwargs):
            self.assertIn('--force-resolved-versions', args)
            self.assertEqual(cached.read_bytes(), b'compiler intermediate')
            self.assertFalse(list(self.root.rglob('*.profraw')))
            self.assertFalse(any(p.exists() for p in products))
            for product in products:
                product.write_bytes(b'new executable')
            return SimpleNamespace(returncode=0)

        with patch.object(coverage, 'run'), patch.object(coverage.subprocess, 'run', side_effect=rebuild), \
             patch.object(coverage, 'export') as export:
            coverage.unit(self.root, output)
        export.assert_called_once()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Sources").mkdir()
        (self.root / "Sources/sample.swift").write_text("let a = 1\nlet b = 2\nlet c = 3\n")

    def report(self, label, counts):
        file = "Sources/sample.swift"
        path = self.root / label
        coverage.render({"version": 1, "inputs": [label], "sources": coverage.source_hashes(self.root),
                         "files": {file: counts},
                         "covered_by": {file: {n: [label] for n, c in counts.items() if c}}}, self.root, path)
        return path

    def test_normalization_excludes_dependencies_and_unrelated_sources(self):
        text = f"SF:{self.root}/Sources/sample.swift\nDA:1,2\nDA:2,0\nend_of_record\nSF:/another/project/Sources/sample.swift\nDA:1,99\nSF:{self.root}/Vendor/a.swift\nDA:2,88\n"
        self.assertEqual(coverage.parse_lcov(text, self.root), {"Sources/sample.swift": {"1": 2, "2": 0}})

    def test_merge_unions_executable_lines_and_retains_case_attribution(self):
        unit = self.report("unit", {"1": 2, "2": 0})
        harness = self.report("ddl-create", {"1": 0, "2": 3, "3": 0})
        output = self.root / "combined"
        coverage.merge(self.root, output, [unit, harness])
        result = json.loads((output / "coverage.json").read_text())
        self.assertEqual(result["files"]["Sources/sample.swift"], {"1": 2, "2": 3, "3": 0})
        self.assertEqual(result["covered_by"]["Sources/sample.swift"], {"1": ["unit"], "2": ["ddl-create"]})
        self.assertIn("LF:3\nLH:2", (output / "coverage.lcov").read_text())
        self.assertIn("ddl-create", (output / "file-0.html").read_text())
        self.assertIn("| Runtime (excluding lab) | 2/3 | 66.67% |", (output / "summary.md").read_text())

    def test_stale_duplicate_and_empty_reports_are_rejected(self):
        unit = self.report("unit", {"1": 1})
        output = self.root / "combined"
        with self.assertRaisesRegex(ValueError, "duplicate"):
            coverage.merge(self.root, output, [unit, unit])
        with self.assertRaisesRegex(ValueError, "no coverage"):
            coverage.merge(self.root, output, [])
        (self.root / "Sources/sample.swift").write_text("changed\n")
        with self.assertRaisesRegex(ValueError, "source mismatch"):
            coverage.merge(self.root, output, [unit])

    def test_missing_raw_profiles_fail_instead_of_claiming_zero_coverage(self):
        with self.assertRaisesRegex(ValueError, "no nonempty profiles"):
            coverage.export(self.root, self.root / "out", "unit", [], [self.root / "missing"])

    def test_harness_records_crash_loss_but_rejects_missing_normal_exit(self):
        profiles = self.root / "code-coverage"
        profiles.mkdir()
        invocations = self.root / "code-coverage-invocations.json"
        invocations.write_text(json.dumps([{"label": "crashed", "exit_code": 137}, {"label": "normal", "exit_code": 0}]))
        with self.assertRaisesRegex(ValueError, "no profiles"):
            coverage.harness(self.root, profiles, "suite")
        statuses = json.loads((profiles / "profile-status.json").read_text())
        self.assertEqual([s["profile"] for s in statuses], ["missing-abrupt-exit", "missing"])
        completed = profiles / "completed"
        completed.mkdir()
        (completed / "one.profraw").write_bytes(b"mock LLVM profile")
        with patch.object(coverage, "export"), patch.object(coverage, "merge"):
            with self.assertRaisesRegex(ValueError, "normally exited.*normal"):
                coverage.harness(self.root, profiles, "suite")

    def test_demo_without_writer_emits_no_fake_report(self):
        profiles = self.root / "code-coverage"
        coverage.harness(self.root, profiles, "demo", allow_empty=True)
        self.assertFalse((profiles / "combined/coverage.json").exists())


if __name__ == "__main__":
    unittest.main()
