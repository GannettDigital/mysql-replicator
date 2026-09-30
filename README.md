# mysql-replicator

Direct MySQL replication POC: Swift capture/application, Rust mysql_common decoding through a C ABI, and local binlog relay files with SQLite replication state. The intended source is Cloud SQL MySQL 8.4 InnoDB and the target is on-premises MySQL 5.7 MyISAM.

Phase 1 is in progress. The repository contains a bounded Rust decoder behind a Swift/C interface, an offline JSON inspector with bounded transaction assembly, and a tested native-reference harness. Swift capture, the file relay/SQLite state store, REST status API and target apply are not implemented yet. Decoder coverage is deliberately limited; see [offline inspect](PLAN/OFFLINE_INSPECT.md).

## Offline binlog inspection

```sh
make build
.build/debug/mysql-replicator inspect tests/ReplicatorLabTests/Fixtures/source-positive.binlog --schema tests/ReplicatorCodecTests/Schema/source-positive.json
```

The command prints JSON events, preserves exact values, and stops with a nonzero exit on malformed or unsupported input. Row decoding requires historical signedness/encoding tied to table-map positions. Add `--include-raw` for original event bytes. See [the schema format, supported types and review points](PLAN/OFFLINE_INSPECT.md).

For complete source groups and validated file/position boundaries:

```sh
.build/debug/mysql-replicator inspect tests/ReplicatorLabTests/Fixtures/source-positive.binlog --schema tests/ReplicatorCodecTests/Schema/source-positive.json --transactions --binlog-file binlog.000003
```

This mode rejects incomplete transactions at EOF and emits no partial group. Its coordinates are in-memory boundary candidates, not durable or applied checkpoints. See [transaction assembly and review points](PLAN/TRANSACTION_ASSEMBLY.md). The pinned MySQL 8.4.8 source checkout is available locally in ignored `.upstream/mysql-server` for protocol research.

## Repository automation

Automation lives in the SwiftPM executable `replicator-lab`. Make coordinates the Rust static-library prerequisite and provides short aliases. Python and shell workflow scripts have been removed.

```sh
make build
make test
make native-suite
make upstream-tests
make ubuntu-smoke
```

Equivalent SwiftPM harness commands:

```sh
swift run replicator-lab native-suite
swift run replicator-lab upstream-tests
swift run replicator-lab verify-evidence artifacts/native-suite/<case-directory>
```

`make native-suite` runs four isolated cases: autocommit success and expected native error 1837, each using file/position and GTID auto-positioning. A negative case passes only when the expected error, receiver state, failure boundary, partial rows and logical binlog effects match. Unrelated errors fail the suite. Each case preserves observed native outcome separately from assertion results. Swift apply remains explicitly pending.

The three servers have no published ports, use unique Compose projects and disposable volumes, and are cleaned up after each case. Evidence stays under `artifacts/native-suite/`. Source GTIDs remain ON with consistency ON; both targets use OFF_PERMISSIVE/WARN. Target client sessions initialize GTID_NEXT=AUTOMATIC. The native reference and future Swift target are separate servers.

For individual diagnostics:

```sh
make native-smoke ARGS="--positioning file-position --workload autocommit"
make native-smoke ARGS="--positioning file-position --native-init-automatic"
make native-smoke ARGS="--native-engine InnoDB"
```

The raw transaction/MyISAM smoke intentionally returns exit 1 for the verified native rejection; infrastructure or assertion failures return 2. Use the suite for a green expected-outcome check.

`make ubuntu-smoke` builds static x86_64 Linux executables and tests the actual networking/TLS, Rust codec/zstd and SQLite dependency stack in Ubuntu 16.04 containers, including TLS rejection and SQLite recovery after SIGKILL. See [the packaging spike](packaging/README.md) for scope, evidence and prerequisites. Docker tests the Ubuntu user environment under its own kernel; fleet kernel qualification remains separate.

## Prerequisites and limits

Validated host toolchain: Swift 6.2.1, Rust/Cargo 1.93.1, Docker Compose v2, Git, OpenSSL, and a MySQL 8.4 `mysqlbinlog` in PATH. Set `MYSQLBINLOG=/absolute/path/to/mysqlbinlog` when needed. The tested reference client is 8.4.6; the servers are 8.4.8 and 5.7.42. That patch difference is recorded in evidence. This is not Ubuntu 16.04 release qualification.

`mysqlbinlog` always receives `--no-defaults` to prevent host option files from filtering events, and `--verify-binlog-checksum`. The independent Swift normalizer covers only the known fixture schema: signed INT key, unescaped printable ASCII VARCHAR, and BIGINT UNSIGNED. It preserves UINT64_MAX as an exact string and verifies the signed/unsigned dual rendering. It is not the production decoder or a general lossless mysqlbinlog text converter. Windows containing rotation, arbitrary types/strings, DDL and other tables require further qualification.

`make test` builds and tests the Rust adapter, then runs SwiftPM tests without Docker. `make test-asan` instruments the Swift/C callers and CLI with AddressSanitizer; Rust instrumentation remains separate. Make clears Swift build products after building Rust to prevent stale static-library links. After `make codec`, direct `swift test` also works. `swift run replicator-lab` does not need the Rust archive. `make upstream-tests` fetches the pinned codec, explicitly enables its binlog test feature, uses a committed test lockfile, and writes a fixture catalog. Its test-only C++ dependencies are described in [upstream qualification](tests/Upstream/README.md). Production Rust dependencies exclude that test feature.

## Design and evidence

- [Local binlog files, SQLite state and REST status](PLAN/RELAY_STATE_AND_STATUS.md)

- [Ubuntu packaging results](PLAN/UBUNTU_PACKAGING_RESULTS.md)
- [Current Phase 1 progress](PLAN/PHASE_1_PROGRESS.md)
- [Implementation status and outstanding gates](PLAN/IMPLEMENTATION_STATUS.md)
- [Approved technical plan](PLAN/REPLICATOR_TECHNICAL_PLAN.md)
- [Native-reference compatibility contract](PLAN/NATIVE_REFERENCE_CONTRACT.md)
- [Reader/decoder decision](PLAN/REPLICATOR_CODEC_DECISION.md)
- [GTID qualification](PLAN/GTID_QUALIFICATION.md) and [positional experiments](PLAN/POSITIONAL_GTID_RESEARCH.md)
- [Imported planning provenance](PLAN/IMPORT_NOTES.md)
