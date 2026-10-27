import json
import tempfile
import subprocess
from pathlib import Path
from contextlib import nullcontext
import unittest
from unittest.mock import Mock, patch

import ci_lab


class CIShardsTests(unittest.TestCase):
    def test_invalid_catalog_blocks_matrix_generation(self):
        query = Mock(side_effect=subprocess.CalledProcessError(1, ['lab', 'ddl-catalog', 'check']))
        with patch.object(ci_lab, 'select_plan') as select, self.assertRaises(subprocess.CalledProcessError):
            ci_lab.validated_plan(query, scope='full')
        query.assert_called_once_with('ddl-catalog', 'check')
        select.assert_not_called()

    def test_image_preparation_uses_profile_definition_and_builds_shared_image_once(self):
        from ci_jobs import assign_jobs
        group = dict(id='one', profile='reverse', variant='default', image='coverage', area='dml')
        plan = assign_jobs(dict(include=[group]), dict(max_groups=1, group_timeout_minutes=45,
                          setup_timeout_minutes=10, standalone_areas=[]))
        job = plan['jobs'][0]['id']
        catalog = dict(profiles=[dict(id='reverse', fixture=dict(
            compose_files=['compose.yaml', 'docker/reverse/compose.yaml'],
            environment={'EVIDENCE': 'ci-image-preparation'}, services=['source', 'native', 'target57']))])
        config = dict(services={'source': dict(image='mysql:8.4'),
                               'native': dict(image='fixture:5.7', build={}),
                               'target57': dict(image='fixture:5.7', build={})})
        for failure in (False, True):
            with tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                env_file = root / 'environment'
                with patch.object(ci_lab, 'ROOT', root), patch.object(ci_lab, 'validate_bundle'), \
                        patch.object(ci_lab, 'matrix', return_value=plan), \
                        patch.object(ci_lab, 'lab', return_value=json.dumps(catalog)), \
                        patch.object(ci_lab.subprocess, 'check_output', return_value=json.dumps(config)), \
                        patch.object(ci_lab.subprocess, 'run') as run, \
                        patch.dict(ci_lab.os.environ, GITHUB_ENV=str(env_file)):
                    if failure:
                        run.side_effect = subprocess.CalledProcessError(1, ['docker'])
                        with self.assertRaises(subprocess.CalledProcessError):
                            ci_lab.prepare_job(job)
                        self.assertFalse(env_file.exists())
                    else:
                        ci_lab.prepare_job(job)
                        self.assertEqual(run.call_count, 2)
                        self.assertEqual(run.call_args_list[0].args[0][-4:], ['pull', '--policy', 'missing', 'source'])
                        self.assertEqual(run.call_args_list[1].args[0][-2:], ['build', 'native'])
                        self.assertTrue(all('up' not in c.args[0] for c in run.call_args_list))
                        self.assertEqual(env_file.read_text(), 'REPLICATOR_LAB_IMAGES_PREPARED=true\n')
                saved = json.loads((root / f'artifacts/ci/setup/{job}.json').read_text())
                self.assertEqual(saved['status'], 'failed' if failure else 'passed')
                self.assertEqual(saved['phases']['pull']['status'], saved['status'])

    def test_pr_plan_resolves_explicit_policy_against_full_catalogs(self):
        from ci_matrix import SMOKE_PROFILES
        policy = json.loads((ci_lab.ROOT / 'tools/ci_matrix.json').read_text())
        catalogs = [dict(scenarios=[dict(id=c, profile=p, suite='correctness',
                                       variant='default', status='not_run')
                                   for c in policy['pr_smoke']['cases'] + ['full-only']]) for p in SMOKE_PROFILES]
        query = Mock(side_effect=[json.dumps(c) for c in catalogs])
        with patch.dict(ci_lab.os.environ, CI_SUITE='pr-smoke', CI_EXPANDED_COVERAGE='true'):
            result = ci_lab.select_plan(query)
        self.assertEqual(result['obligations'], 2 * len(policy['pr_smoke']['cases']))
        for call, profile in zip(query.call_args_list, SMOKE_PROFILES):
            self.assertEqual(call.args, ('test', '--profile', profile, '--suite', 'correctness',
                                        '--variant', 'default', '--tier', 'full', '--list'))
        self.assertTrue(all('full-only' not in s['cases'] for s in result['include']))

    def test_production_plan_has_two_short_uninstrumented_checks(self):
        from ci_matrix import SMOKE_PROFILES
        query = Mock(side_effect=[json.dumps(dict(scenarios=[dict(id=c, profile=p, suite='correctness',
                     variant='default', status='not_run') for c in ['positive', 'offline-replay', 'other']]))
                                  for p in SMOKE_PROFILES])
        with patch.dict(ci_lab.os.environ, CI_SUITE='production'):
            result = ci_lab.select_plan(query)
        self.assertEqual((result['scope'], result['images'], len(result['jobs'])), ('production', ['release'], 2))
        for group in result['include']:
            self.assertNotIn('--coverage', ci_lab.command(group))
            self.assertEqual(group['cases'], ['positive', 'offline-replay'])

    def test_recovery_collects_coverage_but_native_observations_do_not(self):
        for suite in ('recovery', 'native'):
            command = ci_lab.command(dict(profile='mysql57-to-mysql84-innodb', suite=suite, image='coverage'))
            self.assertEqual('--coverage' in command, suite == 'recovery')

    def test_unknown_selection_fails_before_catalog_queries(self):
        query = Mock()
        with patch.dict(ci_lab.os.environ, CI_SUITE='typo'), self.assertRaisesRegex(ValueError, 'CI_SUITE'):
            ci_lab.select_plan(query)
        query.assert_not_called()

    def test_bundle_keeps_swift_runtime_but_uses_workers_system_loader_and_libc(self):
        listing = '''libswiftCore.so => /opt/swift/usr/lib/swift/linux/libswiftCore.so (0x1)
libFoundation.so => /opt/swift/usr/lib/swift/linux/libFoundation.so (0x2)
libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x3)
/lib64/ld-linux-x86-64.so.2 (0x4)'''
        self.assertEqual([p.name for p in ci_lab.runtime_libraries(listing)], ['libswiftCore.so', 'libFoundation.so'])
        with self.assertRaisesRegex(ValueError, 'unresolved'):
            ci_lab.runtime_libraries('libswiftCore.so => not found')
        with self.assertRaisesRegex(ValueError, 'no Swift runtime'):
            ci_lab.runtime_libraries('libc.so.6 => /lib/libc.so.6 (0x1)')

    def test_full_shard_passes_profile_variant_and_exact_cases(self):
        shard = dict(profile='mysql84-to-mysql57-myisam', variant='gtid-full',
                     suite='correctness', image='release', tier='full', cases=['one', 'two'])
        self.assertEqual(ci_lab.command(shard), ['test', '--profile', shard['profile'],
                         '--suite', 'correctness', '--skip-build', '--variant', 'gtid-full',
                         '--tier', 'full', '--case', 'one', '--case', 'two'])

    def test_binlog_lifecycle_passes_transport_and_selected_cases(self):
        shard = dict(profile='profile', variant='default', suite='lifecycle',
                     image='release', dml_transport='binlog',
                     cases=['target-uncertain', 'target-uncertain-resume'])
        self.assertEqual(ci_lab.command(shard), [
            'test', '--profile', 'profile', '--suite', 'lifecycle', '--skip-build',
            '--variant', 'default', '--dml-transport', 'binlog',
            '--case', 'target-uncertain', '--case', 'target-uncertain-resume'])

    def test_adapters_use_shared_entrypoint_without_unsupported_selectors(self):
        for suite in ['native', 'recovery']:
            shard = dict(profile='profile', suite=suite, image='release', cases=['internal-case'])
            self.assertEqual(ci_lab.command(shard),
                             ['test', '--profile', 'profile', '--suite', suite, '--skip-build'])

    def test_demo_passes_only_the_selected_fixture_session(self):
        shard = dict(profile='profile', suite='demo', image='coverage',
                     cases=['demo-idle-sigint', 'demo-resume-baseline-gtid'])
        self.assertEqual(ci_lab.command(shard), [
            'test', '--profile', 'profile', '--suite', 'demo', '--skip-build', '--coverage',
            '--case', 'demo-idle-sigint', '--case', 'demo-resume-baseline-gtid'])

    def test_coverage_smoke_remains_instrumented(self):
        args = ci_lab.command(dict(profile='profile', suite='correctness', image='coverage',
                                   variant='default', tier='smoke', cases=[]))
        self.assertIn('--coverage', args)
        self.assertEqual(args[-2:], ['--tier', 'smoke'])

    def test_wrong_source_bundle_fails_before_any_docker_or_suite_commands(self):
        with patch.object(ci_lab, 'lab', return_value='actual'), \
             patch.object(ci_lab.Path, 'read_text', return_value='different'), \
             patch.object(ci_lab, 'matrix', return_value={'include': [dict(id='sample')]}), \
             patch.object(ci_lab.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'inputs differ'):
                ci_lab._run_shard('sample')
            run.assert_not_called()

    def test_wrong_matrix_fails_before_any_docker_or_suite_commands(self):
        with patch.object(ci_lab, 'validate_bundle'), \
             patch.object(ci_lab.Path, 'read_text', return_value='current'), \
             patch.object(ci_lab, 'matrix', return_value={'inputs': 'old'}), \
             patch.object(ci_lab.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'matrix inputs differ'):
                ci_lab._run_shard('sample')
            run.assert_not_called()

    def test_shard_wrapper_records_build_inputs_only_in_actions(self):
        for actions, expected in [('true', True), ('false', False), ('', False)]:
            with self.subTest(actions=actions), \
                 patch.dict(ci_lab.os.environ, GITHUB_ACTIONS=actions), \
                 patch('ci_measurements.record_shard', return_value=nullcontext()) as record, \
                 patch.object(ci_lab, '_run_shard') as run:
                ci_lab.run_shard('sample')
                record.assert_called_once_with(ci_lab.ROOT, 'sample', build_inputs=expected)
                run.assert_called_once_with('sample')


    def test_job_records_failure_then_runs_the_next_isolated_group(self):
        from ci_jobs import assign_jobs
        groups = [dict(id=name, profile='forward', variant='default', image='release', area='database')
                  for name in ('first', 'second')]
        plan = assign_jobs(dict(include=groups), dict(max_groups=3, group_timeout_minutes=45,
                                                    setup_timeout_minutes=10, standalone_areas=[]))
        identifier = plan['jobs'][0]['id']
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = []
            def execute(group):
                calls.append(group)
                result = root / 'artifacts/lab' / group / 'result.json'
                result.parent.mkdir(parents=True)
                result.write_text(json.dumps(dict(scenarios=[dict(id=group, profile='forward', suite='correctness',
                    status='failed' if group == 'first' else 'passed')])))
                if group == 'first':
                    raise subprocess.TimeoutExpired(['lab'], 2700)
            with patch.object(ci_lab, 'ROOT', root), patch.object(ci_lab, 'matrix', return_value=plan), \
                    patch.object(ci_lab, '_run_shard', side_effect=execute), \
                    patch.dict(ci_lab.os.environ, GITHUB_ACTIONS='false'):
                with self.assertRaisesRegex(RuntimeError, 'first'):
                    ci_lab.run_job(identifier)
            self.assertEqual(calls, ['first', 'second'])
            records = [json.loads((root / f'artifacts/ci/measurements/{name}.json').read_text()) for name in calls]
            self.assertEqual([r['status'] for r in records], ['failed', 'passed'])
            self.assertTrue(all(r['job_id'] == identifier for r in records))
            self.assertEqual([[s['id'] for s in r['scenarios']] for r in records], [['first'], ['second']])

    def test_job_cancellation_stops_later_groups(self):
        from ci_jobs import assign_jobs
        groups = [dict(id=name, profile='p', variant='default', image='release', area='database')
                  for name in ('one', 'two')]
        plan = assign_jobs(dict(include=groups), dict(max_groups=3, group_timeout_minutes=45,
                                                    setup_timeout_minutes=10, standalone_areas=[]))
        with patch.object(ci_lab, 'matrix', return_value=plan), \
                patch.object(ci_lab, 'run_shard', side_effect=KeyboardInterrupt) as run:
            with self.assertRaises(KeyboardInterrupt):
                ci_lab.run_job(plan['jobs'][0]['id'])
            self.assertEqual(run.call_count, 1)

    def test_group_coverage_count_excludes_previous_groups(self):
        old = Path('old/combined/coverage.json')
        current = Path('new/combined/coverage.json')
        shard = dict(id='second', profile='p', variant='default', image='coverage', area='database',
                     suite='correctness', tier='full', cases=['case'], reports=1)
        plan = dict(inputs='current', include=[shard], group_timeout_seconds=2700)
        for after, should_pass in [([old, current], True), ([old], False)]:
            with patch.object(ci_lab, 'validate_bundle'), patch.object(ci_lab.Path, 'read_text', return_value='current'), \
                    patch.object(ci_lab, 'matrix', return_value=plan), patch.object(ci_lab.subprocess, 'run') as run, \
                    patch('coverage_report.downloaded_inputs', side_effect=[[old], after]):
                if should_pass:
                    ci_lab._run_shard('second')
                else:
                    with self.assertRaisesRegex(ValueError, 'got 0'):
                        ci_lab._run_shard('second')
                self.assertEqual(run.call_args.kwargs['timeout'], 2700)


if __name__ == '__main__':
    unittest.main()
