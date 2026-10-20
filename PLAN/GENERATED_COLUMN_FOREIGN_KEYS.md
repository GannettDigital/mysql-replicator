# Generated-column foreign keys

Branch: `beta/6/53-generated-column-foreign-keys`, based on branch 52.

## Native rules

MySQL 5.7.42 and 8.4.8 accept stored generated columns on either side of an
InnoDB FK. Both versions reject virtual generated FK columns.

A stored generated child column permits RESTRICT, NO ACTION and ON DELETE
CASCADE. It cannot use ON UPDATE CASCADE, ON UPDATE SET NULL or ON DELETE SET
NULL. A stored generated parent column can supply values to a normal child
column with those actions.

A normal child column that supplies a stored generated expression has additional
native action restrictions. The target server checks those restrictions during
DDL. An indexed virtual expression can depend on a normal FK child column and
can follow native cascades. The shared workflow checks both forms.

Local upstream references:

- MySQL 5.7 `sql/sql_class.cc`, `Foreign_key::validate`.
- MySQL 8.4 `sql/key_spec.cc`, `Foreign_key_spec::validate`.
- MySQL 8.4 `sql/sql_table.cc`, virtual FK column checks.
- Both versions, `storage/innobase/handler/handler0alter.cc`,
  `innobase_check_fk_stored` for stored-expression base columns.

Disposable probes compared all five action forms for generated parents, generated
children, and normal child columns that supply stored or virtual expressions.

## Implementation

The shared graph validator accepts stored generated columns. A separate native
rule helper checks virtual columns and forbidden generated-child actions.
These checks also apply when a parent is missing.

DML uses the existing generated-column path. It writes base columns and lets the
target calculate generated values. The existing checks compare those values with
the source row image. The target performs FK cascades. There is no new row writer,
configuration option or SQLite format.

## Verification

The selected apply and lab unit run passed 490 tests. Periphery found no unused
code. The shared `ddl-compat-foreign-key-generated` case checks CREATE and ALTER,
stored parent and child values, native cascades, virtual-expression dependencies,
restart and offline replay. Native rejection probes in the same workflow verify
that invalid virtual/action definitions do not change any server's binlog position.

Both InnoDB profiles passed the selected workflow, including restart, offline
replay and the five native rejection definitions. The full profile matrix was not run.

| Profile | Local artifact root |
| --- | --- |
| 5.7 → 8.4 InnoDB | `artifacts/lab/20261016T044905Z-184971aa` |
| 5.7 → 5.7 InnoDB | `artifacts/lab/20261016T045047Z-feb3bd25` |

Both runs used binary SHA-256
`7731837606e3091ab2dfb1fcecc1c6503e2e9b710c629342a6cec366fd276120`.

## Remaining work

Branch 54 adds [compound supporting-index changes](COMPOUND_FOREIGN_KEY_INDEXES.md).
Generated
expression and value boundaries remain subject to the complete support plan.
Virtual FK columns are a native restriction, not a missing replication feature.
