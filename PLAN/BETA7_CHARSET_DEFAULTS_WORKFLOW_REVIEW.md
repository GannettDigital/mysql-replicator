# Database and table character set defaults: workflow review

Status: implemented and tested on reverse InnoDB. The review below records the
approved design. See [the focused results](#implementation-and-focused-results).
The preceding column-conversion change was committed as `bf13ed6`.

## Decision

Convert only `ddl-compat-charset-defaults`. Keep its ID, group, source SQL,
profile exclusions and engine choices. Keep all ten original operations first,
with restarts before operations 6 and 9. Use five body batches and final
observations. Keep four explicit query checks and the row comparisons which
currently follow INSERT, UPDATE and DELETE.

The proposal has 40 source operations in batches of 5/2/1/29/3. Five retained
tables preserve results that later statements replace. Each operation remains
one source transaction. Do not combine transactions or add an offline replay
path. No production parser, encoding resolver or conversion probe change belongs
in this slice.

The initial review used saved CI evidence, the current harness and checked-out
MySQL 5.7 source. It did not run a build or integration test. The session simulation
in the review script checks the proposed order; it is not a live MySQL test.

## MySQL names and source references

Consult the MySQL documentation when naming features. Use
[Database Character Set and Collation](https://dev.mysql.com/doc/refman/8.4/en/charset-database.html)
and [Table Character Set and Collation](https://dev.mysql.com/doc/refman/8.4/en/charset-table.html).
Use the case title **Database and table character set defaults: MySQL 5.7 DEFAULT syntax**.
The linked 8.4 pages supply feature names. They do not establish acceptance of
the old 5.7 DEFAULT-name syntax. Requests for the old 5.7 manual pages redirected
to a newer manual during this review. Use the checked-out 5.7 implementation for
that syntax and its session rules.

Native references under `.upstream/mysql-server-5.7/` in the root checkout:

- `sql/sql_yacc.yy`, `default_charset` and `default_collation`: DEFAULT clears
  the parsed table charset. A later DEFAULT collation can clear an earlier
  explicit charset. Clause order matters.
- `sql/sql_table.cc`, `set_table_default_charset`: an unset table charset uses
  the table database's defaults.
- `sql/sql_yacc.yy`, CONVERT production: CONVERT TO CHARACTER SET DEFAULT uses
  `thd->variables.collation_database`.
- `sql/sql_class.cc`, THD initialization: the initial `db_charset` comes from
  `global_system_variables.collation_database`.
- `sql/sql_db.cc`, `mysql_change_db` and `mysql_change_db_impl`: USE loads the
  database collation and sets both `db_charset` and `collation_database`. This
  also resets an earlier override when USE names the same database.
- `sql/log_event.cc`, Query event construction and application: the event records
  a database-collation override when the session value differs from `db_charset`.
  Native apply restores the recorded override, or the database baseline when it
  is absent.

The current `TargetSession.resolveTableEncodingDefaults` uses the database and
logged session context for DEFAULT translation. Its no-database fallback uses
the target's global database-collation baseline. Do not replace this behavior
with unconditional USE or an assumed baseline collation. See [ALTER_CHARSET.md](ALTER_CHARSET.md).

## Saved evidence

The current case still matches CI commit `efb3458` byte-for-byte. CI run
`40454033524` has complete measurements and coverage, with no failed or missing
shards. The three applicable default/SQL executions passed:

| Profile | Case seconds | SQL client calls |
|---|---:|---:|
| mysql57-to-mysql84-innodb | 30.87 | 168 |
| mysql57-to-mysql57-myisam | 34.66 | 168 |
| mysql57-to-mysql57-innodb | 31.20 | 168 |

The forward 8.4-source profile remains excluded because it rejects the old
DEFAULT-name syntax with error 1064. This is a source-version restriction, not
a missing target test. Do not remove the exclusion to make the matrix uniform.

Coverage was collected for the larger character-set group. It cannot identify
this case's individual lines or prove equivalence with a table-default case.
Keep the comparison limits in the [character-set review](BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#coverage-comparison-scope).

Local review evidence:

- `artifacts/charset-defaults-workflow-review/baseline.json`
- `artifacts/charset-defaults-workflow-review/source-review.json`
- `artifacts/charset-defaults-workflow-review/review.py`

The proposal file contains original SQL and checks, retained-table histories,
phase order, expected session contexts and cleanup. The audit verifies each
history's operation order and original SQL bytes. It also checks the unchanged
case against the saved commit.

## Original source sessions

The old runner starts a new mysql client for each operation. Neither its client
arguments nor `LabProfile.session` selects a database. The `database` argument
to `step` names the database to compare; it does not issue USE. Batch execution
also starts with no selected database, but shares that client across its writes.
The common resets do not clear a selected database or `collation_database`.

In this table, "initial global baseline" means the value inherited by a new
source connection. Do not assume that changing `collation_server` changes it.

| Operation | Main SQL | Database at the main statement | Database collation at that statement |
|---|---|---|---|
| 1 | CREATE latin1 table | None | Initial global baseline |
| 2 | DEFAULT CHARSET=DEFAULT | None | Initial global baseline |
| 3 | COLLATE latin1_bin, CHARACTER SET DEFAULT | None | Initial global baseline |
| 4 | COLLATE DEFAULT | None | Initial global baseline |
| 5 | CHARACTER SET latin1 COLLATE DEFAULT | None | Initial global baseline |
| 6 | USE ddlcompat; CONVERT TO CHARACTER SET DEFAULT | ddlcompat | utf8mb4_bin from the database |
| 7 | USE ddlcompat; SET collation_database=latin1_bin; CONVERT TO CHARACTER SET DEFAULT | ddlcompat | Explicit latin1_bin override |
| 8 | INSERT café | None | Initial global baseline |
| 9 | UPDATE to été | None | Initial global baseline |
| 10 | DELETE row 1 | None | Initial global baseline |

Operations 6 and 7 can share a client. Each starts with USE, and operation 7
then sets its explicit override. Operation 8 must start a fresh client after
operation 7. Resetting only the collation variable would leave the database
selected and change the logged context. The original restart before operation
9 also starts a new source batch; keep it.

## Retained histories and final checks

Keep these complete prefixes, replacing only qualified `ddlcompat.t` references.
Keep each USE and SET statement as written. All retained tables stay in ddlcompat.

| Prefix | Table | Result kept |
|---|---|---|
| 1–2 | cd_after_default | Table collation after DEFAULT CHARSET=DEFAULT. |
| 1–5 | cd_after_clauses | Table collation after all later DEFAULT clause forms. |
| 1–6 | cd_after_utf8 | Column collation after conversion using database defaults. |
| 1–8 | cd_after_insert | Row bytes after the original INSERT into the converted latin1 column. |
| 1–9 | cd_after_update | Row bytes after the original UPDATE. |
| Original final table | t | latin1 column/default metadata and no rows after DELETE. |

Five histories preserve different overwritten results. A later DEFAULT clause
could correct an earlier wrong table default, so prefix 5 does not replace prefix
2. Conversion in operation 6 can correct an earlier wrong default, so prefix 6
does not replace prefix 5. Operation 7 replaces the utf8mb4 column collation.
UPDATE replaces the inserted bytes, and DELETE removes them. Do not retain only
the four explicit charset checks and discard the old INSERT/UPDATE comparisons.

Map the four original queries without changing selected columns, WHERE clauses,
ordering or expected strings:

1. Operation 2 TABLE_COLLATION query: cd_after_default, expected utf8mb4_bin.
2. Operation 5 TABLE_COLLATION query: cd_after_clauses, expected utf8mb4_bin.
3. Operation 6 v COLLATION_NAME query: cd_after_utf8, expected utf8mb4_bin.
4. Operation 7 v COLLATION_NAME query: original t, expected latin1_bin.

Add explicit final queries for `id,HEX(v) ORDER BY id` on cd_after_insert and
cd_after_update. Expected values are `1\t636166E9` and `1\tE974E9` respectively.
These bytes follow the declared latin1 column; obtain confirmation from the
focused native run. Keep full source/native/target schema and row comparisons.
Also require COUNT(*)=0 on original t and its final TABLE_COLLATION=latin1_bin.
This gives eight final query checks across six base tables.

## Five body batches

1. **table-default-clauses:** original operations 1–5. No selected database.
2. **convert-database-and-session-defaults:** original operations 6–7. Keep the
   first deliberate applier restart. Both operations issue their original USE.
3. **insert-after-session-reset:** original operation 8. A new client removes
   the selected database and latin1 override. Do not restart the applier here.
4. **update-delete-and-retain-encoding-states:** original operations 9–10, after
   the second deliberate restart. Append all retained histories as follows:
   first execute each history's operations 1–min(5,prefix), while no database is
   selected. Then execute operation 6 for cd_after_utf8, operations 6–7 for
   cd_after_insert, and operations 6–7 for cd_after_update. Each selected tail
   starts with USE. This batch has 29 source operations.
5. **retain-insert-and-update-results:** a new client executes operation 8 for
   cd_after_insert, then operations 8–9 for cd_after_update. No database is
   selected and no override carries over. This batch has three operations.

The batch sizes are 5/2/1/29/3, for 40 operations. Original operations 1–10 stay
first and unchanged. Retained histories are interleaved to share the required
session boundaries. Each history keeps its own original operation order. This
avoids opening a separate client for each retained prefix. Keep the existing
phase helper; no general session-reset mechanism is needed for this proposal.

Every Step keeps transactions=1. Capture source warnings, but do not require
empty warnings from the deprecated session override. Do not add a FULL metadata
override; this case has no ENUM/SET label requirement. Keep all three applicable
profiles and their default engine choices.

After saved-state assertions, cleanup drops only the five retained tables in
one source operation:

```sql
DROP TABLE ddlcompat.cd_after_default,ddlcompat.cd_after_clauses,ddlcompat.cd_after_utf8,ddlcompat.cd_after_insert,ddlcompat.cd_after_update;
```

Leave original t for the shared saved-schema restart. Keep exact GTIDs, file/end
offsets, six current saved schemas and DONE DDL intents. No existing replay
boundary needs to be moved, and no new replay test belongs in this slice.

## Implementation and focused validation

1. Convert only this case with existing phase/final-observation helpers. Use the
   phase order in the proposal. Keep the exclusion and original restarts.
2. Add focused unit tests for the original UTF-8 bytes, per-history order,
   session boundaries, unchanged USE/SET clauses, four original predicates,
   two retained row outcomes, final DELETE result and owned cleanup. A test must
   reject a proposed phase order that carries the selected database or override
   into an originally unselected statement. Check metadata on the emitted Query
   events where existing evidence allows; distinguish an abstract session model
   from a server observation.
3. Run affected workflow and phase/final-observation unit tests. Run selection
   tool tests only if the selection or inventory code changes. Do not run the
   separate syntax suite for this lab-only change.
4. Run only this case on mysql57-to-mysql84-innodb/default/SQL with coverage.
   This checks the 5.7 syntax and its translation for an 8.4 target. Forward is
   excluded; leave the other 5.7 target profiles and full suite to GitHub Actions.
5. Inspect all 40 body GTIDs and offsets, the final checkpoint, six saved schemas,
   completed intents, raw engines, the original/retained row bytes, native schema
   results, saved-schema restart and cleanup ownership. Use the support bundle
   before any failed-case rerun. Keep the original evidence.
6. Compare catalog and matrix selections with the current 183 jobs, 1,545 catalog
   obligations and 182 coverage collections. Update the test guide and current
   plan only after the focused run. Do not claim individual coverage parity with
   the old whole-group report.

Focused command:

```sh
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite correctness --case ddl-compat-charset-defaults --coverage"
```

Record SQL client calls, case time and separate setup/coverage/cleanup costs.
The proposal has seven CONVERT statements instead of two. It also replaces ten
body waits/comparisons with five body batches and one final comparison. The
extra source/native work can offset those savings. Measure before claiming a
speed improvement. Do not weaken assertions to obtain a lower time.

Next after this case: encoded Query SQL and identifier workflows. Keep native
collation/encoding inventories, ENUM/SET, remaining type/value and key/index
reviews, full-matrix validation, final balancing and short PR selection in the
overall consolidation plan.

## Implementation and focused results

The case now uses five body batches of 5/2/1/29/3 operations. All ten original
SQL operations remain first and byte-for-byte unchanged. Five retained tables
execute complete original prefixes in the reviewed session order. All four
original queries remain. Final queries also check the inserted and updated
latin1 bytes, final table default and DELETE result. Both original restart
points, the forward exclusion and engine choices remain unchanged. No shared
runner, production encoding resolver, metadata override or replay path changed.

The mysql57-to-mysql84-innodb/default/SQL fixture passed all 17 named
assertions. Source, native and target agreed on the retained row bytes:
`636166E9` after INSERT and `E974E9` after UPDATE. Original t was empty after
DELETE. Full schema and row comparisons included all six base tables.

Read-only inspection of the captured relay decoded 40 source Query events,
one for each body GTID. It confirmed database selection for all seven CONVERT
statements. The three session-override conversions recorded database collation
ID 47. The four database-default conversions did not record that override.
All other body DDL events and row-transaction BEGIN events had an empty database
and no database-collation override. This includes the later retained conversion
after an earlier override: its original USE reset the source session as planned.
This is event evidence in addition to the abstract model in the unit tests.

Saved-state inspection confirmed all 40 body groups APPLIED, exact GTIDs and
file/end offsets, the final checkpoint, six current schemas and no unfinished
DDL intents. Raw table data confirmed InnoDB on source, native and target.
Saved-schema restart and cleanup passed. Cleanup dropped only the five retained
tables. The run used one fixture and seven source batches: setup, five body
batches and cleanup.

| Measurement | Saved CI | Focused local run |
|---|---:|---:|
| Case seconds | 30.87 | 28.31 |
| Harness SQL client calls | 168 | 64 |

The hosts differ. These times are not a controlled speed comparison. The case
now executes seven CONVERT statements instead of two. Retained states add real
native conversion work. Setup, coverage export and cleanup times are recorded
separately in `artifacts/charset-defaults-workflow-review/results.json`.

The selected run executed 8,029 of 20,880 mapped first-party lines.
The old coverage belongs to the larger character-set group. This run does not
establish whole-group coverage parity or a loss in cases which did not run.
The source, query and row-state audit preserves this case's original conditions.

All 19 selected Swift tests passed. They cover original SQL bytes, retained
prefix order, restart/transaction/profile conditions, result checks and cleanup.
The session guard rejects merged batches which carry database selection or a
collation override into originally unselected statements. It also rejects a
missing USE before a later database-default conversion.

Formatting, source-preservation, catalog and matrix checks passed. The matrix
retains 183 jobs, 1,545 catalog obligations and 182 coverage collections. Case
ordering, profile exclusions and groups remain unchanged. Selection tool tests
were not repeated because their code and inventory did not change. No other
case/profile, full suite, benchmark or syntax suite ran locally.

Evidence:

- `artifacts/lab/20261104T001731Z-991fcfac/result.json`
- `artifacts/charset-defaults-workflow-review/results.json`
- `artifacts/charset-defaults-workflow-review/state-results.json`
- `artifacts/charset-defaults-workflow-review/session-results.json`
- `artifacts/charset-defaults-workflow-review/relay-records.jsonl`
- `artifacts/charset-defaults-workflow-review/source-preservation.json`
- `artifacts/charset-defaults-workflow-review/matrix-comparison.json`
- `artifacts/charset-defaults-workflow-review/unit.log`

The [encoded Query workflow](BETA7_QUERY_IDENTIFIER_WORKFLOW_REVIEW.md#encoded-query-implementation-and-focused-results)
passed the forward case, including exact original bytes and connection settings.
Next: review Unicode table-name workflows, then the lower-case variant and DML
identifier cases. Keep native encoding inventories, ENUM/SET, remaining type/value
and key/index reviews, full-matrix validation, final balancing and short PR
selection in the overall plan.
