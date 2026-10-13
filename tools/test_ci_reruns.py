import copy
import json
import os
import sys
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from ci_reruns import api_pages, build_identity, job_history, validate_results, REQUIRED_DEPENDENCIES
from ci_measurements import record_shard, summarize


class RetryTests(unittest.TestCase):
    def test_transient_failure_discards_partial_pages_and_retries(self):
        results = [subprocess.CompletedProcess([], 1, '[{"partial":true}]', 'gh: Server Error (HTTP 502)'),
                   subprocess.CompletedProcess([], 0, '[{"jobs": []}]', '')]
        with patch('ci_reruns.subprocess.run', side_effect=results) as run, patch('ci_reruns.time.sleep') as sleep:
            self.assertEqual(api_pages('endpoint'), [{'jobs': []}])
            self.assertEqual(run.call_count, 2)
            sleep.assert_called_once_with(2)

    def test_timeout_retries_but_permission_error_does_not(self):
        with patch('ci_reruns.subprocess.run', side_effect=subprocess.TimeoutExpired('gh', 60)) as run, \
                patch('ci_reruns.time.sleep') as sleep:
            with self.assertRaisesRegex(ValueError, 'timed out'):
                api_pages('endpoint')
            self.assertEqual(run.call_count, 4)
            self.assertEqual(sleep.call_count, 3)
        with patch('ci_reruns.subprocess.run', return_value=subprocess.CompletedProcess([], 1, '', 'HTTP 403')) as run, \
                patch('ci_reruns.time.sleep') as sleep:
            with self.assertRaisesRegex(ValueError, 'HTTP 403'):
                api_pages('endpoint')
            self.assertEqual(run.call_count, 1)
            sleep.assert_not_called()

    def test_job_copies_keep_the_original_execution_attempt(self):
        old = dict(id=1, name='shard', run_id=9, run_attempt=1, started_at='old', completed_at='done', conclusion='success')
        retry = dict(old, id=2, name='retry', conclusion='failure')
        pages = [[dict(total_count=2, jobs=[old, retry])],
                 [dict(total_count=2, jobs=[dict(old, id=3, run_attempt=2),
                                           dict(retry, id=4, run_attempt=2, started_at='new', completed_at='new-end', conclusion='success')])]]
        with patch('ci_reruns.api_pages', side_effect=pages):
            jobs = job_history('owner/repo', '9', '2')[0]['jobs']
        self.assertEqual([j['execution_attempt'] for j in jobs], ['1', '2'])
        self.assertEqual([j['conclusion'] for j in jobs], ['success', 'success'])

    def test_missing_pages_wrong_runs_and_duplicate_jobs_fail(self):
        job = dict(id=1, name='shard', run_id=9)
        for page in (dict(total_count=2, jobs=[job]),
                     dict(total_count=1, jobs=[dict(job, run_id=8)]),
                     dict(total_count=2, jobs=[job, job])):
            with self.subTest(page=page), patch('ci_reruns.api_pages', return_value=[page]), self.assertRaises(ValueError):
                job_history('owner/repo', '9', '1')

    def test_queued_matrix_copy_does_not_hide_the_execution_or_change_its_attempt(self):
        for conclusion in ('success', 'failure'):
            actual = dict(id=2, name='shard', run_id=9, run_attempt=2, head_sha='a',
                          created_at='created', started_at='new', completed_at='done',
                          status='completed', conclusion=conclusion, steps=[dict(name='test')],
                          runner_id=10, runner_name='runner')
            queued = dict(actual, id=3, status='queued', conclusion=None, started_at='created',
                          completed_at=None, steps=[], runner_id=None, runner_name=None)
            old = dict(actual, id=1, run_attempt=1, started_at='old', completed_at='old-done')
            for pair in ([actual, queued], [queued, actual]):
                pages = [[dict(total_count=1, jobs=[old])],
                         [dict(total_count=2, jobs=pair)],
                         [dict(total_count=1, jobs=[dict(actual, id=4, run_attempt=3)])]]
                with self.subTest(conclusion=conclusion, first=pair[0]['id']), \
                        patch('ci_reruns.api_pages', side_effect=pages):
                    jobs = job_history('owner/repo', '9', '3')[0]['jobs']
                self.assertEqual(len(jobs), 1)
                self.assertEqual(jobs[0]['execution_attempt'], '2')
                self.assertEqual(jobs[0]['conclusion'], conclusion)

    def test_conflicting_duplicates_and_assigned_queued_jobs_fail(self):
        actual = dict(id=1, name='shard', run_id=9, run_attempt=1, head_sha='a',
                      created_at='created', started_at='start', completed_at='end',
                      status='completed', conclusion='success', steps=[dict(name='test')],
                      runner_id=10, runner_name='runner')
        queued = dict(actual, id=2, status='queued', conclusion=None, completed_at=None,
                      steps=[], runner_id=None, runner_name=None)
        for change in (dict(status='in_progress'), dict(runner_id=20), dict(runner_name='assigned'),
                       dict(steps=[dict(name='test')]), dict(conclusion='failure'),
                       dict(completed_at='end'), dict(head_sha='b'), dict(run_attempt=2),
                       dict(created_at='other'), dict(actual, id=2, conclusion='failure')):
            pages = [dict(total_count=2, jobs=[actual, dict(queued, **change)])]
            with self.subTest(change=change), patch('ci_reruns.api_pages', return_value=pages), \
                    self.assertRaisesRegex(ValueError, 'Conflicting duplicate'):
                job_history('owner/repo', '9', '1')


