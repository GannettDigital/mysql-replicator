"""Compare measured test areas without treating line overlap as redundant assertions."""
from collections import defaultdict
import csv
import hashlib
import json

from ci_matrix import SMOKE_PROFILES, key
from ci_measurements import line_sets


def repeated_cases(manifest):
    """List repeated declared cases. Different transports/images are separate checks."""
    occurrences = defaultdict(list)
    unlisted = []
    fields = ('profile', 'variant', 'suite', 'transport', 'image', 'case')
    for group in manifest['include']:
        cases = group.get('cases', [])
        if not cases:
            unlisted.append(group['id'])
        for case in cases:
            identity = (group['profile'], group.get('variant', 'default'), group['suite'],
                        group.get('dml_transport', 'sql'), group['image'], case)
            occurrences[identity].append(dict(group=group['id'], area=group['area'],
                dependency=case not in group.get('requested_cases', cases)))
    return dict(repeated=[dict(zip(fields, identity), executions=groups)
                         for identity, groups in sorted(occurrences.items()) if len(groups) > 1],
                unlisted_groups=sorted(unlisted))


def line_locations(lines):
    if lines is None:
        return None
    locations = defaultdict(list)
    for path, line in sorted(lines, key=lambda item: (item[0], int(item[1]))):
        locations[path].append(int(line))
    return dict(locations)


