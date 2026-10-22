import json
from pathlib import Path
import tempfile
import unittest

from lab_sql_report import summarize


class SQLReportTests(unittest.TestCase):
    def trace(self, root, events):
        path = Path(root) / "sql-trace.jsonl"
        path.write_text("".join(json.dumps({"schema_version": 1, **event}) + "\n" for event in events))
        return path

    def start(self, call, case=None):
        return {"event": "start", "call_id": call, "case_id": case, "role": "source",
                "kind": "batch", "queries": [{"name": "rows", "sql": "SELECT secret"}],
                "sql": "SELECT secret"}

    def finish(self, call, outcome="succeeded"):
        return {"event": "finish", "call_id": call, "outcome": outcome, "seconds": 0.25}

    def test_counts_setup_cases_errors_and_unfinished_without_exposing_sql(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.trace(directory, [self.start("a"), self.finish("a"), self.start("b", "ddl"),
                                         self.finish("b", "failed"), self.start("c", "ddl")])
            report = summarize([Path(directory), path])
            self.assertEqual(report["trace_files"], 1)
            self.assertEqual(report["calls"], 3)
            self.assertEqual(report["unfinished_calls"], 1)
            ddl = report["groups"][1]
            self.assertEqual(ddl["case_id"], "ddl")
            self.assertEqual(ddl["outcomes"], {"failed": 1, "unfinished": 1})
            self.assertEqual(ddl["batch_queries"], 2)
            self.assertEqual(ddl["seconds"], 0.25)
            self.assertNotIn("secret", json.dumps(report))

    def test_missing_files_and_bad_pairing_are_not_silently_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "No sql-trace"):
                summarize([Path(directory)])
            for events in ([self.finish("a")], [self.start("a"), self.start("a")],
                           [self.start("a"), self.finish("a"), self.finish("a")]):
                path = self.trace(directory, events)
                with self.assertRaises(ValueError):
                    summarize([path])


if __name__ == "__main__":
    unittest.main()
