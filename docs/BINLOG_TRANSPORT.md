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
  it after a format-description event, even when source GTIDs are not preserved.
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

## Initial limits

This path accepts version 4 binlogs with CRC32, table maps, and version 2 FULL
INSERT, UPDATE, and DELETE row events. The existing decoder and schema checks
still run. The applier does not reconstruct or translate row-event bytes.

These cases stop before row writes:

- A MyISAM source group with multiple statement ends when source GTIDs must be
  preserved. MySQL completes the GTID at the first statement end. The SQL path
  remains available for its supported MyISAM groups.
- A source group with both included and filtered events. Entirely filtered groups
  still advance the checkpoint and, when enabled, record an empty source GTID.
- Generated columns, partial row images, partial JSON updates, and unsupported
  event types. These limits apply to BINLOG mode, not to the default SQL mode.
- `compatibility.jsonYearToInteger: true`. This conversion needs the SQL path.
- A group whose encoded request exceeds the target packet limit or the raw-event
  byte limit. Base64 adds approximately one third to the raw size. The complete
  SQL request and command byte must fit `max_allowed_packet` and the client limit.

The applier does not split a source row statement across BINLOG requests. MySQL
can discard table-map context between requests and then report success without
applying the later rows. The initial implementation sends each complete source
DML group in one row request. Increase the packet limit and reconnect if needed.

## Failure and restart

Both transports use the same relay files, SQLite row intents, durable preparation
queue, and ordered checkpoints. SQLite format 14 records the transport and event
program version. Older SQL state can migrate to format 14. It cannot change to
BINLOG transport during that migration. Older binaries cannot open format 14.

InnoDB groups use BEGIN and COMMIT. A write failure requires a confirmed ROLLBACK
before an allowed duplicate-key skip. A lost COMMIT reply remains uncertain.
MyISAM can keep partial writes and the source GTID after an error. The applier
keeps the pending group for review. It never retries a failed BINLOG request as SQL.

Support bundles retain the transport setting, source events, schema records, row
intents, and target failure. Start with `failure.json`. Do not use the target's
GTID set alone to decide that a failed MyISAM group applied in full.

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
The first 10K single-row benchmarks passed, but BINLOG did not improve elapsed
time. Native times varied between runs. No performance improvement is claimed.
See [the measurements](../PLAN/BINLOG_TRANSPORT_MEASUREMENTS.md) for scope and limits.
