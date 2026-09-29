# Reader and decoder implementation decision

Date: 2026-09-28. Applies to [REPLICATOR_TECHNICAL_PLAN.md](REPLICATOR_TECHNICAL_PLAN.md). Status: **selected for implementation; production qualification pending**.

## Decision

Use **a Swift capture reader on MySQLNIO/SwiftNIO, and the Rust `mysql_common` binlog codec behind a narrow C ABI**. Keep SQLite, transaction assembly, schema history, target application, diagnostics, bootstrap and the CLI in Swift. Statically link the Rust adapter into the Swift executable. Use Go's reader and selected Go/MySQL/Rust fixtures as independent test references.

This replaces the earlier “try native Swift, decide in Phase 2” approach. We will not build two production decoders or port the full Go decoder into Swift. Phase 2 qualifies the selected architecture rather than running an open-ended language comparison.

“Reader” here means transport/authentication reuse plus new replication-command framing: receive original event bytes, apply size/backpressure limits and persist them. “Decoder” means interpreting event bodies, table maps, binary values, JSON, decimals and temporal formats. The latter has the larger reusable implementation and fixture investment. The new Swift reader is not a new TLS or general MySQL client implementation.

## Evidence used

The pins from the main plan were inspected more deeply, including actual assertions and error paths. One additional clone was inspected: `blackbeam/rust-mysql-simple`, version declaration 28.0.1, commit `e5d282f98ab0e9b93537f74671a8f13102e2c4a5`, under `.upstream/rust-mysql-simple`.

| Candidate | Test evidence and limitations | Decision |
| --- | --- | --- |
| Native Swift port from Go | The inspected `go-mysql/replication/*test.go` contains 98 test/fuzz function declarations under a simple source count, including exact row/type assertions, malformed inputs, GTIDs and compression; additional packet tests cover framing. This is a valuable test source, not measured branch coverage or a complete specification. Porting tests does not transfer the correctness of implementation paths they do not assert. Go tests were inspected, not executed in this research. | Port relevant vectors and scenarios, not the full production decoder. |
| Rust `mysql_common` via C ABI | 41 checked-in binlog fixture files, exact row/metadata assertions, serialization roundtrips, GTID cases and a decimal property test against MySQL C++ routines. Explicitly enabled binlog test run passed; local Swift/C/Rust probe passed. Requires the strict adapter work below. | **Selected codec**, pinned to `374c9d5c24f76a00b678d5b1d7103d6ceb4edb8c` (version declaration 0.38.2). |
| Rust `mysql` client plus codec, all behind ABI | Has positional/GTID/nonblocking streaming tests, but the inspected `should_read_binlog` primarily asserts that events parse and count is nonzero. `BinlogStream` returns decoded `Event` objects, while the exact packet bytes are private to `next()`. A raw-byte delivery extension/fork would be needed to meet our capture-before-decode contract without reserializing events. | Do not add a second network/TLS client or its raw-stream fork now. Keep capture in the existing Swift networking stack. |
| MariaDB Connector/C | Existing C replication API makes interop easy; `rpl_api.c` registers ten tests, many specific to MariaDB event/GTID semantics. Inspected MySQL event enumeration stops before event types 40–42. This does not establish Oracle 8.4 default-feature coverage. | Not selected. The ABI is easier than filling and qualifying the dialect gaps. |
| ApeCloud Rust connector | Useful data-type integration tests and 5.7/8.0 fixtures, but file tests count until any error; runtime skips checksum bytes and compressed decoding stops its loop on any nested parser error. | Fixture/scenario source only. More stream/error-path repair than the codec-only adapter needs. |
| Oracle MySQL C client | `mysql_binlog_fetch` exposes event buffers directly and is a valid capture alternative. It does not by itself provide our typed row/value decoder or Swift recovery layer. | Not selected for this build: would add another client stack alongside MySQLNIO and still require the codec. |
| Go through C ABI or helper process | Broad event support and reusable tests. A helper is straightforward but changes deployment; a linked Go wrapper adds its runtime, cgo build and ownership boundary. | Keep in the harness, outside the shipped executable. |

