# mysql-replicator

Direct MySQL replication POC: Swift capture and application, a Rust `mysql_common` codec through a C ABI, and a local SQLite durable relay. Intended topology: Cloud SQL MySQL 8.4 InnoDB to on-premises MySQL 5.7 MyISAM.

This is an independent repository created from the approved design in `maxwell-mysql-consumer`. The initial implementation provides a buildable Swift/Rust ABI skeleton and an isolated three-server native-reference smoke harness. It does **not** replicate through Swift yet.

## Development

Local baseline: Swift 6.2.1, Cargo/Rust 1.93.1, Python 3, Docker Compose v2. Run from this repository:

```sh
make build
.build/debug/mysql-replicator --help
make native-smoke
```

The build compiles the pinned Rust dependency with binlog support, statically links the adapter into Swift and checks the ABI version. Its capability mask is zero until decoding is implemented. `Cargo.lock` pins transitive dependencies. The production decoder excludes upstream's `test` feature. This host development build is not the qualified Ubuntu 16.04 release build.

The harness starts fresh MySQL 8.4 InnoDB, 8.4 MyISAM native replica and 5.7 MyISAM future Swift target containers. It uses a unique Compose project, no published ports and disposable volumes. It verifies source/native rows, engines, rollback behavior and captures raw binlogs, coordinates and configuration. It always cleans up its own containers/volumes, retaining evidence under `artifacts/native-smoke/<run-id>/`. Fixture credentials are local-only. Failed cleanup is reported with the project name. Logical binlog decoding/comparison is pending: the minimal 8.4 fixture lacks `mysqlbinlog`; raw files and SHA-256 digests are captured for the forthcoming reference decoder. The default source uses `gtid_mode=ON` and `enforce_gtid_consistency=ON`. Every fixture target client session explicitly runs `SET @@SESSION.GTID_NEXT = 'AUTOMATIC';`; the separate native applier still receives source GTIDs. Both replicas use `gtid_mode=OFF_PERMISSIVE` and `enforce_gtid_consistency=WARN`, as required for the cloud-source POC. The native channel uses GTID auto-positioning after an explicit disposable-fixture snapshot handoff. The current MyISAM workload still fails with native error 1837; `make native-smoke` returns nonzero and preserves diagnostics and raw binlogs. This is now an accepted negative reference under the [initial compatibility contract](PLAN/NATIVE_REFERENCE_CONTRACT.md): Swift may stop on the corresponding native-failing cases. The raw smoke command still exits nonzero; an expectation-aware suite remains to be implemented. See [GTID qualification results](PLAN/GTID_QUALIFICATION.md).

Run `python3 tests/harness/native_smoke.py --native-engine InnoDB` for the engine control. Each server's GTID mode is independently configurable; `--positioning file-position` selects coordinate-based positioning while still allowing a GTID-enabled source. `--gtid` retains the old all-ON experiment. The previous all-OFF baseline is available only with explicit `--source-gtid-mode OFF --native-gtid-mode OFF --target57-gtid-mode OFF --positioning file-position`.

The 5.7 target remains at its seed boundary; Swift parity is explicitly pending.

Additional diagnostic cases are documented in [positional GTID research](PLAN/POSITIONAL_GTID_RESEARCH.md). `--native-init-automatic` runs the reset inside the native SQL thread at startup; `--workload autocommit` changes the first three source DML statements into separate transactions. Keep both cases: autocommit is the positive reference and the original multi-statement workload is the expected negative reference.

## Design and status

- [Approved technical plan](PLAN/REPLICATOR_TECHNICAL_PLAN.md)
- [Reader/decoder decision and research evidence](PLAN/REPLICATOR_CODEC_DECISION.md)
- [Implementation status and next gates](PLAN/IMPLEMENTATION_STATUS.md)
- [Imported-document provenance](PLAN/IMPORT_NOTES.md)

No remote repository, production connection, deployment or production-ready replication service is configured.
