# Compound ALTER TABLE renames

Branch: `beta/6/60-compound-table-renames`, based on branch 59.

## Native rules

MySQL 5.7.42 and 8.4.8 InnoDB probes accepted:

- ALTER TABLE RENAME with an optional TO or AS.
- RENAME before or after column changes in the same ALTER.
- A rename to the existing table name.
- Multiple rename clauses in one ALTER. Only the last destination is used.
- A parent table rename with a referenced-column rename. Child FK metadata
  changes to the final table and column names.
- A child table rename with a dropped and added FK.

An ALTER rename list differs from a RENAME TABLE list. RENAME TABLE visits each
pair in order. ALTER retains its final destination and applies one table change.
The pinned grammar is `alter_list_item` in `sql/sql_yacc.yy`. Its RENAME action
assigns the final table name in Alter_info.

## Implementation

Standalone renames use the existing table/view rename path. Compound ALTER
first predicts column, index and FK changes under the original table name.
It then changes the final table identity and every affected FK reference.
The plan keeps both table names and all changed peer schemas in the DDL journal.

For supported forms, the target receives the original ALTER once. The applier checks the new table
schema and the removal of the old name after success. Uncertain DDL remains
pending. No separate ALTER/RENAME statements or automatic retries are added.
A destination that already exists stops preparation. Same-name renames remain
valid. The existing filter check includes all named destinations and rejects
mixed included/excluded DDL.

No SQLite format change is needed. The existing before/after schema transitions
already support a change of table identity.

## MySQL 8.4 native limitation

A 5.7 source accepts a single ALTER that renames a parent table, renames its
referenced column and adds a column. MySQL 8.4.8 can fail this statement with
error 1146. Direct probes reproduced the error without the replicator.

An explicit ALGORITHM=INPLACE makes the DDL succeed in the probe. However, a
subsequent parent-key update does not cascade to the child. SHOW CREATE TABLE
still reports the expected FK. FORCE does not correct this result. COPY fails
with error 1846 for the referenced-column rename.

Do not translate this statement to INPLACE. The applier rejects the affected
combination before target SQL when the target is 8.4. The error identifies the
native limitation. Issue ADD COLUMN as a separate source ALTER. Table rename
plus referenced-column rename passes the direct cascade probe without ADD.
The equivalent child-column change passes the native probe. The guard applies
only to referenced parent columns. It leaves 5.7 targets unchanged.

The separate `alter-rename-target84-refusal` case checks the refusal, unchanged
target and unchanged checkpoint.
It also checks subsequent cascades for supported compound renames. Metadata
comparison alone would not find this native defect.

## Verification

All 512 selected apply/lab unit tests passed. Tests check syntax, final-destination
selection, changed columns, FK peer metadata and mixed filter boundaries.
MySQLSyntax did not change, so its separate suite was not rerun.

The shared `ddl-compat-alter-table-rename` case runs on all four profiles. It
checks cross-schema moves, column changes, same-name renames, multiple rename
clauses, subsequent rows, saved-state restart and offline replay. The InnoDB
variants also change FK definitions and test cascades after the rename.

The eight affected unit tests pass after the final native safety check and
fixture changes. Periphery passes. The catalog check passes with 63 scenarios,
228 registered cases and 51 support requirements. These are inventory counts,
not a complete-support percentage.

The rename case passes with 22 steps, saved-state restart and offline replay on
all four profiles:

| Profile | Run under artifacts/lab | Result |
| --- | --- | --- |
| 8.4 to 5.7 MyISAM | 20261016T164928Z-a5cb4621 | Pass |
| 5.7 to 8.4 InnoDB | 20261016T165506Z-2be81f4e | Pass; separate native-defect refusal also passes |
| 5.7 to 5.7 InnoDB | 20261016T170005Z-e001f5d0 | Pass |
| 5.7 to 5.7 MyISAM | 20261016T170038Z-87a8311d | Pass |

The forward run used binary SHA-256
`dff5087448330f1e634bb0a5bd6faebc228236a51e3c27cfdc4d7e3a36aba974`.
The three 5.7-source runs used
`8d39e9373e4470f5b29bf2b4e386ea56eef79d08c84a96b9225b2ed7312f985f`.
Between these builds, the 8.4-only guard was narrowed to parent columns, its
negative test was isolated, and an unused import was removed. The forward
execution path did not change. Full release qualification remains open.

Earlier failed runs remain under artifacts/lab:

- 20261016T162359Z-996cb939: native 8.4 error 1146. The support bundle retains
  the uncertain DDL and its schema transitions.
- 20261016T162558Z-b0dbd1fe: a fixture used an unqualified intermediate name.
  The source rejected it. The fixture now qualifies the name.
- 20261016T163910Z-c745eee6: the attempted INPLACE workaround passed metadata
  comparison but failed the subsequent cascade assertion. That workaround was
  removed. No production translation uses it.
- 20261016T164733Z-d23c34db: supported live/replay operations and the isolated
  refusal passed. The harness then resumed the normal writer at the intentional
  refusal. Move the refusal to its own case after the normal writer stops.
  Both saved bundles confirm notIssued and unchanged checkpoints.

## Remaining work

This closes selected ALTER table-rename forms. It does not implement RENAME COLUMN
translation for a 5.7 target or every interaction with other ALTER clauses.
The remaining work stays in [the DDL checklist](DDL_COMPLETION_CHECKLIST.md).
