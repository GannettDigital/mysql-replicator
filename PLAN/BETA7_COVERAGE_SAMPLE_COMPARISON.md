# Beta.7 coverage sample comparison

## Purpose

Compare the separate coverage sample with a combined selection on the same
current binary. The earlier [sample review](BETA7_SAMPLE_REVIEW.md) removed the
duplicate release run. It retained the coverage sample because its source map
differed from the current code.

Keep the release case owners, profile variants and transport checks. Do not
change the PR selection during this comparison.

## Selections

Use `mysql84-to-mysql57-myisam`, the default variant and SQL transport for all
runs. Use the same instrumented image and source map.

1. Run the current sample: `positive`, `ddl-modify-demo-varchar-120` and
   `ddl-index-create`.
2. Run the current 11-case forward PR coverage selection.
3. Run that selection with `ddl-modify-demo-varchar-120` and
   `database-existing-different` added. Resolve dependencies and preserve
   catalog order.

Compare the union of runs 1 and 2 with run 3. Check all missing and added
runtime lines. Compare case and assertion sets, SQL records and saved results.
An added database case is expected. No baseline case or assertion can disappear.

## Behavior under review

The historical sample added five lines beyond unit tests and the PR baseline:

- Conditional table DDL reads the existing schema (`DDL.swift:383`).
- `MODIFY COLUMN` resolves the column encoding and changes the saved schema
  (`DDL.swift:470–472`).
- Conditional database creation keeps the existing encoding (`DDL.swift:516`).

These line numbers still identify those paths in the current file. The complete
file has changed. Measure the current file instead of reusing historical counts.

`database-existing-different` verifies warning 1007, unchanged collation,
retained rows, later INSERT/UPDATE/DELETE, the SQLite checkpoint and restart.
It depends on `database-explicit`, which is already in the PR selection.
The column-change case verifies metadata, later writes, schema history, binlog
operations and restart. The next index case drops the preceding table during
setup; this reaches the conditional table-DDL path.

## Build and evidence

The local files are under `artifacts/coverage-sample-review/`. The comparison
script uses the shared CI command builder. It records each command, elapsed time,
result path, build-input digest and MySQL image contents.

The coverage build starts from a saved dependency image. The existing dependency
versions match; the current package adds ArgumentParser. The build copies the
current package, vendor code, runtime sources and Rust sources. SwiftPM checks
the inputs and rebuilds changed code. The build is outside test timing.

The host runs AMD64 containers on ARM64. Existing demo containers remain running.
Local times do not predict GitHub workflow times. Instrumented run times do not
measure release-binary performance.

## Reporting constraint

The current full-CI report treats the two PR selections as its baseline. A full-CI
selection with extra cases must have a distinct name and explicit case list. Do
not label its line coverage as PR-only coverage. The PR selection stays unchanged
until the test-group review is complete.

## Results and decision

All three runs passed on 2026-10-23 (local time), at source commit `a908204`.
The source hashes in the coverage files match the current source files. The
applier image, build inputs, MySQL image contents, profile settings and transport
match across the runs. There was no concurrent build during test measurement.

| Measurement | Baseline plus separate sample | Combined selection |
|---|---:|---:|
| Measured invocation time | 464.70 s | 374.46 s |
| Fixtures | 2 | 1 |
| Unique cases | 12 | 13 |
| Case executions | 14 | 13 |
| Unique recorded check IDs | 26 | 29 |
| Recorded check executions | 33 | 29 |
| Harness SQL calls | 1530 | 1304 |
| Harness SQL time | 206.11 s | 177.52 s |
| Executable runtime lines mapped | 20,852 | 20,852 |
| Runtime lines reached | 10,649 | 10,649 |

The sample took 156.74 seconds. The original baseline took 307.96 seconds.
The combined selection saved 90.24 measured seconds (19.4%) and 226 SQL client
calls. This is one local comparison, not a repeated benchmark or a GitHub timing
claim. Do not use its 374-second time as the PR target: the PR selection did not
change, and the host uses AMD64 emulation.

There are **no missing cases, missing assertion IDs, lost runtime lines or added
runtime lines**. The added case is `database-existing-different`. It adds its
case record and two named assertions. The comparison therefore correctly reports
that the complete case/assertion sets differ. No previous check is lost.
Recorded check IDs include case records and named assertions. They do not count
every inline Swift assertion.