def analyze(manifest, records, unit=None):
    planned = {s['id']: s for s in manifest['include']}
    records = {r['id']: r for r in records}
    coverage_sources = {r['coverage']['sources_digest'] for r in records.values() if r.get('coverage')}
    if len(coverage_sources) > 1:
        raise ValueError('integration coverage sources differ')
    job_ids = {g: job['id'] for job in manifest.get('jobs', []) for g in job['group_ids']}
    expected = {key(r): r for r in manifest['inventory'] if r['status'] == 'not_run'}
    unit_hits = None
    if unit is not None:
        digest = hashlib.sha256(json.dumps(unit['sources'], sort_keys=True).encode()).hexdigest()
        if any(r.get('coverage', {}).get('sources_digest', digest) != digest for r in records.values()):
            raise ValueError('unit and integration coverage sources differ')
        _, unit_hits = line_sets([unit])
    # Older saved plans used the two fixed PR IDs. New plans name their actual
    # baseline groups, including the full-CI-only conditional DDL cases.
    baseline_ids = manifest.get('coverage_baseline_groups',
                                [f'coverage-{p}-default-smoke' for p in SMOKE_PROFILES])
    if (not isinstance(baseline_ids, list) or any(not isinstance(k, str) for k in baseline_ids)
            or len(set(baseline_ids)) != len(baseline_ids)
            or ('coverage_baseline_groups' in manifest and any(
                k not in planned or planned[k]['image'] != 'coverage' or planned[k]['reports'] != 1
                for k in baseline_ids))):
        raise ValueError('coverage baseline groups must be unique planned groups with one coverage collection')
    baseline_ready = bool(baseline_ids) and all(k in records and records[k]['status'] == 'passed' and
                         records[k].get('coverage', {}).get('collections') == 1 for k in baseline_ids)
    baseline = set().union(*(set(map(tuple, records[k]['coverage']['hit'])) for k in baseline_ids)) if baseline_ready else None
    groups = defaultdict(list)
    for shard in planned.values():
        area = shard.get('area', shard['suite'])
        if area.rsplit('-', 1)[-1].isdigit():
            area = area.rsplit('-', 1)[0]
        groups[(shard['profile'], shard['variant'], shard['suite'], area)].append(shard)
    hits, results = {}, []
    for group, shards in sorted(groups.items()):
        measured, mapped, passed = set(), set(), set()
        costs = defaultdict(float)
        collections = instrumented = 0
        for shard in shards:
            record = records.get(shard['id'], {})
            costs[shard['image']] += record.get('seconds', 0)
            if record.get('status') == 'passed':
                passed.update(key(r) for r in record.get('scenarios', []) if r['status'] == 'passed' and key(r) in expected)
            if 'coverage' in record:
                coverage = record['coverage']
                instrumented += 1
                collections += coverage['collections']
                measured.update(map(tuple, coverage['hit']))
                mapped.update(map(tuple, coverage['mapped']))
        hits[group] = measured
        results.append(dict(profile=group[0], variant=group[1], suite=group[2], area=group[3],
            jobs=len({job_ids.get(s['id'], s['id']) for s in shards}),
            instrumented_jobs=len({job_ids.get(s['id'], s['id']) for s in shards
                                   if 'coverage' in records.get(s['id'], {})}),
            execution_groups=len(shards), instrumented_groups=instrumented, collections=collections,
            complete=all(s['id'] in records and records[s['id']]['status'] == 'passed' and
                         records[s['id']].get('coverage', {}).get('collections', 0) == s['reports'] for s in shards),
            release_seconds=costs['release'], coverage_seconds=costs['coverage'],
            covered_lines=len(measured) if instrumented else None, mapped_lines=len(mapped) if instrumented else None,
            extra_over_baseline=len(measured - baseline) if instrumented and baseline is not None else None,
            extra_over_unit_baseline=len(measured - baseline - unit_hits) if instrumented and baseline is not None and unit_hits is not None else None,
            line_details=dict(
                extra_over_baseline=line_locations(measured - baseline) if instrumented and baseline is not None else None,
                extra_over_unit_baseline=line_locations(measured - baseline - unit_hits)
                    if instrumented and baseline is not None and unit_hits is not None else None),
            passed_catalog_keys=len(passed),
            obligations=[{k: expected[identity][k] for k in ('profile', 'variant', 'suite', 'id', 'family', 'intent', 'expected', 'dependencies')
                          if k in expected[identity]} for identity in sorted(passed)]))
    for group, row in zip(sorted(groups), results):
        others = set().union(*(value for other, value in hits.items() if other != group))
        exclusive = hits[group] - others if row['instrumented_jobs'] else None
        after_unit = exclusive - unit_hits if exclusive is not None and unit_hits is not None else None
        row['exclusive_integration_lines'] = len(exclusive) if exclusive is not None else None
        row['exclusive_after_unit_lines'] = len(after_unit) if after_unit is not None else None
        row['line_details'].update(exclusive_integration=line_locations(exclusive),
                                   exclusive_after_unit=line_locations(after_unit))
    provenance = {k: next(iter(records.values())).get(k) for k in ('commit', 'run_id', 'attempt')} if records else {}
    return dict(provenance=provenance, baseline_group_ids=baseline_ids,
                baseline_scope=manifest.get('scope', 'legacy PR selection'),
                baseline_selections=[{k: planned.get(identifier, {'id': identifier}).get(k) for k in
                                      ('id', 'profile', 'area', 'cases')} for identifier in baseline_ids], baseline_complete=baseline_ready,
                baseline_lines=len(baseline) if baseline is not None else None,
                unit_baseline_available=unit_hits is not None, areas=results, case_repetitions=repeated_cases(manifest))


