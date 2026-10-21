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
Position means byte offset within a binlog file. The following fields have
separate meanings:

| Field | Meaning |
| --- | --- |
| `appliedPosition` | End of the last transaction recorded as completed in SQLite. |
| `activity.readPosition` | Last file offset reported by the decoder. It can be ahead of prepared and applied work. It is not the download position. |
| `activity.preparedPosition` | End of the last transaction for which preparation or an unresolved intent was saved. It does not confirm a target write. |
| `pendingTransactions[]` | GTID, `start`, and `end` coordinates of unresolved transactions, in source order. The list contains at most 16 entries. |
| `pendingTransactionCount` | Total number of unresolved transactions, including entries omitted from the compact list. |
| `sourceFailurePosition` | Physical file and event offset of an archive read, decode, or transaction assembly error, when known. |
| `recovery` | Failure category, whether target reconciliation is required, and operator next steps. Present when available after a blocked run. |

The `activity` object changes while a worker waits. It includes:

- `generatedAt`: time when this reply was built, as Unix seconds.
- `checkpointUpdatedAt` and `checkpointAgeSeconds`: time and age of the
  coordinator's last progress snapshot. A fresh reply can contain an old
  checkpoint snapshot.
- `lastProgressAt` and `secondsSinceLastProgress`: time and age of the last
  observed increase in completed transactions in this process. These fields are
  absent until the process makes progress. They include filtered and skipped
  transactions.
- `phases`: current work for each active worker, with `name` and
  `elapsedSeconds`. Schema queries also include their purpose and table when
  known. The coordinator, capture worker, and target worker can be active at
  the same time. Do not add their durations.

Typical phases are `archiveValidation`, `schemaDiscovery`, `targetExecution`,
`targetCompletionWait`, `sourceReconnectWait`, and `targetReconnectWait`.
`archiveReadAndDecode` and `sourceReadAndDecode` include input waits and decoding.
`schemaWait` and `queueWait` identify capture waits. `targetReadOrControl`
includes session setup and transaction control. Other short phases identify
startup, preparation, and state writes. A schema phase with a query purpose
measures that query. A schema phase without a purpose measures the enclosing
lookup. Completed or blocked summaries have no
active phases. Phase durations and ages use a monotonic clock. Wall-clock
corrections do not change them.

Read and prepared positions are observations for the current run. They can move
back to the applied position when reconnect or reload discards queued work.
Use `appliedPosition` for resume. A pending intent can contain rejected SQL;
`preparedPosition` does not mean that SQL is executable.

Pending transactions can include work that was prepared but never issued. They
can also include writes that the target committed before SQLite recorded the
result. Match their GTIDs to `targetFailure` for the reported target outcome.
Do not treat the last pending offset as applied progress. For a decode failure,
no transaction end offset is reported unless a complete transaction was saved.

Status uses the coordinator's in-memory pending list. It does not add SQLite or
target queries to each status request. After the process exits, use `recovery
inspect` and the final error output. Inspection includes the saved source failure
coordinate and all supported pending records. Support bundles retain the final
error and SQLite records and use the failure coordinate to select binlog bytes.
Guidance does not resolve state or authorize an automatic retry. Recovery commands
validate the journal again and require an explicit operator action and reason.

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

## Table statistics

Enable detailed collection in the configuration. These settings require a restart.

```yaml
statistics:
  tableDetails: true
  maximumTableEntries: 6000
  snapshotIntervalSeconds: 30
```

`tableDetails` defaults to false. `maximumTableEntries` accepts 1 through 100000.
`snapshotIntervalSeconds` accepts 5 through 3600. Normal status adds only a small
`progress.tableStatistics` summary. Read or export one page with:

```sh
mysql-replicator ctl status --config apply.yaml --details --limit 100 --offset 0 \
  | jq '.tableStatistics' > table-statistics-page.json
```

Use `nextOffset` for the next page. A null value means there are no more entries.
Pages contain at most 100 entries. They read memory and do not query MySQL or
SQLite. Pages can change while replication runs; multiple pages are not one
atomic snapshot. After stop, export all saved entries from `state.sqlite`:

