import copy
import hashlib
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from release_evidence import REQUIRED_JOBS, PRODUCTION_JOBS, create, verify, validate_test_run, find_tests


class ReleaseEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tree = 'd' * 40
        self.env = dict(GITHUB_SHA='a' * 40, GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='2',
                        GITHUB_REPOSITORY='owner/repo', GITHUB_EVENT_NAME='pull_request', GITHUB_REF='refs/pull/10/merge')
        self.report = dict(complete=True, scope='full', coverage_mode='all',
                           provenance=dict(commit='a' * 40, run_id='123', attempt='2'),
                           profiles={'profile': dict(catalog_expected=10, catalog_passed=10,
                                                     catalog_missing=[], coverage_collections=2)},
                           builds={'coverage': dict(image='coverage', commit='a' * 40, run_id='123', attempt='1')},
                           shard_attempts={'one': '1', 'two': '2'})
        self.jobs = {name: {'result': 'success'} for name in REQUIRED_JOBS}
        self.run = dict(id=123, run_attempt=2, head_sha='b' * 40, event='pull_request',
                        repository=dict(full_name='owner/repo'), head_repository=dict(full_name='owner/repo'),
                        path='.github/workflows/ci.yml', status='completed', conclusion='success')
        self.commit = dict(sha='a' * 40, tree=dict(sha=self.tree), parents=[dict(sha='b' * 40)])
        self.checksums = b'checksums from production packages\n'
        self.production_env = dict(self.env, GITHUB_SHA='c' * 40, GITHUB_RUN_ID='456', GITHUB_RUN_ATTEMPT='1',
                                   CI_RUN_ID='456', CI_RUN_ATTEMPT='1', GITHUB_EVENT_NAME='push', GITHUB_REF='refs/heads/main')

    def full_receipt(self):
        return create(self.report, self.jobs, self.env, '0.1.0-beta.7', self.tree)

    def production(self):
        report = copy.deepcopy(self.report)
        report.update(scope='production', coverage_mode='none', provenance=dict(commit='c' * 40, run_id='456', attempt='1'),
                      builds={'release': dict(image='release', commit='c' * 40, run_id='456', attempt='1',
                         package_checksums_sha256=hashlib.sha256(self.checksums).hexdigest())}, shard_attempts={'one': '1'})
        receipt = create(report, {n: dict(result='success') for n in PRODUCTION_JOBS}, self.production_env,
                         '0.1.0-beta.7', self.tree)
        receipt['tested_source'] = dict(tests=self.full_receipt(), run=self.run, commit=self.commit)
        return receipt

    def verify(self, receipt, **env):
        verify(receipt, self.checksums, dict(self.production_env, **env), '0.1.0-beta.7', self.tree)

    def test_squash_commit_can_promote_same_tree_and_exact_packages(self):
        receipt = self.production()
        self.assertNotEqual(receipt['provenance']['commit'], receipt['tested_source']['tests']['provenance']['commit'])
        self.verify(receipt)

    def test_partial_or_smoke_runs_and_failed_required_jobs_are_rejected(self):
        for changes in ({'complete': False}, {'scope': 'pr-smoke'}, {'profiles': {}}, {'coverage_mode': 'selected'},
                        {'provenance': dict(commit='a' * 40, run_id='123', attempt='3')}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                create(dict(self.report, **changes), self.jobs, self.env, 'v', self.tree)
        for job in REQUIRED_JOBS:
            for outcome in ('failure', 'skipped', 'cancelled'):
                with self.subTest(job=job, outcome=outcome), self.assertRaises(ValueError):
                    create(self.report, dict(self.jobs, **{job: dict(result=outcome)}), self.env, 'v', self.tree)

    def test_failed_production_checks_cannot_promote(self):
        receipt = self.production()
        for job in PRODUCTION_JOBS:
            bad = copy.deepcopy(receipt)
            bad['jobs'][job] = 'failure'
            with self.subTest(job=job), self.assertRaises(ValueError):
                self.verify(bad)

    def test_evidence_retry_can_reuse_prior_successful_report_and_build(self):
        self.report['provenance']['attempt'] = '1'
        self.report['shard_attempts'] = {'one': '1'}
        tests = self.full_receipt()
        self.assertEqual(tests['provenance']['attempt'], '2')
        self.assertEqual(tests['report_attempt'], '1')
        self.verify(self.production())

    def test_full_test_tree_and_github_records_must_match(self):
        for change in ('receipt-tree', 'api-tree', 'head', 'workflow', 'fork', 'failed', 'attempt', 'repository'):
            tests, run, commit = copy.deepcopy((self.full_receipt(), self.run, self.commit))
            if change == 'receipt-tree': tests['source_tree'] = 'e' * 40
            if change == 'api-tree': commit['tree']['sha'] = 'e' * 40
            if change == 'head': run['head_sha'] = 'f' * 40
            if change == 'workflow': run['path'] = '.github/workflows/untrusted.yml'
            if change == 'fork': run['head_repository']['full_name'] = 'fork/repo'
            if change == 'failed': run['conclusion'] = 'failure'
            if change == 'attempt': run['run_attempt'] = 3
            if change == 'repository': run['repository']['full_name'] = 'other/repo'
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_test_run(tests, run, commit, 'owner/repo', self.tree)

    def test_manual_full_run_requires_its_exact_head(self):
        self.env.update(GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_REF='refs/heads/main')
        self.run.update(event='workflow_dispatch', head_sha='a' * 40)
        self.verify(self.production())
        self.run['head_sha'] = 'b' * 40
        with self.assertRaises(ValueError):
            self.verify(self.production())

    def test_changed_package_version_commit_run_and_tree_cannot_promote(self):
        evidence = self.production()
        for changes in ({'GITHUB_SHA': 'b' * 40}, {'CI_RUN_ID': '789'}, {'CI_RUN_ATTEMPT': '3'},
                        {'GITHUB_REPOSITORY': 'other/repo'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify(evidence, **changes)
        for checksums, version, tree in [(b'other', '0.1.0-beta.7', self.tree),
                                        (self.checksums, 'other', self.tree),
                                        (self.checksums, '0.1.0-beta.7', 'e' * 40)]:
            with self.assertRaises(ValueError):
                verify(evidence, checksums, self.production_env, version, tree)

    def test_foreign_build_and_incomplete_catalog_are_rejected(self):
        self.report['builds']['coverage']['run_id'] = 'other'
        with self.assertRaises(ValueError): self.full_receipt()
        self.report['builds']['coverage']['run_id'] = '123'
        self.report['profiles']['profile']['catalog_passed'] = 9
        with self.assertRaises(ValueError): self.full_receipt()

    def test_find_tests_uses_artifact_and_independent_github_commit(self):
        responses = [{'workflow_runs': [self.run]}, {'artifacts': [dict(name='full-test-evidence', expired=False)]}, self.commit]
        def download(command, **_):
            directory = command[command.index('--dir') + 1]
            (Path(directory) / 'full-test-evidence.json').write_text(json.dumps(self.full_receipt()))
        with patch('release_evidence.api', side_effect=responses) as api, patch('release_evidence.subprocess.run', side_effect=download):
            linked = find_tests(self.env, self.tree)
            self.assertEqual(linked['tests'], self.full_receipt())
            self.assertIn('/git/commits/' + 'a' * 40, api.call_args.args[0])

    def test_deleted_fork_is_skipped_during_lookup(self):
        run = dict(self.run, head_repository=None)
        with patch('release_evidence.api', return_value={'workflow_runs': [run]}) as api, \
                self.assertRaisesRegex(ValueError, 'No successful full test'):
            find_tests(self.env, self.tree)
        self.assertEqual(api.call_count, 1)

    def test_expired_or_missing_full_results_fail_closed(self):
        for artifacts in ([], [dict(name='full-test-evidence', expired=True)]):
            with patch('release_evidence.api', side_effect=[{'workflow_runs': [self.run]}, {'artifacts': artifacts}]), self.assertRaisesRegex(ValueError, 'No successful full test'):
                find_tests(self.env, self.tree)


if __name__ == '__main__':
    unittest.main()
