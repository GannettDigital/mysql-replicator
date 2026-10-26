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

For a case-cost report with repeated-call fingerprints:

```sh
python3 tools/lab_sql_report.py artifacts/lab/RUN_ID --output artifacts/sql-cost
```

The output has `report.json` and `report.md`. It groups client cost by case and
role. Categories identify known schema comparisons, position checks, metadata
reads, other reads, and simple source statements. Calls outside cases remain
separate. Mixed SQL remains unclassified. A simple source statement can be setup
or workload SQL; review its case and assertions before deciding.

Fingerprints preserve SQL bytes, literals, identifiers and query order. Only
random batch framing is excluded. Copied `evidence/` traces are excluded when
scanning a directory. Repeated calls can be required polling or repeated checks;
they do not prove redundancy. The report contains no SQL text or query results.

CI now saves these per-case costs under `sql_cost` in each group measurement.
The combined report lists the most expensive cases. Its JSON retains all costs
and the 20 most expensive repeated-call fingerprints per group. Coverage remains
at execution-group level. Do not attribute a group's coverage to one case.

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

Use the beta.7 release candidate to collect measurements for all four profiles.
PR checks use [changed-file selection](PR_TEST_SELECTION.md). Component checks
include the two-profile baseline and matching groups. Shared runtime changes
select the full catalog. Unit tests and Periphery remain parallel checks. Main builds production packages and runs two small binary checks. Add `ci-full` to the top release PR to run that catalog before
merge. See [release testing](RELEASE_TESTING.md) for the evidence and release gate.
The targets for later work are five minutes for PR feedback and twenty minutes
for the full pre-merge checks. This change does not claim those times.

## Execution groups and CI jobs

An execution group is one lab invocation with its own fixtures and results.
The JSON files retain the name `shard` for these groups. The bundled plan stores
them in `include`. Its separate `jobs` list assigns every group to exactly one
CI job. Result IDs, SQL traces and coverage remain attached to the group.

`tools/ci_jobs.json` assigns one execution group to each current job. Cases
inside a correctness group share their fixture. Jobs run in parallel, up to
16 at a time. DDL, DML, index and bootstrap tests use named behavior groups
with explicit case lists. New cases in those families must be assigned to a group; the planner rejects
omissions and duplicate assignments. The scheduler starts longer estimated jobs
first. Each job downloads its tools and image once.

Each lab invocation has a 45-minute limit. The job timeout adds 10 minutes for
setup. These are failure limits, not expected durations. A timed-out lab process
can leave containers on its disposable runner. The runner removes those
resources when the job ends.

Coverage checks count only the files produced by the current group. Each
measurement includes its CI `job_id`. The aggregate rejects a missing group or
a result assigned to the wrong job. A failed-job rerun runs that group and
replaces its measurement and coverage artifacts.

The beta.7 catalog currently produces these plans:

| Scope | Execution groups | CI jobs | Coverage collections |
|---|---:|---:|---:|
| PR | 2 | 2 | 2 |
| Full | 240 | 240 | 253 |
| Main production packages | 2 | 2 | 0 |

The full plan has 2,075 applicable obligations. Before the two case migrations,
it had 2,095. Ten executions belonged to `matrix-generated` and ten belonged to
`matrix-fulltext`. Their conditions now run in `ddl-compat-generated` and
`ddl-compat-fulltext` in the same profile/variant/transport selections.
Existing-schema generated-column and FULLTEXT tests remain separate. See the
[migration review](../PLAN/BETA7_TEST_SUITE_CONSOLIDATION.md) for assertion and
line-coverage evidence. This change does not reduce the number of fixtures.
Full CI runs each apply group with
coverage once. It does not add copies for coverage or repeat the PR baseline.
The [sample comparison](../PLAN/BETA7_COVERAGE_SAMPLE_COMPARISON.md) records the
previous consolidation. Its cases now run in their full-catalog groups.
The planner checks the 256-job limit after grouping. These are local plan counts;
GitHub runtime measurements are still needed.

Index tests use two groups: column modifications and index changes. Bootstrap
tests use three groups: encodings/defaults, numeric/temporal values, and structured
values/row operations/target metadata. Each group retains its selected cases and
assertions. The change reduces fixture count without removing any catalog
obligation. Scheduling estimates use run `40170659705`; new group estimates add
the recorded case times and the median time outside named cases. They include
20% headroom, rounded up to a minute. They are not measured runtimes for the new
groups. See [the grouping study](../PLAN/BETA7_INTEGRATION_GROUP_PROPOSAL.md).

## Normal CI

