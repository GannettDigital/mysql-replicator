"""Plan CI from the lab's complete catalog; policy controls grouping, not inventory."""
from collections import Counter, defaultdict

SMOKE_PROFILES = ('mysql84-to-mysql57-myisam', 'mysql57-to-mysql84-innodb')


def generate_smoke(catalogs, selection):
    """Resolve the explicit PR selection against the full lab catalog."""
    requested = selection['cases']
    if not isinstance(requested, list) or not requested or any(not isinstance(c, str) for c in requested):
        raise ValueError('PR cases must be a nonempty list of case IDs')
    if len(set(requested)) != len(requested):
        raise ValueError('duplicate PR case IDs')
    if not isinstance(selection.get('area'), str) or not selection['area'].strip():
        raise ValueError('PR selection requires a descriptive area')
    inventory, shards = [], []
    for profile in SMOKE_PROFILES:
        rows = [dict(r, variant=r.get('variant', 'default'))
                for catalog in catalogs for r in catalog['scenarios'] if r['profile'] == profile]
        if not rows or len({key(r) for r in rows}) != len(rows):
            raise ValueError(f'empty or duplicate smoke catalog: {profile}')
        if any(r['suite'] != 'correctness' or r['variant'] != 'default' or
               r['status'] not in ('not_run', 'not_applicable') for r in rows):
            raise ValueError(f'invalid smoke catalog: {profile}')
        applicable = {r['id']: r for r in rows if r['status'] == 'not_run'}
        if not set(requested) <= set(applicable):
            raise ValueError(f'missing or inapplicable PR cases: {profile}: {sorted(set(requested) - set(applicable))}')

        selected = set()
        def check_dependencies(identifier, visiting=()):
            if identifier in visiting or identifier not in applicable:
                raise ValueError(f'missing or cyclic smoke dependency: {identifier}')
            for dependency in applicable[identifier].get('dependencies', []):
                check_dependencies(dependency, visiting + (identifier,))
            selected.add(identifier)

        for identifier in requested:
            check_dependencies(identifier)
        inventory.extend(r for r in rows if r['id'] in selected)
        shards.append(dict(id=f'coverage-{profile}-default-smoke', profile=profile,
                           variant='default', suite='correctness', area=selection['area'], image='coverage',
                           reports=1, tier='full', cases=[r['id'] for r in rows if r['id'] in selected],
                           requested_cases=requested, owns_obligations=True))
    return dict(scope='pr-smoke', images=['coverage'], coverage_mode='selected', include=shards,
                coverage_reports=len(shards), obligations=sum(len(s['cases']) for s in shards),
                inventory=inventory)


def key(row):
    return (row['profile'], row.get('variant', 'default'), row['suite'], row['id'])


def case_groups(members, area):
    """Keep catalog order. Use reviewed time-based boundaries or fixed sizes."""
    if 'split_after' in area:
        anchors = area['split_after']
        if 'size' in area or not isinstance(anchors, list) or not anchors:
            raise ValueError('split_after requires a nonempty list and cannot use size')
        if any(not isinstance(anchor, str) or anchor not in members for anchor in anchors):
            raise ValueError(f"split_after case is not applicable in area {area['name']}")
        ends = [members.index(anchor) + 1 for anchor in anchors]
        if ends != sorted(set(ends)) or ends[-1] == len(members):
            raise ValueError('split_after boundaries must be ordered, unique, and leave a final group')
        return [members[start:end] for start, end in zip([0] + ends, ends + [len(members)])]
    size = area.get('size', len(members))
    if not isinstance(size, int) or isinstance(size, bool) or size < 1:
        raise ValueError('area size must be a positive integer')
    return [members[offset:offset + size] for offset in range(0, len(members), size)]


def generate(catalogs, policy, expanded_coverage=False):
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
                # This variant selects a few focused cases, not the full family.
                # Full-family timing boundaries need not exist in that subset.
                chunks = [members] if variant == 'without-source-gtids' else case_groups(members, area)
                for index, roots in enumerate(chunks, 1):
                    selected = closure(roots)
                    # Dependencies may be repeated, but each primary obligation
                    # must have exactly one owning shard.
                    cases = [r['id'] for r in rows if r['id'] in selected]
                    name = area['name'] + (f'-{index}' if len(chunks) > 1 else '')
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
    pr_shards = {}
    if 'pr_smoke' in policy:
        catalog = [r for r in inventory.values() if r['suite'] == 'correctness' and r['variant'] == 'default']
        pr_shards = {s['profile']: s for s in generate_smoke([dict(scenarios=catalog)], policy['pr_smoke'])['include']}
    for profile, variant, suite in sorted(groups):
        if suite == 'correctness' and variant == 'default':
            if profile in pr_shards:
                shards.append(dict(pr_shards[profile], owns_obligations=False))
            else:
                add(profile, variant, suite, 'smoke', [], image='coverage', reports=1, tier='smoke', count=False)
    sample = policy['sample']
    for identifier in sample['cases']:
        if (sample['profile'], 'default', 'correctness', identifier) not in applicable:
            raise ValueError(f'sample case missing from applicable catalog: {identifier}')
    for image in ('release', 'coverage'):
        add(sample['profile'], 'default', 'correctness', 'sample', sample['cases'],
            image=image, reports=int(image == 'coverage'), count=False)
    # Selected BINLOG runs use the same named cases. They supplement SQL
    # catalog obligations; a passing SQL case does not test the BINLOG executor.
    for selection in policy.get('binlog_selections', []):
        for profile in selection['profiles']:
            variant, suite = selection.get('variant', 'default'), selection['suite']
            rows = {r['id']: r for r in groups.get((profile, variant, suite), [])}
            requested = selection['cases']
            if not requested or len(set(requested)) != len(requested):
                raise ValueError('BINLOG selection must contain unique case IDs')
            selected = set()

            def include(identifier, visiting=()):
                if identifier not in rows or identifier in visiting:
                    raise ValueError(f'missing or cyclic BINLOG case: {profile}: {identifier}')
                for dependency in rows[identifier].get('dependencies', []):
                    include(dependency, visiting + (identifier,))
                selected.add(identifier)

            for identifier in requested:
                include(identifier)
            add(profile, variant, suite, 'binlog-' + selection['area'],
                [identifier for identifier in rows if identifier in selected], count=False)
            shards[-1].update(dml_transport='binlog', owns_obligations=False)
    # Keep release-binary obligations intact. These extra runs measure the same
    # shared scenarios with instrumentation; adapters have no coverage contract.
    if expanded_coverage:
        for shard in list(shards):
            if shard['image'] == 'release' and shard['suite'] in ('correctness', 'lifecycle') and shard['area'] != 'sample':
                measured = dict(shard, id=shard['id'].replace('release-', 'coverage-', 1),
                                image='coverage', reports=1)
                shards.append(measured)
    # Start the longest stateful suites early to avoid a serial tail after the
    # shorter case chunks finish. GitHub may further limit runner concurrency.
    priority = {'failure-recovery-offline': 0, 'native-ddl': 1, 'demo': 2, 'reconnect': 3}
    shards.sort(key=lambda s: priority.get(s['area'], 4))
    if len({s['id'] for s in shards}) != len(shards):
        raise ValueError('duplicate shard identifiers')
    if len(shards) > 256:
        raise ValueError('CI matrix exceeds GitHub limit of 256 jobs')
    return dict(scope='full', images=['release', 'coverage'], coverage_mode='expanded' if expanded_coverage else 'selected', include=shards, coverage_reports=sum(s['reports'] for s in shards),
                obligations=len(applicable), inventory=list(inventory.values()))
