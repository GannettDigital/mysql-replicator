# ALTER column keys and implicit values

Branch: `beta/6/55-alter-column-keys`, based on branch 54.

## Scope

Support inline PRIMARY KEY on ADD, MODIFY and CHANGE column definitions.
Support ADD NOT NULL without a declared default, including AUTO_INCREMENT.
The target checks whether the type, existing rows and SQL mode permit the change.
Do not invent a column default from the value used to fill existing rows.

Normalize an inline key into a column change and a primary-key addition. Resolve
added keys after column changes and old-key removal. This permits a key clause
before its new column and an inline new primary key before DROP PRIMARY KEY.
Validate the complete schema before target SQL. Intermediate definitions can
lack the index required by an AUTO_INCREMENT column.

The normal DDL journal records the old and new schemas and the original SQL.
The target executes that SQL. The applier checks and saves the target schema.
This does not change SQLite tables or add automatic DDL recovery.

## Logged AUTO_INCREMENT settings

MySQL records nondefault `auto_increment_increment` and `auto_increment_offset`
in QUERY_EVENT status field 3. Native replication restores them before DDL.
The codec previously checked this field's bytes but discarded its values.

The codec now exposes both values. An absent field means 1 for each setting.
The DDL session restores both settings on every statement, including the default
values after a statement with nondefault settings. DDL diagnostics retain them.
The C interface changes from ABI 12 to ABI 13. Rebuild Swift and Rust together.
The saved raw event already contains this context, so replay needs no state migration.

## Native behavior and limits

Disposable probes on MySQL 5.7.42 and 8.4.8 covered both InnoDB and MyISAM:

- An inline primary-key addition succeeds on an empty table.
- On one existing row, a new INT primary key without a default receives zero.
- On two existing rows, that same ALTER fails with duplicate-key error 1062.
- New INT NOT NULL and VARCHAR NOT NULL columns fill existing rows with zero
  and an empty string. Their COLUMN_DEFAULT remains NULL in information_schema.
- AUTO_INCREMENT works with an inline key or a separate key clause.
- A key clause can precede the added column.
- MODIFY and CHANGE can add primary-key membership.
- A new inline primary key can precede DROP PRIMARY KEY in the same statement.

AUTO_INCREMENT assignment during a rebuild depends on engine row order and the
ALTER algorithm. This is a native limitation. A probe inserted primary keys 2,
then 1. InnoDB assigned new sequence values in primary-key order. MyISAM assigned
them in insertion order. Both versions showed this difference. With increment 3
and offset 2, default InnoDB ALTER and COPY also assigned different first values.

The shared case uses COPY for nondefault sequence settings and known row order.
This is not a guarantee for arbitrary populated cross-engine tables. To preserve
a particular row-to-ID mapping, add a nullable ordinary column, fill explicit IDs
through row-logged DML, then add the required key and AUTO_INCREMENT attribute.
Do not assume ALTER will generate the same IDs independently on both engines.
The applier does not rewrite ALTER algorithms or assign replacement IDs.

Native reference paths:

- MySQL 5.7 `sql/sql_table.cc`: `mysql_prepare_alter_table` checks implicit values;
  `copy_data_between_tables` assigns new AUTO_INCREMENT values during row copy.
- MySQL 5.7 `sql/log_event.cc`: QUERY status serialization near line 3707 and
  native session restoration near line 4577.
- MySQL 8.4 has the corresponding paths in `sql/sql_table.cc` and `sql/log_event.cc`.

## Verification

The shared `ddl-compat-alter-column-keys` case runs on all four profiles. It checks
metadata, existing values, primary-key changes, logged sequence settings, INSERT,
UPDATE, DELETE, saved-state restart and offline replay. It also checks that later
DDL returns to default sequence settings. The journal retains nondefault settings.

Validation passed:

- 573 selected Swift apply, lab and codec tests.
- Four Rust query-context tests, including malformed and duplicate status fields.
- Periphery, with no unused code reported.
- The selected integration runs below, including restart and offline replay.

| Profile | Steps | Result file under `artifacts/lab/` |
| --- | ---: | --- |
| 8.4 → 5.7 MyISAM | 30 | `20261016T052922Z-b2cf155c/result.json` |
| 5.7 → 8.4 InnoDB | 58 | `20261016T053116Z-e79d06f6/result.json` |
| 5.7 → 5.7 MyISAM | 30 | `20261016T145903Z-39462d32/result.json` |
| 5.7 → 5.7 InnoDB | 58 | `20261016T150055Z-1e20dfd5/result.json` |

Both InnoDB runs also include the compound FK/index regression case. All four
runs used binary SHA-256
`566500ac104778cedf8de2bd0fd0f0b96f00bb88817eb80d6057cdd2fb25a8ad`.

These were selected tests, not the full correctness matrix. This increment does
not qualify every ALTER combination or generated expression.
