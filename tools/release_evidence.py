#!/usr/bin/env python3
"""Bind a complete full-suite CI run to the packages it tested."""
import argparse
import hashlib
import json
import os
from pathlib import Path

REQUIRED_JOBS = {'lab-tools', 'unit-tests', 'packaging-and-smoke', 'combined-coverage', 'periphery', 'measurements'}


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def validate_builds(builds, shard_attempts, provenance):
    require('release' in builds and bool(shard_attempts), 'missing tested build or shard attempts')
    for image, build in builds.items():
        require(build['image'] == image and all(build[k] == provenance[k] for k in ('commit', 'run_id'))
                and 1 <= int(build['attempt']) <= int(provenance['attempt']), 'build belongs to another run or attempt')
    require(all(1 <= int(a) <= int(provenance['attempt']) for a in shard_attempts.values()),
            'invalid shard attempt')


def create(report, jobs, checksums, env, version):
    require(set(jobs) == REQUIRED_JOBS and all(j['result'] == 'success' for j in jobs.values()),
            'all full-suite jobs must succeed')
    require(report['complete'] is True and report['scope'] == 'full', 'complete full-suite report required')
    provenance = {k: env[v] for k, v in [('commit', 'GITHUB_SHA'), ('run_id', 'GITHUB_RUN_ID'),
                                       ('attempt', 'GITHUB_RUN_ATTEMPT')]}
    origin = report['provenance']
    require(all(origin[k] == provenance[k] for k in ('commit', 'run_id')) and
            1 <= int(origin['attempt']) <= int(provenance['attempt']),
            'report belongs to another commit or run attempt')
    builds = report['builds']
    require(builds['release']['package_checksums_sha256'] == hashlib.sha256(checksums).hexdigest(),
            'release packages differ from tested packages')
    validate_builds(builds, report['shard_attempts'], origin)
    require(report['profiles'] and all(p['catalog_expected'] > 0 and
            p['catalog_expected'] == p['catalog_passed'] and not p['catalog_missing']
            for p in report['profiles'].values()), 'profile catalog is incomplete')
    return dict(format_version=2, report_attempt=origin['attempt'], builds=builds,
                shard_attempts=report['shard_attempts'], version=version, scope='full', provenance=provenance,
                repository=env['GITHUB_REPOSITORY'], event=env['GITHUB_EVENT_NAME'], ref=env['GITHUB_REF'],
                run_url=f"https://github.com/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}/attempts/{env['GITHUB_RUN_ATTEMPT']}",
                package_checksums_sha256=hashlib.sha256(checksums).hexdigest(),
                coverage_mode=report['coverage_mode'],
                profiles={name: {k: p[k] for k in ('catalog_expected', 'catalog_passed', 'coverage_collections')}
                          for name, p in report['profiles'].items()},
                jobs={name: j['result'] for name, j in jobs.items()})


def verify(evidence, checksums, env, version):
    require(evidence['format_version'] == 2 and evidence['scope'] == 'full', 'full release evidence required')
    require(evidence['version'] == version, 'release version differs from tested version')
    require(evidence['repository'] == env['GITHUB_REPOSITORY'], 'release evidence is from another repository')
    require(evidence['event'] == 'push' and evidence['ref'] == 'refs/heads/main', 'release needs main push evidence')
    expected = dict(commit=env['GITHUB_SHA'], run_id=env['CI_RUN_ID'], attempt=env['CI_RUN_ATTEMPT'])
    require(evidence['provenance'] == expected, 'release evidence is from another commit or run attempt')
    require(set(evidence['jobs']) == REQUIRED_JOBS and all(v == 'success' for v in evidence['jobs'].values()),
            'release evidence has missing or failed jobs')
    require(evidence['profiles'] and all(p['catalog_expected'] > 0 and p['catalog_expected'] == p['catalog_passed']
            for p in evidence['profiles'].values()), 'release evidence has incomplete profiles')
    require(1 <= int(evidence['report_attempt']) <= int(expected['attempt']), 'invalid report attempt')
    validate_builds(evidence['builds'], evidence['shard_attempts'], dict(expected, attempt=evidence['report_attempt']))
    require(evidence['builds']['release']['package_checksums_sha256'] == hashlib.sha256(checksums).hexdigest(),
            'release packages differ from tested packages')
    require(evidence['package_checksums_sha256'] == hashlib.sha256(checksums).hexdigest(),
            'release packages differ from tested packages')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['create', 'verify'])
    parser.add_argument('--packages', type=Path, default=Path('artifacts/release'))
    parser.add_argument('--report', type=Path, default=Path('artifacts/ci/report/report.json'))
    args = parser.parse_args()
    checksums = (args.packages / 'SHA256SUMS').read_bytes()
    require(checksums.strip(), 'empty package checksums')
    version = Path('VERSION').read_text().strip()
    path = args.packages / 'release-test-evidence.json'
    if args.action == 'verify':
        verify(json.loads(path.read_text()), checksums, os.environ, version)
        print('Verified full-suite evidence for the tagged commit and its tested packages.')
        return
    evidence = create(json.loads(args.report.read_text()), json.loads(os.environ['CI_JOB_RESULTS']),
                      checksums, os.environ, version)
    path.write_text(json.dumps(evidence, indent=2) + '\n')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write('# Full-suite evidence\n\nCommit: `' + evidence['provenance']['commit'] + '`.\n\n')
        summary.write('| Profile | Passed obligations | Coverage collections |\n| --- | ---: | ---: |\n')
        for name, p in evidence['profiles'].items():
            summary.write(f"| {name} | {p['catalog_passed']}/{p['catalog_expected']} | {p['coverage_collections']} |\n")
        summary.write('\nPackages and this evidence belong to the same CI run. '
                      'Release preparation also requires a successful main push run on the tagged commit.\n')


if __name__ == '__main__':
    main()
