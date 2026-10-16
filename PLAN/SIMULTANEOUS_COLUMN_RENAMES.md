# Simultaneous column renames

Branch: `beta/6/66-simultaneous-column-renames`.

## Native behavior

MySQL 5.7 and 8.4 accept a swap in one ALTER:

```sql
ALTER TABLE t CHANGE a b INT, CHANGE b a BIGINT;
```

Each CHANGE refers to an original column. Values follow that column. Existing
primary keys, secondary indexes and foreign keys follow the same column.
MySQL 8.4 also accepts `RENAME COLUMN a TO b, RENAME COLUMN b TO a`.
The applier translates RENAME COLUMN for a 5.7 target with the existing native
column-definition translation.

The local source references are `mysql_prepare_alter_table` in
`.upstream/mysql-server-5.7/sql/sql_table.cc` and
`.upstream/mysql-server/sql/sql_table.cc`. Both implementations first match
original fields. They then apply ADD and FIRST/AFTER placement in statement
order. Native code uses field identity to remove a column before placement.
A final column name alone cannot identify that field during a swap.

## Implementation

`AlterColumnLayout` resolves all original columns before it checks final names.
It uses original ordinals for column placement. It maps existing key parts once.
It retains key prefixes, directions, index visibility and parser names.
Explicit index drops still find their original index when a column drop removes
its last part.

`ColumnNameChanges` also maps the existing FK relationships once. New FK
constraints already use final names. They do not pass through this mapping.
Incoming relationships on other tables are included in the DDL transition.
Supporting indexes that MySQL can remove are compared with final column names.

The target receives one ALTER. No temporary names or extra ALTER statements
are used. The existing DDL journal records the old and proposed schemas before
execution. Schema replacement and the applied checkpoint still share one
SQLite transaction. This work does not add automatic recovery for uncertain DDL.

## Restrictions

Native expression rules still apply. Replace a dependent generated/default
expression or functional index explicitly when the native server requires it.
The applier does not rewrite an expression by text substitution. Branch 67
supports [partition dependency renames](PARTITION_COLUMN_RENAMES.md) when the
same ALTER replaces or removes partitioning.

Missing original columns, repeated changes to one original column, and duplicate
final names cause an error before target SQL. Native ALTER DEFAULT requires an
unchanged original column. A CHANGE and a separate ALTER DEFAULT for that same
column are not combined by this implementation.

## Tests

- Unit tests cover swaps, chains, reversed clause order, FIRST/AFTER, ADD,
  dropped names, key prefixes, self FKs and generated-expression dependencies.
- A checkpoint-failure test checks both saved layouts and the pending status.
  It also checks the final schema after completion and reopening SQLite.
- `ddl-compat-column-swaps` covers CHANGE on all four profiles.
- `ddl-compat-column-renames` includes a RENAME COLUMN swap on the 8.4 source.
- `ddl-compat-foreign-key-column-swaps` covers parent, child and self FKs on
  InnoDB targets. It checks cascades and new FKs in the same ALTER.
- Shared cases include following DML, saved-state restart and offline replay.

## Verification results

Run `20261016T182654Z-3d1d573c` passes all seven applicable profile/case pairs.
The other five pairs are not applicable: MySQL 5.7 has no RENAME COLUMN syntax,
and MyISAM has no foreign keys.

| Profile | Selected steps | Result |
| --- | ---: | --- |
| 8.4 → 5.7 MyISAM | 33 | Pass |
| 5.7 → 8.4 InnoDB | 37 | Pass |
| 5.7 → 5.7 MyISAM | 20 | Pass |
| 5.7 → 5.7 InnoDB | 37 | Pass |

These are selected DDL workflows, not full profile qualification. Each includes
restart and offline replay. The catalog check passes with 235 registered cases.
Periphery reports no unused code. All 214 focused unit tests pass. They include
schema prediction,
FK metadata, DDL checkpoint failure and the shared lab catalog.

Full release qualification remains assigned to GitHub.
