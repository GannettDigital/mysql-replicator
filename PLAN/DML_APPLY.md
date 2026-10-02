# First serial DML applier

This increment connects the existing live reader/decoder/transaction assembler to
MySQL 5.7 MyISAM. It implements INSERT/UPDATE/DELETE for a declared narrow subset.
The [native engine/charset DDL foundation](DDL_NATIVE_DEFAULTS.md) replaces the
initial prototype rewrites. Broader coverage follows the [DDL completeness plan](DDL_COMPLETENESS.md).
Cleanly stopped state can be resumed explicitly. `skip '<GTID-set>' --config APPLY.json`
can exclude the single captured failed group before any target write intent;
see [the workbook](DEMO_WORKBOOK.md#skip-the-rejected-ddl-and-resume).
Automatic reconnect and recovery of interrupted or uncertain writes remain unimplemented.
Statistics will be read from SQLite; no embedded REST service is planned. The order remains DML correctness, then DDL correctness,
then crash/reconnect recovery. Dump/load and target provisioning remain external.

The reviewed checkpoint is `d188f58`. The current increment replaces its manual
schema lists with [automatic discovery and bounded state history](SCHEMA_DISCOVERY_AND_RETENTION.md).
The usage below describes the current working implementation.

## Run or review

For the self-contained three-server test, use `make dml-suite`. It builds a static
Ubuntu 16.04 x86_64 image tagged `mysql-replicator-packaging:dml`. To reuse an image
built from the same code, use `make dml-suite ARGS=--skip-build`. The harness prints
stage progress and streams Docker build/startup output to the terminal; the
initial image compilation can take several minutes. Runtime certificates, configs
and state live in a per-case Docker volume, avoiding Docker Desktop host bind
mounts. Closed state is copied back for SQLite assertions; all evidence is copied
back before cleanup removes that volume.

For a separately prepared target, start with the checked-in
[configuration template](../examples/apply.example.json). **Replace its placeholders
with the connection identities and external starting boundary before running.**
Target UUID is discovered through the verified target connection and saved in
SQLite; remove `targetUUID` from old configs. The template is not a ready-to-run fixture. Set the two named password environment
variables, then run:

```sh
make build
.build/debug/mysql-replicator run --config apply.json --initialize
```

For `--initialize`, the state directory's parent must already exist and the state
directory itself must not exist. Initialization creates it exclusively with private
permissions and records the configured external baseline. To restart after a clean
stop, omit the flag:

```sh
.build/debug/mysql-replicator run --config apply.json
```

SQLite is authoritative on restart: use the saved fully applied position and GTID
snapshot; when no group has been applied, use the recorded baseline instead.
Configuration `source.start` cannot replace saved progress. `source.mode` selects
GTID or file-position transport; positional mode requires a saved coordinate.
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
Stdout contains one progress JSON record per fully applied source group; stderr
contains the final summary or a structured error. SIGINT/SIGTERM at a complete
capture/apply boundary persist STOPPED and exit zero; a partial capture/apply
interruption remains BLOCKED. A known transport or apply failure is not converted
to success by a concurrent stop. A clean STOPPED state can then be resumed
explicitly; uncertain writes are never retried.
Passwords and row values are not printed in ordinary apply progress. Relay files do contain source row bytes.

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
- ASCII SQL identifiers (quoted, never interpolated unescaped); a single full,
  nonnullable integer primary key. Named ordinary/unique BTREE secondary indexes
  are supported as described in [the MODIFY/index slice](DDL_MODIFY_AND_INDEXES.md);
  row identity still uses the primary key. No triggers, generated/auto-increment
  columns or partitioned targets. Discovery obtains ordered column names, types, nullability and text collation
  from the target, validates source wire metadata and rechecks under the apply lock.
- Declared types: signed/unsigned INT and BIGINT, VARCHAR(n) with utf8mb4_bin,
  utf8mb4_unicode_ci or utf8mb4_general_ci, and VARBINARY(n); lengths 1–16383.
  NULL is permitted only by compatible discovered metadata. Missing row-image fields are errors.
  Scope/type/shape validation covers the whole source group before writing.

Target preflight checks every native channel and performance_schema worker/receiver
state, failing on missing privileges or indeterminate results. This initial version
rejects even retained stopped channels; explicit stopped-channel adoption is later
work. It acquires one server-wide advisory writer lock and checks ownership/channel
state before each source group. Administrative native starts and other writers
must be excluded operationally; native replication does not honor this lock.

MySQL 5.7's `skip-slave-start` is a startup option, not the queryable system
variable added in 8.0.24. `nativeAutoStartDisabled` is an operator assertion,
not proof from SQL; the harness verifies the actual container startup arguments.
See [MySQL's system-variable worklog](https://dev.mysql.com/worklog/task/?id=14450).
The SQL channel/worker checks remain mandatory regardless of this assertion.

The target account needs SELECT/INSERT/UPDATE/DELETE/LOCK TABLES for declared
tables, REPLICATION CLIENT, SUPER (MySQL 5.7 requires it to set the session
[GTID_NEXT](https://dev.mysql.com/doc/refman/5.7/en/replication-options-gtids.html)), SELECT on the queried performance_schema replication
status tables, and TRIGGER visibility for declared tables (global/schema/table
TRIGGER grant). That last privilege prevents an empty metadata result from hiding
triggers; the applier creates none. It needs no schema creation or GTID_PURGED
mutation privileges. The fixture grants these explicitly.

## Apply and state ordering

For an applier deployed on the MySQL 5.7 host, replace target `host` and `port`
with `"unixSocket": "/var/run/mysqld/mysqld.sock"`. The path must be absolute,
without NUL, and at most 103 UTF-8 bytes. Socket errors fail the connection; there
is no TCP fallback. TLS remains required by default, including CA/hostname
verification. To use a plain local socket, explicitly set `"requireTLS": false`
and omit target `serverHostname` and `caFile`. TCP always requires TLS. MySQL
password authentication, target UUID checks and writer exclusion still apply.
The local account must allow non-TLS socket authentication, and the deployment
must protect access to the socket directory. Source transport remains verified TLS.

Each apply session sets `GTID_NEXT=AUTOMATIC`, autocommit, strict SQL mode and utf8mb4.
The source GTID remains local replication identity, never a target SQL GTID. There
is no target transaction pretending to make MyISAM rows atomic.

The applier holds a MyISAM WRITE table lock while validating the current schema,
reading the exact old row, issuing bound SQL and verifying affected-row count.
A successful SQL response with the expected count acknowledges the row; there is
no post-write SELECT. This acknowledges MyISAM's write acceptance, not a guarantee
of crash durability or atomicity with SQLite. Integer primary keys identify rows. Text comparisons
use stored UTF-8 bytes, not collation or Swift's canonical Unicode equivalence;
binary values and full unsigned 64-bit values remain exact. INSERT requires an
absent key; UPDATE/DELETE require the full matching before image. Key changes also
require the destination key to be absent. Drift is an error, never an upsert.

Raw live events, including required format/rotation/heartbeat context, go to
`relay.frames`. Each record contains little-endian UInt32 metadata length and
UInt32 event length, then UTF-8 JSON metadata (`kind`, `file`, `observedPosition`)
and original event bytes. It is a version-1 private framed relay, not a physical
source binlog accepted directly by mysqlbinlog. Source event headers are unchanged.

`state.sqlite` uses WAL/FULL and stores identities, schema/baseline metadata, group
source boundaries and relay byte references, per-row event offset/row ordinal
intents, completion, applied GTID/position, counts and diagnostics. Raw events and
decoded rows are not copied into SQLite. Before any mutation, relay data is synced
and the group reference is committed, then the row's PENDING intent is committed.
After SQL acknowledgment and affected-row validation the row becomes DONE. The
last row's DONE update commits atomically with marking the source group applied
and advancing its checkpoint/counters, after checking all earlier rows are DONE.
Table locks remain held through that commit. A failed or uncertain SQL outcome
leaves the intent unresolved; no write is retried automatically.

Baseline GTIDs are externally asserted coverage; initialization does not count them
as work performed by this process or claim a locally verified applied position.
Received relay bytes, a pending group and completed target writes are distinct.
If a later row fails, earlier MyISAM mutations remain; the last whole-group applied
checkpoint stays unchanged, and the journal records the partial work. Failures set
BLOCKED where storage is writable and exit nonzero. An uncertain SQL outcome closes
its connection and is never automatically retried. A target/host crash can lose
MyISAM data despite durable local metadata; there is no crash-safe recovery claim.

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
trigger rejection, missing DELETE rows, partial multi-row failure and the known
native multi-statement error 1837. Extended multi-row/key-change history is also
compared through mysqlbinlog. A separate table uses an independent SQL HEX oracle
after each group for integer extremes, quotes, backslashes, NUL/tab, multibyte
UTF-8, distinct Unicode encodings, trailing spaces, binary bytes, NULL and empty
binary values; these are outside the narrow mysqlbinlog text normalizer.

Unit tests exercise group-wide validation, exact UINT64_MAX/null/length behavior,
UTF-8 byte equality, GTID-only configuration, raw relay preservation, unfinished
intent rejection and atomic whole-group checkpoint advancement. They do not claim
crash/reconnect recovery. That qualification follows DDL correctness.

## Recorded validation

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
  about 18 seconds. Swift entry points are recompiled to ensure fresh linkage to
  external Rust archives. See [packaging caches](../packaging/README.md).

The harness reads copied SQLite snapshots only after the writer exits. During
a run it waits on JSON progress. The live relay/SQLite files remain inside Docker
until copied, so the VM and host never share live WAL locks/mmap. This is harness
coordination, not recovery qualification.
