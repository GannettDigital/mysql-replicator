# Full test suite: coverage and cost review

## Evidence

This review uses PR #40, run [38165244447](https://github.com/GannettDigital/mysql-replicator/actions/runs/38165244447), attempt 1.
All checks passed. The head commit was `b6b4d7d6b7c82b3ecbb98d8d67e4a355fc04843e`.
CI tested merge commit `bcaca28113cdb3509e5e8b6d2775bee9de4b617b`.

Read these artifacts to reproduce the review:

- `ci-measurement-report`: `summary.md`, `report.json`, and `test-value.*`.
- `ci-lab`: the exact `matrix.json` used by the run.
- The 116 `ci-measurement-coverage-*` records: line sets and case times.
- The combined coverage artifact: unit and integration line sets.

Local copies are in `artifacts/ci/pr40-expanded-analysis/` in this worktree.
That directory is ignored by Git. `analyze.py` in that directory compares the
line sets. The tables below preserve the main results after CI artifacts expire.

The run passed all 718 catalog obligations. It ran 227 integration jobs.
Of these, 116 jobs collected coverage from 130 fixture runs.
The measurement report recorded 913.9 completed runner-minutes.
Runner-minutes are the sum of job times, not elapsed time.

The normal full suite has 120 integration jobs. Expanded coverage adds 107
instrumented copies of correctness and lifecycle jobs. It retains the 111
release-binary jobs. The normal full suite collects coverage from nine jobs.

## What coverage measures

All rows below use the same 7,469 mapped first-party Swift runtime lines.
The reports exclude Rust, dependencies, and lab code. Coverage comes from an
instrumented binary. It does not measure the static release binary.

| Selection from this run | Lines hit | Coverage |
|---|---:|---:|
| Unit tests | 5,644 | 75.57% |
| Two PR smoke suites | 4,851 | 64.95% |
| Normal full coverage selection: four smoke suites, demos, sample | 5,437 | 72.79% |
| Expanded integration selection | 6,814 | 91.23% |
| Unit tests and expanded integration | 7,255 | 97.13% |

The full suite adds 1,377 integration lines over the normal coverage selection.
It adds 537 lines that unit tests and the two PR smoke suites do not hit.
The earlier 72.79% result did not measure most full-suite jobs.

The two smoke suites hit 4,851 lines in this run. Do not use the 4,884 lines
from PR #36 as the baseline for this comparison. Timing-dependent paths can
change between runs. The line-set comparisons here use one source revision.

There are 214 unhit lines in combined coverage. These include 90 CLI lines,
20 blackhole-run lines, 18 DDL-token lines, and 16 apply-run lines. Review the
actual paths before adding tests. A line count does not identify a missing
behavior by itself.

## Code paths by test area

The extra-line column compares each area with unit tests and the two PR smoke
suites. Areas can add the same lines. Do not add that column to get a total.
Exclusive lines are absent from all other measured integration areas.
Times below are shard minutes. They exclude some CI job overhead.

| Area | Extra lines | Exclusive integration lines | Release minutes | Coverage minutes |
|---|---:|---:|---:|---:|
| Failure, recovery, offline | 247 | 541 | 24.5 | 25.3 |
| DDL | 138 | 234 | 52.5 | 53.1 |
| Foreign keys | 119 | 119 | 7.3 | 7.8 |
| Collation | 67 | 20 | 5.0 | 4.7 |
| Database | 64 | 0 | 19.3 | 18.4 |
| Demo | 63 | 398 | — | 21.3 |
| Reconnect | 61 | 69 | 17.8 | 18.0 |
| Ordered DDL | 49 | 1 | 22.4 | 24.1 |
| Refusals | 24 | 9 | 19.3 | 19.7 |
| Indexes and column changes | 18 | 4 | 100.6 | 105.9 |
| DML | 8 | 0 | 29.3 | 28.9 |
| Bootstrap | 8 | 0 | 56.1 | 57.3 |
| Sample | 3 | 0 | 2.8 | 2.4 |
| Filters and discovery | 0 | 0 | 10.9 | 10.6 |

