# Review of generated-column test batches

## Decision and scope

The geometry, JSON-index and FULLTEXT changes are committed as `c685958`.
The conversions of `ddl-compat-generated` and `ddl-compat-generated-expressions`
are complete. Focused unit and integration checks passed; results are below. Keep both case IDs and their existing CI
assignments. Keep the basic case in the selection with source GTID preservation
disabled. Do not merge either case into the JSON-index case.

The initial review used saved measurements and source inspection. It ran no
builds or tests. Implementation and validation results follow the review.

Use these titles when implementing:

- `ddl-compat-generated`: **Generated columns: stored and virtual values**.
- `ddl-compat-generated-expressions`: **Generated columns: expressions and CREATE TABLE LIKE**.

These names follow the MySQL manual. It distinguishes STORED and VIRTUAL columns,
permits both forms in one table, and describes preservation of generated-column
information by CREATE TABLE LIKE. The tests also use permitted functions and
operators in generation expressions.
[CREATE TABLE and Generated Columns](https://dev.mysql.com/doc/refman/8.4/en/create-table-generated-columns.html).
This reference supplies terminology. The saved native tests supply the evidence
for the selected expressions on each pinned server version.

## Measurements

Successful full CI run `40454033524`, commit `efb3458`, supplies the default SQL
baseline. The summary and report are complete. Both cases passed on all four
profiles. Each cell below is **case seconds / harness SQL client calls**.

| Case | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 InnoDB | 5.7 → 5.7 MyISAM |
|---|---:|---:|---:|---:|
| Basic stored/virtual values | 19.46 / 126 | 16.09 / 125 | 19.51 / 125 | 19.44 / 125 |
| Generated expressions | 34.60 / 153 | 29.93 / 152 | 35.41 / 152 | 34.93 / 152 |

The expressions case has since changed to seven source phases. Its later forward
MyISAM run passed at 47.03 s and 121 client calls. This is the current local
execution baseline for that case; do not attribute the earlier 153-to-121
reduction to the next change. That run also checked column swaps, so its coverage
set does not isolate the expressions case.

Source comparison confirms unchanged SQL, expected values and restart flags
since the full CI baseline. The expression file added phase boundaries. The
basic case still uses seven per-statement calls.

Evidence:

- `artifacts/generated-column-workflow-review/baseline.json`: both cases, all four
  default profiles, with SQL costs by role.
- `artifacts/generated-column-workflow-review/source-comparison.json`: source
  literals and restart flags compared with `efb3458`.
- `artifacts/generated-rename-phase-review/results.json`: later seven-phase run.
- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.

Coverage belongs to the complete execution group, not each case. SQL client
counts include observations and polling; they are not applier SQL statements.
The local and CI hosts differ. Do not predict a speed ratio or remove checks
because coverage overlaps.

## Basic stored and virtual values

The original seven operations are:

1. CREATE `t` with `doubled AS(n*2) STORED` and `added AS(n+1) VIRTUAL`.
2. INSERT `(1,7)` and `(2,NULL)` into the base columns.
3. UPDATE ID 1 to `n=9`.
4. ADD `next_value AS(n+2) STORED`.
5. INSERT ID 3 with `n=11`.
6. DELETE ID 1 while ID 2 remains NULL.
7. DELETE ID 2, leaving ID 3.

Keep this original sequence first. Add four tables that execute prefixes of
2, 3, 5 and 6 operations. Use distinct names, such as `gc_inserted`, `gc_updated`,
`gc_added` and `gc_deleted`. These add 16 operations, for 23 total. One source
body batch can execute the complete sequence. No explicit restart occurs inside
this case. Keep the shared saved-state drain/restart checks. Do not add replay.

| Original check or comparison | Final observation |
|---|---|
| INSERT values and NULL propagation | `gc_inserted` retains rows `1,7,14,8` and `2,NULL,NULL,NULL`. Keep the assertion ID `generated-insert-values`. |
| UPDATE recomputes stored and virtual columns | `gc_updated` retains ID 1 as `1,9,18,10`, plus the unaffected NULL row. Keep `generated-update-values`. |
| ADD computes values for existing rows | `gc_added` retains ID 1 with `next_value=11` and ID 2 with NULL. Compare complete rows and generated definitions. |
| INSERT after ADD | `gc_added` retains ID 3 as `3,11,22,12,13`. Keep the existing query and expected values. |
| DELETE retains the NULL row | `gc_deleted` contains `2,NULL,NULL,NULL,NULL` and `3,11,22,12,13`. Keep `generated-delete-retains-null`. |
| Final DELETE of NULL row | Original `t` has one row, ID 3, with all four expected values. Keep the count check and full row comparison. |
| Stored versus virtual metadata | Check `EXTRA` for `doubled`, `added` and the later `next_value`; retain complete schema comparison. |

The three named IDs are required by `tools/test_case_migrations.json` for the
retired `matrix-generated` case. Move them from step assertions into final
observations. The catalog now exposes final-observation names. Keep the migration
test's required names; update its exact-list expectation to include the final
observations, as done for FULLTEXT. Do not change or weaken migration conditions.

Extract the basic definition into a named property beside the expression case
if that makes the code and focused tests easier to read. Keep it in the same
position in `DDLCompatibilityCases.cases`. Do not change adjacent partition or
constraint tests.

## Generated expressions and LIKE

Keep all eight original operations first:

1. CREATE the table with the existing expressions and `by_chosen` index.
2. INSERT the non-NULL row and the NULL-input row.
3. Restart, then UPDATE ID 1 to `n=12`, `v='xyzx'`, `d='2025-01-02'`.
4. ADD `absent AS(n IS NOT NULL)` and `bounded AS(n NOT BETWEEN 1 AND 10)`.
5. UPDATE the formerly NULL `n` on ID 2 to 1.
6. CREATE `copy LIKE t`.
7. Restart, then INSERT ID 3 into `copy` with `n=1`, `v='xxone'`, `d='2024-01-01'`.
8. DELETE ID 1 from `t`.

Add four tables with prefixes of 2, 3, 4 and 5 operations. Use distinct names,
such as `ge_initial`, `ge_updated`, `ge_added` and `ge_predicates`. These add 14
operations, for 22 total. Put retained preparation after original operation 8.
Use three source body batches, ending before each existing restart and at the
end. Do not add restarts to retained prefixes.

| Original check or comparison | Final observation |
|---|---|
| Initial CASE forms, bit operations, text/date functions and NULL inputs | `ge_initial` retains both rows and the existing ten-column expected result. |
| INTERVAL values for non-NULL and NULL inputs | Keep the exact `(1,1),(2,-1)` check on `ge_initial`. |
| Expression values after UPDATE | `ge_updated` retains the existing result `0,0,8,xyz,yz,2025,12,0` for ID 1. |
| ADD evaluates expressions before the NULL input changes | `ge_added` retains ID 2 with `absent=0` and `bounded=NULL`; ID 1 has both values equal to 1. Keep full schema and row comparison. |
| UPDATE from NULL to 1 | `ge_predicates` retains both rows and the existing ten-column expected result. It keeps ID 1 before the final DELETE. |
| LIKE followed by INSERT | Original `copy` retains ID 3. Compare all copied definitions, `by_chosen`, and the generated values. |
| Final DELETE | Original `t` retains only ID 2. Check its identity and all values. |

The shared snapshot must include every generated column. In particular,
`tomorrow`, `raw` and `negated` are not in the four explicit predicates but are
part of the existing full row comparisons. Do not replace these comparisons
with only the listed scalar queries. Keep raw binary bytes, NULLs, column order,
expression definitions and the generated-column index metadata.

### Replay is part of this case

`SharedCorrectness.ddl` calls `replayDDLWorkflow` with `stopAfter: 3` for this
case. That stops after the original UPDATE, before ADD of the two new columns.
Keep the original eight operations first so retained prefixes do not move this
boundary. Keep the unreachable source during replay and saved-position resume.

The helper already accepts `finalObservations`. It resets the target baseline,
replays the complete workload and runs final observations with `replay-` names.
Use this path to check retained results after replay too. Cleanup must occur
only after replay and the existing saved-state checks. The target reset must
remove the retained tables before rebuilding them. No new replay runner is needed.

## Focused validation for implementation

Implement both case changes before building one matching coverage image.

1. Add focused unit checks for original SQL order, prefix substitution, final
   predicates, storage metadata and NULL values. Verify 23 basic operations and
   22 expression operations. Verify one and three body batches respectively.
2. Keep the basic migration IDs and both expression restarts. Verify that the
   third expression transaction is still the original UPDATE. Update the old
   seven-phase assertions in `DDLExecutionPhaseTests`; keep the unrelated phase
   checks for generated dependencies, column swaps and key changes.
3. Run the affected final-observation and migration/catalog unit tests. Check
   the DDL catalog, feature/migration tools and matrix assignments. The matrix
   must remain at 183 jobs, 1,545 obligations and 182 coverage collections.
   The basic case must still be selected with source GTID preservation disabled.
4. Run both changed cases in one forward MyISAM/default/SQL fixture with coverage:

   ```sh
   make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-generated --case ddl-compat-generated-expressions --coverage"
   ```

5. Verify every final result and evidence file, the three migration IDs, live
   restarts, expression replay stop/resume, saved-schema restart, cleanup and
   coverage export. Read a support bundle before retrying an applier failure.
6. Record SQL calls, case time, setup, cleanup and coverage export separately.
   Compare against the saved CI values and the later expression-phase run, with
   their different scopes stated. Do not claim per-case line coverage parity.

One profile is sufficient for this harness change. Both cases use the same SQL
for all targets; neither has `sqlTransactional`, engine-specific expected values
or a profile exclusion. The forward fixture compares an InnoDB source with native
and target MyISAM tables and includes the existing replay path. Preserve all
other profile and variant selections for CI. Add a second local profile only if
implementation exposes a distinct branch or failure that requires it.

Do not rerun the completed index cases. Do not run the production syntax suite,
full integration suite or benchmark for this test-only conversion. Update
`docs/TEST_LAB.md` after implementation to explain the new batch/final checks and
show the focused command.

## Following work

After these two cases pass, review generated-column dependencies, column swaps,
column/index syntax and ALTER column keys. Each still has multiple intermediate
comparisons. Map its results and restart/replay requirements before reducing its
number of observation phases. Keep these changes in the existing fixture and
CI group.

## Implementation

Both conversions now use `DDLFinalObservations`. The basic definition moved to
`GeneratedColumnCases.swift`; its catalog position and adjacent cases remain.
Its 23 operations use one body batch. The expression case has 22 operations in
three body batches. The original seven and eight operations remain first and in
order. Both expression restarts remain at their original statements.

Final checks retain all three migration assertions and all four original explicit
expression predicates. They also check the values computed when columns are
added, storage forms, final rows, date/binary/negation values and the copied index.
Complete schema and row comparisons remain. The expression case uses the existing
replay helper and its original third-transaction stop. Cleanup follows replay and
saved-state checks.

All 54 selected Swift tests pass. The eight migration tool tests, ten feature
tool tests and DDL catalog check pass. The matrix remains at 183 jobs, 1,545
obligations and 182 runtime coverage collections, with identical assignments
and exclusions. The basic case remains selected on all four profiles when source
GTID preservation is disabled, for both SQL and BINLOG transport.

Evidence before the integration run:

- `artifacts/generated-column-workflow-unit.log`.
- `artifacts/generated-column-workflow-review/source-preservation.json`.
- `artifacts/generated-column-workflow-review/matrix-comparison.json`.

## Focused integration results

Both cases passed in one forward MyISAM/default/SQL fixture in OrbStack:
`artifacts/lab/20261029T221509Z-c64d5537/result.json`.
All 38 named assertions passed. Every named result file is present. The basic
case keeps all three required migration assertions. The expression case passes
ten replay assertions in addition to its live results. Both deliberate live
restarts, the shared saved-schema restart, cleanup and coverage export passed.

| Case | Named assertions | Saved CI calls | Earlier local phase calls | New calls | Saved CI seconds | New local seconds |
|---|---:|---:|---:|---:|---:|---:|
| Stored/virtual values | 12 | 126 | Not measured | 33 | 19.46 | 10.47 |
| Generated expressions | 26, including 10 replay | 153 | 121 | 64 | 34.60 | 28.29 |
| Total | 38 | 279 | Different selection | 97 | 54.06 | 38.77 |

The expression case's earlier seven-phase run took 47.03 s. Its 153-to-121 call
reduction predates this change. The new conversion reduces those 121 calls to 64.
All counts describe harness SQL clients, including observation and wait calls.
They do not describe applier statements. The hosts and selections differ; these
elapsed times do not establish a controlled speed ratio.

Replay stopped after three transactions at `binlog.000003:4690`. It resumed to
22 transactions at `binlog.000003:15058`, with the expected final GTID set.
Both replay configurations use unreachable source `127.0.0.1:1`. The final replay
checks compare all retained tables and the original LIKE copy. The basic case
adds no replay workflow.

The coverage image's Swift application/test build took 225.39 s. Dependency
layers were reused. One image and one fixture served both cases. The fixture
recorded eight source phases: setup, body and cleanup for the basic case; setup,
three body batches and cleanup for the expression case.

| Fixture phase | Seconds |
|---|---:|
| Setup total | 14.655 |
| Container startup, within setup | 11.918 |
| Database preparation, within setup | 2.019 |
| Coverage export | 5.106 |
| Cleanup | 11.027 |

The combined run reached 9,432 of 20,880 mapped Swift runtime lines. Saved full
CI coverage describes the larger table/column/index group. The earlier local
expression run also included column swaps. Neither is a matching line-set
baseline for these two cases, so this result does not establish coverage gain
or loss. Original SQL preservation, the assertion map and complete row/schema
comparisons supply the review of retained behavior.

Evidence:

- `artifacts/generated-column-workflow-review/results.json`: case, SQL, fixture
  and coverage measurements.
- `artifacts/generated-column-workflow-review/replay-results.json`: stop/resume
  counts, GTIDs and file offsets.
- The fixture's `cases.json`, `assertions/`, `fixture-lifecycle.json`,
  `sql-trace.jsonl`, replay logs/configurations and combined coverage report.
- `artifacts/generated-column-workflows-forward.log`: build and test output.

All requested checks passed. No other profile, full suite, production parser
suite or benchmark ran. The matrix and profile exclusions are unchanged.
Next: review generated-column dependencies and column swaps for final batched
observations. Keep their distinct definitions, key identities and replay stops.
Use saved evidence for that review before another implementation or local run.
