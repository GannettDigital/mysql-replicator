import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from build_dependencies import placeholders
from ci_registry import cache_ref, load_receipt, namespace, plan, receipt, study_plan
from code_coverage import llvm_tool


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.env = dict(GITHUB_REPOSITORY='Owner/Project', GITHUB_REF_NAME='main',
                        GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='1')
        self.pr = dict(pull_request=dict(head=dict(ref='beta/4/09', repo=dict(full_name='Owner/Project')),
                                         base=dict(ref='beta/4/08')))

    def test_stack_reads_own_base_and_main_but_writes_only_own_cache(self):
        value = plan(self.env, self.pr, 'coverage')
        self.assertEqual(value['publish'], 'true')
        for branch in ('beta/4/09', 'beta/4/08', 'main'):
            self.assertIn(cache_ref('Owner/Project', 'coverage', branch), value['cache_from'])
        self.assertEqual(value['cache_to'], 'type=registry,ref=' + cache_ref('Owner/Project', 'coverage', 'beta/4/09') + ',mode=max')
        self.assertEqual(namespace('Owner/Project'), 'ghcr.io/owner/project-ci')
        self.assertNotEqual(value['cache_to'], plan(self.env, {}, 'coverage')['cache_to'])
        self.assertNotEqual(value['cache_to'], plan(self.env, self.pr, 'release')['cache_to'])

    def test_forks_never_publish_registry_images_or_caches(self):
        fork = copy.deepcopy(self.pr)
        fork['pull_request']['head']['repo']['full_name'] = 'Other/Project'
        fork['pull_request']['head']['ref'] = 'main'
        value = plan(self.env, fork, 'coverage')
        self.assertEqual(value['publish'], 'false')
        self.assertTrue(value['cache_to'].startswith('type=gha,'))

    def test_missing_source_repository_never_enables_registry_writes(self):
        for source in (None, {}):
            with self.subTest(source=source):
                fork = copy.deepcopy(self.pr)
                fork['pull_request']['head']['repo'] = source
                value = plan(self.env, fork, 'coverage')
                self.assertEqual(value['publish'], 'false')
                self.assertEqual(value['cache_to'], 'type=gha,scope=layers-v2-coverage,mode=max')
                self.assertNotIn(cache_ref('Owner/Project', 'coverage', 'beta/4/09'), value['cache_from'])
                self.assertIn(cache_ref('Owner/Project', 'coverage', 'beta/4/08'), value['cache_from'])

    def test_receipt_loads_by_digest_and_rejects_other_repository_commit_or_image(self):
        digest = 'sha256:' + 'a' * 64
        value = receipt('Owner/Project', 'coverage', 'ghcr.io/owner/project-ci:run-123-1-coverage', digest, 'commit')
        with patch('ci_registry.subprocess.run') as run:
            load_receipt(value, 'Owner/Project', 'coverage', 'commit')
            self.assertEqual(run.call_args_list[0].args[0], ['docker', 'pull', '--platform', 'linux/amd64', 'ghcr.io/owner/project-ci@' + digest])
            run.reset_mock()
            for altered in (dict(value, reference='ghcr.io/other/image@' + digest),
                            dict(value, reference='ghcr.io/owner/project-ci:latest'),
                            dict(value, commit='old'), dict(value, image='release')):
                with self.assertRaises(ValueError):
                    load_receipt(altered, 'Owner/Project', 'coverage', 'commit')
            run.assert_not_called()

    def test_study_cache_is_isolated_and_missing_manifest_does_not_claim_hit(self):
        with patch('ci_registry.subprocess.run') as run:
            cold = study_plan(self.env, 'coverage', 'cold')
            run.assert_not_called()
            self.assertEqual(cold['cache_from'], '')
            self.assertEqual(cold['cache_hit'], 'false')
            run.return_value.returncode = 1
            warm = study_plan(self.env, 'coverage', 'warm')
            self.assertEqual(warm['cache_to'], cold['cache_to'])
            self.assertEqual(warm['cache_hit'], 'false')
            run.return_value.returncode = 0
            self.assertEqual(study_plan(self.env, 'coverage', 'warm')['cache_hit'], 'true')
            retry = study_plan(dict(self.env, GITHUB_RUN_ATTEMPT='2'), 'coverage', 'cold')
            self.assertNotEqual(cold['cache_to'], retry['cache_to'])

    def test_dependency_placeholders_never_replace_real_sources(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            package = dict(targets=[dict(name='App', type='executable'),
                                    dict(name='System', type='system')])
            paths = placeholders(root, package)
            self.assertEqual(len(paths), 2)
            self.assertTrue((root / 'Sources/System/module.modulemap').is_file())
            with self.assertRaisesRegex(ValueError, 'empty source path'):
                placeholders(root, package)

    def test_runtime_uses_explicit_matching_llvm_tools_without_swift_compiler(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict('os.environ', REPLICATOR_LLVM_BIN=folder):
            path = Path(folder) / 'llvm-profdata'
            path.touch()
            self.assertEqual(llvm_tool('llvm-profdata'), str(path))
            with self.assertRaisesRegex(ValueError, 'matching LLVM'):
                llvm_tool('llvm-cov')


if __name__ == '__main__':
    unittest.main()
