# Beta.7: apply row events with BINLOG

Status: opt-in BINLOG execution is connected to the apply loop. SQL remains the
default. Focused unit and shared lab tests check this first implementation. No beta.6 branch was changed for this work.

## Purpose

Add a second target execution mode. Keep SQL as the default. The new mode sends
base64-encoded row events with the MySQL `BINLOG` statement. It can avoid building
INSERT/UPDATE/DELETE SQL and can retain binary JSON values that SQL text cannot
represent exactly. It can avoid the stored-function workaround for large
single-statement MyISAM groups. It does not yet solve source GTID preservation
for MyISAM groups that contain multiple source statements.

The goal is an elapsed time of at most 1.5 times the matching native replica on
the agreed workloads. This is a measurement target, not a current result.

## What MySQL implements

The local MySQL trees already include `client/mysqlbinlog.cc`. No separate
mysqlbinlog source download is needed. The reviewed versions are 8.4.8
(`0896fcd6`) and 5.7.44 (`f7680e98`). The lab uses server versions 8.4.8 and 5.7.42.

`mysqlbinlog` reads events and writes a SQL script. It does not send that script
to a target on port 3306. The `mysql` client reads the script and submits normal
SQL requests. Our existing client connection can submit the same statement form.

The server decodes the base64 payload and calls the replication event apply
code. It creates a session-local relay context. That context does not advance a
native replica channel's position. Our SQLite checkpoint remains necessary.

The two reviewed servers accept format-description, table-map, and row events.
They also accept row-query annotations. MySQL 8.4 accepts partial-update row
events; MySQL 5.7 does not. They reject GTID, Query, XID, Rotate and transaction
payload events in `BINLOG` statements. Therefore, we cannot send a complete raw
transaction stream unchanged.

Use separate SQL for source GTID assignment, BEGIN/COMMIT, session settings, and
DDL. A format-description event must precede row events on each new connection.
Keep every table-map event required by the row events. Preserve the source
statement-end flags; a statement can span several row events.

Permissions are separate from source-GTID assignment:

| Target version | Permission for BINLOG |
| --- | --- |
| 5.7 | `SUPER` |
| 8.4 | `BINLOG_ADMIN`, `SUPER`, or `REPLICATION_APPLIER` with the required event privileges |

Check the actual account before target data writes. Do not assume that a managed
service permits this mode. No Cloud SQL instance was tested. Do not silently
switch execution modes after a statement has been issued.

Primary references:

