# Beta.7 integration grouping proposal

The next implementation sequence is in
[Test suite consolidation](BETA7_TEST_SUITE_CONSOLIDATION.md). This file retains
the measurements and case review that support that plan.

## Decision basis

Use full run `40170659705`, at commit
`d416c21e12729ff70b3f21b91caa079f656160c4`. All 250 integration groups passed.
All 263 expected integration coverage collections are present. Unit coverage is
missing because the unit job was cancelled. The runner timing changes are in
commit `e92b8ac`.

This work changes group boundaries, not selected cases. The saved records are sufficient for
the first review. Do not start another full workflow to collect the same data.

Compare SQL, runtime line sets and assertions together. Equal line sets do not
prove equal branch behavior, input values or failure detection. Retain profile,
capture variant, SQL/BINLOG transport and required restart boundaries.

## Coverage and SQL overlap

The comparison uses SQL correctness groups in the default variant of each of
the four profiles. It checks the source commit and coverage source digest.
Coverage from different groups is combined as a set, not added as a count.

| Group A | Group B | A's runtime lines also reached by B | Interpretation |
|---|---|---:|---|
| Bootstrap, both groups | All replicated-DML groups | 100% on three profiles; 96.8% on 5.7 to 8.4 | Much of the runtime code is shared. Schema discovery from existing tables remains a separate condition. |
| All index groups | DDL columns and keys | About 99.6% on all four profiles | Review repeated setup and comparisons. Keep index-specific SQL and journal/binlog assertions. |
| Index group 1 | Index group 2 | 100% on all four profiles | Strong candidate for fixture consolidation; not proof that the first group's inputs are redundant. |
| Index group 3 | Index group 4 | About 98% on all four profiles | Similar execution cost and setup; keep the distinct index operations. |
| Numeric/temporal DML | Row-operation DML | 90.3–91.0% | The raw overlap includes a large common runtime base. Do not remove type cases from this number. |

For the reverse profile, 6,616 lines are reached by every default SQL correctness
group. These are common lines, not a measured setup-only baseline. After removing
that common set from the comparison, numeric/temporal overlap with row operations
is 51.7%. It is 35.6–52.4% across all four profiles. Numeric tests have 728–793
lines not reached by the row-operation group, including numeric conversion,
floating-point SQL and column-type handling.

The reverse bootstrap groups reach 376 lines not reached by the replicated-DML
groups. Sixty are absent from all other default SQL correctness groups in that
profile. They include expression parsing and expression-dependency checks for
8.4 target metadata. The exact source locations are saved in `overlap.json`.
Do not treat the entire bootstrap area as redundant.

The index groups reach 31 lines not reached by the columns-and-keys group.
Five are absent from the other default SQL correctness groups in each profile.
These are in `SchemaChanges.swift`, including column placement and primary-key
nullability handling. Keep their input cases and assertions when consolidating.

SQL evidence supports a review of repeated harness work:

- `dml()` and `bootstrapDML()` both use `DMLCompatibilityCases`: the same type
  definitions, source DML phases and expected values. The first starts with
  replicated CREATE statements. The second creates equivalent table snapshots
  and starts each nonempty phase with a fresh applier state. That difference is
  the reason to retain both modes.
- In the reverse profile, index groups 1 and 2 share 14 of their recorded SQL
  fingerprints, matched by server role and exact SQL. The matched calls take
  57.9 and 59.0 client-seconds in the two groups. These are costs to inspect,
  not promised savings. The same read can verify different state after a write.
- Each index case repeats table cleanup, source/native/target comparisons,
  saved-state checks and normalized binlog comparisons. The SQL operations
  differ between cases. Consolidation can remove fixture setup while keeping
  these assertions.

Only the 20 most expensive repeated SQL fingerprints per group are in the CI
measurement files. A missing match does not show that SQL is unique. Detailed
SQL traces are needed before removing a specific call. There is no unit coverage
baseline for this run, so this report does not claim that unit tests replace any
integration check.

## First optimization: remove repeated baseline work

`SharedCorrectness.Run.execute` starts the main applier for every selection.
It then calls the database and DML runners. These runners each create a baseline
database even when none of their named cases is selected. It also drains the
main applier, checks SQLite, restarts it, inserts a row into `reverse_poc.aux`,
and drains it again before it runs cases with separate applier states.

Thus, a bootstrap-only group also runs the generic CREATE DATABASE and restart
sequence. Its selected cases then create their own equivalent table snapshots
and fresh state directories. The coverage overlap and this code inspection
identify repeated baseline work; they do not identify redundant type cases.

