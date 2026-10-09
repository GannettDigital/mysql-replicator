#!/usr/bin/env python3
"""Preserve SwiftPM mtimes across fresh checkouts and cache transport.

llbuild's device-agnostic filesystem still compares nanosecond mtimes. Restore
one only when the file's SHA-256, size and mode match the successful build.
Never rewrite the build database or timestamps outside the package/scratch tree.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat

MANIFEST = 'ci-mtimes.json'
INPUTS = ('Package.swift', 'Package.resolved', 'Sources', 'Vendor', 'tests')


def files(root, scratch):
    for base in [root / name for name in INPUTS] + [scratch]:
        if base.is_symlink():
            continue
        if base.is_file():
            yield base
        elif base.is_dir():
            for directory, dirs, names in os.walk(base, followlinks=False):
                dirs[:] = [d for d in dirs if d not in ('.git', 'repositories')
                           and not (Path(directory) / d).is_symlink()]
                for name in names:
                    path = Path(directory) / name
                    if path != scratch / MANIFEST and not path.is_symlink() and path.is_file():
                        yield path


def digest(path):
    with path.open('rb') as stream:
        result = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
        return result.hexdigest()


def save(root, scratch):
    records = {}
    for path in files(root, scratch):
        info = path.stat()
        records[str(path.relative_to(root))] = [
            info.st_mtime_ns, info.st_size, stat.S_IMODE(info.st_mode), digest(path)]
    scratch.mkdir(parents=True, exist_ok=True)
    (scratch / MANIFEST).write_text(json.dumps({'version': 1, 'files': records}) + '\n')
    print(f'Swift cache: saved timestamps for {len(records)} files')


def restore(root, scratch):
    manifest = scratch / MANIFEST
    if not manifest.is_file():
        print('Swift cache: no timestamp manifest; normal incremental/cold build')
        return
    data = json.loads(manifest.read_text())
    if data.get('version') != 1:
        raise ValueError('unsupported Swift timestamp manifest version')
    restored = changed = 0
    # Enumerate current allowed files instead of trusting paths in cached JSON.
    for path in files(root, scratch):
        record = data['files'].get(str(path.relative_to(root)))
        if record is None:
            continue
        mtime, size, mode, sha256 = record
        info = path.stat()
        if (info.st_size, stat.S_IMODE(info.st_mode), digest(path)) != (size, mode, sha256):
            changed += 1
            # Even a same-size edit with a preserved timestamp must invalidate.
            if info.st_mtime_ns == mtime:
                os.utime(path, ns=(info.st_atime_ns, mtime + 1_000_000_000))
            continue
        if info.st_mtime_ns != mtime:
            os.utime(path, ns=(info.st_atime_ns, mtime))
            restored += 1
    print(f'Swift cache: restored {restored} timestamps; {changed} changed files left invalidated')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['save', 'restore'])
    parser.add_argument('--scratch-path', required=True)
    args = parser.parse_args()
    root = Path.cwd().resolve()
    scratch = Path(args.scratch_path).resolve()
    if not scratch.is_relative_to(root) or scratch == root:
        parser.error('scratch path must be a directory inside the package')
    if args.action == 'save':
        save(root, scratch)
    else:
        restore(root, scratch)


if __name__ == '__main__':
    main()
