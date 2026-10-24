# Beta.7 sample-group review

## Scope and decision

This file records the first review. The later
[current coverage comparison](BETA7_COVERAGE_SAMPLE_COMPARISON.md) completes the
follow-up and replaces the separate coverage sample with one combined selection.

Review the release and coverage sample groups against the cases already owned
by full CI. The source baseline is commit `9ec476b`. All compared groups use
`mysql84-to-mysql57-myisam`, the default variant and SQL transport.

The focused release comparison passed. Remove only
`release-mysql84-to-mysql57-myisam-default-sample`. Keep the three cases in their
full release groups.
Keep `coverage-mysql84-to-mysql57-myisam-default-sample` with its original cases
and collection count. Removing a release execution does not remove a coverage
collection.

## Case and assertion review

| Sample case | Retained release group | Checks retained |
|---|---|---|
| `positive` | `dml-6` | Four row changes; source/native/target rows and normalized binlog operations; source GTID preservation; read-call count; SQLite checkpoint, row intents and target identity |
| `ddl-modify-demo-varchar-120` | `indexes-1` | Changed column metadata; retained data; following INSERT/UPDATE/DELETE; warnings; source boundary; saved schema history; normalized binlog operations; restart |
| `ddl-index-create` | `indexes-2` | Index metadata; retained data; following INSERT/UPDATE/DELETE; warnings; source boundary; saved schema history; normalized binlog operations; restart |

The index cases use the same definitions in
[ModifyIndexCases.swift](../Sources/ReplicatorLabCore/ModifyIndexCases.swift).
[SharedCorrectness.swift](../Sources/ReplicatorLabCore/SharedCorrectness.swift)
recreates their seed tables through replication before each case. It checks five
named assertions: `schema-effects`, `following-dml`, `source-boundary`,
`schema-history` and `normalized-binlog`.

Each index case drains the applier, inspects the saved state, then restarts from
that state before the case completes. This is in addition to the common restart
at the end of the group. The earlier group-level review did not identify these
per-case restarts. Both full index groups retain them. The separate
`ddl-index-resume` case also remains in the catalog; it tests a write after
restart and refusal of external schema drift.

The sample does not test coexistence of the two changed tables. The second
index case drops the first case's table during its normal seed setup. The full
groups execute the same seed, mutation, assertions and restart for each case.
They also check the common final checkpoint and saved-schema restart.

[SharedBootstrapDML.swift](../Sources/ReplicatorLabCore/SharedBootstrapDML.swift)
implements `positive`. It seeds its own `poc.items` table and uses a separate
SQLite state directory. Its four-transaction workload and expected operations
do not depend on the two index cases. Its assertions are inline in the case,
so a count of named assertion IDs alone would omit them.

## Local comparison

Run the original sample and its three retained groups, using their complete
case lists from the generated CI plan. This is four focused fixture runs, not
the full suite. Compare their union with the three retained groups alone.
Use matching applier images, MySQL image contents, settings and build inputs.
Also compare the saved index schema history and normalized binlog operations
for the three repeated cases. Retain the original logs and results.

The release image was already built. MySQL fixture setup uses cached Compose
layers. The host uses AMD64 images under ARM64 emulation, with existing demo
containers still running. These times measure local execution cost. They do
not predict total GitHub workflow time.

## Local results

All four focused invocations passed on 2026-10-23 (local time). The comparison
accepted matching build inputs, applier image, MySQL image contents and settings.

| Measurement | Sample plus retained groups | Retained groups only |
|---|---:|---:|
| Sum of invocation times | 842.85 s | 697.41 s |
| Fixtures | 4 | 3 |
| Unique cases | 16 | 16 |
| Case executions | 19 | 16 |
| Unique recorded check IDs | 76 | 76 |
| Recorded check executions | 89 | 76 |
| Harness SQL calls | 3011 | 2513 |

The removed sample cost 145.44 seconds and
498 SQL client calls locally. The table sums measured group costs; it is not an
independent before/after workflow benchmark. Both columns reuse the same retained
group measurements. It does not predict the change in GitHub elapsed time.

No case or recorded check ID is missing from the retained union. Recorded check
IDs include case records and named assertions. The source review also checked
the inline DML assertions that have no separate IDs.

All 11 compared JSON results match exactly: schema effects, following DML,
schema history and normalized binlog results for both repeated index cases,
plus source/native/target operation lists for `positive`. Source-boundary checks
passed independently in each fixture. Their GTIDs and file offsets differ and
are not compared as literal values.

