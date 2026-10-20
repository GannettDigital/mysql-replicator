#!/usr/bin/env python3
"""Compile the SQL syntax target before other first-party sources enter Docker."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
from build_dependencies import placeholders


def main():
    root = Path.cwd().resolve()
    package = json.loads(subprocess.check_output(['swift', 'package', 'dump-package'], text=True))
    names = {target['name'] for target in package['targets']}
    if 'MySQLSyntax' not in names or not (root / 'Sources/MySQLSyntax').is_dir():
        raise ValueError('MySQLSyntax source and target are required')
    package['targets'] = [target for target in package['targets'] if target['name'] != 'MySQLSyntax']
    paths = placeholders(root, package)
    try:
        subprocess.run(['python3', 'tools/swift_cache.py', 'restore', '--scratch-path', '.build'], check=True)
        subprocess.run(['swift', 'build', '--target', 'MySQLSyntax', *sys.argv[1:]], check=True)
        subprocess.run(['python3', 'tools/swift_cache.py', 'save', '--scratch-path', '.build'], check=True)
    finally:
        for path in paths:
            shutil.rmtree(path)


if __name__ == '__main__':
    main()
