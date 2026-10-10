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

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'artifacts/ci/lab'


def matrix():
    return json.loads((BUNDLE / 'matrix.json').read_text())


def command(shard):
    args = ['test', '--profile', shard['profile'], '--suite', shard['suite'], '--skip-build']
    if shard['image'] == 'coverage':
        args += ['--coverage']
    if shard['suite'] in ('correctness', 'lifecycle'):
        args += ['--variant', shard['variant']]
    if shard['suite'] == 'correctness':
        args += ['--tier', shard['tier']]
        for case in shard['cases']:
            args += ['--case', case]
    return args


def plan(query):
    from ci_matrix import generate
    catalogs = [json.loads(query('test', '--profile', 'all', '--suite', suite,
                                '--variant', 'all', '--list'))
                for suite in ('correctness', 'lifecycle')]
    catalogs.append(json.loads(query('test', '--profile', 'all', '--suite', 'all', '--list')))
    result = generate(catalogs, json.loads((ROOT / 'tools/ci_matrix.json').read_text()),
                      expanded_coverage=os.environ.get('CI_EXPANDED_COVERAGE') == 'true')
    result['inputs'] = query('build-inputs').strip()
    destination = ROOT / 'artifacts/ci/matrix.json'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(result, indent=2) + '\n')
    print(f"CI plan: {len(result['include'])} shards, {result['obligations']} catalog obligations, "
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
        output.write('matrix=' + json.dumps({'include': result['include']}, separators=(',', ':')) + '\n')
        output.write('coverage_reports=' + str(result['coverage_reports']) + '\n')


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


def run_shard(identifier):
    from ci_measurements import record_shard
    with record_shard(ROOT, identifier):
        _run_shard(identifier)


def _run_shard(identifier):
    validate_bundle()
    manifest = matrix()
    if manifest['inputs'] != (BUNDLE / 'inputs.sha256').read_text().strip():
        raise ValueError('matrix inputs differ from this bundle')
    matches = [s for s in manifest['include'] if s['id'] == identifier]
    if len(matches) != 1:
        raise ValueError(f'unknown or ambiguous shard: {identifier}')
    shard = matches[0]
    if shard['suite'] == 'recovery':
        subprocess.run(['docker', 'tag', 'mysql-replicator-packaging:lab', 'mysql-replicator-packaging:reverse'], check=True)
    if shard['image'] == 'release':
        subprocess.run(['python3', 'tools/verify_release_binary.py'], cwd=ROOT, check=True)
    env = dict(os.environ, LD_LIBRARY_PATH=str(BUNDLE / 'lib'))
    subprocess.run([str(BUNDLE / 'replicator-lab'), *command(shard)], cwd=ROOT, env=env, check=True)
    if shard['reports']:
        from coverage_report import downloaded_inputs
        reports = downloaded_inputs(ROOT / 'artifacts/lab')
        # Discover only per-fixture combined reports, not per-invocation reports.
        reports = [p for p in reports if p.parent.name == 'combined']
        if len(reports) != shard['reports']:
            raise ValueError(f"{identifier}: expected {shard['reports']} coverage collections, got {len(reports)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--bundle', type=Path)
    group.add_argument('--run', help='shard ID from the bundled CI matrix')
    group.add_argument('--plan', type=Path, help='generate the CI matrix using this local lab binary')
    args = parser.parse_args()
    if args.bundle:
        bundle(args.bundle)
    elif args.plan:
        binary = args.plan.resolve()
        plan(lambda *arguments: subprocess.check_output([str(binary), *arguments], cwd=ROOT, text=True))
    else:
        run_shard(args.run)


if __name__ == '__main__':
    main()
