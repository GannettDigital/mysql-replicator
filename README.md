# mysql-replicator

[![CI](https://github.com/GannettDigital/mysql-replicator/actions/workflows/ci.yml/badge.svg)](https://github.com/GannettDigital/mysql-replicator/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Replicate MySQL across versions where native replication does not meet your needs.
`mysql-replicator` reads source binary logs and applies supported INSERT, UPDATE,
DELETE and DDL changes to a dedicated replica.

**First beta: `0.1.0-beta.1`.** The primary tested profile is
**MySQL 8.4 InnoDB → MySQL 5.7 MyISAM**. Current source builds also include an
[experimental 5.7 → 8.4 InnoDB DML profile](docs/REVERSE_REPLICATION.md). Initial
data copying is external; interrupted or uncertain writes can require DBA intervention.
See [supported behavior](PLAN/DML_APPLY.md) and [DDL compatibility](PLAN/DDL_COMPATIBILITY.md).

## Install and start

Linux x86_64 packages are available from [Releases](https://github.com/GannettDigital/mysql-replicator/releases)
when the beta is published. On Debian/Ubuntu:

```sh
curl -fLO https://github.com/GannettDigital/mysql-replicator/releases/download/v0.1.0-beta.1/mysql-replicator_0.1.0~beta.1-1_amd64.deb
sudo apt install ./mysql-replicator_0.1.0~beta.1-1_amd64.deb
```

Follow the [setup guide](docs/INSTALL.md) to prepare the target, snapshot boundary,
TLS and credentials in `/etc/mysql-replicator/apply.yaml`, then start:

```sh
sudo -u mysql-replicator mysql-replicator run --config /etc/mysql-replicator/apply.yaml --initialize
```

The setup guide also covers checksums, standalone archives and service restarts.

## Try the demo

From a source checkout with the [developer prerequisites](CONTRIBUTING.md#prerequisites):

```sh
make demo-up
make demo-start
```

Follow the [interactive demo workbook](PLAN/DEMO_WORKBOOK.md) to issue SQL and
compare replicas, or use the [demo runbook](PLAN/DEMO.md). Clean up with `make demo-down`.

For the experimental reverse flow, see the [5.7 → 8.4 InnoDB workbook](PLAN/REVERSE_DEMO_WORKBOOK.md).

[Build, test and contribute](CONTRIBUTING.md) · [Security](SECURITY.md) ·
[License](LICENSE) · [Third-party notices](NOTICE)

Copyright 2026 USAToday Co., Inc.
