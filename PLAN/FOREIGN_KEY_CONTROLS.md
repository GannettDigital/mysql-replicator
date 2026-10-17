# Foreign-key relationships and source check settings

Branch: `beta/6/47-foreign-key-controls`.

## Native behavior

Both local MySQL source trees restore `NO_FOREIGN_KEY_CHECKS_F` before row
application. The flag is bit 1 in a row event. Query events use bit 26 in
`Q_FLAGS2_CODE`. These settings are event context. A standalone SET does not
need a separate committed replication group.

Source references:

- MySQL 5.7 `sql/log_event.cc`, `Rows_log_event::do_apply_event`, near line 11042.
- MySQL 8.4 `sql/log_event.cc`, the same function, near line 9693.
- MySQL 5.7 `libbinlogevents/include/rows_event.h`, flag definitions.
- MySQL 5.7 `storage/innobase/row/row0ins.cc`, near line 1184: InnoDB permits
  cyclic DELETE cascades. It rejects a cyclic UPDATE cascade that returns to a
  table already being updated. It also limits cascade depth.

InnoDB does not log each implicit cascade as a separate row event. The target
must retain the matching relationship and check setting. With checks disabled,
a parent DELETE must leave the child rows unchanged. Restoring checks does not
scan old rows for invalid references.

MySQL 5.7 reports an omitted action as `RESTRICT`. MySQL 8.4 reports it as
`NO ACTION`. Both mean an immediate constraint check in InnoDB. Schema prediction
uses the target version. The comparison normalizes only those action fields;
constraint names, columns and cascade actions must still match. The 8.4 source
maps `FK_OPTION_UNDEF` to `RULE_NO_ACTION` in `sql/dd/dd_table.cc`.

## Changes

- Permit self-references and cycles in an otherwise valid relationship graph.
  Keep the existing table, column, key, filter and component-size checks.
- Retain `foreignKeyChecks` on each planned row mutation. Read the flag from
  each row event. A transaction can change the setting between statements.
- Set the target session value before each write when the value changes.
  Do not add a SET call for every row. Each new connection has an empty cache.
- Do not combine INSERT rows that have different check settings. Keep source
  transaction boundaries and rollback rules.
- Restore the Query-event setting before DDL. Keep schema validation in place
  when checks are disabled. This permits ADD FOREIGN KEY over existing rows
  that have no parent, if the referenced table and supported key exist.
- Include the setting in DDL diagnostics and offline recovery rows. Raw relay
  events already retain the flags. No SQLite format change is required.

## Tests

`ddl-compat-foreign-key-controls` compares source, native and target after each
step. It covers self-reference DELETE cascades, two-table cycles, disabled-check
INSERT/UPDATE/DELETE, check changes within a transaction, and ADD FOREIGN KEY
with checks disabled. It also covers saved-state restart and offline replay
with an unreachable source.

`foreign-key-safety` tests rollback after a transaction first writes with checks
disabled, then fails after checks are restored. Recovery must retain both flag
values. Existing filter, schema-drift, nonunique-key and rollback tests remain.
`reject-foreign-key` uses a nonunique parent key on InnoDB. MyISAM still rejects
foreign-key DDL.

The apply, codec and lab unit run passed 549 tests. Periphery passed.
MySQLSyntax did not change, so its separate test suite was not run.

The first 5.7 InnoDB run passed all four selected cases:
`artifacts/lab/20261016T020952Z-32f3d854/result.json`.
The first 8.4 run found the omitted-action metadata difference described above.
Its preserved support bundle is under
`artifacts/lab/20261016T020745Z-82c63f59/`.
The target acknowledged CREATE TABLE, but the expected action string differed.
The target-version rule fixes schema prediction. No SQL substitution is needed.

Final InnoDB results:

| Profile | Selected cases | Result path under `artifacts/lab/` |
| --- | --- | --- |
| `mysql57-to-mysql84-innodb` | New controls, existing FKs, safety and FK refusal; 62 shared steps | `20261016T021823Z-99028a0c/result.json` |
| `mysql57-to-mysql57-innodb` | New controls and safety; 28 shared steps | `20261016T022010Z-9b43495f/result.json` |

Both runs passed. They used build-input digest
`6080aee160c87fc846d04c2d1dd5ca90973d37ed27978539a7003dcb4b4fe809`
and binary SHA-256
`7c75e8c0bf0f575b500bd4bb0d11f574747c57549f7fd0a1b7c289683fcfe093`.
Both offline recovery reports retain `[false, true]` for the failed transaction's
row check settings. The target retained no rows from that rolled-back transaction.

Both MyISAM regression runs also passed `positive` and `reject-foreign-key`.
They use the same build-input digest and binary above:

- 8.4 to 5.7 MyISAM: `artifacts/lab/20261016T022505Z-dfc0dbb5/result.json`.
- 5.7 to 5.7 MyISAM: `artifacts/lab/20261016T022605Z-4b35ea02/result.json`.

The positive case compares INSERT, UPDATE and DELETE results, target/native
binlogs and SQLite checkpoints. The refusal case confirms that foreign-key DDL
still stops before target SQL on MyISAM.

This is selected verification. The full release matrix and performance suite
were not run for this increment.

## Remaining limits

This change does not complete all foreign-key DDL support. Branches 49 and 50 add
[missing parents](MISSING_PARENT_FOREIGN_KEYS.md) and
[native parent keys](FOREIGN_KEY_PARENT_KEYS.md). Branch 53 adds
[stored generated FK columns](GENERATED_COLUMN_FOREIGN_KEYS.md). Partitioned FK
tables retain native engine restrictions. Branch 48 adds supporting-index additions,
FK-column renames and internal database DROP. See [FK DDL transitions](FOREIGN_KEY_DDL.md).
The next DDL work must distinguish target-version restrictions from tool gaps.

The tool still rejects `RELAXED_UNIQUE_CHECKS_F` and other unqualified row flags.
Disabling foreign-key checks does not disable unique-key or before-image checks.

Recovery records describe explicit row changes and the relationship component.
They do not include every implicit cascade image or prove whether COMMIT finished.
No automatic retry or automatic reconciliation is added.
