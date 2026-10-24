"""Describe measured integration scope separately from release test scope."""


def plan_scope(matrix):
    shards = matrix['include']
    by_id = {s['id']: s for s in shards} if 'jobs' in matrix else {}
    jobs = matrix.get('jobs', shards)
    return dict(ci_suite=matrix.get('scope', 'full'),
                coverage_mode=matrix.get('coverage_mode', 'selected'),
                integration_jobs=len(jobs),
                instrumented_jobs=(sum(any(by_id[g]['reports'] > 0 for g in j['group_ids']) for j in jobs)
                                   if 'jobs' in matrix else sum(s['reports'] > 0 for s in shards)),
                execution_groups=len(shards),
                instrumented_groups=sum(s['reports'] > 0 for s in shards),
                expected_integration_reports=sum(s['reports'] for s in shards))


def description(metrics):
    scope = metrics.get('ci_suite', 'unknown')
    mode = metrics.get('coverage_mode', 'unknown')
    lines = [f'Test scope: {scope}. Coverage mode: {mode}.']
    if 'integration_jobs' in metrics:
        lines.append(f"Planned integration jobs: {metrics['integration_jobs']}; "
                     f"jobs that collect coverage: {metrics['instrumented_jobs']}.")
    if 'execution_groups' in metrics:
        lines.append(f"Execution groups: {metrics['execution_groups']}; "
                     f"groups that collect coverage: {metrics['instrumented_groups']}.")
    if 'integration_reports' in metrics:
        expected = metrics.get('expected_integration_reports', 'unknown')
        lines.append(f"Integration coverage collections: {metrics['integration_reports']} / {expected} expected.")
    if mode == 'expanded':
        lines.append('Coverage includes instrumented correctness and reconnect runs, smoke suites, demos and sample. '
                     'Release-binary checks also run. Native-reference and specialized recovery adapters do not export coverage.')
    elif mode == 'selected' and scope == 'full':
        lines.append('Coverage includes smoke suites, demos and sample only. '
                     'The other release-binary tests do not contribute line coverage.')
    elif mode == 'selected' and scope == 'pr-smoke':
        lines.append('Integration coverage includes the two PR smoke suites only.')
    elif mode == 'selected' and scope == 'pr-selected':
        lines.append('Coverage includes the PR baseline and any selected instrumented groups. '
                     'Selected release-binary groups do not contribute line coverage. See the matrix for cases.')
    else:
        lines.append('This older or local report does not identify the full instrumentation plan.')
    return ' '.join(lines)
