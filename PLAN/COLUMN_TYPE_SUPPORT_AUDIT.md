# Column type support audit

Audit baseline: `3fcf9dd` (beta.5 command help).
This report checks code and test definitions. It does not claim a new four-profile
integration qualification. The limits below describe that baseline. The subsequent
[large-value increment](../docs/LARGE_VALUES.md) changes the TEXT/BLOB size limits
and adds tests. The subsequent [BIT increment](BIT_SUPPORT.md) adds BIT support
and unit tests. Its integration qualification is pending. Other type gaps in
this audit remain open.

## Findings

The four profiles use the same type parser, decoder, DML planner, and value checks.
BIT, FLOAT, DOUBLE, JSON, and spatial columns are rejected. These are missing
features, not only missing tests. Support in MySQL itself does not enable support
in this applier.

The supported types have shared tests for replicated CREATE TABLE and discovery
of existing tables. Test depth differs by type. Clean restart tests do not prove
that every type works in pending-transaction inspection or target comparisons.

Keep the planned order: BIT, FLOAT/DOUBLE, then JSON. Review spatial support
separately. Each increment must include all stages below.

## Profiles

All source tables in the standard lab profiles use InnoDB.

| Profile | External target | Native reference | Schema interpretation |
| --- | --- | --- | --- |
| `mysql84-to-mysql57-myisam` | 5.7 MyISAM | 8.4 MyISAM | Check optional TABLE_MAP metadata when present. ENUM/SET require FULL metadata with ordered labels. |
| `mysql57-to-mysql84-innodb` | 8.4 InnoDB | 5.7 InnoDB | Use the matching target baseline and saved schema history for metadata absent from 5.7 events. |
| `mysql57-to-mysql57-myisam` | 5.7 MyISAM | 5.7 MyISAM | Same 5.7 schema requirement. |
| `mysql57-to-mysql57-innodb` | 5.7 InnoDB | 5.7 InnoDB | Same 5.7 schema requirement. |

The 5.7 path still checks facts present in the event. It cannot independently
verify missing source signedness, collation, names, or ENUM/SET labels against
the target. A matching initial schema remains an operational requirement.
Schema lookup and caching already exist. `TargetSession.discover` reuses discovered
tables, and `DMLPlanningCache` reuses parsed types and successful TABLE_MAP checks.
Ordered DDL replaces affected schema plans. This audit does not propose repeated
metadata queries. The limit concerns missing source facts, not lookup cost.
See [SourceContract](../Sources/ReplicatorCapture/SourceContract.swift),
[DMLTablePlan](../Sources/ReplicatorApply/DMLTablePlan.swift), and
[LabProfile](../Sources/ReplicatorLabCore/LabProfile.swift).

## Support by stage

In this table, **yes** means the code has a path for the stated subset.
It does not mean every MySQL syntax form or boundary has an integration test.
**Read/compare** means target row decoding and comparison, plus representation
in offline recovery output. Recovery does not make an automatic commit decision.

| Column family | Binlog decode | Target discovery and DML | Column DDL | Read/compare | Main limits |
| --- | --- | --- | --- | --- | --- |
| TINYINT, SMALLINT, MEDIUMINT, INT, BIGINT | Yes | Yes | Yes | Yes | Signed and unsigned. Integer display widths are normalized. ZEROFILL is rejected. |
| DECIMAL | Yes, exact decimal text | Yes | Yes | Yes, exact decimal text | Precision 1–65; scale 0–30 and no greater than precision. UNSIGNED is accepted. |
| DATE, YEAR | Yes | Yes | Yes | Yes | YEAR is zero or 1901–2155. YEAR(4) is normalized. |
| TIME, DATETIME, TIMESTAMP | Yes, modern temporal wire formats | Yes | Yes | Yes, normalized text | Fractional precision 0–6. TIMESTAMP uses the implemented 1970–2038 range plus zero. Old TIME/DATETIME/TIMESTAMP wire codes are rejected. |
| CHAR, VARCHAR | Yes, UTF-8 | Yes | Yes | Yes, with text comparison limits below | CHAR width 0–255; VARCHAR width 1–16383. Only the allowed utf8mb4 collations. |
| BINARY, VARBINARY | Yes, bytes | Yes | Yes | Yes, bytes | BINARY width 0–255; VARBINARY width 1–16383. BINARY padding is preserved. |
| TINYTEXT, TEXT, MEDIUMTEXT, LONGTEXT | Yes, UTF-8 | Yes | Yes | Yes | Declared family limits and the decoder's 1 MiB value limit both apply. Non-NULL DDL defaults are rejected. |
| TINYBLOB, BLOB, MEDIUMBLOB, LONGBLOB | Yes, bytes | Yes | Yes | Yes | Same decoder value limit. Non-NULL DDL defaults are rejected. |
| ENUM, SET | Yes, ordinal or bitmask | Yes | Yes, limited labels | Yes, unsigned numeric read | ENUM error ordinal 0 is rejected. SET permits all 64 bits. 8.4 requires FULL label metadata. DDL rejects supplementary-plane labels. |
| NULL values | Yes | Yes, nullable columns | Yes | Yes | NULL and empty values remain distinct. NULL is not a separately supported declared column type. |
| BIT | No | No | No | No | Wire type 16 is outside the decoder allowlist. |
| FLOAT, DOUBLE | No | No | No | No | Wire types 4 and 5 are outside the decoder allowlist. No floating-point value case exists in the Swift codec API. |
| JSON | No | No | No | No | Wire type 245 is rejected. Full-document support and partial-update support are separate work. |
| GEOMETRY and spatial subtypes | No | No | No | No | Wire type 255 is rejected. Geometry bytes and spatial semantics need a separate design. |

