# Replication status and statistics

## Command and configuration errors

Successful commands, help, and version requests exit with status `0`. Failures
exit with status `1`. Error diagnostics are JSON records on stderr.

- `argument_error`: an unknown command, missing or invalid argument, duplicate
  option, or invalid placement of a configuration override. Use the command's
  `--help`. The typo `reply` gives a suggestion to use `replay`.
- `configuration_error`: the configuration file cannot be read, or its YAML
  syntax or decoded value type is invalid. `configPath` identifies the file.
  `keyPath` identifies the setting when available. YAML syntax errors include
  `line` and `column` when the parser supplies them. Both start at `1`.

These errors occur before replication starts. They do not include binlog offsets.
Configuration diagnostics omit input values and YAML excerpts. A location inside
a command-line override is not reported as a location in the configuration file.
Connection errors, server compatibility checks, and runtime errors retain their
existing categories, such as `apply_failed` and `binlog_decode_failed`.

Scripts that previously treated an argument error as `apply_failed`,
`skip_failed`, `inspect_failed`, or `binlog_decode_failed` must use the new
categories. Exit status remains unchanged.

## Read running status

Run `mysql-replicator ctl status --config apply.yaml` to read a running process.
Control replies (`status`, `stop`, and `reload`) use indented JSON with sorted
keys on stdout. Diagnostics use stderr. You can pipe the reply to `jq`:

```sh
mysql-replicator ctl status --config apply.yaml | jq '.progress'
mysql-replicator ctl stop --config apply.yaml | jq '.'
```

The `progress` object includes the lifecycle, applied GTID set, applied file and
position, pending GTID, and durable totals. Status reads a published snapshot.
It does not query the target or wait for the current SQL statement.
When available, `sourceFailurePosition` gives the file and byte offset of an
archive or transaction assembly error. Support bundles use this position to
select the relevant binlog bytes.

`transactionsApplied` counts completed source groups. It includes filtered and
skipped groups. It is not a count of successful target commits. `rowsApplied`
counts acknowledged row operations; `ddlApplied` counts applied DDL groups.
`skippedTransactionsByCode` gives automatic error skips by code.

The `counters` object adds INSERT, UPDATE and DELETE row counts, DML groups,
fully filtered groups, policy skips, automatic error skips, event count and
processed binlog bytes. Bytes include headers of events in completed groups.
They exclude retransmissions and events outside those groups. Partially filtered
groups count only included rows as applied. Uncertain writes are not counted.
Counters share the SQLite checkpoint commit and survive restart and history pruning.
`sinceTransaction` marks the start of these additional counters. An older state
starts these counters at upgrade; old operations are not reconstructed. Operator
recovery decisions remain in the recovery audit and are not inferred as SQL writes.

## Backlog and estimated catch-up time

`progress.estimate` gives recent transactions per second, binlog bytes per second,
remaining transactions and estimated seconds remaining. The rate window defaults
to 60 seconds. Estimates change when transaction sizes or target load change.
Filtered and skipped groups count as processed transactions for this rate.

Replay uses `source.stopAfterGTIDs` as the goal. A single endpoint such as
`uuid:1000` estimates the missing transactions through 1000. The exact stop rule
does not change. With no configured GTID goal, replay uses the validated archive
GTIDs. It subtracts the completed GTIDs by UUID, tag and interval. It never
connects to the source. Startup reports `collectingRateSample`; BLOCKED and
STOPPED runs report `paused` unless the goal is complete. A completed goal has
zero remaining seconds. No recent progress reports `noRecentProgress`.

Live mode polls source status and actual binlog file sizes every 15 seconds on
a separate connection. The source user needs `REPLICATION CLIENT` for this
metadata. Observations are saved in SQLite for diagnosis. The status contains
the observation time, age and any monitoring error. A failed or stale sample
does not stop replication, but it suppresses the catch-up estimate. Missing or
purged files can prevent a byte-backlog measurement. Live catch-up estimates
subtract the observed source transaction rate from the apply rate. If new work
arrives at least as fast as apply, status is `notCatchingUp`.

Configure `statistics.sourcePollIntervalSeconds` and
`statistics.rateWindowSeconds` from 5 through 3600 seconds. Replay ignores the
poll interval. Rates describe the current process; durable totals survive restart.

## Target SQL errors

`targetFailure.ddlSQL` identifies the source DDL. The optional
`targetFailure.targetSQL` object identifies the target SQL operation that failed.
These can differ. A session SET or metadata SELECT can fail before the applier
sends the source DDL. The object includes:

- `sql`: the SQL template, without expansion of bound parameters.
- `mysqlErrorNumber` and `sqlState`: the MySQL error number and SQLSTATE.
- `serverMessage`: the message from MySQL.

The applier saves these details in SQLite and the support bundle. Setup errors
that occur before a transaction starts can report `targetSQL` at the top level.
Older saved failures can lack this field. Server messages and literal SQL can
contain row values. Treat these diagnostics as private operational data.

`targetFailure.statement.phase` still describes the data-write outcome.
For example, a failed session SET leaves the source DDL phase at `notIssued`.
Use the recovery commands to inspect a BLOCKED state before restart.
A direct restart rejects a BLOCKED state. For DDL rejected before an intent was
saved, use the procedure below.
Do not infer that a write is safe to retry from the MySQL error number alone.

## Retry DDL rejected before a target write

All four profiles can retry a source statement rejected during DDL preparation.
This applies to both `run` and `replay`. First stop the process and correct the
cause, such as a missing privilege or an incorrect target session default.
Keep the state directory and its relay files.

```sh
mysql-replicator recovery inspect --config /etc/mysql-replicator/apply.yaml
mysql-replicator recovery resolve retry --config /etc/mysql-replicator/apply.yaml \
  --gtids 'SOURCE_UUID:NUMBER' --reason 'Corrected the target session default'
mysql-replicator replay --config /etc/mysql-replicator/apply.yaml
```

Replace `SOURCE_UUID:NUMBER` with the exact pending GTID from inspection. Use
`run` in the last command for live replication. Resume without `--initialize`.
The source or archive must still contain the rejected transaction.

Inspection reports `pending[].rejectedDDL`, with the SQL and its original bytes
in `sqlBase64`. Retry requires one complete source statement in the retained
relay, a matching saved failure with phase `notIssued`, and no row or DDL intent.
A missing diagnostic, damaged relay, mismatched GTID, or possible target write
prevents this action. The command works offline and takes the state writer lock.

Retry writes an audit record and changes the lifecycle to `STOPPED`. It keeps
the applied GTID set, file position, counters, and saved schemas unchanged.
Resume reads the statement again and repeats the normal DDL checks. This action
does not execute DDL, skip a GTID, or mark the statement as applied.

DDL with a saved intent still requires separate schema reconciliation. MyISAM
row recovery remains outside the `recovery resolve` command's scope.
