import contextlib
import copy
import io
import json
import shlex
import subprocess
import unittest
from unittest.mock import patch

import ci_lab
import lab_groups


def fixture_plan():
    groups = [dict(id='sql-one', area='keys', profile='one', variant='default',
                   suite='correctness', tier='full', image='coverage', reports=1,
                   cases=['setup', 'rows'], requested_cases=['rows'], dependency_cases=['setup']),
              dict(id='sql-two', area='keys', profile='two', variant='position-minimal',
                   suite='correctness', tier='full', image='coverage', reports=1,
                   cases=['setup', 'rows'], requested_cases=['rows'], dependency_cases=['setup']),
              dict(id='native', area='native', profile='one', variant='default',
                   suite='native', image='coverage', reports=0, cases=['native-observation']),
              dict(id='benchmark', area='binlog-replication-backlog-10k', profile='two', variant='default',
                   suite='performance', image='coverage', reports=1, cases=['backlog-10k'],
                   dml_transport='binlog', max_native_ratio=2, report_only=True)]
    return dict(scope='full', include=groups, inventory=[
        dict(id='unavailable', profile='two', status='not_applicable', reason='target engine')])


class GroupSelectionTests(unittest.TestCase):
    def test_unfiltered_plan_preserves_all_ci_groups(self):
        source = fixture_plan()
        selected = lab_groups.select_groups(source)
        self.assertEqual(selected['groups'], source['include'])
        self.assertEqual(selected['excluded_groups'], [])
        self.assertEqual(selected['catalog_not_applicable'], source['inventory'])

    def test_selection_preserves_cases_dependencies_and_fixture_boundaries(self):
        result = lab_groups.select_groups(fixture_plan(), groups=['keys'], profiles=['one'])
        self.assertEqual([g['id'] for g in result['groups']], ['sql-one'])
        self.assertEqual(result['groups'][0]['cases'], ['setup', 'rows'])
        self.assertEqual(result['groups'][0]['dependency_cases'], ['setup'])
        self.assertEqual(len(result['excluded_groups']), 3)
        self.assertTrue(all(g['reasons'] for g in result['excluded_groups']))

    def test_group_matrix_and_transport_filters(self):
        source = fixture_plan()
        self.assertEqual(len(lab_groups.select_groups(source, groups=['keys'])['groups']), 2)
        self.assertEqual([g['id'] for g in lab_groups.select_groups(
            source, variants=['position-minimal'])['groups']], ['sql-two'])
        self.assertEqual([g['id'] for g in lab_groups.select_groups(
            source, transports=['binlog'])['groups']], ['benchmark'])
        self.assertEqual(len(lab_groups.select_groups(source, transports=['sql'])['groups']), 3)
        self.assertEqual(lab_groups.select_groups(source, groups=['all'], profiles=['all'])['groups'], source['include'])

    def test_unknown_empty_and_partially_unmatched_filters_fail(self):
        invalid = [dict(groups=['typo']), dict(profiles=['typo']), dict(variants=['typo']),
                   dict(transports=['typo']), dict(groups=['keys', 'keys']),
                   dict(groups=['keys'], profiles=['one'], transports=['binlog']),
                   dict(groups=['keys', 'native'], profiles=['two']),
                   dict(groups=['all', 'keys'])]
        for filters in invalid:
            with self.subTest(filters=filters), self.assertRaises(ValueError):
                lab_groups.select_groups(fixture_plan(), **filters)

    def test_local_commands_match_ci_except_explicit_build_choice(self):
        for group in fixture_plan()['include']:
            expected = ci_lab.command(group)
            expected.remove('--skip-build')
            self.assertEqual(lab_groups.local_command(group, ['lab']), ['lab', *expected])
            self.assertEqual(lab_groups.local_command(group, ['lab'], skip_build=True), ['lab', *ci_lab.command(group)])
            normal = lab_groups.local_command(group, ['lab'], coverage=False)
            self.assertEqual(normal, [v for v in ['lab', *expected] if v != '--coverage'])

    def test_benchmark_overrides_are_explicit_and_do_not_change_ci_policy(self):
        source = fixture_plan()
        original = copy.deepcopy(source)
        result = lab_groups.add_commands(lab_groups.select_groups(source, transports=['binlog']), ['lab'],
                                         max_native_ratio=3, report_only=False)
        command = result['groups'][0]['command']
        self.assertEqual(command[command.index('--max-native-ratio')+1], '3')
        self.assertNotIn('--report-only', command)
        self.assertIn('--dml-transport', command)
        self.assertEqual(source, original)
        result = lab_groups.add_commands(lab_groups.select_groups(source), ['lab'])
        self.assertIn('--report-only', result['groups'][-1]['command'])

    def test_invalid_benchmark_options_fail(self):
        for ratio in [0, -1, float('nan'), float('inf')]:
            with self.subTest(ratio=ratio), self.assertRaises(ValueError):
                lab_groups.add_commands(lab_groups.select_groups(fixture_plan()), ['lab'], max_native_ratio=ratio)
        with self.assertRaisesRegex(ValueError, 'performance'):
            lab_groups.add_commands(lab_groups.select_groups(fixture_plan(), groups=['keys']), ['lab'], report_only=True)

    def test_cli_json_plan_does_not_start_tests_and_ignores_ci_scope_environment(self):
        output = io.StringIO()
        with patch('sys.argv', ['lab_groups.py', '--group', 'keys', '--lab', '/tmp/lab']), \
                patch.dict('os.environ', CI_SUITE='production'), \
                patch.object(lab_groups, 'validated_plan', return_value=fixture_plan()) as build, \
                patch.object(lab_groups, 'run_commands') as run, contextlib.redirect_stdout(output):
            lab_groups.main()
        self.assertEqual(build.call_args.kwargs['scope'], 'full')
        self.assertEqual(len(json.loads(output.getvalue())['groups']), 2)
        run.assert_not_called()

    def test_cli_invalid_combination_does_not_start_tests(self):
        with patch('sys.argv', ['lab_groups.py', '--group', 'keys', '--dml-transport', 'binlog', '--run']), \
                patch.object(lab_groups, 'validated_plan', return_value=fixture_plan()), \
                patch.object(lab_groups, 'run_commands') as run, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                lab_groups.main()
        run.assert_not_called()

    def test_make_group_entry_points_route_to_shared_selector(self):
        for target in ('lab-list', 'lab-plan', 'lab-test'):
            output = subprocess.check_output(['make', '-n', target, 'GROUP=keys-rows-gtids',
                'PROFILE=mysql57-to-mysql84-innodb', 'ARGS=--variant default --no-coverage'],
                cwd=lab_groups.ROOT, text=True)
            args = shlex.split(output)
            self.assertEqual(args[:2], ['python3', 'tools/lab_groups.py'])
            self.assertEqual('--run' in args, target == 'lab-test')
            self.assertEqual(args[args.index('--profile')+1], 'mysql57-to-mysql84-innodb')
            self.assertEqual(args[args.index('--group')+1], 'keys-rows-gtids')
            self.assertIn('--no-coverage', args)

    def test_make_case_selection_remains_available(self):
        output = subprocess.check_output(['make', '-n', 'lab-test',
            'PROFILE=mysql57-to-mysql84-innodb', 'ARGS=--case positive'], cwd=lab_groups.ROOT, text=True)
        self.assertEqual(shlex.split(output), ['swift', 'run', 'replicator-lab', 'test',
            '--profile', 'mysql57-to-mysql84-innodb', '--case', 'positive'])

    def test_runner_stops_on_failure_and_keeps_child_output_off_stdout(self):
        for code, expected in [(4, 4), (-15, 143)]:
            out, err = io.StringIO(), io.StringIO()
            with patch.object(lab_groups.subprocess, 'run', return_value=subprocess.CompletedProcess([], code)) as run, \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                with self.assertRaises(SystemExit) as failure:
                    lab_groups.run_commands([['first'], ['second']])
            self.assertEqual(failure.exception.code, expected)
            run.assert_called_once()
            self.assertIs(run.call_args.kwargs['stdout'], err)
            self.assertEqual(out.getvalue(), '')


if __name__ == '__main__':
    unittest.main()
