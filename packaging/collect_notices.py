#!/usr/bin/env python3
"""Collect original dependency notices from the locked build's source trees."""
import json
from pathlib import Path
import shutil
import subprocess

out = Path('/out/third-party')
out.mkdir(parents=True, exist_ok=True)
records = []


def collect(name, root, provenance):
    root = Path(root)
    names = ('LICENSE', 'LICENCE', 'NOTICE', 'COPYING', 'COPYRIGHT', 'AUTHORS')
    files = sorted(p for p in root.rglob('*') if p.is_file()
                   and p.name.upper().split('.')[0].split('-')[0] in names
                   and '.git' not in p.parts and 'target' not in p.parts)
    if not files:
        raise SystemExit('No license/notice files found for ' + name)
    for path in files:
        dest = out / name / path.relative_to(root)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, dest)
    records.append(dict(component=name, source=provenance, files=[str(p.relative_to(root)) for p in files]))


pins = json.loads(Path('Package.resolved').read_text())['pins']
for pin in pins:
    candidates = [p for p in Path('.build/checkouts').iterdir() if p.name.lower() == pin['identity'].lower()]
    if len(candidates) != 1:
        raise SystemExit('Missing locked Swift checkout: ' + pin['identity'])
    collect('swift/' + pin['identity'], candidates[0], dict(url=pin['location'], **pin['state']))
collect('swift/mysql-nio', 'Vendor/mysql-nio', 'vendored in release source')
metadata = json.loads(subprocess.check_output(['cargo', 'metadata', '--manifest-path', 'rust/Cargo.toml',
                                               '--locked', '--filter-platform', 'x86_64-unknown-linux-musl', '--format-version', '1']))
for package in metadata['packages']:
    if package['name'] != 'replicator-codec':
        collect('rust/' + package['name'] + '-' + package['version'],
                Path(package['manifest_path']).parent,
                dict(source=package['source'], license=package['license']))
collect('runtime/swift', '/usr/share/swift', 'Swift 6.2.1 toolchain')
rust_docs = Path(subprocess.check_output(['rustc', '--print', 'sysroot'], text=True).strip()) / 'share/doc/rust'
collect('runtime/rust', rust_docs, 'Rust 1.93.1 toolchain, including library notices')
collect('runtime/musl', 'packaging/licenses/musl', 'musl 1.2.5, Swift static Linux SDK')
shutil.copyfile('/out/evidence/sdk-sbom.spdx.json', out / 'sdk-sbom.spdx.json')
(out / 'manifest.json').write_text(json.dumps(records, indent=2) + '\n')
