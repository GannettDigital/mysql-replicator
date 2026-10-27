#!/usr/bin/env python3
"""Select complete CI fixture groups for local planning and execution."""
import argparse
import copy
import json
import math
from pathlib import Path
import shlex
import subprocess
import sys

from ci_lab import ROOT, command, validated_plan


def local_command(group, prefix, *, coverage=True, skip_build=False):
    # Keep the CI renderer as the only source of runner arguments.
    selected = dict(group)
    if not coverage:
        selected['image'] = 'release'
    args = command(selected)
    if not skip_build:
        args.remove('--skip-build')
    return list(prefix) + args


def select_groups(plan, *, groups=None, profiles=None, variants=None, transports=None):
    """Filter whole groups. Never combine fixtures or remove dependency cases."""
    filters = [('area', groups), ('profile', profiles), ('variant', variants),
               ('dml_transport', transports)]
    def value(group, field):
        return group.get(field, 'sql' if field == 'dml_transport' else None)
    for field, values in filters:
        if not values or values == ['all']:
            continue
        if len(set(values)) != len(values):
            raise ValueError(f'duplicate {field} filters')
        unknown = set(values) - {value(g, field) for g in plan['include']}
        if unknown:
            raise ValueError(f'unknown {field}: {sorted(unknown)}')
    selected, excluded = [], []
    for group in plan['include']:
        reasons = [f'{field}={value(group, field)} excluded by filter'
                   for field, values in filters
                   if values and values != ['all'] and value(group, field) not in values]
        if reasons:
            excluded.append(dict(id=group['id'], reasons=reasons))
        else:
            selected.append(copy.deepcopy(group))
    if not selected:
        raise ValueError('no CI groups match this combination of filters')
    # Catch a requested name that silently disappeared after another filter.
    for field, values in filters:
        if values and values != ['all']:
            absent = set(values) - {value(g, field) for g in selected}
            if absent:
                raise ValueError(f'no selected groups for {field}: {sorted(absent)}')
    return dict(schema_version=1, source_scope=plan['scope'], groups=selected,
                excluded_groups=excluded,
                catalog_not_applicable=[r for r in plan['inventory'] if r['status'] == 'not_applicable'])


def add_commands(plan, prefix, *, coverage=True, skip_build=False,
                 max_native_ratio=None, report_only=None):
    if (max_native_ratio is not None or report_only is not None) and not any(
            g['suite'] == 'performance' for g in plan['groups']):
        raise ValueError('benchmark options require a performance group')
    if max_native_ratio is not None and (not math.isfinite(max_native_ratio) or max_native_ratio <= 0):
        raise ValueError('max-native-ratio must be finite and positive')
    for group in plan['groups']:
        if group['suite'] == 'performance':
            if max_native_ratio is not None:
                group['max_native_ratio'] = max_native_ratio
            if report_only is not None:
                group['report_only'] = report_only
        group['command'] = local_command(group, prefix, coverage=coverage, skip_build=skip_build)
    plan['execution'] = dict(coverage=coverage, skip_build=skip_build, parallel=False)
    return plan


def run_commands(commands):
    for args in commands:
        print('+ ' + shlex.join(args), file=sys.stderr, flush=True)
        result = subprocess.run(args, cwd=ROOT, stdout=sys.stderr)
        if result.returncode:
            raise SystemExit(result.returncode if result.returncode > 0 else 128 - result.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lab', type=Path, help='Built lab binary; default: swift run replicator-lab')
    parser.add_argument('--group', action='append', help='Exact CI area name; repeat to select several; default: all')
    parser.add_argument('--profile', action='append', help='Profile ID; repeat to select several; default: all')
    parser.add_argument('--variant', action='append', help='Capture variant; default: all variants in the CI plan')
    parser.add_argument('--dml-transport', action='append', choices=['sql', 'binlog', 'all'],
                        help='Filter existing groups; default: both transports in the CI plan')
    parser.add_argument('--no-coverage', action='store_true', help='Use normal binaries instead of CI coverage binaries')
    parser.add_argument('--skip-build', action='store_true', help='Require matching images already built locally')
    parser.add_argument('--max-native-ratio', type=float, help='Override the benchmark ratio limit')
    ratio = parser.add_mutually_exclusive_group()
    ratio.add_argument('--report-only', dest='report_only', action='store_true', default=None,
                       help='Report a benchmark ratio above the limit without failing for it')
    ratio.add_argument('--enforce-ratio', dest='report_only', action='store_false',
                       help='Fail if the benchmark ratio exceeds the limit')
    output = parser.add_mutually_exclusive_group()
    output.add_argument('--commands', action='store_true', help='Print commands instead of JSON')
    output.add_argument('--run', action='store_true', help='Run groups in sequence; stop at the first failure')
    args = parser.parse_args()
    prefix = [str(args.lab.resolve())] if args.lab else ['swift', 'run', 'replicator-lab']
    try:
        full = validated_plan(lambda *a: subprocess.check_output(prefix + list(a), cwd=ROOT, text=True), scope='full')
        selected = select_groups(full, groups=args.group, profiles=args.profile,
                                 variants=args.variant, transports=args.dml_transport)
        result = add_commands(selected, prefix, coverage=not args.no_coverage, skip_build=args.skip_build,
                              max_native_ratio=args.max_native_ratio, report_only=args.report_only)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Group selection failed: {error}\n')
    if args.commands:
        print('\n'.join(shlex.join(g['command']) for g in result['groups']))
    else:
        print(json.dumps(result, indent=2, sort_keys=True), flush=True)
    if args.run:
        run_commands([g['command'] for g in result['groups']])


if __name__ == '__main__':
    main()
