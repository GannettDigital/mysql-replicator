# External provisioning and replication start boundary

## Scope

Database dump/load management is completely outside the replicator. Operators choose and run export/import tools, transfer files, prepare MyISAM schemas, resolve version/collation differences, validate loaded data, and repair/rebuild targets. The replicator contains no database dump parser, transformer, loader, dump-format adapter, MySQL Shell orchestration or dump-verification command. This supersedes the proposed `bootstrap prepare` / `bootstrap verify` workflow.

The replicator begins with an already prepared target and a known source boundary. Its responsibilities are input validation, source-history checks, native-channel exclusion and writer ownership, local state initialization, then ordered capture/application. Fixture seeding in the test harness remains test setup, not a production provisioning feature. MySQL's COM_BINLOG_DUMP protocol and raw relay files remain in scope; these are different from database snapshot export/import.

## Tool-independent input

The planned production configuration supplies:

- Source identity/history, connection/TLS settings and stream identity. Discover the
  target UUID from the verified target connection, persist it on initialization and
  require that identity on reopen; no manually configured target UUID.
- One selected start mode: a source binlog filename plus the position of the next event at a complete boundary; or the executed source GTID set already represented by the prepared target for the configured scope. The latter is an exclusion set, not the next GTID to set on a target session.
- A prepared target whose schema/data match that boundary. Discover schema internally from target metadata and source table maps; do not require column/key descriptions in production configuration. Explicit include/exclude rules are a separate later feature. If both coordinate forms are provided, they must refer to the same boundary; never substitute a later sample of source state.
- An explicit operator declaration that the target is ready at this boundary. An optional opaque external provisioning reference is useful for diagnostics, but no dump files, hashes, format or loader progress are required inputs.

The operator owns snapshot/load correctness. Startup validates syntax, identities, schema compatibility and available history, and refuses active/connecting native channels or uncertain ownership before target writes. These checks cannot prove that every loaded row matches the asserted boundary. A filtered stream's seed GTID set stays bound to that scope; adding previously omitted data requires another externally established baseline.

For a new local state directory, durably record the supplied baseline without counting it as transactions applied by this process. Capture-only mode must not claim target/applied progress. Clean-stop restart uses its own durable applied checkpoint, falling back to the saved baseline; recovery of unfinished capture/apply work remains planned; initialization must refuse to overwrite it. Source GTIDs live in local state; the replicator does not set target `gtid_purged`. Target apply connections continue using `SET @@SESSION.GTID_NEXT = 'AUTOMATIC'` with OFF_PERMISSIVE/WARN.

A prepared-target handoff may come from a dump/load, an existing stopped replica or another externally verified provisioning method. All use this same input contract. Required history must remain available from the supplied boundary until safely captured; expired history produces a diagnostic requiring external action, never an automatic jump to the current source position or an internal reload.

## MySQL Shell as an external option

MySQL Shell documents parallel dumping, separate DDL/data files and chunked data output. This is a suitable format for the operator's proposed large-instance export workflow. [MySQL Shell dump utilities](https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-shell-utilities-dump-instance-schema.html).

Its metadata contains `gtidExecuted` in `@.json`; the source binlog filename/position are included when the dumping account has `REPLICATION CLIENT`. `showMetadata` exposes the recorded replication coordinates. The operator supplies those snapshot coordinates through the generic replication configuration; any extraction stays outside this repository's production feature scope. [MySQL Shell dump metadata](https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-shell-utilities-load-dump.html).

The exact export/import versions and 8.4-to-5.7 MyISAM load compatibility need separate operational qualification. Merely recording coordinates does not establish a consistent or successfully loaded snapshot. These notes describe the boundary of responsibility, not a new dump/load runbook.

## Next implementation increment

DDL native-default behavior and broader coverage are implemented under
[DDL completeness](DDL_COMPLETENESS.md). Explicit clean-stop resume is now
implemented: `run --config APPLY.json` reopens STOPPED SQLite state, starts from
its applied GTID/position or its saved baseline when no work was applied, and
restores counters/schema history. `--initialize` remains exclusive new-state
creation. Local writer locking, target identity/schema checks and native exclusion
are repeated on resume. Changed JSON start coordinates cannot override SQLite.