The main implementation sources are
[the Rust allowlist and row decoder](../rust/src/lib.rs),
[scalar decoding](../rust/src/scalars.rs),
[Swift value types](../Sources/ReplicatorCodec/Codec.swift),
[DMLColumnType](../Sources/ReplicatorApply/DMLColumnType.swift),
[DDLParser](../Sources/ReplicatorApply/DDLParser.swift), and
[TargetSession](../Sources/ReplicatorApply/TargetSession.swift).

### Limits that apply across families

- Target text columns accept `utf8mb4_bin`, `utf8mb4_unicode_ci`, and
  `utf8mb4_general_ci`. Other character sets are not converted. Configured
  collation translation is a separate policy; it is not general type conversion.
- The decoder limits a string or binary value to 1 MiB and decoded event output
  to 16 MiB. A declared LONGTEXT or LONGBLOB column does not remove these limits.
- Application requires complete row images and a supported primary key.
  Tables have at most 256 columns. Primary keys have 1–16 nonnullable columns.
  Generated columns and TEXT/BLOB columns cannot be primary-key columns.
- Stored and virtual generated columns use the supported base types and a
  restricted expression grammar. SQL writes omit generated columns. The applier
  reads generated values back and compares them with the source row image.
- DDL spelling support is narrower than stored type support. `INTEGER`, `DEC`,
  and `NUMERIC` are normalized. `BOOL`, `BOOLEAN`, and `FIXED` are not normalized
  by the DDL parser. A bootstrapped BOOL column reported as TINYINT can therefore
  pass discovery while a logged `CREATE ... BOOL` fails parsing. This is a code
  finding; there is no dedicated end-to-end alias case in the reviewed catalog.
- DDL numeric defaults currently accept integers and fixed decimal notation.
  BIT literals and floating-point exponent notation need parser work.
- The shared parser retains some 5.7 limits even for the 8.4 target. An 8.4 target
  does not imply support for all 8.4 column attributes or default expressions.

See [column/table validation](../Sources/ReplicatorApply/Configuration.swift),
[generated expressions](../Sources/ReplicatorApply/DDLTokens.swift), and
[target metadata normalization](../Sources/ReplicatorApply/TargetColumnMetadata.swift).

## Existing tests and remaining gaps

The shared catalog registers `matrix-*` and `bootstrap-matrix-*` on all four
profiles. The first path creates tables through replication. The second creates
matching tables outside replication and then tests discovery. Both compare rows
with the source and the native reference after each phase.

