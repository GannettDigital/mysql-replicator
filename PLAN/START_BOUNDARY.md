# External provisioning and replication start boundary

## Scope

Database dump/load management is completely outside the replicator. Operators choose and run export/import tools, transfer files, prepare MyISAM schemas, resolve version/collation differences, validate loaded data, and repair/rebuild targets. The replicator contains no database dump parser, transformer, loader, dump-format adapter, MySQL Shell orchestration or dump-verification command. This supersedes the proposed `bootstrap prepare` / `bootstrap verify` workflow.

The replicator begins with an already prepared target and a known source boundary. Its responsibilities are input validation, source-history checks, native-channel exclusion and writer ownership, local state initialization, then ordered capture/application. Fixture seeding in the test harness remains test setup, not a production provisioning feature. MySQL's COM_BINLOG_DUMP protocol and raw relay files remain in scope; these are different from database snapshot export/import.

## Tool-independent input

The planned production configuration supplies:

- Source identity/history and target identity, connection/TLS settings, and stream identity.
- One selected start mode: a source binlog filename plus the position of the next event at a complete boundary; or the executed source GTID set already represented by the prepared target for the configured scope. The latter is an exclusion set, not the next GTID to set on a target session.
- The fixed database/table scope and authoritative historical schema valid at that boundary, including the metadata needed to decode rows. If both coordinate forms are provided, they must refer to the same boundary; never substitute a later sample of source state.
- An explicit operator declaration that the target is ready at this boundary. An optional opaque external provisioning reference is useful for diagnostics, but no dump files, hashes, format or loader progress are required inputs.

The operator owns snapshot/load correctness. Startup validates syntax, identities, schema compatibility and available history, and refuses active/connecting native channels or uncertain ownership before target writes. These checks cannot prove that every loaded row matches the asserted boundary. A filtered stream's seed GTID set stays bound to that scope; adding previously omitted data requires another externally established baseline.

For a new local state directory, durably record the supplied baseline without counting it as transactions applied by this process. Capture-only mode must not claim target/applied progress. Existing state resumes from its own durable capture/applied checkpoints; initialization must refuse to overwrite it. Source GTIDs live in local state; the replicator does not set target `gtid_purged`. Target apply connections continue using `SET @@SESSION.GTID_NEXT = 'AUTOMATIC'` with OFF_PERMISSIVE/WARN.

A prepared-target handoff may come from a dump/load, an existing stopped replica or another externally verified provisioning method. All use this same input contract. Required history must remain available from the supplied boundary until safely captured; expired history produces a diagnostic requiring external action, never an automatic jump to the current source position or an internal reload.

## MySQL Shell as an external option

MySQL Shell documents parallel dumping, separate DDL/data files and chunked data output. This is a suitable format for the operator's proposed large-instance export workflow. [MySQL Shell dump utilities](https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-shell-utilities-dump-instance-schema.html).

Its metadata contains `gtidExecuted` in `@.json`; the source binlog filename/position are included when the dumping account has `REPLICATION CLIENT`. `showMetadata` exposes the recorded replication coordinates. The operator supplies those snapshot coordinates through the generic replication configuration; any extraction stays outside this repository's production feature scope. [MySQL Shell dump metadata](https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-shell-utilities-load-dump.html).

The exact export/import versions and 8.4-to-5.7 MyISAM load compatibility need separate operational qualification. Merely recording coordinates does not establish a consistent or successfully loaded snapshot. These notes describe the boundary of responsibility, not a new dump/load runbook.

## Next implementation increment

Implementation order is DML correctness, then DDL correctness, then crash/reconnect recovery. Start with the serial DML applier:

1. Accept an externally prepared target and known file/position or executed GTID set, with matching source identity, scope and historical schema. Refuse active native replication and acquire exclusive writer ownership before mutation.
2. Feed complete decoded source transactions to a serial MySQL 5.7 MyISAM applier. Start with the existing primary-key fixture and its supported autocommit INSERT/UPDATE/DELETE operations. Keep exact values and statement order, initialize target sessions with `GTID_NEXT=AUTOMATIC`, and leave target binlogging enabled. Reject unsupported transaction shapes before writes where possible.
3. Add the minimum local relay/SQLite state needed for that path: retain raw bytes in files, persist the supplied baseline and row intents before mutation, record completed operations, and advance applied GTID/file-position only after the whole supported source group is verified. SQLite stores state and references, not raw events. Retain the file-fsync-before-metadata ordering; comprehensive storage/recovery qualification is not a prerequisite milestone ahead of the first applier.
4. Extend the three-server harness so the 5.7 target is actually written by Swift. Compare final data and ordered binlog effects against source intent and the native 8.4 MyISAM reference. Assert diagnostics and stopped progress for unsupported operations and apply errors.

The first acceptance gate is correct end-to-end INSERT/UPDATE/DELETE application for the declared subset, including exact values, before/after row matching, affected-row checks, key changes and multi-row operations where supported. Unsupported shapes must stop predictably; the native expected-negative cases remain part of the contract. This increment does not promise automatic crash/reconnect recovery: an interrupted run or uncertain SQL outcome stops/blocks and requires explicit operator handling until recovery is implemented and qualified. Do not retry uncertain writes or treat an incomplete journal as a safe applied checkpoint.

The second increment implements schema changes for a declared compatibility subset. Apply DDL in source order, preserve the explicit MyISAM mapping, update historical schema/table-map context before following DML, and reject unsupported changes with diagnostics. Test schema changes interleaved with INSERT/UPDATE/DELETE, including table-map invalidation/reuse and supported create/alter/rename/drop scenarios. Compare schemas, actual rows and ordered binlog effects against independently expected/native results, with engine/version transformations recorded explicitly. The current inspector's blanket DDL rejection is replaced only for qualified cases.

Only after both DML and DDL correctness gates pass, implement and qualify automatic crash/reconnect recovery. This third increment exercises crashes before/after target mutation, lost SQL responses, disconnects before checkpoint commit, partial MyISAM transactions, interrupted DDL and implicit commits, source rotation/replay, relay/SQLite crash windows and target restart. Prove target data, target binlog effects, row intents and applied checkpoints agree after recovery; capture-only stream equality is insufficient. Retain the conservative block/validation policy for target mysqld or host loss. Add read-only REST status/statistics once the capture/apply state is established; it is not a prerequisite for the first applier.

Phase 2 storage, Phase 3 apply and the relevant Phase 4 schema work may be interleaved to deliver DML then DDL before recovery. Their full qualification gates and remaining Phase 1 inventory/type/fleet work still stand. Dump/load management remains external throughout.

## Current implementation

The first [DML applier](DML_APPLY.md) accepts either file/position or a GTID-only
seed, persists raw relay events and SQLite state/intents, and applies the declared
single-statement DML subset. `run --initialize` asserts an externally prepared
handoff; it refuses existing state directories and all retained native channels,
even stopped ones. Deployment asserts native auto-start is disabled; SQL checks
verify no native channels/workers are present or active. Reopening state, explicit
stopped-channel adoption, DDL and REST serving remain unimplemented. The future
resume behavior above is a contract for a later increment, not current behavior.
