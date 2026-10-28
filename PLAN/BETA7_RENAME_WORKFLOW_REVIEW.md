# Review of column renames and table moves

## Decision

Review complete. The multi-table pilot is implemented and its focused checks passed.

Use independent table sets to keep the result of each ordinary workflow until
one final batch of checks. Distinct assertions do not require distinct waits or
applier restarts. Keep a running applier while source operations execute. Then
wait for the final source position and compare the retained results.

This incorporates the user's review feedback. Do not convert each old statement
comparison into a separate named phase by default. If a later operation would
erase a result, use another table set or another retained row. Keep explicit
stop/resume and offline replay checks at their required boundaries.

The preceding SQL-group change is committed as `3d2fcbd`. This review follows
[Slice 2 of the overall plan](BETA7_TEST_SUITE_CONSOLIDATION.md#remaining-slices-in-order).
Keep the four existing catalog case IDs and profile exclusions. The current
full plan stays at 183 jobs, 1,545 obligations and 182 coverage collections.
Do not add a CI job for each new table set.

## Names and scope

Use these MySQL terms in assertion names and descriptions:

- **RENAME COLUMN:** change a column name while retaining its definition.
  Keep it distinct from CHANGE, which specifies the definition again.
  See [ALTER TABLE: column operations](https://dev.mysql.com/doc/refman/8.4/en/alter-table.html).
- **ALTER TABLE ... RENAME:** rename a table, including a move to another database.
- **RENAME TABLE:** rename one or more tables. A multi-table statement processes
  renames from left to right; a temporary name can support a swap. See
  [RENAME TABLE](https://dev.mysql.com/doc/refman/8.4/en/rename-table.html).

Keep the existing IDs for command compatibility. Use descriptive assertion names
such as `cross-database-table-swap`, `renamed-column-default` and
`foreign-key-cascade-after-move`. A table-set identifier identifies the source
operations and final queries for one result; it is not another test runner.

## Evidence

Saved run: `40454033524`, commit `efb3458`. Its measurement summary and report
are complete, with no failed jobs or missing coverage collections. The four
case definitions have not changed since that run. The shared harness has changed.
The extracted case costs are in `artifacts/rename-workflow-review/baseline.json`.

Each cell is **case seconds / harness SQL calls**. These are default SQL runs.

| Case suffix (`ddl-compat-`) | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 InnoDB | 5.7 → 5.7 MyISAM |
|---|---:|---:|---:|---:|
| `column-renames` | 53.7 / 226 | Not applicable | Not applicable | Not applicable |
| `alter-table-rename` | 58.5 / 268 | 50.0 / 267 | 59.5 / 267 | 58.8 / 267 |
| `multi-table` | 58.6 / 228 | 49.7 / 227 | 59.3 / 227 | 58.4 / 227 |
| `cross-schema-relationships` | 45.5 / 158 | 39.5 / 157 | 45.4 / 157 | 45.5 / 157 |

The forward cases use 880 harness SQL calls. These counts include case setup,
waits and observations, not just statements sent by the applier. Case time
excludes fixture setup and final coverage export. All four cases already share
the group's database containers. New container grouping alone cannot remove
these costs.

The saved runtime line sets cover the whole table/column/index group. They do
not identify which of these four cases executes a particular line. Keep the
existing [group-level comparison](BETA7_TABLE_COLUMN_INDEX_REVIEW.md#what-the-coverage-comparison-shows).
Do not claim per-case redundant coverage or a projected time saving from it.
No tests are proposed for removal.

## Assertion map

| Case | Required behavior | How to retain results for the final check |
|---|---|---|
| `column-renames` | Multiple RENAME COLUMN clauses with ADD; table-default charset change without changing existing column encoding; generated-column rename; multibyte row update; COPY/ORDER BY; omitted-column default; simultaneous name swap; following UPDATE. | Use separate tables for results that a later rename or update would replace. Reproduce the required earlier ALTER sequence for each table. Retain seed and updated rows separately. Check final columns, indexes, generated values, exact bytes and defaults. |
| `alter-table-rename` | Cross-database parent move combined with CHANGE; child move with ADD; return move with MODIFY; InnoDB FK replacement; repeated table-rename clauses in one ALTER; same-name RENAME with ADD; later write and ordered DELETE/DROP. | Keep parent/child pairs for moved, returned and same-name endpoints. Keep a separate pair for delete/drop checks. Each endpoint retains the relevant compound ALTER sequence, rather than replacing it with a simpler RENAME. |
| `multi-table` | Cross-database table collation and rows; UPDATE at the new name; ordered swap of differently typed tables; CREATE LIKE and write; multi-table DROP; IF EXISTS; reuse of a dropped name with DECIMAL. | Keep moved/updated tables, a swapped pair and LIKE copies until the final comparison. Use separate table sets for dropped-only and reused-name results. Check both sides of the swap and the absence of temporary names. |
| `cross-schema-relationships` | Parent and child moves; FK metadata and UPDATE cascade on InnoDB; ordinary row update on MyISAM; joint move back; child-before-parent DROP; retired SQLite schemas. | Keep one moved pair, one returned pair and one dropped pair. Use exact row values and FK metadata for surviving pairs. Check absent tables and scoped saved-schema retirement for the dropped pair. |

Do not simplify a sequence merely because another endpoint looks the same.
For example, the column default must survive the preceding renames and charset
change. A returned FK pair must have undergone the outward moves and cascade.
When a result requires the same prefix, run that prefix on its own table set.
Do not clone a table after the operation being tested and use that clone as proof
that the operation was correct.

Use explicit fixture names and SQL definitions. Do not add a general string
replacement pass for qualified table names. Preserve compound statements and
source transaction boundaries. More source statements can be an acceptable cost
if they remove repeated waits, client starts and result reads. Measure both.

## Comparison gaps to address during conversion

The current per-step comparison calls `compare("ddlcompat")`. It compares table,
column, index, foreign-key and partition metadata, plus exact row values. It does
not also inspect all tables in `otherdb`. Explicit checks read some destination
rows and one destination collation, but several cross-database steps check only
a join count. Those checks do not establish complete destination metadata.

The final batched observations must cover the owned tables in both databases.
Check exact cascade results, not only a join count. Check temporary and old names
are absent. Keep unrelated fixture tables out of expected-table counts. The
shared setup creates `otherdb` with latin1/latin1_bin; moved utf8mb4 tables must
retain their table and column encodings. Do not change this setup to make the
comparison easier.

The column-renames fixture includes `COMMENT 'keep comment'`. The common column
query does not select `COLUMN_COMMENT`. Add an explicit final comment assertion
for the renamed column. Existing default-byte, index and generated-value checks
must remain. These are test-observation improvements, not runtime feature changes.

Design the observation code as a list of named queries and expected results.
Run each role's list through `sqlBatch`. Compare the final table inventory and
schema/row snapshots once per owned database or selected table set. Store both
databases' results under distinct keys; do not overwrite the first result with
the second. Failure output must identify the case, table set, query and expected
value, and retain the existing support-bundle path.

## State, restart and replay boundaries

The four definitions contain 17 explicit `restartBefore` markers: four for
column renames, four for compound table renames, five for multi-table DDL and
four for cross-schema relationships. They test later operations against saved
schema state. Initially retain their mapped stop/resume conditions. Do not
remove them as a side effect of batching ordinary assertions. A later change
may share a restart across independent table sets only after it maps every
required saved-schema condition and following operation.

Keep the two existing offline workflows:

- `column-renames`: stop after three source transactions, then resume with an
  unreachable source.
- `alter-table-rename`: stop after six source transactions, then resume.

If expanded table setup changes those transaction ordinals, map each stop to the
same semantic point and derive its count from the recorded source operations.
Do not keep a hard-coded count that now stops in unrelated setup. Preserve the
final GTID check and restore the live configuration after replay.

New surviving tables also change replay cleanup. The existing helper resets only
`ddlcompat`; these cases currently finish with their moved tables removed.
Before replaying a redesigned workflow, remove or reset its owned `otherdb`
tables while the live applier is stopped. Keep unrelated tables. Compare both
databases after replay. Include this in the change before enabling retained
cross-database endpoints in the compound-ALTER case.

Keep source transaction counts, exact applied GTIDs and DONE DDL intents.
Keep the multi-table DROP record with three transitions and unchanged source SQL
on the target. Preserve saved-schema retirement assertions. Scope their SQL to
the case's dropped table names and GTID interval: independent surviving tables
mean a global `current=1` count can no longer be expected to be zero.

The separate `alter-rename-target84-refusal` case is out of scope. Do not change
its pre-write refusal, BLOCKED state or unchanged-target assertions.

## Implementation slices and validation

1. **Pilot: `multi-table`.** Use independent table sets and one final batch for
   ordinary move, swap, LIKE, drop and name-reuse results. Retain its saved-state
   restart conditions and three-transition DROP record. Keep one fixture and
   the existing case ID. This case has no transactional SQL branch or offline
   replay, so one forward MyISAM/default/SQL local run is sufficient.
2. **Compound table renames and FK moves.** Apply the pilot to
   `alter-table-rename` and `cross-schema-relationships`. Add replay cleanup and
   two-database observations. Run those two cases together on forward MyISAM
   and reverse InnoDB. The second profile is required for FK definitions,
   cascades and the alternate source SQL.
3. **Column renames.** Retain each dependent ALTER sequence in its own table set.
   Include comment, encoding, default and generated-value assertions. Run this
   case on forward MyISAM only. A 5.7 source excludes RENAME COLUMN by design.

For each implementation slice:

- Record old assertion → new table set/query mappings before changing the runner.
  Check original SQL semantics, expected values and engine-specific alternatives.
- Run focused lab unit tests for the workload/observation plan and the affected
  selector/catalog checks. Add tests for scope and replay cleanup when changed.
  Do not run parser tests for harness-only changes.
- Build the host lab after Swift edits. Reuse a matching coverage application
  image when its input check permits. Do not build for this review.
- Run only the local selections above with coverage. Require all mapped checks,
  one fixture setup/cleanup, completed state checks and exported failure paths.
  Inspect a support bundle first if a case fails.
- Record client calls, waits, applier starts, setup/test/export times and executed
  line sets. Compare full-group coverage in the later CI run; saved per-case line
  sets are not available. Do not call added source SQL a regression by itself.

The initial review needed no build or container run. The pilot results below
record the subsequent implementation checks.


## Multi-table pilot assertion mapping

The pilot keeps all 13 original source statements, in their original order.
It adds independent table sets. The workload now has 30 source statements in
six batches, plus common database setup and one final cleanup statement.
Five explicit restart points remain on the original RENAME, swap, DROP,
DROP IF EXISTS and INSERT-after-name-reuse operations.

| Old observation | Retained final result |
|---|---|
| Table collation and initial row after the move | `otherdb.mt_moved`: utf8mb4_bin and `(1,first)` |
| Updated row at the new table name | `otherdb.mt_updated`: `(1,changed)` |
| Integer table after the ordered swap | `otherdb.mt_swap_moved`: `(2,20)` |
| Text table after the ordered swap | `ddlcompat.mt_swap_u`: `(1,changed)` |
| Row inserted into CREATE LIKE copy | `otherdb.mt_copy`: `(3,30)` |
| DROP removed all three original tables | `otherdb.moved` and `otherdb.copy` remain absent. Recreating `ddlcompat.u` succeeds and its type is now DECIMAL. The original DONE DROP intent retains all three transitions. |
| INSERT after restarting with the reused name | Original `ddlcompat.u`: `(4,4.25)` |

Additional final assertions check an empty LIKE copy, absent old/temporary names,
and the reused column's exact DECIMAL definition. Full source/native/target
comparisons now cover both `ddlcompat` and `otherdb` once. The five destination
tables and the retained text table are removed only after the saved-state checks.
The cleanup names are explicit; it does not drop other fixture tables or databases.

`DDLFinalObservations` is an optional case plan. Existing cases retain their
intermediate comparisons. Opted-in cases cannot hide per-step checks: validation
rejects that combination. Named final queries share one client call per role.
Mismatch errors contain the assertion name, role, SQL and expected value.
The existing source-phase records retain each statement's GTID and file/offset.

The adjacent FK workflow and its source SQL are unchanged. The pilot does not
change the CI matrix, case ID, runtime code or source-GTID policy.


## Multi-table pilot results

The focused run passed on `mysql84-to-mysql57-myisam`, default variant, SQL
transport. It used one fixture. All 25 named assertions passed. The five explicit
restart checks remain. The saved-state check found one DONE DROP intent with
three transitions and identical source and target SQL. The removed destination
tables had no current schema records. Fixture cleanup and coverage export passed.

| Measurement | Saved CI case | Local pilot |
|---|---:|---:|
| Harness SQL calls | 228 | 94 |
| Case time | 58.61 s | 57.93 s |

The pilot removes 134 harness SQL calls (59%). The runs used different hosts.
Do not infer an elapsed-time improvement from this comparison. Local container
startup took 19.35 s; database setup took 2.69 s. Coverage export took 18.47 s;
cleanup took 11.64 s. These phases are separate from the case time.

The workload retains all 13 original source statements in order. It has 30
statements across six workload batches. Setup and cleanup add two source batches.
Nine focused unit tests passed. Catalog validation passed. The CI plan remains
at 183 jobs, 1,545 obligations and 182 coverage collections. The adjacent FK
workflow is unchanged.

Runtime coverage reached 7,484 of 20,880 lines. The saved baseline has coverage
for the whole `table-column-index-changes` group, not this case. Thus, these data
cannot establish a per-case coverage increase or decrease. Compare the full
group in the later CI run.

Local evidence:

- `artifacts/multi-table-review/results.json`: timing and SQL-call comparison.
- `artifacts/multi-table-review/source-comparison.json`: original SQL preservation.
- `artifacts/multi-table-unit.log`: nine unit tests.
- `artifacts/lab/20261028T230538Z-b6f207aa/result.json`: passing integration run.

The first `--skip-build` attempt stopped before fixture setup because the image
inputs had changed. The next attempt built the coverage image and passed. No
other profile or full suite ran for this slice.

Next: apply this model to `alter-table-rename` and `cross-schema-relationships`.
Use independent parent/child tables and final observations in both databases.
Add cleanup for retained destination tables before offline replay. Keep FK and
cascade assertions. Run those two cases together on forward MyISAM and reverse
InnoDB, as specified in slice 2 above.
