# Conditional routine creation: workflow review

## Decision

Convert `ddl-compat-conditional-routines` to three body batches and final
observations. Keep its ID, group and all three MySQL 5.7-source exclusions.
Preserve the ten original operations first, all six predicates, restarts before
operations 4 and 8, and replay stop after transaction four.

Retain earlier states in `conditional_routine_results`. Scope both journal
counts to the five original conditional CREATE statements. Keep the original
expected counts: five compatibility records and two skipped target statements.
Do not drop source operations because their target DDL does no work.

The initial review used saved evidence. Implementation results follow at the end
of this document. The preceding view rename conversion was committed as `07e59d6`.

## Names and scope

Consult MySQL documentation before naming features. Use
[CREATE PROCEDURE and CREATE FUNCTION Statements](https://dev.mysql.com/doc/refman/8.4/en/create-procedure.html).
Use the title **CREATE PROCEDURE/FUNCTION IF NOT EXISTS: existing routines and
DROP/recreate**.

The source deliberately attempts a different definer, security setting, comment
and body for an existing routine. Preserve all original literal text, including
`root@localhost`, `root@%`, `original`, `replacement`, `k+10`, `k+20` and `k+999`.
Do not simplify the attempted replacements to duplicate CREATE statements with
identical metadata. Those differences make preservation observable.

Keep the case's default engine behavior. On the forward profile, source base
tables use InnoDB and native/target base tables use MyISAM. Keep the source SQL's
IF NOT EXISTS clauses; the existing target translation remains under test.
No production translation change belongs in this execution conversion.

## Saved measurements and source audit

Successful CI run `40454033524`, commit `efb3458`, has a complete report with no
failed shards, missing shards or missing coverage. The case definition still
matches that commit. Its default forward MyISAM run passed in 38.45s with 186
harness SQL client calls. The other three profiles exclude this case because
their 5.7 sources do not support routine CREATE IF NOT EXISTS.

These are harness calls, not target applier statements. Coverage belongs to the
larger views/routines/temporary-table group. It cannot establish per-case coverage
or justify removing the no-op and DROP/recreate checks. The earlier routine
pilot does not exercise this conditional creation path.

Evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/conditional-routine-workflow-review/baseline.json`: saved default result.
- `artifacts/conditional-routine-workflow-review/source-review.json`: original SQL,
  predicates, retained object map, source-operation counts and replay stop.
- `artifacts/conditional-routine-workflow-review/review.py`: reproducible source audit.

## Retained object map

Keep all ten original operations through the final INSERT. Then create
`conditional_routine_results` with CHARACTER SET utf8mb4 COLLATE utf8mb4_bin.
Append prefixes 1–4 through 1–9. Each owns a table, procedure and function, with
names such as `cr_called_t`, `cr_called_p` and `cr_called_f`. The procedure is
absent at the end of prefix 7.

Replace qualified database/object references consistently, including routine
bodies and CALL/SELECT names. Do not change parameters, columns, definers or
quoted comments. Histories must not share a base table or routine.

| Original prefix | Suggested stem | Required observation |
|---|---|---|
| 1–4 | `cr_procedure_kept` | Original predicate: procedure still has root@localhost, DEFINER security and comment `original` after the replacement attempt. Base table remains empty. |
| 1–5 | `cr_function_kept` | Original function predicates: input 7 returns 8; definer remains root@localhost and security remains DEFINER. |
| 1–6 | `cr_called` | Original source CALL row effect: base table contains only `1,11`. |
| 1–7 | `cr_dropped` | Procedure is absent after DROP; function remains; base row `1,11` remains. |
| 1–8 | `cr_recreated` | Procedure exists again with INVOKER security and root@localhost; base row is still `1,11` before the next CALL. |
| 1–9 | `cr_called_new` | Original recreated-procedure CALL result: rows `1,11` and `2,22`. |
| Original final objects | No extra prefix | Original final INSERT leaves rows `1,11`, `2,22`, `3,8`; original function still returns 8. |

The proposal has six retained base tables and 11 retained routines. It executes
50 source operations: ten original, one CREATE DATABASE and 39 retained operations.
Body batch sizes are 3, 4 and 43. Restart boundaries remain on original operations
4 and 8. Batching must not combine source transactions.

## Final observations

Map the six old predicates to retained objects for operations 4, 5, 6 and 9.
Keep the final row query on original `ddlcompat.t`. Add explicit checks for
procedure absence at prefix 7 and recreated procedure metadata at prefix 8.
Compare both databases' base tables and rows. Use read-only routine metadata
queries and function calls for final observations.

Do not CALL retained procedures during final observations. Their source CALLs
already supply the row effects. This does not directly test invocation of the
target's stored procedure: row replication applies the source's row events.
The target's skipped-DDL journal records and routine metadata separately check
that it retained the existing definition. Keep that scope clear in result text.

Do not require all source warnings to be empty. Existing-routine CREATE attempts
can produce warnings. Keep the current warning capture. A target statement
skipped by the translation does not imply an unlogged source operation:
operations 4 and 5 must retain their normal transaction counts and checkpoints.
All 50 operations in this proposal keep `transactions: 1`.

## Original journal counts and GTID selection

The original conditional CREATE operations are 2, 3, 4, 5 and 8. Keep both
SQLite predicates. Select these five operations by their captured source GTIDs:

- Five DONE records with compatibility rule `mysql57-routine-create-if-not-exists`.
- Two DONE records with `target_sql=''`, corresponding to original operations 4 and 5.

Keep the existing compatibility JSON path and skipped-statement conditions.
Retained histories add matching records, so a global count of five/two is no
longer correct. Do not increase these expected counts or remove the checks.
Keep the shared check that all DDL intents are DONE.

MySQL changes stored routine CREATE text in the binlog. It changes quotes and
spacing, and can omit default security clauses. Exact comparison with submitted
source SQL therefore cannot identify the original journal records. Use the
GTIDs already captured by each source batch. Require one GTID per selected
operation. This adds no SQL client calls.

Use SQLite string quoting for GTID literals. Do not use the MySQL
`LabSQLName.literal` formatter in a SQLite query. The view-rename quoting helper
now uses the shared `LabSQLName.sqliteLiteral` formatter. Focused unit tests
verify its output; this extraction does not require another view integration run.

Prepare and evaluate the scoped queries against a read-only saved SQLite
database. Unit tests cover original GTID selection, omitted or multiple GTIDs,
and independence from server-formatted SQL.

## Replay and cleanup

Extend the existing `conditional-routines` replay call with final observations
and the case ID. Keep stop after transaction four: the first ignored procedure
CREATE. It is a source transaction even though the target skips the DDL.
Retained operations follow the original ten, so this stop selects the same SQL.
Resume must reach all 50 operations with the exact GTID set and file offset.
Keep the unreachable source address and repeat final observations after resume.

Preserve the existing post-replay `SELECT ddlcompat.f(7) = 8` check and the
native/target routine-name/definer/security comparison over `ddlcompat`.
Retained routines use another database and must not enter that comparison.
Cleanup drops only `conditional_routine_results`, after journal and replay
checks. Keep original `t`, `p` and `f`, and the shared saved-schema restart.

## Implementation and local validation

1. Convert this case with the existing phase/final-observation helpers. Keep
   original SQL first, IF NOT EXISTS clauses, source transaction counts,
   source-profile exclusions and restart positions. Extend the replay call
   and scope the original two journal queries.
2. Add focused unit tests for all six old predicates, retained reference isolation,
   different attempted definitions, DROP/recreate stages, assertion-name conflicts,
   captured-GTID journal selection, SQLite quoting and cleanup scope. Run affected
   workflow, phase/final-observation and shared-quoting tests only.
3. Run only this case once on forward MyISAM/default/SQL with coverage. Verify
   five original compatibility records, two original skipped statements, all
   retained values/metadata, replay stop four/resume 50, exact GTIDs and offsets,
   original post-replay checks, saved-schema restart and retained database cleanup.
   Inspect the support bundle before a failed-case rerun.
4. Compare matrix/catalog selection. Record calls and setup, case, coverage-export
   and cleanup time. Do not rerun completed cases, other profiles, syntax tests,
   benchmarks or the full suite for this case conversion. Keep full-matrix
   validation, final balancing and PR selection for the later CI comparison.

Focused integration command:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-conditional-routines --coverage"
```

After this case passes, review absent definers. Preserve ERROR 1449 checks and
unchanged GTIDs/offsets before and after replay. Then review the remaining
executable-comment and temporary-table cases against the consolidation plan.

## Implementation and focused results

`ddl-compat-conditional-routines` passed one forward MyISAM/default/SQL fixture
with coverage. It executed all 50 source operations in three body batches of
3, 4 and 43. Setup and cleanup add two source phases. The first ten operations
remain unchanged and in order. All six original predicates remain among the
14 final predicates.

All 38 named assertions passed. They include 16 replay assertions, two live
restarts and schema comparisons. Replay stopped after transaction four and
resumed through transaction 50 with exact source GTIDs and file offsets. Both
replay configurations used an unreachable source. The existing post-replay
function result and routine metadata checks passed. Saved-schema restart and
cleanup also passed.

Read-only state checks confirmed five original compatibility records and two
original skipped target statements. All DDL intents were DONE, and no active
GTID remained. Six retained table schemas were saved. The retained database
contained 11 routines before cleanup. Source base tables used InnoDB; native
and target base tables used MyISAM. Cleanup removed only the retained database.
Original `ddlcompat.t`, `p` and `f` remained.

The first integration attempt passed live value and metadata checks, then
failed the journal-count assertion. Its support bundle showed no active GTID
or unfinished DDL intent. MySQL had changed routine CREATE text in the binlog,
so exact submitted-SQL selection missed the records. The phase helper now
returns its captured source results. Journal queries use those GTIDs, with no
extra SQL calls. Both corrected queries returned five/two against that original
bundle in read-only mode before the successful rerun.

Harness SQL client calls fell from 186 in saved CI to 79 locally. Case time was
31.41s locally, versus 38.45s in saved CI. These environments differ; this is not
a controlled speed comparison. Local fixture setup took 13.76s, including
11.06s for container startup and 2.27s for database setup. Coverage export took
4.84s and container cleanup took 11.18s. Image build time is separate.

Combined runtime coverage for this case's apply, fetch, replay and restart
processes was 8,161 of 20,880 mapped Swift lines (39.09%). This is a single-case
measurement. The old coverage report covers a larger group, so the two reports
do not establish a coverage increase or decrease.

The 21 selected Swift unit tests and 18 feature/migration tool tests passed.
Swift formatting and `git diff --check` passed. Matrix and catalog checks passed:
183 jobs, 1,545 catalog obligations and 182 instrumented collections. Group
selection and profile exclusions are unchanged. No other profile, benchmark,
syntax suite or full integration suite ran for this conversion.

Evidence:

- `artifacts/lab/20261103T053123Z-a40bcb27/result.json`
- `artifacts/conditional-routine-workflow-review/results.json`
- `artifacts/conditional-routine-workflow-review/state-results.json`
- `artifacts/conditional-routine-workflow-review/source-preservation.json`
- `artifacts/conditional-routine-workflow-review/sqlite-query-check.json`
- `artifacts/conditional-routine-workflow-review/matrix-comparison.json`
- `artifacts/conditional-routine-workflow-review/unit.log`

The [absent definer conversion](BETA7_ABSENT_DEFINER_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed its focused forward MyISAM/default/SQL fixture. All 38 assertions passed,
including both error stages, replay stop four/resume 13, saved-schema restart
and cleanup. SQL trace calls fell from 177 in saved CI to 111 locally. Next:
review character sets and collations. The
[temporary-table conversion and group audit](BETA7_TEMPORARY_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed both focused fixtures and found all 11 group cases converted. The
[executable-comment conversion](BETA7_EXECUTABLE_COMMENT_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed both focused fixtures: 39 named assertions, four restarts and all three
replay paths. SQL trace calls fell from 359 in saved CI to 188 locally. Full-matrix
validation remains later.
