# Possible future CI optimizations

## Decision

Defer further full-suite changes. First measure normal `ci-full` with the current
groups. Select explicit PR checks now. The [PR #42 review](PR42_TEST_SUITE_RESULTS.md)
preserves the assertion review and timing estimates behind the ideas below.

Normal full CI runs 108 integration jobs. Expanded coverage runs 203. The extra
95 jobs measure correctness and reconnect with instrumentation. They are useful
for suite analysis, but are not required for normal release checks.

Removing those extra jobs should reduce time and cost. It does not guarantee half
the elapsed time. Both modes retain shared builds, reporting, and long tests.
Runner availability and the concurrency limit also affect elapsed time. Compare
normal full and expanded runs with similar cache conditions before making a claim.

## Candidates, if normal full CI is still too slow

1. Split demo jobs at existing session boundaries. Use workbook/repair and
   resume/recovery groups. This adds four jobs but no database fixtures. Add
   per-session setup, body, cleanup, and SQL-client timing before assessing cost.
2. Separate complete forward failures from recovery/offline workflows. Keep
   smaller profile selections together. This adds two release jobs and two
   optional coverage jobs. It shortens the longest jobs but adds fixture setup.
3. Record native DDL cost for each engine policy and child case. The current
   aggregate represents two fixtures as one catalog item. Keep the assertions.
   Consider parallel engine-policy jobs only after measuring their costs.
4. Group demo metadata queries in fewer client calls. Export client counters
   first. Preserve exact row bytes, comparison boundaries, and failure evidence.
5. Reassess sample and same-version smoke supplements. Similar line coverage
   does not prove duplicate behavior. Compare fixture state and assertions
   before removing a job.
6. Review build and Periphery time separately from test time. A five-minute
   integration job does not guarantee five-minute PR feedback.

Do not change bootstrap groups because of one slow runner. Keep all four full
profiles, capture variants, intermediate checks, and independent binlog checks.
Do not shorten heartbeat, lock, or crash synchronization without an equivalent
test of the same behavior.

## Measurement conditions

- Compare exact catalog keys and assertions, not only total counts.
- Compare source-matched line sets by area and profile as well as globally.
- Keep release-binary checks as the full-suite default.
- Use `ci-expanded-coverage` when changes need a new coverage comparison.
- Report elapsed workflow time, job time, and runner-minutes separately.
- Retain failure artifacts and support bundles before repeating a failed run.

These are future options. The current PR test selection does not implement them.
