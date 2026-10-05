# Install and configure the first beta

The release supplies Linux x86_64 binaries: a Debian `amd64` package and a static
archive. Swift, Rust and SQLite runtimes do not need separate installation.
The packaged executable is tested in an Ubuntu 16.04 container and CI on Ubuntu
24.04; this is not qualification of every Linux distribution, kernel or systemd
version. macOS users can [build from source](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.1/CONTRIBUTING.md).

## Download and verify

Download the `.deb` or `linux-x86_64.tar.gz` and `SHA256SUMS` from the
[versioned release](https://github.com/GannettDigital/mysql-replicator/releases/tag/v0.1.0-beta.1).
Assets appear only after publication. From the download directory:

```sh
sha256sum --ignore-missing --check SHA256SUMS
sudo apt install ./mysql-replicator_0.1.0~beta.1-1_amd64.deb
```

The checksum check must report `OK` for the downloaded package. Checksums verify
file integrity; they are not a detached release signature. The archive contains
the executable, configuration template, this guide, license and third-party notices.
Extract it and run `./mysql-replicator --version`; keep the accompanying notices
when redistributing. Archive users choose their own service account and private
config/state paths; the following paths and account are created by the `.deb`.

## Prepare replication

Only MySQL **8.4 InnoDB → 5.7 MyISAM** is currently accepted. Fixtures use 8.4.8
and 5.7.42. Provision a dedicated target, copy the initial schema/data externally,
and record the matching source GTID set or binlog file/offset. Do not use an
arbitrary current GTID set after an unrelated snapshot.

Follow [source/target preconditions and supported behavior](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.1/PLAN/DML_APPLY.md)
and the comments in [apply.example.yaml](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.1/examples/apply.example.yaml). Configure
ROW/FULL/CRC32 binlogs, the required GTID settings, account privileges, verified TLS,
and disable native replication autostart on the target. No native channel or
other writer may operate on that target. The program checks these preconditions.

```sh
sudo install -o root -g mysql-replicator -m 0640 /etc/mysql-replicator/apply.example.yaml /etc/mysql-replicator/apply.yaml
sudoedit /etc/mysql-replicator/apply.yaml
```

Replace every placeholder. Keep the installed absolute state path
`/var/lib/mysql-replicator/state`; its parent exists, but `state` must not exist
before initialization. Give the service account read access to CA files.
For each connection use either a quoted literal `password` or
`passwordEnvironment`, never both. Literal passwords in this private YAML file
work for both foreground and service runs. With environment passwords, explicitly
provide them to the foreground process; sudo normally removes environment values.
The service can read a root-owned mode-0600 `/etc/mysql-replicator/credentials`
containing `REPLICATOR_SOURCE_PASSWORD=...` and `REPLICATOR_TARGET_PASSWORD=...`
using systemd EnvironmentFile syntax (no `export`). It is not loaded by the CLI.

Strict collation matching is the default. If opting into translation of
`utf8mb4_0900_ai_ci`, configure the same mapping for the snapshot and replication
before initialization. Equality, ordering and unique-key behavior may differ.

## First start and clean resume

For the first start only:

```sh
sudo -u mysql-replicator mysql-replicator run --config /etc/mysql-replicator/apply.yaml --initialize
```

Let it run and check its JSON progress output. Stop with Ctrl-C and wait for the
process to finish cleanly with lifecycle `STOPPED`. To resume in the foreground,
repeat the command **without** `--initialize`. Never delete state to bypass a
startup error: it holds the applied boundary and write intents.

After a clean stop, the installed systemd unit can resume it:

```sh
sudo systemctl enable --now mysql-replicator
sudo journalctl -u mysql-replicator -f
```

Installation does not start or enable replication. The service runs as the
`mysql-replicator` account and does not automatically restart a failed process.
`systemctl stop` sends SIGTERM and waits for a clean drain without a forced timeout.
If a stop stalls, investigate before killing it; SIGKILL may leave uncertain writes.
A machine reboot or process crash is not a clean stop. Safe connection failures
can reconnect within the running process; `BLOCKED` or interrupted state requires
operator investigation. See [target reconnect and drain](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.1/PLAN/TARGET_RECONNECT.md).

## Upgrade from a development checkout

Stop the old writer cleanly and back up its configuration and entire state directory
before installing. Convert JSON configuration to YAML; JSON is no longer accepted.
Existing state/configuration files are never overwritten by the package. The
service now uses a dedicated account, so move any old relative state path to a
known absolute location and explicitly grant that account access to the existing
state and certificates. Do not reinitialize an existing replica. Resume only from
clean `STOPPED` state; consult the state-version rules in the setup guide above.
