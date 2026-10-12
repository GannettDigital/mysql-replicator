import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import release_cut as cut
from release_version import SWIFT, swift_source


class ReleaseCutTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.version = '0.1.0-beta.4'
        self.repo = 'owner/repo'
        self.commit = 'a' * 40
        self.ci = dict(repository={'full_name': self.repo}, head_sha=self.commit,
                       head_branch='main', event='push', path='.github/workflows/ci.yml',
                       status='completed', conclusion='success', id=123, run_attempt=2,
                       html_url='https://github.com/owner/repo/actions/runs/123')
        (self.root / 'VERSION').write_text(self.version)
        (self.root / SWIFT).parent.mkdir(parents=True)
        (self.root / SWIFT).write_text(swift_source(self.version))
        notes = self.root / 'docs/releases'
        notes.mkdir(parents=True)
        (notes / f'{self.version}.md').write_text('Reviewed release notes.\n')
        (notes / f'{self.version}.plan.json').write_text(json.dumps(
            dict(repository=self.repo, pull_requests=[1, 2])))

    def test_run_must_be_successful_main_push_for_exact_commit(self):
        cut.verify_run(self.ci, self.repo, self.commit)
        for changes in (dict(head_sha='b' * 40), dict(event='pull_request'),
                        dict(head_branch='branch'), dict(status='in_progress'),
                        dict(conclusion='failure'), dict(path='.github/workflows/other.yml'),
                        dict(repository={'full_name': 'other/repo'})):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                cut.verify_run(dict(self.ci, **changes), self.repo, self.commit)

    def manifest(self, name='asset.tar.gz'):
        (self.root / 'asset.tar.gz').write_bytes(b'tested bytes')
        line = hashlib.sha256(b'tested bytes').hexdigest() + '  ' + name + '\n'
        (self.root / 'SHA256SUMS').write_text(line)
        return line

    def test_corrupt_or_missing_assets_stop_release(self):
        self.manifest()
        self.assertEqual(cut.verify_files(self.root), {'asset.tar.gz'})
        (self.root / 'asset.tar.gz').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum differs'):
            cut.verify_files(self.root)
        (self.root / 'asset.tar.gz').unlink()
        with self.assertRaisesRegex(ValueError, 'missing asset'):
            cut.verify_files(self.root)

    def test_manifest_rejects_paths_duplicates_and_empty_content(self):
        for name in ('../asset.tar.gz', '/asset.tar.gz', 'nested/asset.tar.gz', '..'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.manifest(name)
                cut.verify_files(self.root)
        line = self.manifest()
        for value in (line * 2, '', 'invalid\n'):
            (self.root / 'SHA256SUMS').write_text(value)
            with self.assertRaises(ValueError):
                cut.verify_files(self.root)

    def test_asset_symlink_is_rejected(self):
        self.manifest()
        path = self.root / 'asset.tar.gz'
        path.rename(self.root / 'other')
        path.symlink_to(self.root / 'other')
        with self.assertRaises(ValueError):
            cut.verify_files(self.root)

    def fake_api(self, repo, path):
        if path.startswith('pulls/'):
            return {'merged': True}
        if path == 'commits/main':
            return {'sha': self.commit}
        if path.startswith('actions/workflows/'):
            return {'workflow_runs': [self.ci]}
        if path.startswith('actions/runs/'):
            return self.ci
        raise AssertionError(path)

    def fake_run(self, *args):
        if args == ('git', 'status', '--porcelain'):
            return ''
        if args == ('git', 'rev-parse', 'HEAD'):
            return self.commit
        raise AssertionError(args)

    def test_prepare_accepts_complete_stack_on_tested_main(self):
        with patch.object(cut, 'ROOT', self.root), patch.object(cut, 'api', self.fake_api), \
                patch.object(cut, 'run', self.fake_run):
            self.assertEqual(cut.prepare('check')['commit'], self.commit)

    def test_unmerged_stack_and_stale_main_stop_before_download_or_mutation(self):
        for path, value, reason in (('pulls/2', {'merged': False}, 'not merged'),
                                    ('commits/main', {'sha': 'b' * 40}, 'upstream main')):
            def api(repo, requested):
                return value if requested == path else self.fake_api(repo, requested)
            with self.subTest(path=path), patch.object(cut, 'ROOT', self.root), \
                    patch.object(cut, 'api', api), patch.object(cut, 'run', self.fake_run), \
                    self.assertRaisesRegex(ValueError, reason):
                cut.execute('tag')

    def test_existing_tag_is_not_changed(self):
        context = dict(repo=self.repo, tag='v' + self.version, commit=self.commit,
                       version=self.version, ci=self.ci)
        with patch.object(cut, 'prepare', return_value=context), \
                patch.object(cut, 'run', return_value='existing remote tag') as command, \
                self.assertRaisesRegex(ValueError, 'remote tag already exists'):
            cut.execute('tag')
        self.assertEqual(command.call_args.args[:2], ('git', 'ls-remote'))
        self.assertEqual(command.call_count, 1)

    def test_check_does_not_mutate_and_tag_pushes_only_annotated_tag(self):
        context = dict(repo=self.repo, tag='v' + self.version, commit=self.commit,
                       version=self.version, ci=self.ci)
        def command(*args):
            if args[:3] == ('gh', 'run', 'download'):
                destination = Path(args[args.index('--dir') + 1])
                (destination / 'release-verified').touch()
            return ''
        for action in ('check', 'tag'):
            with self.subTest(action=action), patch.object(cut, 'prepare', return_value=context), \
                    patch.object(cut, 'run', side_effect=command) as run, \
                    patch.object(cut, 'api', self.fake_api), patch.object(cut, 'verify_packages'):
                cut.execute(action)
                mutations = [c.args for c in run.call_args_list
                             if c.args[:2] in (('git', 'tag'), ('git', 'push')) and '--list' not in c.args]
                if action == 'check':
                    self.assertEqual(mutations, [])
                else:
                    self.assertEqual(mutations, [
                        ('git', 'tag', '-a', context['tag'], self.commit, '-m', f'Beta release {self.version}'),
                        ('git', 'push', 'https://github.com/owner/repo.git',
                         f'refs/tags/{context["tag"]}:refs/tags/{context["tag"]}')])

    def test_publish_rejects_public_release_or_wrong_tag(self):
        context = dict(repo=self.repo, tag='v' + self.version, commit=self.commit,
                       version=self.version, ci=self.ci)
        for draft in (False, True):
            with self.subTest(draft=draft), patch.object(cut, 'prepare', return_value=context), \
                    patch.object(cut, 'api', return_value={'draft': draft, 'prerelease': True}), \
                    patch.object(cut, 'run', return_value='wrong tag') as command, \
                    self.assertRaises(ValueError):
                cut.execute('publish')
            self.assertFalse(any(c.args[:3] == ('gh', 'release', 'edit') for c in command.call_args_list))

    def test_publish_validated_draft_without_latest_stable(self):
        tag = 'v' + self.version
        context = dict(repo=self.repo, tag=tag, commit=self.commit,
                       version=self.version, ci=self.ci)
        def api(repo, path):
            if path.startswith('releases/'):
                return {'draft': True, 'prerelease': True}
            return self.fake_api(repo, path)
        def command(*args):
            if args[:2] == ('git', 'ls-remote'):
                return f'{self.commit}\trefs/tags/{tag}^{{}}'
            return ''
        with patch.object(cut, 'prepare', return_value=context), \
                patch.object(cut, 'run', side_effect=command) as run, \
                patch.object(cut, 'api', api), patch.object(cut, 'verify_packages') as verify:
            cut.execute('publish')
        verify.assert_called_once()
        run.assert_called_with('gh', 'release', 'edit', tag, '--repo', self.repo,
                               '--draft=false', '--prerelease', '--latest=false')

    def test_ci_rerun_during_download_stops_tagging(self):
        context = dict(repo=self.repo, tag='v' + self.version, commit=self.commit,
                       version=self.version, ci=self.ci)
        def command(*args):
            if args[:3] == ('gh', 'run', 'download'):
                (Path(args[-1]) / 'release-verified').touch()
            return ''
        with patch.object(cut, 'prepare', return_value=context), \
                patch.object(cut, 'run', side_effect=command) as run, \
                patch.object(cut, 'api', return_value=dict(self.ci, run_attempt=3)), \
                patch.object(cut, 'verify_packages'), \
                self.assertRaisesRegex(ValueError, 'CI attempt changed'):
            cut.execute('tag')
        self.assertFalse(any(c.args[:3] == ('git', 'tag', '-a') for c in run.call_args_list))

    def test_failed_package_verification_never_tags(self):
        context = dict(repo=self.repo, tag='v' + self.version, commit=self.commit,
                       version=self.version, ci=self.ci)
        def command(*args):
            if args[:3] == ('gh', 'run', 'download'):
                (Path(args[-1]) / 'release-verified').touch()
            return ''
        with patch.object(cut, 'prepare', return_value=context), \
                patch.object(cut, 'run', side_effect=command) as run, \
                patch.object(cut, 'verify_packages', side_effect=ValueError('bad evidence')), \
                self.assertRaisesRegex(ValueError, 'bad evidence'):
            cut.execute('tag')
        self.assertFalse(any(c.args[:3] == ('git', 'tag', '-a') for c in run.call_args_list))


if __name__ == '__main__':
    unittest.main()
