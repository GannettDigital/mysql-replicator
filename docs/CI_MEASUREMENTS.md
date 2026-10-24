# CI timing and coverage measurements

The [PR #40 review](../PLAN/FULL_SUITE_REORGANIZATION.md) records the first full
coverage comparison. Review assertions before removing tests with overlapping
lines. Select PR cases after the full suite has been organized and measured.

Shared correctness fixtures also write `sql-client.json`. It records client
calls, failed calls, elapsed client seconds, batch calls, and queries in batches.
CI copies these values into each shard's `sql_client` field in `report.json`.
The summary separates release and coverage images. Counts include fixture
setup, waits, and assertions through `NativeHarness.sql`. They do not count
every SQL statement or direct client calls outside that helper. Client time
includes process startup and MySQL execution. It is not applier SQL time.
Missing measurements are not zero.

## SQL records for each test case

The harness writes `sql-trace.jsonl` in each fixture directory. CI includes this
file in the integration evidence artifact. No server general log is required.
The trace does not change SQL or add SQL comments.

Each client call has a `start` record and a `finish` record with the same
`call_id`. The start record contains:

- The SQL text and request kind: `request`, `script`, `batch`, or `direct-client`.
- The logical server role (`source`, `native`, or `target`) and Docker service.
- The profile, variant, DML transport and coverage setting for shared fixtures.
- The active `case_id`, enclosing `case_path`, and test definition location.
- The `assertion_id`, when the call runs inside a named assertion.
- The names and SQL of queries in a batch. These exclude the generated framing queries.

Calls outside an active case have `scope: outside-case`. These calls can include
setup, cleanup and checks between cases. Do not assign them to the next case.
The finish record contains elapsed client time, exit status and output sizes.
Failed calls also retain the last 16 KiB of stderr. Query results remain in the
existing assertion files. A failed SQL call can be part of a passing negative
test. Use `cases.json` and the assertion files to determine the test result.

The trace covers calls through `NativeHarness.sql`, its script and batch helpers,
and direct `mysql` commands through `NativeHarness.compose`. It does not record
SQL sent by the applier, replication threads, benchmark clients, or processes
started outside these helpers. Background commands have outcome `submitted`;
this confirms command submission, not SQL completion. A start without a finish
means the call was interrupted or the result was not recorded. Trace write
errors fail the harness operation instead of silently omitting records.

A client call can contain several SQL statements. Scripts can contain
`DELIMITER` commands. Thus, call counts are not statement counts. The
`resets_gtid` field identifies the extra session reset used by the SQL helper.
Client time includes Docker and mysql client startup. Trace file writes are
outside that measured interval.

To summarize one run or several downloaded artifact directories:

```sh
python3 tools/lab_sql_report.py artifacts/lab/RUN_ID > /tmp/lab-sql-report.json
jq '.groups[] | {case_id, role, calls, seconds, outcomes}' /tmp/lab-sql-report.json
```

The report groups calls by fixture, innermost case and server role. It does not
add a child case's calls to its parent. It reports unfinished calls separately.
It excludes SQL text and query results. The input traces can contain credentials
and row data; keep them with the other restricted test artifacts.

To inspect the SQL for one case:

```sh
jq 'select(.event == "start" and .case_id == "database-explicit") |
    {role, kind, assertion_id, sql, queries}' PATH/TO/sql-trace.jsonl
```

Use the SQL, assertions, profile and catalog obligations together when checking
for duplicate tests. Equal SQL text alone does not prove that tests are duplicates.
This instrumentation does not change test selection or CI job groups.

## SQL client batches

Metadata queries share a client call at each existing comparison boundary.
Row comparisons and independent binlog checks retain their existing boundaries.
Batch framing preserves empty results and exact whitespace. A missing or
unexpected frame fails the comparison.

Use the beta.4 release stack to collect a baseline for all four profiles.
PR checks use unit tests, Periphery and two parallel [explicit test selections](PR_TEST_SELECTION.md). Main retains
the full catalog. Add `ci-full` to the top release PR to run that catalog before
merge. See [release testing](RELEASE_TESTING.md) for the evidence and release gate.
The targets for later work are five minutes for PR feedback and twenty minutes
for the complete merge checks. This change does not claim those times.

## Execution groups and CI jobs

An execution group is one lab invocation with its own fixtures and results.
The JSON files retain the name `shard` for these groups. The bundled plan stores
them in `include`. Its separate `jobs` list assigns every group to exactly one
CI job. Result IDs, SQL traces and coverage remain attached to the group.

`tools/ci_jobs.json` controls job assignment. The current policy puts at most
three groups with the same profile, variant and build type in one job. Long
areas and the two PR selections keep separate jobs. Jobs run in parallel, up to
16 at a time. Groups within a job run in sequence and use separate fixtures.
The job downloads its tools and image once.

A failed group records failure. The job then runs its remaining groups and
returns failure. Cancellation stops the job. Each lab invocation has a 45-minute
limit. The job timeout adds 10 minutes for setup to the sum of its group limits.
These are failure limits, not expected durations. A timed-out lab process can
leave containers on its disposable runner; later groups use different project
names. The runner removes those resources when the job ends.

Coverage checks count only the files produced by the current group. Each
measurement includes its CI `job_id`. The aggregate rejects a missing group or
a result assigned to the wrong job. A failed-job rerun runs all groups in that
job and replaces its measurement and coverage artifacts.

The beta.7 catalog currently produces these plans:

| Scope | Execution groups | CI jobs | Coverage collections |
|---|---:|---:|---:|
| PR | 2 | 2 | 2 |
| Full | 246 | 130 | 23 |
| Full with expanded coverage | 479 | 247 | 256 |

All 2,095 full-catalog obligations remain. The group selections and fixture
boundaries are unchanged. These counts come from local plan generation; CI
runtime measurements are still needed. The planner checks the 256-job limit
after grouping. More cases can require a later grouping-policy change.

## Normal CI

Each integration shard writes a measurement, including failed runs. The final
`Timing & Profile Coverage Report` job publishes `ci-measurement-report`.
Read `summary.md` first. Use `report.json` for job, step and shard times.
The `ci-measurement-*` artifacts contain the source-matched line maps and case
times for each shard. The report contains no row values, SQL or credentials.
Normal integration evidence can still contain sensitive data.

The report separates these measurements:

- Catalog coverage: passed obligations divided by applicable obligations for
  each selected profile and scope. Runtime PR scope is `pr-smoke`. PRs with
  `ci-full` and main use `full`. Manual runs default to `full`. This is coverage of our selected catalog, not all MySQL features.
- Code coverage: the union of mapped Swift runtime lines reached by instrumented
  runs. It excludes Rust, dependencies and the lab. The existing combined Swift
  report also includes unit coverage.
- Time: job and step time from GitHub, shard time from a monotonic clock, and
  case time from the shared reporter. Case time includes waits and assertions.
  Nested cases overlap. Do not add their times to estimate total runtime.

Code coverage belongs to a shard, not an individual case. A shard includes
fixture setup and cleanup. A line reached by one profile alone is marked unique
relative to the other measured profiles. Equal line coverage does not prove
that two tests check the same behavior. SIGKILL paths cannot flush LLVM counters.

Missing shards, failed runs or missing expected coverage collections make the
report partial and fail its job. Missing catalog results are listed explicitly.
Keep the run ID, execution attempt, and commit with downloaded evidence.
A failed-job rerun can reuse successful shards from earlier attempts of the same
run. CI requires successful workflow dependencies, including the aggregate check
of all builds and integration jobs. Each successful build and test job must
replace its named artifact. An upload failure fails that job. Thus, a failed
rerun cannot use an old successful artifact to pass the release check.

The report checks each saved result against the current test matrix and build
identity. A result from another run or commit is rejected. A new build requires
fresh results for the affected shards. The report lists stale shards and the
execution attempt for each result. Test results, catalog checks, expected coverage
collections, and package checksums remain required.

GitHub copies successful jobs into later attempts with new job IDs. The report
uses execution timestamps from the attempt history to find when each job ran.
Times describe the latest execution of each job; they exclude failed executions
replaced by retries. These API measurements are optional. Requests use smaller
pages and bounded retries. The timing step has a three-minute limit. If it fails,
the report marks job and step timing as unavailable, not zero. Shard times and
case times remain in the saved test artifacts. An API outage does not bypass a
required test check. Shard and report uploads replace their earlier artifacts.

## Expanded coverage for the release candidate

Start expanded coverage manually on the release candidate branch or tag.
The `ci-full` label runs the full PR suite without expanded instrumentation.
Add `ci-expanded-coverage` to a PR to collect expanded coverage. This label also
selects the full suite. Each later push keeps this selection. Remove the expanded
label to return to normal full CI if `ci-full` remains, or smoke CI if it does not.
Both label changes start a new CI run. Unrelated labels do not start or cancel CI.

```sh
gh pr edit <top-pr-number> --add-label ci-full --add-label ci-expanded-coverage
```

After the workflow is available on main, a manual run can use:

```sh
gh workflow run ci.yml --ref <branch-or-tag> -f suite=full -f expanded_coverage=true
```

Expanded mode retains every release-binary shard. It adds instrumented copies
of shared correctness and lifecycle shards for every applicable variant.
Runtime PR CI has two smoke shards and two integration coverage collections.
Documentation and report-only selections do not collect Swift coverage or produce
this measurement report. See [changed-file selection](PR_TEST_SELECTION.md).
Each shard now selects 11 named cases from the full catalog. The two cross-version
full-CI coverage supplements use the same cases. The `ddl-dml-policy-replay` job
area and step summary identify the selection. Its artifact IDs retain the
`-smoke` suffix so the same-run coverage baseline remains identifiable.
The earlier suite had 108 normal full shards and 203 expanded shards for 718
catalog obligations. These are historical counts. The beta.6 catalog now has
2,085 obligations. After the DML split below, normal full CI has 226 jobs.
The generated matrix is the authority when the catalog changes.

The beta.7 job plan now fits expanded coverage within the matrix limit.
See [execution groups and CI jobs](#execution-groups-and-ci-jobs) for current
counts. Coverage collection remains attached to each execution group.

DDL and bootstrap now use two groups per profile and variant. The group
boundaries use the [PR #41 timings](../PLAN/PR41_TEST_SUITE_RESULTS.md).
This removes repeated fixture setup without removing cases. Expect fewer
coverage collections because fewer fixtures run. Check line sets and catalog
results separately; the collection count is not a coverage percentage.

DML uses groups of at most eight cases. In the beta.6 stack, a single DML job
contained 44–48 cases and reached the 45-minute timeout while cases were still
passing. The split retains the same case inventory and dependencies. Check the
next CI timings before changing the timeout or selecting fewer cases. See the
[beta.6 failure report](../PLAN/BETA6_CI_FAILURES.md).

Native-reference and specialized recovery adapters do not export line coverage.
Their existing tests remain required. Demo collections remain instrumented.
This experiment is more expensive than normal CI. It is evidence for later
selection changes. It is separate from the PR smoke selection.

## Read coverage scope and test value

The coverage summary states the test scope and instrumentation mode. It shows
planned integration jobs, jobs that collect coverage, and collected versus
expected fixture reports. A fixture report is not a job or an assertion.
A complete selected report does not mean that all release tests were instrumented.
The PR comment uses the same scope fields. Its publisher runs trusted code from
main. New comment wording takes effect after that publisher change reaches main;
PR job summaries and artifacts use the code in the tested PR immediately.

The measurement artifact also contains `test-value.md`, `test-value.csv` and
`test-value.json`. These files group numbered chunks by profile, capture variant,
suite and area. Each row shows:

- Release and coverage group minutes, plus groups with coverage and total groups.
- Passed catalog keys and declared case intent in the JSON.
- Covered lines and lines added beyond the two PR smoke jobs from the same run.
- Lines added beyond that smoke baseline plus the unit report from the same run.
- Lines exclusive to this area among measured integration areas.

An unmeasured area has no line counts. It is not assigned zero coverage. Missing
smoke or unit data makes the corresponding baseline unavailable. Partial rows
can miss results. Source hashes must match before unit and integration line maps
can be compared. Line gains are not additive. Catalog keys can occur in several
rows, so their sum is not catalog coverage.

Review assertions, profile behavior and failure checks before removing a case.
Equal line coverage does not prove equal test value. Native-reference and
specialized recovery adapters remain required without line maps. Rust code is
not measured. SIGKILL can prevent the process from saving coverage counters.
Use expanded coverage for a test-suite investigation. Keep normal full CI as the
release default. Coverage binaries are diagnostic builds, not release packages.

## Review the evidence

If a build fails before it saves `build.json`, the measurement report lists the
missing build record and test shards. The report remains partial, and the job
fails after it saves the report. Results without a matching build record cannot
qualify a release. Check `summary.md` and `report.json` for these failures.

Collect one complete expanded report on the release candidate. Compare
runner-minutes as well as elapsed time. Check build time, cache transfer, image download/load, fixture time and the longest
shards. Do not treat the delay before a dependent job starts as proven runner
queue time. GitHub step times have second-level precision.

Keep the existing release process. These measurements do not replace its required
main CI run. The release workflow must publish the exact packages from that run.
The full-suite evidence file binds the report to the tested package checksums.
No release rebuild is added.