- [BINLOG statement](https://dev.mysql.com/doc/refman/8.4/en/binlog.html).
- [5.7 event allowlist and execution](https://github.com/mysql/mysql-server/blob/mysql-5.7.44/sql/sql_binlog.cc).
- [8.4 event allowlist and execution](https://github.com/mysql/mysql-server/blob/mysql-8.4.8/sql/sql_binlog.cc).
- [mysqlbinlog event printing and row statement cleanup](https://github.com/mysql/mysql-server/blob/mysql-5.7.44/sql/log_event.cc).
- [mysql client SQL submission](https://github.com/mysql/mysql-server/blob/mysql-8.4.8/client/mysql.cc).
- [FDE checksum handling](https://github.com/mysql/mysql-server/blob/mysql-5.7.44/libbinlogevents/src/binlog_event.cpp).

## First probe

`tools/binlog-transport/probe.py` creates two disposable servers per profile.
It does not connect to a running demo. It captures a 32-row INSERT, a three-row
UPDATE, and a two-row DELETE. The INSERT spans multiple row events. Values include
JSON with an opaque binary string and 2 KiB binary columns.

It submits each complete row group through one BINLOG statement, between explicit
source GTID assignment and BEGIN/COMMIT. It checks final values, source GTIDs,
and all field bytes in the source and target binlog row images. It ignores only
unused bitmap padding bits when comparing those images.

The probe tries two format descriptions separately: the original source FDE and
a target-generated FDE. The second is an experiment, not a production conversion
rule. Replacing the FDE alone cannot make arbitrary event bytes compatible.

Initial results on 2026-10-17 UTC:

| Profile | SQL requests and source GTIDs | Binary row images |
| --- | --- | --- |
| 8.4 → 5.7 MyISAM | Passed with both FDEs | All 40 match |
| 5.7 → 8.4 InnoDB | Passed with both FDEs | All 40 match |
| 5.7 → 5.7 MyISAM | Passed with both FDEs | All 40 match |
| 5.7 → 5.7 InnoDB | Passed with both FDEs | All 40 match |

The first reverse test reported a text comparison failure. For the tested binary
JSON value, 5.7 printed a base64 representation. The 8.4 query exposed raw bytes,
and `CAST(doc AS CHAR)` returned NULL for the document. Source and target binlogs
retained identical JSON bytes. This is a cross-version SQL representation
difference. A binary transport does not make the servers' JSON functions identical.

Evidence is under `artifacts/binlog-transport/` in this worktree:
`four-profiles/` retains the original runs, and `raw-row-comparison.json` records
the later binary comparison. Do not relabel the original failed reverse report
as a passing run. The corrected reverse run has its own evidence directory.

The corrected reverse run passed with both FDEs. Its report is
`artifacts/binlog-transport/reverse-binary-comparison/summary.json`. Five unit tests
passed for event framing, CRC validation, transaction grouping, SQL construction,
and byte comparison. The earlier source-FDE CRC error remains in `forward-initial/`;
the corrected reader verifies MySQL's FDE checksum with the in-use flag cleared.

These are transport feasibility checks, not end-to-end applier tests or native
replication benchmarks. They do not prove recovery, filters, error skips, schema
conversion, or all MySQL types. The probe uses FULL row images, CRC32, compatible
schemas, no compression, and root on disposable servers.

## Request boundaries and failure behavior

`tools/binlog-transport/behavior_probe.py` reuses the captured synthetic events.
It starts one disposable target per profile. It uses the client `--force` option
to inspect a session after an error. This is deliberate test behavior. The
production executor must stop at the first error.

The boundary checks produced these results on all four profiles:

| Experiment | InnoDB target | MyISAM target |
| --- | --- | --- |
| Send each table-map and row event in a separate request | No rows applied; no SQL error | No rows applied; no SQL error |
| Commit after those empty requests | Source GTID recorded | Source GTID recorded |
| Insert 32 rows with a pre-existing row at key 32 | Error 1062; no new rows remain | Error 1062; 31 new rows remain |
| Roll back after that duplicate error | Source GTID absent | Source GTID present; partial writes remain |
| Put three source row statements in one request under one explicit GTID | All three statements apply | First statement applies; error 1837 at the next statement |

The multi-statement experiment combines the captured INSERT, UPDATE, and DELETE
events under one explicit GTID. It retains their original statement-end flags.

Splitting failed even without SQL status queries between the requests. The native
`mysql_client_binlog_statement` function calls `slave_close_thread_tables` at the
end of each request. The saved FDE remains available, but a table map from a
previous request is not sufficient to apply the next row event. Do not use a
successful SQL reply or a recorded target GTID as proof that raw events were
assembled correctly.

MyISAM completes an explicit GTID at the first source statement end. Putting all
events in one BINLOG request does not change this behavior. The first builder
rejects a multi-statement MyISAM group when source GTID preservation is enabled.
It makes this check before any target write. Broader MyISAM execution needs more
design and tests. Do not clear statement-end flags as an untested workaround.

Applying an FDE changes the session's internal GTID state. Without source GTID
preservation, explicitly set `GTID_NEXT='AUTOMATIC'` **after** the FDE. Omitting
this step caused error 1782 on targets with `gtid_mode=ON`. With the reset, the
32-row group applies on all four profiles. InnoDB targets assign a local GTID;
the tested MyISAM targets use `OFF_PERMISSIVE` and do not assign one. SQLite must
still track the source identity in either case.

A database-level account without the BINLOG privilege fails with error 1227.
A missing FDE fails with error 1609. A raw GTID event fails with error 1730.
A request above `max_allowed_packet` fails with error 1153, or disconnects with
client error 2006 and a packet-limit message in the server log. These fixture rows
are not written. The probes use native
`STRICT` execution mode. The production preflight must check this setting.

Evidence directories:

- `failure-boundaries/`: initial results, including the failed split assumption.
- `failure-boundaries-confirmed/`: confirms splitting without intervening queries;
  retains the newly found automatic-GTID and multi-statement failures.
- `session-and-rejections/`: tests the explicit AUTOMATIC reset, expected MyISAM
  multi-statement rejection, missing FDE, privileges, and packet limits.
- `rejected-event-type/`: repeats only the GTID-event rejection after the session
  reset. The earlier GTID-event check on InnoDB stopped at error 1782 before it
  reached the event-type validator.

`validated-observations.json` links 40 checked observations to these original
reports. It also includes intentional native failures, as specified above. All
four restricted-account checks returned error 1227. The probe containers were
removed after collection. No full correctness or performance suite ran.

These are native-server probes. There is no applier support bundle for them.
The generated SQL, stderr, server logs, and target binlogs are the failure records.

## Implemented request builder

`Sources/ReplicatorApply/BinlogEventProgram.swift` prepares separate FDE and row
requests. It keeps the original event bytes and creates base64 only when asked
for SQL. It checks these conditions before execution:

- Event lengths and CRC32, including the mutable FDE in-use flag.
- Version 4 events, common-header length, and supported post-header lengths.
- FULL version 2 INSERT/UPDATE/DELETE images and table maps.
- Table-map references within each statement and a final `STMT_END_F` flag.
- A raw-byte budget and a packet budget for base64, SQL syntax, and COM_QUERY.
- The MyISAM multi-statement restriction when source GTIDs must be preserved.

Each prepared group has one row request. If it does not fit the packet budget,
preparation fails. The builder does not split a source statement, rewrite events,
or substitute an FDE. The existing codec and schema checks must validate row
values and target compatibility. This builder does not replace those checks.

The focused request-builder Swift suite has 13 tests. It includes damaged and
truncated events, map reuse, missing statement ends, UPDATE before/after bitmaps,
packet boundaries, and the MyISAM restriction. Seven Python unit tests cover the
probe helpers.

The apply loop now carries the prepared program through the existing durable
queue. State format 14 binds `target.transport` and program version 1. Existing
SQL state migrates without changing transport. Recovery checks the same binding.
A connection-local FDE cache resets on reconnect. InnoDB uses explicit BEGIN,
COMMIT, and confirmed rollback before an allowed duplicate-key skip. MyISAM
failures retain all unacknowledged row intents. No SQL fallback is attempted.

The first implementation rejects partially filtered groups and generated columns.
It preserves entirely filtered groups and the existing empty-GTID path. DDL stays
on the SQL path. The shared lab accepts `--dml-transport binlog` for correctness
and lifecycle tests. See [operator instructions](../docs/BINLOG_TRANSPORT.md).
Broader type, filter, and performance checks remain in the delivery stages below.

## First shared apply tests

The following checks passed on 2026-10-17 UTC:

- 79 focused Swift tests for framing, configuration, execution outcomes, GTIDs,
  state migration, and recovery. Logs: `artifacts/binlog-focused-tests.log` and
  `artifacts/binlog-recovery-tests.log`.
- Seven Python probe-helper tests.
- `positive` on 8.4 → 5.7 MyISAM and 5.7 → 8.4 InnoDB, with BINLOG transport.
  These cases compare rows, binlog operations, source GTIDs, and SQLite state.
- `offline-replay` on 5.7 → 8.4 InnoDB, with BINLOG transport. This case covers
  DDL and DML, rotation, stop/resume, and external mysqlbinlog archives. Replay
  runs without source credentials and produces a support bundle.
- `live-skip-errors` on 5.7 → 8.4 InnoDB, with BINLOG transport. The duplicate
  group rolls back in full. Later groups apply. Skip counters survive restart,
  with and without individual skip records in SQLite.

Shared results are in these local files:

- `artifacts/lab/20261017T060531Z-255ccb55/result.json` (forward positive).
- `artifacts/lab/20261017T060809Z-ff3cc4e2/result.json` (reverse positive).
- `artifacts/lab/20261017T060953Z-db3be7ea/result.json` (offline replay).
- `artifacts/lab/20261017T061232Z-596419bb/result.json` (live error skips).

The first forward test exposed a stale GTID assertion in the shared case. It
expected no target GTIDs even with preservation enabled. The assertion now
compares source and target GTID deltas. The original failed result remains at
`artifacts/lab/20261017T060057Z-c293c398/result.json`. The applier completed that
run, so it did not create an automatic failure bundle.

These runs do not establish full type support or performance. Live reconnect
and the full test matrix have not run with BINLOG transport. Unit tests check
connection-local FDE state, pre-write connection loss, and lost COMMIT replies.

## Implementation structure

Implemented configuration:

```yaml
target:
  transport: sql # sql (default) or binlog
```

Use one shared coordinator and two target DML executors. Keep the engine contract
separate from the wire format. Both modes must use the existing transaction
assembler, schema checks, filters, durable preparation, ordered completion,
reconnect policy, and stop/reload behavior.

Relevant existing boundaries:

- `LiveRecord.rawBytes` already carries source event bytes to the relay.
- `StateStore.append` already saves these bytes in `relay.frames`.
- `StateStore.beginBatches` syncs the relay and saves pending work before execution.
- `DMLExecutor` already provides a bounded queue and one target worker.
- `TargetSession.execute` selects engine and source-GTID behavior.

Add a target-event preparation layer. It must retain the FDE, table maps, row
events and statement boundaries without converting them to base64 until needed.
Use relay references or bounded `Data` buffers, not a second unbounded raw-event
queue. Represent prepared SQL and prepared BINLOG programs with distinct types.
The executor must report the same commit and uncertain-write outcomes to the
shared coordinator.

Retain existing row intents in the first implementation. They provide primary
keys, before/after images, schema versions and DBA recovery details. Add the
selected transport and prepared-event format version to durable state. Bind the
transport at initialization and reject a change on resume until a safe migration
is defined. Do not replace SQLite with a target journal.

The source relay remains the replay authority. If preparation rewrites bytes,
save the conversion version and enough data to inspect the exact issued request.
Support bundles must identify its source GTID, event offsets, FDE/table-map
context, target schema and outcome. No new whole-file hashes are required.

## Delivery order

1. Finish the native behavior probes. Check rollback and duplicate failures on
   each target engine, MyISAM partial writes and GTID state, disabled preservation,
   restricted accounts, packet limits, and statement splitting. Check JSON YEAR
   separately from opaque binary strings. Keep the raw-event probe reproducible.
2. Add the event-program representation and unit tests. Validate event lengths,
   CRCs, table-map lifetimes, statement boundaries, packet budgets and FDE resets.
   Base64 expands bytes by approximately one third. Budget the complete SQL
   request against target `max_allowed_packet`, not just the raw row bytes.
3. Add the opt-in BINLOG executor for compatible FULL row events. Keep the
   existing SQL DDL path and compatibility rules. Use the shared durable queue
   and state completion. Apply one source GTID at a time. Keep SQL as the default.
4. Add explicit cross-version preparation rules only where needed. Test optional
   table-map metadata, collations, generated columns, JSON YEAR, and source/target
   schema differences. Decompress transaction payloads before submission. Do not
   assume that changing a version string or FDE converts the event format.
5. Run the same named lab cases with both transports. Add transport as an option
   under the existing profile model. Include restart, offline replay, target
   disconnect, filters, empty GTID markers, skip policies and failure bundles.
   Confirm that native execution does not silently ignore errors because of a
   target replication setting. Preserve current trigger and foreign-key policy.
6. Measure 10K and 25K runs on all four profiles, with the matching native
   reference and SQL mode. Use the same durability, binlog, engine, indexes and
   workload settings. Report startup separately. Repeat runs and report the
   median and range. Add JSON-heavy and multi-row cases. Test TCP and Unix sockets
   separately where supported. Only then assess the 1.0–1.5x goal.

Do not add an automatic SQL fallback after a BINLOG error. A MyISAM statement
can have partially applied. A lost COMMIT reply remains uncertain on InnoDB too.
Keep the existing BLOCKED behavior and saved evidence. A source GTID in the target
alone does not prove complete MyISAM application.

## Open questions before production enablement

- How can BINLOG preserve one source GTID for multiple MyISAM statements?
  The direct path fails with error 1837 after the first statement.
- A duplicate-key failure retains error 1062. Check other error classes before
  connecting existing numeric skip policies to this path.
- Does strict native row lookup have the same intended duplicate and keyless
  behavior as the current executor? Compare affected rows, not only exit codes.
- Which compatibility translations require row-byte reconstruction rather than
  table-map changes? Do not change collation identifiers without checking values.
- How much preparation can avoid typed row decoding while retaining useful
  recovery records? Optimize only after the first durable path is correct.
- Does BINLOG materially reduce total apply time once GTID assignment, commits,
  base64 encoding and the shared journal are included?
