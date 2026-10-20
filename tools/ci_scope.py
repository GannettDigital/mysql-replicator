#!/usr/bin/env python3
"""Select CI checks from event policy and the shared changed-file rules."""
import argparse
import json
import os
from pathlib import Path

from test_selection import checks_for, from_git, select_changes

FULL_LABEL = 'ci-full'
EXPANDED_LABEL = 'ci-expanded-coverage'
CI_LABELS = {FULL_LABEL, EXPANDED_LABEL}


def select(event_name, event):
    if event_name == 'pull_request':
        # Ignore unrelated label edits. Expanded coverage implies the full suite.
        if event.get('action') in ('labeled', 'unlabeled') and event.get('label', {}).get('name') not in CI_LABELS:
            return None
        labels = {label['name'] for label in event['pull_request'].get('labels', [])}
        return {'scope': 'full' if labels & CI_LABELS else 'pr-smoke',
                'expanded': EXPANDED_LABEL in labels}
    if event_name == 'push':
        if event['ref'] != 'refs/heads/main':
            raise ValueError('automatic full CI requires main')
        return {'scope': 'full', 'expanded': False}
    if event_name != 'workflow_dispatch':
        raise ValueError('unsupported CI event: ' + event_name)
    inputs = event.get('inputs', {})
    scope = inputs.get('suite', 'full')
    if scope not in ('full', 'pr-smoke'):
        raise ValueError('unknown CI suite: ' + scope)
    expanded = inputs.get('expanded_coverage', False) in (True, 'true')
    if expanded and scope != 'full':
        raise ValueError('expanded coverage requires the full suite')
    return {'scope': scope, 'expanded': expanded}


def resolve(event_name, event, change_plan=None):
    selected = select(event_name, event)
    if selected is None:
        return None
    plan = change_plan or select_changes([], fallback='changed-file list unavailable; use full checks')
    if event_name != 'pull_request' or selected['scope'] == 'full':
        plan = dict(plan, scope=selected['scope'], selected_by=[], reason='event or explicit CI label/input')
    return dict(plan, expanded=selected['expanded'], checks=checks_for(plan['scope']))


def check_results(scope, results):
    checks = checks_for(scope)
    expected = {'select-suite': True, 'tool-tests': True, 'swift-lint': True, 'unit-tests': checks['unit'],
                'periphery': checks['periphery'], 'lab-tools': checks['integration'],
                'build-images': checks['integration'], 'integration': checks['integration']}
    for job, required in expected.items():
        actual = results.get(job, {}).get('result')
        wanted = 'success' if required else 'skipped'
        if actual != wanted:
            raise ValueError(f'{job}: expected {wanted}, got {actual}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-results', action='store_true')
    args = parser.parse_args()
    if args.check_results:
        check_results(os.environ['SELECTED_SCOPE'], json.loads(os.environ['RESULTS']))
        return
    event_name = os.environ['GITHUB_EVENT_NAME']
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    change_plan = None
    if event_name == 'pull_request':
        pr = event.get('pull_request', {})
        base, head = pr.get('base', {}).get('sha'), pr.get('head', {}).get('sha')
        if base and head:
            change_plan = from_git(base, head)
    selected = resolve(event_name, event, change_plan)
    if selected is None:
        raise ValueError('unrelated label event must not start CI')
    destination = Path('artifacts/ci/test-selection.json')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(selected, indent=2) + '\n')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('scope=' + selected['scope'] + '\n')
        output.write('expanded=' + str(selected['expanded']).lower() + '\n')
        for name, enabled in selected['checks'].items():
            output.write(name + '=' + str(enabled).lower() + '\n')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write('CI scope: **' + selected['scope'] + '**. Expanded coverage: '
                      + str(selected['expanded']).lower() + '.\n\n' + selected['reason'] + '.\n\n')
        summary.write('Selected checks: ' + ', '.join(k for k, v in selected['checks'].items() if v) + '.\n\n')
        for change in selected['changes']:
            summary.write('- ' + json.dumps(change['path']) + ': ' + change['reason'] + '.\n')
        if not selected['checks']['integration']:
            summary.write('\nSwift coverage and database tests are not selected for this change.\n')


if __name__ == '__main__':
    main()
