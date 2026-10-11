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

    def test_job_pages_and_incomplete_jobs(self):
        jobs = job_timings([dict(jobs=[dict(name='build', started_at='2026-10-10T00:00:00Z',
                    completed_at='2026-10-10T00:01:00Z', steps=[])]), dict(jobs=[dict(name='report')])])
        self.assertEqual(jobs[0]['seconds'], 60)
        self.assertIsNone(jobs[1]['seconds'])



if __name__ == '__main__':
    unittest.main()