BLOCKED state, incomplete work and crash recovery remain future work, as do native
channel adoption and operator skip commands. The broader contracts below describe
those remaining increments; clean-stop resume does not certify target durability
after mysqld/host loss.

## Future first start: stopped native replica

Use a working replica stopped at an established application boundary. Capture the
handoff evidence before removing/reconfiguring any native channel:

1. The operator stops and fences native receiver/applier/coordinator/workers and
   disables automatic native start. Confirm all channels are enumerated and none
   are running or connecting; recheck after acquiring Swift writer ownership.
2. Record source identity, channel, scope/filters, observed target UUID, settings,
   stop time, errors and **executed** upstream boundary. On 5.7, inspect
   `Relay_Master_Log_File` / `Exec_Master_Log_Pos` and the relevant executed GTID
   coverage; on 8.4 use their corresponding SOURCE-named fields. Do not substitute
   `Read_Master_Log_Pos` / `Read_Source_Log_Pos`, `Retrieved_Gtid_Set`, the target's
   own binlog position or the source's current position.
3. Prove no worker gaps or partial failed MyISAM group remain. A stopped SQL thread
   or a GTID in `Executed_Gtid_Set` alone is insufficient: the native error-1837
   fixture already demonstrates partial effects. Exclude unrelated target-local or
   other-channel GTIDs from the supplied source coverage; validate lineage/scope.
4. Supply the verified file/position, GTID set or both through the generic boundary
   input. Persist baseline and handoff provenance atomically without incrementing
   this process's applied counters. Discover the target schema at this boundary.

The planned adoption path may accept retained stopped channels only with this
explicit handoff record and exclusive operational ownership. It never silently
issues STOP/RESET or discards channel credentials/coordinates. The current code is
stricter and rejects **all** retained channels, including stopped ones; changing
that check requires the handoff tests, not simply dropping the guard.

## Future first start: externally loaded MySQL Shell dump

The operator completes and verifies the parallel dump/load externally, then
supplies the coordinates recorded for that snapshot. Accept file/position only,
GTID set only, or both when their correspondence is established. Preserve which
form is authoritative and the external provenance; do not fabricate missing
coordinates or sample new ones from the live source. The MySQL Shell metadata
notes above describe the external source of these values, not a dump parser or
loader to add to the replicator.

Validate source history availability, target identity/schema and ownership before
writing. A supplied baseline is an operator assertion about prepared data; the
replicator cannot infer load completeness from coordinates. Unavailable upstream
history blocks and requires external repair/reseed. Never silently jump forward.

## Subsequent starts: SQLite is authoritative

Ordinary startup with existing state reads its persisted baseline, source/target
identities, scope, schema versions, completed applied checkpoint, cumulative GTID
snapshot plus committed deltas, and pending row/DDL intents. New start arguments
must not overwrite it. Missing/corrupt/incompatible state is an error requiring
explicit handling, not an implicit first start. Target UUID must match the value
previously discovered; a replacement target needs a new external handoff.

Keep received, durably captured, fully applied and explicitly skipped/resolved
coverage separate. Verify pinned relay ranges before replay. Select the reader's
reconnect boundary from validated durable capture/replay availability; the applier
continues from its applied/resolved state and outstanding intents. A GTID exclusion
set must not suppress an incomplete or unaccounted-for group. Missing local bytes
may be fetched again only when the exact source history remains available.

Before any target write, recheck native exclusion and writer ownership. Reconcile
uncertain outstanding DML/DDL outcomes before continuing. A lost SQL response is
not permission to retry a MyISAM mutation; a durable SQLite checkpoint alone does
not establish target durability after mysqld/host loss. Retain the technical plan's
conservative block/validate/reseed policy for those failures. Restart preserves a
permanent diagnostic until explicit resolution.

## Future operator resolution and skipping

