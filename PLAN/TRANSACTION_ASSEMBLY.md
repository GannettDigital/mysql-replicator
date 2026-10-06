# Offline transaction boundaries and coordinates

This increment adds typed control events and a bounded Swift transaction assembler on top of the Rust decoder. It emits complete source binlog groups and validates physical file/position boundaries. Live transport, persistence, GTID-set reconciliation, resume commands and target application remain unimplemented. Phase 1 and Phase 2 are still open.

## Review and run

```sh
make build
.build/debug/mysql-replicator inspect \
  tests/ReplicatorLabTests/Fixtures/source-positive.binlog \
  --schema tests/ReplicatorCodecTests/Schema/source-positive.json \
  --transactions --binlog-file binlog.000003
make test
```

The source filename is explicit because a captured fixture's local name can differ from its source binlog name. File names and offsets are not a source-history identity: future capture must bind them to the verified source lineage and bootstrap manifest.

Stdout has one JSON object per complete group, with `start`, `end`, optional `gtid`, `anonymous`, `outcome` and ordered `events`. Positions and GTID sequence numbers are decimal strings. Outcomes distinguish `committed`, `rolledBack` and opaque standalone `statement` groups. A statement group's completion says nothing about whether its SQL is compatible with the target. No SQL is executed. Source GTIDs remain identities; this code does not change target GTID settings or claim native MyISAM compatibility.

The committed source fixture produces nine groups: four setup statements, one seed transaction and four workload transactions. The workload starts at 1589, 1885, 2213 and 2509, and ends at 1885, 2213, 2509 and 2841. Its source GTIDs are `8ba09bde-bc41-11f1-8272-ba06e9024a03:11` through `:14`. These expectations come from the independently captured `mysqlbinlog` text. The physical rotation afterward identifies `binlog.000004:4`.

Ordinary event inspection remains available without `--transactions`. It may print rows from an incomplete transaction. Transaction inspection buffers a group until its end; an incomplete group is never emitted. Previously completed groups may have been printed before an error. Always check exit status. Cancellation and output callback errors abort inspection.

## Boundary rules

| Input | Accepted state and effect |
| --- | --- |
| FDE | Required first at position 4; validates the file preamble boundary |
| Previous-GTIDs | At most once, immediately after FDE; retained as raw set metadata, never installed as executed progress |
| Named/anonymous GTID | Opens a group only when idle; records identity without completing it |
| Exact `BEGIN` | Opens a transaction, optionally following its GTID marker |
| Table map and row events | Require BEGIN; preserve every ordered row image |
| Row `STMT_END_F` | Ends the row statement and map lifetime, **not** the transaction |
| XID or exact `COMMIT` | Completes a transaction only after its row statement has ended |
| Exact `ROLLBACK` | Completes an empty transaction as `rolledBack`; logged row effects are rejected because discarding them could hide nontransactional effects |
| Other standalone query | Completes an opaque statement group, optionally with its preceding GTID; does not interpret DDL or session state |
| Physical ROTATE | Accepted only between groups, to a different file at position 4; the next file must start with its FDE |
| STOP | Accepted only between groups; no further event may follow |

Canonical BEGIN/COMMIT/ROLLBACK bytes are recognized without SQL rewriting. XA, SAVEPOINT/ROLLBACK TO, noncanonical transaction controls, leading SQL comments/whitespace, queries inside row transactions, nonzero source query errors and row flags other than STMT_END are deliberately unsupported in transaction mode. Raw event inspection can still expose supported query bytes for diagnostics. Unknown GTID flags also stop assembly. Tagged GTIDs and compressed/XA event types remain decoder-level failures.

The assembler requires contiguous physical offsets and `header.nextPosition == offset + eventSize`. Duplicated, skipped, reordered or incorrectly positioned frames fail. Rotation does not make an incomplete transaction complete. A live dump connection's artificial ROTATE/FDE/heartbeat events and zero positions require a separate transport envelope; feeding them as physical file events is not supported. The CLI still reads one file. The assembler API can follow validated rotation when its caller supplies the next file's events from a **fresh decoder**, rebuilding table-map state from that file's FDE and historical schema.

## Progress and failure semantics

