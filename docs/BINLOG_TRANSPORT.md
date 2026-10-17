# Apply row events with BINLOG

The default DML transport is `sql`. Beta.7 also provides an opt-in `binlog`
transport. It sends source table-map and row events through the target's `BINLOG`
statement. MySQL then applies those events through its row replication code.
DDL still uses SQL. This mode does not create a native replication channel.

Select the mode before you initialize a new state directory:

```yaml
target:
  transport: binlog
  preserveSourceGTIDs: true
  # Keep the connection and credential settings for your target.
```

The same setting applies to `run` and offline `replay`. Replay does not connect
to the source. Use a verified target baseline and its source GTID set, as for
SQL transport. Do not change transport in an existing state directory.

## Target settings and privileges

- MySQL 5.7 requires `SUPER` for `BINLOG`.
- MySQL 8.4 accepts `BINLOG_ADMIN`, `SUPER`, or `REPLICATION_APPLIER` with the
  required event privileges.
- The account must also be able to set session `GTID_NEXT`. The applier resets
  it after a format-description event when source GTIDs are not preserved.
  See [source GTID preservation](GTID_PRESERVATION.md).
- Keep `slave_exec_mode` (5.7) or `replica_exec_mode` (8.4) at `STRICT`.
  Keep `slave_skip_errors` or `replica_skip_errors` at `OFF`.
  The applier checks these settings. Use its `skipErrors` policy for supported skips.
- Remove native `replicate-rewrite-db` rules from the target configuration.
  MySQL 5.7 can use those rules for BINLOG statements, but does not expose them
  as a system variable that this preflight can check.
- Keep `target.explicitTableLocks: false`. The existing requirements for target
  engine, binary logging, exclusive writes, and disabled native replication still apply.

The account's first format-description request checks the BINLOG privilege before
row writes. A format-description event tells the target how to read the event
headers. Each new target connection receives its own format description.

## Supported inputs and limits

This path accepts version 4 binlogs with CRC32, table maps, and version 2 FULL
INSERT, UPDATE, and DELETE row events. The existing decoder and schema checks
still run. The applier does not reconstruct or translate row-event bytes.

The current implementation has the following limits. A refusal keeps the
checkpoint before the affected transaction. It does not silently fall back to SQL.
These are tool limits unless the text identifies a MySQL restriction.

These cases stop before row writes:

- MyISAM groups outside the shared one-statement/one-included-table rule.
  This rule also applies with source GTID preservation disabled. When preservation
  is enabled, MySQL itself completes the GTID at the first MyISAM statement end.
  This implementation does not remove that engine restriction.
- A source group with both included and filtered events. Entirely filtered groups
  still advance the checkpoint and, when enabled, record an empty source GTID.
- Generated columns, partial row images, partial JSON updates, and unsupported
  event types. These limits apply to BINLOG mode, not to the default SQL mode.
- `compatibility.jsonYearToInteger: true`. This conversion needs the SQL path.
- A source statement whose encoded request exceeds the target packet limit,
  or a group that exceeds the raw-event byte limit. Base64 adds approximately one third to the raw size. The complete
  SQL request and command byte must fit `max_allowed_packet` and the client limit.

Source and target schemas must pass the existing compatibility checks. DDL
collation mappings still apply. They do not change the raw row-event bytes.
Compressed transaction payloads and XA remain unsupported by the shared decoder.
A different server version, permissive execution mode, or disabled GTID
preservation does not waive these checks.

The applier does not split a source row statement across BINLOG requests. MySQL
can discard table-map context between requests and then report success without
applying the later rows. Each complete source row statement gets one request.
Several requests can belong to one source transaction. Increase the packet limit
and reconnect if one complete statement does not fit.

## Transaction execution

The BINLOG path follows `mysqlbinlog` for supported row transactions:

```sql
SET SESSION GTID_NEXT = 'source-uuid:101';
BEGIN;
BINLOG '...'; -- One complete source row statement.
COMMIT;
SET SESSION GTID_NEXT = 'source-uuid:102';
-- Next source transaction.
```

