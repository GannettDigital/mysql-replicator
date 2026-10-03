# Implementation status

Phase 1 is in progress.

Current follow-up after `3618fd4`: [native engine/charset defaults](DDL_NATIVE_DEFAULTS.md)
remove DDL compatibility rewriting, resolve inherited defaults from discovered schema,
add typed Rust query-context decoding and TRUNCATE, and broaden the native/Swift
fixtures. General DDL/type/charset coverage and recovery are still open. The earlier
prototype validation below remains tied to that checkpoint.

Reviewed DML checkpoint: `d188f58`. The current follow-up implements automatic
schema discovery (version 2 configuration), ABI 6/event JSON 4 metadata and bounded
SQLite history. Cleanup removes covered completed records older than the minimum
age only when storage approaches its limit. See [the implementation and storage
policy](SCHEMA_DISCOVERY_AND_RETENTION.md). That work is committed as `e8c0e77`.
The current follow-up adds discovered target UUIDs and a strict ordered DDL subset
with versioned schema/DDL intents; see [DDL application](DDL_APPLY.md). Its forced engine/charset/collation rewrites are superseded by the
[next DDL completeness plan](DDL_COMPLETENESS.md) and are replaced in the foundation follow-up.
Resume/recovery and operator skip/resolution remain future work. Statistics will
be read from SQLite; an embedded REST API is no longer planned. The DDL increment passes 80 Swift tests normally and
with Swift/C/CLI AddressSanitizer, the Rust test, both strengthened DDL start modes
and both existing DML regression modes; evidence is recorded in the DDL document. Those passes describe the old prototype
and do not qualify the revised native engine policy or broader DDL support.
 The reviewed GTID/reference checkpoint is commit `42c36d3`. See [the current implementation evidence](PHASE_1_PROGRESS.md).

Previous decoder checkpoint (`9378bf4`): 30 Swift tests and one Rust panic-containment test pass; all 30 Swift tests also pass with Swift/C/CLI AddressSanitizer instrumentation. Rust itself remains uninstrumented. Ubuntu run `replicator-ubuntu-20260929t230511z-5a362b66` passed, including the production inspector; all 36 source-file JSON events match the host output. Local evidence is under `artifacts/decoder/` and `artifacts/ubuntu/<run>/`.

Transaction checkpoint (`2395b94`): typed control fields through ABI 3, event JSON schema 2 and bounded Swift transaction assembly are implemented. `inspect --transactions --binlog-file NAME` emits complete source groups and rejects incomplete EOF, illegal transitions and invalid physical coordinates. 48 Swift tests pass, including 18 transaction tests; Rust's panic-containment test also passes. These are in-memory boundary candidates, not durable progress. See [transaction assembly](TRANSACTION_ASSEMBLY.md) for the review command, limits and local MySQL source reference.

That checkpoint also passes all 48 Swift tests with Swift/C/CLI AddressSanitizer (Rust uninstrumented). Ubuntu run `replicator-ubuntu-20260930t014415z-67fc2683` passed, including transaction inspection and cleanup; all nine transaction records and all 36 event records match the host output byte for byte. Evidence is in `artifacts/transactions/` and `artifacts/ubuntu/replicator-ubuntu-20260930t014415z-67fc2683/`.

Live checkpoint (`d7725b2`): verified-TLS Swift capture supports file/position and GTID dump commands, bounded packet framing, synthetic context, heartbeat gaps, rotation and JSON inspection using the same Rust decoder and Swift assembler. See [live inspection](LIVE_INSPECTION.md) for configuration, limits, harness and review points. The source schema is frozen at a caller-supplied verified seed boundary; DDL stops inspection. That inspection command has no automatic reconnect, durable progress or target apply. All 63 Swift tests pass normally and with Swift/C/CLI AddressSanitizer; Rust remains uninstrumented.

Ubuntu live run `20260930T030250Z-17f7bd18-auto-autocommit-myisam` passed all 15 checks and cleanup. Positional and GTID readers emit identical complete-group JSON across rotation; source/mysqlbinlog/native MyISAM comparisons, explicit replay/resume, clean nonblocking EOF, disconnect, certificate/identity rejection and purged-history error 1236 pass. Evidence is in `artifacts/live-suite/<run>/` and test/build logs in `artifacts/live-capture-validation/`. The shipped static Ubuntu binary was exercised under Docker Desktop amd64 emulation.

Scope update: dump/load management and target provisioning are entirely external. Replace the earlier dump preparation/verification proposal with a tool-independent known-boundary handoff. The first serial end-to-end MyISAM applier now includes the minimum relay/state/intent support it needs. The immediate next work is native-compatible DDL completeness, with subsequent DML for every supported change. Crash/reconnect recovery implementation and qualification come only after both DML and DDL pass their correctness gates; external SQLite readers replace the REST requirement. GTID mode now permits a seed set without positional context. See [the boundary contract and next increment](START_BOUNDARY.md).

