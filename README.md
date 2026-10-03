# mysql-replicator

[![CI](https://github.com/GannettDigital/mysql-replicator/actions/workflows/ci.yml/badge.svg)](https://github.com/GannettDigital/mysql-replicator/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

`mysql-replicator` reads MySQL binary logs and applies changes to another MySQL
server. It is built for replication across versions or dialects where native
MySQL replication cannot meet the compatibility requirements. The current focus
is MySQL 8.4 InnoDB to MySQL 5.7 MyISAM, including Cloud SQL to on-premises targets.

The implementation uses Swift for capture and application, Rust for binlog
decoding, and local relay files plus SQLite for replication state. It supports
INSERT/UPDATE/DELETE and a limited set of DDL, with tests against a native MySQL
replica. This is an experimental project: supported schemas are limited,
performance is not yet qualified, and automatic crash recovery is not implemented.

## Build

Use Swift 6.2.1, Rust/Cargo 1.93.1, Make, and Git. Native builds also need SQLite
headers and libraries (`libsqlite3-dev` on Ubuntu; supplied by the macOS SDK).

```sh
git clone https://github.com/GannettDigital/mysql-replicator.git
cd mysql-replicator
make build
.build/debug/mysql-replicator --help
```

To build an x86_64 Debian package through Docker:

```sh
make deb
```

The package and checksum are written to `artifacts/deb/`. See
[packaging instructions](packaging/README.md) for options and verification scope.

## Test

Run the Rust and Swift unit tests without Docker:

```sh
make test
```

Run a small integration sample with Docker Compose, Linux/amd64 support, OpenSSL,
the SQLite CLI, and a MySQL 8.4 `mysqlbinlog` in `PATH`:

```sh
make integration-smoke
# If mysqlbinlog is installed elsewhere:
# MYSQLBINLOG=/path/to/mysqlbinlog make integration-smoke
```

The sample checks INSERT/UPDATE/DELETE, a column change, and index creation using
GTID positioning. It compares the source, native replica, and replicator target
in disposable containers, then removes the stack and keeps evidence under
`artifacts/ddl-suite/`. CI runs this same sample alongside unit tests and Debian
package verification. The first Docker build downloads toolchains and dependencies
and can take several minutes.

For broader coverage, run `make dml-suite` and `make ddl-suite`. See
[incremental checks](PLAN/INCREMENTAL_CHECKS.md) for selecting individual cases.

To compare native and custom replication under source write load, run
`make benchmark`; use `make benchmark-capture` to isolate download and decoding
with a blackhole sink. See the [performance harness](PLAN/PERFORMANCE_BENCHMARK.md)
for sysbench workloads, progress measurements, and interpretation limits.

## Try the interactive demo

The demo needs Swift, Docker Compose with Linux/amd64 support, and OpenSSL.
It prepares a MySQL 8.4 source, a native reference replica, and a MySQL 5.7 target,
including fixture data, certificates, and a ready-to-run replicator configuration.
No host MySQL client or SQLite CLI is required.

```sh
make demo-up                                  # Prepare the containers
make demo-start                               # Start replication
make demo-sql FILE=examples/demo/01-success.sql
make demo-compare                             # Compare schema and rows
make demo-status                              # Inspect replication progress
```

`demo-up` prints commands for opening MySQL shells. Try the sample SQL one
statement at a time instead of running the SQL file, or follow the
[four-terminal walkthrough](PLAN/DEMO_WORKBOOK.md) to run the replicator in the
foreground and watch each server. The [demo runbook](PLAN/DEMO.md) also covers
clean-stop resume and a controlled failure with `make demo-fail`.

When finished, archive the evidence and remove the demo containers and volumes:

```sh
make demo-down
```

## Use your own databases

Start with an externally prepared target and a known source position or GTID set.
Copy [the commented YAML example](examples/apply.example.yaml) to `apply.yaml`,
edit it, then follow the [setup and supported-behavior guide](PLAN/DML_APPLY.md).
Configuration files use `.yaml` or `.yml`; each connection accepts either
`password: 'literal password'` or `passwordEnvironment: VARIABLE_NAME`.
Initial data copying and target provisioning are outside this project's scope.
The CLI also supports
[offline binlog inspection](PLAN/OFFLINE_INSPECT.md) and
[live source inspection](PLAN/LIVE_INSPECTION.md).

See [DDL compatibility](PLAN/DDL_COMPATIBILITY.md) for supported schema changes,
generated columns, partitions, views and routines, and the trigger-skip/event-rejection policy.

Treat the target as a dedicated replica: application writes and schema changes
must come through replication, with local administrative changes made while stopped.

## Project information

- [Contributing and development checks](CONTRIBUTING.md)
- [Security reporting](SECURITY.md)
- [Apache 2.0 license](LICENSE) and [third-party notices](NOTICE)
- [Implementation status](PLAN/IMPLEMENTATION_STATUS.md) and [DDL coverage](tests/DDLCoverage/README.md)

Copyright 2026 USAToday Co., Inc.
