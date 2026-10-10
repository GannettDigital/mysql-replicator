# Install and configure mysql-replicator

The release supplies Linux x86_64 binaries: a Debian `amd64` package and a static
archive, plus a container image. Swift, Rust and SQLite runtimes do not need separate installation.
The packaged executable is tested in an Ubuntu 16.04 container and CI on Ubuntu
24.04; this is not qualification of every Linux distribution, kernel or systemd
version. macOS and Linux ARM64 binaries are not supplied; those users can
[build from source](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.3/CONTRIBUTING.md).

## Standalone installer

Install the newest published release, including betas:

```sh
curl -fLo install.sh https://raw.githubusercontent.com/GannettDigital/mysql-replicator/main/packaging/install.sh
sh install.sh
~/.local/bin/mysql-replicator --version
```

The installer requires Linux x86_64, `curl`, `tar` and coreutils (`sha256sum`).
Automatic selection also requires `jq`: it chooses the most recently published
release by publication time, including prereleases and excluding drafts. It fails
if no release is published. For a pinned install, use
`sh install.sh --version 0.1.0-beta.3`; this does not require `jq` or release discovery.
The versionless installer URL follows `main`; a reviewed installer can also be
downloaded from a specific release's assets.

It downloads the selected version's archive and checks it against that release's
`SHA256SUMS`. It installs the complete distribution, including examples and
notices, into `~/.local/lib/mysql-replicator/<version>/` and links the command
from `~/.local/bin/`. Add that directory to `PATH`, or use the full path.
Use `--prefix /absolute/path` to choose another prefix; no sudo is needed when
the prefix is writable. It refuses unsupported platforms and unmanaged binaries.

Copy the example from the installed distribution to a private location and edit
it for your source, target and snapshot boundary. The installer does not configure
or start replication. It neither reads nor changes existing configuration/state.
After completing the replication preconditions below, start it with
`~/.local/bin/mysql-replicator run --config /absolute/path/apply.yaml --initialize`.
Use a second terminal to run `~/.local/bin/mysql-replicator ctl stop --config
/absolute/path/apply.yaml` for a planned shutdown. The Debian account and systemd
commands below apply only to `.deb` installations.
For upgrades, cleanly stop the old process first, back up the full state directory,
and install the new explicit version. Old version directories are retained, but
an existing version is never overwritten. Resume without `--initialize`.

## Download and verify