Each integration shard writes a measurement, including failed runs. The final
`Timing & Profile Coverage Report` job publishes `ci-measurement-report`.
Read `summary.md` first. Use `report.json` for job, step and shard times.
The `ci-measurement-*` artifacts contain the source-matched line maps and case
times for each shard. The report contains no row values, SQL or credentials.
Normal integration evidence can still contain sensitive data.

The report separates these measurements:

- Catalog coverage: passed obligations divided by applicable obligations for
  each selected profile and scope. The baseline scope is `pr-smoke`. Component
  scope is `pr-selected`. All selected apply groups collect coverage. PRs with
  `ci-full` use `full`. Main uses `production`. Manual runs default to `full`. This is coverage of our selected catalog, not all MySQL features.
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

Full CI collects coverage for all apply groups by default. Use `ci-full` on the
release candidate PR, or dispatch:

```sh
gh workflow run ci.yml --ref <branch-or-tag> -f suite=full
```

`ci-expanded-coverage` and `expanded_coverage=true` remain accepted aliases.
They do not repeat tests. Correctness, reconnect, recovery and demo runs export
coverage. Native-only observations do not run the replicator and have no line map.

The full plan does not repeat the PR baseline groups. Thus its report does not
claim an exact PR-baseline delta. Use the union of integration lines, exclusive
lines by area, and exclusive lines after unit coverage to identify expensive
areas for review. Retain profile, variant and behavior checks when lines overlap.

## Read coverage scope and test value

The coverage summary states the test scope and instrumentation mode. It shows
planned integration jobs, jobs that collect coverage, and collected versus
expected fixture reports. A fixture report is not a job or an assertion.
Read the scope before comparing reports. Production checks have no line coverage.
The PR comment uses the same scope fields. Its publisher runs trusted code from
main. New comment wording takes effect after that publisher change reaches main;
PR job summaries and artifacts use the code in the tested PR immediately.

The measurement artifact also contains `test-value.md`, `test-value.csv` and
`test-value.json`. These files group numbered chunks by profile, capture variant,
suite and area. Each row shows:

- Release and coverage group minutes, plus groups with coverage and total groups.
- Passed catalog keys and declared case intent in the JSON.
- Covered lines and lines added beyond the baseline groups named by the plan.
- Lines added beyond that baseline plus the unit report from the same run.
- Lines exclusive to this area among measured integration areas.

An unmeasured area has no line counts. It is not assigned zero coverage. Missing
baseline-group or unit data makes the corresponding baseline unavailable. Partial rows
can miss results. Source hashes must match before unit and integration line maps
can be compared. Line gains are not additive. Catalog keys can occur in several
rows, so their sum is not catalog coverage.

Review assertions, profile behavior and failure checks before removing a case.
Equal line coverage does not prove equal test value. Native-reference observations remain required without replicator line maps. Rust code is
not measured. SIGKILL can prevent the process from saving coverage counters.
Full CI supplies the test-suite measurements. Coverage binaries are test builds;
main builds separate production packages.

## Review the evidence

If a build fails before it saves `build.json`, the measurement report lists the
missing build record and test shards. The report remains partial, and the job
fails after it saves the report. Results without a matching build record cannot
qualify a release. Check `summary.md` and `report.json` for these failures.

Collect one complete full report on the release candidate. Compare
runner-minutes as well as elapsed time. Check build time, cache transfer, image download/load, fixture time and the longest
shards. Do not treat the delay before a dependent job starts as proven runner
queue time. GitHub step times have second-level precision.

Keep the existing release process. These measurements do not replace its required
main CI run. The release workflow must publish the exact packages from that run.
The release evidence links pre-merge full tests to the same Git tree and the
production package checks. See [release testing](RELEASE_TESTING.md).
No release rebuild is added.

## Compare selected groups locally

Use [LOCAL_TEST_COMPARISON.md](LOCAL_TEST_COMPARISON.md) to compare complete
fixture runs before changing CI groups. The report separates repeated case
executions from unique cases and named assertions. It also compares SQL cost
and optional runtime line coverage. Keep release and instrumented runs separate.
Local measurements do not include GitHub queue, download or runner setup time.

`test-value.json` also lists repeated declared case identities. The key includes
profile, variant, suite, transport and image type. The report marks prerequisite
executions and groups without explicit case lists. Use this list to choose review
candidates. A repeated identity does not prove that fixture state or restart
assertions are the same.

## Review a costly group with a small line gain

Do not keep a large group only to reach a few lines. First identify those lines
and the behavior that reaches them. `test-value.json` includes `line_details`
for every area. The report also lists `baseline_scope`, `baseline_group_ids` and
`baseline_selections`. Use these fields when comparing PR and full runs. Older
reports called the difference fields `extra_over_smoke` and
`extra_over_unit_smoke`; current reports name the actual baseline.
Each map uses source file paths as keys and line numbers as
values:

