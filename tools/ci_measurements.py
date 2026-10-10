#!/usr/bin/env python3
"""Record CI costs and coverage without changing test selection or assertions."""
import argparse
from collections import Counter, defaultdict
from contextlib import contextmanager
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import time

from code_coverage import load_reports
from coverage_report import downloaded_inputs
from ci_matrix import key


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def provenance():
    return {name: os.environ.get(env, '') for name, env in
            [('commit', 'GITHUB_SHA'), ('run_id', 'GITHUB_RUN_ID'),
             ('attempt', 'GITHUB_RUN_ATTEMPT'), ('runner_image', 'ImageVersion')]}


def line_sets(reports):
    mapped, hit = set(), set()
    for report in reports:
        for path, lines in report['files'].items():
            if path.startswith('Sources/ReplicatorLab'):
                continue
            mapped.update((path, str(n)) for n in lines)
            hit.update((path, str(n)) for n, count in lines.items() if count > 0)
    return mapped, hit


@contextmanager
def record_shard(root, identifier):
    started = time.monotonic()
    directory = root / 'artifacts/lab'
    before = set(directory.glob('*/result.json'))
    previous_coverage = set(downloaded_inputs(directory))
    record = dict(version=1, id=identifier, **provenance(), status='failed', scenarios=[])
    try:
        yield
        record['status'] = 'passed'
    finally:
        record['seconds'] = time.monotonic() - started
        try:
            for path in sorted(set(directory.glob('*/result.json')) - before):
                report = json.loads(path.read_text())
                record['scenarios'].extend({k: row[k] for k in
                    ('profile', 'variant', 'suite', 'id', 'family', 'status', 'seconds') if k in row}
                    for row in report.get('scenarios', []))
            paths = [p for p in set(downloaded_inputs(directory)) - previous_coverage
                     if p.parent.name == 'combined']
            if paths:
                reports = load_reports(root, sorted(paths))
                mapped, hit = line_sets(reports)
                record['coverage'] = dict(mapped=sorted(mapped), hit=sorted(hit), collections=len(paths),
                    sources_digest=hashlib.sha256(json.dumps(reports[0]['sources'], sort_keys=True).encode()).hexdigest())
        except Exception as error:
            record['measurement_error'] = str(error)
            raise
        finally:
            write(root / 'artifacts/ci/measurements' / (identifier + '.json'), record)


def seconds(start, end):
    if not start or not end:
        return None
    return (datetime.fromisoformat(end.replace('Z', '+00:00')) -
            datetime.fromisoformat(start.replace('Z', '+00:00'))).total_seconds()


def job_timings(pages):
    # --paginate --slurp returns pages. Keep run attempts separate at the API URL.
    jobs = [job for page in pages for job in page['jobs']]
    result = []
    for job in jobs:
        result.append(dict(name=job['name'], conclusion=job.get('conclusion'),
            seconds=seconds(job.get('started_at'), job.get('completed_at')),
            started_at=job.get('started_at'), completed_at=job.get('completed_at'),
            steps=[dict(name=s['name'], conclusion=s.get('conclusion'),
                        seconds=seconds(s.get('started_at'), s.get('completed_at')))
                   for s in job.get('steps', [])]))
    return result


