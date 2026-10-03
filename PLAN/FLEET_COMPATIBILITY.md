# Fleet compatibility work

The private binlog summary under `PLAN/data/` identifies common types and a few
missing families. Counts of row events or column occurrences do not establish
schema compatibility. This plan and the checked-in fixtures contain no production
names or row data.

## Current implementation slice

- Composite primary keys: 1–16 ordered, full, nonnullable supported scalar
  columns, including `(report_date DATE, id INT)`. Discovery validates every key
  part. Reads, UPDATE and DELETE bind the complete tuple. Key changes check the
  destination tuple and still verify the entire before image. A collation-equivalent
  text key may resolve to the original row; another occupied row is rejected.
- Schema serialization retains the old `primaryKey` string for one-column keys.
  Composite schemas use `primaryKeyColumns`. New code reads old clean-stop state;
  older binaries cannot read new composite schemas. ADD/MODIFY/RENAME/LIKE retain
  all key parts; dropping any key column is rejected. CREATE accepts a composite
  PRIMARY KEY list and DATE, CHAR and BINARY columns within the existing grammar.
- CHAR(0–255) and BINARY(0–255): decode STRING metadata, restore omitted BINARY
  zero padding and normalize CHAR trailing spaces to the target session's normal
  CHAR read behavior. Binary bytes remain exact. VARCHAR/VARBINARY accept wire
  type 15 or 253 when metadata matches.
- ENUM and SET: preserve numeric ordinals/bitmasks instead of interpreting labels
  as SQL literals. The target reads them numerically for exact before-image checks.
  One-/two-byte ENUM and up to 64-bit SET values are supported. Ordered source
  labels must exactly match target labels and collation. ENUM's special error
  ordinal zero is rejected before writes under the strict-target contract; an
  explicitly declared empty-string label remains supported at its real ordinal.
- ENUM/SET require source `binlog_row_metadata=FULL`, because MINIMAL omits label
  definitions. Missing or reordered labels fail before writing. Other existing
  types retain their MINIMAL/FULL metadata behavior.
- Source table-map and target schema/SQL caches allow up to 1,024 entries instead
  of 64. The decoder retains its separate 4 MiB table-map byte bound and 256-column
  bound; the increase does not remove memory/resource limits.
- Codec ABI 6 adds owned, length-prefixed ENUM/SET label metadata. Rebuild both
  Rust and Swift (`make test`/`make build`); do not combine old archives and new
  headers. Relay framing and checkpoint versions are unchanged.

Text remains restricted to matching utf8mb4_bin, utf8mb4_unicode_ci or
utf8mb4_general_ci. This slice does not add charset conversion. DDL for ENUM/SET
is still outside the parser grammar; provision those definitions before starting.
FLOAT/DOUBLE, JSON, BIT, spatial types and multi-statement source transactions
remain separate work. TYPE support does not mean arbitrary MySQL DDL support.

## Verification

- Rust: 6 tests passed. Swift: 246 tests passed, including raw-wire fixed strings,
  two-byte ENUM/64-bit SET, composite schema serialization, and reload of 160
  saved table schemas.
- GTID extended live suite: 20 cases passed against the MySQL source, native
  reference and MySQL 5.7 target. New cases exercise 160-table discovery,
  composite-key CREATE, clean stop/resume through ADD and RENAME, key-changing
  UPDATE/DELETE, and destination-key collision rejection without checkpoint
  advancement. Existing before-image and interrupted-write checks also pass.
  Evidence: `artifacts/dml-suite/20261003T063420Z-f93dc31b-auto-autocommit-myisam/`.
- File-position type matrix: 61 cases passed, comparing exact observed row bytes
  across source/native/target after every positive phase. Covers the new fixed
  strings, ENUM/SET widths, composite keys and collation-equivalent text keys,
  plus existing integer/decimal/temporal/LOB and SQL-form regressions. Negative
  cases confirm rejection before target writes or checkpoint advancement.
  Evidence: `artifacts/dml-suite/20261003T063515Z-e567422b-position-autocommit-myisam/`.

Reproduce with `make test`, then `make dml-suite ARGS='--positioning gtid --slice extended'`.
Run the type matrix with `make dml-suite ARGS='--positioning both --slice matrix'`.
The ENUM/SET positive fixtures explicitly enable FULL metadata in either transport
mode; a separate negative fixture checks rejection when labels are omitted.

## Requested sanitized inventory and fixtures

Have the approved data-access agent produce a sanitized schema inventory and,
where authorized, synthetic SQL/binlogs preserving relevant behavior. No live
credentials, production connection details or original customer row values are
needed here. Use stable replacement database/table/column names consistently.

For each table include:

- Source server version, binlog row image/metadata settings, column ordinal,
  exact COLUMN_TYPE (including signedness and precision), nullability, charset,
  collation, defaults, EXTRA attributes and raw binlog type IDs/metadata.
- Primary-key columns in SEQ_IN_INDEX order, prefix lengths, secondary unique
  indexes, engine and whether generated columns/partitioning/triggers exist.
- Ordered ENUM/SET members. If their text is sensitive, replace it consistently
  on both sides while preserving empty labels, case/collation equivalences,
  quotes, backslashes, commas, character widths and number of members.
- Maximum observed byte lengths for variable/binary/JSON values; presence of
  non-ASCII text, embedded NUL, trailing padding, zero/invalid dates, enum ordinal
  zero, and floating-point extrema. Report characteristics, not original values.

Useful synthetic rows include the same id on different dates, changes to either
part of `(report_date,id)`, destination-key collisions, CHAR trailing spaces,
BINARY zero padding, enum values around ordinals 255/256, SET bits 0/63, NULL and
empty values. Include INSERT/UPDATE/DELETE, a clean stop/resume, and representative
schema changes. Source and target definitions must both be supplied so matching
labels, key order and collations can be checked independently.

## Following slices

1. Compare the sanitized charset/collation inventory with the current allowlist;
   add explicitly tested encodings without silently changing target collation.
2. Add FLOAT/DOUBLE transport and before-image handling with exact numeric
   round-trip tests and explicit finite/range rules.
3. Add MySQL 5.7-compatible JSON decoding/binding/comparison, including numeric
   fidelity and explicit handling of newer partial-JSON row events.
4. Extend DDL separately for the newly supported prepared-table definitions.
