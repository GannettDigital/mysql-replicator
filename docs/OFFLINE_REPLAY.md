# Offline binlogs and support bundles

`fetch` downloads a finite archive from a source. `replay` applies local raw
binlogs through the same decoder, DDL policies, target execution, and SQLite
journal as `run`. Replay never connects to the source. `support-bundle` collects
local evidence into one uncompressed tar file without contacting either database.

Database cloning, restoration, and upgrades happen outside these commands. Supply
the complete source GTID set corresponding to the target's existing data in
`source.start.executedGTIDs`. Replay does not establish or verify that snapshot.

Use the normal [apply configuration](../examples/apply.example.yaml), selecting
the appropriate `profile`, and add:

```yaml
archive:
  directory: /var/lib/mysql-replicator/binlogs
  # Optional: fetch from this file through the tip observed when fetch starts.
  # If absent, fetch uses source.start.file, or the oldest available file.
  # firstFile: binlog.000003
  maximumBytes: 68719476736 # 64 GiB; increase for larger archives

supportBundle:
  output: /var/lib/mysql-replicator/support.tar
  maximumBytes: 2147483648 # 2 GiB, including tar overhead
  # Optional existing log files, copied without workload-data redaction:
  # logs:
  #   - /var/log/mysql-replicator/applier.ndjson
```

All paths use the process's filesystem namespace; mount them into the container
when running in Docker. Relative paths resolve against the working directory.
Use the same YAML path for all three commands:

```sh
mysql-replicator fetch --config apply.yaml
mysql-replicator replay --config apply.yaml --initialize
mysql-replicator support-bundle --config apply.yaml
```

`fetch` requires source credentials and replication privileges, including
`REPLICATION CLIENT` for `SHOW BINARY LOGS`. It does not require target settings.
Its destination directory must not exist. It downloads whole files, including the
first file's format context, even when replay will start later within that file.
Files and their captured sizes are fixed at the beginning; new rotations and
later writes are not followed. A successful archive contains `manifest.json`
with source observations, file order, sizes, and SHA-256 hashes. Failure leaves
an incomplete directory for diagnosis; fetch does not overwrite or resume it.
Use a new destination to retry. Structural validation preserves unsupported row
formats for diagnosis; semantic compatibility is checked during replay.

## External archives

A directory containing files downloaded with **`mysqlbinlog --raw`** is a valid
replay input. No fetch run or manifest is required. SQL/text output from
`mysqlbinlog` is not a raw binlog archive.

By default, every directory entry is treated as a binlog, in filename order. Keep
other files out of the directory, or select an explicit ordered list in YAML:

```yaml
archive:
  directory: /data/external-binlogs
  files:
    - binlog.000003
    - binlog.000004
  # Required for external archives only when table filtering is enabled:
  # lowerCaseTableNames: 0
```

Raw files provide format versions and GTID history, but not all source identity
and settings. For external archives, source identity and the qualified source
contract come from the operator's configuration; these are not claimed as live
source observations. Files are hashed when opened and checked before replay.
No metadata is written into the external directory.

Replay currently requires `source.mode: gtid` on both profiles. Source endpoint
fields retain the normal apply YAML shape, but are not used to connect. Source
`password` and `passwordEnvironment` may be omitted for replay; only the target
password is resolved. Replay excludes already-covered GTIDs locally, including
sets with holes, without decoding historical row values against newer schemas.
SQLite's saved source progress takes precedence on resume. Target-local GTIDs do
not replace this checkpoint.

Target TCP connections still require TLS. The default
`target.tlsVerification: verify-identity` verifies the CA chain and requires
`serverHostname` to match the server certificate. For a target with an
instance-specific CA but no certificate DNS name (such as some Cloud SQL
instances), set these fields in your existing `target` section:

```yaml
target:
  # Keep host, port, credentials and nativeAutoStartDisabled from your config.
  tlsVerification: verify-ca
  caFile: /data/server-ca.pem
  # serverHostname can be omitted.
```

`verify-ca` requires an explicit, nonempty `caFile`; it still validates the
certificate chain and validity period. It skips hostname matching. Trust the
intended instance's CA: a shared CA alone does not distinguish its instances.
If supplied, `serverHostname` is used for TLS SNI, not identity matching in this
mode. This target setting applies to both `run` and `replay`; source TLS settings
are unchanged. Changing TLS settings requires stopping and restarting the
applier, rather than `ctl reload`.

The reader validates file ordering, rotation, framing, CRCs, complete transaction
boundaries, and whether the baseline covers history before the first available
file. Missing required history, corruption, and a partial last transaction fail.
The supplied files define the ending boundary; reaching their end does not mean
the live source is caught up. Keep archive files immutable while replay runs.

## Stop, resume, and failures

`--initialize` creates a new state directory for an externally prepared target.
Omit it to resume cleanly stopped state:

```sh
mysql-replicator replay --config apply.yaml
```

`source.stopAfterTransactions` optionally bounds one replay invocation. Remove or
adjust it for the next invocation. `source.stopAfterGTIDs` stops inclusively once
the saved source checkpoint covers the entire requested GTID set:

```yaml
source:
  # Keep the other source fields from your apply configuration.
  start:
    executedGTIDs: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:1-25000'
  stopAfterGTIDs: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:1-40000'
```

Use the complete executed set associated with the externally prepared target,
not only its last GTID. Ranges, holes, and multiple source UUIDs are supported.
Replay follows binlog order, including intervening transactions outside the stop
set. Batches end at the satisfying transaction; completion is reported after
target acknowledgment and the SQLite checkpoint, before applying any later group.
An already-covered stop set applies nothing (`stopReason: alreadySatisfied`);
this does not rewind a target that has already passed the requested boundary.

