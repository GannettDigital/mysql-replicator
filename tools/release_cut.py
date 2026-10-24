#!/usr/bin/env python3
"""Check, tag, or publish a release from the packages tested by main CI."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

from release_evidence import require, verify
from release_version import ROOT, SWIFT, swift_source, versions


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def api(repo, path):
    return json.loads(run('gh', 'api', f'repos/{repo}/{path}'))


def verify_run(data, repo, commit):
    require(data['repository']['full_name'] == repo, 'CI belongs to another repository')
    require(data['head_sha'] == commit and data['head_branch'] == 'main'
            and data['event'] == 'push', 'CI must be a main push on the exact commit')
    require(data['path'] == '.github/workflows/ci.yml', 'unexpected CI workflow')
    require(data['status'] == 'completed' and data['conclusion'] == 'success',
            'main CI must finish successfully')


def verify_files(directory):
    """Check every manifest entry; reject paths outside the artifact directory."""
    lines = (directory / 'SHA256SUMS').read_text().splitlines()
    require(bool(lines), 'empty checksum manifest')
    names = set()
    for line in lines:
        match = re.fullmatch(r'([0-9a-f]{64}) [ *](.+)', line)
        require(match is not None, 'invalid checksum entry')
        digest, name = match.groups()
        require(Path(name).name == name and name not in ('.', '..') and name not in names,
                'invalid or duplicate asset name')
        names.add(name)
        path = directory / name
        require(path.is_file() and not path.is_symlink(), f'missing asset: {name}')
        checksum = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                checksum.update(chunk)
        require(checksum.hexdigest() == digest, f'checksum differs: {name}')
    return names


def required_assets(version):
    _, debian = versions(version)
    return {f'mysql-replicator-{version}-linux-x86_64.tar.gz',
            f'mysql-replicator-{version}-linux-x86_64-image.tar.gz',
            f'mysql-replicator_{debian}_amd64.deb', 'install.sh',
            'apply.example.yaml', 'run.minimal.yaml', 'replay.minimal.yaml', 'LICENSE', 'NOTICE'}


def verify_packages(directory, repo, commit, ci, version):
    checksums = (directory / 'SHA256SUMS').read_bytes()
    evidence = json.loads((directory / 'release-test-evidence.json').read_text())
    verify(evidence, checksums, dict(GITHUB_REPOSITORY=repo, GITHUB_SHA=commit,
           CI_RUN_ID=str(ci['id']), CI_RUN_ATTEMPT=str(ci['run_attempt'])), version,
           run('git', 'rev-parse', commit + '^{tree}'))
    require(required_assets(version) <= verify_files(directory), 'release assets are incomplete')


def prepare(action):
    version = (ROOT / 'VERSION').read_text().strip()
    versions(version)
    require('-' in version, 'the release workflow only supports prereleases')
    require((ROOT / SWIFT).read_text() == swift_source(version), 'stale Swift version')
    require(not run('git', 'status', '--porcelain'), 'use a clean checkout of the release commit')
    plan = json.loads((ROOT / f'docs/releases/{version}.plan.json').read_text())
    repo = plan['repository']
    require(bool(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo)), 'invalid repository')
    prs = plan['pull_requests']
    require(bool(prs) and all(type(n) is int and n > 0 for n in prs)
            and len(prs) == len(set(prs)), 'release plan must list unique PR numbers')
    tag = 'v' + version
    commit = run('git', 'rev-parse', 'HEAD')
    for number in prs:
        require(api(repo, f'pulls/{number}')['merged'] is True, f'PR #{number} is not merged')
    main = api(repo, 'commits/main')['sha']
    if action != 'publish':
        require(commit == main, 'check out the current upstream main commit first')
    else:
        comparison = api(repo, f'compare/{commit}...main')
        require(comparison['status'] in ('ahead', 'identical'), 'release commit is not on main')
    notes = ROOT / f'docs/releases/{version}.md'
    require(notes.is_file() and bool(notes.read_text().strip()), 'release notes are missing')
    runs = api(repo, f'actions/workflows/ci.yml/runs?branch=main&event=push&head_sha={commit}&per_page=100')
    successful = [r for r in runs['workflow_runs']
                  if r['status'] == 'completed' and r['conclusion'] == 'success']
    require(bool(successful), 'wait for successful main CI on this exact commit')
    ci = api(repo, f"actions/runs/{successful[0]['id']}")
    verify_run(ci, repo, commit)
    env = dict(repo=repo, tag=tag, commit=commit, version=version, ci=ci)
    return env


def execute(action):
    context = prepare(action)
    repo, tag, commit, version, ci = (context[k] for k in ('repo', 'tag', 'commit', 'version', 'ci'))
    # No branch pushes or force updates. Use the named repository, not a mutable remote URL.
    url = f'https://github.com/{repo}.git'
    with tempfile.TemporaryDirectory(prefix='mysql-replicator-release-') as temporary:
        directory = Path(temporary)
        if action == 'publish':
            release = api(repo, f'releases/tags/{tag}')
            require(release['draft'] and release['prerelease'], 'expected a draft prerelease')
            remote = run('git', 'ls-remote', url, f'refs/tags/{tag}', f'refs/tags/{tag}^{{}}')
            require(any(line.split() == [commit, f'refs/tags/{tag}^{{}}']
                        for line in remote.splitlines()), 'annotated release tag differs from HEAD')
            run('gh', 'release', 'download', tag, '--repo', repo, '--dir', str(directory))
        else:
            remote = run('git', 'ls-remote', url, f'refs/tags/{tag}')
            require(not remote, 'remote tag already exists; inspect its release workflow')
            require(not run('git', 'tag', '--list', tag), 'local tag already exists; inspect it before retrying')
            for artifact in ('linux-release-packages', 'release-test-evidence'):
                run('gh', 'run', 'download', str(ci['id']), '--repo', repo,
                    '--name', artifact, '--dir', str(directory))
            require((directory / 'release-verified').is_file(), 'missing package verification marker')
        verify_packages(directory, repo, commit, ci, version)
        # Detect a rerun started while assets were downloaded. Do not mix attempts.
        current = api(repo, f"actions/runs/{ci['id']}")
        verify_run(current, repo, commit)
        require(current['run_attempt'] == ci['run_attempt'], 'CI attempt changed; run the command again')
        print(f'Verified {tag} at {commit}. CI: {ci["html_url"]}', flush=True)
        if action == 'tag':
            require(api(repo, 'commits/main')['sha'] == commit, 'main changed; check the new commit first')
            run('git', 'tag', '-a', tag, commit, '-m', f'Beta release {version}')
            # A failed push leaves the local tag for inspection. Never delete or move it here.
            run('git', 'push', url, f'refs/tags/{tag}:refs/tags/{tag}')
            print('Tag pushed. The release workflow will create a draft. Review its notes and assets.')
        elif action == 'publish':
            run('gh', 'release', 'edit', tag, '--repo', repo, '--draft=false',
                '--prerelease', '--latest=false')
            print('Prerelease published. Check the release workflow for the GHCR image push.')
        else:
            print('Checks passed. No tag or release was changed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('check', 'tag', 'publish'), nargs='?', default='check')
    args = parser.parse_args()
    try:
        execute(args.action)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Release stopped: {error}\n')


if __name__ == '__main__':
    main()
