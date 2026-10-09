import unittest
from unittest.mock import Mock

from qualification_inputs import REQUIRED, select_run


def run(identifier=1, **changes):
    return dict(databaseId=identifier, headSha='exact', headBranch='main', event='push',
                status='completed', conclusion='success') | changes


def retained():
    return [dict(name=name, expired=False) for name in REQUIRED]


class QualificationInputsTests(unittest.TestCase):
    def test_selects_exact_successful_main_commit(self):
        artifacts = Mock(return_value=retained())
        self.assertEqual(select_run([run()], 'exact', artifacts), 1)
        artifacts.assert_called_once_with(1)

    def test_never_uses_another_commit_branch_event_or_unsuccessful_run(self):
        for changes in [dict(headSha='old'), dict(headBranch='feature'),
                        dict(event='pull_request'), dict(status='in_progress'),
                        dict(conclusion='failure'), dict(conclusion='cancelled')]:
            with self.subTest(changes=changes):
                artifacts = Mock()
                with self.assertRaisesRegex(ValueError, 'exact commit'):
                    select_run([run(**changes)], 'exact', artifacts)
                artifacts.assert_not_called()

    def test_requires_all_artifacts_retained_in_one_run(self):
        for missing in REQUIRED:
            with self.subTest(missing=missing):
                artifacts = Mock(return_value=[a for a in retained() if a['name'] != missing])
                with self.assertRaisesRegex(ValueError, 'retained'):
                    select_run([run()], 'exact', artifacts)
        with self.assertRaises(ValueError):
            select_run([run(1), run(2)], 'exact',
                       lambda i: [dict(name='ci-lab' if i == 1 else 'ci-image-release', expired=False)])

    def test_expired_newest_run_falls_back_only_to_same_commit(self):
        artifacts = lambda i: [dict(name=n, expired=(i == 1)) for n in REQUIRED]
        self.assertEqual(select_run([run(1), run(2)], 'exact', artifacts), 2)
        with self.assertRaisesRegex(ValueError, 'expired'):
            select_run([run(1), run(2, headSha='old')], 'exact', artifacts)

    def test_no_runs_reports_prerequisite(self):
        with self.assertRaisesRegex(ValueError, 'Wait for main CI'):
            select_run([], 'exact', Mock())


if __name__ == '__main__':
    unittest.main()
