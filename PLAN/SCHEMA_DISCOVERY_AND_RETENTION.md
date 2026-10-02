# Schema discovery and bounded state history

Implementation following the first DML checkpoint (`d188f58`). Version 2 apply
configuration removes manual schema lists. Discovered schema remains internal
state. SQLite history is timestamped and pruned by minimum age only under storage
pressure. Explicit wildcard exclusions are now implemented separately; see [filtering](WILDCARD_FILTERS.md). Discovery never implies filtering.

## What the reviewed checkpoint required

`poc.items` is a fixture/example, not a hard-coded production table. However, the
reviewed implementation required a manually supplied manifest twice:

- `source.tables[].columns` supplies signedness and text/binary interpretation to
  the Rust decoder at each TABLE_MAP event. Other tables are rejected.
- Top-level `tables` provides ordered names/types/nullability/collation and a
  primary key. It validates full row images, selects the target key, constructs
  bound SQL, interprets readback values and checks target information_schema.
- `state.schema_json` saves that manifest for diagnostics and eventual history
  reconstruction; it is not a list of application rows.

Relevant code: `ReplicatorCapture/StreamProcessor.swift`,
`ReplicatorApply/Configuration.swift`, `TargetSession.swift`, and `StateStore.swift`.
That checkpoint had no automatic schema discovery/evolution. Its
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
`sql/sys_vars.cc:1547` defaults `binlog_row_metadata` to MINIMAL. The Rust
adapter now exposes this metadata through ABI 4 and event JSON schema 3. Absence of metadata
must be handled explicitly; do not assume every event carries all optional fields.

Introduce a versioned configuration migration. Reject legacy manual schema fields
with a clear message instead of silently ignoring an old allowlist and applying
unexpected tables. Connections, identities, starting boundary, state location and
runtime limits remain configuration. Explicit wildcard exclusions now use `replicateWildIgnoreTable`; see
[filtering](WILDCARD_FILTERS.md). Discovery metadata itself never decides filtering.

Acceptance: run the DML harness without either schema list; use multiple tables,
different names/column orders, MINIMAL/FULL metadata, signed/unsigned extremes,
text/binary/NULL, map reuse and mismatched/missing target schemas. Preserve strict
failure for unsupported types/shapes. Source-only inspection should use sufficient
wire metadata or fail clearly; explicit historical metadata can remain an offline
fixture/debugging facility, separate from production replication configuration.

## What the reviewed SQLite checkpoint wrote

The singleton `state` row contains `applied_gtids`, overwritten after every fully
verified source group. It is not an appended series of full GTID sets. This row
already has `updated_at`, but that timestamp also changes for lifecycle operations
and is not a dedicated last-applied time.

`groups` and `row_intents` append transaction/row history with no timestamps or
pruning. They retain completed work as well as incomplete work. The framed relay
is also unrotated and bounded by a stop-at-limit policy. Those were limitations of the reviewed checkpoint.

## Selected checkpoint and retention approach

Separate authoritative applied coverage from bounded history. Do not expire
executed GTIDs by age: losing that coverage can cause already applied MyISAM
operations to be replayed. Do not postpone the durable record of successful apply
until a periodic timer.

- Persist one small applied delta per completed group: ordered local sequence,
  source GTID, source end coordinate, completion time and counter changes. Commit
  it atomically with whole-group completion after every row has been acknowledged
  by the target with the expected affected-row count.
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
- When storage approaches its configured limit, prune historical snapshots and
  completed journal records older than a configurable minimum age. Age alone
  does not trigger cleanup, and young records are not evicted to stay running.
  Publish a durable covering snapshot before deleting covered deltas. Always
  retain current coverage and outstanding work. If eligible history cannot
  release sufficient space, stop with a storage-pressure diagnostic.
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

## Implemented discovery contract

Apply config and nested source config require `version: 2`, without `tables`.
Legacy version/schema lists fail validation; remove them only after acknowledging
that this is no longer a table allowlist. Source-only debug inspection still
accepts version 1 explicit history; version 2 resolves sufficient wire metadata.
Offline fixture manifests remain independent from production configuration.

Source MINIMAL metadata supplies types, lengths, signedness and encoding; FULL
also supplies names and keys, which are checked when present. Missing required
interpretations and duplicate/conflicting metadata fail before target writes.
Names and keys absent under MINIMAL rely on the externally prepared target's
matching column order. This cannot independently certify a load or detect a
preexisting permutation of indistinguishable columns.

The initial cache is bounded to 64 tables, 256 columns each. Each first discovery
records source coordinate, table-map hash, discovery time, target description and
wire description in `schemas`; row intents reference its ID. Repeated maps are
validated against that description. The subsequent [DDL increment](DDL_APPLY.md) adds ordered versions for its strict
subset; other schema changes still stop the stream.

