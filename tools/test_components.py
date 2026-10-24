"""Select complete CI execution groups from explicit component rules."""
import json
from pathlib import Path

POLICY = Path(__file__).with_name('test_components.json')


def rules():
    policy = json.loads(POLICY.read_text())
    paths = set()
    if not isinstance(policy, dict) or not policy:
        raise ValueError('component rules must be a nonempty object')
    for name, rule in policy.items():
        if not name or not rule.get('reason'):
            raise ValueError('component needs a name and reason')
        if set(rule) - {'paths', 'reason', 'families', 'cases', 'suites'}:
            raise ValueError('unknown component rule field: ' + name)
        for field in ('paths', 'families', 'cases', 'suites'):
            values = rule.get(field, [])
            if not isinstance(values, list) or any(not isinstance(v, str) or not v for v in values):
                raise ValueError('invalid component ' + field)
            if len(values) != len(set(values)):
                raise ValueError('duplicate component ' + field)
        if not rule.get('paths') or not any(rule.get(f) for f in ('families', 'cases', 'suites')):
            raise ValueError('component needs paths and catalog selectors: ' + name)
        for path in rule['paths']:
            if path.startswith('/') or '..' in path.split('/') or '\\' in path or '*' in path or path in paths:
                raise ValueError('invalid or repeated component path: ' + path)
            paths.add(path)
    return policy


def component_for(path):
    return next(((name, rule['reason']) for name, rule in rules().items() if path in rule['paths']), None)


def select_groups(full, change_plan, baseline):
    """Retain whole reviewed groups, all variants/profiles and both transports.

    The full planner has already resolved dependencies. Do not slice its groups:
    an adapter may need its complete fixture, and coverage counts are per fixture.
    """
    from ci_matrix import generate_smoke, key
    from test_selection import select_changes
    # Recompute the policy from saved paths. Do not trust a stale or edited list
    # of component names passed between the selector and the bundler.
    computed = select_changes([c['path'] for c in change_plan['changes']])
    if change_plan['scope'] != 'pr-selected' or computed['scope'] != 'pr-selected':
        raise ValueError('component selection requires a complete component-only change plan')
    policy = rules()
    names = sorted({c['component'] for c in computed['changes'] if 'component' in c})
    inventory = full['inventory']
    matches, explanations = {}, []
    for name in names:
        rule = policy[name]
        for field, column in [('families', 'family'), ('cases', 'id'), ('suites', 'suite')]:
            unknown = set(rule.get(field, [])) - {r.get(column) for r in inventory}
            if unknown:
                raise ValueError(f'component {name}: unknown {field}: {sorted(unknown)}')
        rows = [r for r in inventory if r.get('family') in rule.get('families', [])
                or r['id'] in rule.get('cases', []) or r['suite'] in rule.get('suites', [])]
        applicable = {key(r) for r in rows if r['status'] == 'not_run'}
        if not applicable:
            raise ValueError('component has no applicable cases: ' + name)
        matches[name] = applicable
        explanations.append(dict(component=name, reason=rule['reason'],
                                 paths=[c['path'] for c in computed['changes'] if c.get('component') == name],
                                 profiles=sorted({r['profile'] for r in rows if r['status'] == 'not_run'}),
                                 selected=[dict(profile=r['profile'], variant=r['variant'], suite=r['suite'],
                                                case=r['id'], status=r['status'], reason=r.get('reason')) for r in rows]))
    # Keep the two reviewed PR checks as a baseline, including line coverage.
    base = generate_smoke([dict(scenarios=[r for r in inventory
                          if r['suite'] == 'correctness' and r['variant'] == 'default'])], baseline)
    groups = {g['id']: dict(g, selected_by=['PR baseline']) for g in base['include']}
    baseline_cases = {g['profile']: set(g['cases']) for g in base['include']}
    for group in full['include']:
        matching_cases = set(group['cases'])
        if group['id'] in full.get('coverage_baseline_groups', []) and group['id'] not in groups:
            # A full-CI extension supplements the PR baseline already selected.
            # Match only its extra cases; shared baseline cases must not pull
            # this second fixture into unrelated component checks.
            matching_cases -= baseline_cases.get(group['profile'], set())
        identities = {(group['profile'], group['variant'], group['suite'], c) for c in matching_cases}
        causes = [name for name, selected in matches.items() if identities & selected]
        if causes:
            if group['id'] in groups:
                groups[group['id']]['selected_by'] += causes
            else:
                groups[group['id']] = dict(group, selected_by=causes, owns_obligations=True)
    selected_keys = {(g['profile'], g['variant'], g['suite'], c) for g in groups.values() for c in g['cases']}
    if not set.union(*matches.values()) <= selected_keys:
        raise ValueError('component cases are missing from the selected execution groups')
    rows = [r for r in inventory if key(r) in selected_keys and r['status'] == 'not_run']
    groups = list(groups.values())
    return dict(scope='pr-selected', images=sorted({g['image'] for g in groups}), coverage_mode='selected',
                include=groups, inventory=rows, obligations=len(rows),
                coverage_baseline_groups=base['coverage_baseline_groups'],
                coverage_reports=sum(g['reports'] for g in groups), components=explanations,
                selection=computed)
