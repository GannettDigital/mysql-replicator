import json
from pathlib import Path
import tempfile
import unittest

from lab_sql_report import summarize, category, fingerprint, markdown


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

    def test_categories_preserve_unknown_calls_and_position_checks(self):
        self.assertEqual(category(self.start('a')), 'outside_case')
        base = dict(self.start('a', 'ddl'), queries=[])
        for sql, expected in [('SELECT GTID_SUBSET(\'a:1\',\'a:1\')', 'position_or_wait'),
                              ('SHOW MASTER STATUS', 'position_or_wait'),
                              ('SELECT * FROM information_schema.COLUMNS', 'metadata_read'),
                              ('SELECT COUNT(*) FROM t', 'result_or_status_read'),
                              ('SET NAMES utf8mb4; INSERT INTO t VALUES(1)', 'source_statement'),
                              ('SET NAMES utf8mb4; SELECT * FROM information_schema.COLUMNS', 'metadata_read'),
                              ('SELECT 1; DROP TABLE t', 'mixed_or_unclassified')]:
            self.assertEqual(category(dict(base, sql=sql)), expected)
        queries = [dict(name=n, sql='SELECT 1') for n in ['database', 'tables', 'columns', 'foreignKeys']]
        self.assertEqual(category(dict(base, queries=queries)), 'schema_comparison')

    def test_repetition_ignores_only_batch_framing_and_keeps_case_costs(self):
        a = self.start('a', 'first')
        b = dict(self.start('b', 'second'), sql='different batch framing')
        self.assertEqual(fingerprint(a), fingerprint(b))
        self.assertNotEqual(fingerprint(a), fingerprint(dict(b, queries=[dict(name='rows', sql='SELECT 2')])))
        self.assertNotEqual(fingerprint(dict(a, queries=[], sql='SELECT a')),
                            fingerprint(dict(a, queries=[], sql='SELECT A')))
        with tempfile.TemporaryDirectory() as directory:
            path = self.trace(directory, [a, self.finish('a'), b, self.finish('b')])
            copy = Path(directory) / 'evidence'
            copy.mkdir()
            self.trace(copy, [a, self.finish('a')])
            report = summarize([Path(directory), path])
            self.assertEqual(report['calls'], 2)
            repeated = report['repeated_calls'][0]
            self.assertEqual(repeated['cases'], {'first': 1, 'second': 1})
            self.assertEqual(repeated['seconds'], 0.5)
            self.assertNotIn('secret', json.dumps(report))
            self.assertIn('first', markdown(report))


if __name__ == "__main__":
    unittest.main()