Download the `.deb` or `linux-x86_64.tar.gz` and `SHA256SUMS` from the
[versioned release](https://github.com/GannettDigital/mysql-replicator/releases/tag/v0.1.0-beta.3).
Assets appear only after publication. From the download directory:

```sh
sha256sum --ignore-missing --check SHA256SUMS
sudo apt install ./mysql-replicator_0.1.0~beta.3-1_amd64.deb
```

The checksum check must report `OK` for the downloaded package. Checksums verify
file integrity; they are not a detached release signature. The archive contains
the executable, configuration template, this guide, license and third-party notices.
Extract it and run `./mysql-replicator --version`; keep the accompanying notices
when redistributing. Archive users choose their own service account and private
config/state paths; the following paths and account are created by the `.deb`.

## Prepare replication

For a short starting configuration, use [run.minimal.yaml](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.3/examples/run.minimal.yaml)
for live replication or [replay.minimal.yaml](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.3/examples/replay.minimal.yaml) for
offline replay. The [full example](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.3/examples/apply.example.yaml) documents all options. The standalone archive includes all three templates beside
the binary; Debian puts the minimal templates in
`/usr/share/doc/mysql-replicator/examples/` and the full template in
`/etc/mysql-replicator/apply.example.yaml`.

The default profile is **8.4 InnoDB → 5.7 MyISAM**. The release also includes the
experimental [5.7 → 8.4 InnoDB profile](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.3/docs/REVERSE_REPLICATION.md), selected with
`profile: mysql57-to-mysql84-innodb`. Both have shared correctness and reconnect
tests using 8.4.8 and 5.7.42; this is not Cloud SQL qualification. Provision a dedicated target, copy the initial schema/data externally,
and record the matching source GTID set or binlog file/offset. Do not use an
arbitrary current GTID set after an unrelated snapshot.

Source builds also offer [5.7 InnoDB → 5.7 MyISAM](MYSQL57_MYISAM.md), selected
with `profile: mysql57-to-mysql57-myisam`. This profile is not in beta.3 binaries.

Follow [source/target preconditions and supported behavior](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.3/PLAN/DML_APPLY.md)
and the comments in [apply.example.yaml](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.3/examples/apply.example.yaml). Configure
ROW/FULL/CRC32 binlogs, the required GTID settings, account privileges, connection security,
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

## Connection security

Source and target TCP connections use verified TLS by default.
To connect without TLS, set `requireTLS: false` in the applicable section:

```yaml
source:
  # Keep the other source settings.
  requireTLS: false
target:
  # Keep the other target settings.
  requireTLS: false
```

Remove `serverHostname` and `caFile` from each section where you disable TLS.
Also remove `target.tlsVerification` if you disable target TLS.
You can disable TLS for one connection and keep it for the other.
The account and server must permit connections without TLS.
Replication data on these connections is not encrypted.

For a local TCP target, use `host: 127.0.0.1` and its port.
For a local Unix socket, replace target `host` and `port` with
`unixSocket: /var/run/mysqld/mysqld.sock`. Set `requireTLS: false` to use the
socket without TLS. The source uses TCP.

These settings apply to live replication, source archive downloads, and target
replay connections. Replay never connects to the source.
Stop and restart the process to change connection settings. `ctl reload` cannot
change them. A connection that requires TLS cannot fall back to an unencrypted connection.

## First start and clean resume

For the first start only:

```sh
sudo -u mysql-replicator mysql-replicator run --config /etc/mysql-replicator/apply.yaml --initialize
```

Let it run and check its JSON progress output. From another terminal, run
`sudo -u mysql-replicator mysql-replicator ctl stop --config /etc/mysql-replicator/apply.yaml`
and wait for lifecycle `STOPPED`. To resume in the foreground,
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
`systemctl reload mysql-replicator` uses the acknowledged local control command
to reload only `source.stopAfterTransactions` and `source.stopAfterGTIDs`.
For status, run `sudo -u mysql-replicator mysql-replicator ctl status --config
/etc/mysql-replicator/apply.yaml`. See [process controls](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.3/docs/OFFLINE_REPLAY.md#controlling-a-running-process)
for reload restrictions, timeouts, and direct `ctl stop` usage.
If a stop stalls, investigate before killing it; SIGKILL may leave uncertain writes.
A machine reboot or process crash is not a clean stop. Safe connection failures
can reconnect within the running process; `BLOCKED` or interrupted state requires
operator investigation. See [target reconnect and drain](https://github.com/GannettDigital/mysql-replicator/blob/v0.1.0-beta.3/PLAN/TARGET_RECONNECT.md).

## Container

The Linux/amd64 image uses the exact release-archive binary, runs as UID/GID 65532
by default, and includes licenses and examples under `/opt/mysql-replicator`.
It has no shell or package manager. The image is published to GHCR after the
GitHub prerelease is published. No registry login is required once the package
is public. Pin a version (or its registry digest); no `latest` tag is published.

Prepare `config/apply.yaml` and CA files in a private local `config/` directory.
Set `stateDirectory: /data/state` and use container paths such as `/config/ca.pem`.
For archive/replay/bundle settings, also choose mounted paths. Create an empty
private `replica-data/` directory owned by your user. This example runs with your
UID so that bind-mounted credentials and persistent state keep their host ownership:

```sh
docker run --name mysql-replicator --platform linux/amd64 \
  --user "$(id -u):$(id -g)" --read-only --tmpfs /tmp:rw,nosuid,noexec,size=64m \
  --mount "type=bind,src=$(pwd)/config,dst=/config,readonly" \
  --mount "type=bind,src=$(pwd)/replica-data,dst=/data" \
  ghcr.io/gannettdigital/mysql-replicator:0.1.0-beta.3 \
  run --config /config/apply.yaml --initialize
```

`--initialize` is only for the first run. After a clean stop, remove the stopped
container and create it again with the same mounts and **without** that flag.
Do not restart a container whose command still contains `--initialize`.
For Docker-managed named volumes, use the default UID and mount the volume at
`/var/lib/mysql-replicator`, with `stateDirectory: /var/lib/mysql-replicator/state`.
The image provides a writable parent there, without preinitializing state.
Ensure the default UID can read your config and CA mounts.

Control the running process without a shell inside the image:

```sh
docker exec mysql-replicator /opt/mysql-replicator/mysql-replicator ctl status --config /config/apply.yaml
docker exec mysql-replicator /opt/mysql-replicator/mysql-replicator ctl stop --config /config/apply.yaml --timeout 300
```

`ctl stop` drains and waits for durable `STOPPED` state. A client timeout does not
force-kill the process. Docker's ordinary stop has a finite grace period; use the
control command for planned shutdown or `docker stop --timeout -1 mysql-replicator`
to wait indefinitely after SIGTERM. Investigate a stalled drain before forcing it.
Keep state on persistent storage and leave automatic container restart disabled.

For offline container installation, download the release's
`mysql-replicator-0.1.0-beta.3-linux-x86_64-image.tar.gz` and `SHA256SUMS`, verify the
checksum, then `docker load --input mysql-replicator-0.1.0-beta.3-linux-x86_64-image.tar.gz`.
The loaded image is named `mysql-replicator-release:0.1.0-beta.3`; substitute that
name in the command above. To build your own image, the ordinary binary archive
can also be extracted and copied into a Linux x86_64 container; preserve its notices.

## Optional bounded shutdown

The default `TimeoutStopSec=infinity` favors completing an in-flight apply over
forcing the process to exit. A hung process can therefore delay service restart
or host shutdown indefinitely. For deployments that require a bounded stop, use
`sudo systemctl edit mysql-replicator` to add a local override, for example:

```ini
[Service]
TimeoutStopSec=30min
```

Then run `sudo systemctl daemon-reload`. Choose the limit for your workload:
`ddlTimeoutSeconds` alone can be configured up to 24 hours, and draining
may include several operations. Thirty minutes is an example, not a universal
safe bound. For planned maintenance, drain and verify `STOPPED` before rebooting.

Once a finite stop timeout expires, systemd can send SIGKILL. This bounds the wait
for a normally killable process; it does not guarantee a clean replication stop
or recover a process stuck in uninterruptible kernel I/O. Keep `Restart=no`.
After a forced termination, preserve SQLite, relay files and target data. Startup
refuses interrupted state even when the last applied checkpoint looks complete;
pending write intents must not be replayed or marked done based on a timeout.
Have a DBA inspect and reconcile affected target tables against the source before
explicit recovery. Do not delete state, change its lifecycle to `STOPPED`, or run
`--initialize` to bypass the refusal.

## Upgrade from beta.1 or a development checkout

Stop the old writer cleanly and back up its configuration and entire state directory
before installing. Convert JSON configuration to YAML; JSON is no longer accepted.
Existing state/configuration files are never overwritten by the package. The
service now uses a dedicated account, so move any old relative state path to a
known absolute location and explicitly grant that account access to the existing
state and certificates. Do not reinitialize an existing replica. Resume only from
clean `STOPPED` state; consult the state-version rules in the setup guide above.
Beta.2 records the replication profile in SQLite schema version 9. Supported
older forward-profile state is migrated on resume; beta.1 cannot read the upgraded
state. A version rollback therefore needs a coordinated state/target recovery,
not just switching the binary or restoring an old checkpoint after target writes.
Changing profiles requires a separately prepared baseline and new state directory.
