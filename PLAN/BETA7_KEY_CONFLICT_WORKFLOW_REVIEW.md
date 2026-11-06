# INSERT and REPLACE conflict handling: workflow review

Status: the retained-table conflict workflow is implemented locally after
`c268dd7`. Fifteen focused unit tests passed. The case passed all 15 assertions
on default SQL, 8.4 → 5.7 MyISAM. No case or catalog assertion was removed.

## Decision and fixture

`ddl-compat-key-conflicts` now uses the retained-table plan in `keys-rows-gtids`.
It shares that fixture's containers and ordinary applier. Keep its 11 named
assertions and its replacement links for `matrix-upsert`, `matrix-replace` and
`matrix-ignore`. Do not restore those retired cases or add another job/profile.

Extend the retained-table plan used by the primary-key and constraint cases.
The conflict case has three independent tables and 11 operation states. Eight
history tables can retain its earlier states. Final batched observations can
check all eight original row predicates and the three CREATE states.

Consult the MySQL manuals before naming the checks. Use INSERT ... ON DUPLICATE
KEY UPDATE, REPLACE and INSERT IGNORE. These tests send those statements to the
source. The applier and native replica receive their resulting row events.
They do not need to execute the original conflict-handling statements on the target.

## Source and assertion audit

`KeyConflictCases.swift` is unchanged from successful CI run `40454033524`,
commit `efb3458`. It has no explicit restart, offline replay or version/engine
SQL branch. Keep the existing generic checkpoint and saved-schema restart.

| Source operations | Named assertions | Required result |
|---|---|---|
| CREATE, seed, mixed duplicate-key UPDATE/INSERT, unchanged duplicate-key UPDATE | `upsert-table-create`, `insert-on-duplicate-seed`, `insert-on-duplicate-mixed`, `insert-on-duplicate-noop` | Separate updated, inserted and unaffected rows; no row change for the final statement |
| CREATE, seed, REPLACE with primary-key and UNIQUE-key conflicts | `replace-table-create`, `replace-seed`, `replace-primary-and-unique-conflicts` | Two different old rows conflict; exact replacement and following inserted row |
| CREATE, seed, mixed INSERT IGNORE, fully ignored INSERT | `ignore-table-create`, `insert-ignore-seed`, `insert-ignore-mixed-conflicts`, `insert-ignore-noop` | Keep the original row, accept the nonconflicting row, ignore both conflict types, then leave rows unchanged |

All tables keep an integer PRIMARY KEY, a NOT NULL integer value column and
`UNIQUE KEY uk(v)`. Keep their explicit utf8mb4/bin collation. Compare exact
rows, including unaffected rows. Keep empty rows and PRIMARY/UNIQUE metadata
for each CREATE assertion.

The two `transactions: 0` statements use this fixture's automatic GTID assignment
and row logging. Do not turn that fixture result into a rule for every statement
that reports zero affected rows under other session or binlog settings.

## Saved measurements

All four default SQL CI executions passed. Values below are case seconds and
harness client calls. They are not applier SQL statement counts.

| Profile | Case seconds | Client calls | Schema-comparison calls |
|---|---:|---:|---:|
| 8.4 → 5.7 MyISAM | 20.99 | 183 | 39 |
| 5.7 → 8.4 InnoDB | 25.74 | 182 | 39 |
| 5.7 → 5.7 MyISAM | 25.17 | 182 | 39 |
| 5.7 → 5.7 InnoDB | 25.32 | 182 | 39 |

Coverage belongs to the complete saved keys-rows-gtids fixture. It cannot
identify exclusive lines for this case. Its conflict types and zero-change
statements are distinct obligations. Coverage overlap is not a removal reason.

Two older local runs also passed this exact SQL and all eight predicates:
`20261026T214702Z-8da296c1` on forward MyISAM and
`20261026T214043Z-b588038b` on reverse InnoDB. Their read-only SQLite snapshots
show these row-intent counts per logged DML group:

| Table | Seed group | Conflict group |
|---|---:|---:|
| `insert_on_duplicate` | 2 | 2 |
| `replace_rows` | 2 | 3 |
| `insert_ignore` | 1 | 1 |

The original body therefore logs nine transactions: three DDL and six DML.
It has 11 row mutations. Do not derive the REPLACE row-mutation count from SQL's
affected-row count. The pinned 8.4 and 5.7 `sql/sql_insert.cc` implementations
can use `ha_update_row` for the last unique-key conflict when their FK/trigger
conditions permit it. The saved fixture counts agree across both source versions.

Native source references from the root checkout:

- `.upstream/mysql-server/sql/sql_insert.cc:2067`, commit `0896fcd61dec11a0904166911a0126f59daaa1bf`.
- `.upstream/mysql-server-5.7/sql/sql_insert.cc:1833`, commit `f7680e98b6bbe3500399fbad465d08a6b75d7a5c`.

The complete audit is `artifacts/key-conflict-workflow-review/review.json`.
It contains the unchanged source, assertion IDs, predicates, four CI results,
two saved local row-intent inventories and native source references.

## Required helper changes

1. Add the three table histories to the existing key-workflow plan. Preserve
   every original operation and assertion ID. Keep the original definitions
   and catalog unchanged. Retain the pre-no-op rows as separate states even
   when they equal the final rows.
2. Preserve each source step's `transactions` value when generating execution
   steps, including the last step in a phase. Permit a
   zero value only with zero row mutations and a non-DDL operation in this plan.
3. Keep the generic named-assertion guard strict. Map each named assertion to
   its required final observation before generating assertion-free phase steps.
