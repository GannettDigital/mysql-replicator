import io
import contextlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_selection import ROOT, changed_files, checks_for, from_git, local_commands, select_changes, main


class SelectionTests(unittest.TestCase):
    def test_reviewed_examples(self):
        examples = {
            'docs': [['README.md'], ['docs/OFFLINE_REPLAY.md', 'PLAN/beta.5.md'], ['AGENTS.md']],
            'tools': [['tools/ci_measurements.py', 'tools/test_ci_measurements.py'],
                      ['README.md', 'tools/coverage_report.py'], ['tools/coverage_comment.py'],
                      ['tools/ci_scope.py', 'tools/test_ci_scope.py'],
                      ['tools/test_selection.py', 'tools/test_test_selection.py']],
            'pr-smoke': [['Makefile'], ['.github/workflows/ci.yml']],
            'pr-selected': [['Sources/ReplicatorApply/SourceReconnect.swift'],
                            ['tests/ReplicatorCaptureTests/ArchiveTests.swift'],
                            ['Sources/ReplicatorLabCore/SharedIndexResume.swift'],
                            ['README.md', 'tools/coverage_report.py', 'Sources/ReplicatorCapture/ArchiveReplay.swift']],
            'full': [['Sources/ReplicatorCLI/main.swift'], ['Sources/ReplicatorCodec/StageTimings.swift'],
                     ['Sources/ReplicatorApply/ApplyRun.swift'], ['Sources/MySQLSyntax/SQLLexer.swift'],
                     ['tests/MySQLSyntaxTests/SQLLexerTests.swift'], ['rust/src/lib.rs'],
                     ['examples/apply.example.yaml'], ['Sources/ReplicatorApply/SchemaMetadataCache.swift'],
                     ['Sources/ReplicatorLabCore/SharedCorrectness.swift'], ['Sources/ReplicatorLabCore/ModifyIndexCases.swift'], ['Package.swift'], ['Package.resolved'], ['.github/workflows/release.yml'],
                     ['tools/ci_matrix.json'],
                     ['tools/ci_lab.py'], ['tools/code_coverage.py'], ['tools/swift_cache.py'],
                     ['tools/coverage_runtime.py'], ['tools/release_evidence.py'], ['tools/release_cut.py'],
                     ['packaging/install.sh'], ['docker/coverage/Dockerfile'], ['Vendor/mysql/a.swift'],
                     ['Sources/ReplicatorLab/main.swift'], ['tests/ReplicatorLabTests/Fixtures/raw.binlog'],
                     ['tests/ReplicatorCaptureTests/Fixtures/new.binlog'], ['tools/new_tool.py'],
                     ['docs/config.yaml'], ['unknown.file'], [], ['../README.md'], ['/README.md']],
        }
        for scope, changes in examples.items():
            for paths in changes:
                with self.subTest(paths=paths):
                    result = select_changes(paths)
                    self.assertEqual(result['scope'], scope)
                    self.assertEqual(result['checks'], checks_for(scope))

    def test_selection_changes_do_not_request_all_correctness_variants(self):
        paths = ['.github/workflows/ci.yml', 'Makefile', 'docs/PR_TEST_SELECTION.md',
                 'tools/ci_scope.py', 'tools/test_ci_scope.py', 'tools/test_selection.py',
                 'tools/test_test_selection.py', 'tools/coverage_comment.py', 'tools/test_coverage_comment.py']
        result = select_changes(paths)
        self.assertEqual(result['scope'], 'pr-smoke')
        self.assertEqual(result['selected_by'], ['.github/workflows/ci.yml', 'Makefile'])
        self.assertIn('Makefile', result['reason'])
        self.assertFalse(any('--variant' in c for c in local_commands(result['scope'])))
        tools = select_changes([p for p in paths if p not in result['selected_by']])
        self.assertEqual(tools['scope'], 'tools')
        self.assertFalse(tools['checks']['integration'])

    def test_new_module_in_reporting_directory_does_not_inherit_exemption(self):
        self.assertEqual(select_changes(['tools/coverage_report/new_runner.py'])['scope'], 'full')

    def test_incomplete_diff_overrides_apparently_safe_paths(self):
        self.assertEqual(select_changes(['README.md'], fallback='diff failed')['scope'], 'full')
        with patch('test_selection.changed_files', side_effect=subprocess.CalledProcessError(128, 'git')):
            self.assertEqual(from_git('missing')['scope'], 'full')

    def test_failed_diff_includes_git_diagnostic(self):
        error = subprocess.CalledProcessError(128, 'git', stderr=b'fatal: bad revision missing\n')
        with patch('test_selection.changed_files', side_effect=error):
            result = from_git('missing')
        self.assertEqual(result['scope'], 'full')
        self.assertIn('fatal: bad revision missing', result['reason'])

    def test_run_stops_with_child_status(self):
        for status, expected in [(3, 3), (-15, 143)]:
            with patch('sys.argv', ['test_selection.py', '--run']), \
                 patch('test_selection.from_git', return_value=select_changes(['README.md'])), \
                 patch('test_selection.local_commands', return_value=[['first'], ['second']]), \
                 patch('test_selection.subprocess.run', return_value=subprocess.CompletedProcess(['first'], status)) as run, \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as failure:
                    main()
                self.assertEqual(failure.exception.code, expected)
                run.assert_called_once()

    def test_local_commands_keep_one_case_inventory(self):
        policy = json.loads((ROOT / 'tools/ci_matrix.json').read_text())['pr_smoke']
        commands = local_commands('pr-smoke')
        lab = [c for c in commands if '--profile' in c]
        self.assertEqual(len(lab), 2)
        for command in lab:
            cases = [command[i+1] for i, arg in enumerate(command) if arg == '--case']
            self.assertEqual(cases, policy['cases'])
        self.assertEqual(local_commands('docs'), local_commands('tools'))
        self.assertEqual(len(local_commands('tools')), 1)
        full = [c for c in local_commands('full') if '--suite' in c]
        self.assertEqual(len(full), 5)
        for command in full:
            suite = command[command.index('--suite')+1]
            self.assertEqual('--variant' in command, suite in ('correctness', 'lifecycle'))
        with self.assertRaises(ValueError):
            checks_for('typo')


class GitChangeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        self.write('Sources/ReplicatorCLI/main.swift', 'runtime')
        self.write('README.md', 'documentation')
        self.git('add', '.')
        self.commit()
        self.base = self.git('rev-parse', 'HEAD').strip()

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', *args], cwd=self.root, text=True, stderr=subprocess.PIPE)

    def write(self, path, contents):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)

    def commit(self):
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture')

    def test_rename_keeps_old_runtime_path_and_new_doc_path(self):
        self.git('mv', 'Sources/ReplicatorCLI/main.swift', 'renamed.md')
        self.commit()
        paths = changed_files(self.base, root=self.root)
        self.assertEqual(paths, ['Sources/ReplicatorCLI/main.swift', 'renamed.md'])
        self.assertNotEqual(select_changes(paths)['scope'], 'docs')

    def test_local_selection_includes_all_worktree_states_and_unusual_names(self):
        self.write('README.md', 'staged')
        self.git('add', 'README.md')
        self.write('Sources/ReplicatorCLI/main.swift', 'unstaged')
        self.write('docs/a\nname.md', 'untracked')
        self.assertEqual(changed_files(self.base, root=self.root), [])
        paths = changed_files(self.base, include_worktree=True, root=self.root)
        self.assertEqual(paths, ['README.md', 'Sources/ReplicatorCLI/main.swift', 'docs/a\nname.md'])
        self.assertEqual(select_changes(paths)['scope'], 'full')

    def test_deletion_cannot_disappear_from_selection(self):
        self.git('rm', 'Sources/ReplicatorCLI/main.swift')
        self.commit()
        self.assertEqual(from_git(self.base, root=self.root)['scope'], 'full')

    def test_stacked_branch_uses_merge_base_not_unrelated_base_changes(self):
        self.git('checkout', '-qb', 'base')
        self.write('unknown-build-input', 'base change')
        self.git('add', '.')
        self.commit()
        self.git('checkout', '-qb', 'feature', self.base)
        self.write('README.md', 'PR change')
        self.git('add', '.')
        self.commit()
        self.assertEqual(changed_files('base', root=self.root), ['README.md'])

    def test_more_than_api_page_or_file_limit_is_not_truncated(self):
        for i in range(305):
            self.write(f'docs/{i}.md', 'doc')
        self.write('Sources/ReplicatorCLI/main.swift', 'runtime change')
        self.git('add', '.')
        self.commit()
        paths = changed_files(self.base, root=self.root)
        self.assertEqual(len(paths), 306)
        self.assertEqual(select_changes(paths)['scope'], 'full')

    def test_ci_entrypoint_emits_selection_outputs_and_full_label_override(self):
        self.write('README.md', 'PR documentation')
        self.git('add', 'README.md')
        self.commit()
        head = self.git('rev-parse', 'HEAD').strip()
        for name in ('ci_scope.py', 'test_selection.py', 'test_components.py', 'test_components.json'):
            self.write('tools/' + name, (ROOT / 'tools' / name).read_text())
        event = dict(action='synchronize', pull_request=dict(
            base=dict(sha=self.base), head=dict(sha=head), labels=[]))
        for labels, scope in (([], 'docs'), ([dict(name='ci-full')], 'full')):
            event['pull_request']['labels'] = labels
            self.write('event.json', json.dumps(event))
            output = self.root / 'output'
            output.write_text('')
            env = dict(os.environ, GITHUB_EVENT_NAME='pull_request',
                       GITHUB_EVENT_PATH=str(self.root / 'event.json'),
                       GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(self.root / 'summary'))
            subprocess.run([sys.executable, 'tools/ci_scope.py'], cwd=self.root, env=env,
                           check=True, capture_output=True)
            fields = dict(line.split('=', 1) for line in output.read_text().splitlines())
            selected = json.loads((self.root / 'artifacts/ci/test-selection.json').read_text())
            self.assertEqual(fields['scope'], scope)
            self.assertEqual(selected['scope'], scope)
            self.assertEqual(fields['integration'], str(scope == 'full').lower())
            self.assertEqual(fields['unit'], fields['integration'])
            self.assertEqual(fields['periphery'], fields['integration'])
            self.assertEqual([c['path'] for c in selected['changes']], ['README.md'])

    def test_unavailable_base_falls_back_to_full(self):
        result = from_git('not-fetched', root=self.root)
        self.assertEqual(result['scope'], 'full')
        self.assertIn('cannot read complete git diff', result['reason'])


if __name__ == '__main__':
    unittest.main()