Native-reference and specialized recovery adapters do not collect coverage.
Their coverage is unknown, not zero. Keep their behavioral checks.

The DML and bootstrap suites reuse type fixtures. They test different paths.
DML tests changes during replication. Bootstrap tests schema discovery from
existing tables with fresh state at phase boundaries. Rust decoding can also
differ without a change in Swift line coverage.

The index area tests column changes, clone and rename operations, index changes,
and unique keys with NULL values. It checks more than target rows. It also checks
schema history, checkpoint positions, counters, and normalized binlog events.
Keep these assertions. Consider a clearer area name in a later change.

The demos test operator workflows. Removing all demo jobs would lose 398
integration lines. Unit tests cover most of these, but 38 would remain unhit
in combined coverage. Keep the demo checks.

## Profiles and capture variants

| Profile | Passed catalog obligations | Integration lines | Lines exclusive to this profile |
|---|---:|---:|---:|
| `mysql57-to-mysql57-innodb` | 118 | 6,556 | 0 |
| `mysql57-to-mysql57-myisam` | 116 | 5,902 | 0 |
| `mysql57-to-mysql84-innodb` | 118 | 6,601 | 54 |
| `mysql84-to-mysql57-myisam` | 366 | 5,958 | 77 |

The two cross-version profiles together hit all 6,814 integration lines.
This does not prove that the same-version profiles are redundant. The same
applier code can produce different results on different MySQL versions or
storage engines. Keep all four profiles in release testing.

The forward profile runs three capture variants. File-position capture adds
14 lines beyond the other variants in this run. GTID capture without a supplied
file position adds four exclusive transport-error lines. Small line differences
do not remove the need to test startup positions, optional metadata, and
reconnect behavior. Keep all three variants during this reorganization.

## Cost findings

Shared lab, release, and coverage build jobs took about 51, 131, and 19 seconds.
Compilation is not the main cost in this run.

Indexes, bootstrap, and DDL used about 209.2 release shard minutes. This is
about 56% of the 374.5 release shard minutes. Start optimization there.

Most correctness shards have a 60–80 second difference between shard time and
the sum of their selected root-case times. This difference can include fixture
setup, cleanup, common checks, and coverage export. It is not a measurement of
Docker startup alone. Nested case times overlap and must not be added again.

`SharedCorrectness.step` waits for replication and compares all three servers.
`SharedCorrectness.compare` collects database, table, column, foreign-key,
index, partition, and row data. `NativeHarness.sql` starts a new
`docker compose exec ... mysql` process for each call. A comparison makes
approximately seven calls per server when it also reads rows.

The index cases repeat database creation and four individual table drops before
their main workload. Each step performs a comparison. Some setup methods also
run when their family has no selected cases. These are candidates for reducing
work, but their existing checks must first have explicit replacement coverage.

## Proposed work order

### 1. Compare assertions before removing tests

Zero exclusive lines means that other tests execute the same Swift lines.
It does not mean that a test has zero value. Compare inputs, starting state,
expected results, intermediate checks, and failure behavior before calling two
tests duplicates.

