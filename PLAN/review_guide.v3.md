# Reviewer Guide

## Prerequisites

### MySQL Replication

The primary database records changes into a binary log (binlog). Modern MySQL uses Row-Based log format, where data modifications are stored as binary row events (before/after row images) and DDL changes are stored as SQL statements query events.  GTID mode assigns each transaction a unique identifier `UUID:sequence` and trx groups represented as ranges in GTID sets. The server maintains the current binlog file offset (position) and the executed GTID set to track what transactions have been committed on the primary.

Replicas connect to the primary, download binary log files, decode events and apply changes.

ref (5.7): https://dev.mysql.com/doc/refman/5.7/en/replication-implementation.html  
ref (8.4): https://dev.mysql.com/doc/refman/8.4/en/replication-implementation.html

### Notes on Performance & Latency

Current implementation applies source transactions sequentially. MyISAM does not support transactions or rollback and uses table-level write locks (`LOCK TABLES ... WRITE`). Running parallel applier threads against the same MyISAM table would lead to lock contention; independent tables can be written in parallel, but applying changes in order in a single-threaded loop is the current design choice to maintain data consistency.

CDC systems typically capture binlogs and publish events to distributed systems like Kafka, Pub/Sub, BigQuery, or Snowflake. Those systems can ingest events in parallel, so they benefit from distributed workers. 

For database replication, however, performance is heavily dominated by single-thread apply speed, which is bounded by network latency. If the applier is 20ms away from the target database, that network roundtrip adds 20ms to *every single transaction*. On a busy database with hundreds or thousands of transactions per second, network latency can create a growing replication lag.

## Implementation Details

### Target Implementation Profile

Since transactions are applied sequentially and performance is dominated by network roundtrips between the applier and the database, one approach is to emulate native MySQL replication: stream binary logs from the primary and apply them directly on the replica host, running as close as possible to the database engine.

```
[ MySQL 8.4 Primary (Cloud SQL) ]
              │ (TLS / COM_BINLOG_DUMP_GTID)
              ▼
    ┌───────────────────────────────────────────────┐
    │ mysql-replicator (On the replica host)        │
    │                                               │
    │ 1. Capture (SwiftNIO / MySQLNIO)              │
    │ 2. Codec (Rust via C ABI)                     │
    │    └── decode events as objects               │
    │ 3. Transaction Assembler                      │
    │    └── trx groups, schema/table filtering     │
    │ 4. Bounded queue to ordered consumer          │
    │ 5. Raw frame storage (relay.frames)           │
    │ 6. State and Journal Store (SQLite WAL)       │
    │    └── store current trx position and journal │
    │ 7. Applier (same consumer as relay and SQLite) │
    │    └── apply rows individually, batch journal │
    └───────────────────────────────────────────────┘
              │ (Unix Domain Socket / TCP)
              ▼
[ Local MySQL 5.7 Replica (MyISAM) ]
```

### Details

What we want is a native binary that can emulate a MySQL replication thread just outside of the database server. MySQL cannot reolicate from newer to older version, because native replication uses the same server code to encode and decode binlog events,we can use independent binlog decoding and MySQL client code to re-implement pulling and applying binlogs outside of mysqld.

- **Swift for core runtime & daemon:** Swift provides native compiled performance and memory safety (similar to Rust). It gives us clean C interop and leverages **SwiftNIO** and **MySQLNIO** for async networking, TLS handling, and event loop management.
- **Swift as scripting language:** Harness tools and benchmarks in this repo are written in Swift (`ReplicatorLab`), instead of commonly used shell or Python scripts, with Make and Docker build automation.
- **Rust for binlog decoding (`rust/src/`):** We use the well-tested Rust `mysql_common` crate to decode binary log events, row images, and CRC32 checksums. This code is exposed to Swift via a thin, versioned C ABI (`Sources/CReplicatorCodec`). The Rust library contains no networking or application logic.
- **Modified MySQL driver:** Swift uses a patched version of `mysql-nio` to implement binlog dump protocol streaming (`COM_BINLOG_DUMP_GTID`), and cache prepared statements for fast execution.
- **SQLite as an intent journal and state store:** Because our target engine is MyISAM (non-transactional), a crash mid-transaction cannot be rolled back by MySQL. SQLite in WAL mode is used as pre-write journal: row and DDL intents are recorded in SQLite before applying them to MyISAM. If the process or target stops, SQLite preserves intended writes and recorded acknowledgments for recovery and audit. Pending writes may already have succeeded and require manual reconciliation; (automatic crash recovery is not implemented, similar to MySQL).

### Target Deployment & Operational Profile

