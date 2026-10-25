import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ci_test_build as build
from ci_registry import plan


class SharedBuildTests(unittest.TestCase):
    def test_rust_manifest_selects_only_test_executables(self):
        rows = [dict(reason='compiler-artifact', executable='/test', profile=dict(test=True)),
                dict(reason='compiler-artifact', executable='/app', profile=dict(test=False)),
                dict(reason='compiler-artifact', executable=None, profile=dict(test=True)),
                dict(reason='build-finished', success=True)]
        self.assertEqual(build.rust_executables('\n'.join(map(json.dumps, rows))), ['/test'])
        with self.assertRaisesRegex(ValueError, 'no test'):
            build.rust_executables(json.dumps(rows[-1]))

    def test_recording_rust_tests_uses_build_output_without_compilation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            metadata = root / '.build/rust-test-artifacts.jsonl'
            metadata.parent.mkdir()
            metadata.write_text(json.dumps(dict(reason='compiler-artifact', executable='/workspace/rust/target/test',
                                                profile=dict(test=True))))
            with patch.object(build, 'ROOT', root), patch.object(build.subprocess, 'run') as run:
                build.record_rust_tests()
                run.assert_not_called()
            self.assertEqual(json.loads(metadata.with_name('rust-tests.json').read_text()), ['/workspace/rust/target/test'])

    def test_swift_edits_cannot_invalidate_the_rust_stage(self):
        dockerfile = (Path(__file__).resolve().parents[1] / 'docker/coverage/Dockerfile').read_text()
        codec = dockerfile.split('FROM toolchain AS codec', 1)[1].split('FROM dependencies AS sql-syntax', 1)[0]
        self.assertIn('COPY rust rust', codec)
        self.assertIn('source-positive.binlog', codec)
        self.assertNotIn('COPY Sources', codec)
        app = dockerfile.split('FROM sql-syntax AS build', 1)[1].split('FROM toolchain AS periphery-tool', 1)[0]
        self.assertIn('COPY --from=codec /workspace/rust rust', app)
        self.assertNotIn('cargo build', app)
        self.assertNotIn('cargo test', app)

    def test_rust_tests_execute_saved_binary_without_cargo(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            binary = root / 'rust/target/debug/deps/tests'
            binary.parent.mkdir(parents=True)
            binary.touch()
            manifest = root / '.build/rust-tests.json'
            manifest.parent.mkdir()
            manifest.write_text(json.dumps([str(binary)]))
            with patch.object(build, 'ROOT', root), patch.object(build.subprocess, 'run') as run:
                build.rust_test()
                run.assert_called_once_with([str(binary)], cwd=root / 'rust', check=True)
                manifest.write_text('["/elsewhere/test"]')
                with self.assertRaisesRegex(ValueError, 'Invalid prebuilt'):
                    build.rust_test()

    def test_runtime_receipt_must_match_source_and_run(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            receipt = root / 'artifacts/ci/image/build.json'
            receipt.parent.mkdir(parents=True)
            value = dict(image='coverage', commit='abc', run_id='12', attempt='1')
            with patch.object(build, 'ROOT', root), patch.dict(os.environ, GITHUB_SHA='abc', GITHUB_RUN_ID='12'):
                receipt.write_text(json.dumps(value))
                build.check_runtime()
                for key in ('commit', 'image', 'run_id'):
                    receipt.write_text(json.dumps(dict(value, **{key: 'different'})))
                    with self.assertRaisesRegex(ValueError, 'identity'):
                        build.check_runtime()

    def test_fork_archive_is_checked_before_loading_and_checks_source_label(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            with patch.dict(os.environ, GITHUB_SHA='expected'), \
                 patch.object(build.subprocess, 'run') as run, \
                 patch.object(build.subprocess, 'check_output', return_value='wrong\n'):
                with self.assertRaisesRegex(ValueError, 'checkout'):
                    build.load(directory)
                self.assertEqual(run.call_args_list[0].args[0], ['sha256sum', '--check', 'SHA256SUMS'])
                self.assertEqual(run.call_args_list[1].args[0][:2], ['docker', 'load'])

    def test_shared_cache_is_separate_from_production(self):
        env = dict(GITHUB_REPOSITORY='Owner/Project', GITHUB_REF_NAME='beta/7/test',
                   GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='1')
        shared = plan(env, {}, 'test-build')
        self.assertNotEqual(shared['cache_to'], plan(env, {}, 'release')['cache_to'])
        self.assertTrue(shared['runtime'].endswith('-test-build'))

    def test_workflow_consumers_do_not_compile_the_application(self):
        # Do not require a YAML dependency for the lightweight Python tool suite.
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/ci.yml').read_text()
        def job(name, following):
            return workflow.split('\n  ' + name + ':', 1)[1].split('\n  ' + following + ':', 1)[0]
        for name, following in [('unit-tests', 'lab-tools'), ('periphery', 'measurements')]:
            section = job(name, following)
            self.assertIn('needs: [select-suite, test-build]', section)
            self.assertNotIn('swift build', section)
            self.assertNotIn('cargo build', section)
        self.assertIn('unit --prebuilt', job('unit-tests', 'lab-tools'))
        self.assertIn('periphery scan --strict --skip-build', job('periphery', 'measurements'))
        self.assertIn('max-parallel: 16', job('integration', 'packaging-and-smoke'))
        self.assertIn('target: ci-build', job('test-build', 'unit-tests'))
        self.assertIn('target: runtime', job('test-build', 'unit-tests'))
        self.assertNotIn('docker/coverage/Dockerfile', job('build-images', 'integration'))
