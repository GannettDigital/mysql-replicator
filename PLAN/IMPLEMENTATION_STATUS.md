# Implementation status

Phase 1 is in progress. The approved architecture is unchanged. See [bootstrap validation and findings](BOOTSTRAP_RESULTS.md).

Initial scope:

- Independent Git repository and imported approved plans.
- Swift executable, C header/module and Rust static-library build structure; pinned `mysql_common` revision and Cargo lockfile. Only ABI version/capability exports exist; no decoder is advertised.
- Disposable three-server harness with aligned post-seed source coordinates, native 8.4 InnoDB-to-MyISAM replication, exact row/engine checks, raw binlogs, explicit pending 5.7 Swift parity.

Remaining Phase 1 gates:

- Build an expectation-aware native suite around the positive autocommit and accepted negative multi-statement cases; assert specific outcomes, not just process exit.

- Independent normalized event comparator and negative missing/duplicate/reordered/wrong-value/checkpoint cases; fixture catalog and provenance.
- Reproduce the explicit upstream 26-test binlog run in this repository, then implement ABI ownership/error/value tests.
- Process-kill, connection-cut, disk-full, rotation, DDL and transient-row scenarios; matched resource profiles and fleet inventory.
- Ubuntu 16.04 x86_64 deployment spike with actual Swift/NIO/TLS/SQLite/Rust/zstd dependencies.
- Full Phase 1 evidence report. A native smoke pass is not Phase 1 completion.

Phase 2 adds Swift capture, the strict Rust adapter, typed records, SQLite and JSON inspect. Phase 3 adds target apply and failure recovery. The CLI currently rejects all replication commands.

Current required fixture settings: source `gtid_mode=ON`, `enforce_gtid_consistency=ON`; both native 8.4 and future Swift 5.7 targets `gtid_mode=OFF_PERMISSIVE`, `enforce_gtid_consistency=WARN`. Native setup uses GTID auto-positioning. Source GTID mode is not downgraded to obtain a passing smoke test.

Native 8.4 MyISAM apply still stops with error 1837 after the first row of the multi-statement source transaction under these settings. The receive path connects and obtains GTIDs; exact row reads expose partial application. The user has accepted this as an expected negative reference for the initial Swift implementation, which may also reject the corresponding case with durable diagnostics and no applied-checkpoint advance. See [GTID qualification](GTID_QUALIFICATION.md) for the settings, controls, evidence and implications for Swift checkpoint design.

The [positional follow-up](POSITIONAL_GTID_RESEARCH.md) also reproduces error 1837 with Auto_Position=0, including a reset inside the actual applier thread via init_replica. A control with the same DML split into separate source commits passes into MyISAM under the required GTID settings. This supplies a restricted positive reference case; the original multi-statement workload is retained as an expected negative case. Resolving native error 1837 is no longer a prerequisite to progress. See [the accepted compatibility contract](NATIVE_REFERENCE_CONTRACT.md); the remaining Phase 1 gates still apply.
