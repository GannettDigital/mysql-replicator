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

    def test_expanded_label_implies_full_and_survives_full_label_removal(self):
        for action in ('opened', 'synchronize', 'reopened', 'labeled'):
            self.assertEqual(select('pull_request', self.pr(action, ['ci-expanded-coverage'], 'ci-expanded-coverage')),
                             dict(scope='full', expanded=True))
        self.assertEqual(select('pull_request', self.pr('unlabeled', ['ci-expanded-coverage'], 'ci-full')),
                         dict(scope='full', expanded=True))
        self.assertEqual(select('pull_request', self.pr('unlabeled', ['ci-full'], 'ci-expanded-coverage')),
                         dict(scope='full', expanded=False))
        self.assertEqual(select('pull_request', self.pr('unlabeled', [], 'ci-expanded-coverage')),
                         dict(scope='pr-smoke', expanded=False))
        self.assertIsNone(select('pull_request', self.pr('labeled', ['ci-expanded-coverage'], 'documentation')))

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


class ChangedScopeTests(unittest.TestCase):
    def test_labels_main_and_manual_selection_override_safe_paths(self):
        from ci_scope import resolve
        from test_selection import select_changes
        docs = select_changes(['README.md'])
        pr = ScopeTests().pr()
        self.assertEqual(resolve('pull_request', pr, docs)['scope'], 'docs')
        for label in ('ci-full', 'ci-expanded-coverage'):
            result = resolve('pull_request', ScopeTests().pr(labels=[label]), docs)
            self.assertEqual(result['scope'], 'full')
            self.assertEqual(result['selected_by'], [])
            self.assertTrue(result['checks']['integration'])
        for event, data, scope in [('push', {'ref': 'refs/heads/main'}, 'full'),
                                   ('workflow_dispatch', {}, 'full'),
                                   ('workflow_dispatch', {'inputs': {'suite': 'pr-smoke'}}, 'pr-smoke')]:
            self.assertEqual(resolve(event, data, docs)['scope'], scope)
        self.assertEqual(resolve('pull_request', pr)['scope'], 'full')
        self.assertIsNone(resolve('pull_request', ScopeTests().pr('labeled', changed='unrelated'), docs))

    def test_gate_requires_selected_checks_and_exact_intentional_skips(self):
        from ci_scope import check_results
        for scope in ('docs', 'tools', 'pr-smoke', 'full'):
            results = {job: {'result': 'success'} for job in
                       ('select-suite', 'tool-tests', 'unit-tests', 'periphery', 'lab-tools', 'build-images', 'integration')}
            if scope in ('docs', 'tools'):
                for job in ('unit-tests', 'periphery', 'lab-tools', 'build-images', 'integration'):
                    results[job]['result'] = 'skipped'
            check_results(scope, results)
            for job in results:
                for bad in ('failure', 'cancelled', None):
                    changed = dict(results, **{job: {'result': bad}})
                    with self.subTest(scope=scope, job=job, result=bad), self.assertRaises(ValueError):
                        check_results(scope, changed)
            unexpected = dict(results, **{'tool-tests': {'result': 'skipped'}})
            with self.assertRaises(ValueError):
                check_results(scope, unexpected)
        with self.assertRaises(ValueError):
            check_results('pr-smoke', {job: {'result': 'skipped'} for job in results})
