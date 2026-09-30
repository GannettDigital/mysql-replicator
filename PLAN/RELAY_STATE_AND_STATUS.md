# Local binlog files, SQLite state and runtime status

## Accepted storage split

Raw binlog events belong in local relay/binlog files, **not SQLite BLOB rows**. SQLite stores replication state and indexes into those files, historical schema, externally supplied start-boundary provenance, pending MyISAM/DDL recovery intents, diagnostics and statistics. This supersedes the earlier proposal to put the entire raw event stream in SQLite. The first DML checkpoint implements a bounded framed relay and minimum SQLite state/intents. SQLite history now has timestamped, pressure-triggered retention; relay segmentation/rotation and reopening/recovery remain unimplemented. The planned embedded REST server is removed in favor of external SQLite readers.

Use one state directory and supervised process per source/target pair initially. Keep source history identity separate from a source filename, which may be reused after reset or source replacement. A relay location identifies a local segment, byte range and digest; source coordinates identify the upstream file/position and GTID. They must not be conflated: GTID dump startup may begin within a source file and may include artificial protocol events. Phase 2 must define and test the local segment format and coordinate mapping before live resume. Store original event frames without rewriting their headers; keep transport-only pseudo-events separate from source progress. Complete downloaded source files can be inspected directly with the existing offline inspector.

## External initialization

Dump/load and target provisioning are completely external. Accept a prepared target and known file/position or executed GTID set with matching identity, scope and historical schema; see [the start-boundary contract](START_BOUNDARY.md). SQLite records this supplied baseline and replication progress, not dump contents or load progress. Capture-only state never claims an applied target checkpoint. Initializing existing state must fail; the future ordinary restart path uses its durable checkpoint, with pending intent reconciliation before further writes.

## SQLite metadata

Persist at least:

- Stream/source/target identities, configuration and filter scope, externally supplied baseline, schema versions and state schema version.
- Stream lifecycle state (`STARTING`, `RUNNING`, `RECONNECTING`, `BLOCKED`, `STOPPED`), separate capture/apply status, last transition/update times and durable diagnostic references.
- Received position for observation; durable relay byte ranges and complete captured transaction boundary/GTID set for recovery; fully applied source file/position and GTID set; current transaction and outstanding row/DDL intent. An incomplete transaction never enters the completed GTID set. Received-only progress must be labelled volatile.
- Relay manifest: segment identity, source history/coordinate range, durable length, validation/checksum information, transaction completeness and retention pins. Index transactions/events only as needed to locate bytes; do not duplicate event payloads or every decoded row in SQLite.
- Last receive, durable capture and apply times, counter snapshots, source/apply error history, disconnect/reconnect diagnostics and explicit human resume history.

For MyISAM, retain the accepted write-ahead row-intent protocol. An intent references pinned relay bytes, schema version, transaction/row ordinal, target identity and the expected mutation/reconciliation state. Reconstruct row images from the retained bytes where practical; persist only the additional key/expected-state information needed for reliable recovery. This journal is replication state, not a second event store. Its referenced bytes cannot be purged while the intent or a repair diagnostic needs them. Applied source GTIDs advance only after all required row operations have been verified, independently of target-local GTIDs.

## Timestamped checkpoints and retained history

The implementation records durable per-group GTID deltas and periodically compacts
cumulative snapshots. Creation/completion/last-applied/snapshot timestamps support
inspection. Cleanup deletes only covered completed history older than the configured
minimum age when storage approaches its limit; it is not unconditional time-based
expiry. Pending intents, current schema and referenced history stay pinned.

Never expire cumulative coverage. Snapshot publication precedes pruning covered
deltas; current progress is snapshot plus subsequent committed deltas. Bound the
database plus WAL, with a separate relay budget. If old enough safe-to-delete data
cannot relieve pressure, stop with a diagnostic rather than remove pending work.
Deletion makes pages reusable and need not shrink the main file. Do not rotate the
live SQLite database in place or delay durable group completion until a stats timer.
See [implemented limits and checks](SCHEMA_DISCOVERY_AND_RETENTION.md).
Future skip/resolution coverage requires the same bounded design and separate outcome
accounting, as specified in [the recovery plan](START_BOUNDARY.md).

## Durability across files and SQLite

SQLite cannot atomically commit an ordinary file append. Enforce this order:

1. Append framing/checksum-validated, bounded event frames to the owned relay segment, recording source-to-local positions. Large transactions can span bounded capture batches without being marked complete.
2. Synchronize the required file data; synchronize directory entries when creating/publishing segments. Only then commit the referenced durable lengths, transaction-completeness indexes and safe capture progress in SQLite (`WAL`, `synchronous=FULL`).
3. Publish durable progress to the decoder/applier and status snapshot only after that metadata commit. Progress must never reference bytes not yet durable. The applied checkpoint remains a separate operation governed by the MyISAM recovery journal.

After restart, verify the manifest and referenced file ranges before trusting capture progress. A complete or torn tail beyond SQLite's committed durable length is unacknowledged data: validate and explicitly recover it or truncate it and refetch from the recorded boundary. Never blindly treat file length as committed progress. Missing, short or corrupt referenced segments require re-download and verification against the same source history, or a visible blocked/reseed path. Do not move the applied checkpoint backward or replay an uncertain target mutation merely because a local file was lost.

Re-download is available only while the source retains the required binlogs/GTIDs and compatible history. Test purged history and changed source lineage explicitly. Losing unapplied local bytes does not imply data loss if an exact source replay is still possible; source retention is still a finite recovery dependency. GTID reconnect must include incomplete transactions again and distinguish captured-complete from applied-complete sets.

