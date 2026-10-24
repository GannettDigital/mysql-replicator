import copy
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import ci_lab
import test_components
import test_selection
from ci_matrix import SMOKE_PROFILES
from ci_jobs import assign_jobs
from ci_measurements import summarize
from ci_scope import resolve


def fixture():
    rows, groups = [], []
    for profile in SMOKE_PROFILES + ('same-version',):
        for variant in ('default', 'position'):
            for identifier, family, dependencies in [('baseline', 'base', []), ('index-create', 'indexes', ['setup']),
                                                    ('setup', 'database', []), ('index-resume', 'discovery', []),
                                                    ('offline', 'offline', []), ('other', 'other', [])]:
                rows.append(dict(profile=profile, variant=variant, suite='correctness', id=identifier,
                                 family=family, dependencies=dependencies, status='not_run'))
            def group(area, cases, **extras):
                return dict(id=f'{profile}-{variant}-{area}', profile=profile, variant=variant,
                            suite='correctness', area=area, image='release', reports=0,
                            tier='full', cases=cases, **extras)
            groups += [group('indexes', ['setup', 'index-create', 'index-resume'],
                             requested_cases=['index-create', 'index-resume'], dependency_cases=['setup']),
                       group('other', ['other']), group('offline', ['offline'])]
            # A selected transport group may also contain collateral cases.
            groups.append(group('binlog-index', ['setup', 'index-create', 'other'],
                                dml_transport='binlog', owns_obligations=False))
    rows.append(dict(profile='same-version', variant='default', suite='correctness', id='index-na',
                     family='indexes', status='not_applicable', reason='target engine limit'))
    return dict(scope='full', include=groups, inventory=rows), dict(cases=['baseline'], area='baseline')


