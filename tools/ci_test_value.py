"""Compare measured test areas without treating line overlap as redundant assertions."""
from collections import defaultdict
import csv
import hashlib
import json

from ci_matrix import SMOKE_PROFILES, key
from ci_measurements import line_sets


def analyze(manifest, records, unit=None):
    planned = {s['id']: s for s in manifest['include']}
    records = {r['id']: r for r in records}
    job_ids = {g: job['id'] for job in manifest.get('jobs', []) for g in job['group_ids']}
    expected = {key(r): r for r in manifest['inventory'] if r['status'] == 'not_run'}
    unit_hits = None
    if unit is not None:
        digest = hashlib.sha256(json.dumps(unit['sources'], sort_keys=True).encode()).hexdigest()
        if any(r.get('coverage', {}).get('sources_digest', digest) != digest for r in records.values()):
            raise ValueError('unit and integration coverage sources differ')
        _, unit_hits = line_sets([unit])
    baseline_ids = [f'coverage-{p}-default-smoke' for p in SMOKE_PROFILES]
    baseline_ready = all(k in records and records[k]['status'] == 'passed' and
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
            extra_over_smoke=len(measured - baseline) if instrumented and baseline is not None else None,
            extra_over_unit_smoke=len(measured - baseline - unit_hits) if instrumented and baseline is not None and unit_hits is not None else None,
            passed_catalog_keys=len(passed),
            obligations=[{k: expected[identity][k] for k in ('profile', 'variant', 'suite', 'id', 'family', 'intent', 'expected', 'dependencies')
                          if k in expected[identity]} for identity in sorted(passed)]))
    for group, row in zip(sorted(groups), results):
        others = set().union(*(value for other, value in hits.items() if other != group))
        row['exclusive_integration_lines'] = len(hits[group] - others) if row['instrumented_jobs'] else None
    provenance = {k: next(iter(records.values())).get(k) for k in ('commit', 'run_id', 'attempt')} if records else {}
    return dict(provenance=provenance, baseline_smoke_jobs=baseline_ids, baseline_complete=baseline_ready,
                baseline_smoke_lines=len(baseline) if baseline is not None else None,
                unit_baseline_available=unit_hits is not None, areas=results)


def markdown(report):
    rows = report['areas']
    show = lambda v: 'unmeasured' if v is None else str(v)
    text = ['# Test area value', '',
        'Baseline: the two PR case selections from this run. Unit + smoke also includes this run\'s unit report.',
        f"Smoke baseline complete: {report['baseline_complete']}. Unit baseline available: {report['unit_baseline_available']}.", '',
        'Each row groups one profile, capture variant, suite and area. Numbered chunks share a row. '
        'Times are summed execution-group minutes, not elapsed workflow time. Partial rows can miss results.', '',
        '| Profile / variant / suite / area | Complete | Passed catalog keys | Groups with coverage / total | Minutes release / coverage | Lines hit | Extra over smoke | Extra over unit + smoke | Exclusive integration lines |',
        '|---|---|---:|---:|---:|---:|---:|---:|---:|']
    for r in sorted(rows, key=lambda r: -(r['release_seconds'] + r['coverage_seconds'])):
        label = ' / '.join(r[k] for k in ('profile', 'variant', 'suite', 'area'))
        text.append(f"| {label} | {r['complete']} | {r['passed_catalog_keys']} | {r['instrumented_groups']} / {r['execution_groups']} | "
                    f"{r['release_seconds']/60:.1f} / {r['coverage_seconds']/60:.1f} | {show(r['covered_lines'])} | "
                    f"{show(r['extra_over_smoke'])} | {show(r['extra_over_unit_smoke'])} | {show(r['exclusive_integration_lines'])} |")
    text += ['', 'Line gains are set differences and are not additive. Exclusive lines are relative to other measured areas. '
             'Zero extra lines does not prove redundant assertions. Unmeasured is not zero. '
             'Passed catalog keys can overlap between rows; do not sum them as catalog coverage. '
             'Fixture setup and cleanup contribute coverage and time. Crash paths may not flush counters. '
             'Rust, dependencies and harness code are excluded. The JSON includes case IDs and declared test intent; '
             'review the assertions before removing a case.']
    return '\n'.join(text) + '\n'


def write(output, report):
    (output / 'test-value.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    (output / 'test-value.md').write_text(markdown(report))
    if report['areas']:
        with (output / 'test-value.csv').open('w', newline='') as stream:
            fields = [k for k in report['areas'][0] if k != 'obligations']
            writer = csv.DictWriter(stream, fieldnames=fields)
            writer.writeheader()
            writer.writerows({k: r[k] for k in fields} for r in report['areas'])
