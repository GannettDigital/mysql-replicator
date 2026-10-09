import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import coverage_comment as publisher


def metrics():
    return dict(version=1, complete=True, commit="a" * 40, head_sha="b" * 40, base_sha="c" * 40,
                policy="d" * 64, run_id="12", run_attempt="1",
                scopes={name: {"covered": 1, "total": 2} for name in publisher.SCOPES})


def archive(report, name="metrics.json"):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as zipped:
        zipped.writestr(name, json.dumps(report))
    return output.getvalue()


class CommentTests(unittest.TestCase):
    def test_only_bounded_valid_json_is_accepted(self):
        self.assertEqual(publisher.read_archive(archive(metrics())), metrics())
        for name in ["../metrics.json", "script.py", "directory/metrics.json"]:
            with self.assertRaises(ValueError):
                publisher.read_archive(archive(metrics(), name))
        with self.assertRaises(ValueError):
            publisher.read_archive(b"x" * (1024 * 1024 + 1))
        large = metrics()
        large["padding"] = "x" * 70000
        with self.assertRaises(ValueError):
            publisher.read_archive(archive(large))
        for value in [-1, True, "50%", 3, 10**9]:
            bad = metrics()
            bad["scopes"]["runtime"]["covered"] = value
            with self.assertRaises(ValueError):
                publisher.validate(bad)
        bad = metrics()
        bad["commit"] = "@everyone"
        with self.assertRaises(ValueError):
            publisher.validate(bad)

    def test_delta_requires_exact_base_same_policy_and_complete_reports(self):
        current = metrics()
        base = metrics()
        base["commit"] = current["base_sha"]
        base["scopes"]["runtime"]["covered"] = 0
        run = dict(id=12, run_attempt=1)
        self.assertIn("+50.00 pp", publisher.comment(current, run, "owner/repo", base))
        for key, value in [("commit", "e" * 40), ("policy", "f" * 64), ("complete", False)]:
            bad = dict(base, **{key: value})
            self.assertFalse(publisher.comparable(current, bad))
            self.assertIn("Base comparison unavailable", publisher.comment(current, run, "owner/repo", bad))
        self.assertIn("PARTIAL", publisher.comment(dict(current, complete=False), run, "owner/repo", base))
        self.assertIn("unavailable", publisher.comment(None, run, "owner/repo"))

    def test_artifact_must_match_run_and_attempt(self):
        run = dict(id=12, run_attempt=1, head_sha="b" * 40)
        item = dict(name="coverage-summary", expired=False, size_in_bytes=100, id=3)
        with patch.object(publisher, "pages", return_value=[item]), patch.object(publisher, "api", return_value=archive(metrics())):
            self.assertIsNotNone(publisher.metrics_for("owner/repo", run))
            with self.assertRaisesRegex(ValueError, "triggering run"):
                publisher.metrics_for("owner/repo", dict(run, run_attempt=2))
            with self.assertRaisesRegex(ValueError, "triggering run"):
                publisher.metrics_for("owner/repo", dict(run, head_sha="c" * 40))

    def exercise(self, prior=None, head="b" * 40, fork="contributor/repo"):
        repo = "owner/repo"
        run = dict(event="pull_request", path=".github/workflows/ci.yml", id=12, run_attempt=1,
                   head_sha="b" * 40, repository={"full_name": repo}, head_repository={"full_name": fork})
        pr = dict(number=7, state="open", head={"sha": "b" * 40, "repo": {"full_name": fork}},
                  base={"repo": {"full_name": repo}})
        calls = []

        def api(path, method="GET", body=None):
            calls.append((path, method, body))
            if path.endswith("/pulls/7"):
                return dict(pr, head={"sha": head})
            return {}

        def pages(path, key=None):
            return [pr] if path.endswith("/pulls") else ([prior] if prior else [])

        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory) / "event.json"
            event.write_text(json.dumps({"workflow_run": run}))
            with patch.dict(os.environ, GITHUB_EVENT_PATH=str(event), GITHUB_REPOSITORY=repo), \
                    patch.object(publisher, "pages", side_effect=pages), \
                    patch.object(publisher, "api", side_effect=api), \
                    patch.object(publisher, "metrics_for", return_value=dict(metrics(), complete=False)):
                publisher.main()
        return [c for c in calls if c[1] != "GET"]

    def test_fork_pr_create_update_and_stale_runs(self):
        calls = self.exercise()
        self.assertEqual(calls[0][0:2], ("repos/owner/repo/issues/7/comments", "POST"))
        prior = dict(id=9, user={"login": "github-actions[bot]"},
                     body=publisher.MARKER + "\n<!-- coverage-run:11:1 -->")
        calls = self.exercise(prior)
        self.assertEqual(calls[0][0:2], ("repos/owner/repo/issues/comments/9", "PATCH"))
        newer = copy.deepcopy(prior)
        newer["body"] = publisher.MARKER + "\n<!-- coverage-run:13:1 -->"
        self.assertEqual(self.exercise(newer), [])
        self.assertEqual(self.exercise(head="f" * 40), [])


if __name__ == "__main__":
    unittest.main()
