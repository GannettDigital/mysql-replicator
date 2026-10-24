import copy
import unittest

from ci_jobs import assign_jobs, validate_jobs


def group(identifier, **changes):
    return dict(dict(id=identifier, profile='forward', variant='default', image='release',
                     suite='correctness', area='database', cases=[identifier], reports=0), **changes)


class JobPlanTests(unittest.TestCase):
    def setUp(self):
        self.policy = dict(max_groups=3, group_timeout_minutes=45, setup_timeout_minutes=10,
                           standalone_areas=['long'])

    def test_groups_keep_cases_and_each_has_one_job(self):
        groups = [group(str(i)) for i in range(7)]
        original = copy.deepcopy(groups)
        plan = assign_jobs(dict(include=groups), self.policy)
        self.assertEqual(plan['include'], original)
        self.assertEqual([j['group_ids'] for j in plan['jobs']], [['0', '1', '2'], ['3', '4', '5'], ['6']])
        self.assertEqual([j['timeout_minutes'] for j in plan['jobs']], [145, 145, 55])
        self.assertEqual(plan['group_timeout_seconds'], 2700)
        validate_jobs(plan)

    def test_profiles_variants_and_images_never_share_a_job(self):
        groups = [group('first'), group('reverse', profile='reverse'), group('coverage', image='coverage'),
                  group('variant', variant='position'), group('last')]
        jobs = assign_jobs(dict(include=groups), self.policy)['jobs']
        self.assertEqual(len(jobs), 4)
        self.assertEqual(jobs[0]['group_ids'], ['first', 'last'])

    def test_long_areas_and_pr_executions_remain_standalone(self):
        groups = [group('first'), group('long', area='long'), group('last')]
        jobs = assign_jobs(dict(include=groups), self.policy)['jobs']
        self.assertEqual([j['group_ids'] for j in jobs], [['first', 'last'], ['long']])
        jobs = assign_jobs(dict(include=groups, scope='pr-smoke'), self.policy)['jobs']
        self.assertEqual([j['group_ids'] for j in jobs], [['first'], ['long'], ['last']])

    def test_unknown_missing_duplicate_and_incompatible_assignments_fail(self):
        original = assign_jobs(dict(include=[group('first'), group('second')]), self.policy)
        for ids in (['first'], ['first', 'first', 'second'], ['first', 'second', 'unknown'], []):
            plan = copy.deepcopy(original)
            plan['jobs'][0]['group_ids'] = ids
            with self.subTest(ids=ids), self.assertRaises(ValueError):
                validate_jobs(plan)
        for key in ('image', 'profile', 'variant'):
            plan = copy.deepcopy(original)
            plan['jobs'][0][key] = 'different'
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_jobs(plan)

    def test_matrix_limit_applies_to_jobs_not_groups(self):
        plan = assign_jobs(dict(include=[group(str(i)) for i in range(600)]), self.policy)
        self.assertEqual(len(plan['jobs']), 200)
        with self.assertRaisesRegex(ValueError, '256 jobs'):
            assign_jobs(dict(include=[group(str(i), area='long') for i in range(257)]), self.policy)

    def test_invalid_policy_and_duplicate_ids_fail(self):
        for key in ('max_groups', 'group_timeout_minutes', 'setup_timeout_minutes'):
            for value in (0, -1, True, '3'):
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    assign_jobs(dict(include=[group('one')]), dict(self.policy, **{key: value}))
        with self.assertRaisesRegex(ValueError, 'timeout'):
            assign_jobs(dict(include=[group('one')]), dict(self.policy, max_groups=10))
        with self.assertRaisesRegex(ValueError, 'duplicate execution'):
            assign_jobs(dict(include=[group('one'), group('one')]), self.policy)
