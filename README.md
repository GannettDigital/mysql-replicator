# mysql-replicator

Direct MySQL replication POC: Swift capture/application, Rust mysql_common decoding through a C ABI, and a local SQLite durable relay. The intended source is Cloud SQL MySQL 8.4 InnoDB and the target is on-premises MySQL 5.7 MyISAM.

Phase 1 is in progress. The repository contains a Swift/Rust build skeleton and a tested native-reference harness. Swift capture, production decoding, SQLite relay and target apply are not implemented yet.

## Repository automation

Automation lives in the SwiftPM executable `replicator-lab`. Make coordinates the Rust static-library prerequisite and provides short aliases. Python and shell workflow scripts have been removed.

```sh
make build
make test
make native-suite
make upstream-tests
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

## Prerequisites and limits

Validated host toolchain: Swift 6.2.1, Rust/Cargo 1.93.1, Docker Compose v2, Git, OpenSSL, and a MySQL 8.4 `mysqlbinlog` in PATH. Set `MYSQLBINLOG=/absolute/path/to/mysqlbinlog` when needed. The tested reference client is 8.4.6; the servers are 8.4.8 and 5.7.42. That patch difference is recorded in evidence. This is not Ubuntu 16.04 release qualification.

`mysqlbinlog` always receives `--no-defaults` to prevent host option files from filtering events, and `--verify-binlog-checksum`. The independent Swift normalizer covers only the known fixture schema: signed INT key, unescaped printable ASCII VARCHAR, and BIGINT UNSIGNED. It preserves UINT64_MAX as an exact string and verifies the signed/unsigned dual rendering. It is not the production decoder or a general lossless mysqlbinlog text converter. Windows containing rotation, arbitrary types/strings, DDL and other tables require further qualification.

`make test` builds the Rust prerequisite and runs SwiftPM tests without Docker. After `make codec`, direct `swift test` also works. `swift run replicator-lab` does not need the Rust archive. `make upstream-tests` fetches the pinned codec, explicitly enables its binlog test feature, uses a committed test lockfile, and writes a fixture catalog. Its test-only C++ dependencies are described in [upstream qualification](tests/Upstream/README.md). Production Rust dependencies exclude that test feature.

## Design and evidence

- [Current Phase 1 progress](PLAN/PHASE_1_PROGRESS.md)
- [Implementation status and outstanding gates](PLAN/IMPLEMENTATION_STATUS.md)
- [Approved technical plan](PLAN/REPLICATOR_TECHNICAL_PLAN.md)
- [Native-reference compatibility contract](PLAN/NATIVE_REFERENCE_CONTRACT.md)
- [Reader/decoder decision](PLAN/REPLICATOR_CODEC_DECISION.md)
- [GTID qualification](PLAN/GTID_QUALIFICATION.md) and [positional experiments](PLAN/POSITIONAL_GTID_RESEARCH.md)
- [Imported planning provenance](PLAN/IMPORT_NOTES.md)
