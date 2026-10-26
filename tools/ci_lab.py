#!/usr/bin/env python3
"""Bundle the Linux lab once and run isolated CI shards without a compiler."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'artifacts/ci/lab'


def matrix():
    return json.loads((BUNDLE / 'matrix.json').read_text())


def command(shard):
    args = ['test', '--profile', shard['profile'], '--suite', shard['suite'], '--skip-build']
    if shard['image'] == 'coverage' and shard['suite'] != 'native':
        args += ['--coverage']
    if shard['suite'] in ('correctness', 'lifecycle'):
        args += ['--variant', shard['variant']]
    if 'dml_transport' in shard:
        args += ['--dml-transport', shard['dml_transport']]
    if shard['suite'] == 'correctness':
        args += ['--tier', shard['tier']]
    if shard['suite'] in ('correctness', 'lifecycle', 'demo'):
        for case in shard['cases']:
            args += ['--case', case]
    return args


def full_catalogs(query):
    catalogs = [json.loads(query('test', '--profile', 'all', '--suite', suite,
                                '--variant', 'all', '--list'))
                for suite in ('correctness', 'lifecycle')]
    catalogs.append(json.loads(query('test', '--profile', 'all', '--suite', 'all', '--list')))
    return catalogs


def component_plan(query, change_plan):
    from ci_matrix import generate
    from ci_jobs import assign_jobs
    from test_components import select_groups
    policy = json.loads((ROOT / 'tools/ci_matrix.json').read_text())
    full = generate(full_catalogs(query), policy)
    selected = select_groups(full, change_plan, policy['pr_smoke'])
    return assign_jobs(selected, json.loads((ROOT / 'tools/ci_jobs.json').read_text()))


def select_plan(query):
    from ci_matrix import SMOKE_PROFILES, generate, generate_smoke, generate_production
    scope = os.environ.get('CI_SUITE', 'full')
    policy = json.loads((ROOT / 'tools/ci_matrix.json').read_text())
    from ci_jobs import assign_jobs
    job_policy = json.loads((ROOT / 'tools/ci_jobs.json').read_text())
    if scope == 'production':
        return assign_jobs(generate_production([json.loads(query('test', '--profile', profile, '--suite',
                           'correctness', '--list')) for profile in SMOKE_PROFILES]), job_policy)
    if scope == 'pr-smoke':
        return assign_jobs(generate_smoke([json.loads(query('test', '--profile', profile, '--suite', 'correctness',
                                               '--variant', 'default', '--tier', 'full', '--list'))
                               for profile in SMOKE_PROFILES], policy['pr_smoke']), job_policy)
    if scope == 'pr-selected':
        path = Path(os.environ.get('CI_TEST_SELECTION', ROOT / 'artifacts/ci/test-selection.json'))
        return component_plan(query, json.loads(path.read_text()))
    if scope != 'full':
        raise ValueError(f'unknown CI_SUITE: {scope}')
    catalogs = full_catalogs(query)
    return assign_jobs(generate(catalogs, policy,
                      expanded_coverage=os.environ.get('CI_EXPANDED_COVERAGE') == 'true'), job_policy)


def plan(query):
    result = select_plan(query)
    from lab_features import with_features
    result = with_features(result, [dict(scenarios=result['inventory'])],
                           complete=result['scope'] == 'full')
    from lab_migrations import validate_migrations
    validate_migrations([dict(scenarios=result['inventory'])], complete=result['scope'] == 'full',
                        groups=result['include'], selection_only=True)
    result['inputs'] = query('build-inputs').strip()
    destination = ROOT / 'artifacts/ci/matrix.json'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(result, indent=2) + '\n')
    print(f"CI plan: {len(result['jobs'])} jobs, {len(result['include'])} execution groups, {result['obligations']} catalog obligations, "
          f"{result['coverage_reports']} instrumented collections; {destination}")
    return result


def lab(*args):
    env = dict(os.environ, LD_LIBRARY_PATH=str(BUNDLE / 'lib'))
    return subprocess.check_output([str(BUNDLE / 'replicator-lab'), *args], cwd=ROOT, env=env, text=True).strip()


def bundle(binary):
    if BUNDLE.exists():
        shutil.rmtree(BUNDLE)
    BUNDLE.mkdir(parents=True, exist_ok=True)
    (BUNDLE / 'lib').mkdir(exist_ok=True)
    shutil.copy2(binary, BUNDLE / 'replicator-lab')
    # Ship Swift/Foundation, not glibc: libc must match the worker's loader.
    # Jobs use the same Ubuntu release and install their normal OS libraries.
    listing = subprocess.check_output(['ldd', str(binary)], text=True)
    for path in runtime_libraries(listing):
        shutil.copy2(path, BUNDLE / 'lib' / path.name)
    digest = lab('build-inputs')
    (BUNDLE / 'inputs.sha256').write_text(digest + '\n')
    result = plan(lab)
    (BUNDLE / 'matrix.json').write_text(json.dumps(result) + '\n')
    archive = BUNDLE.parent / 'lab.tar.gz'
    with tarfile.open(archive, 'w:gz') as out:
        out.add(BUNDLE, arcname='lab')
    (archive.parent / 'lab.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  lab.tar.gz\n')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('inputs=' + digest + '\n')
        output.write('matrix=' + json.dumps({'include': result['jobs']}, separators=(',', ':')) + '\n')
        output.write('coverage_reports=' + str(result['coverage_reports']) + '\n')
        output.write('images=' + json.dumps(result['images']) + '\n')
        output.write('scope=' + result['scope'] + '\n')


def runtime_libraries(listing):
    if 'not found' in listing:
        raise ValueError('unresolved lab shared library: ' + listing)
    libraries = []
    for line in listing.splitlines():
        if '=>' in line:
            path = Path(line.split('=>', 1)[1].strip().split()[0])
            if path.is_absolute() and path.parent.name == 'linux' and 'swift' in path.parts:
                libraries.append(path)
    if not libraries:
        raise ValueError('no Swift runtime libraries found in ldd output')
    return libraries


def validate_bundle():
    if lab('build-inputs') != (BUNDLE / 'inputs.sha256').read_text().strip():
        raise ValueError('lab bundle inputs differ from this checkout')


def run_shard(identifier, job_id=None):
    from ci_measurements import record_shard
    options = {'job_id': job_id} if job_id is not None else {}
    with record_shard(ROOT, identifier, build_inputs=os.environ.get('GITHUB_ACTIONS') == 'true', **options):
        _run_shard(identifier)


def run_job(identifier):
    from ci_jobs import validate_jobs
    manifest = matrix()
    validate_jobs(manifest)
    matches = [job for job in manifest['jobs'] if job['id'] == identifier]
    if len(matches) != 1:
        raise ValueError('unknown CI job: ' + identifier)
    job = matches[0]
    print('Execution groups: ' + ', '.join(job['group_ids']), flush=True)
    failures = []
    for group in job['group_ids']:
        try:
            run_shard(group, job_id=identifier)
        except Exception as error:
            # Keep the later groups independent of an earlier assertion failure.
            # KeyboardInterrupt and SystemExit still stop the job immediately.
            print(f'Execution group {group} failed: {error}', file=sys.stderr, flush=True)
            failures.append(group)
    if failures:
        raise RuntimeError('Failed execution groups: ' + ', '.join(failures))


def prepare_job(identifier):
    """Fetch/build fixture images without creating containers or data volumes."""
    from ci_jobs import validate_jobs
    from ci_measurements import provenance, write
    validate_bundle()
    manifest = matrix()
    validate_jobs(manifest)
    matches = [job for job in manifest['jobs'] if job['id'] == identifier]
    if len(matches) != 1:
        raise ValueError('unknown CI job: ' + identifier)
    job = matches[0]
    catalog = json.loads(lab('test', '--profile', job['profile'], '--suite', 'correctness', '--list'))
    fixture = next(p['fixture'] for p in catalog['profiles'] if p['id'] == job['profile'])
    env = dict(os.environ, **fixture['environment'])
    compose = ['docker', 'compose', '-p', 'ci-image-preparation']
    for file in fixture['compose_files']:
        compose += ['-f', str(ROOT / file)]
    config = json.loads(subprocess.check_output(compose + ['config', '--format', 'json'], cwd=ROOT, env=env, text=True))
    pulls, builds, seen = [], [], set()
    for name in fixture['services']:
        service = config['services'][name]
        if service['image'] in seen:
            continue
        seen.add(service['image'])
        (builds if 'build' in service else pulls).append(name)
    record = dict(version=1, job_id=identifier, **provenance(), status='failed', phases={}, images=sorted(seen))
    started = time.monotonic()
    try:
        for phase, args, services in [('pull', ['pull', '--policy', 'missing'], pulls),
                                      ('build', ['build'], builds)]:
            if not services:
                continue
            begin = time.monotonic()
            status = 'failed'
            try:
                subprocess.run(compose + args + services, cwd=ROOT, env=env, check=True, timeout=600)
                status = 'passed'
            finally:
                record['phases'][phase] = dict(seconds=time.monotonic() - begin, status=status)
        record['status'] = 'passed'
    finally:
        record['seconds'] = time.monotonic() - started
        write(ROOT / 'artifacts/ci/setup' / (identifier + '.json'), record)
        summary = '\n'.join(['', '### MySQL image preparation (seconds)', '',
                             '| Phase | Seconds | Result |', '|---|---:|---|',
                             *[f"| {p} | {v['seconds']:.1f} | {v['status']} |" for p, v in record['phases'].items()],
                             '', 'Containers and data directories start in the test step.', ''])
        print(summary, flush=True)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
                output.write(summary)
    if os.environ.get('GITHUB_ENV'):
        with open(os.environ['GITHUB_ENV'], 'a') as output:
            output.write('REPLICATOR_LAB_IMAGES_PREPARED=true\n')


def _run_shard(identifier):
    validate_bundle()
    manifest = matrix()
    if manifest['inputs'] != (BUNDLE / 'inputs.sha256').read_text().strip():
        raise ValueError('matrix inputs differ from this bundle')
    matches = [s for s in manifest['include'] if s['id'] == identifier]
    if len(matches) != 1:
        raise ValueError(f'unknown or ambiguous shard: {identifier}')
    shard = matches[0]
    selection = f"{shard['profile']} / {shard['area']} / {shard.get('variant', 'default')} / {shard['image']}"
    print('Test selection: ' + selection, flush=True)
    if shard['cases']:
        print('Cases: ' + ', '.join(shard['cases']), flush=True)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write('### Test selection\n\n' + selection + '\n\n')
            summary.writelines(f'- `{case}`\n' for case in shard['cases'])
    if shard['image'] == 'release':
        subprocess.run(['python3', 'tools/verify_release_binary.py'], cwd=ROOT, check=True)
    from coverage_report import downloaded_inputs
    before = set(downloaded_inputs(ROOT / 'artifacts/lab')) if shard['reports'] else set()
    env = dict(os.environ, LD_LIBRARY_PATH=str(BUNDLE / 'lib'))
    subprocess.run([str(BUNDLE / 'replicator-lab'), *command(shard)], cwd=ROOT, env=env, check=True,
                   timeout=manifest.get('group_timeout_seconds', 45 * 60))
    if shard['reports']:
        reports = set(downloaded_inputs(ROOT / 'artifacts/lab')) - before
        # Discover only per-fixture combined reports, not per-invocation reports.
        reports = [p for p in reports if p.parent.name == 'combined']
        if len(reports) != shard['reports']:
            raise ValueError(f"{identifier}: expected {shard['reports']} coverage collections, got {len(reports)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--bundle', type=Path)
    group.add_argument('--run', help='execution group ID from the bundled plan')
    group.add_argument('--run-job', help='CI job ID from the bundled plan')
    group.add_argument('--prepare-job', help='prepare the selected job\'s MySQL images without starting containers')
    group.add_argument('--plan', type=Path, help='generate the CI matrix using this local lab binary')
    args = parser.parse_args()
    if args.bundle:
        bundle(args.bundle)
    elif args.plan:
        binary = args.plan.resolve()
        plan(lambda *arguments: subprocess.check_output([str(binary), *arguments], cwd=ROOT, text=True))
    elif args.prepare_job:
        prepare_job(args.prepare_job)
    elif args.run_job:
        run_job(args.run_job)
    else:
        run_shard(args.run)


if __name__ == '__main__':
    main()