Make setup requirements explicit before changing this path:

1. Identify cases that use the main applier and cases that create their own
   applier state. Keep the database and native-replication prerequisites for both.
2. Run the main-applier setup and saved-schema restart checks when selected cases
   use that state. Keep the restart checks after real DDL and DML: they verify
   the schema history written by those cases.
3. For selections that only use separate states, omit the unrelated main-applier
   CREATE/restart sequence. Keep every selected case's cold discovery, checkpoint,
   failure and resume checks.
4. Compare one affected bootstrap selection before and after the change. Check
   SQL, assertions and exact lost runtime lines. Lines lost only from baseline
   work must still be exercised by a named retained test.

Do not change every bootstrap phase into a saved-state resume to save process
startup. That would replace cold schema discovery with a different condition.

## Group boundaries after that change

Use explicit case lists and descriptive names. Keep catalog order inside each
group. A group is one fixture invocation; each CI job continues to run one group.
Putting several isolated fixture invocations into a job would retain container
restarts and hide their separate cost.

The first candidate does only two things:

| Area | Current groups per full profile/variant | Proposed groups | Estimated group time |
|---|---:|---:|---:|
| Index and MODIFY cases | 4 | 2: column modifications; index changes | 4.1–5.7 min |
| Bootstrap | 2, with a 4–17 min imbalance | 3: encodings/defaults; numeric/temporal; structured values, rows and target metadata | 5.7–8.0 min |

This changes the full plan from 250 to 240 groups. It retains all 2,095 catalog
obligations and the exact multiset of profile/variant/suite/transport/case
executions, including dependency executions. Expected coverage collections
change from 263 to 253 because there are fewer fixture reports. This count is
not a claim about the number of runtime lines covered.

Estimates sum saved top-level case times and add the median time outside named
cases for the same profile, variant, suite and transport. They are planning
estimates, not new measurements. Table accumulation can increase comparison
cost. Removing repeated baseline work can decrease it. Do not use estimates as
test timeouts or as evidence that coverage is unchanged.

A second candidate combines numeric/temporal and row-operation DML, then splits
the long columns/keys and foreign-key groups. It has 244 groups in total, with
the same execution multiset. The proposed DML groups take about 3–4 minutes for
full variants. The new DDL groups are estimated at about 5–8 minutes. The small
`without-source-gtids` selections remain shorter. This candidate reduces the
longest groups; it does not minimize the job count.

Keep lifecycle, crash recovery, demo, native-only observations and BINLOG checks
separate. Keep all four profiles and the declared capture variants. Do not split
an ordered DDL workflow or its intermediate comparisons.

## Evidence and next change

Local analysis files are in `artifacts/ci-grouping-proposal/`:

- `overlap.py` and `overlap.json`: same-profile coverage and exact SQL fingerprint
  comparisons, with the source locations of lines found only in one set.
- `propose.py`: builds candidate plans from the saved catalog without starting
  containers. It checks exact selected-execution counts against the old plan.
- `first-policy.json`, `first-plan.json`, `second-policy.json`,
  `second-plan.json` and `comparison.json`: explicit case lists and estimates.

Recommended order: remove unrelated baseline work from isolated-state selections,
consolidate the index groups, then balance bootstrap. Reassess the second candidate
after the affected local comparisons.

## Implementation

The first candidate is implemented in `tools/ci_matrix.json`. The current lab
catalog produces 240 jobs, 240 groups and 253 coverage collections. A comparison
with the saved plan confirms all 2,095 obligations, applicability rules, declared
dependencies and selected execution counts are retained. `tools/ci_jobs.json`
uses the latest recorded group times and the estimates for the new groups.
Job and group timeouts are unchanged.

The setup change is limited to the reviewed bootstrap cases. They declare
`requires_main_applier: false` in the catalog. Other cases default to the existing
setup. Mixed selections, unknown cases and legacy slices keep the main applier.
This prevents a new test from silently losing setup it needs. Results state
whether the main applier was required and whether its saved-schema restart ran.

Each bootstrap DML phase still has its own fresh state, source SQL, row comparison
and checkpoint check. The four 8.4 target-metadata cases retain their explicit
restart, replay and refusal checks. Other separate-state workflows retain their
baseline until their prerequisites receive the same review. No selected case or
per-case assertion has been removed. No full local suite or full CI run was started.