| Family | Existing named cases and assertions | Remaining test gaps |
| --- | --- | --- |
| Integers | `matrix-integers`: small signed/unsigned bounds, NULL, key update, delete. `positive` and MyISAM `exact-values`: INT/BIGINT and unsigned high values. Codec tests cross the Swift ABI with signed/unsigned 64-bit bounds. | One shared all-profile case for the full INT/BIGINT boundary set, including post-restart writes. |
| DECIMAL | `matrix-decimal`: DECIMAL(65,30), unsigned, scale equal to precision, NULL, INSERT/UPDATE/DELETE. Unit tests reject bad precision, scale, and signedness. | Target read-back and pending-recovery assertions at the same boundaries. |
| Temporal | `matrix-temporal`: zero values, negative TIME, time zone, upper DATETIME/TIMESTAMP values, NULL, and all three DML operations. `matrix-precision`: TIME(0–6), selected DATETIME/TIMESTAMP precisions. | Every DATETIME/TIMESTAMP precision; DELETE in the precision case; same-type writes after saved-state restart. |
| Fixed strings | `matrix-fixed`: CHAR padding, Unicode, BINARY padding, empty/NULL, width boundary, and all three operations. | End-to-end zero-width cases; byte-exact recovery comparisons of different Unicode encodings. |
| Variable strings | `matrix-textkey`, `positive`, and MyISAM `exact-values`: text keys, bytes, NULL, empty values, updates, deletes. | Shared declared-width bounds and VARBINARY values above the current width cap as explicit refusals. |
| TEXT/BLOB | `matrix-lob`: all eight names, binary/control bytes, NULL/empty, 70 KB values, and all three operations. | Decoder limit boundary and one byte beyond it. Large-value restart and recovery inspection. The fixture does not fill every family to its MySQL maximum. |
| ENUM/SET | `matrix-choices`, `matrix-widechoices`: labels, NULL, ENUM 255/256, SET high bit and all 64 bits, INSERT/UPDATE/DELETE. | Maximum ENUM label count; label/default edge cases; saved-state and pending-recovery tests with wide values. |
| Generated columns | `matrix-generated`; DDL compatibility and generated-value mismatch tests. | Do not infer each base type/expression combination from the integer expression cases. |
| Unsupported types | Shared `reject-float` and `reject-json` check DDL refusal before target SQL. Forward `matrix-reject-float` and `matrix-reject-json` check existing-table decoder refusal. | Dedicated BIT, DOUBLE, and spatial refusals are missing. Forward DML refusals are not proof of the 5.7 discovery refusal path. |

Fixture definitions:
[DMLCompatibilityCases](../Sources/ReplicatorLabCore/DMLCompatibilityCases.swift),
[SharedCorrectness](../Sources/ReplicatorLabCore/SharedCorrectness.swift),
[SharedBootstrapDML](../Sources/ReplicatorLabCore/SharedBootstrapDML.swift),
[SharedRejections](../Sources/ReplicatorLabCore/SharedRejections.swift), and
[catalog applicability](../Sources/ReplicatorLabCore/LabScenario.swift).

### Recovery is a separate check

`RecoveryRelay` decodes retained events using saved column definitions.
`Recovery.fold` combines changes to the same encoded key within a transaction.
`recovery inspect` reports the resulting initial/final row images. It does not
connect to the target or prove a commit outcome.

`TargetSession.read` has read paths for each currently supported value kind.
`exactImage` compares text bytes explicitly. However, `Recovery.fold` uses the
synthesized `DecodedValue` equality for row continuity. Swift String equality
can equate different Unicode encodings. Add a focused comparison test before
describing recovery continuity as byte-exact. This does not authorize automatic
recovery from matching row images.

The shared correctness runner reopens saved schemas at the end and writes to
an integer helper table. Bootstrap phases create separate state directories.
Neither operation proves resumed DML for every data type. The MyISAM composite
resume case and the InnoDB recovery runner cover selected layouts only.

See [Recovery](../Sources/ReplicatorApply/Recovery.swift),
[RecoveryRelay](../Sources/ReplicatorApply/RecoveryRelay.swift),
[MyISAM workflows](../Sources/ReplicatorLabCore/SharedMyISAMRecovery.swift), and
[InnoDB recovery](../Sources/ReplicatorLabCore/ReverseQualification.swift).

## Implementation order and acceptance checks

The TEXT/BLOB capacity work below is a separate gap in existing type support.
It needs a coordinated size-limit and transport change. It is not part of adding
a new scalar type.

### 1. BIT

Support `BIT(1)` through `BIT(64)`, plus the omitted width if the DDL uses it.
Preserve width in saved schema metadata. A UInt64 value is a possible internal
representation, but do not treat BIT as an integer wire type. Validate its two
metadata bytes and its packed byte order independently. Normalize target reads
explicitly, for example with an unsigned cast, instead of relying on driver
interpretation of a BIT result.

Add shared CREATE and bootstrap cases for widths 1, 7, 8, 9, 63, and 64.
Test zero, maximum, high bits, NULL, defaults, INSERT/UPDATE/DELETE, and key use.
Test ADD/MODIFY, width mismatch, malformed metadata, truncated values, clean
restart, and offline recovery output. Keep unsupported forms as explicit refusals.

### 2. FLOAT and DOUBLE