| Candidate | Assertion review | Decision for the first follow-up PR |
|---|---|---|
| Replicated DML and bootstrap DML | Both use the 18 type/workload fixtures in `DMLCompatibilityCases`. Replicated DML applies CREATE and subsequent changes through a continuous applier. Bootstrap creates equivalent snapshots without logging, then uses fresh state for each phase. It tests discovery, independent expected values, exact bytes, and durable stop positions. | Keep both. The starting state and discovery path differ. Do not use equal line coverage as a reason to remove a type fixture. |
| `positive` and DML matrix | `positive` also checks direct YAML passwords, exact transaction/row counts, target identity, completed row intents, target read counts on MyISAM, and an independent binlog sequence. | Keep `positive`. The matrix does not replace all its assertions. |
| `sample` CI jobs | The job selects `positive`, `ddl-modify-demo-varchar-120`, and `ddl-index-create`. All three run elsewhere. The sample has no separate cross-case assertion. It does exercise their combination in one fixture. | Mark as a likely duplicate job. Keep it during the first comparison run. Review the shared-fixture effect before later removal. |
| Extra same-version smoke jobs | They repeat selected full-catalog cases in smaller fixtures. They own no additional catalog keys. | Keep during measurement. Reassess when the explicit PR selection is defined. |
| Indexes and ordered DDL | They share DDL operations, but index cases check schema history and following DML per change. Ordered DDL checks a dependent lifecycle sequence. Both retain independent binlog checks. | Keep both. Audit repeated setup separately from the workload assertions. |
| Filter and discovery tests | These add no exclusive lines in this run. They check excluded mutations, saved-state resume, native/target operations, and schema-drift refusal. | Keep the behavior checks. |

Reviewed code: `SharedBootstrapDML.swift`, `SharedCorrectness.swift`,
`SharedCatalogSupport.swift`, `SharedOrderedDDL.swift`, and `tools/ci_matrix.py`.
Catalog keys identify scenarios. They do not enumerate every assertion inside
those scenarios. Keep the assertion review with any later removal change.

#### Binlog comparisons and intermediate state

The basic DML, index, ordered DDL, and filter workflows already use independent
binlog comparisons. The parsers have fixture-specific limits. They are not a
complete binlog oracle for every DML type.

A final row snapshot can miss an extra INSERT followed by a DELETE. A normalized
operation sequence can detect that error. Collect source, native, and target
binlogs after a case has reached a known boundary. Compare the ordered logical
operations in that bounded interval. Ignore server IDs, timestamps, positions,
and local GTIDs only through explicit normalization rules. Do not ignore row
values or unexpected operations. Preserve transaction boundaries where the
profile requires them. Account for profile-specific changes, such as engine
selection and collation mapping, explicitly.

Binlogs do not replace checks of durable intents, rollback, excluded writes,
schema drift, generated values, or intermediate schema publication. Keep those
checks at their required boundaries. A target binlog also cannot prove that an
unlogged write did not occur. Keep exact row and metadata comparisons.

Extend the independent parsers by fixture family before using them to remove
snapshot checks. Do not use the production decoder as its own reference.
The first follow-up PR retains the existing binlog checks without extending the
parser contract or moving assertions to the end of a whole suite.

### 2. Reduce assertion transport cost

First record SQL-call counts and elapsed time for representative index, DDL,
and bootstrap shards. Separate SQL-client startup from fixture and applier time
where practical.

Collect multiple schema queries in one client call, or use a reusable test
connection. Preserve query results, exact row bytes, NULL handling, ordering,
and per-step evidence. Some row queries depend on metadata results, so one
call for the entire comparison might not be practical.

Keep replication waits and comparison boundaries. Do not replace checks after
each DDL operation with one final comparison. Keep fresh bootstrap state and
the intended restart checks. Do not cache schema results across DDL changes.

Guard unrelated family setup only after identifying any downstream dependency.
Do not change application SQL to make the test harness faster.

#### Balance shards by measured time

The matrix currently uses fixed case counts. DDL uses three shards per
profile/variant. Bootstrap also uses three. Indexes uses four.

A model that keeps case order and splits DDL and bootstrap into two balanced
shards gives these maximum shard times:

- DDL: approximately 217–274 seconds across profile/variant combinations.
- Bootstrap: approximately 243–267 seconds across profile/variant combinations.

The model sums measured root-case times and adds the median residual time for
that profile and area. It excludes additional CI job overhead. It assumes that
regrouping does not change case time. Validate this assumption in CI.

