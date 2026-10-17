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
replication channels. Each replicated table needs a supported primary key.

Sources use ROW logging, FULL row images, CRC32 checksums, and GTIDs. A MySQL 5.7
source requires GTID capture; the 8.4 profile also permits file-position capture.

GTID restrictions apply in both modes. File-position mode selects where capture
starts; it does not enable non-GTID transactions or relax transaction rules. Live
capture requires `gtid_mode=ON` and `enforce_gtid_consistency=ON` on the source.
Replay has the same transaction requirements.
The decoder does not support every binlog format: XA, compressed transaction
payloads, and tagged GTIDs remain unsupported. Replay reads raw local binlogs
without a source connection. It has the same DML and DDL limits as live mode.

MyISAM profiles accept one row statement on one included table per source
transaction. InnoDB profiles also accept transactions with multiple statements
and tables. MyISAM writes cannot be rolled back. Neither profile makes a target
commit atomic with the SQLite checkpoint. Uncertain writes require DBA review;
InnoDB provides explicit recovery inspection and resolution commands.

## Native restrictions and tool limits

A support gap is a native-valid operation that this tool cannot yet apply within
its declared profile. Keep these other cases separate:

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
restart tests on all four profiles. Mode 2 and cross-setting replication remain
unqualified. See [table-name settings](../PLAN/TABLE_NAME_CASE.md).
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

NULL is supported where the column permits it. Primary keys need 1–16 full,
nonnullable, nongenerated scalar columns. TEXT, BLOB, JSON, and spatial columns
cannot serve as primary keys in this applier. Types outside this table, including
newer-server-only types, are rejected. Numeric aliases and DDL forms have further
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
- FULLTEXT indexes support CREATE, ADD, DROP and RENAME with parser metadata.
  Source and target need compatible parser plugins and search settings. See
  [FULLTEXT scope and tests](../PLAN/FULLTEXT_SUPPORT.md).
  Functional indexes require an 8.4 target. MySQL 5.7 ignores DESC index
  direction; 8.4 retains it. Invisible indexes are not supported.
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
  does not enter the source binlog. Some partition expressions and tablespace
  operations remain outside the current implementation.
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
  MODIFY and CHANGE permit cross-family conversions. ALTER TABLE can change
  its default charset or convert text columns with CONVERT TO CHARACTER SET.
  Native field probes determine converted types, labels and defaults before
  application SQL is issued. Binary columns retain their bytes and types.
  The target converts the data under the recorded SQL mode. Version-specific conversion differences
  still need qualification. Arbitrary table options remain unsupported.
- Generated columns use a limited deterministic expression grammar, including
  JSON extraction. Indexes on VIRTUAL generated columns require InnoDB. Indexes
  on STORED generated columns also work on MyISAM. See [JSON DDL](JSON_SUPPORT.md#json-indexes-and-defaults).
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
  targets accept functional indexes and JSON expression defaults, including
  discovery of existing tables. Spatial defaults are not qualified. Spatial
  BTREE byte-prefix indexes are supported on 5.7 targets; MySQL 8.4 rejects
  them with native error 1089. See [the version limits](../PLAN/SPATIAL_PREFIX_INDEXES.md).
  MySQL 8.4 column SRID attributes remain unsupported. Stored
  spatial bytes can have different function semantics across server versions.
- InnoDB foreign keys use the [documented subset](../PLAN/MYSQL57_FOREIGN_KEYS.md).
  Self-references, cycles, incomplete or nonunique parent keys, generated FK
  columns, partitioned participants, and source events with checks disabled
  remain unsupported. Filters cannot split a foreign-key relationship.

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
