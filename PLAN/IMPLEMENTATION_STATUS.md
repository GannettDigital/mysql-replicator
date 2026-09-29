# Implementation status

Phase 1 is in progress. The approved architecture is unchanged. See [bootstrap validation and findings](BOOTSTRAP_RESULTS.md).

Initial scope:

- Independent Git repository and imported approved plans.
- Swift executable, C header/module and Rust static-library build structure; pinned `mysql_common` revision and Cargo lockfile. Only ABI version/capability exports exist; no decoder is advertised.
- Disposable three-server harness with aligned post-seed source coordinates, native 8.4 InnoDB-to-MyISAM replication, exact row/engine checks, raw binlogs, explicit pending 5.7 Swift parity.

Remaining Phase 1 gates:

- Independent normalized event comparator and negative missing/duplicate/reordered/wrong-value/checkpoint cases; fixture catalog and provenance.
- Reproduce the explicit upstream 26-test binlog run in this repository, then implement ABI ownership/error/value tests.
- Process-kill, connection-cut, disk-full, rotation, DDL and transient-row scenarios; matched resource profiles and fleet inventory.
- Ubuntu 16.04 x86_64 deployment spike with actual Swift/NIO/TLS/SQLite/Rust/zstd dependencies.
- Full Phase 1 evidence report. A native smoke pass is not Phase 1 completion.

Phase 2 adds Swift capture, the strict Rust adapter, typed records, SQLite and JSON inspect. Phase 3 adds target apply and failure recovery. The CLI currently rejects all replication commands.

Observed qualification issue: the first GTID-enabled native 8.4 run stopped on the initial multi-statement InnoDB-to-MyISAM transaction with error 1837 (`GTID_NEXT` after COMMIT/ROLLBACK). Its source UUID/GTID and diagnostics are retained in the local failed-run artifacts. The cause and production implications require investigation; do not infer GTID compatibility from the positional smoke. The default baseline disables GTID explicitly; `native_smoke.py --gtid` preserves the failing scenario without error skipping.
