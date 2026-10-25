#!/usr/bin/env python3
"""Prepare and consume the common Linux test build without rebuilding it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

from ci_lab import runtime_libraries
from ci_registry import TAGS, load_receipt

ROOT = Path(__file__).resolve().parents[1]


def rust_executables(messages):
    executables = []
    for line in messages.splitlines():
        value = json.loads(line)
        if value.get('reason') == 'compiler-artifact' and value.get('profile', {}).get('test') and value.get('executable'):
            executables.append(value['executable'])
    if not executables:
        raise ValueError('Rust produced no test executables')
    return sorted(set(executables))


def record_rust_tests():
    result = (ROOT / '.build/rust-test-artifacts.jsonl').read_text()
    path = ROOT / '.build/rust-tests.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(rust_executables(result)) + '\n')


def rust_test():
    executables = json.loads((ROOT / '.build/rust-tests.json').read_text())
    if not executables:
        raise ValueError('Shared build has no Rust tests')
    for name in executables:
        binary = Path(name).resolve()
        if not binary.is_relative_to(ROOT / 'rust/target') or not binary.is_file():
            raise ValueError('Invalid prebuilt Rust test executable: ' + name)
        subprocess.run([str(binary)], cwd=ROOT / 'rust', check=True)


def export_lab():
    destination = ROOT / 'artifacts/ci/prebuilt-lab'
    destination.mkdir(parents=True, exist_ok=True)
    library_dir = destination / 'swift/linux'
    library_dir.mkdir(parents=True, exist_ok=True)
    binary = ROOT / '.build/release/replicator-lab'
    shutil.copy2(binary, destination / binary.name)
    listing = subprocess.check_output(['ldd', str(binary)], text=True)
    for library in runtime_libraries(listing):
        shutil.copy2(library, library_dir / library.name)
    archive = destination.with_suffix('.tar.gz')
    with tarfile.open(archive, 'w:gz') as out:
        out.add(destination, arcname=destination.name)
    archive.with_suffix('.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
    inputs = subprocess.check_output([str(binary), 'build-inputs'], cwd=ROOT, text=True).strip()
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('inputs=' + inputs + '\n')


def load(directory):
    receipt = directory / 'image.json'
    if receipt.exists():
        load_receipt(json.loads(receipt.read_text()), os.environ['GITHUB_REPOSITORY'], 'test-build', os.environ['GITHUB_SHA'])
    else:
        subprocess.run(['sha256sum', '--check', 'SHA256SUMS'], cwd=directory, check=True)
        subprocess.run(['docker', 'load', '--input', str(directory / 'image.tar.gz')], check=True)
    # The archive fallback also carries the source identity in the image.
    commit = subprocess.check_output(['docker', 'inspect', TAGS['test-build'], '--format',
                                     '{{index .Config.Labels "org.opencontainers.image.revision"}}'], text=True).strip()
    if commit != os.environ['GITHUB_SHA']:
        raise ValueError('Shared test image does not match this checkout')


def check_runtime():
    value = json.loads((ROOT / 'artifacts/ci/image/build.json').read_text())
    if (value['image'] != 'coverage' or value['commit'] != os.environ['GITHUB_SHA']
            or value['run_id'] != os.environ['GITHUB_RUN_ID']):
        raise ValueError('Runtime build identity does not match this run')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['record-rust-tests', 'rust-test', 'export-lab', 'load', 'check-runtime'])
    parser.add_argument('--directory', type=Path, default=Path('artifacts/ci/test-build'))
    args = parser.parse_args()
    if args.action == 'load':
        load(args.directory)
    else:
        {'record-rust-tests': record_rust_tests, 'rust-test': rust_test, 'export-lab': export_lab, 'check-runtime': check_runtime}[args.action]()


if __name__ == '__main__':
    main()
