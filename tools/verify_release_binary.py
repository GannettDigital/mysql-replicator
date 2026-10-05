#!/usr/bin/env python3
"""Require the integration image to contain the exact release archive binary."""
import hashlib
from pathlib import Path
import subprocess
import tarfile

from release_version import ROOT, versions

version, _ = versions((ROOT / 'VERSION').read_text().strip())
name = f'mysql-replicator-{version}-linux-x86_64'
with tarfile.open(ROOT / 'artifacts/release' / (name + '.tar.gz')) as archive:
    binary = archive.extractfile(name + '/mysql-replicator')
    digest = hashlib.sha256()
    for chunk in iter(lambda: binary.read(1024 * 1024), b''):
        digest.update(chunk)
actual = subprocess.check_output(['docker', 'run', '--rm', '--platform', 'linux/amd64',
                                 '--entrypoint', 'sha256sum', 'mysql-replicator-packaging:dml',
                                 '/usr/local/bin/mysql-replicator'], text=True).split()[0]
if actual != digest.hexdigest():
    raise SystemExit('Integration executable differs from release archive; do not publish.')
print('Integration and release binaries match: ' + actual)
