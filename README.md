# mysql-replicator

[![CI](https://github.com/GannettDigital/mysql-replicator/actions/workflows/ci.yml/badge.svg)](https://github.com/GannettDigital/mysql-replicator/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Replicate MySQL across versions where native replication does not meet your needs.
`mysql-replicator` reads source binary logs and applies supported INSERT, UPDATE,
DELETE and DDL changes to a dedicated replica.

The primary tested profile is
**MySQL 8.4 InnoDB → MySQL 5.7 MyISAM**, alongside an
[experimental 5.7 → 8.4 InnoDB profile](docs/REVERSE_REPLICATION.md). Initial
data copying is external; interrupted or uncertain writes can require DBA intervention.
See [supported behavior](PLAN/DML_APPLY.md) and [DDL compatibility](PLAN/DDL_COMPATIBILITY.md).

## Install and start

Download a standalone binary from [Releases](https://github.com/GannettDigital/mysql-replicator/releases).
**Binaries and containers are Linux x86_64 only**;
other platforms require a source build. No Swift, Rust, Node.js or SQLite runtime
installation is needed. With `curl`, `jq`, `tar` and coreutils installed:

```sh
curl -fLo install.sh https://raw.githubusercontent.com/GannettDigital/mysql-replicator/main/packaging/install.sh
sh install.sh
~/.local/bin/mysql-replicator --version
```

Follow the [setup guide](docs/INSTALL.md) to prepare the target, snapshot boundary,
TLS and credentials in your `apply.yaml`, then start:

```sh
~/.local/bin/mysql-replicator run --config ./apply.yaml --initialize
```

The installer selects the newest published release, including betas, verifies its
archive checksum and preserves configuration and state. Use `--version VERSION`
to pin a release. The setup guide also covers `.deb` packages, systemd and containers.
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
