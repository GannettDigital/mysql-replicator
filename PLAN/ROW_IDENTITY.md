# Row identity and recovery

Branch: `beta/6/45-unique-row-identity`, based on branch 44.

This file records the unique-key increment. Branch 46 adds
[full-row matching for tables without a usable unique key](KEYLESS_ROWS.md).

## Native behavior

Native row replication first seeks a primary key whose columns are present
in the row image. It then seeks a nonnullable unique key. Other lookup methods
can use nonunique indexes and full-row matching. Those later methods are not
part of this increment.

MySQL can promote a nonnullable full unique index to its internal primary key
when no PRIMARY KEY was declared. In 8.4, FULL table-map metadata can report
that index as the primary key. It need not have the same name or order as the
lookup key that this tool selects.

Local upstream references:

- 5.7 `sql/log_event.cc`, `search_key_in_table`: key selection for row apply.
- 8.4 `sql/dd_table_share.cc`: selection of a suitable internal primary key.
- 8.4 `sql/log_event.cc`, `Table_map_log_event::init_primary_key_field`: binlog metadata.

## Selected scope

Keep the declared primary key when it exists. Otherwise select a UNIQUE BTREE
index with 1–16 full, nonnullable base scalar columns. The existing scalar key
restrictions also apply. Prefixes, expressions, generated columns, JSON, spatial
columns and TEXT/BLOB columns are not fallback keys. A nullable unique key is
not enough, even when current rows contain no NULL values. These are current
tool limits, not a claim that native MySQL rejects these tables.

If several eligible keys exist, select by normalized index name. Preserve key
column order. The choice need not match the native lookup order because each
eligible key identifies at most one row. Keep all declared primary and secondary
index metadata. Do not report a UNIQUE index as a declared PRIMARY KEY.

INSERT retains all target constraints. UPDATE and DELETE use the old lookup
key, verify the full before-image, and check the affected-row count. Key changes
check the new key before the write. Collation-equivalent keys can identify the
same row; exact before-image comparison remains required.

Ordered DDL can replace a key or switch between primary and unique keys. Check
the completed ALTER schema for a usable identity. An intermediate prediction
inside one ALTER can lack a key while that statement replaces it.

## Durable records

For a table without a primary key, save `rowIdentity` in its schema JSON. It
contains `kind`, `index` and ordered `columns`. Keep `primaryKeyColumns` empty.
The row intent already refers to that schema version and the retained source
event. No SQLite table migration is needed. Existing primary-key schema records
keep their previous encoding.

On reload, validate the saved identity against the saved index and column
metadata. Do not select a different key for that historical schema. A new DDL
schema can select a new key. Recovery reads the saved schema and reports the
old/new lookup values, exact row images and selected index. Its expectation
folding includes the identity, so different keys do not share an entry.

A matching row is not proof of a successful COMMIT. The DBA still resolves an
uncertain group. Collation-equivalent values can make exact-key folding
ambiguous. This change does not add automatic retry or crash repair.

## Tests

Unit tests cover candidate selection, ineligible keys, SQL predicates, saved
schema reload, changed-index rejection and pending relay recovery. The shared
`ddl-compat-unique-row-identity` case covers composite and text keys, key-value
changes, index replacement, primary-key addition/removal, AUTO_INCREMENT, clean
restart and offline stop/resume. Its row comparison uses an independent order
over exact row values when a table has no primary key.

Nullable, prefix, expression and keyless matching remain future work. Full
release qualification remains separate from these selected tests.

## Verification

Each selected run passed live apply, key changes, ordered DDL, clean restart
and offline stop/resume. Each run executed 24 shared steps.

| Profile | Lab run | Build |
| --- | --- | --- |
| 8.4 → 5.7 MyISAM | `20261015T235945Z-9fc0aadb` | Final |
| 5.7 → 8.4 InnoDB | `20261015T234340Z-6e6cd6a9` | Initial |
| 5.7 → 5.7 MyISAM | `20261015T234558Z-d9af6729` | Initial |
| 5.7 → 5.7 InnoDB | `20261015T235742Z-0a939df8` | Final |

- Final build-input digest: `a268eca9ee8aefadffbc69fc3d62084f80a2f085054cae02948d52ced9175919`.
- Initial build-input digest: `db5521c5357b7c75cdd2e1ceeaa242e34f78e0be6eb4e10af5ced3fe8ec8353d`.

The initial build passed the first three profiles. Final review then added a
regression for partially supplied optional table-map metadata. Available key
flags must agree with a candidate even when other names are absent. The final
build passed the forward repeat and the 5.7 InnoDB run. The reverse and 5.7
MyISAM workflows were not repeated after that validation-only change.

The final apply/lab unit run passed 468 tests. It includes saved unique-key
schemas, pending relay inspection, DBA retry resolution, and reopened state.
Periphery passed. MySQLSyntax did not change, so its separate syntax suite
was not run. Full release qualification remains open.