4. Use `DDLExecutionPhase.validateUnlogged` for both zero-transaction statements.
   Require an empty GTID delta, an unchanged executed GTID set, the same binlog
   file and the same offset. Record their complete before/after boundaries.
   Exact final rows alone do not prove those conditions.
5. Extend the saved-state checkpoint to distinguish submitted operations from
   logged transactions. Require unique, single-GTID identities for logged
   writes only. Do not treat the two empty deltas as duplicate GTIDs or query
   SQLite for an empty GTID. Check all logged groups as APPLIED at their saved
   file/offset, all expected intents as DONE, and every retained schema.
6. Count `transactionsApplied` from the declared logged steps, not the number
   of submitted writes. Keep DDL and row-mutation counters independent. Check
   the total checkpoint against the last operation's end boundary, including
   when that last operation logs nothing.
7. Record source warnings from the phase results. The old `step` path did not
   request SHOW WARNINGS for this case. Do not introduce a blanket empty-warning
   requirement. Duplicate-key warnings from INSERT IGNORE and version-specific
   VALUES() deprecation warnings are compatible with successful source execution.

The proposed body has 26 submitted operations, 24 logged transactions, two
unlogged operations, 11 DDL operations and 22 row mutations. These totals include
the history tables and exclude database setup and restart probes. Histories
stop before the two final no-op statements, so they add no duplicate no-op checks.

## Verification scope

Add focused unit checks for original SQL, all 11 states/assertions and all eight
predicates. Confirm the expanded counts above. Check zero-transaction steps keep
their flags and zero row counts. Reject a false no-op that changes any GTID/file/
offset field. Reject multiple GTIDs for a logged operation, repeated logged GTIDs,
missing groups, wrong counters, unfinished intents and missing schemas. Keep
the existing primary-key/constraint workflow unit tests green after the helper
extension. Preserve their 25/65 transaction and 27/48 row totals.

Run the affected key-workflow, unlogged-phase and migration unit checks. Build
once. Run only `ddl-compat-key-conflicts` on default SQL, 8.4 → 5.7 MyISAM, with
coverage. Require all 11 original named assertions, retained rows/schema, both
unchanged source boundaries, saved offsets, completed intents and the existing
saved-schema restart. Inspect a failure's support bundle before a rerun.

Do not rerun the prior two cases or the other profiles locally for this helper
extension. Their unit tests cover the existing one-transaction path. The saved
reverse fixture also confirms the REPLACE count. Add a focused profile run only
if the implementation introduces a source-version/engine branch. Leave the full
group, other profiles and variants to CI. Compare the catalog and matrix without
running them. Do not run syntax tests for this harness change.

## Implementation and focused results

`KeyConstraintWorkflows.swift` now includes the three conflict tables and eight
history tables. The generated steps preserve the original SQL and transaction
flags. Final observations retain all 11 named assertions, eight fixed predicates
and 11 operation states. The CREATE assertions also check empty tables, column
types/nullability and both PRIMARY/UNIQUE index definitions. The original case
definitions, migration links and native-only fixtures remain unchanged.

The phase helper checks both unlogged operations. The saved-state checkpoint
checks those boundaries again and records them as `unloggedWrites`. It checks
unique, single-GTID identities only for logged writes. Empty deltas do not enter
SQLite lookups or the applied-transaction count. The checkpoint still uses the
last submitted operation's end boundary, including an unlogged ending.

The workflow permits and records valid source warnings. The focused run recorded
warning 1287 for the unchanged duplicate-key UPDATE and warning 1062 for the
fully ignored INSERT. These warnings did not make successful source statements
fail. No new source-version branch was required.

| Default SQL, 8.4 → 5.7 MyISAM | Result |
|---|---:|
| Passing assertions | 15, including all 11 original named assertions |
| Retained operation states | 11 |
| Submitted operations / logged transactions | 26 / 24 |
| Unlogged operations | 2; GTID sets, files and offsets unchanged |
| DDL / row mutations, including histories | 11 / 22 |
| Original REPLACE group | 3 row mutations, matching both saved source versions |
| Harness SQL client calls within the case | 33; saved CI: 183 |
| Local case time | 11.08 seconds |
| Saved groups and intents | All 24 groups APPLIED at exact offsets; no unfinished intents |
| Empty GTID records | 0 |
| Saved-schema restart | Passed |
| Catalog and matrix | Unchanged: 183 jobs, 1,545 obligations, 182 collections |

The saved CI case time was 20.99 seconds on different hardware. This is not a
controlled speed comparison. Client calls are harness calls, not target applier
statement counts. The complete fixture used 99 client calls, including setup
and outer checks.

The run used one container setup, three source phases and the existing three
applier invocations, including the case and outer restart checks. Coverage was
7,441/20,880 runtime lines. This is the selected case and its fixture checks,
not the complete keys-rows-gtids group.

All 15 focused unit tests passed: KeyConflictWorkflowTests,
KeyConstraintWorkflowTests, DDLExecutionPhaseTests, LabSQLPhaseTests and the
key-conflict migration test. They check both empty deltas, an unlogged ending,
each false-boundary condition, multiple/repeated logged GTIDs, counters and
saved-state failures. The earlier primary-key/constraint plans keep their
25/65 transaction and 27/48 row totals. Their integration cases and the other
profiles were not rerun locally. The generic phase guard remains unchanged.

Passed lab result: `artifacts/lab/20261106T224218Z-b83be123/result.json`.
Other evidence is in `artifacts/key-conflict-workflow-review/`:
`workflow-results.json`, `inventory-results.json`, `unit.log` and `integration.log`.

Next: review INSERT SELECT, joined UPDATE/DELETE and LOAD DATA in the remaining
`matrix-select`/`matrix-load` cases. Keep their distinct source statements and
input-file conditions.
