# Local binlog files, SQLite state and runtime status

## Accepted storage split

Raw binlog events belong in local relay/binlog files, **not SQLite BLOB rows**. SQLite stores replication state and indexes into those files, historical schema, externally supplied start-boundary provenance, pending MyISAM/DDL recovery intents, diagnostics and statistics. This supersedes the earlier proposal to put the entire raw event stream in SQLite. The existing packaging probe qualifies SQLite durability primitives only; the production file relay, state store and REST API are not implemented yet.

Use one state directory and supervised process per source/target pair initially. Keep source history identity separate from a source filename, which may be reused after reset or source replacement. A relay location identifies a local segment, byte range and digest; source coordinates identify the upstream file/position and GTID. They must not be conflated: GTID dump startup may begin within a source file and may include artificial protocol events. Phase 2 must define and test the local segment format and coordinate mapping before live resume. Store original event frames without rewriting their headers; keep transport-only pseudo-events separate from source progress. Complete downloaded source files can be inspected directly with the existing offline inspector.

## External initialization

Dump/load and target provisioning are completely external. Accept a prepared target and known file/position or executed GTID set with matching identity, scope and historical schema; see [the start-boundary contract](START_BOUNDARY.md). SQLite records this supplied baseline and replication progress, not dump contents or load progress. Capture-only state never claims an applied target checkpoint. Initializing existing state must fail; ordinary restart uses its durable checkpoint.

## SQLite metadata

Persist at least:

- Stream/source/target identities, configuration and filter scope, externally supplied baseline, schema versions and state schema version.
- Stream lifecycle state (`STARTING`, `RUNNING`, `RECONNECTING`, `BLOCKED`, `STOPPED`), separate capture/apply status, last transition/update times and durable diagnostic references.
- Received position for observation; durable relay byte ranges and complete captured transaction boundary/GTID set for recovery; fully applied source file/position and GTID set; current transaction and outstanding row/DDL intent. An incomplete transaction never enters the completed GTID set. Received-only progress must be labelled volatile.
- Relay manifest: segment identity, source history/coordinate range, durable length, validation/checksum information, transaction completeness and retention pins. Index transactions/events only as needed to locate bytes; do not duplicate event payloads or every decoded row in SQLite.
- Last receive, durable capture and apply times, counter snapshots, source/apply error history, disconnect/reconnect diagnostics and explicit human resume history.

For MyISAM, retain the accepted write-ahead row-intent protocol. An intent references pinned relay bytes, schema version, transaction/row ordinal, target identity and the expected mutation/reconciliation state. Reconstruct row images from the retained bytes where practical; persist only the additional key/expected-state information needed for reliable recovery. This journal is replication state, not a second event store. Its referenced bytes cannot be purged while the intent or a repair diagnostic needs them. Applied source GTIDs advance only after all required row operations have been verified, independently of target-local GTIDs.

## Durability across files and SQLite

SQLite cannot atomically commit an ordinary file append. Enforce this order:

1. Append framing/checksum-validated, bounded event frames to the owned relay segment, recording source-to-local positions. Large transactions can span bounded capture batches without being marked complete.
2. Synchronize the required file data; synchronize directory entries when creating/publishing segments. Only then commit the referenced durable lengths, transaction-completeness indexes and safe capture progress in SQLite (`WAL`, `synchronous=FULL`).
3. Publish durable progress to the decoder/applier and status snapshot only after that metadata commit. Progress must never reference bytes not yet durable. The applied checkpoint remains a separate operation governed by the MyISAM recovery journal.

After restart, verify the manifest and referenced file ranges before trusting capture progress. A complete or torn tail beyond SQLite's committed durable length is unacknowledged data: validate and explicitly recover it or truncate it and refetch from the recorded boundary. Never blindly treat file length as committed progress. Missing, short or corrupt referenced segments require re-download and verification against the same source history, or a visible blocked/reseed path. Do not move the applied checkpoint backward or replay an uncertain target mutation merely because a local file was lost.

Re-download is available only while the source retains the required binlogs/GTIDs and compatible history. Test purged history and changed source lineage explicitly. Losing unapplied local bytes does not imply data loss if an exact source replay is still possible; source retention is still a finite recovery dependency. GTID reconnect must include incomplete transactions again and distinguish captured-complete from applied-complete sets.

Purge only segments no longer required by the chosen replay window, unapplied work, outstanding intents, schema reconstruction or pinned diagnostics. Use a recoverable metadata/tombstone and file-unlink ordering so a crash cannot leave an active manifest referring to a deliberately deleted file. Bound relay space independently of the small SQLite database/WAL; disk pressure applies backpressure and never evicts unapplied data.

