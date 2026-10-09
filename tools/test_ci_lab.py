import unittest
from unittest.mock import patch

import ci_lab


class CIShardsTests(unittest.TestCase):
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

    def test_preserves_both_profiles_and_all_existing_suite_obligations(self):
        shards = ci_lab.matrix()['include']
        forward = 'mysql84-to-mysql57-myisam'
        reverse = 'mysql57-to-mysql84-innodb'
        actual = {(s['image'], s['profile'], s['suite']) for s in shards}
        expected = {('release', p, suite) for p in [forward, reverse] for suite in ['correctness', 'lifecycle']}
        expected |= {('coverage', p, suite) for p in [forward, reverse] for suite in ['correctness', 'demo']}
        expected |= {('release', forward, 'sample'), ('coverage', forward, 'sample'), ('release', reverse, 'recovery')}
        self.assertEqual(actual, expected)
        self.assertEqual(len({s['id'] for s in shards}), len(shards))
        self.assertEqual(len(actual), len(shards))
        self.assertEqual(sum(s['reports'] for s in shards), 12)
        for shard in shards:
            args = ci_lab.command(shard)
            self.assertIn('--skip-build', args)
            self.assertEqual('--coverage' in args, shard['image'] == 'coverage')
            if shard['suite'] == 'sample':
                self.assertEqual([args[i+1] for i, x in enumerate(args) if x == '--case'],
                                 ['positive', 'ddl-modify-demo-varchar-120', 'ddl-index-create'])
            elif shard['suite'] == 'correctness':
                self.assertEqual(args[-2:], ['--tier', 'smoke'])
            elif shard['suite'] == 'recovery':
                self.assertEqual(args, ['reverse-suite', '--skip-build', '--events', '0'])

    def test_wrong_source_bundle_fails_before_any_docker_or_suite_commands(self):
        with patch.object(ci_lab, 'lab', return_value='actual'), \
             patch.object(ci_lab.Path, 'read_text', return_value='different'), \
             patch.object(ci_lab, 'matrix', return_value={'include': [dict(id='sample')]}), \
             patch.object(ci_lab.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'inputs differ'):
                ci_lab.run_shard('sample')
            run.assert_not_called()

    def test_specialized_recovery_cannot_silently_change_profile(self):
        with self.assertRaisesRegex(ValueError, 'reverse release'):
            ci_lab.command(dict(suite='recovery', image='coverage', profile='mysql57-to-mysql84-innodb'))


if __name__ == '__main__':
    unittest.main()
