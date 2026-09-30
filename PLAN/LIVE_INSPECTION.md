# Live binlog inspection

The first live increment adds one verified-TLS MySQL 8.4 connection and JSON
inspection. It performs no target writes, relay-file persistence, SQLite writes,
automatic reconnect or REST serving. Completion is volatile observation, never
an applied or durable checkpoint. Phase 1 remains in progress.

## Run and review

Build with `make build`, then run:

```sh
.build/debug/mysql-replicator inspect --source-config source.json --transactions
```

Set the password through the environment variable named by `passwordEnvironment`.
The JSON configuration below is illustrative: replace the UUID, binlog boundary,
GTID set and column interpretations with metadata from the **same verified seed
boundary**. The tool does not establish that seed or validate its snapshot.

```json
{
  "version": 1,
  "host": "source.example.internal",
  "port": 3306,
  "username": "capture",
  "passwordEnvironment": "REPLICATOR_SOURCE_PASSWORD",
  "serverHostname": "source.example.internal",
  "caFile": "/absolute/path/source-ca.pem",
  "serverID": 9001,
  "sourceUUID": "00000000-0000-0000-0000-000000000001",
  "mode": "file-position",
  "start": {
    "file": "binlog.000003",
    "position": 1589,
    "executedGTIDs": "00000000-0000-0000-0000-000000000001:1-10"
  },
  "tables": [{"database": "poc", "table": "items", "columns": ["signed", "utf8", "unsigned"]}],
  "idleTimeoutSeconds": 15,
  "maximumEventBytes": 4194304,
  "nonBlocking": false,
  "stopAfterTransactions": 4
}
```

`mode: "gtid"` sends COM_BINLOG_DUMP_GTID with the supplied executed set. The source
selects a file; the supplied file/position still bounds the historical schema
window. File-position mode sends COM_BINLOG_DUMP and checks the source's announced
start exactly. Use a nonzero client server ID distinct from the source and other
active readers. Untagged GTIDs only; bounds are 64 SIDs, 4096 intervals per SID
and 1 MiB of text. UUIDs and intervals are canonicalized and merged.

Omit `stopAfterTransactions` to follow indefinitely; `nonBlocking: true` ends when
the source reports EOF. Heartbeats keep an idle stream alive. SIGINT/SIGTERM,
transport errors, malformed events, unsupported SQL/schema, incomplete EOF and
missing/purged history stop with a nonzero exit and JSON diagnostics on stderr.
The optional count stops only after a complete group. Reconnect/replay is an
explicit new invocation. Output can repeat across invocations; it is not a
persistent delivery protocol.

`--transactions` prints the same complete-group JSON as offline inspection.
Without it, live envelopes distinguish `rotationAnnouncement`, `formatContext`,
`heartbeat` and physical `event` records. `observedPosition` is a source coordinate;
the format-context event's offset describes synthetic decoder context, not a
physical replay boundary. `--include-raw` includes original bytes. Event mode can
show partial transactions before failure; only transaction mode withholds partial
groups. Summary/error progress includes event bytes, events, transactions,
heartbeats, announcements, a last complete boundary and any pending start.
`completeGTIDSet` is the caller's seed set plus fully observed groups, **not** an
applied GTID set. `durableProgress` is always false. Preamble/rotation coordinates
can also be complete boundaries; a skipped-range heartbeat never adds a GTID or
advances the last complete boundary.

## Qualified contract and implementation

The source preflight requires the expected UUID, MySQL 8.4, GTID ON/consistency ON,
ROW, FULL and CRC32, plus coverage of the supplied seed GTID set. TLS verifies CA
and hostname; omitting `caFile` uses system trust (configure a CA explicitly for
the minimal Ubuntu image). A vendored, pinned MySQLNIO patch refuses a server
without SSL capability **before authentication** and bounds handshake time.
See [vendor provenance](../Vendor/mysql-nio/README.replicator.md). TCP connect,
handshake and metadata commands have ten-second limits. DNS uses the system
resolver; it is not yet independently cancellable.

