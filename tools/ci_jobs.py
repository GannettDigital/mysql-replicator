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
    estimates = policy.get('estimated_seconds_by_area', {})
    fallback = policy.get('unmeasured_group_seconds', minutes * 60)
    if not isinstance(estimates, dict) or any(not isinstance(k, str) or not k for k in estimates):
        raise ValueError('invalid area time estimates')
    if any(not isinstance(v, (int, float)) or isinstance(v, bool) or not 0 < v <= 21600
           for v in [fallback, *estimates.values()]):
        raise ValueError('invalid group time estimate')
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
                       profile=profile, variant=variant, image=image, area='', group_ids=[], reports=0,
                       timeout_minutes=setup, estimated_seconds=0)
            jobs.append(job)
            if not isolated:
                pending[key] = job
        job['group_ids'].append(group['id'])
        job['reports'] += group.get('reports', 0)
        job['area'] += (' + ' if job['area'] else '') + group['area']
        job['timeout_minutes'] += minutes
        job['estimated_seconds'] += estimates.get(group['area'], fallback)
        if len(job['group_ids']) == maximum:
            pending.pop(key, None)
    # Longest estimated jobs enter the runner queue first. Never reorder cases.
    # Equal estimates retain the catalog order. Estimates do not set timeouts.
    jobs.sort(key=lambda job: -job['estimated_seconds'])
    result = dict(plan, jobs=jobs, group_timeout_seconds=minutes * 60)
    validate_jobs(result)
    if plan.get('scope') == 'full' and 'growth_budget' in policy:
        result['growth_check'] = check_growth(result, policy)
    return result


def check_growth(plan, policy):
    """Plan extra profiles/variants without adding them to the runnable matrix."""
    budget = policy['growth_budget']
    if not isinstance(budget, dict) or set(budget) != {'max_jobs', 'max_growth_jobs'}:
        raise ValueError('invalid CI growth budget')
    if any(type(v) is not int or not 1 <= v <= 256 for v in budget.values()):
        raise ValueError('CI growth budgets must be between 1 and 256')
    if budget['max_jobs'] > budget['max_growth_jobs']:
        raise ValueError('CI growth budget is below current job budget')
    if len(plan['jobs']) > budget['max_jobs']:
        raise ValueError(f"current CI jobs exceed growth budget: {len(plan['jobs'])} > {budget['max_jobs']}")
    policy = {k: v for k, v in policy.items() if k != 'growth_budget'}
    groups = plan['include']
    profiles = sorted({g['profile'] for g in groups})
    extra_profile, extra_variant = '__growth_profile__', '__growth_variant__'
    if extra_profile in profiles or any(g.get('variant') == extra_variant for g in groups):
        raise ValueError('reserved CI growth-check identity in real matrix')

    def variant_copy(items):
        # Source variants apply to correctness/lifecycle, not demo or native suites.
        return [dict(g, id='growth-variant:' + g['id'], variant=extra_variant)
                for g in items if g.get('variant', 'default') == 'default'
                and g['suite'] in ('correctness', 'lifecycle')]

    def measure(items):
        candidate = assign_jobs(dict(include=items), policy)
        count = len(candidate['jobs'])
        if count > budget['max_growth_jobs']:
            raise ValueError(f"projected CI jobs exceed growth budget: {count} > {budget['max_growth_jobs']}")
        return dict(groups=len(items), jobs=count)

    # Try every existing profile as the model. Do not assume the largest group
    # count also produces the largest packed job count.
    profile_runs = {}
    for profile in profiles:
        extended = groups + [dict(g, id='growth-profile:' + g['id'], profile=extra_profile)
                             for g in groups if g['profile'] == profile]
        profile_runs[profile] = measure(extended)
    return dict(budget=budget, current=dict(groups=len(groups), jobs=len(plan['jobs'])),
                additional_profile=profile_runs,
                additional_source_variant=measure(groups + variant_copy(groups)),
                scope='Separate planning scenarios: one extra profile OR one extra source variant. Real selections are unchanged.')