```sh
sqlite3 -readonly /path/to/state/state.sqlite \
  'SELECT entry_json FROM table_statistics ORDER BY id;' > table-statistics.ndjson
```

This export has one JSON object per line. The same tables are in a support bundle's `state.sqlite`. Collection does not
create another per-row audit log.

Each entry has two groups of counters:

| Group | Meaning |
| --- | --- |
| `durable` | INSERT, UPDATE, and DELETE rows in completed source transactions; completed, filtered/empty, policy-skipped, and error-skipped transactions; applied DDL by operation. These updates share the SQLite checkpoint commit. They survive restart. Partial or uncertain transactions do not add applied rows. |
| `process` | Events delivered to the coordinator, decoded rows, known filtered rows, planned row operations and DDL, failed queries, planning failures, blocked runs, query counts and elapsed time, and encountered target column/index types. These start at zero in each process. Reconnects can repeat observations and planning attempts. |

`filteredTransactions` includes fully filtered groups and empty or rolled-back
groups completed without included row writes. It does not measure rows rejected
by a filter.

`durable.completedTransactions` counts participation by name. A transaction that
touches two tables counts once for each table. Do not sum these counts to obtain
the global transaction count. Row-operation counts can be summed. A multi-name
DDL counts once for each name in its prepared plan. A schema entry has an empty
`table` string. View and routine names share the same database/name grouping.
Group entries by `database` to compare schemas. The overflow entry has no schema
attribution.

The first configured number of names get stable entry IDs. The tool keeps these
entries; it does not evict them. It emits one warning per process when the limit
is reached, including after restart with a full registry. The warning gives the
limit and `statistics.maximumTableEntries`. Further names use entry `-1`, the
overflow total. Identifiers longer than 256 UTF-8 bytes also use overflow.
Entry `0` contains work with no known name, including general target queries and
blocked-run counts. These two entries do not consume named slots.

RENAME keeps the old name's history and records the new name separately. DROP
keeps history. A later CREATE with the same name uses that name's existing entry.
If you lower the limit below the number of saved entries, startup fails with an
instruction to increase it. Increasing it permits new entries. It cannot split
old overflow totals back into names.

Filters can discard a row event without decoding its rows. Such an event adds to
`filteredRowEventsWithoutRowCount`. `filteredRows` counts only rows whose count is
known; it is not a complete count when that event counter is nonzero. Column and
index types are sets from target schema lookups, not per-row counters.
`schemaQuerySeconds` measures metadata queries for the named table when known.
`targetQuerySeconds` measures other target queries in entry `0`. Both include
server and network waits. A failed query and a later blocked run are separate
counters; neither counts unique failed source transactions.

Applied counts are recorded only while detailed collection is enabled.
`sinceTransaction` gives the starting global transaction count.
`transactionsNotRecorded` reports later gaps, for example when collection was
disabled or an operator resolved transactions outside normal apply. Counts do
not reconstruct earlier work.

Process statistics are best effort. Changed entries can be saved with completion
commits. A full process snapshot is saved at the next completion commit after the
configured interval, and on clean stop. Saving on BLOCKED is best effort.
A crash can lose recent process measurements. Saved entries include `processID`
and `sampledAt` (Unix seconds), so you can identify old samples. After restart,
live process counters start at zero. Durable counts continue from saved totals.

## Backlog and estimated catch-up time

`progress.estimate` gives recent transactions per second, binlog bytes per second,
remaining transactions and estimated seconds remaining. The rate window defaults
to 60 seconds. `sampleDurationSeconds` and `sampleTransactions` show the
observations used for the rate. An estimate is `provisional` until the sample
covers at least 5 seconds and 20 transactions. `sampleAgeSeconds` shows the age
of this rate calculation. If the coordinator has not refreshed it within the
rate window, status becomes `staleRateSample`. The last ETA remains visible as
a provisional value. It is not a countdown. Estimates change when transaction
sizes or target load change.
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
does not stop replication. It marks the estimate `staleSourceSample` and
`provisional`. The estimate uses the last observed source goal; new source work
can make it too small. Missing or
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

