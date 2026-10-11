#!/usr/bin/env python3
"""Select smoke or full CI without a second test inventory."""
import json
import os
from pathlib import Path

FULL_LABEL = 'ci-full'


def select(event_name, event):
    if event_name == 'pull_request':
        # Ignore unrelated label edits. A removed ci-full label restores smoke.
        if event.get('action') in ('labeled', 'unlabeled') and event.get('label', {}).get('name') != FULL_LABEL:
            return None
        labels = {label['name'] for label in event['pull_request'].get('labels', [])}
        return {'scope': 'full' if FULL_LABEL in labels else 'pr-smoke', 'expanded': False}
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


def main():
    selected = select(os.environ['GITHUB_EVENT_NAME'], json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()))
    if selected is None:
        raise ValueError('unrelated label event must not start CI')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('scope=' + selected['scope'] + '\n')
        output.write('expanded=' + str(selected['expanded']).lower() + '\n')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write('CI scope: **' + selected['scope'] + '**. Expanded coverage: '
                      + str(selected['expanded']).lower() + '.\n')


if __name__ == '__main__':
    main()
