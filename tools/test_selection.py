#!/usr/bin/env python3
"""Select existing tests from changed paths. Use the same rules locally and in CI."""
import argparse
import json
from pathlib import Path, PurePosixPath
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SCOPES = ('docs', 'tools', 'pr-smoke', 'pr-selected', 'full')
# These tools consume saved results. They do not build or run the replicator.
REPORT_TOOLS = {
    'ci_measurements', 'ci_test_value', 'compare_test_coverage',
    'coverage_comment', 'coverage_report', 'coverage_scope',
}

SELECTOR_PATHS = {
    'tools/ci_scope.py', 'tools/test_ci_scope.py',
    'tools/test_selection.py', 'tools/test_test_selection.py',
    'tools/test_components.py', 'tools/test_test_components.py', 'tools/test_components.json',
}


def checks_for(scope):
    if scope not in SCOPES:
        raise ValueError('unknown test scope: ' + scope)
    runtime = scope in ('pr-smoke', 'pr-selected', 'full')
    return dict(tooling=True, unit=runtime, periphery=runtime, integration=runtime)


def classify(path):
    parts = PurePosixPath(path).parts
    if not path or path.startswith('/') or '..' in parts or '\\' in path:
        return 'full', 'unknown or invalid path'
    if path in SELECTOR_PATHS:
        return 'tools', 'test selection policy; verify with Python tests'
    if path in ('Makefile', '.github/workflows/ci.yml'):
        return 'pr-smoke', 'build/test entry point; verify the two-profile PR path'
    from test_components import component_for
    component = component_for(path)
    if component:
        return 'pr-selected', component[1]
    # Fixture and harness changes can affect cases outside the PR selection.
    if (path.startswith(('Sources/ReplicatorLab', 'tests/ReplicatorLabTests/',
                         '.github/', 'docker/', 'packaging/', 'Vendor/'))
            or '/Fixtures/' in path):
        return 'full', 'harness, fixture, build, or CI contract'
    if path.startswith(('Sources/', 'rust/', 'tests/', 'examples/')):
        return 'full', 'shared runtime, configuration, or unmapped tests; use all profiles and variants'
    if path.startswith('tools/') and len(parts) == 2 and path.endswith('.py'):
        name = PurePosixPath(path).stem.removeprefix('test_')
        if name in REPORT_TOOLS:
            return 'tools', 'saved-result reporting tool'
        return 'full', 'build, test, or release tooling; or unclassified tool'
    if (path in ('README.md', 'CONTRIBUTING.md', 'AGENTS.md', 'LICENSE', 'SECURITY.md', 'CODE_OF_CONDUCT.md')
            or (path.startswith(('docs/', 'PLAN/')) and path.endswith(('.md', '.png', '.svg')))):
        return 'docs', 'documentation'
    return 'full', 'unclassified path'


def select_changes(paths, fallback=None):
    changes = []
    for path in sorted(set(paths)):
        scope, reason = classify(path)
        change = dict(path=path, scope=scope, reason=reason)
        if scope == 'pr-selected':
            from test_components import component_for
            change['component'] = component_for(path)[0]
        changes.append(change)
    scope = max((c['scope'] for c in changes), key=SCOPES.index) if changes else 'full'
    if fallback:
        scope = 'full'
    selected_by = [c['path'] for c in changes if c['scope'] == scope] if not fallback else []
    return dict(version=1, scope=scope, checks=checks_for(scope), selected_by=selected_by, changes=changes,
                reason=fallback or (f'{scope} required by: ' + ', '.join(selected_by)
                                    if changes else 'no changed files; use full checks'))


def changed_files(base, head='HEAD', include_worktree=False, root=ROOT):
    """Use both rename paths and all pages of history, not an API file-count limit."""
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.PIPE).decode('utf-8').split('\0')
    # Resolve refs first so a user-supplied ref cannot become a git option.
    base_sha = git('rev-parse', '--verify', '--end-of-options', base + '^{commit}')[0].strip()
    head_sha = git('rev-parse', '--verify', '--end-of-options', head + '^{commit}')[0].strip()
    paths = git('diff', '--name-only', '--no-renames', '-z', base_sha + '...' + head_sha, '--')
    if include_worktree:
        paths += git('diff', '--name-only', '--no-renames', '-z', head_sha, '--')
        paths += git('ls-files', '--others', '--exclude-standard', '-z')
    return sorted(set(p for p in paths if p))