The focused Python checks passed: 20 matrix, 6 job assignment, 9 component
selection, 13 runner, 8 test-value report and 8 measurement tests (64 total).
No full database suite was run. No fresh beta.7 line coverage was collected.

## CI plan validation

The before/after plans differ by exactly one execution group: the release
sample. Every retained group is identical, including case order, variants,
transport, image type and coverage requirements. The full catalog still has
2,095 case/profile/variant obligations.

| Plan | Groups before → after | Jobs before → after | Coverage collections |
|---|---:|---:|---:|
| Normal full | 246 → 245 | 130 → 129 | 23 → 23 |
| Expanded coverage | 479 → 478 | 247 → 246 | 256 → 256 |

The two-profile PR baseline is unchanged. Component-selected index checks lose
the same duplicate execution: 54 → 53 groups, still 22 jobs and 278 obligations.
Other component plans are unchanged. This change does not remove a database
assertion, profile or capture variant.

## Coverage follow-up

The old beta.6 report showed a small sample line gain, but its source differs
from beta.7. Do not use its line counts to remove current coverage runs.

A local coverage-build retry restored the saved dependency directory but began
recompiling dependencies. It was stopped before the release measurements.
No fresh coverage result is claimed. Keep the coverage sample until a matching
comparison identifies its exact extra lines and shows where they are retained.

The test-value report now saves exact file/line maps for each coverage difference.
It also subtracts unit coverage from lines absent in other integration areas.
Review those functions and branches. Move a small requirement into a focused
unit test or an existing integration case when that retains the behavior check.
Measure the replacement before removing the costly group. Low line counts alone
do not justify removal. See [the reporting guide](../docs/CI_MEASUREMENTS.md#review-a-costly-group-with-a-small-line-gain).

## Exact lines from the earlier report

The saved run is [39509695777](https://github.com/GannettDigital/mysql-replicator/actions/runs/39509695777),
commit `35fd687b77730f4cb9e9c7b558716d56592bf7df`. Its nine measured integration
groups contain 23 coverage collections. All passed and use the same source map.
The unit report has the same source map. The downloaded `DDL.swift` hash matches
the hash recorded in coverage. These are historical results, not fresh beta.7
coverage. The current complete file has changed.

| Historical location in `Sources/ReplicatorApply/DDL.swift` | Behavior | Existing test that can supply the behavior |
|---|---|---|
| 383 | Read the existing table schema for conditional table DDL | The second index case drops the preceding case's table with `DROP TABLE IF EXISTS`; full `indexes-1` and `indexes-2` retain this setup |
| 516 | Keep the existing database encoding for conditional CREATE | `database-existing-different` and `database-existing-matching` explicitly check this behavior |
| 470–472 | Resolve a modified column's encoding and produce its schema | `ddl-modify-demo-varchar-120` in full `indexes-1` |

Lines 383 and 516 were absent from all other measured integration areas and from
unit tests. The MODIFY lines were reached by other measured areas, but not by
unit tests plus the two PR selections. Of the sample's 33 lines beyond the PR
baseline, unit tests already reached 28. This leaves five lines to examine,
including the two integration-exclusive lines.

The two exclusive paths arise from fixture setup in the sample. This is why we
must inspect code and SQL instead of treating the sample's name or its three
case IDs as its unique purpose. The existing database cases have stronger
explicit assertions for preserving encoding and data.

For the next matching coverage run, inspect the database and index groups first.
A small selection of existing cases is sufficient to investigate these paths;
there is no need to rerun the whole suite merely to locate them. If a normal-CI
coverage group still needs these paths, add the smallest relevant case to an
existing instrumented selection, measure it, and retain the behavior assertions.
Do not add a test that asserts nothing simply to increase the line count.

## Evidence

Local files are under `artifacts/sample-review/` in this worktree:

- `plan.json`: baseline commit, build-input digest and the four original groups.
- `run.py`: commands generated through the CI command builder.
- `sample.json`, `dml-6.json`, `indexes-1.json`, `indexes-2.json`: recorded runs.
- Matching `.log` files and referenced lab result directories.
- `comparison/`: the original union versus the retained union.
- `compare_assertions.py` and `assertion-comparison.json`: exact comparison of
  11 saved schema, row and binlog result files.
- `plan-diff.json`: exact group and catalog comparison for both CI modes.
- `coverage-build.log`: the stopped dependency-build retry.

- `old-ci-records/`, `old-ci-unit/`, `DDL.beta6.swift` and `old-line-review.json`: historical line sets, matching unit coverage and verified source.