These two changes would remove 12 release jobs and 12 expanded-coverage copies.
With later supplement removal, the candidate matrix would have 104 normal full
jobs or 199 expanded jobs. Do not remove supplements in the first optimization
PR. Treat these counts as a proposal, not an acceptance target.

Keep index shards split. Their current times are already near five minutes.
Keep ordered scenarios intact. Do not split a case between jobs. Review long
failure/recovery shards separately; some currently take more than seven minutes.
Do not combine all tests into one serial job per profile.

Use checked-in timing weights or explicit reviewed groups. Do not make test
selection depend on a CI artifact that can expire. Preserve dependency closure
and exact catalog ownership in `tools/ci_matrix.py`.

### 3. Reassess after measurement

Run the release suite and expanded coverage on the revised structure. Compare
line sets, catalog keys, assertion output, job times, and runner-minutes.
Use more than one run before making firm timing claims.

Only then consider reducing profile/variant combinations for individual cases.
That requires a behavior and assertion inventory. Swift line overlap alone is
not sufficient evidence. Rust coverage would improve a later decoder review.

### 4. Select explicit PR tests after optimization

Use the assertion review below before removing any supplement. Its case IDs already run
in the full suite. The sample jobs are candidates for removal from full CI. Keep the sample command available for local use if it remains useful.

Review the two same-version smoke supplements for removal from full CI. Keep the two PR
smoke suites in full CI to provide a comparison from the same run. Keep all
four profiles' full correctness, lifecycle, and demo tests.

A joint line-set simulation removes these four jobs without losing any of the
6,814 integration lines. They own no catalog obligations. This would change
normal full CI from 120 to 116 jobs, and expanded CI from 227 to 223 jobs.
The four jobs used 12.2 shard minutes in this run. This is a small saving.

After the full suite is organized and measured, select PR cases explicitly.
Target about five minutes with a warm build cache. Publish the case IDs,
profiles, variants, prerequisites, and assertion purpose in the plan and report.
Use descriptive job names. A label such as `smoke` alone does not state what ran.
The existing `--case` and `--family` options already provide explicit selection.
Keep one catalog as the source for PR and full selections.

## Acceptance conditions

- Keep the exact 718 catalog keys, including profile and variant. A matching
  total alone is insufficient.
- Keep the existing assertions and evidence, or document and test each explicit
  replacement. Keep source, native, and target comparisons.
- Keep release-binary verification as the default full-suite contract.
- Keep expanded instrumentation optional for suite analysis.
- Compare source-matched line sets globally and by profile/variant. Investigate
  lost paths. Do not hide them with coverage added by an unrelated area.
- Keep failure evidence and support bundles available.
- Report elapsed CI time and runner-minutes separately. Preserve parallel jobs.

The first follow-up PR keeps the matrix and case selections unchanged. It groups
metadata reads at each comparison boundary and adds SQL-call measurements.
Keep row comparisons, waits, restarts, and binlog assertions at their current
boundaries. Use full CI with expanded coverage to measure the result.

## First follow-up: local validation

The query grouping passed 85 lab unit tests and 41 CI-tool tests.
The generated expanded matrix matches the PR #40 matrix. It retains the same
718 obligations and all 227 shard selections.

| Local selection | Result | Metadata queries / client calls | All measured client calls |
|---|---|---:|---:|
| 8.4 → 5.7 MyISAM: `ddl-index-create` | Passed, including binlog and restart checks | 252 / 42 | 254 |
| 5.7 → 8.4 InnoDB: `ddl-compat-generated`, `ddl-index-create` | Passed, including generated values and binlog checks | 396 / 66 | 369 |

This saves five client launches for each metadata batch. It does not reduce
the six metadata queries or remove comparison steps. The local runs establish
behavior on both server versions. They are not a controlled CI timing comparison.
Compare the next full CI run with PR #40 before claiming an elapsed-time saving.