### Focused local comparison

Run `bootstrap-matrix-composite` and `bootstrap-matrix-typedjson` together before
and after the setup change. Run `ddl-modify-primary-widen` and `ddl-modify-first`
in separate fixtures before the change, then in one fixture after it. These
MODIFY cases came from different index groups and now share the column-modification
group. All five invocations passed on `mysql57-to-mysql84-innodb`, default variant,
SQL transport, with runtime coverage.

| Measurement | Bootstrap before | Bootstrap after | MODIFY separate | MODIFY combined |
|---|---:|---:|---:|---:|
| Complete invocation time, seconds | 172.58 | 147.59 | 216.68 | 146.65 |
| Selected case time, seconds | 82.62 | 84.48 | 74.09 | 73.04 |
| Fixtures | 1 | 1 | 2 | 1 |
| SQL client calls | 198 | 167 | 406 | 362 |
| SQL client seconds | 35.70 | 30.65 | 74.00 | 63.01 |
| Runtime lines reached | 7,488 | 6,322 | 7,577 | 7,580 |

Bootstrap retains both cases, all eight child phases, and all 140 SQL client
calls inside the cases. The eight saved comparison files have the same source
SQL, checks, observed source/native/target values and transaction counts.
The 31 removed client calls were outside the cases. The two unrelated main-applier
invocations are gone; all eight fresh-state invocations remain. Total time is
24.99 seconds shorter (14.5%).

The 1,166 lines no longer reached by this bootstrap run are all reached by the
retained combined MODIFY run. They include database DDL, state writes and restart
handling. No runtime line is lost from the union of the compared selections;
that union increases from 8,288 to 8,291 lines.
This confirms that a high bootstrap line count previously included substantial
unrelated baseline work. It does not make cold schema discovery redundant.

The combined MODIFY run retains both cases and all ten named assertions. Its
eight saved metadata, following-DML, schema-history and normalized-binlog result
files match the separate runs exactly. Each case's source-boundary assertion
still checks its actual GTID and offset; the absolute boundaries change when
cases share a fixture. The general saved-schema restart also passes.

The combined run saves 70.03 seconds (32.3%) and 44 client calls. Calls outside
cases fall from 106 to 53. Calls inside cases increase by nine: the second case's
cleanup now compares the preceding case's table three more times on each server.
These extra row comparisons remain. Other classified inside-case call counts
are unchanged. Consolidation is not a reason to remove intermediate checks.

The application binary hash, server image contents, server settings and runtime
line mapping match. Only the lab source hashes for `LabScenario.swift` and
`SharedCorrectness.swift` differ. The comparison checks these specific differences;
the general comparison tool still rejects different build inputs. The host runs
AMD64 containers on ARM64 with cached images. No build or other lab run overlapped
these measurements. They are single local comparisons, not full-suite savings.

The focused setup-selection unit test and all 31 matrix/job planner unit tests
pass. The new live catalog matches the prior obligations and exact execution
counts. Swift formatting and whitespace checks pass. Remaining case combinations
and profiles must run in GitHub Actions.

Evidence is in `artifacts/ci-grouping-validation/`: the before/after measurement
files, `comparison.json`, `compare.py`, `after-plan.json`, `plan-comparison.json`
and `unit.log`. The earlier sandbox-denied attempt is retained separately; it
started no fixture and is excluded from the comparisons.

## Next review: group by MySQL feature

Organize tests by the feature and behavior they check. DDL and DML are useful
case tags, but they do not define separate test areas. A partition test can
check partition changes, row routing and subsequent writes. An index test can
check index definitions and row changes under those indexes.

This replaces the earlier proposal to combine numeric and row-operation groups
only because they are small. First identify which existing feature workflows can
take over a DML case's assertions. Then choose group boundaries by measured time.
The following items are proposals, not implemented removals.

### Case-level review

The review reads the source SQL and expected results in `DMLCompatibilityCases`,
`DDLCompatibilityCases`, `FulltextCases`, `PartitionCases`, `PartitionColumnCases`,
`UniqueKeyCases` and `ModifyIndexCases`. Both replicated matrix phases and DDL
steps use `SharedCorrectness.step`, which compares source, native and target
metadata and rows after each step. Case-specific expectations still differ.

