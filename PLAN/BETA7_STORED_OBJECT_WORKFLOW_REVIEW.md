# Stored-object workflows: review and first conversion slice

## Decision

Start with `ddl-compat-views` and `ddl-compat-routines`. Convert each to one body
batch and final observations. Keep both IDs, profile selections and their current
`ddl-views-routines-temporary-tables` group. Run both cases in one fixture.

Keep all 12 original source operations first. Preserve all eight explicit query
predicates. Neither case has a live restart or offline replay path today. Add
neither for this execution optimization. Retain objects in a separate database
so the original database-wide DROP checks keep their exact SQL and expectations.

Then review the four larger stored-object cases in separate implementation slices.
Do not force executable comments, temporary tables or expected execution errors
into the ordinary success-case helper. Do not remove cases based on group coverage.

The review used saved evidence. The pilot implementation and focused validation
are now complete; results follow below. The preceding partition work was
committed as `af6930c`.

## Names and terminology

Consult the MySQL documentation before naming features. Use
[Using Views](https://dev.mysql.com/doc/refman/8.4/en/views.html),
[Using Stored Routines](https://dev.mysql.com/doc/refman/8.4/en/stored-routines.html)
and [Stored Object Access Control](https://dev.mysql.com/doc/refman/8.4/en/stored-objects-security.html).

Use these pilot titles:

- **Views: CREATE OR REPLACE, ALTER and base-table row effects**.
- **Stored routines: compound procedure, function and row effects**.

The current routine title says bodies are not executed. The case also executes
CALL and SELECT of a function. The first CREATE must not execute the procedure
body, but later statements deliberately exercise both routines. The new title
states that scope.

## Group inventory and saved evidence

The current group has 11 case IDs. The saved default runs contain 37 applicable
executions across four profiles, all passed. The group also contains three
executable-comment cases and two temporary-table cases. Those five require their
own review. The six stored-object cases below retain distinct assertions.

Successful CI run `40454033524`, commit `efb3458`, has a complete report with no
failed shards, missing shards or missing coverage. All six case definitions
still match that commit. Each cell is **case seconds / harness SQL client calls**:

| Case suffix after `ddl-compat-` | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 InnoDB | 5.7 → 5.7 MyISAM |
|---|---:|---:|---:|---:|
| `views` | 18.07 / 111 | 17.69 / 110 | 17.89 / 110 | 15.40 / 110 |
| `routines` | 18.16 / 111 | 17.64 / 110 | 17.77 / 110 | 15.95 / 110 |
| `stored-objects` | 52.45 / 263 | 51.93 / 262 | 50.32 / 262 | 49.65 / 262 |
| `view-renames` | 51.68 / 251 | 50.68 / 250 | 50.17 / 250 | 46.63 / 250 |
| `conditional-routines` | 38.45 / 186 | Not applicable | Not applicable | Not applicable |
| `absent-definers` | 37.56 / 177 | 36.93 / 176 | 34.68 / 176 | 34.73 / 176 |

The pilot pair used 222 forward client calls. These are harness calls, not
applier target statements. Coverage belongs to the whole group. It cannot show
which individual case supplied a line or prove that a case is redundant.

Evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/stored-object-workflow-review/baseline.json`: 37 saved default results.
- `artifacts/stored-object-workflow-review/source-review.json`: original SQL,
  predicates and restart positions for the six stored-object cases.
- `artifacts/stored-object-workflow-review/review.py`: reproducible source audit.

## Helper limits

The full schema/row comparison checks base-table schemas and rows. It records
view table/column metadata, but it does not compare complete view definitions,
view query results or routine definitions/bodies. Explicit view and routine
queries must remain. Do not replace them with the generic comparison.

The final-observation helper supports multiple databases and explicit cleanup.
Use that support for the pilot instead of changing the old absence predicates.
Routine SQL contains semicolons inside BEGIN/END. Keep each compound CREATE as
one source operation. NativeHarness uses LabSQLInput with a custom mysql-client
delimiter for requests and batches. Preserve this path and its original bytes.
Add a unit guard for the compound CREATE inside a source batch; do not split its
body or introduce a client script that executes the body during CREATE.

## Pilot: views

Keep all six original operations first, including final DROP VIEW. Then CREATE
DATABASE `stored_view_results` with CHARACTER SET utf8mb4 COLLATE utf8mb4_bin.
Append three independent histories in that database. Replace qualified table
and view names in all statements and references; preserve column names/literals.

| Original prefix | Suggested base table/view | Required final query |
|---|---|---|
| 1–3 | `sv_initial_base` / `sv_initial` | View returns `1,7`; INSERT through the view changed its base table. |
| 1–4 | `sv_replaced_base` / `sv_replaced` | Replaced view returns `1,8`; base value remains 7. |
| 1–5 | `sv_altered_base` / `sv_altered` | ALTERed view returns `1,9`; base value remains 7. |

Keep the three old row predicates on those retained views. Keep the original
`COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat' = 0`
check unchanged. Compare all base rows in both databases. Add explicit metadata
queries for retained view names and INVOKER security. Do not claim that row
results alone compare full view definitions.

This proposal has 19 operations: six original, one CREATE DATABASE and 12 retained
operations. It uses one body batch. Cleanup drops only `stored_view_results`.
It must leave original `ddlcompat.t` and the original dropped-view state intact.

## Pilot: stored routines

Keep all six original operations first, including both DROP statements. Then
CREATE DATABASE `stored_routine_results` with the same explicit defaults.
Append two independent histories:

| Original prefix | Suggested objects | Required final query |
|---|---|---|
| 1–2 | `sr_created_base`, `sr_created_p` | Base-table count is zero: CREATE did not execute the compound procedure body. |
| 1–3 | `sr_function_base`, `sr_function_p`, `sr_function_f` | Function call with 7 returns 8; base-table count stays zero. |
| Original final table | `ddlcompat.t` | Original CALL produced row `1,2`. |

Replace qualified references in the copied procedure body as well as CREATE/CALL
names. Preserve DECLARE, SET, INSERT and BEGIN/END. Keep the original final
ROUTINES count of zero in `ddlcompat`. Retained routines live only in the second
database. Add explicit retained-name/type/security queries there. Do not CALL
retained procedures during final observations: those observations must not write.
The original CALL already exercises the procedure's row effect.

This proposal has 12 operations: six original, one CREATE DATABASE and five
retained operations. It uses one body batch. Cleanup drops only
`stored_routine_results`. No retained copy of prefix 1–4 is needed: the original
base table still holds that CALL result at the end.

## Later slices and special checks

| Case | Original operations / predicates | Restarts before operations | Existing replay stop | Checks that must remain |
|---|---|---|---|---|
| `stored-objects` | 15 / 11 | 4, 9, 15 | 4 | ALTER procedure/function metadata and security, function result, CALL rows, LOCAL/CASCADED view metadata, updatable-view writes, multi-view DROP, original routine/view absence and exact original journal SQL. |
| `view-renames` | 13 / 11 | 7, 9, 13 | 7 | View and table identity through swaps, base-row effects, view transitions in SQLite, exclusion from row-schema cache, error 1450 for cross-database view rename with unchanged GTIDs/offsets, replay metadata and final view rows. |
| `conditional-routines` | 10 / 6 | 4, 8 | 4 | Original body/definer/comment survive IF NOT EXISTS; two no-op intents and five compatibility-rule records; DROP/recreate changes behavior; replay function value and routine metadata. Keep 5.7-source exclusions. |
| `absent-definers` | 7 / 4 | 4, 6 | 4 | INVOKER behavior, stored definer metadata, ERROR 1449 for definer view/function on all three roles, and no GTID/offset changes on failed calls. Keep checks before and after replay. |

Review retained-object naming and journal scopes for each later slice before
implementation. Extra histories must not inflate counts that refer to the
original SQL. Select original names or exact original SQL without dropping
metadata/no-op requirements. Keep the original sequence first so replay stops
still select the same operations. Pass final observations into replay when a
later case gains retained objects. Cleanup must follow saved-state and replay
checks. Preserve expected execution failures outside ordinary success queries.

The executable-comment and temporary-table cases remain unchanged during the
pilot and these four stored-object conversions. Review them next, including
source/target version gates, session lifetime and transaction counts. A temporary
table's CREATE/use/drop sequence must remain in its original source operation.

## Pilot implementation and validation

1. Extract the two inline cases into a stored-object workflow file. Keep IDs,
   profile behavior and original SQL first. Add one body batch per case and
   final observations over the original and retained databases. Use explicit
   database cleanup after case state checks.
2. Add focused unit tests for all eight old predicates, retained dependencies,
   compound body preservation, distinct assertion names and cleanup scope.
   Check LabSQLInput/LabSQLBatch framing of the compound CREATE. Run only affected
   workflow, phase/final-observation and SQL input/batch tests.
3. Run only this pilot pair together on forward MyISAM/default/SQL with coverage.
   Confirm original absence checks, retained view/function results, empty
   unexecuted procedure tables, original CALL result, state checkpoints, saved
   schemas and cleanup. Use the support bundle first if a case fails.
4. Compare matrix/catalog before and after. Record client calls and setup, case,
   coverage-export and cleanup time. Keep the remaining nine group cases, other
   profiles, syntax tests, benchmarks and full suite for CI. Add another local
   profile only if a new branch or failure requires it.
5. Record pilot results. Then review `stored-objects`, followed by view renames,
   conditional routines and absent definers. Keep final group balancing and PR
   selection until a later full instrumented CI run.

Focused integration command:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-views --case ddl-compat-routines --coverage"
```


## Pilot implementation and focused results

The two inline cases now live in `StoredObjectWorkflowCases.swift`. Each uses
one body batch and final observations over two databases. All 12 original SQL
operations remain first. All eight original predicates remain, with retained
object names where an earlier value would otherwise be lost. The original
absence queries still select the whole `ddlcompat` database. No live restart
or offline replay path was added. Production replication code did not change.

Both cases passed in one forward MyISAM/default/SQL fixture with coverage:

| Case | Saved CI client calls | New client calls | Local case seconds | Named assertions |
|---|---:|---:|---:|---:|
| Views | 111 | 39 | 13.60 | 13 |
| Routines | 111 | 39 | 10.92 | 10 |

Client calls fell from 222 to 78. These are harness calls, not target applier
statements. The old times came from CI and the new times came from a local
machine. They do not establish a controlled elapsed-time speedup.

All 23 named assertions passed. They include 15 explicit final queries, four
full schema/row comparisons, both source body batches and both cleanup batches.
View queries returned the original, replaced and altered values. Base values
remained 7. Retained view names and INVOKER security matched. Function input 7
returned 8. Both retained procedure tables remained empty, so CREATE did not
execute either compound body. The original CALL produced row `1,2`. The original
view/routine absence queries returned zero. No final observation called a
procedure or wrote data.

Read-only state checks confirmed all 19 view and 12 routine source operations,
final file offsets, applied groups and DONE DDL intents. Retained schema counts
matched the three view base tables and two routine base tables. Raw table
metadata confirmed InnoDB on source and MyISAM on native/target. Cleanup dropped
only the two retained databases. Shared saved-schema restart and fixture cleanup
passed.

The fixture used six source phases: two body batches, two setup batches and two
cleanup batches. Setup took 20.77s, including 15.35s for container startup and
5.04s for database setup. Coverage export took 2.73s. Fixture cleanup took 10.73s.
Combined runtime coverage was 7,188 of 20,880 mapped lines. Saved CI coverage
includes the larger views/routines/temporary-table group, so it cannot establish
per-case coverage parity for this pair. SQL and predicate audits preserve the
original conditions.

All 23 focused Swift tests and 18 feature/migration tool tests passed. The tests
check retained dependencies, cleanup scope and compound BEGIN/END framing in
one mysql client request. Formatting, DDL catalog and matrix checks passed.
The matrix retains 183 jobs, 1,545 obligations and 182 coverage collections,
with the same groups and exclusions. Source locations changed when the cases
moved; nested catalog locations were excluded from the semantic comparison.
No other profile, remaining group case, full suite, syntax suite or benchmark ran.

Evidence:

- `artifacts/lab/20261103T032544Z-667d8973/result.json`
- `artifacts/stored-object-workflow-review/results.json`
- `artifacts/stored-object-workflow-review/state-results.json`
- `artifacts/stored-object-workflow-review/source-preservation.json`
- `artifacts/stored-object-workflow-review/matrix-comparison.json`
- `artifacts/stored-object-workflow-review/unit.log`

The [stored-object ALTER conversion](BETA7_STORED_OBJECT_ALTER_REVIEW.md#implementation-and-focused-results)
passed its focused forward MyISAM/default/SQL fixture. All 52 named assertions,
three restarts, replay stop four/resume 79, the three original journal records,
saved-schema restart and cleanup passed. Client calls fell from 263 in saved CI
to 86 locally. The 11 original predicates and matrix remain intact.

Next: review view rename chains with saved SQL, assertions and timings. Preserve
error 1450, view-transition records, row-schema-cache exclusions and replay
metadata/results. Then continue conditional routines and absent definers. Keep
full-matrix validation, final balancing and PR selection for later.