## Statistics and read-only REST API

Expose the running replicator's in-process view through a versioned JSON REST API using the existing SwiftNIO stack. Do not require clients to open or poll the live SQLite file. Default to loopback binding; remote access must be explicitly configured with authentication and TLS (directly or through an authenticated reverse proxy). Keep resume/skip/mutation operations out of this first read-only API. In service mode, a permanent error stops capture/apply workers and leaves the read-only server available with durable BLOCKED status; non-service runs retain the dedicated nonzero failure exit. Keeping status alive must never restart or skip blocked work.

| Endpoint | Required information |
| --- | --- |
| `GET /v1/status` | Stream identities/scope, role, process epoch/version, lifecycle and capture/apply state, snapshot/update time, received/durable/applied coordinates and GTID sets, pending transaction/intent, lag observations with timestamps, relay usage/retention, last error and disconnect/reconnect state |
| `GET /v1/stats` | Transactions/rows durably applied, bytes/events received, unique bytes/events durably captured, replay bytes, reconnect attempts/successes, disconnects, decode/apply errors, relay bytes, and receive/capture/apply rates |
| `GET /v1/diagnostics?after=ID&limit=N` | Bounded, stable-order diagnostics with timestamps, category/code, source coordinate/GTID, transaction/row progress and repair state; no credentials or raw application row values by default |
| `GET /health/live` | Process/server responsiveness |
| `GET /health/ready` | Readiness for the configured role; startup, blocked and unrecovered states are not ready. A connected source socket alone is insufficient |

Define counters before implementation: `bytes_received` includes replay/network attempts and is distinct from unique durable bytes; `transactions_applied` counts fully verified source groups once, not SQL attempts or partial rows. Keep reconnect attempts separate from successful reconnects. Exact completed-transaction counters can be updated with the applied checkpoint; high-frequency network counters stay in memory and are periodically snapshotted to SQLite. Expose process epoch, snapshot time and persistence time so consumers can distinguish current values, reset rates and potentially lost recent diagnostic counts after a crash. Statistics never drive recovery decisions.

Return an internally consistent status generation. Label volatile received progress, durable capture progress and applied progress explicitly. Use short SQLite read transactions or cached immutable snapshots; a slow HTTP client must not retain a WAL reader or block capture/application. Bound response size, diagnostic history/page size and request time. Lag estimates must show their observation age and be unknown/stale when appropriate rather than claiming zero during disconnects. Error reporting must still reach stderr/system logs and the live status view if SQLite itself cannot be written.

## Phase integration and acceptance

- **First DML increment (Phase 2/3 interleaved):** implement the serial INSERT/UPDATE/DELETE applier and the minimum file relay/SQLite baseline, row intents, diagnostic and applied-checkpoint support it requires. Verify actual 5.7 MyISAM rows and binlog effects against source intent and the native reference. Preserve the storage ordering above; stop on uncertain/interrupted apply until recovery is qualified.
- **Second DDL increment:** add ordered schema-change application, historical schema updates and DDL intent/boundary records. Verify supported schema transformations and DDL immediately followed by DML against actual schemas, rows and binlogs. Unsupported DDL stops without guessing; no automatic recovery claim yet.
- **Third increment, after DML and DDL correctness are solid:** implement and qualify recovery; test relay append/fsync/metadata-commit windows together with crashes around target writes, lost SQL responses, partial transactions, interrupted DDL/implicit commits, applied-checkpoint commits and target restart. Verify reconciliation or the required durable block, including actual target effects. Capture-only replay tests do not establish application recovery.
- **Runtime visibility:** add coherent read-only REST status/stats/diagnostics after capture/apply state exists. Expose separate received/durable/applied progress, outstanding intents and blocked/resume history. REST implementation is not a prerequisite for the first applier; prove concurrent readers cannot impede replication when adding it.
- **Phase 5:** measure append/fsync and metadata-commit latency separately; qualify disk limits/retention, snapshot counter overhead and slow/disconnected REST clients on the fleet resource profiles.

Required fault cases include crashes during append, after file fsync but before SQLite commit, after metadata commit, during rotation/publication and during purge; partial local frames, SQLite I/O/full/corruption, missing segment with successful re-download, purged upstream history, and source-history mismatch. Tests must prove that no durable pointer moves ahead of durable bytes, no incomplete GTID is excluded on reconnect, no counter advances applied progress, and no HTTP reader holds storage resources while stalled. Preserve relay manifest/files and a consistent SQLite state export as harness evidence.