def markdown(report):
    rows = report['areas']
    show = lambda v: 'unmeasured' if v is None else str(v)
    text = ['# Test area value', '',
        'Baseline: the measured groups named by this run\'s plan. Unit + baseline also includes this run\'s unit report.',
        f"Coverage baseline complete: {report['baseline_complete']}. Unit baseline available: {report['unit_baseline_available']}.", '',
        'Each row groups one profile, capture variant, suite and area. Numbered chunks share a row. '
        'Times are summed execution-group minutes, not elapsed workflow time. Partial rows can miss results.', '',
        '| Profile / variant / suite / area | Complete | Passed catalog keys | Groups with coverage / total | Minutes release / coverage | Lines hit | Extra over baseline | Extra over unit + baseline | Exclusive integration lines | Exclusive after unit |',
        '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|']
    for r in sorted(rows, key=lambda r: -(r['release_seconds'] + r['coverage_seconds'])):
        label = ' / '.join(r[k] for k in ('profile', 'variant', 'suite', 'area'))
        text.append(f"| {label} | {r['complete']} | {r['passed_catalog_keys']} | {r['instrumented_groups']} / {r['execution_groups']} | "
                    f"{r['release_seconds']/60:.1f} / {r['coverage_seconds']/60:.1f} | {show(r['covered_lines'])} | "
                    f"{show(r['extra_over_baseline'])} | {show(r['extra_over_unit_baseline'])} | {show(r['exclusive_integration_lines'])} | {show(r.get('exclusive_after_unit_lines'))} |")
    text += ['', '## Baseline selections', '',
             'Scope: `' + report.get('baseline_scope', 'unavailable') + '`. '
             'Full CI can add cases to its baseline without changing PR checks. '
             'Line gains refer to the groups listed here, not an assumed PR selection.']
    for selection in report.get('baseline_selections', []):
        cases = selection.get('cases')
        description = ', '.join('`' + case + '`' for case in cases) if cases else 'case list unavailable'
        text += ['', '- `' + selection['id'] + '`: ' + description + '.']
    text += ['', 'Line gains are set differences and are not additive. Exclusive lines are relative to other measured areas. '
             'Zero extra lines does not prove redundant assertions. Unmeasured is not zero. '
             'Passed catalog keys can overlap between rows; do not sum them as catalog coverage. '
             'Fixture setup and cleanup contribute coverage and time. Crash paths may not flush counters. '
             'Rust, dependencies and harness code are excluded. The JSON includes case IDs and declared test intent; '
             'review the assertions before removing a case.']
    text += ['', '## Lines to review', '',
             'Use the source revision in `provenance.commit`: `'
             + str(report.get('provenance', {}).get('commit') or 'unavailable') + '`. '
             'The JSON `line_details` maps files to exact line numbers for each difference. '
             'Missing measurements are null, not empty maps. '
             'The lists below show areas with 1–25 lines not reached by other measured areas'
             + (' or unit tests.' if report['unit_baseline_available'] else '. Unit coverage is unavailable.'), '',
             'Inspect the code and the branch condition. Add a focused unit test where practical, '
             'or add the required operation and assertion to an existing integration case. '
             'Measure that replacement against the same source revision. '
             'Do not remove profile, failure or restart checks because their lines overlap.']
    count_key = 'exclusive_after_unit_lines' if report['unit_baseline_available'] else 'exclusive_integration_lines'
    detail_key = 'exclusive_after_unit' if report['unit_baseline_available'] else 'exclusive_integration'
    for row in sorted(rows, key=lambda r: -(r['release_seconds'] + r['coverage_seconds'])):
        count = row.get(count_key)
        if count is None or not 1 <= count <= 25:
            continue
        details = row.get('line_details', {}).get(detail_key)
        if details is None:
            continue
        label = ' / '.join(row[k] for k in ('profile', 'variant', 'suite', 'area'))
        locations = ', '.join(f'`{path}:{line}`' for path, lines in details.items() for line in lines)
        text += ['', f'- {label}: {count} lines; '
                 f"{(row['release_seconds'] + row['coverage_seconds'])/60:.1f} runner-minutes. {locations}"]
    repetitions = report.get('case_repetitions')
    if repetitions is not None:
        text += ['', '## Repeated declared cases', '',
                 'Match profile, variant, suite, transport, image type and case ID. '
                 'These are review candidates, not proof of redundant assertions. '
                 'Fixture state and restart boundaries can differ.', '',
                 '| Profile / variant / suite / transport / image / case | Execution groups |', '|---|---|']
        for row in repetitions['repeated']:
            text.append('| ' + ' / '.join(row[k] for k in ('profile', 'variant', 'suite', 'transport', 'image', 'case'))
                        + ' | ' + ', '.join(e['group'] for e in row['executions']) + ' |')
        if repetitions['unlisted_groups']:
            text += ['', 'Groups without explicit case lists are excluded from this count: '
                     + ', '.join(repetitions['unlisted_groups']) + '. Read their actual results before a removal decision.']
    return '\n'.join(text) + '\n'


def write(output, report):
    (output / 'test-value.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    (output / 'test-value.md').write_text(markdown(report))
    if report['areas']:
        with (output / 'test-value.csv').open('w', newline='') as stream:
            fields = [k for k in report['areas'][0] if k not in ('obligations', 'line_details')]
            writer = csv.DictWriter(stream, fieldnames=fields)
            writer.writeheader()
            writer.writerows({k: r[k] for k in fields} for r in report['areas'])
