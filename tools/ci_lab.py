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
    return json.loads((ROOT / 'tools/ci_matrix.json').read_text())


def command(shard):
    if shard['suite'] == 'recovery':
        if shard['image'] != 'release' or shard['profile'] != 'mysql57-to-mysql84-innodb':
            raise ValueError('specialized recovery requires the reverse release profile')
        return ['reverse-suite', '--skip-build', '--events', '0']
    args = ['test', '--profile', shard['profile'], '--skip-build']
    if shard['image'] == 'coverage':
        args += ['--coverage']
    if shard['suite'] == 'sample':
        args += ['--case', 'positive', '--case', 'ddl-modify-demo-varchar-120', '--case', 'ddl-index-create']
    else:
        args += ['--suite', shard['suite']]
        if shard['suite'] == 'correctness':
            args += ['--tier', 'smoke']
    return args


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
    archive = BUNDLE.parent / 'lab.tar.gz'
    with tarfile.open(archive, 'w:gz') as out:
        out.add(BUNDLE, arcname='lab')
    (archive.parent / 'lab.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  lab.tar.gz\n')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('inputs=' + digest + '\n')
        output.write('matrix=' + json.dumps(matrix(), separators=(',', ':')) + '\n')


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


def run_shard(identifier):
    shard = next(s for s in matrix()['include'] if s['id'] == identifier)
    if lab('build-inputs') != (BUNDLE / 'inputs.sha256').read_text().strip():
        raise ValueError('lab bundle inputs differ from this checkout')
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
    group.add_argument('--run', choices=[s['id'] for s in matrix()['include']])
    args = parser.parse_args()
    if args.bundle:
        bundle(args.bundle)
    else:
        run_shard(args.run)


if __name__ == '__main__':
    main()