Default behavior stays stop, diagnose, retain evidence and await intervention.
Design a local CLI/state-writer operation, not an HTTP mutation API; exact command
syntax remains to be designed. Reject concurrent state mutation by another writer.
Provide a dry-run description of the selected groups and resulting boundary.

| Operation | Planned semantics |
| --- | --- |
| Repair and resume | After an external correction, reconcile the outstanding intent and continue the original group at its known progress; never blindly repeat completed MyISAM writes |
| Mark externally applied | Verify the declared target effects/schema and record the source group as externally resolved, separately from Swift-applied work |
| Skip source GTID/set | Select exact complete source groups in this stream, retaining every affected GTID and reason; never install those GTIDs on the target SQL session |
| Skip source file/offset range | Require matching source lineage and complete group boundaries, not a byte in a row event or the middle of a transaction; record all covered groups |
| Skip selected error types | An explicit, bounded policy keyed by stable MySQL code/SQLSTATE or replicator diagnostic category, with stream/object scope and maximum count/expiry; no default catch-all or error-message substring policy |

Error-type skipping is inspired by Percona's restart tooling, but this replicator
owns its own journal and cannot delegate checkpoint changes to native skip counters.
The Percona documentation describes selective error matching/restart behavior;
MySQL documents different skipping mechanisms for GTID and non-GTID channels.
[Percona pt-replica-restart / pt-slave-restart](https://docs.percona.com/percona-toolkit/pt-replica-restart.html),
[MySQL skipping transactions](https://dev.mysql.com/doc/refman/8.4/en/replication-administration-skip.html).

A skip advances **accounted-for consumption**, not the count/set of transactions
successfully applied by Swift. Keep applied, skipped and externally resolved
outcomes distinct in SQLite. Their validated union with the external baseline can
form the future source exclusion set; never label that union `transactions_applied`.
Pending/partial MyISAM effects must be inspected and resolved before a group can be
skipped. Skipping is not rollback. Exclude storage corruption, unknown framing and
uncertain ownership/outcomes from automatic error-type skip policies. A DDL skip
needs explicit schema reconciliation before following row events can be decoded
and applied safely.

Persist each decision atomically with checkpoint/coverage changes: operator or
policy identity, timestamp, reason, original diagnostic, source identity/GTIDs/
start-end positions, previous/new progress, known partial effects and resolution
evidence. Snapshot skipped/resolved coverage without confusing it with applied
coverage. Keep unresolved records pinned; compact completed audit/history only under
the age-gated storage-pressure policy, preserving coverage and required summaries.
If safe reclamation is impossible, stop before exhausting the storage budget.
Target connections always retain `GTID_NEXT=AUTOMATIC`; source skips are local state,
not injected empty target transactions or changed `gtid_purged`.

## Future recovery acceptance

After the DDL/DML correctness gate, test both first-start sources, both positioning
modes, agreeing/conflicting dual coordinates, stopped-channel adoption and active/
connecting-channel rejection. Test repeat initialization, accidental start overrides,
wrong identities/scope, corrupt state, purged source history and missing relay files.

Inject failures before/after target writes, DDL implicit commits, relay fsync,
SQLite intent/completion/checkpoint commits and lost responses. Prove actual target
rows/schema/binlogs and local progress agree after recovery or that the required
block persists. Include target/host restart separately from replicator process loss.
For every resolution mode, test partial groups, malformed/mid-group offsets, GTID
sets with gaps/wrong lineage, policy limits, failed manual repair and crashes during
audit/checkpoint publication. Following work must neither be lost nor duplicated;
failed resolution retains the block. Expose durable results through SQLite.

## Current implementation

`run --initialize` accepts externally established positional or GTID-only starts,
refuses existing state and all retained native channels, and persists a bounded
relay plus SQLite state/intents. [DML](DML_APPLY.md) and a [narrow DDL prototype](DDL_APPLY.md)
are implemented. Target UUID discovery is implemented. Reopening state, reconnect
recovery, stopped-channel adoption and all resolution/skip operations above remain
future work. An embedded REST server is no longer planned.
