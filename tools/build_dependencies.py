#!/usr/bin/env python3
"""Compile Swift dependencies before application sources enter a Docker layer."""
import json
from pathlib import Path
import shutil
import subprocess
import sys


def placeholders(root, package):
    paths = []
    for target in package['targets']:
        path = root / target.get('path', 'Sources/' + target['name'])
        if not path.is_relative_to(root) or path.exists():
            raise ValueError(f'dependency build requires an empty source path: {path}')
        paths.append((path, target))
    for path, target in paths:
        path.mkdir(parents=True)
        if target['type'] == 'system':
            (path / 'empty.h').touch()
            (path / 'module.modulemap').write_text(f'module {target["name"]} {{ header "empty.h" export * }}\n')
        else:
            (path / 'Placeholder.swift').write_text('// Dependency-layer placeholder. Never shipped.\n')
        for resource in target.get('resources', []):
            (path / resource['path']).mkdir(parents=True, exist_ok=True)
    return [path for path, _ in paths]


def main():
    root = Path.cwd().resolve()
    package = json.loads(subprocess.check_output(['swift', 'package', 'dump-package'], text=True))
    paths = placeholders(root, package)
    try:
        for target in ('MySQLNIO', 'Crypto', 'Yams'):
            subprocess.run(['swift', 'build', '--target', target, *sys.argv[1:]], check=True)
        subprocess.run(['python3', 'tools/swift_cache.py', 'save', '--scratch-path', '.build'], check=True)
    finally:
        for path in paths:
            shutil.rmtree(path)


if __name__ == '__main__':
    main()
