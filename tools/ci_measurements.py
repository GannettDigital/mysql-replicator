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
from coverage_scope import description, plan_scope
from ci_reruns import digest, validate_results


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
def record_shard(root, identifier, build_inputs=False, job_id=None):
    started = time.monotonic()
    directory = root / 'artifacts/lab'
    before = set(directory.glob('*/result.json'))
    previous_coverage = set(downloaded_inputs(directory))
    previous_sql = set(directory.rglob('sql-client.json'))
    record = dict(version=1, id=identifier, **provenance(), status='failed', scenarios=[])
    if job_id is not None:
        record['job_id'] = job_id
    try:
        if build_inputs:
            record['build'] = json.loads((root / 'artifacts/ci/image/build.json').read_text())
            record['matrix_sha256'] = digest(root / 'artifacts/ci/matrix.json')
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
            # Each correctness fixture writes one file outside copied evidence.
            sql_paths = sorted(p for p in set(directory.rglob('sql-client.json')) - previous_sql
                               if 'evidence' not in p.relative_to(directory).parts)
            if sql_paths:
                values = [json.loads(p.read_text()) for p in sql_paths]
                record['sql_client'] = {k: sum(v[k] for v in values) for k in
                                        ('calls', 'failures', 'seconds', 'batch_calls', 'batch_queries')}
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
    # The history reader retains the execution attempt of reused jobs.
    jobs = [job for page in pages for job in page['jobs']]
    result = []
    for job in jobs:
        result.append(dict(name=job['name'], conclusion=job.get('conclusion'),
            execution_attempt=job.get('execution_attempt'),
            seconds=seconds(job.get('started_at'), job.get('completed_at')),
            started_at=job.get('started_at'), completed_at=job.get('completed_at'),
            steps=[dict(name=s['name'], conclusion=s.get('conclusion'),
                        seconds=seconds(s.get('started_at'), s.get('completed_at')))
                   for s in job.get('steps', [])]))
    return result


def summarize(manifest, records, jobs=None, context=None, builds=None, matrix_digest=None, dependencies=None):
    if 'jobs' in manifest:
        from ci_jobs import validate_jobs
        validate_jobs(manifest)
    planned = {s['id']: s for s in manifest['include']}
    job_ids = {group: job['id'] for job in manifest.get('jobs', []) for group in job['group_ids']}
    by_id = {}
    for record in records:
        identifier = record['id']
        if identifier in by_id or identifier not in planned:
            raise ValueError('duplicate or unknown shard: ' + identifier)
        if job_ids and record.get('job_id') != job_ids[identifier]:
            raise ValueError('execution group has wrong or missing CI job ID: ' + identifier)
        by_id[identifier] = record
    origins = {(r.get('commit'), r.get('run_id'), r.get('attempt')) for r in records}
    stale = []
    missing_builds = []
    if context is not None:
        missing_builds = sorted({s['image'] for s in planned.values()} - set(builds))
        stale = validate_results(manifest, records, context, builds, matrix_digest, dependencies)
    elif len(origins) > 1:
        raise ValueError('mixed commits or run attempts; CI job and build evidence is required to reuse results')
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
            # New plans name their owners explicitly. Keep the default only
            # for historical reports with supplemental coverage runs.
            owns = shard.get('owns_obligations', shard['image'] == 'release' or shard['suite'] == 'demo')
            if record['status'] == 'passed' and owns:
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
    # This report cannot require its own success or that of its downstream
    # evidence job. A retry can still expose their previous failed executions.
    reporting_jobs = {'Timing & Profile Coverage Report', 'Full Suite / Release Evidence',
                      'Full Suite / Test Evidence', 'Production Packages / Release Evidence'}
    expected_skips = {'unit-tests', 'combined-coverage', 'periphery', 'swift-lint'} if manifest.get('scope') == 'production' else set()
    job_failures = ([name for name, job in dependencies.items()
                     if job.get('result') != ('skipped' if name in expected_skips else 'success')]
                    if dependencies is not None else
                    [j['name'] for j in timings if j['name'] not in reporting_jobs and
                     j['conclusion'] in ('failure', 'cancelled', 'timed_out', 'action_required')])
    complete = not (missing or failed or missing_coverage or job_failures or stale or missing_builds) and all(not p['catalog_missing'] for p in profiles.values())
    return dict(version=1, complete=complete, scope=manifest.get('scope', 'full'), coverage_mode=manifest.get('coverage_mode', 'selected'),
        provenance=context if context is not None else ({k: records[0].get(k) for k in ('commit', 'run_id', 'attempt')} if records else {}),
        builds=builds, missing_builds=missing_builds, stale_shards=stale,
        dependency_results={name: job.get('result') for name, job in dependencies.items()} if dependencies is not None else None,
        job_timing_status='available' if jobs else 'unavailable',
        shard_attempts={r['id']: r.get('attempt') for r in records},
        missing_shards=missing, failed_shards=failed, missing_coverage=missing_coverage,
        profiles=profiles, jobs=timings, failed_jobs=job_failures,
        execution_groups=len(planned), planned_jobs=len(manifest.get('jobs', manifest['include'])),
        instrumentation=dict(plan_scope(manifest), integration_reports=sum(r.get("coverage", {}).get("collections", 0) for r in records)),
        completed_job_seconds=sum(j['seconds'] or 0 for j in timings) if jobs else None,
        shards=[dict(planned[k], job_id=r.get('job_id', k), seconds=r['seconds'], status=r['status'], attempt=r.get('attempt'),
                     sql_client=r.get('sql_client'),
                     covered_lines=len(r.get('coverage', {}).get('hit', [])),
                     mapped_lines=len(r.get('coverage', {}).get('mapped', []))) for k, r in sorted(by_id.items())])


