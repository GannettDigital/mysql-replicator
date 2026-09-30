# Schema discovery and bounded state history

Review of the first DML checkpoint (`d188f58`). These are the next changes, not
capabilities of that checkpoint. Remove schema descriptions from production
configuration; retain discovered schema as internal replication state. Filters
are a separate later feature and must not be inferred from schema metadata.

## What the current schema does

`poc.items` is a fixture/example, not a hard-coded production table. However, the
current implementation requires a manually supplied manifest twice:

- `source.tables[].columns` supplies signedness and text/binary interpretation to
  the Rust decoder at each TABLE_MAP event. Other tables are rejected.
- Top-level `tables` provides ordered names/types/nullability/collation and a
  primary key. It validates full row images, selects the target key, constructs
  bound SQL, interprets readback values and checks target information_schema.
- `state.schema_json` saves that manifest for diagnostics and eventual history
  reconstruction; it is not a list of application rows.

Relevant code: `ReplicatorCapture/StreamProcessor.swift`,
`ReplicatorApply/Configuration.swift`, `TargetSession.swift`, and `StateStore.swift`.
The POC is schema-dependent but has no automatic schema discovery/evolution. Its
manual table list also acts as an accidental allowlist; this is not a filtering
implementation and must not become the production interface.

## Selected schema approach

Use source TABLE_MAP metadata together with automatically inspected target
metadata at the externally established replication boundary. Do not require
operators to describe columns or keys in config or maintain a separate schema
manifest for normal replication.

1. Preserve the external prepared-target/known-position-or-GTID contract. The
   operator guarantees that the target represents this boundary. Dump/load and
   validation of the external load remain outside the replicator.
2. Expose validated TABLE_MAP type/length/nullability and optional signedness,
   charset/collation, names and key metadata through the codec ABI. Source wire
   metadata determines how source bytes are interpreted. Qualify MINIMAL and
   FULL metadata; do not require changing the cloud source to FULL by default.
3. On encountering a table, inspect the prepared target's ordered columns,
   types, encoding, keys, engine and unsupported features. Bind this internal
   description to the source table map by ordinal and validate compatibility.
   Use target names and keys to construct SQL. Keep explicit source/target type
   and collation distinctions rather than silently treating them as identical.
   Revalidate the target under the apply lock before mutation.
4. Store discovered descriptions internally with schema version, discovery time,
   source coordinate/table-map fingerprint and provenance. Bind table IDs to a
   specific map/version; IDs alone are not durable schema identities. Reject
   missing, contradictory or unsupported metadata before writes.
5. Do not consult the source's *current* information_schema as the schema of an
   older binlog event: the source may already have executed later DDL. The target
   at the accepted starting boundary is the initial baseline; subsequent schema
   changes must be consumed and applied in binlog order.
6. The DDL increment applies each qualified change, refreshes/versions the target
   description, invalidates old table-map bindings and then decodes/applies later
   DML. Until that increment, DDL continues to stop replication.

The local pinned MySQL 8.4.8 source supports this distinction:
`sql/log_event.cc:11207` initializes signedness and character metadata before the
FULL-only branch; FULL adds column names and primary-key metadata.
`sql/sys_vars.cc:1547` defaults `binlog_row_metadata` to MINIMAL. The current Rust
adapter already checks wire signedness against supplied history but does not yet
expose enough table-map metadata to replace the manifest. Absence of metadata
must be handled explicitly; do not assume every event carries all optional fields.

Introduce a versioned configuration migration. Reject legacy manual schema fields
with a clear message instead of silently ignoring an old allowlist and applying
unexpected tables. Connections, identities, starting boundary, state location and
runtime limits remain configuration. Explicit binlog include/exclude rules can be
added later; discovery metadata itself never decides filtering.

Acceptance: run the DML harness without either schema list; use multiple tables,
different names/column orders, MINIMAL/FULL metadata, signed/unsigned extremes,
text/binary/NULL, map reuse and mismatched/missing target schemas. Preserve strict
failure for unsupported types/shapes. Source-only inspection should use sufficient
wire metadata or fail clearly; explicit historical metadata can remain an offline
fixture/debugging facility, separate from production replication configuration.

## What SQLite currently writes

The singleton `state` row contains `applied_gtids`, overwritten after every fully
verified source group. It is not an appended series of full GTID sets. This row
already has `updated_at`, but that timestamp also changes for lifecycle operations
and is not a dedicated last-applied time.

`groups` and `row_intents` append transaction/row history with no timestamps or
pruning. They retain completed work as well as incomplete work. The framed relay
is also unrotated and bounded by a stop-at-limit policy. These are current POC
limitations, not implemented retention policies.

## Selected checkpoint and retention approach

Separate authoritative applied coverage from bounded history. Do not expire
executed GTIDs by age: losing that coverage can cause already applied MyISAM
operations to be replayed. Do not postpone the durable record of successful apply
until a periodic timer.

- Persist one small applied delta per completed group: ordered local sequence,
  source GTID, source end coordinate, completion time and counter changes. Commit
  it atomically with whole-group completion after every row has been verified.
  Pending row intents still precede mutation and survive until resolved.
- Periodically fold completed deltas into a compact cumulative GTID snapshot,
  with a generation, covered sequence, file/position and snapshot timestamp.
  This avoids serializing/replacing the complete GTID set on every transaction.
  Authoritative progress is the committed snapshot plus subsequent committed
  deltas; in-memory/API progress must describe the same generation/boundary.
- Preserve gaps and source identities when merging GTID intervals. The cumulative
  set includes the externally asserted baseline, without counting it as work
  applied by this process. Record baseline provenance separately.
- Timestamp group creation/completion and row-intent creation/completion; expose
  dedicated `last_applied_at` and checkpoint-snapshot times. Local observation
  time and any available source commit time are separate fields. Time alone is
  never proof of completion or a safe purge boundary.
- Rotate/prune historical snapshots, completed journal records and diagnostics
  using configurable age and count/size limits. Publish a durable covering
  snapshot before deleting covered deltas. Always retain the authoritative
  current coverage and any references still needed by outstanding work.
- Never purge incomplete/uncertain intents, their relay bytes, required schema
  versions, or pinned error evidence. Relay segment retention follows those same
  references. On space pressure with no safe eviction, stop/block rather than
  discard required state. Ordinary history may expire; unresolved work may not.
- Use bounded SQLite pruning and WAL checkpoint/space-reuse maintenance. Do not
  periodically replace a live SQLite database file as a substitute for semantic
  retention. Segment rotation, snapshot compaction and SQLite WAL checkpointing
  are different operations.

Acceptance: after many groups the retained completed history remains bounded;
folding/pruning preserves the exact applied GTID set, end coordinate and counters;
pending/failed groups and their schema/relay references stay pinned; timestamps
identify actual application and snapshot times. A simulated interrupted compaction
must leave a committed snapshot-plus-delta representation. This metadata check
is not permission to retry uncertain MyISAM writes.

## Sequence

Next: automatic metadata discovery for the existing DML subset, without schema
in config. Add timestamped checkpoint/history compaction as a bounded-state
increment. Continue with ordered DDL and schema-cache evolution. Full target
crash/reconnect recovery remains after DML and DDL correctness; filtering and REST
remain separate later work. None of these changes brings dump/load into scope.