`TransactionAssembler.lastCompleteBoundary` is an in-memory validated boundary. It advances after a complete group or safe file metadata, never after GTID/BEGIN/table-map/rows alone. It is **not** a durable captured position, an applied position, or a GTID auto-position set. The file relay must later synchronize event bytes before SQLite commits the referenced durable lengths and associated progress. Raw events do not belong in SQLite; see [relay state and SQLite status](RELAY_STATE_AND_STATUS.md). The caller must not infer source lineage, retention coverage or acknowledged target effects from this coordinate.

Any assembly error poisons that instance and releases buffered events. The diagnostic retains the failing coordinate, pending transaction start and previous complete boundary. Recovery requires new decoder/assembler instances and replay; there is no skip or speculative resynchronization. `finish()` rejects EOF inside a group even when the last frame was complete and CRC-valid. EOF at a completed group, in an otherwise valid empty file, or immediately after physical rotation is accepted.

Default per-group limits are 4096 events, 16 MiB of wire data and 32 MiB of retained-data accounting. The latter includes decoded values and copied strings/query/raw representations, with per-object allowances; it is not an RSS guarantee. Existing per-event decoder limits still apply. Output JSON allocation and consumer-retained completed groups are outside the assembler budget. A future durable relay must support large transactions without unbounded in-memory buffering; this increment stops at its limit.

## ABI and JSON versioning

The current interface is **ABI 6**, adding owned, length-prefixed ENUM/SET labels
to the table-map accessor. ABI 5 introduced raw type metadata, signedness and
exact decimal/temporal value kinds. Event JSON schema **4** retains those fields
and adds optional labels; transaction JSON remains version 1.
Swift requires ABI 6; rebuild Rust and Swift together. The transaction-control
change originally introduced ABI 3. `rc_event` adds event size, raw payload flags, source query error code and owned query-status bytes. Row flags are preserved without upstream's unknown-bit truncation. XID payloads must be exactly eight bytes; named GTIDs require a positive valid sequence, anonymous identities require zero SID/sequence. All C views are copied before freeing the Rust result.

The transaction-control increment introduced event JSON schema version **2**, adding `eventSize`, typed `control` and row-only `rowFlags`. Existing row/detail fields remain available. Named GTIDs expose a canonical SID, exact sequence and flags; anonymous markers are distinct. Query SQL and status-variable `Data` fields encode as base64, with source error code and database. Query status variables are preserved, not semantically interpreted. XID and rotation positions are exact strings. Previous-GTID sets remain opaque bytes. Transaction JSON has its own schema version **1** and now embeds version-4 events.

## Evidence and limits

`make test` includes 18 new tests for source/reference coordinates and identities, native COMMIT versus XID, anonymous and legacy groups, empty commit/rollback, multi-statement grouping, EOF at every frame within a transaction, misplaced controls, coordinate corruption, rotation, resource limits, raw unknown flags, query-status ownership across the C ABI, cancellation and CLI output/error behavior. Native fixture comparisons cover the declared workload range; later MyISAM rollback probes are not evidence of rollback support.

Swift/C AddressSanitizer and Ubuntu results are recorded in [implementation status](IMPLEMENTATION_STATUS.md). Rust remains uninstrumented by `make test-asan`. Broader mixed-language fuzzing, transport pseudo-event semantics, source-history validation, GTID-set progress, durable replay/resume, query-status interpretation and DDL/application policy remain open.

## Local upstream reference

The ignored `.upstream/mysql-server` checkout is a shallow full working tree of tag `mysql-8.4.8`, commit `0896fcd61dec11a0904166911a0126f59daaa1bf`. It is for source inspection only and is not linked into the product. Both `.gitignore` and `.dockerignore` already exclude `.upstream/`.

Read `libs/mysql/binlog/event/trx_boundary_parser.cpp` for group transitions, `control_events.cpp` for GTID sequence checks, and `rows_event.h` for statement flags. The native parser accepts more formats and ignores rotation for boundary-state purposes; our physical-file inspector intentionally rejects rotation within an incomplete group. Native permissive resynchronization in some applier contexts is not adopted.

Pinned references: [MySQL transaction parser](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/libs/mysql/binlog/event/trx_boundary_parser.cpp), [control event parser](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/libs/mysql/binlog/event/control_events.cpp), [row flags](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/libs/mysql/binlog/event/rows_event.h).