def markdown(report):
    lines = ['# CI measurement', '', 'Complete' if report['complete'] else 'PARTIAL: inspect missing or failed records.', '',
        'Scope: ' + report['scope'] + '. Catalog totals cover only this selection.', '',
        description(report['instrumentation']), '',
        'See test-value.md, test-value.csv and test-value.json for costs, marginal line coverage and case intent by area.', '',
        '| Profile | Catalog passed / expected | Runtime lines hit / mapped | Unique lines | Shard minutes: release / coverage |',
        '|---|---:|---:|---:|---:|']
    lines[4:4] = [f"CI jobs: {report['planned_jobs']}. Execution groups: {report['execution_groups']}.", '']
    for name, p in report['profiles'].items():
        duration = p['shard_seconds']
        lines.append(f"| {name} | {p['catalog_passed']} / {p['catalog_expected']} | {p['covered_lines']} / {p['mapped_lines']} | {p['unique_covered_lines']} | {duration.get('release', 0)/60:.1f} / {duration.get('coverage', 0)/60:.1f} |")
    timing = (f"Completed jobs: {report['completed_job_seconds']/60:.1f} runner-minutes."
              if report['completed_job_seconds'] is not None else
              'GitHub job and step timing unavailable. Test results, shard times and coverage are retained.')
    lines += ['', timing, '', 'Coverage mode: ' + report['coverage_mode'] + '.', '',
        'Line coverage measures first-party Swift runtime code. It excludes Rust and lab code. '
        'Unique lines are relative to the other measured profiles. They do not prove that a test is redundant. '
        'Coverage is attributed to a shard, not an individual case. SIGKILL cannot flush LLVM counters. '
        'Native-only observations do not run the replicator and have no runtime coverage.', '',
        'Shard time includes tool validation and the lab run. Case time includes its assertions and waits. '
        'Nested case times overlap. The remainder can include fixture setup, cleanup and coverage export. '
        'When available, use job and step times in report.json to identify build, download and setup costs.']
    if report['jobs']:
        lines += ['', '| Slowest job | Minutes | Result |', '|---|---:|---|']
    for job in sorted(report['jobs'], key=lambda j: j['seconds'] or 0, reverse=True)[:12]:
        if job['seconds'] is not None:
            lines.append(f"| {job['name']} | {job['seconds']/60:.1f} | {job['conclusion']} |")
    sql = defaultdict(list)
    for shard in report['shards']:
        if shard.get('sql_client') is not None:
            sql[shard['image']].append(shard['sql_client'])
    if sql:
        lines += ['', '## SQL client cost', '',
                  'These measurements cover the shared correctness fixtures that export sql-client.json. '
                  'Calls include setup, waits, and assertions through NativeHarness.sql. '
                  'Seconds include client startup and query execution. They are not target apply time. '
                  'Missing measurements are not zero. Per-shard values are in report.json.', '',
                  '| Image | Measured shards | Client calls | Failed calls | Batch calls | Queries in batches | Client seconds |',
                  '|---|---:|---:|---:|---:|---:|---:|']
        for image, values in sorted(sql.items()):
            totals = {k: sum(v[k] for v in values) for k in values[0]}
            lines.append(f"| {image} | {len(values)} | {totals['calls']} | {totals['failures']} | "
                         f"{totals['batch_calls']} | {totals['batch_queries']} | {totals['seconds']:.1f} |")
    if report.get('shard_attempts'):
        counts = Counter(report['shard_attempts'].values())
        lines += ['', 'Shard execution attempts: ' + ', '.join(f'{k}: {v} shards' for k, v in sorted(counts.items(), key=lambda item: str(item[0]))) + '.',
                  'Times describe the latest execution of each job. They do not include failed executions replaced by retries.']
    if report.get('stale_shards'):
        lines += ['', 'Stale results: rerun these shards against the current build and matrix:']
        lines += ['- ' + shard for shard in report['stale_shards']]
    for field, label in [('missing_builds', 'Missing build records'), ('failed_jobs', 'Failed required jobs'),
                         ('missing_shards', 'Missing shards'), ('failed_shards', 'Failed shards'),
                         ('missing_coverage', 'Missing coverage')]:
        if report.get(field):
            lines += ['', label + ':', ''] + ['- ' + value for value in report[field]]
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--matrix', type=Path, required=True)
    parser.add_argument('--records', type=Path, required=True)
    parser.add_argument('--jobs', type=Path)
    parser.add_argument('--optional-job-timings', action='store_true',
                        help='Allow missing GitHub timing data; required workflow results still apply')
    parser.add_argument('--unit-coverage', type=Path)
    parser.add_argument('--builds', type=Path)
    parser.add_argument('--output', type=Path, default=Path('artifacts/ci/report'))
    args = parser.parse_args()
    records = [json.loads(p.read_text()) for p in sorted(args.records.rglob('*.json'))]
    manifest = json.loads(args.matrix.read_text())
    context = None
    builds = None
    dependencies = None
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        if not args.builds or not os.environ.get('CI_JOB_RESULTS'):
            parser.error('CI reporting requires --builds and CI_JOB_RESULTS')
        dependencies = json.loads(os.environ['CI_JOB_RESULTS'])
        context = {k: os.environ[v] for k, v in [('commit', 'GITHUB_SHA'), ('run_id', 'GITHUB_RUN_ID'), ('attempt', 'GITHUB_RUN_ATTEMPT')]}
        builds = {}
        for image in {s['image'] for s in manifest['include']}:
            path = args.builds / ('ci-build-' + image) / 'build.json'
            if path.is_file():
                builds[image] = json.loads(path.read_text())
    jobs = None
    try:
        if args.jobs:
            jobs = json.loads(args.jobs.read_text())
            job_timings(jobs)  # Validate optional timing input before using it.
    except (OSError, ValueError, TypeError, KeyError):
        if not args.optional_job_timings:
            raise
        print('GitHub job timing unavailable; validating saved test artifacts and required jobs.')
        jobs = None
    report = summarize(manifest, records, jobs, context, builds, digest(args.matrix), dependencies)
    write(args.output / 'report.json', report)
    from ci_test_value import analyze, write as write_value
    unit = load_reports(Path(__file__).resolve().parents[1], [args.unit_coverage])[0] if args.unit_coverage else None
    if unit is not None and unit['inputs'] != ['unit']:
        raise ValueError('unit baseline must contain only unit coverage')
    value = analyze(manifest, records, unit)
    value['provenance'] = report['provenance']
    value['shard_attempts'] = report['shard_attempts']
    write_value(args.output, value)
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
