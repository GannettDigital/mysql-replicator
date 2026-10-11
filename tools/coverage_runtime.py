#!/usr/bin/env python3
"""Extract the instrumented binary, its Swift libraries and matching LLVM tools."""
from pathlib import Path
import shutil
import subprocess


def main():
    destination = Path('/out/coverage-runtime')
    swift = Path(shutil.which('swift')).resolve()
    binaries = [Path('/usr/local/bin/mysql-replicator')]
    binaries += [swift.parent / name for name in ('llvm-profdata', 'llvm-cov')]
    libraries = set()
    for binary in binaries:
        target = destination / 'usr/local/bin' / binary.name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, target)
        listing = subprocess.check_output(['ldd', str(binary)], text=True)
        if 'not found' in listing:
            raise ValueError('unresolved runtime dependency: ' + listing)
        for line in listing.splitlines():
            if '=>' in line:
                path = Path(line.split('=>', 1)[1].strip().split()[0])
                if 'swift' in path.parts:
                    libraries.add(path)
    if not libraries:
        raise ValueError('no Swift runtime libraries found')
    for library in libraries:
        target = destination / library.relative_to('/')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(library, target)


if __name__ == '__main__':
    main()