class ComponentTests(unittest.TestCase):
    def setUp(self):
        self.full, self.baseline = fixture()
        self.change = test_selection.select_changes(['Sources/ReplicatorLabCore/SharedIndexResume.swift'])

    def selected(self):
        return test_components.select_groups(self.full, self.change, self.baseline)

    def test_all_profiles_variants_dependencies_and_transport_groups_remain(self):
        plan = self.selected()
        selected = plan['include']
        groups = [g for g in selected if g['selected_by'] == ['indexes']]
        self.assertEqual(len(groups), 12)
        self.assertEqual({g['profile'] for g in groups}, set(SMOKE_PROFILES) | {'same-version'})
        self.assertEqual({g['variant'] for g in groups}, {'default', 'position'})
        self.assertEqual(sum(g.get('dml_transport') == 'binlog' for g in groups), 6)
        index = next(g for g in groups if g['area'] == 'indexes')
        self.assertEqual(index['dependency_cases'], ['setup'])
        self.assertTrue(all(g['cases'] == next(old for old in self.full['include'] if old['id'] == g['id'])['cases'] for g in groups))
        self.assertEqual(plan['coverage_reports'], 2)
        self.assertEqual(plan['obligations'], 26)  # four cases * six dimensions + two baseline rows
        self.assertFalse(any(r['id'] == 'offline' for r in plan['inventory']))
        excluded = [r for r in plan['components'][0]['selected'] if r['status'] == 'not_applicable']
        self.assertEqual(excluded[0]['reason'], 'target engine limit')

    def test_union_shared_path_and_unclassified_path(self):
        self.change = test_selection.select_changes([*self.change['selected_by'], 'Sources/ReplicatorCapture/ArchiveReplay.swift'])
        plan = self.selected()
        self.assertEqual({r['component'] for r in plan['components']}, {'indexes', 'offline'})
        self.assertEqual(sum(g['area'] == 'offline' for g in plan['include']), 6)
        for path in ['Sources/ReplicatorApply/SchemaMetadataCache.swift', 'Sources/ReplicatorLabCore/NewHelper.swift', 'unknown']:
            self.change = test_selection.select_changes(['Sources/ReplicatorLabCore/SharedIndexResume.swift', path])
            self.assertEqual(self.change['scope'], 'full')
            with self.assertRaisesRegex(ValueError, 'component-only'):
                self.selected()

    def test_missing_component_case_and_edited_change_plan_fail(self):
        self.full['inventory'] = [r for r in self.full['inventory'] if r.get('family') != 'discovery']
        with self.assertRaisesRegex(ValueError, 'unknown families'):
            self.selected()
        self.change = dict(scope='pr-selected', changes=[dict(path='Sources/ReplicatorApply/ApplyRun.swift', component='indexes')])
        with self.assertRaisesRegex(ValueError, 'component-only'):
            self.selected()

    def test_missing_group_fails_and_original_full_plan_is_unchanged(self):
        original = copy.deepcopy(self.full)
        self.selected()
        self.assertEqual(self.full, original)
        self.full['include'] = [g for g in self.full['include'] if g['area'] != 'indexes']
        with self.assertRaisesRegex(ValueError, 'missing from'):
            self.selected()

    def test_measurement_requires_each_selected_group_and_counts_transport_cases(self):
        plan = assign_jobs(self.selected(), dict(max_groups=3, group_timeout_minutes=45, setup_timeout_minutes=10,
                                                standalone_areas=[]))
        jobs = {g: j['id'] for j in plan['jobs'] for g in j['group_ids']}
        records = [dict(id=g['id'], job_id=jobs[g['id']], seconds=1, status='passed',
                        coverage=dict(collections=g['reports'], mapped=[], hit=[], sources_digest='fixture'),
                        scenarios=[dict(profile=g['profile'], variant=g['variant'], suite=g['suite'], id=c, status='passed')
                                   for c in g['cases']]) for g in plan['include']]
        self.assertTrue(summarize(plan, records)['complete'])
        self.assertFalse(summarize(plan, records[:-1])['complete'])

    def test_full_label_and_main_override_component_scope(self):
        event = dict(pull_request=dict(labels=[]))
        self.assertEqual(resolve('pull_request', event, self.change)['scope'], 'pr-selected')
        for label in ['ci-full', 'ci-expanded-coverage']:
            event['pull_request']['labels'] = [dict(name=label)]
            self.assertEqual(resolve('pull_request', event, self.change)['scope'], 'full')
        self.assertEqual(resolve('push', dict(ref='refs/heads/main'), self.change)['scope'], 'full')

    def test_ci_reads_saved_selection_and_refuses_missing_artifact(self):
        query = Mock()
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / 'selection.json'
            with patch.dict(ci_lab.os.environ, CI_SUITE='pr-selected', CI_TEST_SELECTION=str(artifact)):
                with self.assertRaises(FileNotFoundError):
                    ci_lab.select_plan(query)
                query.assert_not_called()
                artifact.write_text(json.dumps(self.change))
                with patch.object(ci_lab, 'component_plan', return_value={'plan': True}) as build:
                    self.assertEqual(ci_lab.select_plan(query), {'plan': True})
                    build.assert_called_once_with(query, self.change)

    def test_local_commands_use_same_plan_cases_variants_and_transports(self):
        plan = self.selected()
        output = io.StringIO()
        with patch('sys.argv', ['test_selection.py', '--lab', '/tmp/lab']), \
                patch.object(test_selection, 'from_git', return_value=self.change), \
                patch.object(ci_lab, 'component_plan', return_value=plan) as build, \
                contextlib.redirect_stdout(output):
            test_selection.main()
        result = json.loads(output.getvalue())
        self.assertEqual(result['integration_plan'], plan)
        build.assert_called_once()
        commands = result['commands'][4:]
        self.assertEqual(len(commands), len(plan['include']))
        for group, command in zip(plan['include'], commands):
            self.assertIn('--variant ' + group['variant'], command)
            self.assertTrue(all('--case ' + c in command for c in group['cases']))
            self.assertNotIn('--skip-build', command)
            self.assertEqual('--dml-transport binlog' in command, group.get('dml_transport') == 'binlog')

    def test_rules_use_existing_exact_paths_and_reject_wildcards_or_duplicate_paths(self):
        policy = test_components.rules()
        for rule in policy.values():
            for path in rule['paths']:
                self.assertTrue((test_selection.ROOT / path).is_file(), path)
        for path in ['Sources/*', '../outside', policy['indexes']['paths'][0]]:
            altered = copy.deepcopy(policy)
            altered['offline']['paths'].append(path)
            with patch.object(test_components.POLICY.__class__, 'read_text', return_value=json.dumps(altered)):
                with self.assertRaisesRegex(ValueError, 'invalid or repeated'):
                    test_components.rules()


if __name__ == '__main__':
    unittest.main()