class ResultReuseTests(unittest.TestCase):
    def setUp(self):
        self.context = dict(commit='a', run_id='9', attempt='3')
        self.build = dict(image='release', commit='a', run_id='9', attempt='1', runtime='sha256:image',
                          package_checksums_sha256='package-hash')
        self.builds = {'release': self.build}
        self.shards = [dict(id=n, profile='p', area=n, variant='default', image='release', suite='correctness', reports=0)
                       for n in ('one', 'two')]
        self.rows = [dict(profile='p', variant='default', suite='correctness', id=n, status='not_run') for n in ('one', 'two')]
        self.manifest = dict(include=self.shards, inventory=self.rows)
        self.records = [dict(id=n, commit='a', run_id='9', attempt=str(a), status='passed', build=self.build,
                             matrix_sha256='matrix', seconds=1, scenarios=[dict(self.rows[i], status='passed')])
                        for i, (n, a) in enumerate((('one', 1), ('two', 2)))]
        self.dependencies = {name: dict(result='success') for name in REQUIRED_DEPENDENCIES}
        self.jobs = [dict(jobs=[dict(name='Build release once', conclusion='success', execution_attempt='1'),
                               dict(name='Integration / p / one / default / release', conclusion='success', execution_attempt='1'),
                               dict(name='Integration / p / two / default / release', conclusion='success', execution_attempt='2')])]

    def summary(self):
        return summarize(self.manifest, self.records, self.jobs, self.context, self.builds, 'matrix', self.dependencies)

    def test_mixed_attempts_same_run_and_build_produce_complete_report(self):
        report = self.summary()
        self.assertTrue(report['complete'])
        self.assertEqual(report['provenance']['attempt'], '3')
        self.assertEqual(report['shard_attempts'], {'one': '1', 'two': '2'})
        self.assertEqual(report['profiles']['p']['catalog_passed'], 2)

    def test_other_commits_runs_and_future_attempts_are_rejected(self):
        for change in (dict(commit='b'), dict(run_id='8'), dict(attempt='4'), dict(attempt=None)):
            with self.subTest(change=change):
                records = copy.deepcopy(self.records)
                records[0].update(change)
                with self.assertRaises(ValueError):
                    validate_results(self.manifest, records, self.context, self.builds, 'matrix', self.dependencies)

    def test_failed_job_changed_build_or_matrix_cannot_pass(self):
        for field, value in (('build', dict(self.build, runtime='other')), ('matrix_sha256', 'other')):
            with self.subTest(field=field):
                original = self.records[1]
                self.records[1] = dict(original, **{field: value})
                self.assertFalse(self.summary()['complete'])
                self.assertEqual(self.summary()['stale_shards'], ['two'])
                self.records[1] = original
        self.dependencies['packaging-and-smoke']['result'] = 'failure'
        self.assertFalse(self.summary()['complete'])

    def test_rerun_build_requires_matching_latest_receipt(self):
        self.builds = {'release': dict(self.build, attempt='2')}
        self.assertFalse(self.summary()['complete'])

    def test_old_reporting_failure_does_not_block_its_own_retry(self):
        self.jobs[0]['jobs'].append(dict(name='Full Suite / Release Evidence', conclusion='failure'))
        self.assertTrue(self.summary()['complete'])
        self.jobs[0]['jobs'].append(dict(name='Unit Tests & Catalog Check', conclusion='failure'))
        # REST history is diagnostic. The workflow dependency reports the latest result.
        self.assertTrue(self.summary()['complete'])
        self.dependencies['unit-tests']['result'] = 'failure'
        self.assertFalse(self.summary()['complete'])

    def test_missing_record_still_fails(self):
        self.records.pop()
        self.assertFalse(self.summary()['complete'])

    def test_ci_report_cli_uses_current_attempt_and_retains_shard_attempts(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            matrix = root / 'matrix.json'
            matrix.write_text(json.dumps(dict(self.manifest, scope='full')))
            from ci_reruns import digest
            records = root / 'records'
            records.mkdir()
            for record in self.records:
                (records / (record['id'] + '.json')).write_text(json.dumps(dict(record, matrix_sha256=digest(matrix))))
            jobs = root / 'jobs.json'
            jobs.write_text(json.dumps(self.jobs))
            builds = root / 'builds/ci-build-release'
            builds.mkdir(parents=True)
            (builds / 'build.json').write_text(json.dumps(self.build))
            output = root / 'output'
            env = dict(os.environ, GITHUB_ACTIONS='true', GITHUB_SHA='a', GITHUB_RUN_ID='9', GITHUB_RUN_ATTEMPT='3',
                       CI_JOB_RESULTS=json.dumps(self.dependencies))
            env.pop('GITHUB_STEP_SUMMARY', None)
            command = [sys.executable, str(Path(__file__).with_name('ci_measurements.py')),
                       '--matrix', str(matrix), '--records', str(records), '--jobs', str(jobs),
                       '--builds', str(builds.parent), '--output', str(output), '--optional-job-timings']
            for timing in ('valid', 'missing', 'invalid'):
                if timing == 'missing':
                    jobs.unlink()
                elif timing == 'invalid':
                    jobs.write_text('truncated API response')
                with self.subTest(timing=timing):
                    result = subprocess.run(command, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    report = json.loads((output / 'report.json').read_text())
                    self.assertTrue(report['complete'])
                    self.assertEqual(report['provenance'], self.context)
                    self.assertEqual(report['shard_attempts'], {'one': '1', 'two': '2'})
                    self.assertEqual(report['job_timing_status'], 'available' if timing == 'valid' else 'unavailable')
                    if timing != 'valid':
                        self.assertIsNone(report['completed_job_seconds'])
                        self.assertIn('timing unavailable', (output / 'summary.md').read_text())
                    self.assertEqual(json.loads((output / 'test-value.json').read_text())['provenance'], self.context)
            # An API outage cannot turn a failed rerun with old successful artifacts into a pass.
            self.dependencies['packaging-and-smoke']['result'] = 'failure'
            env['CI_JOB_RESULTS'] = json.dumps(self.dependencies)
            self.assertNotEqual(subprocess.run(command, env=env, capture_output=True).returncode, 0)
            env.pop('CI_JOB_RESULTS')
            self.assertNotEqual(subprocess.run(command, env=env, capture_output=True).returncode, 0)

    def test_missing_or_failed_workflow_dependencies_block_without_history(self):
        self.jobs = None
        self.assertTrue(self.summary()['complete'])
        for name in REQUIRED_DEPENDENCIES:
            for status in ('failure', 'cancelled', 'skipped', None):
                self.dependencies[name]['result'] = status
                with self.subTest(name=name, status=status):
                    self.assertFalse(self.summary()['complete'])
                self.dependencies[name]['result'] = 'success'
            saved = self.dependencies.pop(name)
            with self.assertRaisesRegex(ValueError, 'workflow dependencies'):
                self.summary()
            self.dependencies[name] = saved

    def test_bad_build_origin_and_shards_before_build_are_rejected_without_history(self):
        self.jobs = None
        for changes in (dict(commit='b'), dict(run_id='10'), dict(attempt='4'), dict(attempt=None), dict(runtime='')):
            with self.subTest(changes=changes):
                self.builds = {'release': dict(self.build, **changes)}
                with self.assertRaisesRegex(ValueError, 'Build identity differs'):
                    self.summary()
        self.builds = {'release': dict(self.build, attempt='2')}
        for record in self.records:
            record['build'] = self.builds['release']
        self.assertEqual(self.summary()['stale_shards'], ['one'])

    def test_shard_records_build_identity_before_execution(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            image = root / 'artifacts/ci/image'
            image.mkdir(parents=True)
            (image / 'build.json').write_text(json.dumps(self.build))
            (image.parent / 'matrix.json').write_text('{}')
            with record_shard(root, 'one', build_inputs=True):
                pass
            record = json.loads((root / 'artifacts/ci/measurements/one.json').read_text())
            self.assertEqual(record['build'], self.build)
            self.assertEqual(record['status'], 'passed')
            self.assertEqual(len(record['matrix_sha256']), 64)
            (image / 'build.json').unlink()
            with self.assertRaises(FileNotFoundError):
                with record_shard(root, 'two', build_inputs=True):
                    self.fail('Missing identity must stop test execution')
            failed = json.loads((root / 'artifacts/ci/measurements/two.json').read_text())
            self.assertEqual(failed['status'], 'failed')

    def test_registry_and_archive_build_identity_include_package_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            image = root / 'artifacts/ci/image'
            image.mkdir(parents=True)
            release = root / 'artifacts/release'
            release.mkdir(parents=True)
            (release / 'SHA256SUMS').write_text('first packages')
            (image / 'image.tar.gz').write_bytes(b'image')
            env = dict(GITHUB_SHA='a', GITHUB_RUN_ID='9', GITHUB_RUN_ATTEMPT='1')
            first = build_identity(root, 'release', env)
            self.assertTrue(first['runtime'].startswith('archive-sha256:'))
            (release / 'SHA256SUMS').write_text('different packages')
            self.assertNotEqual(first['package_checksums_sha256'], build_identity(root, 'release', env)['package_checksums_sha256'])
            (image / 'image.json').write_text(json.dumps(dict(image='release', commit='a', reference='registry@sha256:abc')))
            self.assertEqual(build_identity(root, 'release', env)['runtime'], 'registry@sha256:abc')
            with self.assertRaises(ValueError):
                build_identity(root, 'coverage', env)


if __name__ == '__main__':
    unittest.main()