If both limits are set, the first satisfied condition stops the run. The final
summary reports `gtidsSatisfied` or `transactionLimit` (GTIDs take precedence if
both are reached together). Offline validation rejects a stop set unavailable in
the baseline plus archive before target application. EOF with no configured
condition satisfied is an error; reaching EOF with no limits is `endOfInput`.

Use `ctl stop` for an acknowledged clean drain. The existing fail-stop rules still apply: blocked
or uncertain writes require explicit operator resolution, not an automatic
retry. Skips and recovery remain subject to their existing profile restrictions.

Offline replay does not expand supported schemas or DDL. In particular, target
trigger and foreign-key checks remain active. Successful replay establishes that
the supplied workload applied without errors; data-equivalence claims require a
separate comparison against a reference at the same boundary.

## Controlling a running process

Both `run` and `replay` expose the same local controls:

```sh
mysql-replicator ctl status --config apply.yaml
mysql-replicator ctl reload --config apply.yaml
mysql-replicator ctl stop --config apply.yaml --timeout 300
```

Responses are JSON. `status` includes the process PID, instance ID, latest
published lifecycle/checkpoint, active batch count, effective limits, and
configuration generation. `stop` stops admission, finishes issued work, journals
acknowledged results, discards unissued preparation, and exits `STOPPED` with
`stopReason: drainRequested`. The command waits for the final checkpoint; errors
and timeouts return nonzero. A timeout never force-kills the applier or cancels
an accepted request. The default acknowledgment timeout is 60 seconds; use
`--timeout` (1..86400 seconds) for longer operations. `SIGTERM` and `SIGUSR1`
request the same drain; `SIGINT` remains cancellation and may leave blocked state.

Edit the YAML and call `reload` to change **only** `source.stopAfterTransactions`
and `source.stopAfterGTIDs`. Remove a limit to disable it. The running process
reads its original configuration path, validates the candidate, finishes issued
work, and resumes from SQLite with the accepted limits. The count remains relative
to the invocation's original start, including work before reload and reconnect.
It does not reset on reload. A limit already satisfied after issued work is
rejected because an exact earlier stop cannot be promised. Offline reload also
checks that the archive contains the requested GTIDs.

Rejected reloads preserve the previous settings and configuration generation.
They may still have drained issued work to establish a safe boundary. All other
configuration changes require stop/edit/restart. In particular, reload cannot
reseed `source.start.executedGTIDs`, change identities or compatibility mappings,
or reset SQLite. Restart retains the existing checkpoint and identity checks.
After a process exits at its limit, extend/remove the limit and resume normally;
`ctl` does not start a stopped process.

The endpoint is `stateDirectory/control.sock`, mode 0600, owned by the applier's
OS user. Its full path must fit within 103 UTF-8 bytes. The existing writer lock
protects endpoint creation and stale-socket cleanup; PID files are not used for
signaling. Run `ctl` as the same user (or root), on the same host/container or with
the same state-volume mount. No TCP port is opened. The client needs only readable
YAML containing `stateDirectory`, so a separate minimal YAML can reach a process
whose main configuration currently has invalid settings. `reload` still reads
the process's original path. Neither control clients nor reload resolve database
password environment variables.

## Support evidence

Stop the applier before `support-bundle`; collection refuses an active state
writer. It also works with blocked or abandoned state, and does not perform
recovery. The output path must be new and outside the state directory.

The bundle includes a standalone SQLite backup, relay evidence, configuration
with credential fields excluded, and build/state diagnostics. If `archive` is
configured, it includes raw binlogs within the byte budget, prioritizing pending
and last-applied files. Optional log files are included when they fit.
`bundle.json` lists file hashes and omitted evidence. Relay bytes beyond the
journal's durable boundary are labeled as an unjournaled tail, not applied work.

**Bundles contain customer data**, including SQL, schema defaults, row values,
and identifiers. Workload data is deliberately not anonymized. Connection
password/private-key/secret fields are excluded from configuration evidence;
referenced environment values and TLS private-key files are not collected.
Explicitly supplied logs are not scrubbed. The file is created with mode 0600 and
is never uploaded automatically. SQLite backup includes committed WAL contents;
the original state and relay are not changed or pruned.

Extract with a standard tar reader. A bundle is evidence, not a ready-to-run
restored replica: reproducing some target errors still requires the relevant
initial schema/data and environment.

## Qualification

```sh
make correctness ARGS="--case offline-replay"
make correctness ARGS="--case runtime-control"
```

This shared scenario exercises both profiles, DDL/DML across rotation, fetch,
partial replay and resume, external raw input with unreachable source settings
and no source password, comparison with source/native rows and schemas, and
support-bundle extraction. The 5.7 fixture uses its native `mysqlbinlog --raw`;
the minimal 8.4 image lacks that utility, so its independent external archive is
copied directly from source binlog files. Unit tests cover GTID holes, corrupt
and incomplete files, manifest mismatches, writer exclusion, standalone SQLite
extraction, credential exclusion, and evidence size limits.

`runtime-control` adds exact stops inside a normal batch, already-covered limits,
resume, offline reload during blocked target execution, live idle reload,
rejection of checkpoint changes/past limits, and acknowledged stop during an
active target batch. It compares final rows and schemas against source/native on
both profiles. Unit tests also cover control socket cleanup and GTID-set holes.
