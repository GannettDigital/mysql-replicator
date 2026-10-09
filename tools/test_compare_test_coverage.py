import json
from pathlib import Path
import tempfile
import unittest

from code_coverage import source_hashes
from compare_test_coverage import compare


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.file = "Sources/ReplicatorApply/Sample.swift"
        source = self.root / self.file
        source.parent.mkdir(parents=True)
        source.write_text("one\ntwo\nthree\n")
        lab = self.root / "Sources/ReplicatorLab/main.swift"
        lab.parent.mkdir()
        lab.write_text("legacy entry point\n")

    def evidence(self, name, counts):
        directory = self.root / name
        directory.mkdir()
        result = directory / "result.json"
        result.write_text(json.dumps(dict(result="passed", cleanup="passed", code_coverage=True, image="sha256:same")))
        coverage = directory / "coverage.json"
        coverage.write_text(json.dumps(dict(version=1, inputs=[name], sources=source_hashes(self.root),
                                            files={self.file: counts, "Sources/ReplicatorLab/main.swift": {"1": 99}})))
        return {"coverage": str(coverage), "result": str(result)}

    def manifest(self):
        return dict(schema_version=1, groups={"legacy": [self.evidence("legacy", {"1": 2, "2": 1, "3": 0})],
                                             "shared": [self.evidence("shared", {"1": 2, "2": 0, "3": 1})]},
                    comparisons=[dict(id="forward", baseline="legacy", candidate="shared")])

    def run_compare(self, manifest):
        return compare(self.root, manifest, self.root / "out")

    def test_equal_percentages_do_not_hide_lost_lines_and_lab_is_excluded(self):
        report = self.run_compare(self.manifest())["comparisons"][0]
        self.assertEqual(report["counts"], dict(mapped=3, baseline_hit=2, candidate_hit=2, both=1, baseline_only=1, candidate_only=1))
        self.assertEqual(report["baseline_only"], {self.file: [2]})
        self.assertEqual(report["baseline_only_origins"], [dict(file=self.file, line=2, inputs=["legacy"])])

    def test_harness_removal_does_not_invalidate_unchanged_runtime_baseline(self):
        manifest = self.manifest()
        (self.root / "Sources/ReplicatorLab/main.swift").unlink()
        self.run_compare(manifest)
        (self.root / self.file).write_text("runtime changed\n")
        with self.assertRaisesRegex(ValueError, "source mismatch"):
            self.run_compare(manifest)

    def test_failed_run_cleanup_wrong_image_and_duplicate_are_refused(self):
        manifest = self.manifest()
        result = Path(manifest["groups"]["shared"][0]["result"])
        original = json.loads(result.read_text())
        for field, value, message in [("result", "failed", "did not pass"), ("cleanup", "failed", "did not pass"),
                                      ("code_coverage", False, "not instrumented"), ("image", "sha256:other", "same instrumented")]:
            result.write_text(json.dumps(dict(original, **{field: value})))
            with self.assertRaisesRegex(ValueError, message):
                self.run_compare(manifest)
        result.write_text(json.dumps(original))
        manifest["groups"]["shared"].append(manifest["groups"]["shared"][0])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.run_compare(manifest)

    def test_cannot_attach_failed_or_foreign_coverage_to_a_successful_run(self):
        manifest = self.manifest()
        manifest["groups"]["legacy"][0]["result"] = manifest["groups"]["shared"][0]["result"]
        with self.assertRaisesRegex(ValueError, "outside its declared run"):
            self.run_compare(manifest)

    def test_crash_profile_loss_remains_visible_and_normal_loss_is_rejected(self):
        manifest = self.manifest()
        entry = manifest["groups"]["legacy"][0]
        old = Path(entry["coverage"])
        parent = old.parent / "code-coverage"
        (parent / "combined").mkdir(parents=True)
        moved = parent / "combined/coverage.json"
        old.rename(moved)
        entry["coverage"] = str(moved)
        status = parent / "profile-status.json"
        status.write_text(json.dumps([dict(label="killed", exit_code=137, profile="missing-abrupt-exit")]))
        self.run_compare(manifest)
        self.assertIn("Crash-path coverage is incomplete", (self.root / "out/comparison.md").read_text())
        status.write_text(json.dumps([dict(label="normal", exit_code=0, profile="missing")]))
        with self.assertRaisesRegex(ValueError, "missing normally exited"):
            self.run_compare(manifest)


if __name__ == "__main__":
    unittest.main()
