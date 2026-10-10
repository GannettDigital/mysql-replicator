#!/usr/bin/env python3
"""Compare isolated cold/warm builds of the same revision and runner image."""
import argparse
import json
import os
from pathlib import Path
import time

from ci_measurements import job_timings, provenance, write


def comparison(records):
    pairs = {}
    for record in records:
        key = (record['image'], record['phase'])
        if key in pairs:
            raise ValueError('duplicate build measurement')
        pairs[key] = record
    rows = []
    for image in ('release', 'coverage'):
        cold, warm = pairs.get((image, 'cold')), pairs.get((image, 'warm'))
        errors = []
        if not cold or not warm:
            errors.append('missing cold or warm build')
        else:
            for field in ('commit', 'run_id', 'attempt', 'runner_image'):
                if not cold.get(field) or cold[field] != warm.get(field):
                    errors.append('different or missing ' + field)
            if cold['cache_hit']:
                errors.append('cold compiler cache was not empty')
            if not warm['cache_hit']:
                errors.append('warm compiler cache was not restored')
            if any(r['status'] != 'success' or r['seconds'] is None for r in (cold, warm)):
                errors.append('build failed or did not start')
        rows.append(dict(image=image, valid=not errors, errors=errors,
                         cold_seconds=cold.get('seconds') if cold else None,
                         warm_seconds=warm.get('seconds') if warm else None))
    return dict(version=1, valid=all(r['valid'] for r in rows), builds=rows, records=records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['record', 'report'])
    parser.add_argument('--records', type=Path)
    parser.add_argument('--jobs', type=Path)
    parser.add_argument('--output', type=Path, default=Path('artifacts/ci/cache-study'))
    args = parser.parse_args()
    if args.action == 'record':
        value = dict(version=1, **provenance(), image=os.environ['BUILD_IMAGE'],
                     phase=os.environ['BUILD_PHASE'], cache_hit=os.environ.get('CACHE_HIT') == 'true',
                     seconds=time.time() - float(os.environ['BUILD_STARTED']) if os.environ.get('BUILD_STARTED') else None,
                     status=os.environ['BUILD_STATUS'])
        write(args.output / (value['image'] + '-' + value['phase'] + '.json'), value)
        return
    if not args.records:
        parser.error('--records is required for report')
    result = comparison([json.loads(p.read_text()) for p in sorted(args.records.rglob('*.json'))])
    if args.jobs:
        result['jobs'] = job_timings(json.loads(args.jobs.read_text()))
        result['failed_jobs'] = [j['name'] for j in result['jobs'] if j['conclusion'] in ('failure', 'cancelled', 'timed_out', 'action_required')]
        result['valid'] = result['valid'] and not result['failed_jobs']
    write(args.output / 'comparison.json', result)
    lines = ['# Cold/warm build comparison', '', '| Build | Cold seconds | Warm seconds | Valid pair |', '|---|---:|---:|---|']
    for row in result['builds']:
        lines.append(f"| {row['image']} | {row['cold_seconds']} | {row['warm_seconds']} | {row['valid']} |")
        if row['errors']:
            lines.append('\n' + row['image'] + ': ' + '; '.join(row['errors']) + '\n')
    lines += ['', 'Each pair uses the same commit on fresh runners. Compiler mounts and Docker layers use an isolated cache namespace. '
              'Cold disables build-layer reuse. Warm imports that experiment\'s caches. '
              'The build timer includes layer import/export and package or image output. '
              'Job and step times include compiler-cache restore/save. '
              'This measures exact-revision reuse, not incremental compilation after a source edit. '
              'It does not measure unit-test or lab-tool builds. Repeat pairs to estimate variation. '
              'These artifacts do not qualify or publish a release.']
    text = '\n'.join(lines) + '\n'
    (args.output / 'summary.md').write_text(text)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as out:
            out.write(text)
    print(text)
    if not result['valid']:
        raise SystemExit('invalid cold/warm comparison')


if __name__ == '__main__':
    main()