def from_git(base, head='HEAD', include_worktree=False, root=ROOT):
    try:
        return select_changes(changed_files(base, head, include_worktree, root))
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or b'').decode('utf-8', errors='replace').strip()
        return select_changes([], fallback='cannot read complete git diff; use full checks (CalledProcessError'
                              + (': ' + detail if detail else '') + ')')
    except (UnicodeError, OSError) as error:
        return select_changes([], fallback='cannot read complete git diff; use full checks (' + type(error).__name__ + ')')


def local_commands(scope):
    if scope == 'pr-selected':
        raise ValueError('component commands require a resolved catalog')
    commands = [['python3', '-m', 'unittest', 'discover', '-s', 'tools', '-p', 'test_*.py']]
    if checks_for(scope)['unit']:
        commands += [['make', 'test'], ['swift', 'run', 'replicator-lab', 'ddl-catalog', 'check'], ['make', 'periphery']]
        if scope == 'full':
            for suite in ('correctness', 'lifecycle', 'recovery', 'native', 'demo'):
                command = ['swift', 'run', 'replicator-lab', 'test', '--profile', 'all', '--suite', suite]
                if suite in ('correctness', 'lifecycle'):
                    command += ['--variant', 'all']
                commands.append(command)
        else:
            from ci_matrix import SMOKE_PROFILES
            cases = json.loads((ROOT / 'tools/ci_matrix.json').read_text())['pr_smoke']['cases']
            for profile in SMOKE_PROFILES:
                commands.append(['swift', 'run', 'replicator-lab', 'test', '--profile', profile,
                                 '--suite', 'correctness', '--tier', 'full',
                                 *[arg for case in cases for arg in ('--case', case)]])
    return commands


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='origin/main', help='compare with this merge base (default: origin/main)')
    parser.add_argument('--head', help='compare a committed revision; omit to include staged, unstaged, and untracked files')
    parser.add_argument('--lab', type=Path, help='built lab binary for component plans; default: swift run replicator-lab')
    parser.add_argument('--full', action='store_true', help='force the full test scope')
    output = parser.add_mutually_exclusive_group()
    output.add_argument('--commands', action='store_true', help='print local commands instead of JSON')
    output.add_argument('--run', action='store_true', help='run the local commands; stop at the first failure')
    args = parser.parse_args()
    result = from_git(args.base, args.head or 'HEAD', include_worktree=args.head is None)
    if args.full:
        result.update(scope='full', checks=checks_for('full'), selected_by=[], reason='explicit full selection')
    if result['scope'] == 'pr-selected':
        from ci_lab import component_plan, command
        prefix = [str(args.lab.resolve())] if args.lab else ['swift', 'run', 'replicator-lab']
        plan = component_plan(lambda *a: subprocess.check_output(prefix + list(a), cwd=ROOT, text=True), result)
        result['integration_plan'] = plan
        commands = local_commands('tools') + local_commands('pr-smoke')[1:4]
        for group in plan['include']:
            # Local execution uses the normal image. CI measures coverage and
            # verifies the release binary separately. Keep transport and cases.
            arguments = command(dict(group, image='release'))
            arguments.remove('--skip-build')
            commands.append(prefix + arguments)
    else:
        commands = local_commands(result['scope'])
    result['commands'] = [shlex.join(c) for c in commands]
    if args.commands:
        print('\n'.join(result['commands']))
    else:
        print(json.dumps(result, indent=2), flush=True)
    if args.run:
        for command in commands:
            print('+ ' + shlex.join(command), file=sys.stderr, flush=True)
            result = subprocess.run(command, cwd=ROOT, stdout=sys.stderr)
            if result.returncode:
                # Preserve command failure without reporting a tool traceback.
                raise SystemExit(result.returncode if result.returncode > 0 else 128 - result.returncode)


if __name__ == '__main__':
    main()
