#!/usr/bin/env python3
"""Link pre-merge full tests, the merged Git tree, and the exact production packages."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

REQUIRED_JOBS = {'lab-tools', 'unit-tests', 'packaging-and-smoke', 'combined-coverage', 'periphery', 'swift-lint', 'measurements'}
PRODUCTION_JOBS = {'lab-tools', 'packaging-and-smoke', 'measurements', 'tested-source'}


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def tree():
    return subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], text=True).strip()


def origin(env):
    return {k: env[v] for k, v in [('commit', 'GITHUB_SHA'), ('run_id', 'GITHUB_RUN_ID'),
                                  ('attempt', 'GITHUB_RUN_ATTEMPT')]}


def validate_builds(builds, shard_attempts, provenance, image):
    require(set(builds) == {image} and bool(shard_attempts), 'missing tested build or shard attempts')
    for name, build in builds.items():
        require(build['image'] == name and all(build[k] == provenance[k] for k in ('commit', 'run_id'))
                and 1 <= int(build['attempt']) <= int(provenance['attempt']), 'build belongs to another run or attempt')
    require(all(1 <= int(a) <= int(provenance['attempt']) for a in shard_attempts.values()), 'invalid shard attempt')


def validate_receipt(receipt, scope, jobs, image):
    require(receipt['format_version'] == 3 and receipt['scope'] == scope, 'wrong evidence format or scope')
    require(re.fullmatch(r'[0-9a-f]{40}', receipt['source_tree']) is not None, 'invalid source tree')
    require(set(receipt['jobs']) == jobs and all(v == 'success' for v in receipt['jobs'].values()),
            'evidence has missing or failed jobs')
    require(receipt['profiles'] and all(p['catalog_expected'] > 0 and p['catalog_expected'] == p['catalog_passed']
            for p in receipt['profiles'].values()), 'evidence has incomplete profiles')
    require(1 <= int(receipt['report_attempt']) <= int(receipt['provenance']['attempt']), 'invalid report attempt')
    validate_builds(receipt['builds'], receipt['shard_attempts'],
                    dict(receipt['provenance'], attempt=receipt['report_attempt']), image)


def create(report, jobs, env, version, source_tree):
    scope = report['scope']
    require(scope in ('full', 'production'), 'full or production report required')
    required = REQUIRED_JOBS if scope == 'full' else PRODUCTION_JOBS
    require(set(jobs) == required and all(j['result'] == 'success' for j in jobs.values()),
            'all required jobs must succeed')
    require(report['complete'] is True, 'complete report required')
    provenance = origin(env)
    source = report['provenance']
    require(all(source[k] == provenance[k] for k in ('commit', 'run_id')) and
            1 <= int(source['attempt']) <= int(provenance['attempt']), 'report belongs to another commit or run attempt')
    require(all(not p['catalog_missing'] for p in report['profiles'].values()), 'profile catalog is incomplete')
    receipt = dict(format_version=3, scope=scope, version=version, source_tree=source_tree,
                   provenance=provenance, report_attempt=source['attempt'], builds=report['builds'],
                   shard_attempts=report['shard_attempts'], repository=env['GITHUB_REPOSITORY'],
                   event=env['GITHUB_EVENT_NAME'], ref=env['GITHUB_REF'], coverage_mode=report['coverage_mode'],
                   profiles={n: {k: p[k] for k in ('catalog_expected', 'catalog_passed', 'coverage_collections')}
                             for n, p in report['profiles'].items()}, jobs={n: j['result'] for n, j in jobs.items()})
    validate_receipt(receipt, scope, required, 'coverage' if scope == 'full' else 'release')
    if scope == 'full':
        require(receipt['coverage_mode'] == 'all', 'full tests must use instrumentation')
    return receipt


def validate_test_run(tests, run, commit, repository, source_tree):
    """Use GitHub run and commit records, not only values supplied by an artifact."""
    validate_receipt(tests, 'full', REQUIRED_JOBS, 'coverage')
    require(tests['coverage_mode'] == 'all', 'full tests must use instrumentation')
    require(tests['repository'] == repository and run['repository']['full_name'] == repository
            and run['head_repository']['full_name'] == repository, 'test run is from another repository')
    require(run['status'] == 'completed' and run['conclusion'] == 'success', 'test run did not succeed')
    require(run['path'] == '.github/workflows/ci.yml' and run['event'] in ('pull_request', 'workflow_dispatch'),
            'test run must use the CI workflow before package promotion')
    provenance = tests['provenance']
    require(str(run['id']) == provenance['run_id'] and str(run['run_attempt']) == provenance['attempt']
            and tests['event'] == run['event'], 'test receipt does not match the GitHub run')
    require(commit['sha'] == provenance['commit'] and commit['tree']['sha'] == source_tree
            and tests['source_tree'] == source_tree, 'tested Git tree differs from merged source')
    # Actions checks out a synthetic merge commit for PRs. A squash merge has a
    # different commit ID but must have exactly the same tracked file contents.
    permitted = {commit['sha']}
    if run['event'] == 'pull_request':
        permitted.update(p['sha'] for p in commit['parents'])
    require(run['head_sha'] in permitted, 'tested commit is not the workflow head or its PR merge')


def verify(evidence, checksums, env, version, source_tree):
    validate_receipt(evidence, 'production', PRODUCTION_JOBS, 'release')
    require(evidence['version'] == version, 'release version differs from tested version')
    require(evidence['repository'] == env['GITHUB_REPOSITORY'], 'release evidence is from another repository')
    require(evidence['event'] == 'push' and evidence['ref'] == 'refs/heads/main', 'release needs main push evidence')
    expected = dict(commit=env['GITHUB_SHA'], run_id=env['CI_RUN_ID'], attempt=env['CI_RUN_ATTEMPT'])
    require(evidence['provenance'] == expected, 'release evidence is from another commit or run attempt')
    require(evidence['source_tree'] == source_tree, 'release tree differs from package source')
    linked = evidence['tested_source']
    require(linked['tests']['version'] == version, 'full test version differs')
    validate_test_run(linked['tests'], linked['run'], linked['commit'], env['GITHUB_REPOSITORY'], source_tree)
    require(checksums.strip() and evidence['builds']['release']['package_checksums_sha256'] ==
            hashlib.sha256(checksums).hexdigest(), 'release packages differ from tested packages')


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def find_tests(env, source_tree, run_id=None):
    repo = env['GITHUB_REPOSITORY']
    # Bound the search. An explicit run ID handles an older retained receipt.
    for page in range(1, 11):
        runs = ([api(f'repos/{repo}/actions/runs/{run_id}')] if run_id else
                api(f'repos/{repo}/actions/workflows/ci.yml/runs?status=success&per_page=100&page={page}')['workflow_runs'])
        for run in runs:
            if run['event'] not in ('pull_request', 'workflow_dispatch') or (run.get('head_repository') or {}).get('full_name') != repo:
                continue
            artifacts = api(f"repos/{repo}/actions/runs/{run['id']}/artifacts?name=full-test-evidence")['artifacts']
            if not any(a['name'] == 'full-test-evidence' and not a['expired'] for a in artifacts):
                continue
            with tempfile.TemporaryDirectory() as directory:
                subprocess.run(['gh', 'run', 'download', str(run['id']), '--repo', repo,
                                '--name', 'full-test-evidence', '--dir', directory], check=True)
                tests = json.loads((Path(directory) / 'full-test-evidence.json').read_text())
            if tests.get('source_tree') != source_tree:
                continue
            sha = tests['provenance']['commit']
            require(re.fullmatch(r'[0-9a-f]{40}', sha) is not None, 'invalid test commit')
            commit = api(f'repos/{repo}/git/commits/{sha}')
            validate_test_run(tests, run, commit, repo, source_tree)
            return dict(tests=tests, run=run, commit=commit)
        if run_id or len(runs) < 100:
            break
    raise ValueError('No successful full test run has this Git tree. Run CI with suite=full on this exact source, '
                     'then rerun the main package jobs. Do not bypass the test requirement.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['create', 'verify', 'find-tests'])
    parser.add_argument('--packages', type=Path, default=Path('artifacts/release'))
    parser.add_argument('--report', type=Path, default=Path('artifacts/ci/report/report.json'))
    parser.add_argument('--tested-source', type=Path, default=Path('artifacts/ci/tested-source.json'))
    parser.add_argument('--test-run', help='successful full CI run ID; otherwise search the latest 1000 successful runs')
    args = parser.parse_args()
    if args.action == 'find-tests':
        linked = find_tests(os.environ, tree(), args.test_run)
        args.tested_source.parent.mkdir(parents=True, exist_ok=True)
        args.tested_source.write_text(json.dumps(linked, indent=2) + '\n')
        print('Matched full test run: ' + str(linked['run']['id']))
        return
    version = Path('VERSION').read_text().strip()
    path = args.packages / 'release-test-evidence.json'
    if args.action == 'verify':
        verify(json.loads(path.read_text()), (args.packages / 'SHA256SUMS').read_bytes(), os.environ, version, tree())
        print('Verified full source tests and the exact production packages.')
        return
    evidence = create(json.loads(args.report.read_text()), json.loads(os.environ['CI_JOB_RESULTS']),
                      os.environ, version, tree())
    if evidence['scope'] == 'full':
        path = Path('artifacts/ci/full-test-evidence.json')
    else:
        evidence['tested_source'] = json.loads(args.tested_source.read_text())
        verify(evidence, (args.packages / 'SHA256SUMS').read_bytes(),
               dict(os.environ, CI_RUN_ID=os.environ['GITHUB_RUN_ID'], CI_RUN_ATTEMPT=os.environ['GITHUB_RUN_ATTEMPT']),
               version, tree())
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(evidence, indent=2) + '\n')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write('Test evidence: `' + str(path) + '`.\n\nGit tree: `' + evidence['source_tree'] + '`.\n')
        if evidence['scope'] == 'production':
            summary.write('\nFull test run: ' + evidence['tested_source']['tests']['provenance']['run_id'] + '.\n')


if __name__ == '__main__':
    main()
