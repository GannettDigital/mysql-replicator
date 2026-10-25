import json
from pathlib import Path
import tempfile
import unittest

from ci_measurements import job_timings, line_sets, markdown, record_shard, summarize


class MeasurementsTests(unittest.TestCase):
    def fixture(self):
        row = dict(profile='p', variant='default', suite='correctness', id='ddl', status='not_run')
        shard = dict(id='release-p-ddl', profile='p', variant='default', suite='correctness',
                     image='release', reports=0)
        manifest = dict(inventory=[row], include=[shard])
        record = dict(id=shard['id'], status='passed', seconds=3, scenarios=[dict(row, status='passed')])
        return manifest, record

    def test_missing_failed_duplicate_and_instrumented_only_results_cannot_claim_catalog_pass(self):
        manifest, record = self.fixture()
        self.assertTrue(summarize(manifest, [record])['complete'])
        self.assertFalse(summarize(manifest, [])['complete'])
        self.assertFalse(summarize(manifest, [dict(record, status='failed')])['complete'])
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            summarize(manifest, [record, record])
        manifest['include'][0]['image'] = 'coverage'
        self.assertFalse(summarize(manifest, [record])['complete'])

    def test_missing_coverage_and_mixed_provenance_fail(self):
        manifest, record = self.fixture()
        manifest['include'][0]['reports'] = 1
        self.assertFalse(summarize(manifest, [record])['complete'])
        other = dict(manifest['include'][0], id='other')
        manifest['include'].append(other)
        with self.assertRaisesRegex(ValueError, 'mixed commits'):
            summarize(manifest, [dict(record, commit='a'), dict(record, id='other', commit='b')])

    def test_smoke_coverage_owns_selected_catalog_but_still_requires_cases_and_collection(self):
        manifest, record = self.fixture()
        manifest['scope'] = 'pr-smoke'
        manifest['include'][0].update(image='coverage', reports=1, owns_obligations=True)
        record['coverage'] = dict(collections=1, sources_digest='a', mapped=[], hit=[])
        report = summarize(manifest, [record])
        self.assertTrue(report['complete'])
        self.assertIn('Scope: pr-smoke', markdown(report))
        self.assertFalse(summarize(manifest, [dict(record, scenarios=[])])['complete'])
        without_coverage = dict(record)
        del without_coverage['coverage']
        self.assertFalse(summarize(manifest, [without_coverage])['complete'])

    def test_group_results_are_bound_to_jobs_and_missing_groups_still_fail(self):
        from ci_jobs import assign_jobs
        manifest, record = self.fixture()
        manifest['include'][0]['area'] = 'ddl'
        manifest['include'].append(dict(manifest['include'][0], id='supplement', owns_obligations=False))
        plan = assign_jobs(manifest, dict(max_groups=3, group_timeout_minutes=45,
                                         setup_timeout_minutes=10, standalone_areas=[]))
        job = plan['jobs'][0]['id']
        for bad in (record, dict(record, job_id='wrong')):
            with self.assertRaisesRegex(ValueError, 'CI job ID'):
                summarize(plan, [bad])
        first = dict(record, job_id=job)
        report = summarize(plan, [first])
        self.assertFalse(report['complete'])
        self.assertEqual(report['missing_shards'], ['supplement'])
        report = summarize(plan, [first, dict(first, id='supplement')])
        self.assertTrue(report['complete'])
        self.assertEqual((report['planned_jobs'], report['execution_groups']), (1, 2))
        self.assertEqual(report['instrumentation']['integration_jobs'], 1)
        self.assertEqual(report['instrumentation']['execution_groups'], 2)
        self.assertIn('CI jobs: 1. Execution groups: 2.', markdown(report))

    def test_lines_are_unioned_and_harness_is_excluded(self):
        mapped, hit = line_sets([dict(files={'Sources/App/A.swift': {'1': 2, '2': 0},
                                            'Sources/ReplicatorLab/main.swift': {'1': 10}}),
                                dict(files={'Sources/App/A.swift': {'1': 1, '2': 1}})])
        self.assertEqual(mapped, hit)
        self.assertEqual(len(hit), 2)

    def test_failure_records_time_and_only_new_result_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            old = root / 'artifacts/lab/old/result.json'
            old.parent.mkdir(parents=True)
            old.write_text('{"scenarios": [{"id": "old"}]}')
            with self.assertRaisesRegex(RuntimeError, 'test failed'):
                with record_shard(root, 'failed'):
                    new = root / 'artifacts/lab/new/result.json'
                    new.parent.mkdir()
                    new.write_text('{"scenarios": [{"id": "new", "status": "failed", "sql": "private"}]}')
                    raise RuntimeError('test failed')
            result = json.loads((root / 'artifacts/ci/measurements/failed.json').read_text())
            self.assertEqual(result['status'], 'failed')
            self.assertEqual(result['scenarios'], [dict(id='new', status='failed')])
            self.assertGreaterEqual(result['seconds'], 0)

    def test_fixture_metrics_ignore_old_and_copied_records(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            value = dict(version=1, fixture='f', profile='p', phases={
                'setup': dict(seconds=12, status='passed'), 'cleanup': dict(seconds=3, status='passed')})
            old = root / 'artifacts/lab/old/fixture-lifecycle.json'
            old.parent.mkdir(parents=True)
            old.write_text(json.dumps(value))
            with record_shard(root, 'fixture'):
                for suffix in ('fixture', 'fixture/evidence/copy'):
                    path = root / 'artifacts/lab/new' / suffix / 'fixture-lifecycle.json'
                    path.parent.mkdir(parents=True)
                    path.write_text(json.dumps(value))
            record = json.loads((root / 'artifacts/ci/measurements/fixture.json').read_text())
            self.assertEqual(record['fixtures'], [value])
            manifest, base = self.fixture()
            report = summarize(manifest, [dict(base, fixtures=[value])])
            self.assertEqual(report['shards'][0]['fixtures'], [value])
            self.assertIn('| p | 1 | 12.0 | 3.0 |', markdown(report))

    def test_job_pages_and_incomplete_jobs(self):
        jobs = job_timings([dict(jobs=[dict(name='build', started_at='2026-10-10T00:00:00Z',
                    completed_at='2026-10-10T00:01:00Z', steps=[])]), dict(jobs=[dict(name='report')])])
        self.assertEqual(jobs[0]['seconds'], 60)
        self.assertIsNone(jobs[1]['seconds'])

    def test_sql_client_metrics_ignore_old_runs_and_copied_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            metrics = dict(calls=10, failures=1, seconds=2.5, batch_calls=2, batch_queries=12)
            old = root / 'artifacts/lab/old/sql-client.json'
            old.parent.mkdir(parents=True)
            old.write_text(json.dumps(metrics))
            with record_shard(root, 'sql'):
                for suffix in ('fixture', 'fixture/evidence/copy'):
                    path = root / 'artifacts/lab/new' / suffix / 'sql-client.json'
                    path.parent.mkdir(parents=True)
                    path.write_text(json.dumps(metrics))
            record = json.loads((root / 'artifacts/ci/measurements/sql.json').read_text())
            self.assertEqual(record['sql_client'], metrics)
            manifest, base = self.fixture()
            report = summarize(manifest, [dict(base, sql_client=metrics)])
            self.assertEqual(report['shards'][0]['sql_client'], metrics)
            self.assertIn('| release | 1 | 10 | 1 | 2 | 12 | 2.5 |', markdown(report))



if __name__ == '__main__':
    unittest.main()