Ideally, we deploy directly on the replica server to run right next to the database, communicating over Unix domain sockets (`socketPath`) or localhost TCP to eliminate network latency. 

build produces a statically linked x86_64 Linux binary using the musl C library and the Swift Static Linux SDK. The binary has no external shared library dependencies or dynamic loader; it is tested in Ubuntu 16.04 containers. 
See the [packaging instructions](../packaging/README.md).  There is a support to generate a `.deb` package (`make deb`) with a standard `systemd` service (`mysql-replicator.service`) for deployment.

Current code supports a subset of DML, see the [supported-behavior guide](DML_APPLY.md) however it is enough to run sysbench tool w/our errors.

Operationally, the replicator behaves similarly to native MySQL replication:
- Can be started, stopped, and resumed from "stopped" state.
- Supports skipping GTIDs in blocked state when ther are no penidng writes (`mysql-replicator skip '<gtid>' ...`).
- Supports wildcard table filtering (`replicateWildIgnoreTable`) similar to MySQL using the match patterns.
- Stores replication progress, checkpoints, and diagnostics in SQLite. 
- `mysql-replicator inspect` inspects binlog files or logs avilable on the primary, similar to mysqlbinlog


## Codebase Navigation

| Directory / Module | Description |
|---|---|
| `Sources/ReplicatorCLI/main.swift` | CLI entry point (`run`, `inspect`, `skip`, `--version`). |
| `Sources/ReplicatorCapture/` | Streaming capture loop, TLS , dump binlogs protocol. |
| `Sources/ReplicatorCodec/` | Transaction boundary assembly (`TransactionAssembler`), timings  and Swift wrappers over the C ABI. |
| `Sources/CReplicatorCodec/` | C header definitions exposing the Rust decoder to Swift. |
| `rust/src/` | Rust adapter around `mysql_common` implementing the C ABI. |
| `Sources/ReplicatorApply/` | Target apply loop, SQLite `StateStore`, `DMLBatch` journal batching, `TableLockEpoch`, and `TargetSession`. |
| `Sources/ReplicatorLabCore/` | Unified test harness, 3-server Docker qualification suites, sysbench benchmarks, and demo session runner. |
| `Vendor/mysql-nio/` | Patched MySQL client (TLS pre-auth enforcement, prepared statement cache). |
| `packaging/` | Debian package, systemd service unit, and Docker packaging scripts. |


## Testing & Verification

Besides standard unit tests (`make test`), the primary validation is an end-to-end differential test harness running in Docker Compose:

- **Source:** MySQL 8.4 InnoDB (simulating the Cloud SQL primary).
- **Native Reference:** MySQL 8.4 MyISAM (replica fed by native MySQL replication).
- **MySQL 5.7 Target:** MySQL 5.7 MyISAM (replica fed by `mysql-replicator`).
- **Ubuntu 16.04 Container:** Runs the static `mysql-replicator` binary.

The test harness runs SQL workloads against the source database, and then verifies that:
1. Table rows match between the Native reference and the MySQL 5.7 target.
2. Table schemas match across both replicas.
3. Selected tests compare normalized logical binlog between the source and replicas using `mysqlbinlog`.

This 3-way comparison checks whether `mysql-replicator` makes changes that are the same changes made by the native MySQL replication;

### Interactive Demo Walkthrough

You can test and observe this behavior locally using the demo commands:

```sh
export PROFILE=mysql84-to-mysql57-myisam
make lab-demo ACTION=up       # Launches the 3-server Docker stack and prints MySQL connection commands
make lab-demo ACTION=start    # Starts mysql-replicator in the separate applier container
make lab-demo ACTION=sql ARGS=examples/demo/01-success.sql   # Executes sample DML/DDL against the primary
make lab-demo ACTION=compare  # Compares rows and schemas across all instances
make lab-demo ACTION=status   # Inspects current replication position and applied GTID progress
make lab-demo ACTION=down     # Archives evidence and cleans up containers
```
additonal manual commands [demo workbook](DEMO_WORKBOOK.md) 

## AI-Assisted Engineering & Maintainability

Writing this much low-level replication and harness code from scratch would take a lot of time, so I used AI tooling (Codex) to speed up implementation:
- Generating the Swift/Rust C ABI shims
- Porting test scenarios from the official MySQL server test suite (`mysql-test`).
- Building the automated 3-server test harness and verification suites.

I think this code is safe and maintainable due to the test harness and 3-way verification approach. 
Any future fixes or feature additions can be verified against the test matrix (`make integration-smoke`, `make correctness`, `make lab-test`, and `make lab-benchmark PROFILE=PROFILE`).
