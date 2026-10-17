# Support and limits

This page describes the current source tree. For an installed binary, also check
its release notes. Implementation support, a passing selected test, and a full
release qualification are different claims. Use the CI results for the exact
commit and profile that you intend to deploy.

## Profiles and source requirements

The four [profiles in the README](../README.md#tested-profiles) select explicit
source versions, target versions, and target engines. Other combinations are not
tested. Initial copying, engine conversion, and server upgrades are external tasks.
The target must have a matching baseline and no independent writers or native
replication channels. The applier prefers a supported primary key, then a unique
key with full, nonnullable base scalar columns. Otherwise it matches the full
base-row image and changes one matching row per row event. Duplicate rows and
nullable keys use this path. It can require a table scan for each row event.
See [key selection](../PLAN/ROW_IDENTITY.md) and
[full-row matching and recovery](../PLAN/KEYLESS_ROWS.md).

Sources use ROW logging, FULL row images, CRC32 checksums, and GTIDs. A MySQL 5.7
source requires GTID capture; the 8.4 profile also permits file-position capture.

GTID restrictions apply in both modes. File-position mode selects where capture
starts; it does not enable non-GTID transactions or relax transaction rules. Live
capture requires `gtid_mode=ON` and `enforce_gtid_consistency=ON` on the source.
Replay has the same transaction requirements.
The decoder does not support every binlog format: XA, compressed transaction
payloads remain unsupported. Replay reads raw local binlogs
without a source connection. It has the same DML and DDL limits as live mode.

`target.preserveSourceGTIDs` defaults to `true`. The target records source GTIDs
when its version and privileges permit this. A 5.7 target blocks tagged GTIDs.
With `false`, source GTIDs, including tags, stay only in SQLite. Target GTIDs then
follow the server's normal assignment. Use SQLite to resume in both cases.
See [GTID settings, privileges and Cloud SQL limits](GTID_PRESERVATION.md) and
[tagged GTID tests](../PLAN/TAGGED_GTIDS.md).

MyISAM profiles accept one row statement on one included table per source
transaction. InnoDB profiles also accept transactions with multiple statements
and tables. MyISAM writes cannot be rolled back. Neither profile makes a target
commit atomic with the SQLite checkpoint. Uncertain writes require DBA review;
InnoDB provides explicit recovery inspection and resolution commands.

## Support status

Use these terms when you read this guide and the support catalog:

| Status | Meaning |
| --- | --- |
| Unsupported by this tool (`tool_gap`) | A specific path is refused or not implemented. Native eligibility can still need review. |
| Incompatible with the target (`target_limit`) | The target version or engine cannot retain the source feature or behavior. |
| Rejected by native MySQL (`native_restriction`) | Native MySQL rejects the stated form under the stated settings. |
| Deliberate policy (`safety_policy`) | The tool intentionally excludes the operation, such as installing active target triggers. |
| Not fully tested (`untested`) | The stated combinations still need qualification. Selected tests can already pass. This label is not evidence of an implementation failure. |

Implementation and qualification are separate. `subset` states a bounded
implementation scope. It does not identify an additional unsupported SQL form.
`implemented` does not mean that every profile, value boundary and failure path
has passed release checks. Candidate test IDs are pointers, not proof of a pass.

The current specific tool restrictions include partial source DDL errors,
some typed JSON values, MyISAM groups outside one statement/one included table,
and table-name modes other than matching
0 or 1. See the source requirements above for unsupported event formats. Expression, conversion,
partition, unusual row-key and failure combinations also need more qualification.
Do not call those whole feature families unsupported because their tests are
incomplete. See the [current work list](../PLAN/COMPLETE_MYSQL_SUPPORT.md) and
[machine-readable support catalog](../tests/DDLCoverage/support.json).

## Native restrictions and tool limits

A positive-support gap requires a native-valid operation within the declared
profile. A confirmed tool refusal can still need native eligibility review.
Keep these other cases separate:

| Case | Native behavior and this tool's scope |
| --- | --- |
| CREATE TABLE SELECT with GTIDs | MySQL 5.7 rejects logged, permanent CTAS with GTID consistency enabled (1786). MySQL 8.4 logs atomic InnoDB CTAS as a generated CREATE plus row events. The CREATE uses START TRANSACTION: 5.7 cannot parse it (1064), and native 8.4 MyISAM cannot execute it (3979). The applier stops before target writes. Temporary CTAS permanent-row effects use normal row replication. See [native contract and tests](../PLAN/CREATE_TABLE_SELECT.md). |
| Explicit `ENGINE=InnoDB` on a MyISAM-only target | Native replication executes the explicit engine clause. It does not convert it to the target's default engine. If the engine is disabled or unavailable, `NO_ENGINE_SUBSTITUTION` causes an error. With substitution allowed, native MySQL can use a default engine and issue warnings. This tool requires the explicit engine to match the profile and does not substitute engines. |
| GTID transaction applied to nontransactional tables | Some source transaction forms cannot be applied by native replication to MyISAM under the same GTID. The native multistatement fixture expects error 1837. Keep this restriction separate from the tool's one-statement, one-included-table limit; check each proposed extension against native behavior. |
| Row transaction with included and excluded tables | Native ROW replication can apply only the included table changes. This tool also permits mixed included/excluded row events within the profile's transaction limits. This can break application relationships. The tool rejects foreign keys across a filter boundary and DDL that changes both included and excluded objects. These are explicit safety policies, not a claim that native replication rejects every transaction across filters. |

Native restrictions and target configuration limits are not missing features.
Keep negative tests for them. Record tool limitations, explicit safety policies,
and untested behavior separately. A passing rejection test does not prove that
an operation is supported.

References: [MySQL 5.7 GTID restrictions](https://dev.mysql.com/doc/mysql-replication-excerpt/5.7/en/replication-gtids-restrictions.html),
[MySQL 8.4 GTID restrictions](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-restrictions.html),
[MySQL filter interactions](https://dev.mysql.com/doc/mysql-replication-excerpt/5.7/en/replication-rules-examples.html),
and [MySQL 5.7 engine selection](https://github.com/mysql/mysql-server/blob/f7680e98b6bbe3500399fbad465d08a6b75d7a5c/sql/sql_table.cc#L4870).

## Identifiers

Table and column names can use Unicode characters in the native system charset.
Table caches and prepared statement caches keep distinct UTF-8 byte sequences.
Column and index references use the native case map. Table-name modes 0 and 1
require matching source and target settings. Mode 1 has selected DDL/DML and
restart tests on all four profiles. Mode 2 and cross-setting replication cannot
be enabled. They require a separate implementation and qualification. See [table-name settings](../PLAN/TABLE_NAME_CASE.md).
Query events retain their client charset and original SQL bytes. Selected latin1
and Shift-JIS DDL cases cover names and text/binary defaults. See the
[identifier notes](../PLAN/IDENTIFIER_SUPPORT.md) and
[SQL encoding notes](../PLAN/QUERY_ENCODINGS.md) for limits and tests.

## Column types

| Types | Support and remaining limits |
| --- | --- |
| TINYINT, SMALLINT, MEDIUMINT, INT, BIGINT | Signed and unsigned values, including full unsigned BIGINT range |
| DECIMAL | Precision 1–65; scale 0–30 and no greater than precision; unsigned supported; numeric and quoted defaults use native target rounding |
| FLOAT, DOUBLE | Finite IEEE values, including subnormal values; fixed-scale `(M,D)` forms are supported; ZEROFILL is supported; AUTO_INCREMENT requires a 5.7 source and target; NaN and infinity are not supported |
| BIT | Widths 1–64, including primary keys |
| DATE, YEAR, TIME, DATETIME, TIMESTAMP | Fractional precision 0–6 where applicable; TIMESTAMP uses the 5.7 range and its zero value |
| CHAR, VARCHAR, TEXT families | All native 5.7 text encodings and collations; CHAR/VARCHAR defaults use native conversion and stored values; see below. CHAR width 0–255 characters; VARCHAR permits width zero and is bounded by charset and native row limits |
| BINARY, VARBINARY, BLOB families | Exact bytes; BINARY/VARBINARY defaults retain non-UTF-8 and NUL bytes; BINARY width 0–255 and VARBINARY width 0–65535, subject to native row limits |
| ENUM, SET | Matching ordered encoded labels, including supplementary characters, binary bytes and ENUM ordinal zero |
| JSON | Ordinary and typed values; partial updates require a full before image. Some legacy opaque types have no exact target SQL constructor; see [JSON support and limits](JSON_SUPPORT.md). |
| Spatial types | GEOMETRY, POINT, LINESTRING, POLYGON, MULTIPOINT, MULTILINESTRING, MULTIPOLYGON, GEOMETRYCOLLECTION; exact SRID and WKB bytes, with [DDL and index limits](../PLAN/SPATIAL_SUPPORT.md) |

NULL is supported where the column permits it. Primary keys can have 1–16
nonnullable base columns of supported types. TEXT/BLOB keys require prefixes.
Row lookups use the full source values, not only the indexed prefixes. Generated,
JSON and spatial columns cannot serve as primary keys in this applier. Types
outside this table, including newer-server-only types, are rejected. Numeric aliases and DDL forms have further
rules in the [DML guide](../PLAN/DML_APPLY.md).

CHAR, VARCHAR and TEXT accept the 40 native 5.7 text encodings and their
221 collations. Binary columns use the separate binary encoding. The registry
accepts both `utf8_` and `utf8mb3_` names. Non-UTF-8 values keep their source bytes.
Wide-character CHAR padding uses complete encoded space characters.
ENUM/SET metadata uses temporary target tables to read exact ordered labels.
The target account needs `CREATE TEMPORARY TABLES` on each replicated database.
These tables contain probe values, not application rows. They are removed after
the metadata check. The schema cache keeps this work out of the row apply loop.
Hex and bit literals are supported in ENUM/SET labels and defaults. MySQL 8.4.8
rejects the tested binary SET labels `X'ff',X'61'` with native error 3507. That case
is supported on the two 5.7-to-5.7 profiles. See [binary choice metadata](../PLAN/BINARY_CHOICE_METADATA.md).
VARCHAR declarations can use at most
65,535 bytes. MySQL row and index limits can reduce this maximum.
See [charset behavior and remaining checks](../PLAN/CHARACTER_SETS.md).

The 8.4 → 5.7 profile can explicitly map `utf8mb4_0900_ai_ci` to one of the three
destinations: `utf8mb4_general_ci`, `utf8mb4_bin` or `utf8mb4_unicode_ci`. This changes comparison semantics; it is not a charset
conversion. Other source collations need compatible source/target definitions.
MySQL 5.7 omits some table-map metadata. The applier uses the matching target
baseline and saved schemas for these fields. It cannot prove that an external
copy preserved information absent from the binlog.

All values remain subject to declared type sizes, [configured event and
transaction limits](LARGE_VALUES.md), and the target's `max_allowed_packet`.

## DDL and database objects

The [DDL guide](../PLAN/DDL_COMPATIBILITY.md) describes the supported grammar for
databases, tables, indexes, generated columns, partitions, views, and routines.
It is a subset of MySQL SQL. Important exclusions and policies are:

- No engine rewriting. An explicit engine must match the target profile.
- Executable version comments are retained in target SQL. MySQL evaluates them
  against the target version. Schema prediction uses the same version gate.
  Entirely inactive statements are journaled and acknowledged before checkpoint
  advancement. If an ignored clause causes incompatible later row events, apply
  blocks under the existing schema checks. See [comment support and tests](../PLAN/EXECUTABLE_COMMENTS.md).
- FULLTEXT indexes support CREATE, ADD, DROP and RENAME with parser metadata.
  Source and target need compatible parser plugins and search settings. See
  [FULLTEXT scope and tests](../PLAN/FULLTEXT_SUPPORT.md).
  Functional indexes require an 8.4 target. MySQL 5.7 ignores DESC index
  direction; 8.4 retains it. Index visibility is retained on 8.4 targets.
  A 5.7 target rejects active visibility attributes because it lacks the feature.
  It ignores attributes inside executable comments whose version exceeds the target version.
  SPATIAL indexes require one full, nonnullable spatial column.
- Cross-schema RENAME and ordered multi-table RENAME are supported. The table
  keeps its encoding. Multi-table DROP records every affected schema before
  SQL. A failed DROP can leave a partial target result, especially on 5.7.
  The applier keeps the DDL pending for DBA review. Statements that cross table
  filter boundaries are rejected. Source DDL events with a nonzero error code
  still stop replication. This includes a 5.7 DROP that partially succeeds on
  the source and records an error. Reproducing that result is not implemented.
- MySQL 5.7 CHECK clauses are ignored, as in native replication. Compound DDL
  retains its other operations. A check-only ALTER advances the checkpoint
  without target DDL. Enforced 8.4 checks cannot be preserved on a 5.7 target.
  See [native compatibility rules](NATIVE_COMPATIBILITY.md).
- RANGE/LIST subpartitions support HASH/KEY methods, explicit and generated
  names, and selected lifecycle operations. Named HASH/KEY partitions and
  implicit KEY columns are supported. See [partition scope and tests](../PLAN/PARTITION_SUPPORT.md).
  KEY ALGORITHM=1 and 2 are tracked in the saved schema. REBUILD, ANALYZE,
  OPTIMIZE and REPAIR PARTITION use the normal DDL journal. CHECK PARTITION
  does not enter the source binlog. The complete partition-expression and bound
  matrix is not qualified. File/tablespace administration is outside application
  schema replication scope.
  Column renames can replace or remove partitioning in the same ALTER. New
  partition expressions use final column names. Unchanged expressions still
  block dependent renames. Implicit KEY() follows the primary key. See
  [partition-column renames](../PLAN/PARTITION_COLUMN_RENAMES.md).
  Selected constant partition bounds use native evaluation. COLUMNS bounds
  support byte literals and charset introducers. Binary bounds retain exact
  bytes in saved state. Native type and conversion checks remain active.
  EXCHANGE supports WITHOUT VALIDATION. This can keep rows outside their partition bounds, as in
  MySQL. Queries can then miss those rows. Native UPDATE and DELETE can fail
  with error 1863. The tests exchange the rows back before DML. An uncertain exchange requires manual resolution; it is not retried.
  Permanent CREATE TABLE SELECT has native source or target restrictions on
  the current profiles. Temporary CTAS permanent-row effects are supported.
  FORCE and ENABLE/DISABLE KEYS use the target engine behavior.
  Table and column COMMENT, ROW_FORMAT, AUTO_INCREMENT,
  selected physical/statistics options, and same-engine rebuilds are parsed.
  The original SQL is saved and sent to the target. Comments and physical
  options are not part of the saved row schema. The target checks engine limits.
  ALTER TABLE RENAME also supports compound column/index/FK changes and
  cross-schema moves. The original ALTER is executed once. See
  [compound rename behavior](../PLAN/COMPOUND_TABLE_RENAMES.md).
  On an 8.4 target, do not combine a table rename, a referenced parent-column rename and
  ADD COLUMN in one ALTER. Native 8.4.8 can fail or lose cascade behavior.
  The applier stops before this statement. Put ADD COLUMN in a separate source
  ALTER. This restriction does not apply to 5.7 targets.
  ADD, MODIFY and CHANGE support inline primary and UNIQUE keys. SERIAL and
  SERIAL DEFAULT VALUE retain native auto-increment and unique-key behavior.
  Grouped ADD supports column and index definitions. Index COMMENT, KEY_BLOCK_SIZE,
  USING and ALGORITHM/LOCK options use native target behavior. COLUMN_FORMAT and
  STORAGE attributes remain in the original SQL. See [column and index syntax](../PLAN/COLUMN_INDEX_SYNTAX.md).
  ADD NOT NULL without a
  default uses native rebuild values. Logged AUTO_INCREMENT increment and offset
  are restored before DDL. New IDs on populated tables can differ by engine
  row order or ALTER algorithm. See [column keys and native limits](../PLAN/ALTER_COLUMN_KEYS.md).
  MODIFY and CHANGE permit cross-family conversions. ALTER TABLE can change
  its default charset or convert text columns with CONVERT TO CHARACTER SET.
  Native field probes determine converted types, labels and defaults before
  application SQL is issued. Binary columns retain their bytes and types.
  The target converts the data under the recorded SQL mode. Version-specific conversion differences
  still need qualification. The parser accepts the documented table options;
  other forms need a specific syntax audit before we classify them.
- Generated columns use typed expression parsing, including
  JSON extraction. Indexes on VIRTUAL generated columns require InnoDB. Indexes
  on STORED generated columns also work on MyISAM. CHANGE can rename a dependency
  when the same ALTER replaces or removes its generated expressions. MySQL 5.7
  requires a separate ALTER before dropping a referenced base column. See
  [dependency rules](../PLAN/GENERATED_COLUMN_DEPENDENCIES.md) and
  [JSON DDL](JSON_SUPPORT.md#json-indexes-and-defaults).
- Trigger DDL is skipped by default or rejected by policy. Target tables with
  triggers are rejected. Source trigger effects arrive as row changes and remain
  subject to the profile's transaction limits.
- Event DDL is rejected. Stored routine creation does not execute its body.
- Views support CREATE, REPLACE, ALTER and DROP, including parenthesized
  queries and multi-view DROP. Procedures and functions support CREATE,
  ALTER characteristics and DROP. Definers and SQL SECURITY are preserved.
  The target checks account privileges and query syntax. Routine CREATE IF
  NOT EXISTS is translated for 5.7: create an absent routine, or retain an
  existing routine and record a no-op. RENAME TABLE supports views within one
  database, including ordered lists with tables. The target account needs
  SHOW VIEW to read definitions before a rename. MySQL rejects cross-database
  view moves. See
  [stored-object scope and tests](../PLAN/STORED_OBJECT_SUPPORT.md).
- Temporary tables are not copied. The supported logged DROP TEMPORARY TABLE
  cleanup is skipped; CREATE TEMPORARY TABLE is not a supported apply operation.
- MySQL 5.7 targets reject expression defaults and functional indexes. MySQL 8.4
  targets accept functional indexes and expression defaults, including JSON and
  integer defaults on existing tables. Compound ALTER can remove or replace dependent
  indexes and defaults while it renames or drops columns. Unchanged dependencies
  stop apply before target SQL. See [the tested dependency forms](../PLAN/COLUMN_EXPRESSION_DEPENDENCIES.md).
  Spatial defaults are not qualified. Spatial
  BTREE byte-prefix indexes are supported on 5.7 targets; MySQL 8.4 rejects
  them with native error 1089. See [the version limits](../PLAN/SPATIAL_PREFIX_INDEXES.md).
  MySQL 8.4 targets retain column SRID constraints and index visibility in saved
  schemas. MySQL 5.7 targets reject these attributes with a version-specific
  error. See [target metadata tests](../PLAN/TARGET84_INDEX_SRID.md). Stored
  spatial bytes can have different function semantics across server versions.
- InnoDB foreign keys use the [documented rules and tests](../PLAN/MYSQL57_FOREIGN_KEYS.md).
  Selected tests pass; the full relationship and failure matrix is not qualified.
  Self-references, cycles and source `foreign_key_checks` settings are supported.
  Nonunique parent indexes, leading columns of composite keys, and clustered-key
  extensions are supported. MySQL 8.4 sessions use native replica-thread settings.
  See [parent-key rules](../PLAN/FOREIGN_KEY_PARENT_KEYS.md). Named supporting
  indexes, unnamed constraints and MySQL 5.7 MATCH behavior are supported. Column
  checks use native InnoDB storage rules, including different string lengths. See
  [FK syntax and columns](../PLAN/FOREIGN_KEY_SYNTAX_COLUMNS.md). Stored generated FK
  columns are supported with native action limits. Virtual FK columns and partitioned
  participants have native restrictions. See [generated FKs](../PLAN/GENERATED_COLUMN_FOREIGN_KEYS.md).
  Filters cannot split a relationship.
  Missing-parent FKs are supported with source checks disabled for DDL. The
  target still enforces each row event’s check setting. See
  [missing-parent behavior](../PLAN/MISSING_PARENT_FOREIGN_KEYS.md).
  Compound FK/index/column changes are tested with exact index-choice records.
  See [compound ALTER scope](../PLAN/COMPOUND_FOREIGN_KEY_INDEXES.md).
  Supporting-index additions, FK-column renames and cross-database DROP are
  implemented. A parent database DROP requires disabled source checks when an
  outside child still references it. See [database drops](../PLAN/CROSS_DATABASE_FOREIGN_KEYS.md),
  [FK DDL scope](../PLAN/FOREIGN_KEY_DDL.md) and
  [check settings](../PLAN/FOREIGN_KEY_CONTROLS.md) for limits.

Selected error skips do not make unsupported behavior correct. See
[error handling and recovery](OFFLINE_REPLAY.md) before enabling skips.

See the [complete-support plan](../PLAN/COMPLETE_MYSQL_SUPPORT.md) for the proposed
work to close implementation gaps. Planned work is not current support.

Numeric ZEROFILL declarations retain their implicit UNSIGNED attribute and
integer display widths. Padding affects display, not the stored numeric range.
YEAR modifiers normalize to native YEAR metadata. See
[numeric attributes](../PLAN/NUMERIC_ATTRIBUTES.md) for tests and limits.

The remaining JSON opaque subtype and range limits are documented in the
[JSON transport investigation](../PLAN/JSON_TRANSPORT_INVESTIGATION.md). Native
row replication can store binary JSON values that ordinary client SQL cannot
recreate with the same type. The applier retains the source bytes and stops
before a write when its constructor cannot preserve the value.

### Database defaults in legacy ALTER syntax

MySQL 5.7 charset and collation names of `DEFAULT` are resolved before execution.
The applier uses explicit names on the target. A table-default change inherits
from the table database. A conversion uses the logged session database collation
or the selected database default. When neither is in the Query event, source and
target `@@GLOBAL.collation_database` values must match. This value is separate
from `collation_server`. The binlog does not record an unmodified initial session
value. See [the native behavior and tests](../PLAN/ALTER_CHARSET.md).

Primary-key prefix lengths and sort directions are retained in saved schemas.
TEXT/BLOB primary keys require a prefix. Row lookups use the complete source key
values. MySQL 5.7 treats DESC as ascending. See [primary-key details](../PLAN/PRIMARY_KEY_PARTS.md).

Compound ALTER statements can swap column names or rename a chain of columns.
Existing keys and FK relationships follow the original columns. New constraints
use the final names. Expression and target-engine restrictions still apply.
See [column rename behavior and tests](../PLAN/SIMULTANEOUS_COLUMN_RENAMES.md).