Next storage/runtime design is updated: raw events live in local binlog/relay files; SQLite holds state, GTID/file-position checkpoints, recovery intents, diagnostics and counter snapshots. SQLite exposes persisted status/statistics to external readers; a stable read contract and broader snapshots remain planned. The applier implements a bounded framed relay, state/intents and pressure-triggered SQLite history cleanup; relay rotation and reopening/recovery remain planned; see [relay state and status](RELAY_STATE_AND_STATUS.md).

Current DML increment: `run --config FILE --initialize` applies one-table,
one-statement committed groups to MySQL 5.7 MyISAM with exact before-image checks,
bound SQL, native-channel exclusion and `GTID_NEXT=AUTOMATIC`. Raw events go to a
bounded local framed relay; SQLite records baseline, intents, whole-group applied
GTID/position, counts and diagnostics. Initialization refuses existing state;
clean STOPPED state supports explicit resume, while uncertain writes have no
automatic retry or crash recovery. Prepared-table types now include smaller
integers, exact DECIMAL, temporal types, TEXT/BLOB and source-generated defaults
and IDs, within the MySQL 5.7 feature ceiling. DDL retains its separate grammar.
The current unit run passes 197 Swift and 5 Rust tests; this run does not extend
the earlier sanitizer qualification. See [scope and validation](DML_APPLY.md)
for the DML compatibility matrix and integration evidence.

Source reconnect update: the running applier retries transient source-only
transport failures from its durable applied checkpoint, preserving the target
connection and refusing uncertain target outcomes. This supersedes the earlier
deferral of source reconnect; process-crash and target recovery remain separate.
See [source reconnect policy and qualification](SOURCE_RECONNECT.md).

Implemented and validated:

- Independent repository, approved architecture and accepted native-reference contract.
- Rust/Swift C ABI version 5 with bounded offline event/row decoding, owned typed results, CRC/framing/resource checks, poisoned contexts and schema-history validation. `mysql-replicator inspect` emits NDJSON from a local file; capability bit 0 is set. See [offline inspection](OFFLINE_INSPECT.md) for the limited supported subset.
- SwiftPM `replicator-lab` replaces the Python harness. Make coordinates Cargo and SwiftPM; no Python or shell workflow script is required.
- Four-case native suite: positive autocommit and expected error 1837 under both positional and GTID auto-positioning. Exact rows, receiver/applier status, boundaries, GTID coverage, engines, rollback behavior and cleanup are asserted.
- Physical binlog capture plus checksum-verified mysqlbinlog reference decoding and ordered logical operation comparison for the fixed fixture schema. Source/native effects and unchanged future Swift target are checked independently of final rows.
- Swift tests for missing/duplicate/reordered/wrong-value operations, transient insert/delete history, prematurely advanced native completion, malformed reference rows and process timeouts. Three synthetic offline reference fixtures have provenance and checksums.
- Ubuntu 16.04 container userland spike: static x86_64 CLI and dependency probe build/run; verified MySQL TLS plus negative certificate cases, Rust decoding/zstd, NIO DNS/timers and SQLite WAL/FULL SIGKILL recovery/locking/checkpoint/restart pass. Docker uses emulation and its modern kernel. See [packaging results](UBUNTU_PACKAGING_RESULTS.md).
- Reproducible upstream codec qualification: 26 tests pass with binlog explicitly enabled, committed test lockfile and a generated catalog of 41 upstream binlog fixtures.

Remaining Phase 1 gates:

- Broaden the independent corpus beyond the fixed three-column schema, including exact boundary types, multi-row statements, DDL, key changes and live transient-row histories. Add an independent Go reference where planned; the current external decoder is MySQL's mysqlbinlog.
- Implement process-kill, connection-cut, disk-full and rotation/restart controls and appropriate resource profiles. ProcessRunner timeout tests do not satisfy these database failure scenarios.
- Broaden ABI/decoder qualification beyond the current bounded subset: mixed-language sanitizer/fuzz coverage, more malformed metadata, broader control-event semantics (beyond the qualified live pseudo-events), type coverage and imported Go cases. Initial ownership/error/value/CLI tests and Swift-side AddressSanitizer checks now pass; this does not qualify full production decoding.
- Complete Ubuntu 16.04 fleet qualification: the actual Swift/NIO/TLS/SQLite/Rust/zstd stack now builds and passes in x86_64 Ubuntu containers using the Static Linux SDK in Docker. Run the artifacts on the fleet kernel/CPU/filesystem class and qualify CA configuration/rotation, service management and release packaging. The container result is not full production or old-kernel qualification.
- Complete the remaining per-pair workload inventory and publish the Phase 1 exit report. This increment is not Phase 1 completion.

Source settings remain ON/ON; both targets remain OFF_PERMISSIVE/WARN. The positive native MyISAM case now passes with both positioning modes. The native multi-statement error-1837 case is an accepted expected-negative reference, so it is not necessary to make native MySQL succeed before proceeding. The initial DML subset and local BLOCKED/checkpoint journal are now implemented; full apply/storage/recovery qualification remains open.
