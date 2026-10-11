import unittest

from ci_scope import select


class ScopeTests(unittest.TestCase):
    def pr(self, action='synchronize', labels=(), changed=None):
        return dict(action=action, pull_request=dict(labels=[dict(name=n) for n in labels]),
                    label=dict(name=changed))

    def test_normal_pr_is_smoke_and_labeled_stack_tip_is_full(self):
        for action in ('opened', 'synchronize', 'reopened'):
            self.assertEqual(select('pull_request', self.pr(action))['scope'], 'pr-smoke')
            self.assertEqual(select('pull_request', self.pr(action, ['ci-full']))['scope'], 'full')

    def test_add_and_remove_full_label(self):
        self.assertEqual(select('pull_request', self.pr('labeled', ['ci-full'], 'ci-full'))['scope'], 'full')
        self.assertEqual(select('pull_request', self.pr('unlabeled', [], 'ci-full'))['scope'], 'pr-smoke')

    def test_unrelated_label_does_not_run_or_downgrade_full_ci(self):
        for action in ('labeled', 'unlabeled'):
            self.assertIsNone(select('pull_request', self.pr(action, ['ci-full'], 'documentation')))

    def test_main_and_default_manual_runs_are_full(self):
        self.assertEqual(select('push', {'ref': 'refs/heads/main'}), dict(scope='full', expanded=False))
        self.assertEqual(select('workflow_dispatch', {}), dict(scope='full', expanded=False))

    def test_manual_inputs_and_invalid_combinations(self):
        for enabled in (True, 'true'):
            self.assertEqual(select('workflow_dispatch', {'inputs': {'expanded_coverage': enabled}}),
                             dict(scope='full', expanded=True))
        self.assertEqual(select('workflow_dispatch', {'inputs': {'suite': 'pr-smoke', 'expanded_coverage': 'false'}}),
                         dict(scope='pr-smoke', expanded=False))
        for inputs in ({'suite': 'invalid'}, {'suite': 'pr-smoke', 'expanded_coverage': 'true'}):
            with self.assertRaises(ValueError):
                select('workflow_dispatch', {'inputs': inputs})
        for event, payload in [('push', {'ref': 'refs/heads/feature'}), ('release', {})]:
            with self.assertRaises(ValueError):
                select(event, payload)
