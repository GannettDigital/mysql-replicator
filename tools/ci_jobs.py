"""Assign complete, isolated lab executions to CI jobs without changing their cases."""
from collections import Counter


def validate_jobs(plan):
    """Reject missing, repeated, or incompatible group assignments before execution."""
    groups = {g['id']: g for g in plan['include']}
    if not groups or len(groups) != len(plan['include']):
        raise ValueError('empty or duplicate execution groups')
    jobs = plan['jobs']
    if not jobs or len(jobs) > 256:
        raise ValueError('CI matrix must contain 1 to 256 jobs')
    if len({job['id'] for job in jobs}) != len(jobs):
        raise ValueError('duplicate CI job IDs')
    owners = Counter()
    for job in jobs:
        if not job['group_ids']:
            raise ValueError('empty CI job: ' + job['id'])
        for identifier in job['group_ids']:
            if identifier not in groups:
                raise ValueError('unknown execution group: ' + identifier)
            group = groups[identifier]
            if any(job[key] != group.get(key, 'default' if key == 'variant' else None)
                   for key in ('profile', 'variant', 'image')):
                raise ValueError('incompatible execution group: ' + identifier)
            owners[identifier] += 1
    if set(owners) != set(groups) or any(n != 1 for n in owners.values()):
        raise ValueError('CI jobs must assign each execution group exactly once')


def assign_jobs(plan, policy):
    maximum = policy['max_groups']
    minutes, setup = policy['group_timeout_minutes'], policy['setup_timeout_minutes']
    if any(not isinstance(v, int) or isinstance(v, bool) or v < 1 for v in (maximum, minutes, setup)):
        raise ValueError('CI job group counts and timeouts must be positive integers')
    if setup + maximum * minutes > 360:
        raise ValueError('CI job timeout exceeds 360 minutes')
    standalone = policy['standalone_areas']
    if not isinstance(standalone, list) or any(not isinstance(a, str) or not a for a in standalone):
        raise ValueError('standalone areas must be a list of names')
    jobs, pending, counters = [], {}, Counter()
    # Keep the existing priority order. Only combine compatible executions.
    for group in plan['include']:
        key = (group['profile'], group.get('variant', 'default'), group['image'])
        isolated = group['area'] in standalone or plan.get('scope') == 'pr-smoke'
        job = None if isolated else pending.get(key)
        if job is None:
            counters[key] += 1
            profile, variant, image = key
            job = dict(id=f'job-{image}-{profile}-{variant}-{counters[key]}',
                       profile=profile, variant=variant, image=image, area='', group_ids=[],
                       timeout_minutes=setup)
            jobs.append(job)
            if not isolated:
                pending[key] = job
        job['group_ids'].append(group['id'])
        job['area'] += (' + ' if job['area'] else '') + group['area']
        job['timeout_minutes'] += minutes
        if len(job['group_ids']) == maximum:
            pending.pop(key, None)
    result = dict(plan, jobs=jobs, group_timeout_seconds=minutes * 60)
    validate_jobs(result)
    return result
