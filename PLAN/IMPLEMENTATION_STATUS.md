# Implementation status

Phase 1 is in progress. The reviewed GTID/reference checkpoint is commit `42c36d3`. See [the current implementation evidence](PHASE_1_PROGRESS.md).

Implemented and validated:

- Independent repository, approved architecture and accepted native-reference contract.
- Swift/Rust static-library build skeleton; production decoding capability remains zero.
- SwiftPM `replicator-lab` replaces the Python harness. Make coordinates Cargo and SwiftPM; no Python or shell workflow script is required.
- Four-case native suite: positive autocommit and expected error 1837 under both positional and GTID auto-positioning. Exact rows, receiver/applier status, boundaries, GTID coverage, engines, rollback behavior and cleanup are asserted.
- Physical binlog capture plus checksum-verified mysqlbinlog reference decoding and ordered logical operation comparison for the fixed fixture schema. Source/native effects and unchanged future Swift target are checked independently of final rows.
- Swift tests for missing/duplicate/reordered/wrong-value operations, transient insert/delete history, prematurely advanced native completion, malformed reference rows and process timeouts. Three synthetic offline reference fixtures have provenance and checksums.
- Ubuntu 16.04 container userland spike: static x86_64 CLI and dependency probe build/run; verified MySQL TLS plus negative certificate cases, Rust decoding/zstd, NIO DNS/timers and SQLite WAL/FULL SIGKILL recovery/locking/checkpoint/restart pass. Docker uses emulation and its modern kernel. See [packaging results](UBUNTU_PACKAGING_RESULTS.md).
- Reproducible upstream codec qualification: 26 tests pass with binlog explicitly enabled, committed test lockfile and a generated catalog of 41 upstream binlog fixtures.

Remaining Phase 1 gates:

- Broaden the independent corpus beyond the fixed three-column schema, including exact boundary types, multi-row statements, DDL, key changes and live transient-row histories. Add an independent Go reference where planned; the current external decoder is MySQL's mysqlbinlog.
- Implement process-kill, connection-cut, disk-full and rotation/restart controls and appropriate resource profiles. ProcessRunner timeout tests do not satisfy these database failure scenarios.
- Strengthen the Rust/Swift ABI beyond version/capability exports with ownership/error/value tests; current upstream and harness tests do not qualify the production adapter.
- Complete Ubuntu 16.04 fleet qualification: the actual Swift/NIO/TLS/SQLite/Rust/zstd stack now builds and passes in x86_64 Ubuntu containers using the Static Linux SDK in Docker. Run the artifacts on the fleet kernel/CPU/filesystem class and qualify CA configuration/rotation, service management and release packaging. The container result is not full production or old-kernel qualification.
- Complete the remaining per-pair workload inventory and publish the Phase 1 exit report. This increment is not Phase 1 completion.

Source settings remain ON/ON; both targets remain OFF_PERMISSIVE/WARN. The positive native MyISAM case now passes with both positioning modes. The native multi-statement error-1837 case is an accepted expected-negative reference, so it is not necessary to make native MySQL succeed before proceeding. Swift target apply and its durable BLOCKED/checkpoint behavior remain Phase 3 work.