Purge only segments no longer required by the chosen replay window, unapplied work, outstanding intents, schema reconstruction or pinned diagnostics. Use a recoverable metadata/tombstone and file-unlink ordering so a crash cannot leave an active manifest referring to a deliberately deleted file. Bound relay space independently of the small SQLite database/WAL; disk pressure applies backpressure and never evicts unapplied data.

## Statistics and external SQLite readers

Persist status, diagnostic history and counter snapshots in SQLite. Operators and
external monitoring can read them with SQLite tools; no embedded HTTP/REST server
or web interface is required. A future local `status --json` command may provide a
convenient read-only view, but direct database access is sufficient. This decision
supersedes the earlier endpoint/service-mode design. On a permanent failure, record
BLOCKED and exit nonzero; the persisted record stays inspectable after exit.

Define a versioned read contract (documented tables or stable views) before external
monitoring depends on internal schemas. Proposed records, not implemented view names:

| Record | Required information |
| --- | --- |
| Status snapshot | Stream identities/scope/version, process epoch, lifecycle, snapshot/update times, received/durable/applied coordinates and GTID coverage, pending intent, last error and source/target connection state |
| Counter snapshot | Transactions/rows/DDL durably applied, bytes/events received, unique bytes/events captured, replay bytes, disconnects, reconnect attempts/successes, decode/apply errors and separate skip/external-resolution counts |
| Storage/lag snapshot | SQLite main/WAL usage, relay size/pins, oldest retained work, checkpoint pressure, lag observations and observation age; unknown/stale values stay explicit |
| Diagnostics/resolutions | Stable ID/order, timestamps, category/code, source coordinate/GTID, partial progress and operator/policy outcome, without credentials or application row values by default |

Exact completed-group/row/DDL counters commit with the applied checkpoint. Network
and other high-frequency diagnostic counters accumulate in memory and periodically
persist as a coherent generation. `bytes_received` includes retransmission attempts;
unique durable bytes do not. Reconnect attempts and successes are separate. Persist
process epoch, observation/persistence times and heartbeat age so monitoring can
handle restarts and stale records. A last RUNNING record after process loss is not
proof of liveness; use supervisor/process observations as well. Statistics never
control recovery or advance applied progress.

Use short read-only transactions against a local SQLite WAL database, and close
cursors promptly. Do not open a changing database as `immutable=1`, copy only its
main file while WAL is active, or put live WAL access on a network filesystem.
For off-host/offline readers use a consistent SQLite backup/export. Existing hard
storage limits remain authoritative: long readers can prevent WAL recycling, so
qualify bounded monitoring queries, busy/checkpoint handling and safe backpressure/
stop when the limit cannot be maintained. Do not promise arbitrary external readers
cannot impede checkpointing. [SQLite WAL readers and checkpointing](https://www.sqlite.org/wal.html).

Keep a bounded current snapshot and age-gated, pressure-cleaned diagnostic/history
records, not an unbounded row per stats sample. Document refresh intervals and units;
compute rates from timestamped snapshots and label stale/unknown lag. If SQLite is
unwritable, stderr/system logs report the failure; a stale SQLite row must not be
presented as a newly persisted diagnostic.

Current code already persists applied-group/row/DDL counts, checkpoints, timestamps
and diagnostics. The complete read contract and broader counter/heartbeat snapshots
above are planned work, not existing monitoring APIs.

## Phase integration and acceptance

- **First DML increment (Phase 2/3 interleaved):** implement the serial INSERT/UPDATE/DELETE applier and the minimum file relay/SQLite baseline, row intents, diagnostic and applied-checkpoint support it requires. Verify actual 5.7 MyISAM rows and binlog effects against source intent and the native reference. Preserve the storage ordering above; stop on uncertain/interrupted apply until recovery is qualified.
- **Second DDL increment:** add ordered schema-change application, historical schema updates and DDL intent/boundary records. Remove forced engine/collation rewrites and verify native-compatible DDL and DDL immediately followed by DML against actual schemas, rows and binlogs. Unsupported DDL stops without guessing; no automatic recovery claim yet.
- **Third increment, after DML and DDL correctness are solid:** implement and qualify recovery; test relay append/fsync/metadata-commit windows together with crashes around target writes, lost SQL responses, partial transactions, interrupted DDL/implicit commits, applied-checkpoint commits and target restart. Verify reconciliation or the required durable block, including actual target effects. Capture-only replay tests do not establish application recovery.
- **Runtime visibility:** document and extend SQLite status/statistics/diagnostics for external readers. Preserve separate received/durable/applied and operator-resolved progress. Qualify monitoring-reader impact on WAL retention and the storage cap; no embedded server is required.
- **Phase 5:** measure append/fsync and metadata-commit latency separately; qualify disk limits/retention, snapshot counter overhead and slow external SQLite readers on the fleet resource profiles.

Required fault cases include crashes during append, after file fsync but before SQLite commit, after metadata commit, during rotation/publication and during purge; partial local frames, SQLite I/O/full/corruption, missing segment with successful re-download, purged upstream history, and source-history mismatch. Tests must prove that no durable pointer moves ahead of durable bytes, no incomplete GTID is excluded on reconnect, no counter advances applied progress, and reader-induced WAL pressure remains bounded or causes an explicit safe stop. Preserve relay manifest/files and a consistent SQLite state export as harness evidence.
