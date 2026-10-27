#!/usr/bin/env python3
"""Resolve lab cases before choosing CI jobs. Planning does not start containers."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SUITES = ('correctness', 'lifecycle', 'recovery', 'native', 'demo', 'performance')
SELECTABLE_SUITES = ('correctness', 'lifecycle', 'demo', 'performance')


def strings(values, name):
    if not isinstance(values, list) or any(not isinstance(v, str) or not v for v in values):
        raise ValueError(f'{name} must be a list of nonempty strings')
    if len(values) != len(set(values)):
        raise ValueError(f'duplicate {name}')
    return values


def resolve_cases(rows, cases=None, families=None):
    """Resolve one profile/variant/suite in catalog order. Never split a case."""
    if len({(r.get('profile'), r.get('variant', 'default'), r.get('suite')) for r in rows}) > 1:
        raise ValueError('resolve_cases requires one profile, variant and suite')
    by_id = {r['id']: r for r in rows}
    if len(by_id) != len(rows):
        raise ValueError('duplicate case IDs in selection catalog')
    if any(r['status'] not in ('not_run', 'not_applicable') for r in rows):
        raise ValueError('unexpected selection catalog status')
    requested = set(strings(cases if cases is not None else [], 'case IDs'))
    families = set(strings(families if families is not None else [], 'families'))
    if requested - by_id.keys():
        from lab_migrations import retired_hint
        raise ValueError(retired_hint(requested - by_id.keys())
                         or f'unknown case IDs: {sorted(requested - by_id.keys())}')
    available_families = {r.get('family') for r in rows}
    if families - available_families:
        raise ValueError(f'unknown families: {sorted(families - available_families)}')
    roots = [r for r in rows if (cases is None and not families)
             or r['id'] in requested or r.get('family') in families]
    excluded = [dict(id=r['id'], reason=r.get('reason', 'not applicable'))
                for r in roots if r['status'] == 'not_applicable']
    roots = [r['id'] for r in roots if r['status'] == 'not_run']
    selected, required_by = set(), defaultdict(set)

    def include(identifier, visiting=()):
        if identifier in visiting:
            raise ValueError(f'cyclic dependency: {visiting + (identifier,)}')
        row = by_id.get(identifier)
        if row is None or row['status'] != 'not_run':
            reason = row.get('reason', 'not applicable') if row else 'absent from catalog'
            raise ValueError(f'missing applicable dependency: {identifier}: {reason}')
        if identifier in selected:
            return
        for dependency in strings(row.get('dependencies', []), 'dependencies'):
            required_by[dependency].add(identifier)
            include(dependency, visiting + (identifier,))
        selected.add(identifier)

    for identifier in roots:
        include(identifier)
    ordered = [r['id'] for r in rows if r['id'] in selected]
    return dict(requested_cases=roots, cases=ordered,
                dependency_cases=[identifier for identifier in ordered if identifier not in roots],
                required_by={identifier: sorted(parents) for identifier, parents in required_by.items()},
                excluded=excluded)


def select_catalog(catalogs, *, profiles=None, variants=None, suites=None, cases=None, families=None):
    inventory = {}
    for catalog in catalogs:
        for item in catalog['scenarios']:
            row = dict(item, variant=item.get('variant', 'default'))
            key = (row['profile'], row['variant'], row['suite'], row['id'])
            if key in inventory and inventory[key] != row:
                raise ValueError(f'conflicting catalog rows: {key}')
            inventory[key] = row
    if not inventory:
        raise ValueError('empty lab catalog')
    rows = list(inventory.values())
    for field, values in [('profile', profiles), ('variant', variants), ('suite', suites)]:
        if values is not None:
            values = strings(values, field)
            unknown = set(values) - {r[field] for r in rows}
            if unknown:
                raise ValueError(f'unknown {field}: {sorted(unknown)}')
            rows = [r for r in rows if r[field] in values]
    for field, values in [('id', cases), ('family', families)]:
        if values is not None:
            unknown = set(strings(values, field)) - {r.get(field) for r in rows}
            if unknown:
                raise ValueError(f'unknown {field} in selected profiles/suites/variants: {sorted(unknown)}')
    scopes = defaultdict(list)
    for row in rows:
        scopes[(row['profile'], row['variant'], row['suite'])].append(row)
    groups, excluded = [], []
    for (profile, variant, suite), members in sorted(scopes.items()):
        # A filter that matches another scope must not select this entire scope.
        if (cases is not None or families) and not any(
                r['id'] in (cases or []) or r.get('family') in (families or []) for r in members):
            continue
        selection = resolve_cases(
            members, cases=None if cases is None else [c for c in cases if any(r['id'] == c for r in members)],
            families=None if families is None else [f for f in families if any(r.get('family') == f for r in members)])
        context = dict(profile=profile, variant=variant, suite=suite)
        excluded += [dict(context, **row) for row in selection.pop('excluded')]
        if not selection['cases']:
            continue
        if suite not in SELECTABLE_SUITES:
            applicable = {r['id'] for r in members if r['status'] == 'not_run'}
            if set(selection['cases']) != applicable:
                raise ValueError(f'{suite} runner requires its complete case group')
        groups.append(dict(context, **selection))
    return dict(schema_version=1, groups=groups, excluded=excluded,
                requested_cases=sum(len(g['requested_cases']) for g in groups),
                selected_cases=sum(len(g['cases']) for g in groups))


def command(group, *, skip_build=False, coverage=False):
    args = ['test', '--profile', group['profile'], '--suite', group['suite']]
    if skip_build:
        args.append('--skip-build')
    if coverage:
        args.append('--coverage')
    if group['suite'] in ('correctness', 'lifecycle'):
        args += ['--variant', group['variant']]
    if group['suite'] == 'correctness':
        args += ['--tier', 'full']
    if group['suite'] in SELECTABLE_SUITES:
        for case in group['cases']:
            args += ['--case', case]
    return args


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lab', type=Path, help='Built replicator-lab binary; default: swift run replicator-lab')
    parser.add_argument('--profile', action='append', help='Repeat for several profiles; default: all')
    parser.add_argument('--variant', action='append', help='Repeat for several variants; default: default; all selects all')
    parser.add_argument('--suite', action='append', choices=(*SUITES, 'all'), help='Default: correctness')
    parser.add_argument('--family', action='append', help='Select the union of these families and explicit cases')
    parser.add_argument('--case', dest='cases', action='append', help='Select a case and its required dependencies')
    parser.add_argument('--selection', choices=['pr'], help='Use the reviewed PR selection from ci_matrix.json')
    parser.add_argument('--commands', action='store_true', help='Print shell commands instead of the JSON plan')
    parser.add_argument('--skip-build', action='store_true', help='Add --skip-build to the generated commands')
    args = parser.parse_args()
    if args.selection and any([args.profile, args.variant, args.suite, args.family, args.cases]):
        parser.error('--selection cannot be combined with case or topology filters')
    prefix = [str(args.lab.resolve())] if args.lab else ['swift', 'run', 'replicator-lab']
    suites = list(SUITES) if args.suite and 'all' in args.suite else args.suite or ['correctness']
    profiles, variants, cases = args.profile, args.variant or ['default'], args.cases
    if args.selection == 'pr':
        from ci_matrix import SMOKE_PROFILES, generate_smoke
        profiles, variants = list(SMOKE_PROFILES), ['default']
        pr_selection = json.loads((ROOT / 'tools/ci_matrix.json').read_text())['pr_smoke']
        cases = pr_selection['cases']
    if profiles == ['all']:
        profiles = None
    if variants == ['all']:
        variants = None
    try:
        catalogs = []
        # The canonical "all" catalog omits MyISAM recovery aliases already
        # present in correctness. Do not recreate those aliases as extra work.
        query_suites = ['correctness', 'lifecycle', 'all'] if args.suite and 'all' in args.suite else suites
        for suite in query_suites:
            query = prefix + ['test', '--profile', 'all', '--suite', suite, '--list']
            if suite in ('correctness', 'lifecycle'):
                query += ['--variant', 'default' if args.selection == 'pr' else 'all']
            catalogs.append(json.loads(subprocess.check_output(query, cwd=ROOT, text=True)))
        if args.selection == 'pr':
            generate_smoke(catalogs, pr_selection)
        from lab_migrations import retired_hint, validate_migrations
        hint = retired_hint(cases or [])
        if hint:
            raise ValueError(hint)
        validate_migrations(catalogs, complete=args.suite is not None and 'all' in args.suite)
        plan = select_catalog(catalogs, profiles=profiles, variants=variants, suites=suites,
                              cases=cases, families=args.family)
        from lab_features import with_features
        plan = with_features(plan, catalogs, complete=args.suite is not None and 'all' in args.suite)
        if args.selection and (plan['excluded'] or not plan['groups']):
            raise ValueError('PR selection contains inapplicable cases or no cases')
        for group in plan['groups']:
            group['command'] = prefix + command(group, skip_build=args.skip_build, coverage=args.selection == 'pr')
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Lab selection failed: {error}\n')
    if args.commands:
        print('\n'.join(shlex.join(g['command']) for g in plan['groups']))
    else:
        print(json.dumps(plan, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