## Retry an archive failure before target setup

An archive error can occur before the applier saves the target UUID. Inspection
now accepts this state only if it contains no applied or pending target work.
The target UUID is absent from the report. The report still shows the baseline
GTIDs and the saved `sourceFailurePosition`.

Keep the original support bundle. Correct the archive or decoder problem, then
use an explicit retry:

```sh
mysql-replicator recovery inspect --config replay.yaml
mysql-replicator recovery resolve retry --config replay.yaml \
  --gtids none --reason 'Replaced the invalid archive file from the source'
mysql-replicator replay --config replay.yaml
```

Use this path only when inspection confirms an empty startup state and a matching
saved source failure. It works with all four profiles. The command records the
operator decision and makes the empty state resumable. It does not apply or skip
any GTID. Normal replay repeats readiness and archive checks. Do not use
`--initialize` to bypass blocked state.

For an InnoDB target with pending rows, reconcile every pending transaction first.
Use the [InnoDB recovery procedure](REVERSE_REPLICATION.md) to choose an
action. DDL with saved intents and uncertain MyISAM writes retain their existing
recovery limits.

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

## Inspect a range without writes

Use `mysql-replicator replay --config replay.yaml --dry-run` to inspect
a local archive. Use `run --dry-run` for a finite live range. The command reads
target metadata and discards writes. It does not open replication state.
Discarded DDL can cause later events to fail against the unchanged target schema.
See [dry-run checks and limits](COMMAND_LINE.md#dry-run).

## Target connections and schema cache

Run and replay open two target connections with the same configured credentials
and TLS or socket settings. One connection reads server schema metadata. The
other executes DML, DDL, and session commands. Startup requires the same server
UUID and version on both connections. A connection failure uses the existing
target failure and reconnect path. The tool does not retry individual SQL
statements on a new connection.

Session variables, temporary-table reads, lock checks, and SHOW CREATE operations
that depend on session settings stay on the write connection. Metadata checks
under an explicit table lock also use that connection to avoid waiting on the
tool's own lock. Ordinary discovery releases the old table lock before lookup.

The shared schema cache uses database and table names as keys. Entries have no
time-based expiry or periodic refresh. The tool assumes that it is the only
target writer. Entries remain until DDL invalidates or replaces them, or a new
target session rebuilds the cache. The size limit stops growth; it does not evict
entries. Normal apply
updates the cache with verified schema changes after DDL. Dry run clears its
cache after discarded DDL and reads the unchanged target again. No schema is
predicted in dry run. Metadata read-ahead is not implemented yet.

### Schema cache limits and discovery timings

The top-level `maximumCachedTables` setting defaults to 6,000 tables. Set an
integer from 1 to 100,000 to change it. Restart the applier after the change.
The same limit applies to target discovery, validated plans, DDL, saved-schema
reload, and capture schema interpretation. A larger limit uses more memory.
SQLite storage limits still apply. This setting does not change the limits for
active table maps within one statement or tables in one FK component. A restart
with a limit below the saved table
count fails; it does not discard saved schemas.

Target table entries do not expire with time. Ordered DDL invalidates affected
metadata. New target sessions rebuild their caches. Capture can discard its
interpretation cache at the limit and repeat an ordered schema lookup.

During one discovery operation, identical metadata queries reuse their results.
This temporary query cache has a 16 MiB estimated-result budget and a 2,048-query
limit. When it fills, queries continue without caching. Its results do not survive
completion or failure of the discovery operation. It never caches writes,
session-local queries, or query failures.

Stage timings include counts, failures, total time, and maximum time for each
`target.metadata.*` query family. `target.metadata.cache_hit` counts reused
reads. `--verbose` reports per-table discovery totals. A metadata query that
fails or takes at least one second produces a warning with its family, table,
elapsed time, and timeout. Logs do not include SQL text or bindings.

`target.sql.write` measures mutation statements. `target.sql.read_or_control`
measures reads, session setup, and transaction control. These stages are nested
under `target.sql`; do not add them to that total. A prepared SQL command can
require more than one network round trip on its first use.