Counts above are inventory, not coverage percentages. There is no evidence supporting a claim that any candidate's tests completely specify MySQL 8.4 behavior. Reusing the Rust implementation and supplementing its tests is less duplicated work than recreating the same decoding rules in Swift. That is the engineering judgment behind the selection, not a claim that Rust is inherently more correct.

Sources: [Go tests](https://github.com/go-mysql-org/go-mysql/tree/51f557e85dcd3345496cc0b89f69c2c6e02bd908/replication), [Rust fixture assertions](https://github.com/blackbeam/rust_mysql_common/blob/374c9d5c24f76a00b678d5b1d7103d6ceb4edb8c/src/binlog/mod.rs), [Rust decimal property test](https://github.com/blackbeam/rust_mysql_common/blob/374c9d5c24f76a00b678d5b1d7103d6ceb4edb8c/src/binlog/decimal/test/mod.rs), [Rust client's stream API](https://github.com/blackbeam/rust-mysql-simple/blob/e5d282f98ab0e9b93537f74671a8f13102e2c4a5/src/conn/binlog_stream.rs), [Rust client's streaming test](https://github.com/blackbeam/rust-mysql-simple/blob/e5d282f98ab0e9b93537f74671a8f13102e2c4a5/src/conn/mod.rs), [MariaDB API tests](https://github.com/mariadb-corporation/mariadb-connector-c/blob/be67a4fc1e0493913732df90e562f122bff9dfe3/unittest/libmariadb/rpl_api.c), [Oracle raw event API](https://dev.mysql.com/doc/c-api/8.4/en/mysql-binlog-fetch.html).

## Tests actually run

On the local arm64 macOS host, Rust 1.93.1 and Apple Swift 6.2.1:

```sh
cargo test --manifest-path .upstream/rust_mysql_common/Cargo.toml \
  --no-default-features --features test,binlog,flate2/rust_backend \
  --lib binlog --target-dir /tmp/replicator-rust-research-target
```

Result: **26 passed, 0 failed, 0 ignored, 86 filtered out**, test execution 7.63 seconds after build. The `binlog` name filter also selects packet tests such as `com_binlog_dump_gtid_roundtrip`; this is not 26 separate end-to-end replication cases. The decimal property test configures 16,384 generated cases against the C++ reference. The aggregate binlog roundtrip test traverses the fixture directory and includes selected semantic row assertions, not exhaustive independent expected values for every fixture.

The first attempted invocation omitted upstream's required `test` feature and failed to compile; the successful run uses the corrected command above. The test feature links the upstream MySQL decimal reference support and is **test-only**, not part of the shipped codec dependency. The resolved lockfile is preserved with the evidence; production must pin its own smaller dependency graph.

Built a research-only Rust `staticlib` and imported its C header into a Swift executable. On `mysql-enum-string-set.000001` (fixture server string 8.0.28), the Swift caller passed original bytes into Rust, decoded **21 events and 3 row images**, and verified rejection of a truncated event, corrupted CRC and an oversized event length. The simple function returns fixed-width result/count values; this establishes a working ABI/link path, not the final typed-value API. Early probe runs used a pre-checksum 5.1 file and a GTID fixture with no row events; their CRC/row assertions were inapplicable. The final fixture explicitly exercises rows and checksums.

Evidence under ignored `artifacts/replicator-codec-research/`:

- `upstream-tests.log`, `upstream-Cargo.lock`;
- `abi-probe/`: Cargo manifest/lock, Rust source, C header/module map, Swift caller and local executable;
- `abi-build.log`, `abi-results.log`.

Reproduce the ABI probe from the saved research sources with:

```sh
cargo build --manifest-path artifacts/replicator-codec-research/abi-probe/Cargo.toml \
  --locked --target-dir /tmp/replicator-rust-research-target
swiftc -module-cache-path /tmp/replicator-probe-swift-cache \
  -I artifacts/replicator-codec-research/abi-probe/include \
  artifacts/replicator-codec-research/abi-probe/probe.swift \
  /tmp/replicator-rust-research-target/debug/libreplicator_codec_abi_probe.a \
  -o artifacts/replicator-codec-research/abi-probe/probe
artifacts/replicator-codec-research/abi-probe/probe \
  .upstream/rust_mysql_common/test-data/binlogs/mysql-enum-string-set.000001
```

Fixture SHA-256: `f0964305ad925d94039797f152238b8fe77a1a0928915d624d284fae605c4764`.

No 8.4 live source, target applier, Linux x86_64 binary, Ubuntu 16.04 deployment, complete ABI lifetime tests or throughput benchmark was run. The local link emitted deployment-version warnings for bundled zstd objects; this host probe is not a portable release artifact. The warnings reinforce the need for a consistent target/toolchain in Phase 1.

## Implementation increment

The first bounded adapter and offline JSON inspector are implemented. [Offline inspect](OFFLINE_INSPECT.md) records the supported subset, ABI 2 ownership contract, historical column-context approach, tests and remaining qualification work. This implementation does not change the selected upstream revision or claim full event/type coverage.

## Required strict adapter behavior

The upstream crate is a low-level parser, not a fail-closed replication boundary. These are mandatory implementation tasks, not optional hardening:

1. **Framing and EOF:** reject short headers, impossible lengths, extra bytes and oversized events before parser allocation. In the inspected `Event::read`, body reading uses `unwrap`; the `BinlogFile` iterator maps `UnexpectedEof` to end-of-input. Do not use that iterator as the production file reader. Swift frames exact complete events and the Rust adapter validates them again; an incomplete offline final event is an error.
2. **Checksums:** the inspected read path stores a checksum and exposes `calc_checksum`, but does not compare them. The adapter must verify it and the checksum algorithm explicitly; preserve special format-description rules and the absence of inner CRCs in compressed transaction payloads. Failed verification must not publish rows or advance state. Discard a decoder context after any fatal error and rebuild its state from a verified boundary.
3. **Unsupported events:** `Event::read_data` can return `None`, and heartbeat v2 is explicitly absent from the enum. Preserve type/header/raw bytes and return a typed unsupported error. Implement heartbeat v2 with MySQL/Go-derived fixtures before its use, or establish a tested heartbeat-v1 request contract. Never turn `None` into successful skip. XA, tagged GTID and partial JSON decode support does not automatically mean applier support.
4. **Historical metadata:** `BinlogRow::deserialize` defaults missing optional signedness metadata to signed. Source schema history must supply authoritative column signedness and encoding where absent, especially for 5.7/minimal-metadata streams. Add a small reviewed Rust API extension for column decode context when the current public API cannot supply it. Validate UINT64_MAX, high-bit integer values, binary/text and ENUM/SET with missing metadata; do not guess from today's schema or mandate FULL metadata as a workaround for 5.7.
5. **Resource bounds:** limit frame length, column counts, table-map growth, individual values, decoded output, compressed size and expansion. Iterate compressed inner events/rows incrementally; validate complete consumption. A panic catcher cannot recover from every allocation failure, abort, undefined behavior or process fault.
6. **ABI errors:** no Rust panic may unwind into Swift. Catch unwind-capable panics at every exported entry point, return an internal-error status and invalidate the context. Rust aborts remain process failures handled through the durable relay. Preserve error location and reason without exposing credentials. Do not equate a caught panic with an ordinary recoverable input error.

These gaps are bounded adapter/extension work and are explicitly covered in Phase 2. They are also why a green upstream suite is insufficient justification for using the high-level iterator unmodified. [Event read/checksum code](https://github.com/blackbeam/rust_mysql_common/blob/374c9d5c24f76a00b678d5b1d7103d6ceb4edb8c/src/binlog/events/mod.rs), [reader/iterator code](https://github.com/blackbeam/rust_mysql_common/blob/374c9d5c24f76a00b678d5b1d7103d6ceb4edb8c/src/binlog/mod.rs), [row metadata handling](https://github.com/blackbeam/rust_mysql_common/blob/374c9d5c24f76a00b678d5b1d7103d6ceb4edb8c/src/binlog/row.rs), [event enum](https://github.com/blackbeam/rust_mysql_common/blob/374c9d5c24f76a00b678d5b1d7103d6ceb4edb8c/src/binlog/consts.rs).

## ABI and ownership contract

Expose our own small versioned C header, not Rust struct layouts or the whole crate API. Swift's Clang importer can consume that header through a module map. Rust uses `extern "C"` functions and a `staticlib`; no Tokio runtime or Rust network connection is needed. [Rust FFI guidance](https://doc.rust-lang.org/nomicon/ffi.html).

Proposed surface: ABI version/capabilities, create/destroy decoder, set historical column context, feed one framed event, fetch next decoded record, inspect a record/error and release it. Use opaque handles, `uint32_t`/`int32_t` tags, pointer-plus-length bytes and explicit result statuses. Avoid C strings for application values. Decoding context owns format-description/table-map state; Swift owns source identity, transaction/recovery/checkpoint policy.

Input is borrowed only for the call unless the documented feed operation copies it into a Rust-owned bounded frame. Returned records own their storage until released by the matching Rust function; Swift never frees Rust memory with its allocator. Fixed-width integers, decimal digit strings, binary bytes, temporal components and explicit NULL/missing/JSON tags cross the ABI losslessly. Use one bounded event/row batch with lazy draining instead of a complete decompressed transaction tree. Never expose pointers into released Swift `Data` or into Rust vectors that will be resized. Calls on one context are serialized on a decoder worker, with no callbacks into Swift or work on a NIO event loop.

JSON is produced by the Swift inspection layer from these same typed records. JSON strings are not the production ABI, and generic serde-to-floating-point conversion is not the numeric contract. ABI tests must cover invalid arguments, repeated create/free, error lifetimes, context poisoning, cancellation/reset, exact value conversion and sanitizer runs in addition to decoder fixtures.

## Test and build ownership

- **Upstream Rust tests:** explicitly run with `test,binlog`. The inspected CI workflow runs a compile-check feature matrix, but its main test invocation is only `cargo test --features test`; defaults omit `binlog`. Do not infer binlog runtime coverage from that workflow badge. Pin and run our exact feature set in our CI. [Inspected workflow](https://github.com/blackbeam/rust_mysql_common/blob/374c9d5c24f76a00b678d5b1d7103d6ceb4edb8c/.github/workflows/rust.yml).
- **Adapter regression tests:** execute at the C boundary for framing/CRC/unknown-event failures and typed values. Import Go vectors here and through the Swift wrapper; they must not only test the Rust functions directly. Preserve any local Rust extension as a small patch with a regression case and upstream contribution where appropriate.
- **Swift reader tests:** add dump/GTID request fixtures, packet fragmentation/continuation, sequence wrap, TLS/authentication, cancellation, backpressure, disconnect/reconnect and raw-byte equality. Reuse MySQLNIO for connection/authentication; do not claim its SQL tests cover the new streaming command. Reconnect uses Swift's durable state, not hidden library progress.
- **End-to-end tests:** retain the independent writer model and native 8.4 branch, and run the three-server tests from the main plan. The Rust codec cannot serve as the sole oracle for its own output.
- **Deployment:** pin Rust/compiler/SDK/Cargo.lock, build `mysql_common` with only required production features (no decimal-reference `test` feature), link matching x86_64 musl objects with the Swift Static Linux SDK, and qualify SQLite/zstd/TLS together on Ubuntu 16.04. macOS arm64 and Linux x86_64 outputs are distinct artifacts. Verify notices, native link dependencies and symbol collisions; never mix glibc and musl archives in one target.

The architecture decision is closed. It should be reopened only for a demonstrated blocker—such as unresolvable historical-value decoding, deployment incompatibility or failing performance after measurement—not merely because another language binding is possible. Such a blocker stops the relevant phase and produces evidence; it does not silently start a second decoder implementation.
