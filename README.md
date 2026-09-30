# mysql-replicator

Direct MySQL replication POC: Swift capture/application, Rust mysql_common decoding through a C ABI, and local binlog relay files with SQLite replication state. The intended source is Cloud SQL MySQL 8.4 InnoDB and the target is on-premises MySQL 5.7 MyISAM.

Phase 1 is in progress. The repository contains a bounded Rust decoder behind a Swift/C interface, offline and live JSON inspection with bounded transaction assembly, and a tested native-reference harness. The first serial INSERT/UPDATE/DELETE applier now connects that pipeline to MySQL 5.7 MyISAM, with a local framed relay and SQLite state/row intents. The first [native engine/charset DDL slice](PLAN/DDL_NATIVE_DEFAULTS.md) removes compatibility rewrites and adds TRUNCATE, discovered defaults and native-reference fixtures. Broader [DDL completeness](PLAN/DDL_COMPLETENESS.md) remains in progress. Resume/recovery remains future work; statistics will be read from SQLite without an embedded REST server. Decoder coverage is deliberately limited; see [offline inspect](PLAN/OFFLINE_INSPECT.md).

Database dump/load and target provisioning are entirely external. The replicator starts from a prepared target and a known source position or executed GTID set; see [the start-boundary contract](PLAN/START_BOUNDARY.md).

The [DDL coverage catalog](tests/DDLCoverage/README.md) now provides an offline
checklist: `make ddl-catalog-check` validates it and `make ddl-catalog-report`
prints its current implementation and coverage gaps. All qualifications remain
unverified until assertion/evidence integration; upstream scanning and completeness
gates follow the [implementation plan](PLAN/DDL_COVERAGE_CATALOG.md).
`make upstream-tests` qualifies the Rust binlog codec only.

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

## Live source inspection

```sh
.build/debug/mysql-replicator inspect --source-config source.json --transactions
make live-suite
```

The live reader uses verified TLS and either file/position or GTID starts, follows rotation and stops with diagnostics on errors. It emits complete source groups but does not persist progress or apply them. See [configuration, limits and review points](PLAN/LIVE_INSPECTION.md). `make live-suite` compares the Ubuntu CLI against MySQL source/native binlogs, and tests replay, disconnects, certificate failures and purged history.

## First DML applier

```sh
make dml-suite
# Reuse an image built from this exact code:
make dml-suite ARGS=--skip-build
```

This three-server harness applies live source INSERT/UPDATE/DELETE to the 5.7
MyISAM target through Swift, and compares data and binlog effects with the source
and native 8.4 MyISAM replica. It checks both positional and GTID-only starts,
multi-row/key changes, exact values, stopped progress on errors and row intents.
Evidence and generated fixture configurations are under `artifacts/dml-suite/`.
Run `make ddl-suite` for interleaved schema changes and DML; its evidence is under
`artifacts/ddl-suite/`. Target UUID is discovered from the verified connection and
stored in SQLite; remove `targetUUID` from old configuration files.
Runtime files use a Docker-managed volume and are copied back for inspection.
Docker build/startup progress is streamed to the terminal.

For an externally prepared target, adapt [the configuration template](examples/apply.example.json),
then run `.build/debug/mysql-replicator run --config apply.json --initialize`.
The initial applier requires a **new state directory** and supports a deliberately
limited schema and single-statement transaction subset. It never reopens state or
retries uncertain writes. Review [supported behavior, setup, state ordering and
limits](PLAN/DML_APPLY.md) before using it. See [ordered DDL and its test suite](PLAN/DDL_APPLY.md) for the initial schema-change subset;
the [native-default follow-up](PLAN/DDL_NATIVE_DEFAULTS.md) supersedes its engine/charset rewriting.
First-start handoff, SQLite restart and audited skip/resolution follow DDL/DML correctness;
see [the future recovery contract](PLAN/START_BOUNDARY.md). Version 2 configuration has no
schema lists: discovery combines source table-map metadata with the prepared target.
SQLite keeps timestamped deltas and periodic GTID snapshots. Under storage pressure,
it prunes covered completed history older than `storage.historyRetentionSeconds`
(default 24 hours); age alone does not cause deletion. See [discovery, storage limits
and review points](PLAN/SCHEMA_DISCOVERY_AND_RETENTION.md).

## Repository automation

Automation lives in the SwiftPM executable `replicator-lab`. Make coordinates the Rust static-library prerequisite and provides short aliases. Python and shell workflow scripts have been removed.

```sh
make build
make test
make native-suite
make native-ddl-suite
make upstream-tests
make ubuntu-smoke
```

