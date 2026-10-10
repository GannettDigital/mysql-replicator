import copy
import unittest

from ci_matrix import generate, key


def row(identifier, family='database', suite='correctness', profile='forward',
        variant='default', **extra):
    return dict(id=identifier, family=family, suite=suite, profile=profile,
                variant=variant, status='not_run', dependencies=[], **extra)


class MatrixTests(unittest.TestCase):
    def setUp(self):
        self.policy = dict(areas=[dict(name='database', families=['database'], size=2),
                                 dict(name='failure-recovery-offline', families=['failures', 'recovery', 'offline'])],
                           sample=dict(profile='forward', cases=['create']),
                           demo_reports=dict(forward=4, reverse=5))
        self.rows = [row('create'), row('alter'), row('drop'),
                     row('reconnect', suite='lifecycle'), row('demo-start', suite='demo'),
                     row('native', suite='native'), row('retry', suite='recovery', profile='reverse')]
        self.rows[2]['dependencies'] = ['create']
        for variant in ['position-minimal', 'gtid-full']:
            self.rows += [row('create', variant=variant), row('reconnect', suite='lifecycle', variant=variant)]
        self.rows += [row('create', profile='reverse'), row('demo-start', suite='demo', profile='reverse')]

    def generate(self):
        return generate([dict(scenarios=self.rows)], self.policy)

    def test_full_inventory_dependency_closure_and_coverage_collections(self):
        result = self.generate()
        covered = set()
        for shard in result['include']:
            covered.update((shard['profile'], shard['variant'], shard['suite'], c) for c in shard['cases'])
        self.assertEqual(covered, {key(r) for r in self.rows})
        self.assertEqual(result['obligations'], len(self.rows))
        self.assertEqual(result['coverage_reports'], 12)
        second = next(s for s in result['include'] if s['area'] == 'database-2')
        self.assertEqual(second['cases'], ['create', 'drop'])
        self.assertEqual(len(result['include']), len({s['id'] for s in result['include']}))

    def test_expanded_coverage_adds_runs_without_replacing_release_obligations(self):
        baseline = self.generate()
        measured = generate([dict(scenarios=self.rows)], self.policy, expanded_coverage=True)
        self.assertEqual(baseline['inventory'], measured['inventory'])
        self.assertEqual(baseline['obligations'], measured['obligations'])
        self.assertTrue(all(s in measured['include'] for s in baseline['include']))
        self.assertGreater(measured['coverage_reports'], baseline['coverage_reports'])
        for s in measured['include']:
            if s not in baseline['include']:
                self.assertEqual(s['image'], 'coverage')
                self.assertIn(s['suite'], ['correctness', 'lifecycle'])
                original = next(b for b in baseline['include'] if b['id'] == s['id'].replace('coverage-', 'release-', 1))
                self.assertEqual(original['cases'], s['cases'])

    def test_new_case_and_variant_automatically_enter_ci(self):
        self.rows += [row('new-case'), row('new-mode', variant='new-variant')]
        result = self.generate()
        self.assertTrue(any('new-case' in s['cases'] for s in result['include']))
        self.assertTrue(any(s['variant'] == 'new-variant' for s in result['include']))

    def test_unknown_family_or_suite_fails_instead_of_omitting_coverage(self):
        for extra, reason in [(row('new', family='new-family'), 'unassigned correctness families'),
                              (row('new', suite='new-suite'), 'unassigned suite')]:
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(ValueError, reason):
                    generate([dict(scenarios=self.rows + [extra])], self.policy)

    def test_unavailable_cases_remain_in_inventory_but_not_jobs(self):
        skipped = row('unavailable', family='new-family')
        skipped.update(status='not_applicable', reason='unsupported topology')
        self.rows.append(skipped)
        result = self.generate()
        self.assertEqual(result['obligations'], len(self.rows) - 1)
        self.assertIn(skipped, result['inventory'])
        self.assertFalse(any('unavailable' in s['cases'] for s in result['include']))

    def test_failure_recovery_offline_remain_in_one_fixture(self):
        self.rows += [row('fail', family='failures'), row('recover', family='recovery'),
                      row('offline', family='offline'), row('control', family='offline')]
        shard = next(s for s in self.generate()['include'] if s['area'] == 'failure-recovery-offline')
        self.assertEqual(shard['cases'], ['fail', 'recover', 'offline', 'control'])

    def test_missing_or_cyclic_dependencies_fail(self):
        for dependency, message in [('missing', 'missing applicable dependency'), ('drop', 'cyclic dependency')]:
            with self.subTest(dependency=dependency):
                self.rows[2]['dependencies'] = [dependency]
                with self.assertRaisesRegex(ValueError, message):
                    self.generate()

    def test_conflicting_catalog_duplicates_fail(self):
        changed = dict(self.rows[0], status='not_applicable')
        with self.assertRaisesRegex(ValueError, 'conflicting catalog'):
            generate([dict(scenarios=self.rows), dict(scenarios=[changed])], self.policy)
        result = generate([dict(scenarios=self.rows)] * 2, self.policy)
        self.assertEqual(result['obligations'], len(self.rows))

    def test_ambiguous_policy_and_missing_sample_fail(self):
        policy = copy.deepcopy(self.policy)
        policy['areas'][1]['families'].append('database')
        with self.assertRaisesRegex(ValueError, 'multiple areas'):
            generate([dict(scenarios=self.rows)], policy)
        self.policy['sample']['cases'] = ['removed-case']
        with self.assertRaisesRegex(ValueError, 'sample case missing'):
            self.generate()

    def test_empty_or_oversized_matrix_fails(self):
        with self.assertRaisesRegex(ValueError, 'empty lab catalog'):
            generate([dict(scenarios=[])], self.policy)
        self.rows += [row('create', variant=f'variant-{i}') for i in range(260)]
        with self.assertRaisesRegex(ValueError, '256 jobs'):
            self.generate()


if __name__ == '__main__':
    unittest.main()
