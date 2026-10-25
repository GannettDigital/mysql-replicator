<!-- Current CI model: BETA7_SINGLE_TEST_BUILD.md. Earlier measurements below record prior plans. -->
# Beta.7 test selection and job organization

## Purpose

Change how we select and group tests before we optimize individual suites.
Keep the current assertions and profile limits. Use the SQL traces, case times
and code coverage to assess repeated work after the new structure is in place.

## Design references

[Debezium's file-change workflow](https://github.com/debezium/debezium/blob/main/.github/workflows/file-changes-workflow.yml)
separates connector changes from common code changes. It also identifies parser
changes. We will use explicit component rules and include all affected profiles
when shared code changes. Unknown paths must retain a conservative selection.

[Airbyte's connector test guide](https://github.com/airbytehq/airbyte/blob/master/docs/platform/connector-development/testing-connectors/README.md)
separates unit, integration and shared acceptance tests. Its shared tests check
connector behavior against a common protocol. For this project, shared MySQL
cases and profile-specific expectations serve that purpose. We do not need a
separate test implementation for each replication topology.

These examples support the structure. They do not prove which MySQL cases we can
remove or which version combinations we can omit.

## Beta.7 PR order

Prepare the CI/CD changes as the first PR in the beta.7 release stack. Rebase the
runtime feature PRs onto it later. Do not reorder the current branches yet.

Keep CI tools, workflows and their tests separate from runtime behavior changes.
When we prepare that first PR, validate it against the catalog on GitHub main.
Case IDs and selection rules that need beta.7 runtime features must enter with
the corresponding feature PR, not with the first CI infrastructure PR. Recheck
both normal and expanded plans after the stack has been rebased.

## Keep three separate layers

1. **Case catalog.** A case defines behavior, SQL, assertions, dependencies and
   profile limits. Keep its stable ID. A case can contain ordered SQL statements.
   Do not split these statements into separate cases merely to reduce job time.
2. **Execution group.** One lab invocation selects cases for a profile, variant
   and transport. It owns its fixtures and result files. A dependency must run
   in the same group as the case that needs it.
3. **CI job.** A job can run several execution groups. It downloads the lab and
   runtime image once. Each group retains its own isolation, measurements,
   support bundles, SQL traces and coverage files.

Combining execution groups in one CI job does not mean sharing database state.
We can later combine compatible cases in one fixture after we check their setup
and cleanup requirements. Use one instrumented execution for each test group. Build production packages
after merge and run the small checks described in [the release model](BETA7_SINGLE_TEST_BUILD.md).

## Work order

### 1. Shared case selection — implemented

`tools/lab_selection.py` resolves case IDs and families from the lab's catalog.
CI uses the same dependency resolver for PR cases, full correctness groups and
BINLOG selections. `make lab-plan` prints local plans and commands.

Plans distinguish requested cases from added dependencies. They list profile
exclusions with reasons. Invalid IDs, missing dependencies and cycles fail.
Native and recovery adapters retain their complete execution groups until those
runners support narrower selection.

The first change keeps the current CI executions unchanged. Compared with commit
`d6a6304`, local catalog checks retain:

| Scope | CI jobs | Applicable case/profile/variant obligations |
|---|---:|---:|
| PR | 2 | 22 |
| Full | 246 | 2,095 |

These counts are a baseline, not a target. They include the current supplemental
coverage and BINLOG executions in the job count. No assertion was removed.

### 2. Separate execution groups from CI jobs — implemented

- Save execution groups in the bundled plan. Give each group a stable identity.
- Let CI jobs refer to groups. Keep profile and test area in job names.
- Run independent jobs in parallel. Run groups within a job with separate
  artifacts and failure results. A failed group must not hide a later group.
- Keep result validation, release-binary checks and coverage counts at group
  level. A missing group must fail the aggregate result.
- Preserve the complete case/profile/variant/transport inventory. Compare the
  old and new plans before running database tests.
- Keep both normal and expanded-coverage matrices below GitHub's job limit.
  Start with simple, explicit grouping. Use measured times for later balancing.

Local plan generation keeps the 246 normal execution groups and all 2,095
obligations. It assigns them to 130 CI jobs. Expanded coverage keeps 479 groups
and uses 247 jobs. PR checks remain two groups in two jobs. No case, assertion,
fixture boundary or coverage collection was removed.

The runner checks coverage files for each group separately. The report binds
each measurement to its planned job and still rejects missing groups. Focused
runner tests cover a failed group followed by a passing group, cancellation,
and rejection of coverage files left by an earlier group. These are local
orchestration checks. We have not measured the new job durations in GitHub.

### 3. Select groups from changed components — implemented

Map implementation and test files to the catalog's behavior groups. Start with
clear boundaries such as indexes, JSON transport, replay and reconnect handling.
Use the existing catalog definition locations where they are sufficient. Add
explicit rules for shared implementation files and shared fixture code.

Do not infer safety from a filename alone. For example, a shared schema-cache
change can affect DDL, DML, replay and recovery. It needs a broader selection.
Each plan must explain the changed path, selected cases, profile choices and
added dependencies. Local selection and CI must use the same rules.

`tools/test_components.json` defines exact path rules. The first rules select
index-resume, JSON YEAR, archive and reconnect checks. The shared index fixture
file retains full CI because native, failure and recovery tests use its helpers.
All unmapped runtime and test files retain full CI. Baseline PR checks remain.

Local selection and CI use the same planner. It resolves against the full catalog
and keeps complete execution groups, all applicable profiles and variants, and
existing matching BINLOG groups. Plans list reasons, exclusions and dependencies.
The new `pr-selected` scope cannot produce release evidence. Full labels and main
pushes still select the complete catalog.

Focused Python checks cover component unions, shared-code overrides, dependencies,
profile limits, transport groups, missing groups and local/CI command agreement.
Local catalog checks retain the full inventory of 2,095 obligations and 246 groups.
No database assertion or fixture was changed. See
[PR test selection](../docs/PR_TEST_SELECTION.md) for the current component counts.

### 4. Measure, then review repetitions — first local comparison

Run the reorganized groups with SQL records and timing. Collect instrumented
coverage separately from release-binary tests. Compare assertions, expected
errors, SQL, engine/version behavior and restart boundaries.

Use `tools/lab_compare.py` for local comparisons. The recorder keeps lab and applier image builds
outside elapsed test time. MySQL fixture setup remains included. The comparison checks build and MySQL settings, case
and named assertion sets, SQL calls and optional line coverage. See
[LOCAL_TEST_COMPARISON.md](../docs/LOCAL_TEST_COMPARISON.md).

The first local release comparison passed. Combining two database cases reduced
elapsed time from 184.16 to 104.20 seconds and SQL client calls from 379 to 229.
Both cases and all named assertions remained. This validates the comparison
method; that database group is already combined in CI. Fresh line coverage was
not measured because its cold build stalled. See
[the study](BETA7_LOCAL_TEST_GROUP_STUDY.md) for evidence and limits.

The [sample review](BETA7_SAMPLE_REVIEW.md) removed the duplicate release sample.
The [sample comparison](BETA7_COVERAGE_SAMPLE_COMPARISON.md) then combined its
instrumented cases with the forward baseline. It retained all 10,649 measured
runtime lines. The new [single test build](BETA7_SINGLE_TEST_BUILD.md) supersedes
that supplemental coverage plan. It retains the cases in their full groups and
instruments each group once. The first full run used 240 groups in 125 jobs.
The [full-run fixes](BETA7_FULL_RUN_FIXES.md) assign those groups to 240 jobs,
retain all 2,095 catalog obligations, and record fixture setup and cleanup time.
PR selection remains unchanged.

Use exact file/line differences to review a costly group with a small gain.
Inspect the branch condition. Prefer a focused unit test or a small addition to
an existing integration case when it can retain that behavior. Measure the
replacement before removing its original coverage run.

The next full run will use the [single test build](BETA7_SINGLE_TEST_BUILD.md).
The earlier expanded study was not started. Use the new run's line maps to rank
the next area; the older main timing report did not instrument the full suite.

Remove a test only after another test retains its behavior and assertions.
Overlapping line coverage or equal SQL text is insufficient evidence. Select the
short PR case set after this review. Keep explicit case lists in job reports.

## Local validation for the first change

- Focused Python tests check selection, dependencies, exclusions and CI plans.
- Read the real catalog without starting containers. Compare each existing CI
  execution with its new plan: case order, profile, variant, image, transport,
  coverage count and ID must remain unchanged.
- Combine the indexes family with `database-existing-different`. The plan must
  add `database-explicit` as a dependency.
- Resolve the named PR selection and compare it with the CI PR plan.

Database assertions and their runner code are unchanged in these selection and
reporting steps. See [the local study](BETA7_LOCAL_TEST_GROUP_STUDY.md) for the
separate-versus-combined fixture comparison and its coverage limit.
