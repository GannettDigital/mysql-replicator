# mysql-replicator

[![CI](https://github.com/GannettDigital/mysql-replicator/actions/workflows/ci.yml/badge.svg)](https://github.com/GannettDigital/mysql-replicator/actions/workflows/ci.yml)
[Coverage reports](https://github.com/GannettDigital/mysql-replicator/actions/workflows/ci.yml?query=branch%3Amain+event%3Apush)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Replicate MySQL across versions where native replication does not meet your needs.
`mysql-replicator` reads source binary logs and applies supported INSERT, UPDATE,
DELETE and DDL changes to a dedicated replica.

**Next release: `0.1.0-beta.2`.** The primary tested profile is
**MySQL 8.4 InnoDB → MySQL 5.7 MyISAM**. This beta also includes an
[experimental 5.7 → 8.4 InnoDB profile](docs/REVERSE_REPLICATION.md). Initial
data copying is external; interrupted or uncertain writes can require DBA intervention.
See [supported behavior](PLAN/DML_APPLY.md) and [DDL compatibility](PLAN/DDL_COMPATIBILITY.md).

## Install and start

Download a standalone binary from [Releases](https://github.com/GannettDigital/mysql-replicator/releases)
when beta.2 is published. **Binaries and containers are Linux x86_64 only**;
other platforms require a source build. No Swift, Rust, Node.js or SQLite runtime
installation is needed:

```sh
curl -fLO https://github.com/GannettDigital/mysql-replicator/releases/download/v0.1.0-beta.2/install.sh
sh install.sh --version 0.1.0-beta.2
~/.local/bin/mysql-replicator --version
```

Follow the [setup guide](docs/INSTALL.md) to prepare the target, snapshot boundary,
TLS and credentials in your `apply.yaml`, then start:

```sh
~/.local/bin/mysql-replicator run --config ./apply.yaml --initialize
```

The installer verifies the archive checksum and preserves configuration and state.
The setup guide also covers `.deb` packages, systemd and containers:
`ghcr.io/gannettdigital/mysql-replicator:0.1.0-beta.2` (available after publication).
See [offline replay and support bundles](docs/OFFLINE_REPLAY.md) to test captured
binlogs against a prepared target and collect troubleshooting evidence.

## Try the demo

From a source checkout with the [developer prerequisites](CONTRIBUTING.md#prerequisites):

```sh
make lab-demo PROFILE=mysql84-to-mysql57-myisam ACTION=up
make lab-demo PROFILE=mysql84-to-mysql57-myisam ACTION=start
```

Use the [test lab guide](docs/TEST_LAB.md) to issue SQL, compare replicas, or select
`mysql57-to-mysql84-innodb`. Clean up with the same profile and `ACTION=down`.
Run shared smoke tests with `make correctness TIER=smoke`.
The [forward workbook](PLAN/DEMO_WORKBOOK.md) and
[reverse workbook](PLAN/REVERSE_DEMO_WORKBOOK.md) use the same profile-based commands for detailed experiments.

[Build, test and contribute](CONTRIBUTING.md) · [Security](SECURITY.md) ·
[License](LICENSE) · [Third-party notices](NOTICE)

Copyright 2026 USAToday Co., Inc.
