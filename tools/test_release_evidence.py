import copy
import hashlib
import unittest

from release_evidence import REQUIRED_JOBS, create, verify


class ReleaseEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.env = dict(GITHUB_SHA='a' * 40, GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='2',
                        GITHUB_REPOSITORY='owner/repo', GITHUB_EVENT_NAME='push', GITHUB_REF='refs/heads/main',
                        CI_RUN_ID='123', CI_RUN_ATTEMPT='2')
        self.report = dict(complete=True, scope='full', coverage_mode='selected',
                           provenance=dict(commit='a' * 40, run_id='123', attempt='2'),
                           profiles={'profile': dict(catalog_expected=10, catalog_passed=10,
                                                     catalog_missing=[], coverage_collections=2)})
        self.jobs = {name: {'result': 'success'} for name in REQUIRED_JOBS}
        self.checksums = b'checksums from the package build\n'
        self.report['builds'] = {'release': dict(image='release', commit='a' * 40, run_id='123', attempt='1',
            package_checksums_sha256=hashlib.sha256(self.checksums).hexdigest())}
        self.report['shard_attempts'] = {'one': '1', 'two': '2'}

    def create(self):
        return create(self.report, self.jobs, self.checksums, self.env, '0.1.0-beta.4')

    def verify(self, evidence, **env):
        verify(evidence, self.checksums, dict(self.env, **env), '0.1.0-beta.4')

    def test_exact_main_packages_can_be_promoted(self):
        evidence = self.create()
        self.verify(evidence)
        self.assertIn('/attempts/2', evidence['run_url'])

    def test_partial_smoke_and_wrong_attempt_reports_cannot_certify(self):
        for changes in ({'complete': False}, {'scope': 'pr-smoke'}, {'profiles': {}},
                        {'provenance': dict(commit='a' * 40, run_id='123', attempt='3')}):
            with self.subTest(changes=changes):
                report = dict(self.report, **changes)
                with self.assertRaises(ValueError):
                    create(report, self.jobs, self.checksums, self.env, 'v')
        self.report['profiles']['profile']['catalog_passed'] = 9
        with self.assertRaises(ValueError):
            self.create()

    def test_evidence_only_retry_can_reuse_earlier_valid_report(self):
        self.report['provenance']['attempt'] = '1'
        self.report['shard_attempts'] = {'one': '1'}
        evidence = self.create()
        self.assertEqual(evidence['provenance']['attempt'], '2')
        self.assertEqual(evidence['report_attempt'], '1')
        self.verify(evidence)

    def test_rebuilt_packages_and_foreign_build_identity_are_rejected(self):
        self.report['builds']['release']['package_checksums_sha256'] = 'other'
        with self.assertRaisesRegex(ValueError, 'packages differ'):
            self.create()
        self.report['builds']['release']['package_checksums_sha256'] = hashlib.sha256(self.checksums).hexdigest()
        self.report['builds']['release']['run_id'] = 'other'
        with self.assertRaisesRegex(ValueError, 'build belongs'):
            self.create()

    def test_every_required_job_must_succeed(self):
        for job in REQUIRED_JOBS:
            for outcome in ('failure', 'skipped', 'cancelled'):
                jobs = copy.deepcopy(self.jobs)
                jobs[job]['result'] = outcome
                with self.subTest(job=job, outcome=outcome), self.assertRaises(ValueError):
                    create(self.report, jobs, self.checksums, self.env, 'v')
            jobs = dict(self.jobs)
            del jobs[job]
            with self.assertRaises(ValueError):
                create(self.report, jobs, self.checksums, self.env, 'v')

    def test_other_commits_runs_attempts_and_repositories_cannot_promote(self):
        evidence = self.create()
        for changes in ({'GITHUB_SHA': 'b' * 40}, {'CI_RUN_ID': '456'}, {'CI_RUN_ATTEMPT': '3'},
                        {'GITHUB_REPOSITORY': 'other/repo'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify(evidence, **changes)

    def test_changed_packages_or_version_cannot_promote(self):
        evidence = self.create()
        with self.assertRaisesRegex(ValueError, 'packages differ'):
            verify(evidence, b'other checksum manifest', self.env, '0.1.0-beta.4')
        with self.assertRaisesRegex(ValueError, 'version differs'):
            verify(evidence, self.checksums, self.env, '0.1.0-beta.5')

    def test_full_pr_or_manual_run_is_evidence_but_not_release_authority(self):
        for event, ref in [('pull_request', 'refs/pull/10/merge'), ('workflow_dispatch', 'refs/heads/main')]:
            self.env.update(GITHUB_EVENT_NAME=event, GITHUB_REF=ref)
            evidence = self.create()
            with self.assertRaisesRegex(ValueError, 'main push evidence'):
                self.verify(evidence)

    def test_invalid_receipts_cannot_promote(self):
        for field, value in [('format_version', 1), ('scope', 'pr-smoke'), ('jobs', {}), ('profiles', {})]:
            evidence = dict(self.create(), **{field: value})
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.verify(evidence)