- `extra_over_baseline`: lines beyond the measured baseline selections.
- `extra_over_unit_baseline`: lines beyond unit tests and the baseline selections.
- `exclusive_integration`: lines absent from all other measured integration areas.
- `exclusive_after_unit`: those exclusive lines that unit tests also did not reach.

A null map means that a required measurement is missing. An empty map means
that the measured difference is zero. The CSV retains counts. The Markdown
report lists exact locations for areas with 1–25 exclusive lines, with unit
coverage removed when available. It orders these areas by total runner time.
Full line lists remain in JSON; the display limit does not select tests.

```sh
jq '.areas[] | select(.exclusive_after_unit_lines > 0 and .exclusive_after_unit_lines <= 25) |
    {profile, variant, complete, release_seconds, coverage_seconds, line_details}'     test-value.json
```

Read the code from `provenance.commit`, not the current working tree if it has
changed. Inspect each function and branch condition. Line coverage does not
prove that all branches ran. Check whether a unit test already reaches the line,
or whether a small operation in an existing integration case can reach it with
a useful assertion. For pure parsing or planning logic, prefer a focused unit
test. Keep database behavior checks in integration tests.

Run the replacement with matching source and image inputs. Check the exact
line sets and the behavior assertions before removing the expensive run.
Do not replace a profile-specific check just because another profile reaches
the same Swift lines. Partial reports and unmeasured groups cannot establish
that a line is exclusive across the full suite.

## Common build timing

`Build common Linux test artifacts` compiles the application, lab and tests once.
It exports the compiler index for Periphery and the coverage runtime for the
integration jobs. Unit tests and Periphery run on Linux and use the saved build.
The isolated parser check has its own small test binary in this build.

Compare the common build time, image push time, consumer pull time and test time.
The first run uses new layers because coverage, indexing and test access now use
one set of compiler options. A later run with the same inputs must reuse those
layers. Swift source changes must not rebuild Periphery, Rust dependencies, or external
Swift libraries. Rust source or fixture changes rebuild the codec stage.
`Prepare coverage runtime` checks the saved build identity; it does not compile
code. The main-branch production package build remains separate.

Unit tests now use release coverage maps. Older unit reports used debug maps.
A change in the line total across this switch does not, by itself, show a change
in test coverage. Use reports from the common build to compare test groups.

## Fixture costs and time estimates

`tools/ci_jobs.json` records conservative area estimates from successful groups
in run `40124425871`. Jobs with larger estimates start first. Areas without a
successful measurement use the declared fallback. The named DDL/DML estimates
use reverse-profile case times plus the largest observed fixture overhead in
that family, with a 20% allowance and rounding up to whole minutes. These are
scheduling estimates, not measured times for the new groups. Estimates do not
change test selection, case order, or timeouts. Update them after a successful full run.

CI runs `Prepare MySQL fixture images` before `Run tests with prepared images`.
The first step reads the profile's Compose files from the lab catalog. It pulls
the required MySQL images and builds each shared fixture image once. It does not
start containers or create data volumes. Its times appear in each group's
`job_setup` record and in the measurement report. On failure, CI also saves
`ci-setup-JOB_ID`. A failed image preparation step
stops the tests. Shared fixtures then use `--no-build --pull never`.

Shared fixtures write `fixture-lifecycle.json` with these phases:

| Phase | Work measured |
|---|---|
| `setup` | Total fixture setup |
| `fixture_files` | Certificates, evidence volume, and helper container |
| `container_startup` | Start source, native replica, and target; wait for health checks |
| `database_setup` | Seed data, users, replication configuration, and baseline position |
| `cleanup` | Remove fixture containers and volumes; copy available failure bundles |
| `coverage` | Collect and export runtime coverage |

The three setup detail phases are part of `setup`. Do not add them to the setup
total. `cases.json` records monotonic start and finish times. The report takes
the union of case intervals so nested cases count once. It excludes measured
fixture setup, cleanup, and coverage work from test execution time. Test time
still includes SQL, assertions, and required replication waits.

Each job summary and the final report show these times in seconds. The
`phase_seconds` field retains the values for each execution group. Work without
phase records appears as `unclassified`. This can include tool validation,
applier control outside a case, report generation, and adapter-specific setup.
Missing records are unmeasured, not zero. Older records do not have the interval
fields. Demo and native adapters do not yet measure all setup phases.

Check a timing change with one selected case before another full run. Use the
completed full run for timing, coverage, SQL, and assertion comparisons. Record
whether local images were cached. A cached local run does not measure cold image
downloads or GitHub runner costs. Do not remove cases from line coverage alone.
The matrix lists every selected case and dependency; job names list the profile
and test area.
