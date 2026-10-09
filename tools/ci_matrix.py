"""Plan CI from the lab's complete catalog; policy controls grouping, not inventory."""
from collections import Counter, defaultdict


def key(row):
    return (row['profile'], row.get('variant', 'default'), row['suite'], row['id'])


def generate(catalogs, policy):
    inventory = {}
    for catalog in catalogs:
        for item in catalog['scenarios']:
            row = dict(item, variant=item.get('variant', 'default'))
            identity = key(row)
            if identity in inventory and inventory[identity] != row:
                raise ValueError(f'conflicting catalog rows: {identity}')
            if row['status'] not in ('not_run', 'not_applicable'):
                raise ValueError(f'unexpected catalog status: {identity}')
            inventory[identity] = row
    applicable = {k: r for k, r in inventory.items() if r['status'] == 'not_run'}
    if not applicable:
        raise ValueError('empty lab catalog')
    families = [f for area in policy['areas'] for f in area['families']]
    if len(families) != len(set(families)):
        raise ValueError('a family belongs to multiple areas')
    unknown = {r['family'] for r in applicable.values() if r['suite'] == 'correctness'} - set(families)
    if unknown:
        raise ValueError(f'unassigned correctness families: {sorted(unknown)}')
    groups = defaultdict(list)
    for row in applicable.values():
        groups[key(row)[:3]].append(row)
    shards = []
    owners = Counter()

    def add(profile, variant, suite, area, cases, image='release', reports=0, tier='full', count=True):
        identifier = f'{image}-{profile}-{variant}-{area}'
        shards.append(dict(id=identifier, profile=profile, variant=variant, suite=suite,
                           area=area, image=image, reports=reports, tier=tier, cases=cases))
        if count:
            owners.update((profile, variant, suite, case) for case in cases)

    for (profile, variant, suite), rows in sorted(groups.items()):
        if suite == 'correctness':
            by_id = {r['id']: r for r in rows}
            # Validate dependencies even when a family is never split. Missing/NA
            # prerequisites must not be hidden by the lab's selection expansion.
            def closure(ids, visiting=()):
                result = set()
                for identifier in ids:
                    if identifier in visiting:
                        raise ValueError(f'cyclic dependency: {visiting + (identifier,)}')
                    if identifier not in by_id:
                        raise ValueError(f'missing applicable dependency: {identifier}')
                    result.add(identifier)
                    result.update(closure(by_id[identifier].get('dependencies', []), visiting + (identifier,)))
                return result

            closure(by_id)
            for area in policy['areas']:
                members = [r['id'] for r in rows if r['family'] in area['families']]
                if not members:
                    continue
                size = area.get('size', len(members))
                if size < 1:
                    raise ValueError('area size must be positive')
                for offset in range(0, len(members), size):
                    roots = members[offset:offset + size]
                    selected = closure(roots)
                    # Dependencies may be repeated, but each primary obligation
                    # must have exactly one owning shard.
                    cases = [r['id'] for r in rows if r['id'] in selected]
                    name = area['name'] + (f'-{offset // size + 1}' if len(members) > size else '')
                    add(profile, variant, suite, name, cases, count=False)
                    owners.update((profile, variant, suite, case) for case in roots)
        elif suite in ('lifecycle', 'recovery', 'native', 'demo'):
            reports = policy['demo_reports'][profile] if suite == 'demo' else 0
            area = {'native': 'native-ddl', 'lifecycle': 'reconnect'}.get(suite, suite)
            add(profile, variant, suite, area, [r['id'] for r in rows],
                image='coverage' if suite == 'demo' else 'release', reports=reports)
        else:
            raise ValueError(f'unassigned suite: {suite}')
    if set(owners) != set(applicable) or any(n != 1 for n in owners.values()):
        raise ValueError('CI ownership does not cover the complete applicable catalog exactly once')

    # Instrumentation supplements full release-binary assertions. Keep collection
    # boundaries stable so coverage aggregation can detect missing fixture reports.
    for profile, variant, suite in sorted(groups):
        if suite == 'correctness' and variant == 'default':
            add(profile, variant, suite, 'smoke', [], image='coverage', reports=1, tier='smoke', count=False)
    sample = policy['sample']
    for identifier in sample['cases']:
        if (sample['profile'], 'default', 'correctness', identifier) not in applicable:
            raise ValueError(f'sample case missing from applicable catalog: {identifier}')
    for image in ('release', 'coverage'):
        add(sample['profile'], 'default', 'correctness', 'sample', sample['cases'],
            image=image, reports=int(image == 'coverage'), count=False)
    # Start the longest stateful suites early to avoid a serial tail after the
    # shorter case chunks finish. GitHub may further limit runner concurrency.
    priority = {'failure-recovery-offline': 0, 'native-ddl': 1, 'demo': 2, 'reconnect': 3}
    shards.sort(key=lambda s: priority.get(s['area'], 4))
    if len({s['id'] for s in shards}) != len(shards):
        raise ValueError('duplicate shard identifiers')
    if len(shards) > 256:
        raise ValueError('CI matrix exceeds GitHub limit of 256 jobs')
    return dict(include=shards, coverage_reports=sum(s['reports'] for s in shards),
                obligations=len(applicable), inventory=list(inventory.values()))
