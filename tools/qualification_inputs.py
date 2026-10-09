#!/usr/bin/env python3
"""Select retained qualification artifacts from successful main CI at HEAD."""
import json
import os
import subprocess

REQUIRED = {'ci-lab', 'ci-image-release'}


def select_run(runs, sha, artifacts):
    for run in runs:  # gh returns newest first
        if (run['headSha'] != sha or run['headBranch'] != 'main'
                or run['event'] != 'push' or run['status'] != 'completed'
                or run['conclusion'] != 'success'):
            continue
        retained = {a['name'] for a in artifacts(run['databaseId']) if not a['expired']}
        if REQUIRED <= retained:
            return run['databaseId']
    raise ValueError('No successful main CI with retained ci-lab and ci-image-release '
                     'artifacts for this exact commit. Wait for main CI, or rerun it '
                     'if artifacts expired, then rerun qualification.')


def gh_json(*args):
    return json.loads(subprocess.check_output(['gh', *args], text=True))


def main():
    # Dereference annotated tags to the checked-out commit too.
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    repo = os.environ['GITHUB_REPOSITORY']
    runs = gh_json('run', 'list', '--repo', repo, '--workflow', 'ci.yml',
                   '--commit', sha, '--branch', 'main', '--event', 'push', '--limit', '100',
                   '--json', 'databaseId,headSha,headBranch,event,status,conclusion')

    def artifacts(run_id):
        pages = gh_json('api', '--paginate', '--slurp',
                        f'repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100')
        return [a for page in pages for a in page['artifacts']]

    run_id = select_run(runs, sha, artifacts)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
        out.write(f'run_id={run_id}\n')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as out:
        out.write(f'Qualification reuses lab and release image from '
                  f'[CI run {run_id}](https://github.com/{repo}/actions/runs/{run_id}) '
                  f'at `{sha}`. No compilation in qualification jobs.\n')


if __name__ == '__main__':
    main()
