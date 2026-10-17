# ALTER TABLE charset support

Status: continued on `beta/6/32-alter-charset`, after the syntax extraction.
Selected cases passed, but the final run reported changed checkout inputs.
A fixed-input confirmation and full conversion qualification remain open.

## Native behavior

`DEFAULT CHARACTER SET` and `COLLATE` change table defaults. They do not change
existing columns. New columns in the same ALTER use the final table default,
even when their ADD clause comes first.

`CONVERT TO CHARACTER SET` also changes text columns. MySQL can widen TEXT types
to preserve their character capacity. Binary columns are not converted back to
text. Conversion to `binary` changes text fields to binary fields.

Native 5.7 references are `sql/sql_yacc.yy` (`default_charset`,
`default_collation`, and the CONVERT production), `sql/sql_table.cc`
(`get_sql_field_charset`, `prepare_blob_field`), and `sql/field.cc`
(`Create_field::Create_field`). The local upstream tree pins the source version.

## Metadata preparation

The applier keeps table-default changes separate from column conversion.
For an existing text column, it creates a private temporary field with
`CREATE TEMPORARY TABLE ... AS SELECT ... LIMIT 0`. No application rows are
copied. It applies native ALTER to that field, then reads the resulting type,
encoding, labels and default. This work occurs at DDL barriers, not in the
row apply loop. The temporary table is removed on success or failure.

The complete before/after schema is saved before application DDL execution.
The applier sends the recorded statement once, subject to explicit collation
translation. Existing metadata checks, cache invalidation, pending DDL records
and checkpoint rules still apply. A native conversion error can leave a pending
DDL operation. The applier does not retry uncertain application DDL.

## Native probe limits

A populated 5.7 InnoDB ENUM with the latin1 label `é` failed conversion to
utf8mb4 with error 1265. A non-ASCII ENUM default also produced error 1067 in
an empty-table probe. These are native source outcomes. The positive shared
case uses ASCII ENUM/SET labels, while VARCHAR and TEXT contain non-ASCII data.
Do not claim all ENUM/SET conversion combinations from that selected test.

## Checks

The shared cases are `ddl-compat-table-charset` and
`ddl-compat-charset-conversion`. They check metadata, exact stored bytes,
defaults, generated columns, prefix indexes, following DML and clean restart.
The full charset, SQL-mode, conversion, failure and offline replay matrix is
still open. A selected passing case does not qualify the full catalog.

## DEFAULT syntax across versions

Native 5.7 accepts a charset or collation name of `DEFAULT`. Native 8.4 rejects
these forms with error 1064. The applier resolves the old syntax to explicit
encoding names for an 8.4 target. This is an equivalent syntax translation; it
does not add a collation substitution policy.

For table defaults, 5.7 resolves an unset default from the table's database.
`COLLATE DEFAULT` resets a preceding explicit charset. For `CONVERT`, the default
comes from the session database collation. A logged database collation overrides
the database default. The conversion collation stays separate from a later table
default. Native references: 5.7 `sql_yacc.yy` default and CONVERT productions,
`sql_table.cc::set_table_default_charset`, and `log_event.cc` handling of
`Q_CHARSET_DATABASE_CODE`.

The source SQL remains in the failure record. The execution SQL contains explicit
table encoding clauses on all targets. This also removes dependence on the target connection’s previous
database selection. The parser uses source byte ranges for
these edits. It does not search and replace words in column defaults or comments.
The `ddl-compat-charset-defaults` case applies to 5.7 sources. The 8.4 source
exclusion states the native syntax rejection.

When a Query event has neither a database nor a logged database collation,
native 5.7 uses its initial `@@GLOBAL.collation_database`. The applier uses the
target baseline value for this case. Set this baseline to the source value.
Changing only `collation_server` does not change that variable. The Query event
does not contain enough data to recover a different unlogged source value.
The positive cases use an explicit database and also test a logged override.

## Validation

- 421 affected apply and lab unit tests passed. After the DEFAULT scope fix,
  27 focused parser and catalog tests passed.
- Run `20261015T064735Z-379fdc60` passed table-default changes, native charset
  conversion and compound clauses on all four profiles. Its new DEFAULT case
  exposed the no-selected-database distinction described above.
- The corrected DEFAULT and compound cases passed in
  `20261015T071224Z-e8556bb6`. The DEFAULT case applies to the three 5.7 source
  profiles. The compound case applies to all four profiles. Each selected
  workflow includes following row changes and saved-schema restart. The outer
  run failed its input-stability check. It is not qualification evidence; a
  fixed-input confirmation is required.
- These cases do not qualify every charset pair, conversion warning, row value,
  SQL mode, archive replay or partial-DDL failure.

## Combined fixed-input confirmation

Run `20261015T073916Z-20bde8e4` passed at stack commit `735d35b`. It ran
21 applicable charset, generated-expression and geometry-prefix cases across
the four profiles. Three cases were excluded for native version restrictions.
The outer lab result passed. All 421 build inputs stayed unchanged. The
build-input digest is
`a1782ef199a53cf7e0991118ce527af8ea37a84dd158574bef32c58bf045b82d`.
This is selected-case evidence, not full feature or release qualification.