def summarize(manifest, records, jobs=None):
    planned = {s['id']: s for s in manifest['include']}
    by_id = {}
    for record in records:
        identifier = record['id']
        if identifier in by_id or identifier not in planned:
            raise ValueError('duplicate or unknown shard: ' + identifier)
        by_id[identifier] = record
    origins = {(r.get('commit'), r.get('run_id'), r.get('attempt')) for r in records}
    if len(origins) > 1:
        raise ValueError('mixed commits or run attempts')
    digests = {r['coverage']['sources_digest'] for r in records if r.get('coverage')}
    if len(digests) > 1:
        raise ValueError('mixed coverage source mappings')
    profiles = {}
    all_hits = {}
    for profile in sorted({r['profile'] for r in manifest['inventory']}):
        expected = {key(r) for r in manifest['inventory'] if r['profile'] == profile and r['status'] == 'not_run'}
        observed = set()
        mapped, hit = set(), set()
        count = 0
        wall = defaultdict(float)
        cases = []
        for identifier, shard in planned.items():
            if shard['profile'] != profile or identifier not in by_id:
                continue
            record = by_id[identifier]
            wall[shard['image']] += record['seconds']
            # Instrumented correctness runs supplement release assertions. Only
            # the demo's primary obligations are owned by a coverage job.
            if record['status'] == 'passed' and (shard['image'] == 'release' or shard['suite'] == 'demo'):
                observed.update(key(r) for r in record['scenarios'] if r['status'] == 'passed')
            for row in record['scenarios']:
                if 'seconds' in row:
                    cases.append(dict(row, shard=identifier, image=shard['image']))
            coverage = record.get('coverage')
            if coverage:
                mapped.update(map(tuple, coverage['mapped']))
                hit.update(map(tuple, coverage['hit']))
                count += coverage['collections']
        all_hits[profile] = hit
        profiles[profile] = dict(catalog_expected=len(expected), catalog_passed=len(observed & expected),
            catalog_missing=[list(k) for k in sorted(expected - observed)],
            shard_seconds=dict(wall), coverage_collections=count,
            mapped_lines=len(mapped), covered_lines=len(hit),
            slowest_cases=sorted(cases, key=lambda r: r['seconds'], reverse=True)[:20])
    for profile, hits in all_hits.items():
        others = set().union(*(h for p, h in all_hits.items() if p != profile))
        profiles[profile]['unique_covered_lines'] = len(hits - others)
    missing = sorted(set(planned) - set(by_id))
    failed = sorted(k for k, r in by_id.items() if r['status'] != 'passed' or r.get('measurement_error'))
    missing_coverage = sorted(k for k, s in planned.items() if s['reports'] and
        by_id.get(k, {}).get('coverage', {}).get('collections', 0) != s['reports'])
    timings = job_timings(jobs) if jobs else []
    job_failures = [j['name'] for j in timings if j['conclusion'] in ('failure', 'cancelled', 'timed_out', 'action_required')]
    complete = not (missing or failed or missing_coverage or job_failures) and all(not p['catalog_missing'] for p in profiles.values())
    return dict(version=1, complete=complete, coverage_mode=manifest.get('coverage_mode', 'selected'),
        provenance={k: records[0].get(k) for k in ('commit', 'run_id', 'attempt')} if records else {},
        missing_shards=missing, failed_shards=failed, missing_coverage=missing_coverage,
        profiles=profiles, jobs=timings, failed_jobs=job_failures,
        completed_job_seconds=sum(j['seconds'] or 0 for j in timings),
        shards=[dict(planned[k], seconds=r['seconds'], status=r['status'],
                     covered_lines=len(r.get('coverage', {}).get('hit', [])),
                     mapped_lines=len(r.get('coverage', {}).get('mapped', []))) for k, r in sorted(by_id.items())])


def markdown(report):
    lines = ['# CI measurement', '', 'Complete' if report['complete'] else 'PARTIAL: inspect missing or failed records.', '',
        '| Profile | Catalog passed / expected | Runtime lines hit / mapped | Unique lines | Shard minutes: release / coverage |',
        '|---|---:|---:|---:|---:|']
    for name, p in report['profiles'].items():
        duration = p['shard_seconds']
        lines.append(f"| {name} | {p['catalog_passed']} / {p['catalog_expected']} | {p['covered_lines']} / {p['mapped_lines']} | {p['unique_covered_lines']} | {duration.get('release', 0)/60:.1f} / {duration.get('coverage', 0)/60:.1f} |")
    lines += ['', f"Completed jobs: {report['completed_job_seconds']/60:.1f} runner-minutes.", '', 'Coverage mode: ' + report['coverage_mode'] + '.', '',
        'Line coverage measures first-party Swift runtime code. It excludes Rust and lab code. '
        'Unique lines are relative to the other measured profiles. They do not prove that a test is redundant. '
        'Coverage is attributed to a shard, not an individual case. SIGKILL cannot flush LLVM counters. '
        'Native and specialized recovery adapters have no instrumented collection; their catalog results remain required.', '',
        'Shard time includes tool validation and the lab run. Case time includes its assertions and waits. '
        'Nested case times overlap. The remainder can include fixture setup, cleanup and coverage export. '
        'Use job and step times in report.json to identify build, download and setup costs.', '',
        '| Slowest job | Minutes | Result |', '|---|---:|---|']
    for job in sorted(report['jobs'], key=lambda j: j['seconds'] or 0, reverse=True)[:12]:
        if job['seconds'] is not None:
            lines.append(f"| {job['name']} | {job['seconds']/60:.1f} | {job['conclusion']} |")
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--matrix', type=Path, required=True)
    parser.add_argument('--records', type=Path, required=True)
    parser.add_argument('--jobs', type=Path)
    parser.add_argument('--output', type=Path, default=Path('artifacts/ci/report'))
    args = parser.parse_args()
    records = [json.loads(p.read_text()) for p in sorted(args.records.rglob('*.json'))]
    report = summarize(json.loads(args.matrix.read_text()), records,
                       json.loads(args.jobs.read_text()) if args.jobs else None)
    write(args.output / 'report.json', report)
    text = markdown(report)
    (args.output / 'summary.md').write_text(text)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as out:
            out.write(text)
    print(text)
    if not report['complete']:
        raise SystemExit('CI measurement is partial')


if __name__ == '__main__':
    main()
