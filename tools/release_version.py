#!/usr/bin/env python3
"""Keep standalone Swift binaries and Debian metadata tied to VERSION."""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SWIFT = Path('Sources/ReplicatorConfiguration/ReleaseVersion.swift')


def versions(value):
    # Release tags deliberately exclude build metadata; every asset has one name.
    number = r'(?:0|[1-9][0-9]*)'
    identifier = r'(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)'
    if not re.fullmatch(rf'{number}\.{number}\.{number}(?:-{identifier}(?:\.{identifier})*)?', value):
        raise ValueError('VERSION must be SemVer without build metadata')
    return value, value.replace('-', '~', 1) + '-1'


def swift_source(value):
    semantic, debian = versions(value)
    return ('// Generated from VERSION by tools/release_version.py --write.\n'
            '// Committed so plain swift build embeds the version without runtime files.\n'
            'public enum ReleaseVersion {\n'
            f'    public static let current = "{semantic}"\n'
            f'    public static let debian = "{debian}"\n'
            '}\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    parser.add_argument('--debian', action='store_true')
    parser.add_argument('--tag')
    args = parser.parse_args()
    value = (ROOT / 'VERSION').read_text().strip()
    expected = swift_source(value)
    if args.write:
        (ROOT / SWIFT).write_text(expected)
    if (ROOT / SWIFT).read_text() != expected:
        parser.error('stale Swift version; run python3 tools/release_version.py --write')
    if args.tag and args.tag != 'v' + value:
        parser.error('tag does not match VERSION')
    print(versions(value)[1] if args.debian else value)


if __name__ == '__main__':
    main()
