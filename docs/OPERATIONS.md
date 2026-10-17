# Replication status and statistics

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
