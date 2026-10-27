"""Plan CI from the lab's complete catalog; policy controls grouping, not inventory."""
from collections import Counter, defaultdict

from lab_selection import resolve_cases

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

        resolved = resolve_cases(rows, cases=requested)
        selected = set(resolved['cases'])
        inventory.extend(r for r in rows if r['id'] in selected)
        shards.append(dict(id=f'coverage-{profile}-default-smoke', profile=profile,
                           variant='default', suite='correctness', area=selection['area'], image='coverage',
                           reports=1, tier='full', cases=[r['id'] for r in rows if r['id'] in selected],
                           requested_cases=requested, dependency_cases=resolved['dependency_cases'], owns_obligations=True))
    return dict(scope='pr-smoke', images=['coverage'], coverage_mode='selected', include=shards,
                coverage_baseline_groups=[s['id'] for s in shards],
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


def named_case_groups(members, area):
    """Reviewed behavior groups. Preserve catalog order, including dependencies."""
    selections = area['groups']
    if 'size' in area or 'split_after' in area or not isinstance(selections, list) or not selections:
        raise ValueError('named groups cannot use size/split_after and must be nonempty')
    names, assigned, result = set(), set(), []
    for selection in selections:
        if not isinstance(selection, dict):
            raise ValueError('invalid named case group')
        name, cases = selection.get('name'), selection.get('cases')
        if (not isinstance(name, str) or not name or name in names
                or not isinstance(cases, list) or not cases
                or any(not isinstance(c, str) or not c for c in cases)):
            raise ValueError('invalid named case group')
        if len(set(cases)) != len(cases) or assigned.intersection(cases):
            raise ValueError('case assigned to multiple named groups')
        names.add(name)
        assigned.update(cases)
        selected = [c for c in members if c in cases]
        if selected:
            result.append((area['name'] + '-' + name, selected))
    missing = set(members) - assigned
    if missing:
        raise ValueError(f'unassigned cases in {area["name"]}: {sorted(missing)}')
    return result


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
    # Explicit feature selections cross legacy family boundaries. Remaining
    # cases keep their family owner. Every case still has exactly one owner.
    areas = policy['areas']
    if len({area['name'] for area in areas}) != len(areas):
        raise ValueError('duplicate area name')
    explicit = {}
    known_cases = {r['id'] for r in inventory.values() if r['suite'] == 'correctness'}
    for area in areas:
        if 'cases' not in area:
            continue
        cases = area['cases']
        if any(k in area for k in ('families', 'groups', 'size', 'split_after')):
            raise ValueError('explicit case area cannot use family or split selectors')
        if (not isinstance(cases, list) or not cases
                or any(not isinstance(c, str) or not c for c in cases)
                or len(cases) != len(set(cases))):
            raise ValueError('invalid explicit area cases')
        if set(cases) - known_cases:
            raise ValueError(f'unknown explicit cases: {sorted(set(cases) - known_cases)}')
        for case in cases:
            if case in explicit:
                raise ValueError('case belongs to multiple explicit areas: ' + case)
            explicit[case] = area['name']

    def belongs(row, area):
        if row['id'] in explicit:
            return explicit[row['id']] == area['name']
        return row['family'] in area.get('families', [])

    families = [f for area in areas for f in area.get('families', [])]
    if len(families) != len(set(families)):
        raise ValueError('a family belongs to multiple areas')
    unknown = {r['family'] for r in applicable.values() if r['suite'] == 'correctness' and r['id'] not in explicit} - set(families)
    if unknown:
        raise ValueError(f'unassigned correctness families: {sorted(unknown)}')
    demo_area = dict(name='demo', groups=policy.get('demo_groups', []))
    demo_known = {r['id'] for r in inventory.values() if r['suite'] == 'demo'}
    if demo_known:
        named_case_groups(sorted(demo_known), demo_area)
        requested = {c for group in demo_area['groups'] for c in group['cases']}
        if requested - demo_known:
            raise ValueError(f'unknown demo cases: {sorted(requested - demo_known)}')
    for area in policy['areas']:
        if 'groups' in area:
            known = {r['id'] for r in inventory.values()
                     if r['suite'] == 'correctness' and belongs(r, area)}
            named_case_groups(sorted(known), area)
            requested = {c for group in area['groups'] for c in group['cases']}
            if requested - known:
                raise ValueError(f'unknown cases in {area["name"]}: {sorted(requested - known)}')
    groups = defaultdict(list)
    for row in applicable.values():
        groups[key(row)[:3]].append(row)
    shards = []
    owners = Counter()

    def add(profile, variant, suite, area, cases, image='coverage', reports=1, tier='full', count=True):
        identifier = f'{image}-{profile}-{variant}-{area}'
        shards.append(dict(id=identifier, profile=profile, variant=variant, suite=suite,
                           area=area, image=image, reports=reports, tier=tier, cases=cases,
                           owns_obligations=count))
        if count:
            owners.update((profile, variant, suite, case) for case in cases)

    for (profile, variant, suite), rows in sorted(groups.items()):
        if suite == 'correctness':
            # Validate dependencies even when a family is never split. Missing/NA
            # prerequisites must not be hidden by the lab's selection expansion.
            resolve_cases(rows)
            for area in policy['areas']:
                members = [r['id'] for r in rows if belongs(r, area)]
                if not members:
                    continue
                # This variant selects a few focused cases, not the full family.
                # Full-family timing boundaries need not exist in that subset.
                if 'groups' in area:
                    named = named_case_groups(members, area)
                else:
                    chunks = [members] if variant == 'without-source-gtids' else case_groups(members, area)
                    named = [(area['name'] + (f'-{i}' if len(chunks) > 1 else ''), roots)
                             for i, roots in enumerate(chunks, 1)]
                for name, roots in named:
                    resolved = resolve_cases(rows, cases=roots)
                    selected = set(resolved['cases'])
                    # Dependencies may be repeated, but each primary obligation
                    # must have exactly one owning shard.
                    cases = [r['id'] for r in rows if r['id'] in selected]
                    add(profile, variant, suite, name, cases, count=False)
                    shards[-1].update(owns_obligations=True, requested_cases=roots, dependency_cases=resolved['dependency_cases'])
                    owners.update((profile, variant, suite, case) for case in roots)
        elif suite == 'demo':
            # Each demo session creates its own clean fixture. Keep all assertions
            # for a session together, but never start another session in its job.
            for area, cases in named_case_groups([r['id'] for r in rows], demo_area):
                resolved = resolve_cases(rows, cases=cases)
                if set(resolved['cases']) != set(cases):
                    raise ValueError('demo dependencies cross fixture groups: ' + area)
                add(profile, variant, suite, area, cases)
        elif suite in ('lifecycle', 'recovery', 'native'):
            reports = 0 if suite == 'native' else 1
            area = {'native': 'native-source-restrictions', 'lifecycle': 'connection-restarts-uncertain-writes',
                    'recovery': 'innodb-rollback-recovery'}[suite]
            add(profile, variant, suite, area, [r['id'] for r in rows],
                reports=reports)
        else:
            raise ValueError(f'unassigned suite: {suite}')
    if set(owners) != set(applicable) or any(n != 1 for n in owners.values()):
        raise ValueError('CI ownership does not cover the complete applicable catalog exactly once')

    # Selected BINLOG runs use the same named cases. They supplement SQL
    # catalog obligations; a passing SQL case does not test the BINLOG executor.
    for selection in policy.get('binlog_selections', []):
        for profile in selection['profiles']:
            variant, suite = selection.get('variant', 'default'), selection['suite']
            rows = {r['id']: r for r in groups.get((profile, variant, suite), [])}
            requested = selection['cases']
            if not requested or len(set(requested)) != len(requested):
                raise ValueError('BINLOG selection must contain unique case IDs')
            resolved = resolve_cases(list(rows.values()), cases=requested)
            if resolved['excluded']:
                raise ValueError(f'inapplicable BINLOG cases: {resolved["excluded"]}')
            selected = set(resolved['cases'])
            add(profile, variant, suite, 'binlog-' + selection['area'],
                [identifier for identifier in rows if identifier in selected], count=False)
            shards[-1].update(dml_transport='binlog', owns_obligations=False, requested_cases=requested,
                              dependency_cases=resolved['dependency_cases'])
    # expanded_coverage is retained for old callers. Every apply test now uses
    # instrumentation once. Native-only observations do not run our binary.
    # Start the longest stateful suites early to avoid a serial tail after the
    # shorter case chunks finish. GitHub may further limit runner concurrency.
    priority = {'write-failures-recovery-replay-control': 0, 'native-source-restrictions': 1,
                'demo': 2, 'connection-restarts-uncertain-writes': 3}
    shards.sort(key=lambda s: priority.get(s['area'], 4))
    if len({s['id'] for s in shards}) != len(shards):
        raise ValueError('duplicate shard identifiers')
    return dict(scope='full', images=['coverage'], coverage_mode='all', include=shards, coverage_reports=sum(s['reports'] for s in shards),
                coverage_baseline_groups=[],
                obligations=len(applicable), inventory=list(inventory.values()))


def generate_production(catalogs):
    """Check the shipped binary's SQL, decoder, checkpoint and replay resume."""
    result = generate_smoke(catalogs, dict(area='package-apply-replay-resume',
                                         cases=['positive', 'offline-replay']))
    for group in result['include']:
        group.update(id=f"release-{group['profile']}-default-package-apply-replay-resume", image='release', reports=0)
    return dict(result, scope='production', images=['release'], coverage_mode='none',
                coverage_baseline_groups=[], coverage_reports=0)