Equivalent SwiftPM harness commands:

```sh
swift run replicator-lab native-suite
swift run replicator-lab native-ddl-suite
swift run replicator-lab upstream-tests
swift run replicator-lab verify-evidence artifacts/native-suite/<case-directory>
```

`make native-suite` runs four isolated cases: autocommit success and expected native error 1837, each using file/position and GTID auto-positioning. A negative case passes only when the expected error, receiver state, failure boundary, partial rows and logical binlog effects match. Unrelated errors fail the suite. Each case preserves observed native outcome separately from assertion results. That native-only suite still leaves the Swift target untouched; `dml-suite` exercises the applier.

The three servers have no published ports, use unique Compose projects and disposable volumes, and are cleaned up after each case. Evidence stays under `artifacts/native-suite/`. Source GTIDs remain ON with consistency ON; both targets use OFF_PERMISSIVE/WARN. Target client sessions initialize GTID_NEXT=AUTOMATIC. The native reference and Swift target are separate servers.

For individual diagnostics:

```sh
make native-smoke ARGS="--positioning file-position --workload autocommit"
make native-smoke ARGS="--positioning file-position --native-init-automatic"
make native-smoke ARGS="--native-engine InnoDB"
```

The raw transaction/MyISAM smoke intentionally returns exit 1 for the verified native rejection; infrastructure or assertion failures return 2. Use the suite for a green expected-outcome check.

`make ubuntu-smoke` builds static x86_64 Linux executables and tests the actual networking/TLS, Rust codec/zstd and SQLite dependency stack in Ubuntu 16.04 containers, including TLS rejection and SQLite recovery after SIGKILL. See [the packaging spike](packaging/README.md) for scope, evidence and prerequisites. Docker tests the Ubuntu user environment under its own kernel; fleet kernel qualification remains separate.

## Prerequisites and limits

Validated host toolchain: Swift 6.2.1, Rust/Cargo 1.93.1, Docker Compose v2, Git, OpenSSL, the SQLite CLI, and a MySQL 8.4 `mysqlbinlog` in PATH. Set `MYSQLBINLOG=/absolute/path/to/mysqlbinlog` when needed. The tested reference client is 8.4.6; the servers are 8.4.8 and 5.7.42. That patch difference is recorded in evidence. This is not Ubuntu 16.04 release qualification.

`mysqlbinlog` always receives `--no-defaults` to prevent host option files from filtering events, and `--verify-binlog-checksum`. The independent Swift normalizer covers only the known fixture schema: signed INT key, unescaped printable ASCII VARCHAR, and BIGINT UNSIGNED. It preserves UINT64_MAX as an exact string and verifies the signed/unsigned dual rendering. It is not the production decoder or a general lossless mysqlbinlog text converter. The live suite splits its rotation comparison into two recorded file windows. The DML suite separately checks additional exact values with an SQL HEX oracle; the text normalizer remains limited to this fixture. Broader types, schemas and DDL require further qualification.

`make test` builds and tests the Rust adapter, then runs SwiftPM tests without Docker. `make test-asan` instruments the Swift/C callers and CLI with AddressSanitizer; Rust instrumentation remains separate. Make clears Swift build products after building Rust to prevent stale static-library links. After `make codec`, direct `swift test` also works. `swift run replicator-lab` does not need the Rust archive. `make upstream-tests` fetches the pinned codec, explicitly enables its binlog test feature, uses a committed test lockfile, and writes a fixture catalog. Its test-only C++ dependencies are described in [upstream qualification](tests/Upstream/README.md). Production Rust dependencies exclude that test feature.

## Design and evidence

- [First DML applier](PLAN/DML_APPLY.md)
- [Local binlog files, SQLite state and external statistics readers](PLAN/RELAY_STATE_AND_STATUS.md)

- [Ubuntu packaging results](PLAN/UBUNTU_PACKAGING_RESULTS.md)
- [Current Phase 1 progress](PLAN/PHASE_1_PROGRESS.md)
- [Implementation status and outstanding gates](PLAN/IMPLEMENTATION_STATUS.md)
- [Approved technical plan](PLAN/REPLICATOR_TECHNICAL_PLAN.md)
- [Native-reference compatibility contract](PLAN/NATIVE_REFERENCE_CONTRACT.md)
- [Reader/decoder decision](PLAN/REPLICATOR_CODEC_DECISION.md)
- [GTID qualification](PLAN/GTID_QUALIFICATION.md) and [positional experiments](PLAN/POSITIONAL_GTID_RESEARCH.md)
- [Imported planning provenance](PLAN/IMPORT_NOTES.md)
