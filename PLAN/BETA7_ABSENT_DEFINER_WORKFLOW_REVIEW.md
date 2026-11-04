# Stored object access control: absent definer review

## Decision

Convert `ddl-compat-absent-definers` to three source body batches and final
observations. Keep its ID, group and all four profiles. Preserve all seven
original source operations first, all four query predicates, restarts before
operations 4 and 6, and replay stop after transaction four.

Append one retained copy of operations 1–5 in `absent_definer_results`. This
single history preserves both intermediate results: the INVOKER view still
returns `1,10`, and the INVOKER function still returns 7. The original final
view returns `1,20`; the original function uses DEFINER security after ALTER.
No second retained history is needed.

Keep expected execution failures outside the ordinary final-query batch.
Require ERROR 1449 on source, native and target for both the original DEFINER
view and original DEFINER function, before and after replay. Keep GTID and
file-offset checks around each individual failed query.

The initial review used saved evidence. Implementation results follow at the
end of this document. The conditional-routine conversion was committed as
`d51efce`.

## Names and behavior

Consult MySQL documentation before naming features. Use
[Stored Object Access Control](https://dev.mysql.com/doc/refman/8.4/en/stored-objects-security.html).
MySQL calls an object with a nonexistent DEFINER account an orphan stored
object. Use the case title **Stored object access control: absent DEFINER and
SQL SECURITY INVOKER/DEFINER**.

INVOKER objects use the caller's privileges. DEFINER views and routines fail
when invoked if their definer account does not exist. This case checks the
stored account name and these execution results. It does not test account
creation, account removal, restricted callers, triggers or scheduled events.
Do not change account privileges or production replication logic in this slice.
Keep `'beta6_absent'@'localhost'` exactly as supplied by the original source SQL.

The online 5.7 manual link redirects to a newer manual. Do not treat that
redirect as 5.7 behavior evidence. The saved passing native observations cover
both 5.7 and 8.4 here. The 8.4 manual supplies the feature names and access-control
concepts.

## Saved measurements and source audit

CI run `40454033524`, commit `efb3458`, has no failed or missing shards and no
missing coverage. At review time, the case and expected-error helper matched
that commit. All four default-profile runs passed:

| Profile | Case seconds | Harness SQL client calls |
|---|---:|---:|
| mysql84-to-mysql57-myisam | 37.56 | 177 |
| mysql57-to-mysql84-innodb | 36.93 | 176 |
| mysql57-to-mysql57-innodb | 34.68 | 176 |
| mysql57-to-mysql57-myisam | 34.73 | 176 |

These are SQL trace counts, not target applier statements. The expected-error
queries use direct mysql client invocations outside `NativeHarness.sql`, but
`NativeHarness.compose` records them in the SQL trace. The saved count includes
all twelve expected failures. Record their executions separately within the
call total. The separate `sql-client.json` counter excludes these direct calls;
do not substitute it for trace counts. Coverage belongs to the whole
views/routines/temporary-table group. It cannot establish per-case coverage or
show that this case is redundant.

Evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/absent-definer-workflow-review/baseline.json`: four saved results.
- `artifacts/absent-definer-workflow-review/source-review.json`: original SQL,
  predicate map, retained SQL, source batches and expected-error matrix.
- `artifacts/absent-definer-workflow-review/review.py`: reproducible source audit.

## Source batches and retained objects

Keep original operations 1–7 unchanged. Then CREATE DATABASE
`absent_definer_results` with CHARACTER SET utf8mb4 COLLATE utf8mb4_bin. Append
original operations 1–5 with only these qualified references changed:

| Original object | Retained object |
|---|---|
| `ddlcompat.t` | `absent_definer_results.ad_invoker_base` |
| `ddlcompat.invoker_view` | `absent_definer_results.ad_invoker_view` |
| `ddlcompat.definer_view` | `absent_definer_results.ad_definer_view` |
| `ddlcompat.f` | `absent_definer_results.ad_invoker_f` |

Change references inside view definitions as well as CREATE names and queries.
Do not ALTER the retained function or UPDATE the retained table. Preserve the
missing definer name, function body, security clauses and column/value literals.

The proposal executes 13 source operations: seven original, one CREATE DATABASE
and five retained. Use body batches of 3, 2 and 8. Restart boundaries remain on
original operations 4 and 6. Every operation retains `transactions: 1`; batching
does not combine source transactions. Do not require empty source warnings:
creation with a nonexistent definer can produce a warning.

Keep default engine selection. In the focused forward fixture, source base
tables use InnoDB and native/target base tables use MyISAM. No new profile
exclusion, transport selection or version branch is needed.

## Final predicates

Preserve all four old expectations:

| Old operation | Final query target | Expected value |
|---|---|---|
| 3 | Retained INVOKER view rows | `1,10` |
| 4 | Original DEFINER view's DEFINER and SECURITY_TYPE | `beta6_absent@localhost`, `DEFINER` |
| 5 | Retained INVOKER function result | `7` |
| 7 | Original INVOKER view rows | `1,20` |

Add explicit metadata checks for the retained INVOKER view/function and original
function after its security change. Confirm the original function still names
`beta6_absent@localhost` and uses DEFINER security. Compare base-table schemas
and rows in both databases. Final success queries must not read the DEFINER
view or call the original DEFINER function; those require the error path below.

The generic schema comparison does not compare complete view or routine
definitions. Keep explicit metadata and invocation checks. Do not replace them
with table snapshots or a count of stored objects.

## Expected errors and saved evidence

Retain both queries exactly:

- `SELECT * FROM ddlcompat.definer_view`
- `SELECT ddlcompat.f()`

Run both on source, native and target before replay and again after replay.
Each query must fail with ERROR 1449. Capture a boundary immediately before and
after each query. Require unchanged GTID set, binlog file and file offset for
that query. Do not combine the two boundary checks or accept any nonzero exit
code without checking the MySQL error number.

The current helper overwrites its pre-replay text files when the post-replay
checks run. Add a stage name to its output paths. Register each role/object/stage
result as a named assertion, with the SQL, exit status, error text and both
boundaries. Keep twelve distinct results: two stages × three roles × two objects.
This makes both stages visible without changing expected behavior.

Do not send these queries through a success-only batch or add mysql `--force`.
Keep normal failure reporting and support-bundle collection if an assertion
fails. Keep source warnings separate from expected invocation errors.

## Replay, journal and cleanup

Pass final observations and the case ID into the existing replay helper. Keep
stop after transaction four: original DEFINER view creation. Resume through all
13 operations. Check the exact source GTID set and file offset. Keep an
unreachable source address during replay and repeat final observations after
resume. Then repeat all six expected-error checks.

Keep the shared DONE-DDL-intent and saved-schema checks. This case has no
case-specific compatibility or no-op count to rescope. Do not add exact routine
source-SQL comparisons: MySQL can change their formatting in the binlog.

Use the retained database in the replay reset and final cleanup. Drop only
`absent_definer_results`, after saved-state, replay and error checks. Leave the
original table, views and function for the existing saved-schema restart.

## Implementation and local validation

1. Convert this case with phase/final-observation helpers. Preserve original SQL,
   predicate values, transaction counts, restart points and replay stop.
2. Add focused unit tests for the four predicate mappings, retained dependencies,
   security modes, warning handling, cleanup scope and phase boundaries. Add
   guards for twelve unique stage/role/object error results and unchanged GTID,
   file and offset comparisons around each error query.
3. Run only this case on forward MyISAM/default/SQL with coverage. Check three
   body batches, two live restarts, final queries, all twelve errors, replay stop
   four/resume 13, exact GTIDs/offsets, saved-schema restart and cleanup. Read the
   support bundle before a failed-case rerun.
4. Compare matrix and catalog selection. Record source operations, SQL client
   calls and expected-error executions separately. Record fixture setup, case,
   coverage export and cleanup times. Do not claim whole-group timing or
   per-case coverage parity from group-level saved reports.

Focused integration command:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-absent-definers --coverage"
```

No other profile, full suite, benchmark or syntax suite is required locally for
this lab-only change. Keep all four profiles in the later full instrumented CI
run. Then review executable-comment and temporary-table workflows. Keep final
balancing and selection of short PR tests for the later CI comparison.

## Implementation and focused results

The case passed one forward MyISAM/default/SQL fixture with coverage. All seven
original source operations remain first and unchanged. The case executes 13
source operations in three body batches of 3, 2 and 8. Setup and cleanup add
two source phases. All operations retain their original transaction counts.
No production replication logic or account privileges changed.

All 38 named assertions passed. They include eight live final predicates,
eight replay final predicates, four schema comparisons, twelve expected errors,
three body batches, two restarts and retained-database cleanup. The four old
predicates remain. The retained view returned `1,10`; the retained INVOKER
function returned 7. The original view returned `1,20`. Original and retained
DEFINER/INVOKER metadata matched their required values.

All twelve ERROR 1449 checks passed across source, native and target, before
and after replay. Each failed query left GTIDs, binlog file and file offset
unchanged. All twelve text files exist with unique stage/role/object names.
Their named assertion files retain SQL, exit status, error text and both
boundaries. Neither stage overwrote the other.

Replay stopped after original transaction four and resumed through all 13
operations. Exact source GTID sets and file offsets matched at both boundaries.
Both replay configurations used an unreachable source. Read-only SQLite checks
confirmed no active GTID, all DDL intents DONE, the final source file offset and
one retained base-table schema. Source base tables used InnoDB; native and
target base tables used MyISAM. Saved-schema restart and fixture cleanup passed.
Cleanup dropped only `absent_definer_results` and left the original objects.

Harness SQL trace calls fell from 177 in saved CI to 111 locally. Both counts
include twelve expected-error calls. Case time was 33.56s locally, versus 37.56s
in saved CI. The environments differ; this is not a controlled speed comparison.
Local fixture setup took 16.30s, including 11.73s for container startup and 3.76s
for database setup. Coverage export took 4.88s; fixture cleanup took 10.98s.
Image build time is separate.

Combined runtime coverage was 8,156 of 20,880 mapped Swift lines (39.06%). It
includes this case's apply, fetch, replay and restart processes. Saved coverage
covers the larger stored-object group, so it cannot establish per-case coverage
parity. The SQL and predicate audit preserves the original conditions.

All 17 selected Swift unit tests and 18 feature/migration tool tests passed.
Formatting, catalog and matrix checks passed. The matrix retains 183 jobs,
1,545 catalog obligations and 182 instrumented collections. Group selection and
profile exclusions remain unchanged. No other profile, full integration suite,
benchmark or syntax suite ran for this lab-only conversion.

Evidence:

- `artifacts/lab/20261103T180616Z-bf40e0d3/result.json`
- `artifacts/absent-definer-workflow-review/results.json`
- `artifacts/absent-definer-workflow-review/state-results.json`
- `artifacts/absent-definer-workflow-review/source-preservation.json`
- `artifacts/absent-definer-workflow-review/matrix-comparison.json`
- `artifacts/absent-definer-workflow-review/unit.log`

The [executable-comment conversion](BETA7_EXECUTABLE_COMMENT_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed both focused fixtures. All 39 named assertions, four restarts, three replay
paths, original journal checks, role-specific comments, saved-schema restarts
and cleanup passed. SQL trace calls fell from 359 in saved CI to 188 locally.
The [temporary-table conversion and group audit](BETA7_TEMPORARY_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed both focused fixtures. All 43 named assertions passed, including 5.7
cleanup and exact replay positions. SQL calls fell from 438 in saved CI to 173
locally. All 11 group cases now use final observations. The
[first character-set slice](BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#first-slice-implementation-and-focused-results)
passed its focused forward pair with 26 named assertions. SQL calls fell from
335 in saved CI to 111 locally. The
[charset-conversion results](BETA7_CHARSET_CONVERSION_WORKFLOW_REVIEW.md#implementation-and-focused-results) passed its focused forward fixture.
Next: review DEFAULT session context, then encoded SQL. Full-matrix validation,
final balancing and short PR selection remain later.
