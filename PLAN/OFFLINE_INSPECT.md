# Offline decoder and inspect increment

The production Rust adapter now exposes a versioned C ABI to Swift. The first consumer is a read-only offline inspector. Bounded transaction assembly is now available through `--transactions --binlog-file SOURCE_FILENAME` (see [transaction inspection](TRANSACTION_ASSEMBLY.md)). Live capture, file relay and SQLite state and target application are still pending; this increment does not close Phase 1 or Phase 2.

## Run it

From the repository root:

```sh
make build
.build/debug/mysql-replicator inspect \
  tests/ReplicatorLabTests/Fixtures/source-positive.binlog \
  --schema tests/ReplicatorCodecTests/Schema/source-positive.json
```

Stdout contains one JSON object per complete, successfully decoded event. Diagnostics are JSON on stderr and any failure exits nonzero. Earlier valid events may already have been printed when a later event fails. No row from the failed event is printed. Consumers must check exit status; this is not an atomic export or proof that a source transaction committed.

Add `--include-raw` to include the complete original event as base64. It is omitted by default. Query/detail bytes are represented as base64 with a UTF-8 display field where valid. Integer **values**, GTID sequence/XID/rotation-position values, physical offsets and table IDs are decimal strings so JSON consumers cannot round them through floating point. Event JSON schema version 4 adds exact `decimal`/`temporal` string values and raw type metadata/unsigned flags; version 3 added `wireColumns` for table-map metadata, retains GTID SID bytes in `detailBase64` and also renders typed controls (named GTID identity, anonymous marker, query metadata, XID and rotation). See [the versioning contract](TRANSACTION_ASSEMBLY.md#abi-and-json-versioning).

Rows have `operation`, optional `before`/`after` arrays, and tagged values:

```json
{"kind":"unsigned","value":"18446744073709551615"}
{"kind":"utf8","value":"text"}
{"kind":"binary","value":"AP+A"}
{"kind":"null"}
{"kind":"absent"}
```

SQL NULL, an omitted column in a minimal row image, empty text and empty binary remain distinct. Binary bytes and embedded NULs are preserved.

## Historical column context

The pinned upstream row convenience API defaults missing signedness to signed. The adapter instead passes explicit historical signedness to upstream `BinlogValue::deserialize`, with bounded row-image/null-bitmap framing. There is no second Swift value decoder and no change to the upstream revision. The adapter corrects signed INT24 sign extension, YEAR zero handling and negative TIME(1/2) fractional arithmetic in the pinned upstream parser, and renders decoded decimal/temporal values exactly.

The optional `--schema` file has this structure:

```json
{
  "version": 1,
  "tableMaps": [{
    "offset": 1339,
    "eventSHA256": "<64 lowercase hex characters identifying the complete table-map event>",
    "database": "poc",
    "table": "items",
    "tableID": "123",
    "columns": ["signed", "utf8", "unsigned"]
  }]
}
```

This example illustrates the format; use the committed fixture histories for actual runnable inputs. Every table map used for row decoding needs its own entry. The offset, SHA-256, table ID, database/table and column count must match. Duplicate, mismatched and unused entries fail. A replacement table map replaces its associated history, and statement-end/rotation clear cached maps. Optional wire signedness, when present, must agree with supplied history.

The history is **caller-supplied authoritative metadata**. Fingerprints prevent accidental association with different table-map bytes; they do not establish that the supplied signedness/encoding is truthful. Do not use today's schema to decode an older file. The inspector does not query a database or infer history from DDL. Without history it can print control/table-map events, then stops at the first row requiring column interpretation. UTF-8 is the only supported text encoding; other byte encodings may be inspected explicitly as binary, without claiming text conversion.

## Supported scope

- MySQL v4 file framing, a first format-description event, modern 19-byte headers and CRC32 checksums. FDE's BINLOG_IN_USE checksum convention is handled.
- Query, stop, rotate, XID, table-map, traditional GTID/anonymous-GTID and untagged previous-GTID events. Typed control fields support bounded transaction assembly; previous-GTID sets and query status-variable semantics remain opaque, and an applier still needs additional policy.
- v1/v2 write/update/delete row framing where the FDE declares the supported post-header length, including multiple rows and minimal column bitmaps.
- TINYINT, SMALLINT, MEDIUMINT, INT and BIGINT with explicit signedness; VARCHAR/VAR_STRING/CHAR and BLOB wire types as explicit UTF-8 or binary. ENUM/SET aliases are rejected.
- Exact NEWDECIMAL values; DATE/NEWDATE, YEAR and modern TIME2/DATETIME2/TIMESTAMP2 values. Temporal values retain microseconds; TIMESTAMP is rendered in UTC within the 5.7 range. Legacy TIME/DATETIME/TIMESTAMP encodings are not added.

Compression payload events, tagged GTIDs, partial JSON updates, heartbeat variants, XA, unfamiliar events/checksum algorithms, float/JSON/geometry/vector/ENUM/SET values and other unqualified formats return an explicit unsupported error. There is no silent skip. The inspector reads one file from its FDE; it does not follow rotation or support live/state-indexed relay input yet. Default event mode does not validate complete transaction boundaries at EOF; `--transactions` does.

Bounds are fixed for this increment: 4 MiB default event size (C ABI permits 23 bytes through 16 MiB), 1 MiB per value, 256 columns, 4,096 rows per event, 64 cached table maps / 4 MiB retained table-map frames, and 16 MiB decoded cell/output budget. Previous-GTID counts are checked before upstream allocations. Results are one bounded event batch; compressed transactions are rejected before decompression. Encoded JSON and transient input/copy storage add overhead beyond the decoded-cell budget. No throughput or RSS qualification is claimed.

## Ownership and failure contract

ABI version is **5**, capability bit 0 means bounded offline decoding. Capability bit 1 adds optional per-feed timings through `rc_decoder_feed_profiled`; existing feed functions and structures are unchanged. A null profile disables native clocks. See the [decoder profile](PERFORMANCE_BENCHMARK.md#decoder-function-profile) for stage definitions. Inputs are borrowed only during `rc_decoder_feed`. Results own their storage independently of input and context. C views remain valid until the matching `rc_result_free`; Swift copies them before releasing the result. Contexts and results must be freed exactly once by the matching Rust function. Null handles are checked; arbitrary dangling/forged non-null pointers remain a C caller contract violation.

Feed failure poisons the context and publishes no partial batch. `reset` discards all metadata and requires replay from the file FDE. Swift serializes access with a lock; future capture must run decoding off the NIO event loop. Cancellation stops between bounded frames and discards the inspector's context.

| Status | Meaning |
| --- | --- |
| 1 | Invalid argument / inspection cancellation |
| 2 | Malformed, truncated or noncontiguous input |
| 3 | CRC mismatch |
| 4 | Unsupported event, type, format or encoding |
| 5 | Resource bound exceeded |
| 6 | Poisoned context |
| 7 | Missing/mismatched schema history |
| 8 | Internal parser panic or ABI inconsistency |

The CLI emits a structured JSON error for decoder failures. An unexpected caught upstream panic may additionally print Rust’s panic-hook diagnostic on stderr; stdout remains event NDJSON only.

Unwind-capable parser panics are contained at the exported feed boundary and poison the context. Allocation aborts/process faults cannot be converted into recoverable errors. Durable BLOCKED state and restart checkpoints remain relay/applier work.

## Validation and review points

The following 30-test counts describe the preceding decoder checkpoint. Current transaction-increment evidence is in [implementation status](IMPLEMENTATION_STATUS.md) and [transaction assembly](TRANSACTION_ASSEMBLY.md).

- `make test`: 30 Swift tests (17 decoder/ABI/CLI tests plus 13 existing harness tests) and one Rust panic-containment test.
- Recorded source/native-positive/native-rejected logs agree with the independent mysqlbinlog reference and workload expectations.
- Independently hand-encoded wire vectors plus handwritten JSON expectations cover signed/unsigned extremes, multi-row events, Unicode/NUL, binary, SQL NULL and absent columns. MySQL 8.4.6 also verifies/decodes the synthetic file; its binary text rendering is not used as an exact binary oracle.
- Error tests cover truncation/extra bytes, CRC, unsupported events, FDE checksums, noncontiguous offsets, schema fingerprints, UTF-8, row/map/GTID-count limits, poisoning/reset, cancellation, C result/error lifetimes and CLI exit/stdout/stderr behavior.
- `make test-asan`: all 30 Swift tests pass with Swift/C callers and CLI AddressSanitizer-instrumented. The pinned Rust archive is **not** instrumented; this is not full mixed-language sanitizer or fuzz qualification.
- Host and Ubuntu output agree for all 36 events in the recorded source file, not only the four workload row operations.
- `make ubuntu-smoke` now also runs the production `inspect` executable and compares its four workload operations with independent expectations. See the current evidence entry in implementation status.

Use Make after Rust changes: SwiftPM does not track external archive contents, so `make codec` deliberately cleans Swift build products before relinking. `make test-asan` uses a separate ignored build directory. The host build still reports pre-existing macOS deployment-version warnings from Rust/native archives; only the current macOS host and recorded Ubuntu container are qualified, not every advertised macOS version.

Still needed: broader real-server/type corpus and Go vectors, Rust-instrumented sanitizers/fuzzing, malformed-metadata coverage, broader control-event/transaction support, additional supported types, live capture/relay input, resource profiling and fleet-kernel qualification.

References: [codec decision](REPLICATOR_CODEC_DECISION.md), [C ownership contract](../Sources/CReplicatorCodec/include/replicator_codec.h), [MySQL binlog protocol](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_replication_binlog_event.html), [Rust FFI guidance](https://doc.rust-lang.org/nomicon/ffi.html).
