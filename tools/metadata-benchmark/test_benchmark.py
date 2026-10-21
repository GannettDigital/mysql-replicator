import json
import subprocess
import unittest

from benchmark import final_summary, schema, workload


class ReportTests(unittest.TestCase):
    def testFinalSummaryUsesStoppedRecordFromEitherStream(self):
        stopped = dict(kind="apply_summary", lifecycle="STOPPED", stageTimings={})
        running = dict(kind="apply_summary", lifecycle="RUNNING")
        for stdout, stderr in [(stopped, running), (running, stopped)]:
            result = subprocess.CompletedProcess([], 0, json.dumps(stdout).encode(), json.dumps(stderr).encode())
            self.assertEqual(final_summary(result), stopped)
        with self.assertRaises(RuntimeError):
            final_summary(subprocess.CompletedProcess([], 0, json.dumps(running).encode(), b""))

    def testFKGroupsDoNotJoinEveryTableIntoOneComponent(self):
        sql = schema(8, "InnoDB", 4)
        self.assertEqual(sql.count("REFERENCES metadata_bench.t0"), 3)
        self.assertEqual(sql.count("REFERENCES metadata_bench.t4"), 3)
        self.assertNotIn("REFERENCES", schema(8, "MyISAM", 0))
        self.assertEqual(workload(128, 8).count("INSERT INTO"), 128)


if __name__ == "__main__":
    unittest.main()
