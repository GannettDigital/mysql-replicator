# Review of column keys, index options and AUTO_INCREMENT workflows

## Decision

Convert `ddl-compat-column-index-syntax` and `ddl-compat-alter-column-keys`
to source batches with final observations on retained tables. Keep both case
IDs, their Indexes feature owner, profile selections and current CI group.
They remain separate named results in one shared fixture.

Keep the original SQL first, including each final DROP. Keep all five current
live restarts. Both replay paths must still stop after transaction four.
Append independent table sequences that retain each earlier compared state.
The review used saved evidence without running tests. The implementation and
focused validation are now complete; results follow below.

## Names and scope

Use these case titles:

- **Indexes: column keys, index options and SERIAL**
- **ALTER TABLE: primary keys and AUTO_INCREMENT columns**

Consult MySQL documentation before adding or changing feature names. MySQL
lists column attributes and index definitions under
[CREATE TABLE](https://dev.mysql.com/doc/refman/8.4/en/create-table.html).
It defines `SERIAL` and `SERIAL DEFAULT VALUE` in
[Numeric Data Type Syntax](https://dev.mysql.com/doc/refman/8.4/en/numeric-type-syntax.html).
Index types, comments, ALGORITHM and LOCK are described under
[CREATE INDEX](https://dev.mysql.com/doc/refman/8.4/en/create-index.html).
These names describe the existing tests; they do not imply complete syntax coverage.

Preserve `USING HASH` in the source SQL and compare the resulting native index.
Do not label this a HASH-index test: the manual lists BTREE for InnoDB and
MyISAM. Keep COLUMN_FORMAT, STORAGE, KEY_BLOCK_SIZE and comments in the SQL.
The current shared schema comparison does not check every option's physical
effect. In particular, it does not select INDEX_COMMENT or key block size.
Do not claim this conversion adds those checks or tests NDB storage behavior.
A separate assertion can extend that scope later.

## Saved measurements

Read the summary and report for successful CI run `40454033524`, commit
`efb3458`. The report is complete, with no failed shards, missing shards or
missing coverage. Each cell below is **case seconds / harness SQL client calls**
for the default SQL selection.

| Case | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 InnoDB | 5.7 → 5.7 MyISAM |
|---|---:|---:|---:|---:|
| Column/index syntax | 67.70 / 300 | 59.11 / 299 | 68.31 / 299 | 67.62 / 299 |
| ALTER column keys | 82.80 / 386 | 68.33 / 385 | 84.01 / 385 | 84.81 / 385 |

The later local phase conversion passed both cases in one forward MyISAM fixture:

| Case | Current phases | Current live restarts | Local seconds | SQL client calls |
|---|---:|---:|---:|---:|
| Column/index syntax | 9 | 2 | 50.63 | 136 |
| ALTER column keys | 14 | 3 | 74.52 | 215 |

Use 136 and 215 calls as the current execution baseline. The earlier reduction
from 686 combined CI calls to 351 local calls is already complete. Do not
attribute it to the next conversion. The earlier phase conversion deliberately
reduced live restarts from five to two and from six to three. Preserve the
current five; remove no more. All 45 source operations and 11 explicit query
predicates still match the original CI case definitions.

Evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/column-key-workflow-review/baseline.json`: all four profiles.
- `artifacts/column-key-workflow-review/source-review.json`: SQL, predicates,
  current restart counts, retained-operation maps and proposed batch sizes.
- `artifacts/ddl-phase-review/results.json` and `statement-comparison.json`.
- `artifacts/lab/20261028T015314Z-65ad6c79/result.json`: prior local run.

CI coverage is for the larger table/column/index group. The prior local run
contains these two cases, but its build predates recent changes. Compare the
available line sets with their source revisions. Do not claim exact per-case
coverage parity from the group report. Use SQL and assertion maps to preserve
behavior. Report setup, body, coverage export and cleanup time separately.

## Column/index syntax

Keep all 20 original operations first. Restarts remain before operations 6
and 14. The replay stop remains operation 4, the UPDATE of grouped columns.

The `s` sequence is not contiguous: its CREATE, INSERT and UPDATE are operations
12–14, but its DELETE is operation 19. Operations 15–18 belong to `q`.
Do not use a simple slice that accidentally inserts `q` operations into `s`.

In this table, operation numbers refer to the unchanged original case. Each
retained sequence changes only its qualified table name.

| Original operations | Suggested retained table | Required observation |
|---|---|---|
| 1–2 | `ci_inline` | Both seed rows; inline KEY and UNIQUE declarations; original column definitions and `by_note`. |
| 1–5 | `ci_grouped` | Grouped ADD columns and `by_c`; default `c=3` on the second row; updated first row; exact original `a` and `a_2` index-name predicate. |
| 1–7 | `ci_index_created` | Renamed `b`, generated unique-index names, `by_d` after CREATE INDEX with type/comment/online options; compare actual index metadata and rows. |
| 1–9 | `ci_index_dropped` | `by_d` absent after DROP INDEX and ALGORITHM=COPY; other columns, indexes and rows remain. |
| 1–11 | `ci_final` | `e` and `d` absent after RESTRICT/CASCADE clauses; retain the explicit rows `1,12,22,8` and `2,11,21,3`. |
| 12–13 | `ci_serial_seed` | SERIAL metadata and both initial rows, IDs 1 and 2 with values 40 and 41. |
| 12–14 | `ci_serial_updated` | After the restarted UPDATE: IDs 1 and 2 with values 42 and 41. |
| 12–14, 19 | `ci_serial_deleted` | After DELETE: only ID 1 with value 42; keep SERIAL metadata. |
| 15–18 | `ci_serial_default` | SERIAL DEFAULT VALUE, both generated IDs, grouped UNIQUE(extra), first-row extra 60 and second-row NULL. |

The five `t` prefixes add 34 operations. The three `s` sequences add nine.
The `q` sequence adds four. With the original 20, the case has 67 operations
and nine retained tables. Its three body batches have 5, 8 and 54 operations.
This replaces nine comparison phases with three body batches; it does not
combine source transactions.

Keep both existing explicit queries and their exact expected values. Add named
queries for SERIAL insert/update/delete results and the transient index's presence
and absence. Use the full schema/row comparison for all retained tables. Check
that original tables `t`, `s` and `q` are absent after their original DROP.
Clean up retained tables only after replay and saved-state checks.

## ALTER column keys

Keep all 25 original operations first. Restarts remain before operations 8,
11 and 20. The replay stop remains operation 4, the UPDATE from `id=0` to `id=1`.

| Original operations | Suggested retained table | Required observation |
|---|---|---|
| 1–3 | `ak_implicit_key` | Added primary key FIRST fills the existing row with `id=0,v=7`. |
| 1–5 | `ak_implicit_defaults` | Added NOT NULL columns produce numeric zero and empty string. Preserve both the row predicate and the two metadata rows with NULL COLUMN_DEFAULT. |
| 1–6 | `ak_modified_key` | MODIFY to BIGINT PRIMARY KEY plus DROP PRIMARY KEY: retain actual final key and type before CHANGE replaces them. |
| 1–7 | `ak_renamed_key` | CHANGE to `k` AFTER `v` with inline PRIMARY KEY and DROP PRIMARY KEY: retain physical column order, type and key. |
| 1–8 | `ak_renamed_write` | UPDATE after restart gives `k=2,v=8,n=9,s='x'`. |
| 1–9 | `ak_rebuilt` | AUTO_INCREMENT rebuild with increment 3/offset 2 gives `aid=2,k=2,v=8`. |
| 1–10 | `ak_inserted` | Following INSERT under reset session defaults retains `aid,k` rows `2,2` and `5,3`. |
| 1–12 | `ak_deleted` | After restarted UPDATE and DELETE: only `aid=5,k=3,v=12,n=11,s='y'`. |
| 13–15 | `ak_empty` | Add AUTO_INCREMENT to an empty table; insert rows `1,20` and `2,30`. |
| 16–18 | `ak_secondary` | Add the AUTO_INCREMENT column and its secondary key: `id,seq` rows `1,1` and `2,2`; `by_seq` exists. |
| 16–19 | `ak_promoted` | Promote `seq` to PRIMARY KEY and remove `by_seq`, while both rows remain. |
| 16–21 | `ak_promoted_write` | After restarted UPDATE and DELETE: only `id=2,v=21,seq=2`; retain the promoted key. |
| 22–24 | `ak_grouped` | Grouped ADD PRIMARY KEY before ADD AUTO_INCREMENT column; final `id=1,v=40`. |

The eight `t` prefixes add 60 operations. `e` adds three, the three `u`
prefixes add 13, and `c` adds three. With the original 25, the case has 104
operations and 13 retained tables. Its four body batches have 7, 3, 9 and
85 operations. Preserve all nine explicit query predicates and expected values.
Add final predicates for the retained UPDATE/DELETE rows and original-table
absence. Compare key names, order, uniqueness, types, defaults and all rows.

### Session state and the saved DDL context

`DDLExecutionPhase.writes` already resets AUTO_INCREMENT increment/offset to
the global defaults before every source operation. Keep that reset for original
and retained operations. Keep the source timestamp reset too. Operation 9 must
still contain its own `SET SESSION ...=3,...=2` followed by ALTER in the same
operation. Reset again before the following INSERT. Do not apply the special
session values to the entire batch or replace observed `aid=5` with a guess.
The MySQL manual documents both variables as global and session variables:
[Replication Source Options and Variables](https://dev.mysql.com/doc/refman/8.4/en/replication-options-source.html#sysvar_auto_increment_increment).

Keep the existing SQLite assertion in `SharedCorrectness.swift`. It requires
exactly one completed original `ALTER TABLE ddlcompat.t ADD aid...` intent with
increment 3 and offset 2 in `context_json`. Retained table names must not match
that original-table predicate. Do not broaden it to a positive count across
all retained tables; that could hide a missing original context.

## Shared implementation and focused validation

1. Implement both retained-table definitions before one build. Use explicit
   sequences and descriptive observation IDs. Do not copy only a table's final
   state with CREATE LIKE/INSERT SELECT; execute its original ALTER history.
2. Pass `test.finalObservations` to both existing replay calls in
   `SharedCorrectness.swift`. Their labels and stop count four remain. The shared
   helper must reset retained tables, resume with an unreachable source and run
   the named final checks again. Keep existing checkpoint and DDL-intent checks.
3. Replace the two remaining phase-count expectations in `DDLExecutionPhaseTests`
   with focused workflow tests. Keep the generic planner rejection tests and
   the session-reset test. That test must continue to inspect the special
   AUTO_INCREMENT operation, followed by the reset INSERT.
4. Test all retained sequences, especially noncontiguous `s`; original SQL order;
   five restart points; both replay stops; default/NULL/empty-string values;
   physical column order; implicit key names; and AUTO_INCREMENT context.
   Validate final observation IDs, cleanup and replay reset SQL.
5. Check the DDL catalog, case selection and matrix. Keep the current 183 jobs,
   1,545 obligations and 182 coverage collections. Neither case owns a retired
   case's migration assertion. Keep the same IDs, exclusions and feature owner.
6. Build once and run only these cases in one forward MyISAM/default/SQL fixture:

   ```sh
   make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-column-index-syntax --case ddl-compat-alter-column-keys --coverage"
   ```

7. Verify all named live and replay observations, five live restarts, replay
   stop/resume GTIDs and file offsets, saved-schema restart, the exact original
   SQLite context assertion, cleanup and coverage export. Use a support bundle
   first if the applier fails. Measure added source operations as well as reduced
   client calls. Retained histories add work, so fewer client calls alone do not
   prove a faster test.
8. Update this plan and `docs/TEST_LAB.md` with the measured result. Keep other
   profiles and the full suite for CI unless a new branch or failure requires
   another local profile. No runtime or syntax-parser changes are planned.
   Do not rerun syntax tests, benchmarks or the completed dependency/swap cases.

One local profile is sufficient for the planned conversion. Both definitions use
identical SQL for transactional and nontransactional targets, no engine-specific
expected values and no profile exclusions. Native comparisons remain on all
three servers. Do not increase timeouts or split these cases into new jobs
without a measured need.

## Following review

After both cases pass, check the remaining table/column/index cases against the
overall plan. Separate completed conversions from deliberate restart, rejection
or recovery workflows. Select the next ordinary DDL candidate from saved SQL,
assertions and timing data. Do not expand this slice into a full local run.


## Implementation and focused results

Both workflows now use the reviewed retained-table layout. The 45 original
source operations and all 11 original query predicates remain unchanged, apart
from table names in final observations. Column/index syntax uses three body
batches, 67 operations and nine retained tables. ALTER column keys uses four
body batches, 104 operations and 13 retained tables. The noncontiguous SERIAL
DELETE belongs to the correct retained sequence.

Both cases passed together in one forward MyISAM/default/SQL fixture, with
coverage enabled:

| Case | Prior local SQL client calls | New calls | Prior local seconds | New seconds | Named assertions |
|---|---:|---:|---:|---:|---:|
| Column/index syntax | 136 | 62 | 50.63 | 30.29 | 32 |
| ALTER column keys | 215 | 70 | 74.52 | 37.30 | 46 |

The combined client-call count fell from 351 to 132. These counts include
harness setup, observations and replay controls; they are not SQL statement
counts. Retained histories increase source operations. Both original sequences
still execute before the retained histories, so their restart and replay
positions do not move. Times are local observations, not performance guarantees.

All 78 named assertions passed. They include 32 replay observations: 30 explicit
queries and two full schema/row comparisons. Both replay runs stopped after
transaction four. They resumed to 67 and 104 transactions respectively. Stop
and final GTIDs and file offsets match the source-operation records. Replay
used an unreachable source at `127.0.0.1:1`.

All five live restarts, saved-schema restart and cleanup passed. A read-only
query of the saved SQLite snapshot confirmed exactly one original
`ALTER TABLE ddlcompat.t ADD aid...` intent, with increment 3, offset 2 and
status DONE. Retained-table rebuilds did not satisfy that original-table filter.

There were 11 source phases: seven body batches, two setup batches and two
cleanup batches. Fixture setup took 14.49s, including 11.88s for container
startup and 2.10s for database setup. Coverage export took 8.81s. Cleanup took
11.44s. The coverage-image build step took 232.1s and reused dependency layers.

All 51 focused Swift tests and 18 feature/migration tool tests passed. The DDL
catalog check passed. The matrix keeps 183 jobs, 1,545 obligations and 182
coverage collections. Execution groups and profile exclusions are unchanged.
No other profile, full suite, syntax suite or benchmark ran.

### Coverage comparison

The new combined runtime report contains 9,176 of 20,880 mapped lines. The prior
local run of these same two cases contained 9,178 lines. The exact differences are:

- Three lines only in the prior run: `ProgressEstimate.swift:93–95`, which update
  the source transaction rate when a later source observation is available.
- One line only in this run: `ApplyPipeline.swift:66`, which waits for space in
  the decoded-event queue.

Both source files are unchanged since the saved CI baseline. These are timing
paths, not removed DDL behavior. The existing
`ProgressEstimateTests.testLiveRateSubtractsSourceGrowth` supplies two controlled
source observations and checks the estimate. It was inspected, not rerun for
this lab-only change. Do not add sleeps to DDL workflows to force these lines.
The comparison is for the pair of cases; it is not per-case coverage attribution.

Evidence:

- `artifacts/lab/20261030T183509Z-a5071396/result.json`
- `artifacts/column-key-workflow-review/results.json`
- `artifacts/column-key-workflow-review/replay-results.json`
- `artifacts/column-key-workflow-review/source-preservation.json`
- `artifacts/column-key-workflow-review/coverage-comparison.json`
- `artifacts/column-key-workflow-review/matrix-comparison.json`
- `artifacts/column-key-workflow-review/unit.log`

Next: review the remaining table/column/index cases against the overall plan.
Identify ordinary DDL workflows that still repeat comparisons. Keep deliberate
restart, rejection and recovery workflows separate. Use saved results before
selecting another implementation slice.

The [completion review](BETA7_TABLE_COLUMN_INDEX_COMPLETION.md) confirms no
ordinary table/column/index case remains to convert in the current group.
The next implementation slice covers RANGE COLUMNS/exchange and HASH/KEY/LIST
partition workflows. No tests ran for this review.
