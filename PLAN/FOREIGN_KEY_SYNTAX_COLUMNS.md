# FK syntax and column rules

Branch: `beta/6/51-foreign-key-syntax-columns`, based on branch 50.

## Native behavior and implementation

MySQL 5.7 accepts `MATCH FULL`, `MATCH PARTIAL` and `MATCH SIMPLE`. Its InnoDB
scanner stops at MATCH and ignores the following ON DELETE and ON UPDATE actions.
MySQL 8.4 accepts those actions. The applier removes MATCH and its following actions
from 5.7 source DDL. This keeps the source behavior. The journal keeps the original
SQL, target SQL and rule `mysql57-match-ignores-foreign-key-actions`.

Both tested versions generate `table_ibfk_N` when FOREIGN KEY has an index name
but no explicit constraint name. An explicit CONSTRAINT name takes precedence
over the index name when InnoDB creates a supporting index. The parser now accepts
these forms. Parent identifiers follow `lower_case_table_names`.

InnoDB compares column storage types. It does not require identical SQL type text:

- Nonbinary strings must use the same collation. Their lengths can differ.
- Binary strings, modern temporal types, DECIMAL and BIT share a binary category.
- Integer storage width and signedness must match. ENUM and SET use their integer
  storage width. YEAR uses an unsigned byte. DATE uses three signed bytes.
- FLOAT and DOUBLE are separate categories.

Index checks still require full leading columns. These rules do not permit an FK
on a prefix index. The target still checks the DDL and enforces row constraints.
For unusual type pairs, DDL acceptance does not imply that all values can match.

Local upstream references:

- MySQL 5.7 `storage/innobase/dict/dict0dict.cc`: raw FK SQL scanning after the
  referenced-column list, and constraint-name selection.
- Both versions, `storage/innobase/rem/rem0cmp.cc`: `cmp_cols_are_equal`.
- MySQL 5.7 `storage/innobase/handler/ha_innodb.cc`:
  `get_innobase_type_from_mysql_type`.
- MySQL 8.4 `storage/innobase/handler/ha_innodb.cc`:
  `innodb_fill_fake_column_struct`.

Disposable probes on 5.7.42 and 8.4.8 confirmed the names, MATCH difference and
storage-compatible pairs. A 5.7 probe also confirmed that MATCH hides SET DEFAULT.
Without MATCH, InnoDB rejects SET DEFAULT.

## Verification

The selected apply and lab unit run passed 487 tests. Periphery found no unused
code. Both InnoDB profiles passed the selected workflow (21 reported steps each).
The full profile matrix was not run.
The workflow checks names, ignored cascade actions, string and binary lengths,
ENUM ordinals, compatible DDL types, restart, offline replay and durable SQL records.
No SQLite format change or new setting is required.

| Profile | Local artifact root |
| --- | --- |
| 5.7 → 8.4 InnoDB | `artifacts/lab/20261016T042524Z-c08479c0` |
| 5.7 → 5.7 InnoDB | `artifacts/lab/20261016T042715Z-1b72f995` |

Both runs used binary SHA-256
`f89ebebf01c79667cc9dd91adc510a9fde5902428dc8c3afe4a8f55d9e451522`.

## Remaining limits

Branch 53 adds [stored generated FK columns](GENERATED_COLUMN_FOREIGN_KEYS.md).
Some compound index changes need further work.
Branch 52 adds [cross-database DROP](CROSS_DATABASE_FOREIGN_KEYS.md). Partitioned InnoDB FK tables have native engine restrictions.
Pre-5.6 temporal storage is not qualified by these profiles.