BEGIN and COMMIT correspond to the source BEGIN and COMMIT/XID events. A
preparation batch does not merge source transactions. An empty source ROLLBACK
remains ROLLBACK. DDL uses its implicit commit. An inactive whole version comment
needs an explicit COMMIT to complete the empty source GTID.

The applier assigns the next source GTID directly. It does not query the target
GTID set or reset GTID_NEXT after each transaction. With preservation enabled,
it resets before installing a format description and at clean shutdown. With
preservation disabled, it restores AUTOMATIC after a format-description event.
Ordinary metadata reads do not require a reset.

Like `mysqlbinlog`, this mode lets MySQL skip an already-executed GTID. Use a
verified target baseline. This server behavior does not resolve an uncertain
previous write in SQLite. The SQL transport retains its existing GTID checks.

## Failure and restart

Both transports use the same relay files, SQLite row intents, durable preparation
queue, and ordered checkpoints. SQLite format 14 records the transport and event
program version. Older SQL state can migrate to format 14. It cannot change to
BINLOG transport during that migration. Older binaries cannot open format 14.

Row groups retain the source BEGIN and COMMIT boundaries. InnoDB requires a
confirmed ROLLBACK after a write failure before an allowed duplicate-key skip.
A lost COMMIT reply remains uncertain.
MyISAM can keep partial writes and the source GTID after an error. The applier
keeps the pending group for review. It never retries a failed BINLOG request as SQL.

Support bundles retain the transport setting, source events, schema records, row
intents, and target failure. Start with `failure.json`. Do not use the target's
GTID set alone to decide that a failed MyISAM group applied in full.

## Select and operate the transport

1. Prepare the target baseline and record its source GTID set.
2. Add `transport: binlog` under `target` in the normal run or replay configuration.
3. Select a new durable `stateDirectory`. Start with `--initialize` once.

```sh
mysql-replicator run --config apply.yaml --initialize
# Or apply a local archive without a source connection:
mysql-replicator replay --config replay.yaml --initialize
```

Use the normal `ctl status`, `ctl stop`, and replay stop settings. Resume with the
same configuration and without `--initialize`. Transport changes require a new
state directory and a verified baseline. A config reload cannot switch transport.

Useful timing counters are `apply.binlog.prepare`, `apply.binlog.base64`,
`target.binlog.format`, `target.binlog.rows`, and `target.sql`.
`target.binlog.format.count` includes cache checks; it is not the number of FDE
requests. `target.binlog.rows.count` counts complete row-statement requests.
These counters do not include DDL in the row-request count.

## Focused tests

The shared runner accepts the transport as an option:

```sh
swift run replicator-lab test --profile mysql84-to-mysql57-myisam --dml-transport binlog --case positive
swift run replicator-lab test --profile mysql57-to-mysql84-innodb --dml-transport binlog --case positive --skip-build
```

The option also applies to the shared lifecycle suite. It does not select a
separate test framework or imply that every existing case supports this mode.
The test report records `dml_transport`. See [the test lab guide](TEST_LAB.md).
The first shared runs passed `positive` on both profiles above. The reverse
profile also passed `offline-replay` and `live-skip-errors`. These checks cover
rotation, stop/resume, external archives, and duplicate-error rollback with
continuation. Both profiles also passed the selected lifecycle cases
`source-reconnect`, `target-reconnect`, `target-uncertain`, and
`target-uncertain-resume`. These cover socket loss, server restarts, and refusal
to resume an uncertain write. The full type and lifecycle matrices remain untested.
The 10K single-row benchmarks passed with both transports. BINLOG now uses about
four target calls per transaction, compared with five for SQL. The fresh comparison
did not show a clear elapsed-time gain over SQL. Native times varied between
runs. No stable performance improvement is claimed.
See [the measurements](../PLAN/BINLOG_TRANSPORT_MEASUREMENTS.md) for scope and limits.
