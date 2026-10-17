# DML application

This guide describes row application and local state. The forward MyISAM profile
was the first implementation. The [profile table](../README.md#tested-profiles)
and [support summary](../docs/SUPPORT.md) describe the current four profiles.
The MyISAM group restrictions below do not apply to InnoDB multi-statement
transactions. Initial copying and target provisioning remain external tasks.

Clean stops can resume from saved state. Source and safe target disconnects can
reconnect. Uncertain writes stop for DBA review. InnoDB has explicit recovery
inspection and resolution commands; automatic crash recovery is not implemented.
See [offline replay and recovery](../docs/OFFLINE_REPLAY.md),
[source reconnect](SOURCE_RECONNECT.md), and [target reconnect](TARGET_RECONNECT.md).
Schema discovery and saved history replace manual table definitions.

## Run or review

Use the shared test harness from the repository root:

```sh
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--family dml"
```

Use `PROFILE=all` for all four profiles. Add `--skip-build` to `ARGS` to reuse an
image built from the same inputs. The harness saves SQL, logs, state, and results
under `artifacts/lab/`. See [test selection and evidence](../docs/TEST_LAB.md).

For a separately prepared target, start with the checked-in
[configuration template](../examples/apply.example.yaml). **Replace its placeholders
with the connection identities and external starting boundary before running.**
Target UUID is discovered through the verified target connection and saved in
SQLite; remove `targetUUID` from old configs. Configuration files must use YAML
with a `.yaml` or `.yml` extension; legacy JSON configs must be converted.
For each connection, set either `passwordEnvironment` (the variable's name) or
`password` (the literal value), never both. Quote literal passwords containing
YAML punctuation. The template is not a ready-to-run fixture. Replace its values
and set any chosen password environment variables, then run:

```sh
make build
.build/debug/mysql-replicator run --config apply.yaml --initialize
```

For `--initialize`, the state directory's parent must already exist and the state
directory itself must not exist. Initialization creates it exclusively with private
permissions and records the configured external baseline. To restart after a clean
stop, omit the flag:

```sh
.build/debug/mysql-replicator run --config apply.yaml
```

SQLite is authoritative on restart: use the saved fully applied position and GTID
snapshot; when no group has been applied, use the recorded baseline instead.
Configuration `source.start` cannot replace saved progress. `source.mode` selects
GTID or file-position transport for the 8.4 source; 5.7 sources require GTID mode.
Positional mode requires a saved coordinate.
Counters and current schema history are restored, and relay bytes are appended.
A process-lifetime local writer lock, target UUID/schema checks and native/writer
exclusion prevent concurrent or mismatched startup. Existing version-4 clean-stop
state is supported without migration.

Missing state is an error without `--initialize`. BLOCKED/RUNNING/STARTING state,
unresolved intents, invalid snapshots or mismatched relay lengths are refused;
this slice does not reconcile crashes or partially applied MyISAM writes. Target
server/host crash durability is still outside this guarantee. Never delete state
and reuse an old baseline against a partially changed target.

Source `mode: "gtid"` now accepts a start containing only `executedGTIDs`.
`mode: "file-position"` requires `file` and `position`, plus the seed GTID set
(which may be empty if unavailable). File and position, when present in GTID mode,
are checked as the additional bootstrap bound. Neither mode invents target GTIDs.
The operator supplies a prepared target matching the starting boundary; these
checks do not certify the external snapshot/load.

`stopAfterTransactions` / `nonBlocking` on `source` provide bounded qualification
runs. Otherwise the command follows the source until stopped or an error occurs.
Stdout contains a progress JSON record after each completed DML batch or standalone group; stderr
contains the final summary or a structured error. SIGINT/SIGTERM at a complete
capture/apply boundary persist STOPPED and exit zero; a partial capture/apply
interruption remains BLOCKED. Source reconnect discards unapplied capture only
after the active target batch finishes and its acknowledgments are journaled;
cancellation during reconnect backoff can then stop cleanly. Target, journal and
nonretryable capture failures remain errors. A clean STOPPED state can be resumed
explicitly; uncertain writes are never retried.
On clean capture cancellation, buffered groups with no prepared intents can be
discarded and read again from the saved applied boundary. A finite capture limit
flushes buffered work before stopping.
Passwords and row values are not printed in ordinary apply progress. Relay files do contain source row bytes.

Download, decoding, preparation, and target SQL execution overlap. Decoded
source events pass through a bounded FIFO. Preparation saves write intents before
SQL execution. The execution queue preserves source order; preparing later work
does not advance the applied checkpoint. DDL drains preceding work before it
changes target and saved schema state. See the batch settings in the
[configuration reference](../examples/apply.example.yaml).

The FIFO normally allows at most 4,096 items, 64 complete groups and 64 MiB of
retained-data accounting. An empty FIFO can accept one larger item within the
configured event/transaction limits. These limits do not bound process memory: the socket queue,
current bounded assembler group and current apply batch also retain data. Full
queues pause the producer rather than dropping events. Normal finite completion
drains the queue and flushes the final batch. Failure discards queued work and
joins the producer. A retryable source failure lets already-journaled target work
finish; other failures interrupt execution. SQL is not retried and acknowledged
partial groups retain the existing journal semantics. Uncertain target outcomes
remain BLOCKED, including when source and target fail concurrently.

Final summaries include queue high-water marks and enqueued/dequeued group counts
in `pipeline`. These counters reset per run and are diagnostic, not recovery state.
Capture and apply use separate timing collectors; their elapsed times overlap.

## Declared subset and checks

- MySQL 8.4 GTID-ON InnoDB source with ROW/FULL/CRC32, as qualified by live inspect;
  verified TLS with CA/hostname checking on both connections by default; the
  local target Unix-socket option is described below.
- MySQL 5.7 target, UUID distinct from the source, OFF_PERMISSIVE/WARN, ROW/FULL/CRC32
  binary logging enabled globally and on the apply session. The deployment must
  set `--skip-slave-start` and assert `target.nativeAutoStartDisabled: true`.
- Complete committed source groups with one row statement affecting one discovered
  table. Multi-row events/statements and primary-key changes are supported within
  this subset. Multi-statement groups are rejected before any target mutation,
  consistent with the accepted native MyISAM expected-negative reference.
- Prefer a primary key or eligible UNIQUE index with 1–16 full, nonnullable
  supported base scalar columns, including DATE/integer composite keys. Without
  such a key, use [full-row matching](KEYLESS_ROWS.md) and change one matching copy.
  Named ordinary/unique BTREE secondary indexes
  are supported as described in [the MODIFY/index slice](DDL_MODIFY_AND_INDEXES.md);
  key selection is described in [beta.6 row identity](ROW_IDENTITY.md). Target triggers are rejected. The
  [DDL compatibility increment](DDL_COMPATIBILITY.md) adds bounded generated
  columns and partitioned targets. Prepared targets may use an indexed integer
  AUTO_INCREMENT, literal defaults and temporal CURRENT_TIMESTAMP defaults/on-update
  attributes. All row values, including generated IDs and source-evaluated temporal
  values, are supplied explicitly. Generated-expression columns are the exception:
  the target computes them and the applier compares them with the FULL source image
  before completing the write intent.
  Discovery obtains ordered column names, types, defaults, EXTRA attributes, nullability and text collation
  from the target and validates source wire metadata against that description.
  Validated schema is cached for the session and invalidated around source DDL.
- Prepared-table DML types: signed/unsigned TINYINT, SMALLINT, MEDIUMINT, INT and
  BIGINT; DECIMAL(p,s) including unsigned (precision 1–65, scale 0–30 and no greater
  than precision); DATE, YEAR, TIME/DATETIME/TIMESTAMP with fractional precision
  0–6; CHAR(n), BINARY(n), VARCHAR(n), VARBINARY(n), ENUM, SET, and
  TINY/ordinary/MEDIUM/LONG TEXT and BLOB.
  Text requires matching source and target collations from the supported
  utf8mb4, utf8mb3, latin1 or ASCII subset. See [character sets](CHARACTER_SETS.md). A source 8.4-only collation fails unless covered by the explicit
  [collation mapping policy](DDL_COMPATIBILITY.md#optional-collation-translation-and-table-replacement).
  CHAR/BINARY lengths are 0–255. VARCHAR uses the declared charset byte width;
  VARBINARY uses bytes. Both allow at most 65,535 declared bytes, subject to
  native row and engine limits.
  ENUM/SET require matching ordered labels. The 8.4 profile uses FULL source
  metadata; 5.7 profiles use the matching baseline and saved schema for omitted fields.
  ENUM ordinal zero uses a scoped non-strict write and full after-image checks.
  It remains distinct from a declared empty label. See [ENUM zero](ENUM_ZERO.md).
  Configurable event/transaction limits and the target packet limit apply to
  TEXT/BLOB values. See [large-value limits](../docs/LARGE_VALUES.md).
  NULL is permitted only by compatible discovered metadata. Missing row-image fields are errors.
  Scope/type/shape validation covers the whole source group before writing.

MySQL 5.7 is the target feature boundary, with a pinned 5.7.44 reference under
`.upstream/mysql-server-5.7`; see [reference provenance](../tests/Upstream/README.md).
BIT(1) through BIT(64) use unsigned values with exact width checks, including
primary keys. See [BIT support and tests](BIT_SUPPORT.md).

Finite FLOAT/DOUBLE values retain their exact IEEE bits through decoding, binary
SQL parameters, target reads, and recovery. See [FLOAT/DOUBLE support and tests](FLOATING_POINT_SUPPORT.md).
Fixed-scale FLOAT/DOUBLE
forms, NaN, and infinity remain unsupported.

The [JSON increment](JSON_SUPPORT.md) adds full documents, typed values and
partial updates. Selected integration cases passed on the applicable profiles.
Some legacy opaque types still lack an exact SQL constructor. Typed JSON can
require `CREATE TEMPORARY TABLES` permission on the target.
[Spatial types](SPATIAL_SUPPORT.md) retain SRID and WKB bytes and support SPATIAL
indexes within the documented limits. MyISAM profiles
still exclude multi-statement source transactions. The source DDL grammar now accepts these DML types,
including ENUM/SET, together with bounded defaults and schema operations described
in [DDL compatibility](DDL_COMPATIBILITY.md).

The DML matrix (`make correctness ARGS="--family dml"`) checks multi-value INSERT,
multi-row UPDATE/DELETE, upsert, REPLACE, IGNORE, INSERT…SELECT, single-target
joined UPDATE/DELETE and LOAD DATA as row events, within the supported group and
schema restrictions. No-op SQL that emits no GTID requires no apply; a valid empty
committed GTID advances coverage without target writes. Select a complete fixture
with `--case matrix-decimal`, for example; `--list` shows the available fixtures.

Target preflight checks every native channel and performance_schema worker/receiver
state, failing on missing privileges or indeterminate results. This initial version
rejects even retained stopped channels; explicit stopped-channel adoption is later
work. It acquires one server-wide advisory writer lock on the single target
connection. Safe target reconnect destroys that session and reacquires ownership
on a fresh connection before applying; see [target reconnect](TARGET_RECONNECT.md).
Ownership/channel checks also run at DDL barriers, but not for every DML group.
The target is a dedicated replica: DBAs must exclude target-local writes, DDL,
grant changes and administrative native starts during application. Native
replication and other clients do not honor the advisory lock. The applier does
not poll for these unsupported concurrent changes.

MySQL 5.7's `skip-slave-start` is a startup option, not the queryable system
variable added in 8.0.24. `nativeAutoStartDisabled` is an operator assertion,
not proof from SQL; the harness verifies the actual container startup arguments.
See [MySQL's system-variable worklog](https://dev.mysql.com/worklog/task/?id=14450).
Startup SQL channel/worker checks remain mandatory regardless of this assertion.

The target account needs SELECT/INSERT/UPDATE/DELETE for declared tables
(and LOCK TABLES when `target.explicitTableLocks` is enabled), REPLICATION CLIENT, SUPER (MySQL 5.7 requires it to set the session
[GTID_NEXT](https://dev.mysql.com/doc/refman/5.7/en/replication-options-gtids.html)), SELECT on the queried performance_schema replication
status tables, and TRIGGER visibility for declared tables (global/schema/table
TRIGGER grant). That last privilege prevents an empty metadata result from hiding
triggers; the applier creates none. It needs no schema creation or GTID_PURGED
mutation privileges. The fixture grants these explicitly.

## Apply and state ordering

For an applier deployed on the MySQL 5.7 host, replace target `host` and `port`
with `unixSocket: /var/run/mysqld/mysqld.sock`. The path must be absolute,
without NUL, and at most 103 UTF-8 bytes. Socket errors fail the connection; there
is no TCP fallback. TLS remains required by default, including CA/hostname
verification. Source TCP and target TCP or Unix sockets can use
`requireTLS: false`. Remove the TLS-only fields for that connection. MySQL
password authentication, target UUID checks and writer exclusion still apply.
The local account must allow non-TLS socket authentication, and the deployment
must protect access to the socket directory. TLS is enabled by default. The
target also supports CA-only verification. See [connection security](../docs/INSTALL.md#connection-security).

Each apply session sets `GTID_NEXT=AUTOMATIC`, autocommit, strict SQL mode and utf8mb4.
It also sets `time_zone='+00:00'`, including after DDL session resets. DECIMAL
stays exact decimal text throughout decoding, binding and before-image checks.
Temporal values use canonical text with exact microseconds; target reads cast
them to CHAR to avoid driver calendar/floating-point conversion. TIMESTAMP follows
the 5.7 range, including its special zero value; unsupported values fail explicitly.
The source GTID remains local replication identity, never a target SQL GTID. There
is no target transaction pretending to make MyISAM rows atomic.

The applier validates schema on discovery, on clean resume and around ordered
source DDL. Its session cache holds at most 1,024 validated schemas and their SQL
templates; releasing a table lock does not invalidate them. DDL clears both this
cache and prepared statements, and following DML validates the new version.
`target.explicitTableLocks` defaults to `false`: the applier sends no client
LOCK/UNLOCK TABLES commands. MyISAM still takes its internal per-statement locks.
This relies on the dedicated-replica contract: no other target writers or local
schema changes. Readers can observe intermediate SQL chunks of a source group,
including the gap between an UPDATE/DELETE before-image read and its write.
The advisory writer lock, native replication exclusion, schema checks,
before-image checks and affected-row checks remain mandatory.

Set `target.explicitTableLocks: true` to retain the previous WRITE lock behavior
across before-image reads and writes. Lock epochs are bounded to 32 groups or
50 ms at safe boundaries, and idle capture releases the lock. Neither mode
provides MyISAM rollback or crash durability.

The preparation loop caches parsed column types and the last successfully
validated full wire description per schema, using a database/table lookup.
Changed metadata is revalidated; row values are still validated individually.
Ordered DDL replaces this cache after execution drains. The SQL worker owns
separate immutable column descriptors for exact target result decoding.
A successful SQL response with the expected count acknowledges the row; there is
no general post-write SELECT. Generated columns and ENUM zero retain their
specific post-write checks. Acceptance does not prove MyISAM crash durability or
atomicity with SQLite. Primary or selected unique-key tuples identify rows.
Without a usable key, full-row matching preserves duplicate counts. Text comparisons
use stored UTF-8 bytes, not collation or Swift's canonical Unicode equivalence;
binary values and full unsigned 64-bit values remain exact. Plain INSERT relies
on MySQL to reject duplicate primary/unique keys, without an existence SELECT;
UPDATE/DELETE require the full matching before image. A changed primary or unique
key must not identify another row. A changed full-row image may create another
identical copy. Drift is an error, never an upsert.

Raw live events, including required format/rotation/heartbeat context, go to
`relay.frames`. Each record contains little-endian UInt32 metadata length and
UInt32 event length, then binary metadata (`kind`, `file`, `observedPosition`)
and original event bytes. The reader also accepts legacy JSON metadata. This
private framed relay is not a physical
source binlog accepted directly by mysqlbinlog. Source event headers are unchanged.

`state.sqlite` uses WAL/FULL and stores identities, schema/baseline metadata, group
source boundaries and relay byte references, per-row event offset/row ordinal
intents, completion, applied GTID/position, counts and diagnostics. Raw events and
decoded rows are not copied into SQLite. DML collection defaults to 8 source
groups, 4,096 rows, 8 MiB of wire events or 25 ms, whichever boundary is reached
first. Configure the optional `batch` object in the configuration template.
Time is checked at capture callbacks, rather than by a background deadline.
Idle capture, DDL, filtered groups and finite stop boundaries flush the buffer.
Table changes flush it only when `batch.flushOnTableChange` is enabled. A source group exceeding a collection limit runs alone within
the decoder's existing limits; it is never split.

Before any target mutation, one relay sync and one FULL SQLite transaction persist
all group identities, individual relay ranges and ordered PENDING row intents with
schema references. Target writes execute in source order; consecutive eligible
INSERTs may share a bounded multi-row statement. The before-image, optional
table-lock and affected-row checks described above remain in place. One
completion transaction marks acknowledged rows DONE and whole groups APPLIED, and
advances GTID coverage, position and counters together. Existing lock epoch limits
still apply between source groups; the batch has no atomic target visibility.

On a detected failure, completion records the acknowledged whole-group prefix and
any acknowledged rows of the first incomplete group. Remaining prepared intents
stay PENDING. A process crash before completion leaves the entire prepared batch
unresolved, even if some writes succeeded. No target write is inferred or retried.
`active_gtid` identifies the first unresolved group; inspect all PENDING `groups`
ordered by `sequence`, then their `row_intents` and referenced `schemas`. These
records use the existing version-5 schema, with no new migration required.

Baseline GTIDs are externally asserted coverage; initialization does not count them
as work performed by this process or claim a locally verified applied position.
Received relay bytes, a pending group and completed target writes are distinct.
If a later row fails, earlier MyISAM mutations remain; only fully acknowledged
groups advance the checkpoint, and the journal records partial work. Safe source/target
transport failures reconnect; other failures set BLOCKED where storage is writable and exit nonzero. An uncertain SQL outcome closes
its connection and is never automatically retried. A target/host crash can lose
MyISAM data despite durable local metadata; there is no crash-safe recovery claim.
DBA reconciliation must use a consistent source snapshot and matching GTID boundary,
coordinated with tables not restored. The journal identifies the uncertain work
window and affected tables, not the exact crash instant or durable MyISAM contents.

Relay size defaults to 256 MiB and can be set to 1 MiB–1 GiB using
`maximumRelayBytes`; reaching it stops the attempt. Relay segment purge and re-download remain unimplemented. SQLite history has
separate pressure-triggered retention and a hard budget; see the [storage policy](SCHEMA_DISCOVERY_AND_RETENTION.md#storage-policy). The transaction decoder's existing resource
bounds still apply. These are local qualification limits, not a large-instance
capacity claim.

## Validation scope

The DML suite runs both file/position and GTID-only starts. All three branches are
now active: source 8.4 InnoDB, native 8.4 MyISAM and Swift-applied 5.7 MyISAM.
The initial workload compares exact final rows, ordered source/native/Swift binlog
operations through MySQL's independent decoder, anonymous target GTID behavior,
and SQLite applied boundaries/counters. Additional cases cover multi-row statements,
key changes, before-image mismatch, existing-state refusal, native-channel exclusion,
trigger rejection, missing DELETE rows, partial multi-row failure, process kill
during a prepared group, refusal to replay that crashed group, and the known
native multi-statement error 1837. Extended multi-row/key-change history is also
compared through mysqlbinlog. A separate table uses an independent SQL HEX oracle
after each group for integer extremes, quotes, backslashes, NUL/tab, multibyte
UTF-8, distinct Unicode encodings, trailing spaces, binary bytes, NULL and empty
binary values; these are outside the narrow mysqlbinlog text normalizer.

Unit tests exercise group-wide validation, exact UINT64_MAX/null/length behavior,
UTF-8 byte equality, GTID-only configuration, raw relay preservation, unfinished
intent rejection, batch limits/barriers, failed journal preparation/completion,
and atomic advancement through the acknowledged group prefix. The process-kill
qualification checks evidence retention and replay refusal; automatic recovery
and MySQL/host power-loss durability remain outside this guarantee.

## Recorded validation

### MySQL 5.7 DML expansion (2026-10-02)

- 197 Swift unit tests and 5 Rust tests pass. The DDL catalog structure check and
  the pinned MySQL 5.7.44 revision plus all 14 reference-file hashes pass.
  This increment does not add sanitizer or crash-recovery qualification.
- File-position/MINIMAL-metadata run
  `20261002T193141Z-823f6aa8-position-autocommit-myisam` passes all 41 cases:
  the basic workload, 32 compatibility phases and 8 expected rejections.
  Each positive phase compares exact source/native/target row bytes plus an
  independent SQL expectation; rejected cases assert zero target rows and zero
  applied-transaction count.
- GTID/FULL-metadata run
  `20261002T194538Z-086c30df-auto-autocommit-myisam` passes all 56 cases: the same
  matrix plus the existing DML, schema-cache, drift, partial-write and process-kill
  regressions. Both DML runs completed cleanup. An earlier GTID attempt
  (`20261002T193712Z-1bebd549-auto-autocommit-myisam`) passed the matrix but failed
  the native-channel fixture during target connection setup, before preflight SQL,
  with `Connection closed`. The fresh rerun passed without code changes or retries
  inside the application; the failed attempt's evidence remains preserved.
- The GTID MODIFY/index regression slice
  `20261002T193107Z-0a458a05-auto-autocommit-myisam` passes all 27 cases, including
  clean resume, index drift, DDL timeout and following DML.
- These runs use Ubuntu 16.04 amd64 runtime image
  `sha256:e00ab026c9858ec55c3aa4912a23bf1c4588cb837b68a20bc18f8ff1592cc272`,
  MySQL 8.4.8 source/native servers and MySQL 5.7.42 target. The separately pinned
  5.7.44 checkout is a source reference, not the tested container version.
- Regression vectors cover signed MEDIUMINT sign extension, YEAR zero and
  negative fractional TIME decoding. The large-value fixture covers fragmented
  capture reads with 70 KB TEXT/BLOB values. Packaging now removes executable
  outputs before linking, because touching an unchanged Swift entry point did
  not reliably relink a changed Rust archive.

### Original serial-applier qualification

- 70 Swift tests pass normally and with Swift/C/CLI AddressSanitizer. Rust itself
  is not instrumented by that run.
- Ubuntu 16.04 amd64 Docker runs
  `20260930T050203Z-868edb4a-position-autocommit-myisam` and
  `20260930T050243Z-ca3f136e-auto-autocommit-myisam` pass, including cleanup.
  Their `result.json`, independent binlogs/operations, exact-value SQL snapshots,
  progress/diagnostics, framed relay and SQLite journals are under
  `artifacts/dml-suite/`. Failed development runs are preserved separately there.
- The tested runtime image ID is
  `sha256:56fdba74089ae501f45549a952fd6b55e57f4d9c77bff0fa1a37cb6e9b0f0fc1`.
  The host reference mysqlbinlog is 8.4.6; fixture servers are 8.4.8 and 5.7.42.
- Persistent BuildKit Swift/Cargo caches reduced the observed warm build step to
  about 18 seconds. Swift executables are removed before linking to ensure fresh linkage to
  external Rust archives. See [packaging caches](../packaging/README.md).

The harness reads copied SQLite snapshots only after the writer exits. During
a run it waits on JSON progress. The live relay/SQLite files remain inside Docker
until copied, so the VM and host never share live WAL locks/mmap. This is harness
coordination, not recovery qualification.

See [fleet compatibility work](FLEET_COMPATIBILITY.md) for composite-key behavior,
ENUM/SET metadata requirements and the sanitized inventory request.
