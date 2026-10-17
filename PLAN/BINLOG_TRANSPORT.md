# Beta.7: apply row events with BINLOG

Status: native-code review and a disposable-server probe. The production
applier still uses SQL DML. No beta.6 branch was changed for this work.

## Purpose

Add a second target execution mode. Keep SQL as the default. The new mode sends
base64-encoded row events with the MySQL `BINLOG` statement. It can avoid building
INSERT/UPDATE/DELETE SQL and can retain binary JSON values that SQL text cannot
represent exactly. It can also avoid the stored-function workaround used for
some preserved-GTID MyISAM groups.

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

## Implementation structure

Proposed configuration, not implemented:

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

- Can multiple BINLOG requests safely carry one source statement and one GTID
  on MyISAM, or must the complete statement fit one request?
- Which SQL error code survives native row-apply failure? Check this before
  connecting existing numeric skip policies to this path.
- Does strict native row lookup have the same intended duplicate and keyless
  behavior as the current executor? Compare affected rows, not only exit codes.
- Which compatibility translations require row-byte reconstruction rather than
  table-map changes? Do not change collation identifiers without checking values.
- How much preparation can avoid typed row decoding while retaining useful
  recovery records? Optimize only after the first durable path is correct.
- Does BINLOG materially reduce total apply time once GTID assignment, commits,
  base64 encoding and the shared journal are included?