Start with finite FLOAT and DOUBLE values. Define the treatment of signed zero,
subnormal values, overflow, and non-finite wire values before implementation.
Preserve enough information to reproduce the source's stored value. Test binary
binding and target read-back; a decimal display string alone is not an exact
floating-point comparison.

Account for metadata, codec ABI values, JSON diagnostic encoding, SQL binding,
target reads, key comparisons, and recovery folding. Do not use an epsilon
comparison to infer that a pending transaction committed.

Test both signs, zero, fractional values such as 0.1, normal/subnormal bounds,
NULL, multi-row INSERT, UPDATE, DELETE, and restart on all four profiles.
Make an explicit decision for `FLOAT(p)`, `FLOAT(M,D)`, `DOUBLE(M,D)`, UNSIGNED,
`REAL`, `DOUBLE PRECISION`, and exponent defaults. Do not silently accept a form
before schema normalization and round-trip tests exist. `REAL` depends on SQL mode;
see the [MySQL numeric syntax reference](https://dev.mysql.com/doc/refman/8.4/en/numeric-type-syntax.html).

### 3. JSON

Start with complete documents. Preserve integer precision, scalar values,
SQL NULL versus JSON null, and MySQL binary JSON value types. Define target
binding and document comparison rules before accepting the column.
MySQL 8.4 can log partial document updates when `binlog_row_value_options` enables
`PARTIAL_JSON`. FULL row images alone are not a substitute for checking that
setting. Keep partial updates rejected until there is a separate implementation.
See [MySQL JSON replication](https://dev.mysql.com/doc/refman/8.4/en/replication-features-json.html).

### 4. Spatial types and other gaps

Keep spatial columns rejected until the required geometry types, SRID behavior,
axis order, and target-version limits are specified. Track DDL aliases, larger
VARBINARY widths, and existing-type recovery gaps separately. They need smaller
changes than a new wire type, but they still need named tests.

For each new type, use the shared profile catalog. Add the same CREATE and
bootstrap case definitions once. Add engine-specific failure/recovery assertions
where persistence differs. Replace obsolete refusal cases only when their new
positive cases pass. Do not remove unrelated negative coverage.

## Upstream cross-check

The local upstream checkouts were used first:

- MySQL 8.4: `0896fcd61dec11a0904166911a0126f59daaa1bf`.
- MySQL 5.7: `f7680e98b6bbe3500399fbad465d08a6b75d7a5c`.

Both trees have BIT, FLOAT, DOUBLE, JSON, and GEOMETRY replication handling in
`sql/rpl_utility.cc`. BIT metadata handling and row packing are in `sql/field.cc`.
The 8.4 metadata reader stores one byte for FLOAT/DOUBLE and two bytes for BIT.
This confirms that the missing scalar support is in our current allowlist and
value model. It does not prove that all cross-version values are interchangeable.

## Native TEXT/BLOB handling

Both upstream versions use a length prefix followed by the value bytes in a
row image. TABLE_MAP metadata gives the length-prefix width: 1, 2, 3, or 4 bytes
for the TINY, regular, MEDIUM, or LONG family. `Field_blob::pack` writes that
representation. `Field_blob::unpack` reads the prefix and supplies the bytes to
the target field. There is no separate 1 MiB value check in this path.

`THD::binlog_prepare_pending_rows_event` starts a new event when the next row
does not fit the normal event size. It still admits that row to the new event.
An UPDATE supplies both its before and after image together. The row-event
setting is a grouping target, not a hard limit that splits a large field into
several row events. With FULL row images, an update to a row with a large BLOB
can contain two copies of that value.

Native replication unpacks row images and calls the storage engine's row methods
in `log_event.cc`. It does not send an INSERT statement back through a client
connection. The replication receiver still needs enough packet and event
capacity. MySQL 5.7 sets its I/O and SQL thread limits from
`slave_max_allowed_packet`; its default and maximum are 1 GiB. MySQL 8.4 uses
the name `replica_max_allowed_packet`. These limits do not mean an arbitrary
4 GiB LONGBLOB can pass through replication.

Code references at the inspected revisions:

- [8.4 field packing](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/sql/field.cc): `Field_blob::pack` and `Field_blob::unpack`.
- [5.7 field packing](https://github.com/mysql/mysql-server/blob/f7680e98b6bbe3500399fbad465d08a6b75d7a5c/sql/field.cc): the corresponding BLOB methods.
- [8.4 event grouping](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/sql/binlog.cc) and [5.7 event grouping](https://github.com/mysql/mysql-server/blob/f7680e98b6bbe3500399fbad465d08a6b75d7a5c/sql/binlog.cc): `binlog_prepare_pending_rows_event` and update-row packing.
- [5.7 receiver limits](https://github.com/mysql/mysql-server/blob/f7680e98b6bbe3500399fbad465d08a6b75d7a5c/sql/rpl_slave.cc): `set_slave_max_allowed_packet`.
- [Native row application](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/sql/log_event.cc): `unpack_current_row` and `ha_write_row`/`ha_update_row`/`ha_delete_row` calls.

The manuals describe the
[soft row-event size limit](https://dev.mysql.com/doc/refman/8.4/en/replication-options-binary-log.html#sysvar_binlog_row_event_max_size)
and [5.7 replication packet limits](https://dev.mysql.com/doc/mysql-replication-excerpt/5.7/en/replication-features-max-allowed-packet.html).

### Limits in this application

| Stage | Current limit or behavior | Required work for larger values |
| --- | --- | --- |
| Declared type | 1–4 byte BLOB length metadata is supported. TEXT adds UTF-8 checks. | Keep type-family and encoding checks. No new wire type is needed. |
| Value decode | `MAX_VALUE` is 1 MiB. | Replace the fixed value cap with a documented policy tied to the admitted event size. |
| Event capture/replay | `source.maximumEventBytes` defaults to 4 MiB and permits at most 16 MiB. | Define the required maximum. Apply it to live capture, fetch, replay, inspection, and recovery. |
| Decoded event | `MAX_OUTPUT` is 16 MiB, including decoded-value overhead. | Account for actual retained data and allocation overhead, not only raw value bytes. |
| Transaction assembly | Default limits are 16 MiB wire data and 32 MiB retained data. | Admit a complete transaction or reject it before target writes. Test multiple large rows and UPDATE before/after images. |
| Queues and relay | Independent byte limits apply. | Define whether one large item can exceed a queue's normal budget. Prevent deadlock and excess concurrent allocations. |
| Target SQL batching | The byte setting controls multi-row INSERT grouping. A first row is still sent alone if it exceeds that setting. | Do not mistake the batch setting for a hard per-row transport check. Validate the complete request size. |
| Target transport | The vendored encoder writes one 3-byte packet length and the entire payload. The decoder emits each physical packet separately. | Add packet fragmentation/reassembly, or explicitly reject requests/responses before the 16,777,215-byte protocol boundary. Test exact-boundary terminators and sequence IDs. |
| Target server | An ordinary client session uses target `max_allowed_packet`. | Check that the target can receive the complete prepared-statement request. Native replication's separate packet allowance does not apply to our SQL client. |

The capture transport already reassembles fragmented dump messages. That does
not add fragmentation support to the separate target SQL client. See
[capture packets](../Sources/ReplicatorCapture/Protocol.swift),
[target packet encoder](../Vendor/mysql-nio/Sources/MySQLNIO/Packet/MySQLPacketEncoder.swift),
[target packet decoder](../Vendor/mysql-nio/Sources/MySQLNIO/Packet/MySQLPacketDecoder.swift),
[transaction limits](../Sources/ReplicatorCodec/TransactionAssembler.swift), and
[INSERT grouping](../Sources/ReplicatorApply/DMLExecution.swift).

Recommendation: support larger TEXT/BLOB values as a separate increment.
First define one consistent admission policy for values, events, transactions,
and target messages. Do not remove all memory limits or only raise `MAX_VALUE`.
Test 1 MiB minus/at/plus one byte, then multi-MiB values, complete UPDATE images,
NULL, empty values, and all three DML operations on the four profiles. Include
target read-back, restart, offline replay, and recovery inspection. Add tests
around the protocol packet boundary before claiming support above it.

## Verification

This audit changes documentation only. All 58 selected existing unit tests passed.
The command reused the build from the unchanged CLI-help baseline:

```sh
swift test --skip-build --filter 'DMLTypeTests|DecoderTests|RecoveryTests|SchemaChangeTests|DDLCompatibilityTests|CompatibilityTests'
```

Log: `/tmp/beta5-type-audit-tests.log`. Database integration suites were not rerun
for this report. The tables above identify test definitions, not new integration
results or line-coverage measurements.

The offline catalog check confirmed 18 replicated DML cases and 18 bootstrap
DML cases applicable to each profile. Inventory:
`/tmp/beta5-type-audit-catalog.json`. Relative report links and whitespace checks
also passed.