All 11 saved result comparisons match exactly: schema effects, following DML,
schema history and normalized binlog operations for both sample index cases,
plus the source/native/target operation lists for `positive`. Source-boundary
assertions passed in each run. GTIDs and offsets differ between fixtures and
are not compared as literal values. Per-case restart checks remain unchanged.

The sample adds the same 33 lines beyond the current forward baseline as in the
historical analysis:

| File and lines | Behavior | Retained check |
|---|---|---|
| `DDL.swift:383` | Read the schema for an existing table in conditional DDL | The second index case drops the first case's table through replication |
| `DDL.swift:470–472` | Resolve the modified column encoding and schema | `ddl-modify-demo-varchar-120` |
| `DDL.swift:516` | Keep the database's existing encoding | `database-existing-different`, with explicit metadata and data assertions |
| `DDLParser.swift:885–893` | Parse `MODIFY COLUMN` | `ddl-modify-demo-varchar-120` |
| `SchemaChanges.swift:44–45,47–49,52–59,64–69` | Apply the column modification to the schema | `ddl-modify-demo-varchar-120` |

The combined selection reaches all 33 lines. No current unit-test subtraction
is claimed; this comparison uses instrumented integration runs only. Historical
unit coverage is described separately in the first review.

Replace the separate forward coverage sample with the combined selection in
full CI. Keep all release groups and the two 11-case PR selections unchanged.
Use `full_coverage_extensions` to declare the two added cases. The full forward
area is `ddl-dml-conditional-schema-policy-replay`. Its distinct ID prevents it
from being reported as the unchanged PR selection.

## Plan and report checks

| Plan | Groups before → after | Jobs before → after | Coverage collections before → after |
|---|---:|---:|---:|
| Full | 245 → 244 | 129 → 129 | 23 → 22 |
| Expanded | 478 → 477 | 246 → 246 | 256 → 255 |
| PR | 2 → 2 | 2 → 2 | 2 → 2 |

All 2,095 full catalog obligations remain. Every release group and every retained
coverage group is identical to its earlier definition. Only the two forward
coverage groups are replaced with the measured combined selection. The generated
case order matches the tested command.

The index component still has 53 groups in 22 jobs. Its coverage selection adds
the conditional-database check, so its obligations increase from 278 to 279.
Offline, JSON YEAR and reconnect component plans keep their group and obligation
counts. Component selection matches only the additional cases when deciding
whether to include a full-CI coverage extension. Shared PR cases alone do not
add a second fixture.

The report reads baseline group IDs from `coverage_baseline_groups`. It lists
the scope and exact case lists. The difference fields are now
`extra_over_baseline` and `extra_over_unit_baseline`. They describe the actual
baseline, which differs between PR and full CI. Old saved plans without this
field still use the two historical PR group IDs. Missing measurements remain
unmeasured, not zero.

The 67 focused Python tests passed: matrix, component selection, job assignment,
runner, coverage-value report and measurement checks. The full database suite
was not run. Runtime and harness Swift code did not change.

## Evidence files

- `build.log` and `build-label.log`: successful build and cached label update.
- `Dockerfile`: local build from the saved dependency layer and current sources.
- `plan.json` and `run.py`: tested selections, source revision and commands.
- `sample.json`, `baseline.json`, `combined.json`: measurements and result paths.
- Matching log files and referenced lab results, including coverage exports.
- `comparison/`: timing, case, assertion, SQL and exact line-set comparison.
- `line-review.json`: verified source hashes and all 33 extra line locations.
- `assertion-comparison.json`: all 11 saved result comparisons.
- `before-plans.json`, `after-plans.json` and `plan-diff.json`: complete CI plan
  comparison, with unchanged release groups and PR selection.

## Next review

Use the same rule for other costly groups: identify the exact extra paths and
check their assertions before changing selection. Prefer one small case in an
existing fixture over a separate fixture for a few paths. Do not remove an
engine, version, transport, restart or failure check because its line coverage
overlaps another check.

Fresh expanded beta.7 coverage is still needed to rank the other groups. The
historical report can identify candidates, but it cannot prove that current
coverage is retained. Leave the final PR case selection until this review is
complete.