Supported wire text collations are 45, 46, 224 and 255 (utf8mb4, including 8.4's
0900 default). The target uses its supported legacy utf8mb4 collation. They are
recorded separately, not asserted to have identical sorting semantics. This
compatibility is limited to the current subset: integer primary-key predicates,
no text indexes, and source-computed values applied and verified byte for byte.
Text predicates, indexes and richer schema behavior require separate qualification.
This describes the existing DML-only subset, not permission to rewrite new DDL.
The [charset/default-resolution follow-up](DDL_COMPLETENESS.md#character-sets-event-context-and-native-default-resolution)
removes hard-coded utf8mb4, adds typed query context and historical database/table/
column charset discovery, and qualifies inheritance against native MySQL. Event
metadata and historically resolved defaults must agree; missing metadata never
means guessing the charset or reading a later source schema.

## Storage policy

The optional `storage` object accepts these defaults:

| Setting | Default | Meaning |
| --- | ---: | --- |
| `maximumSQLiteBytes` | 268435456 | Total budget for DB, WAL and SHM; 8 MiB–1 GiB |
| `minimumFreeDiskBytes` | 536870912 | Disk reserve, plus working headroom checked before writes |
| `pruneAtPercent` | 80 | Trigger as occupied main-database pages approach their budget |
| `historyRetentionSeconds` | 86400 | Minimum age before completed history is eligible |
| `snapshotEveryTransactions` | 1000 | Periodic cumulative GTID snapshot cadence |
| `capacityCheckEveryTransactions` | 1000 | Full capacity inspection after this many completed groups; 1–10000 |
| `capacityCheckIntervalSeconds` | 5 | Maximum inspection age while work continues; 1–60 seconds |

The main database receives roughly one third of the total budget. Remaining
space bounds WAL growth and maintenance; `max_page_count` is a separate hard
limit, with cache spilling disabled. Cleanup also starts when disk free space
approaches the reserve plus two SQLite budgets; writes stop before falling below
the reserve plus one SQLite budget. These are conservative POC limits.

Full inspections sample filesystem free space, physical SQLite sizes and occupied
pages at the transaction or time interval, whichever comes first. Between them,
relay bytes are charged against sampled headroom and SQLite's entire budget is
reserved. A WAL commit hook tracks frames in memory; estimated page growth or
reduced disk headroom triggers earlier inspection. Near pressure, inspections
occur before each write. Each write still enforces the cheap WAL/reserve bound,
including within unfinished source groups. WAL checkpoints remain size-triggered;
neither capacity caching nor the hook changes FULL commit durability. The timer
is checked on activity, not by a background thread. External disk use can only be
detected at the next inspection or I/O failure.

Each completed group durably records one GTID delta, its end coordinate and
completion timestamp with the counters. `last_applied_at` is distinct from lifecycle
`updated_at`. Read authoritative coverage as the latest snapshot plus subsequent
APPLIED groups, not a potentially stale snapshot alone. No full GTID set is
rewritten per group. Snapshots occur at cadence, pressure cleanup and clean stop.

Cleanup commits a covering snapshot first, then deletes eligible APPLIED groups
and their intents in batches of up to 128, and older superseded snapshots. Pending
groups/intents and current schema records remain pinned. Incremental vacuum and
WAL truncation reclaim space; a blocked WAL checkpoint causes a diagnostic stop.
Young or pinned history can cause a budget stop instead of deletion. If SQLite
cannot record a failure, stderr remains the diagnostic fallback. Other processes
can still consume disk unexpectedly; I/O/full errors are fatal, never success.

The reviewed checkpoint uses SQLite schema version 2; the [DDL follow-up](DDL_APPLY.md)
uses version 4 with retired table-schema versions, DDL intents and separate
`ddl_intents.database_json` metadata for database creation. Database intents do
not create table-schema rows. Existing state directories are not migrated or
resumed by this slice. Inspect `schemas`, `groups`, `row_intents`, `snapshots`
and the singleton `state`. Old state is never migrated or reopened by this POC.
The raw `relay.frames` file still has its independent stop-at-limit budget (default
256 MiB); segment rotation and re-download are later work. No target recovery or
uncertain-write retry is introduced by metadata compaction.

## Validation and next work

`make test` covers wire metadata across the ABI, malformed/conflicting metadata,
pressure/age gating, pinned intents, exact retained GTID coverage and budget stops.
`make test-asan` checks Swift/C result ownership; Rust is not sanitizer-instrumented.
`make dml-suite` uses schema-free version 2 config, MINIMAL/FULL source metadata,
multiple discovered tables with non-leading keys, exact values and absent or
incompatible targets, alongside the existing native/data/binlog comparisons.

Continue with [native-compatible DDL completeness](DDL_COMPLETENESS.md): remove
forced engine/collation rewrites, broaden schema-cache evolution and test following
DML. Full target crash/reconnect recovery and explicit skip/resolution follow those
correctness gates. Filtering remains later work. External SQLite readers replace
the planned REST service; broader statistics must share the bounded storage policy.
Dump/load management remains external.

Recorded validation (2026-09-29/30): 75 Swift tests pass with Swift/C/CLI
AddressSanitizer (Rust uninstrumented), and the Rust panic-containment test passes.
The filtered macOS sanitizer runner hit a platform loader restriction; the full
suite passed. Both Docker DML cases and cleanup passed:

- `20260930T062958Z-e863299a-position-autocommit-myisam` (MINIMAL, file/position).
- `20260930T063110Z-162d6b40-auto-autocommit-myisam` (FULL, GTID plus discovery/error cases).

Evidence is retained under `artifacts/dml-suite/`; test/build logs are under
`artifacts/schema-retention-validation/`. No performance or crash/recovery
qualification is implied.
