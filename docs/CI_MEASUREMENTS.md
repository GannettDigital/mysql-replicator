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
The current full plan has 108 shards and 203 expanded shards. Both full plans own
718 catalog obligations. There are 23 full-plan coverage collections and 118
expanded collections. Normal full CI instruments 9 of 108 jobs. Expanded CI
instruments 104 of 203 jobs. The other 99 jobs check the release binary.
The generated matrix is the authority if the catalog grows.

DDL and bootstrap now use two groups per profile and variant. The group
boundaries use the [PR #41 timings](../PLAN/PR41_TEST_SUITE_RESULTS.md).
This removes repeated fixture setup without removing cases. Expect fewer
coverage collections because fewer fixtures run. Check line sets and catalog
results separately; the collection count is not a coverage percentage.

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

- Release and coverage shard minutes, plus jobs measured and total jobs.
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

Collect one complete expanded report on the release candidate. Compare
runner-minutes as well as elapsed time. Check build time, cache transfer, image download/load, fixture time and the longest
shards. Do not treat the delay before a dependent job starts as proven runner
queue time. GitHub step times have second-level precision.

Keep the existing release process. These measurements do not replace its required
main CI run. The release workflow must publish the exact packages from that run.
The full-suite evidence file binds the report to the tested package checksums.
No release rebuild is added.