The NIO reader validates packet sequence numbers including wraparound, assembles
0xffffff-byte continuations and checks allocation limits before reading bodies.
Socket reads are paced by a bounded consumer queue. Decode/output happens off the
NIO event loop. Event limit defaults to 4 MiB (maximum 16 MiB); queue capacity is
that limit plus 256 KiB and at most 4096 pending packets. Transaction limits remain
4096 events, 16 MiB wire and 32 MiB retained data. These are safety bounds, not a
throughput qualification.

Transport pseudo-events have separate CRC/header validation. Synthetic rotation
and format descriptions never enter the physical transaction assembler. Real
rotation requires the matching next announcement and a fresh format context.
GTID exclusion can create gaps: only checksum-verified source heartbeats may
advance an idle GTID stream across them. The Rust decoder sees contiguous bytes
actually delivered; emitted physical events retain their source positions,
original headers and hashes. Missing bytes in positional mode are an error.

The manifest supplies historical signedness/encoding for each named table. Each
map is probed with the same Rust decoder and bound to its actual identity/hash;
there is no second Swift row decoder and no query against potentially newer
information_schema. This temporarily adds a small decoder allocation per map.
Every DDL/non-control query stops the live window. The first included GTID must
not precede the bootstrap boundary. Unsupported types/events retain the offline
codec's fail-closed behavior. Schema migration, source failover/lineage changes,
tagged GTIDs and production Cloud SQL connectivity remain unqualified.

Protocol references are local MySQL 8.4.8 at
`0896fcd61dec11a0904166911a0126f59daaa1bf` in ignored `.upstream/mysql-server`:
`sql/rpl_source.cc` (dump command fields), `sql/rpl_binlog_sender.cc`
(fake rotation, dump FDE rewrite, exclusion heartbeat, physical rotation and EOF).
The network implementation remains native Swift/NIO; Rust remains the decoder ABI.

## Harness and review points

```sh
make test
make live-suite
# Reuse an image built from this exact checkout:
make live-suite ARGS=--skip-build
```

The live suite builds the static x86_64 CLI, runs it in Ubuntu 16.04 userland and
uses three disposable MySQL servers: 8.4 InnoDB source, 8.4 native MyISAM replica
and an unchanged 5.7 MyISAM future Swift target. Both targets retain
OFF_PERMISSIVE/WARN. A generated CA and source certificate support verified TLS.
Two readers start before the workload, using positional and GTID commands. Four
autocommit changes straddle source rotation; an InnoDB rollback contributes no
committed row. The suite checks identical complete-group JSON, exact source GTID
delta/end coordinates, native final rows and ordered row operations independently
normalized by MySQL 8.4 mysqlbinlog from source/native physical logs.

It also checks explicit GTID replay and resume, clean nonblocking EOF, a real idle connection kill, wrong hostname,
untrusted CA, wrong source UUID and purged history error 1236. Deterministic Swift
tests fragment recorded wire events and cut before XID, assert no partial group or
GTID advancement, then replay from the original boundary. This is not a claim of
a real server-side mid-transaction kill. Evidence and diagnostics stay under
`artifacts/live-suite/<run>/`; owned containers/volumes are removed on failure too.
Docker Desktop still uses its own kernel and amd64 emulation.

Review the distinction between source coordinates and synthetic context, absence
of progress on incomplete groups, frozen-schema handling, queue bounds, TLS patch
and source/native comparisons. Next work is local raw relay files plus SQLite
state/checkpoints/diagnostics/counters, followed by read-only REST status and
controlled apply. See [the storage/runtime design](RELAY_STATE_AND_STATUS.md).

## Recorded validation

Run `20260930T030250Z-17f7bd18-auto-autocommit-myisam` passed all 15 checks and cleanup. The Ubuntu image ID is `sha256:0512494792a204fce83e3144fe6d405ecbb5f7349397f65687797ef0ee32b7c3`. Source/native servers are MySQL 8.4.8; the independent host mysqlbinlog is 8.4.6. All 63 root Swift tests pass, including 15 capture tests, both normally and with Swift/C/CLI AddressSanitizer. Rust is not sanitizer-instrumented. Logs are preserved under `artifacts/live-capture-validation/`; the failed initial harness-only assertion run is retained separately for transparency.