| Separate replicated DML case | Receiving feature | Existing checks and required additions |
|---|---|---|
| `matrix-generated` | Generated columns and row values | `ddl-compat-generated` already checks multirow INSERT, stored and virtual values, NULL propagation, UPDATE, ALTER and DELETE. Add deletion of the updated non-NULL row while a NULL row remains, with an explicit expected result. This is the smallest replacement candidate. |
| `matrix-fulltext` | FULLTEXT indexes and search | `ddl-compat-fulltext` already checks CREATE/ALTER, normal-parser INSERT/UPDATE/DELETE, search results, restart, ngram INSERT and CREATE LIKE. Retain explicit CREATE WITH PARSER coverage and add ngram UPDATE/DELETE search assertions before replacing the separate case. |
| `matrix-values` | Multirow writes and row keys | Several DDL workflows already insert and update multiple rows. Retain an explicit multirow UPDATE and multirow DELETE, exact retained values, and unaffected rows in one suitable workflow. An INSERT plus DROP/TRUNCATE PARTITION does not replace row DELETE. |
| `matrix-composite` | Composite primary keys and row changes | Partition and ALTER tests use composite keys, but the matrix also has equal IDs on different dates and changes each key component separately. Add all three conditions before replacement. A composite UNIQUE key is not an equivalent primary-key condition. |
| `matrix-textkey` | Text keys and collation matching | `ddl-compat-unique-row-identity` checks a case-only key change and exact bytes, but uses a UNIQUE key at that point. Keep a text PRIMARY KEY, case-insensitive lookup, case-only UPDATE and DELETE with different letter case. Add this condition to the row-key area before replacement. |

The first two are small assertion migrations. The last three need more explicit
conditions. They are not confirmed duplicates that can be deleted now.

Keep the `bootstrap-matrix-*` counterparts. They start from existing schemas and
fresh applier state. Removing a replicated matrix selection must not remove the
shared case definition used by bootstrap. Keep profile, variant, transport and
native-engine conditions when moving a check. For example, some partition cases
set `nativeInnoDB: true`; this can change the reference engine for a MyISAM profile.

`matrix-upsert`, `matrix-replace` and `matrix-ignore` should belong to a named
unique-key conflict area. The reviewed DDL cases do not replace their mixed
insert/update effects, two conflicting unique rows, or no-op statements. Keep
these workloads and their intermediate assertions. `matrix-select` also checks
UPDATE JOIN and DELETE JOIN; a DDL test with only INSERT SELECT is insufficient.
Keep LOAD DATA explicitly visible in the selection.

Most numeric, temporal and binary cases also remain useful. A DDL test that
creates DECIMAL or TIME columns does not establish extreme-value fidelity,
fractional precision, time-zone handling or exact bytes. The spatial prefix-index
case does not replace all geometry subtypes, empty collections and SRID checks
in `matrix-spatial`. Likewise, JSON index tests do not replace typed JSON or
partial-update event checks. Move these cases under clear feature names; remove
them only after another workflow contains their required inputs and assertions.

### Proposed group names

Use names such as:

- `partition-routing-and-maintenance`
- `primary-unique-and-keyless-row-matching`
- `unique-key-conflicts-and-no-op-writes`
- `column-type-changes-and-row-values`
- `generated-columns-and-row-values`
- `fulltext-indexes-and-search`
- `spatial-types-and-indexes`
- `json-values-indexes-and-partial-updates`
- `numeric-limits-and-defaults`
- `temporal-precision-and-time-zones`
- `insert-select-join-writes-and-load-data`

These are names for reviewed selections, not instructions to create one CI job
for every entry. Combine small related selections in one fixture when useful.
Split long selections by named behavior, not numeric suffixes. Job names must
also show the profile, variant and transport. The case list must show exactly
which behaviors run, including bootstrap, restart or replay where selected.

### Measurement and removal conditions

In run `40170659705`, the five replicated matrix candidates above ran 50 times
across the SQL correctness selections. Their recorded case time totals about
358 seconds (six runner-minutes). Their SQL client time overlaps that total;
do not add it. This is work to review, not promised savings. Added assertions
still cost time, and deleting a case does not necessarily remove a CI fixture.

Coverage from that run is attributed to groups, not individual cases. Before
removal, map each old SQL condition and assertion to its replacement. Record
that mapping in the catalog so support reports still identify the tested
behavior. Check explicit smoke and BINLOG selections as well as full SQL runs.
Use focused before/after runs to compare exact runtime line sets, expected
results and state checks. Leave all other cases to GitHub Actions.

Start with generated columns and FULLTEXT. Then review generic multirow writes
and composite/text keys. No tests were removed or renamed during this review.
