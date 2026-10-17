import json
from contextlib import nullcontext
import unittest
from unittest.mock import Mock, patch

import ci_lab


class CIShardsTests(unittest.TestCase):
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
        for suite in ['native', 'recovery', 'demo']:
            shard = dict(profile='profile', suite=suite, image='release', cases=['internal-case'])
            self.assertEqual(ci_lab.command(shard),
                             ['test', '--profile', 'profile', '--suite', suite, '--skip-build'])

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


if __name__ == '__main__':
    unittest.main()
