#!/usr/bin/env python3
"""Run the syntax target alone. No Rust, MySQL client, Docker or server is needed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from code_coverage import export

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "MySQLSyntaxUnitTests", targets: [
    .target(name: "MySQLSyntax"),
    .testTarget(name: "MySQLSyntaxTests", dependencies: ["MySQLSyntax"])
], swiftLanguageModes: [.v5])
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--coverage', action='store_true')
    parser.add_argument('--minimum-line-coverage', type=float, default=95.0)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--build-only', action='store_true')
    mode.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    if not 0 <= args.minimum_line_coverage <= 100:
        parser.error('--minimum-line-coverage must be between 0 and 100')
    package = ROOT / 'artifacts/syntax-unit'
    package.mkdir(parents=True, exist_ok=True)
    (package / 'Package.swift').write_text(MANIFEST)
    for relative, source in [('Sources/MySQLSyntax', 'Sources/MySQLSyntax'),
                             ('Tests/MySQLSyntaxTests', 'tests/MySQLSyntaxTests')]:
        link = package / relative
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.is_symlink():
            if link.resolve() != ROOT / source:
                raise ValueError('unexpected syntax test link: ' + str(link))
        elif link.exists():
            raise ValueError('syntax test source path is not a link: ' + str(link))
        else:
            link.symlink_to(ROOT / source, target_is_directory=True)
    command = ['swift', 'test', '--package-path', str(package)]
    def input_hashes():
        return {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                for directory in ('Sources/MySQLSyntax', 'tests/MySQLSyntaxTests')
                for path in (ROOT / directory).glob('*.swift')}
    before = input_hashes()
    report = ROOT / 'artifacts/coverage/syntax-unit'
    if args.coverage:
        command.append('--enable-code-coverage')
        for raw in (package / '.build').rglob('*.profraw'):
            raw.unlink()
        if report.exists():
            shutil.rmtree(report)
    if args.build_only:
        subprocess.run(['swift', 'build', '--build-tests', *command[2:]], check=True)
        return
    if args.skip_build:
        command.append('--skip-build')
    subprocess.run(command, check=True)
    if input_hashes() != before:
        raise ValueError('syntax sources or tests changed during the run; rerun against stable inputs')
    if args.coverage:
        coverage_path = Path(subprocess.check_output(command + ['--show-codecov-path'], text=True).strip())
        build = coverage_path.parent.parent
        binaries = [build / 'MySQLSyntaxUnitTestsPackageTests.xctest']
        if os.uname().sysname == 'Darwin':
            binaries = [binaries[0] / 'Contents/MacOS/MySQLSyntaxUnitTestsPackageTests']
        export(ROOT, report, 'mysql-syntax-unit-only', binaries, [coverage_path.parent])
        data = json.loads((report / 'coverage.json').read_text())
        if not data['files'] or any(not path.startswith('Sources/MySQLSyntax/') for path in data['files']):
            raise ValueError('syntax-only coverage includes unexpected source files')
        counts = [count for lines in data['files'].values() for count in lines.values()]
        percentage = 100 * sum(count > 0 for count in counts) / len(counts)
        if percentage < args.minimum_line_coverage:
            raise ValueError(f'syntax line coverage {percentage:.2f}% is below {args.minimum_line_coverage:.2f}%')


if __name__ == '__main__':
    main()
