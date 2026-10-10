# mysql-replicator

[![CI](https://github.com/GannettDigital/mysql-replicator/actions/workflows/ci.yml/badge.svg)](https://github.com/GannettDigital/mysql-replicator/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Use `mysql-replicator` to replicate data between MySQL versions when native
replication does not meet your needs. It reads source binary logs and applies
supported INSERT, UPDATE, DELETE, and DDL changes to a dedicated replica.

## Supported profiles

The test suite checks these profiles:

| Configuration profile | Source | Target | Foreign keys |
| --- | --- | --- | --- |
| `mysql84-to-mysql57-myisam` | MySQL 8.4 InnoDB | MySQL 5.7 MyISAM | Not supported |
| [`mysql57-to-mysql84-innodb`](docs/REVERSE_REPLICATION.md) | MySQL 5.7 InnoDB | MySQL 8.4 InnoDB | Supported with [limits](PLAN/MYSQL57_FOREIGN_KEYS.md) |
| [`mysql57-to-mysql57-myisam`](docs/MYSQL57_MYISAM.md) | MySQL 5.7 InnoDB | MySQL 5.7 MyISAM | Not supported |

Set `profile` in your YAML configuration to select a profile. Other combinations
are not tested. See [DML support](PLAN/DML_APPLY.md) and
[DDL support](PLAN/DDL_COMPATIBILITY.md) for the supported operations and limits.

Copy the initial data with an external tool. If a write stops or its result is
unknown, a database administrator can need to repair the target before replication
continues.

## Install and start

Download a binary archive or Debian `.deb` package from [Releases](https://github.com/GannettDigital/mysql-replicator/releases).
**Binaries and containers support Linux x86_64 only.**
For other platforms, build from source. You do not need to install Swift, Rust,
Node.js, or SQLite to use the binary. Install `curl`, `jq`, `tar`, and coreutils.
Then run:

```sh
curl -fLo install.sh https://raw.githubusercontent.com/GannettDigital/mysql-replicator/main/packaging/install.sh
sh install.sh
~/.local/bin/mysql-replicator --version
```

Follow the [setup guide](docs/INSTALL.md) to prepare the target and record the
source position for the initial data copy. Configure TLS and credentials in
`apply.yaml`.

Use the short example for [live replication](examples/run.minimal.yaml) or
[offline replay](examples/replay.minimal.yaml). The [full example](examples/apply.example.yaml)
describes the optional settings. To start live replication, run:

```sh
~/.local/bin/mysql-replicator run --config ./apply.yaml --initialize
```

The installer selects the latest published release, including beta releases.
It checks the archive checksum and keeps the configuration and state.
Use `--version VERSION` to select a specific release.

For Debian or Ubuntu, download the `.deb` and `SHA256SUMS` files for the selected
release. Put them in a directory with no other package versions.
Check the checksum. Then install the package:

```sh
sha256sum --ignore-missing --check SHA256SUMS
sudo apt install ./mysql-replicator_*_amd64.deb
```

The package installs `mysql-replicator` on `PATH` and includes a systemd service.
Follow the [Debian installation and service setup guide](docs/INSTALL.md#download-and-verify)
to configure, start, and restart the service. The setup guide also describes containers.
See [offline replay and support bundles](docs/OFFLINE_REPLAY.md) to test captured
binary logs against a prepared target and collect data for troubleshooting.

## Try the demo

Get a copy of the source and install the [developer prerequisites](CONTRIBUTING.md#prerequisites).
Then run:

```sh
make lab-demo PROFILE=mysql84-to-mysql57-myisam ACTION=up
make lab-demo PROFILE=mysql84-to-mysql57-myisam ACTION=start
```

Use the [test lab guide](docs/TEST_LAB.md) to run SQL, compare replicas, or select
another profile. To remove the demo, use the same profile with `ACTION=down`.
Run shared smoke tests with `make correctness TIER=smoke`.
The [forward workbook](PLAN/DEMO_WORKBOOK.md) and
[reverse workbook](PLAN/REVERSE_DEMO_WORKBOOK.md) give more examples with the same commands.

[Build, test and contribute](CONTRIBUTING.md) · [Security](SECURITY.md) ·
[License](LICENSE) · [Third-party notices](NOTICE)

Copyright 2026 USAToday Co., Inc.
