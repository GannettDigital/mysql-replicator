import copy
import unittest

from ci_matrix import SMOKE_PROFILES, case_groups, generate, generate_smoke, generate_production, key


def row(identifier, family='database', suite='correctness', profile='forward',
        variant='default', **extra):
    return dict(id=identifier, family=family, suite=suite, profile=profile,
                variant=variant, status='not_run', dependencies=[], **extra)


class MatrixTests(unittest.TestCase):
    def setUp(self):
        self.policy = dict(areas=[dict(name='database', families=['database'], size=2),
                                 dict(name='failure-recovery-offline', families=['failures', 'recovery', 'offline'])],
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
        self.assertEqual(result['coverage_reports'], 18)
        second = next(s for s in result['include'] if s['area'] == 'database-2')
        self.assertEqual(second['cases'], ['create', 'drop'])
        self.assertEqual(len(result['include']), len({s['id'] for s in result['include']}))

    def test_all_apply_tests_are_instrumented_once_and_old_flag_is_an_alias(self):
        result = self.generate()
        self.assertEqual(result, generate([dict(scenarios=self.rows)], self.policy, expanded_coverage=True))
        self.assertEqual(result['images'], ['coverage'])
        self.assertEqual(result['coverage_mode'], 'all')
        self.assertEqual(result['coverage_baseline_groups'], [])
        self.assertTrue(all(s['image'] == 'coverage' and s['owns_obligations'] for s in result['include']))
        self.assertTrue(all(s['reports'] > 0 for s in result['include'] if s['suite'] != 'native'))
        self.assertFalse(any(s['area'] == 'smoke' for s in result['include']))

    def test_new_case_and_variant_automatically_enter_ci(self):
        self.rows += [row('new-case'), row('new-mode', variant='new-variant')]
        result = self.generate()
        self.assertTrue(any('new-case' in s['cases'] for s in result['include']))
        self.assertTrue(any(s['variant'] == 'new-variant' for s in result['include']))

    def test_reviewed_boundaries_preserve_order_and_include_new_cases(self):
        area = dict(name='ddl', split_after=['b', 'd'])
        self.assertEqual(case_groups(['a', 'b', 'c', 'd', 'e'], area),
                         [['a', 'b'], ['c', 'd'], ['e']])
        self.assertEqual(case_groups(['a', 'new', 'b', 'c', 'd', 'e', 'later'], area),
                         [['a', 'new', 'b'], ['c', 'd'], ['e', 'later']])

    def test_invalid_boundaries_fail_before_planning_jobs(self):
        for anchors in [[], 'b', ['missing'], [None], ['b', 'b'], ['c', 'b'], ['d']]:
            with self.subTest(anchors=anchors), self.assertRaisesRegex(ValueError, 'split_after'):
                case_groups(['a', 'b', 'c', 'd'], dict(name='ddl', split_after=anchors))
        with self.assertRaisesRegex(ValueError, 'cannot use size'):
            case_groups(['a', 'b'], dict(name='ddl', split_after=['a'], size=1))

    def test_reviewed_boundary_keeps_dependency_closure_and_coverage_copies(self):
        # Each profile/variant needs both sides of its declared boundary.
        rows = [row('create'), row('alter'), dict(row('drop'), dependencies=['create'])]
        policy = copy.deepcopy(self.policy)
        policy['areas'][0].pop('size')
        policy['areas'][0]['split_after'] = ['alter']
        result = generate([dict(scenarios=rows)], policy, expanded_coverage=True)
        for image in ['coverage']:
            groups = [s for s in result['include'] if s['image'] == image and s['area'].startswith('database-')]
            self.assertEqual([s['cases'] for s in groups], [['create', 'alter'], ['create', 'drop']])
        self.assertEqual(result['obligations'], 3)
        self.assertEqual(result['inventory'], rows)
        with self.assertRaisesRegex(ValueError, 'not applicable'):
            generate([dict(scenarios=[rows[0], rows[2]])], policy)

    def test_gtids_disabled_subset_does_not_use_full_family_boundaries(self):
        rows = self.rows[:3] + [dict(row('create'), variant='without-source-gtids')]
        policy = copy.deepcopy(self.policy)
        policy['areas'][0].pop('size')
        policy['areas'][0]['split_after'] = ['create']
        result = generate([dict(scenarios=rows)], policy)
        self.assertEqual(result['obligations'], len(rows))
        shard = next(s for s in result['include'] if s['variant'] == 'without-source-gtids')
        self.assertEqual(shard['cases'], ['create'])

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

    def test_ambiguous_policy_fails(self):
        policy = copy.deepcopy(self.policy)
        policy['areas'][1]['families'].append('database')
        with self.assertRaisesRegex(ValueError, 'multiple areas'):
            generate([dict(scenarios=self.rows)], policy)

    def test_binlog_selection_is_separate_and_checks_dependencies(self):
        self.policy['binlog_selections'] = [dict(area='rows', suite='correctness',
                                               profiles=['forward'], cases=['drop'])]
        result = self.generate()
        shard = next(s for s in result['include'] if s.get('dml_transport') == 'binlog')
        self.assertEqual(shard['cases'], ['create', 'drop'])
        self.assertEqual(shard['area'], 'binlog-rows')
        self.assertEqual(shard['image'], 'coverage')
        self.assertFalse(shard['owns_obligations'])
        self.assertEqual(result['obligations'], len(self.rows))
        expanded = generate([dict(scenarios=self.rows)], self.policy, expanded_coverage=True)
        copies = [s for s in expanded['include'] if s.get('dml_transport') == 'binlog']
        self.assertEqual({s['image'] for s in copies}, {'coverage'})
        for invalid in [[], ['missing'], ['drop', 'drop']]:
            self.policy['binlog_selections'][0]['cases'] = invalid
            with self.subTest(cases=invalid), self.assertRaises(ValueError):
                self.generate()

    def test_empty_catalog_fails_but_execution_groups_can_exceed_job_limit(self):
        with self.assertRaisesRegex(ValueError, 'empty lab catalog'):
            generate([dict(scenarios=[])], self.policy)
        self.rows += [row('create', variant=f'variant-{i}') for i in range(260)]
        self.assertGreater(len(self.generate()['include']), 256)
        # ci_jobs validates the job count after assigning complete groups.

    def test_smoke_owns_only_two_default_profile_selections(self):
        rows = [row('create', profile=p) for p in SMOKE_PROFILES]
        rows += [row('new-smoke', profile=p) for p in SMOKE_PROFILES]
        rows[2]['dependencies'] = ['create']
        rows.append(dict(row('unavailable', profile=SMOKE_PROFILES[0]), status='not_applicable'))
        rows += [row('full-only', profile=p) for p in SMOKE_PROFILES]
        selection = dict(area='ddl-dml-policy-replay', cases=['new-smoke', 'create'])
        result = generate_smoke([dict(scenarios=rows)], selection)
        self.assertEqual(result['scope'], 'pr-smoke')
        self.assertEqual(result['images'], ['coverage'])
        self.assertEqual(result['obligations'], 4)
        self.assertEqual({key(r) for r in result['inventory']}, {key(r) for r in rows[:4]})
        self.assertEqual(result['coverage_reports'], 2)
        self.assertEqual(len(result['include']), 2)
        for shard in result['include']:
            self.assertTrue(shard['owns_obligations'])
            self.assertEqual(shard['cases'], ['create', 'new-smoke'])
            self.assertEqual((shard['suite'], shard['tier'], shard['variant']), ('correctness', 'full', 'default'))
            self.assertEqual(shard['area'], selection['area'])

    def test_pr_cases_are_not_repeated_as_supplemental_full_runs(self):
        rows = [row(c, profile=p) for p in SMOKE_PROFILES for c in ['create', 'alter', 'full-only']]
        policy = dict(areas=[dict(name='database', families=['database'])], demo_reports={},
                      pr_smoke=dict(area='selected', cases=['create']))
        full = generate([dict(scenarios=rows)], policy)
        self.assertEqual(len(full['include']), 2)
        self.assertEqual(full['obligations'], 6)
        self.assertTrue(all(g['cases'] == ['create', 'alter', 'full-only'] for g in full['include']))

    def test_production_checks_only_apply_checkpoint_and_resume(self):
        rows = [row(c, profile=p) for p in SMOKE_PROFILES for c in ['positive', 'offline-replay', 'other']]
        result = generate_production([dict(scenarios=rows)])
        self.assertEqual((result['scope'], result['images'], result['coverage_reports']),
                         ('production', ['release'], 0))
        self.assertEqual(result['obligations'], 4)
        self.assertEqual(len(result['include']), 2)
        for group in result['include']:
            self.assertEqual(group['cases'], ['positive', 'offline-replay'])
            self.assertTrue(group['owns_obligations'])
            self.assertEqual(group['image'], 'release')
        with self.assertRaises(ValueError):
            generate_production([dict(scenarios=[r for r in rows if r['id'] != 'offline-replay'])])

    def test_pr_selection_rejects_empty_duplicate_and_unknown_cases(self):
        rows = [row('create', profile=p) for p in SMOKE_PROFILES]
        for cases in ([], ['create', 'create'], ['typo'], 'create', [None]):
            with self.subTest(cases=cases), self.assertRaises(ValueError):
                generate_smoke([dict(scenarios=rows)], dict(area='selected', cases=cases))

    def test_smoke_rejects_missing_profiles_variants_duplicates_and_dependencies(self):
        rows = [row('create', profile=p) for p in SMOKE_PROFILES]
        invalid = [rows[:1], rows + rows[:1],
                   [dict(rows[0], variant='position-minimal'), rows[1]],
                   [dict(rows[0], dependencies=['missing']), rows[1]],
                   [dict(rows[0], dependencies=['create']), rows[1]],
                   [dict(rows[0], status='not_applicable'), rows[1]]]
        for selected in invalid:
            with self.subTest(rows=selected), self.assertRaises(ValueError):
                generate_smoke([dict(scenarios=selected)], dict(area='selected', cases=['create']))


if __name__ == '__main__':
    unittest.main()
