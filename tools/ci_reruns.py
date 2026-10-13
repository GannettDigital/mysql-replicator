#!/usr/bin/env python3
"""Read CI job history and bind retry results to the build they tested."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def api_pages(endpoint):
    for attempt in range(4):
        try:
            result = subprocess.run(['gh', 'api', '--paginate', '--slurp', endpoint],
                                    capture_output=True, text=True, timeout=60)
            if result.returncode == 0:
                return json.loads(result.stdout)
            retryable = re.search(r'HTTP (429|5\d\d)|error connecting|connection reset|timed out',
                                  result.stderr, re.IGNORECASE)
            error = result.stderr.strip()
        except subprocess.TimeoutExpired:
            retryable, error = True, 'GitHub API request timed out'
        if not retryable or attempt == 3:
            raise ValueError('Cannot read CI jobs: ' + error)
        delay = 2 ** (attempt + 1)
        print(f'GitHub job request failed. Retry in {delay} seconds.', file=sys.stderr)
        time.sleep(delay)


def unique_jobs(jobs, run_id):
    groups = {}
    ids = set()
    for job in jobs:
        if str(job['run_id']) != str(run_id) or job['id'] in ids:
            raise ValueError('Wrong run or duplicate job ID in GitHub response')
        ids.add(job['id'])
        groups.setdefault(job['name'], []).append(job)
    result = []
    for name, candidates in groups.items():
        if len(candidates) == 1:
            result.append(candidates[0])
            continue
        # A matrix rerun can leave a queued copy beside the completed job.
        # Accept only an unassigned copy of the same creation and attempt.
        # Do not choose by conclusion or ID: the unused copy can have a newer ID.
        completed = [j for j in candidates if j.get('status') == 'completed'
                     and j.get('started_at') and j.get('completed_at') and j.get('steps')]
        if len(completed) == 1:
            actual = completed[0]
            identity = ('run_attempt', 'head_sha', 'created_at')
            copies = [j for j in candidates if j is not actual]
            if (all(actual.get(k) is not None for k in identity)
                    and all(all(j.get(k) == actual[k] for k in identity)
                            and j.get('status') == 'queued' and j.get('conclusion') is None
                            and j.get('completed_at') is None and j.get('steps') == []
                            and not j.get('runner_id') and not j.get('runner_name') for j in copies)):
                result.append(actual)
                continue
        raise ValueError('Conflicting duplicate job name in GitHub response: ' + name)
    return result


def job_history(repository, run_id, attempt):
    # GitHub copies successful jobs into later attempts with NEW job IDs and
    # run_attempt values, but keeps their original execution timestamps.
    executions = {}
    latest = []
    for number in range(1, int(attempt) + 1):
        pages = api_pages(f'repos/{repository}/actions/runs/{run_id}/attempts/{number}/jobs?per_page=30')
        jobs = [job for page in pages for job in page['jobs']]
        if not pages or len(jobs) != pages[0]['total_count']:
            raise ValueError('Incomplete GitHub job listing')
        latest = []
        for job in unique_jobs(jobs, run_id):
            key = (job['name'], job.get('started_at'), job.get('completed_at'))
            execution = executions.setdefault(key, number)
            latest.append(dict(job, execution_attempt=str(execution)))
    return [dict(jobs=latest)]


def build_identity(root, image, env):
    directory = root / 'artifacts/ci/image'
    receipt = directory / 'image.json'
    if receipt.exists():
        value = json.loads(receipt.read_text())
        if value['commit'] != env['GITHUB_SHA'] or value['image'] != image:
            raise ValueError('Image receipt differs from this build')
        runtime = value['reference']
    else:
        runtime = 'archive-sha256:' + digest(directory / 'image.tar.gz')
    result = dict(image=image, commit=env['GITHUB_SHA'], run_id=env['GITHUB_RUN_ID'],
                  attempt=env['GITHUB_RUN_ATTEMPT'], runtime=runtime)
    if image == 'release':
        result['package_checksums_sha256'] = digest(root / 'artifacts/release/SHA256SUMS')
    return result


REQUIRED_DEPENDENCIES = {'lab-tools', 'unit-tests', 'packaging-and-smoke', 'combined-coverage', 'periphery'}


def validate_results(manifest, records, context, builds, matrix_digest, dependencies):
    # These are workflow `needs` results, not REST job-history responses.
    # Every successful build/shard must overwrite its named artifact. A failed
    # rerun (including an upload failure) fails the required aggregate job, so
    # it cannot certify an older artifact that remains in this workflow run.
    if dependencies is None or set(dependencies) != REQUIRED_DEPENDENCIES:
        raise ValueError('missing or unexpected required workflow dependencies')
    shards = {s['id']: s for s in manifest['include']}
    stale = []
    for image in {s['image'] for s in shards.values()}:
        build = builds[image]
        attempt = str(build.get('attempt', ''))
        if (build['commit'] != context['commit'] or build['run_id'] != context['run_id']
                or build['image'] != image or not build.get('runtime') or not attempt.isdigit()
                or not 1 <= int(attempt) <= int(context['attempt'])):
            raise ValueError('Build identity differs from this workflow run: ' + image)
    for record in records:
        if record.get('commit') != context['commit'] or record.get('run_id') != context['run_id']:
            raise ValueError('mixed commits or workflow runs')
        attempt = str(record.get('attempt', ''))
        if not attempt.isdigit() or not 1 <= int(attempt) <= int(context['attempt']):
            raise ValueError('invalid or future shard attempt')
        shard = shards[record['id']]
        if (record.get('build') != builds[shard['image']]
                or int(attempt) < int(builds[shard['image']]['attempt'])
                or record.get('matrix_sha256') != matrix_digest):
            stale.append(record['id'])
    return stale


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['jobs', 'identity'])
    parser.add_argument('--image', choices=['release', 'coverage'])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'jobs':
        value = job_history(os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_RUN_ID'],
                            os.environ['GITHUB_RUN_ATTEMPT'])
    else:
        if not args.image:
            parser.error('identity requires --image')
        value = build_identity(Path.cwd(), args.image, os.environ)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(args.output)


if __name__ == '__main__':
    main()
