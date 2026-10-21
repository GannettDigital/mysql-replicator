# MySQL 5.7 → MySQL 8.4 InnoDB profile

For common profile-based test, demo and benchmark commands, see the [test lab](TEST_LAB.md).
The commands in this document remain available; retained legacy demos are separate sessions.

This profile supports the DML and DDL operations described below.
Cloud SQL deployment still requires separate tests. Use external tools to copy the
initial data. Some failures require manual recovery.
The default profile remains 8.4 → 5.7 MyISAM.
The implementation plan is [INNODB_REVERSE_REPLICATION.md](../PLAN/INNODB_REVERSE_REPLICATION.md).

## Configuration and bootstrap

Start with `examples/apply.example.yaml`, use the endpoints of your 5.7 source
and 8.4 destination, and set:

```yaml
profile: mysql57-to-mysql84-innodb
```

Both servers require GTID mode ON, enforce_gtid_consistency ON, ROW/FULL logging
and CRC32 checksums. Target binary logging remains enabled. The default
`target.preserveSourceGTIDs: true` retains source GTIDs on the target. SQLite
remains the source checkpoint. Connections use
verified TLS by default. To disable TLS, see [connection settings](INSTALL.md#connection-security).
Do not configure collation translation or explicit table
locks for this profile. GTID positioning is required.

Target TLS defaults to `tlsVerification: verify-identity`, requiring a matching
`serverHostname`. For an instance-specific CA without a certificate DNS name,
use `target.tlsVerification: verify-ca` and an explicit `target.caFile`;
`serverHostname` becomes optional. Certificate-chain verification remains enabled.
See [target TLS configuration](OFFLINE_REPLAY.md) for the YAML example and scope.

Load matching InnoDB tables and data externally, recording a consistent source
GTID/file/position boundary. Preserve source character sets and collations in
the destination definitions. MySQL 5.7 does not provide the modern optional
table-map metadata, so the destination schema supplies missing signedness,
encoding and ENUM/SET definitions. Independent destination writes or schema
changes invalidate this assumption.

See [current support](SUPPORT.md) for scalar types, native 5.7 charsets and
collations, and primary/unique lookup-key requirements. ENUM/SET discovery reads exact labels
through temporary target columns. This includes non-UTF-8 and supplementary
labels. The target account needs `CREATE TEMPORARY TABLES` on replicated databases.
Composite keys,
PK updates, multiple source statements and multiple tables per transaction are
supported in this profile. Target triggers are rejected. InnoDB foreign keys
support complete primary/unique parent keys, composite references, RESTRICT/NO
ACTION, CASCADE and SET NULL. Self-references, cycles and source
`foreign_key_checks` settings are supported. Nonunique/partial parent keys remain
unsupported. Bootstrap must preserve
matching source relationships; filters cannot split a connected relationship.
See [foreign-key scope](../PLAN/MYSQL57_FOREIGN_KEYS.md) for DDL limits and tests.
Supported database/table DDL, generated columns,
partitions, views and stored routines use the same ordered, journaled DDL path as
the forward profile. Explicit table engines must be InnoDB; omitted engines use
the target's InnoDB default. Trigger definitions follow the configured skip/reject
policy, and events are rejected. Unsupported syntax still blocks replication.

For 5.7 query events, the 8.4 session uses `utf8mb4_general_ci` as the utf8mb4
charset default and discards the obsolete SQL-mode bits ignored by native 8.4
replication. Database defaults come from the logged source session; table defaults
come from the owning database. This preserves source defaults without collation
translation. Existing databases must therefore have matching defaults at bootstrap.
The source must use explicit TIMESTAMP defaults (`explicit_defaults_for_timestamp=ON`).

The source needs its normal replication privileges. The target needs DML and
schema visibility privileges, including explicit global REFERENCES (complete incoming FK
discovery), explicit TRIGGER visibility and
REPLICATION CLIENT to exclude native replication. DDL also needs the corresponding
CREATE/ALTER/DROP/index/view/routine privileges. View renaming also requires
SHOW VIEW to read the current definition. Preserving source DEFINER clauses
may need `SET_ANY_DEFINER` on 8.4; stored functions with binary logging have additional
server privilege/flag requirements. The disposable harness grants ALL PRIVILEGES
plus SET_ANY_DEFINER; this is not a least-privilege Cloud SQL recipe.
GTID preservation assigns `GTID_NEXT` and needs additional privileges. See
[required privileges and Cloud SQL limits](GTID_PRESERVATION.md). Managed-service
privileges, network access and failover must still be tested on Cloud SQL.
For Cloud SQL, set `target.preserveSourceGTIDs: false`. The documented customer
privileges do not establish permission to assign source GTIDs. SQLite still
tracks the complete source checkpoint.

## Transaction and failure behavior

The coordinator synchronizes relay files and persists write intents before the
worker starts any target transaction. A source transaction that fits one target
statement uses autocommit; other transactions use START TRANSACTION/COMMIT.
Multi-row INSERT chunks never cross source transaction boundaries. InnoDB performs
foreign-key checks and cascades within that boundary. SQLite completion can still
be batched after acknowledged commits.

Inside an explicit transaction, successful individual statements are provisional
until COMMIT succeeds. On a statement failure, the worker attempts ROLLBACK and
records `rolledBack` or
`rollbackUnconfirmed` in `targetFailure.transactionOutcome`. A failed COMMIT
response is recorded as `commitUncertain`; a subsequent ROLLBACK cannot prove
that COMMIT failed, so it is not used to infer the outcome. Subsequent source
transactions are not executed after failure. All unresolved intents are retained.

There is deliberately no automatic uncertain-write recovery. A crash after a
target commit and before SQLite completion remains ambiguous. Preserve the
entire state directory and target data for investigation. The existing `skip`
command still refuses groups with write intents. Use the explicit reverse-profile
recovery commands below instead of editing SQLite lifecycle fields.

## Offline inspection and DBA resolution

Stop the applier before inspecting or resolving; both commands acquire its
exclusive state-directory lock. These commands make **no MySQL connections** and
need no source/target passwords. They do not alter target rows or restart replication.

```sh
mysql-replicator recovery inspect --config apply.yaml > recovery.json
mysql-replicator recovery resolve retry --gtids 'SOURCE_UUID:101-104' --reason 'Restored every pending transaction to its initial state; ticket DBA-123' --config apply.yaml
mysql-replicator run --config apply.yaml
```

Inspection lists every pending group, GTID and source/relay boundary, retained
schemas, each mutation's old/new lookup key and before/after row images, and
saved failure/statement diagnostics. Decimal and integer values remain strings
with explicit types; binary values are base64. Expectations fold repeated writes
and lookup-key changes within each transaction into initial/final images. The
`rowIdentity` field names the index and its ordered columns. `primaryKeyColumns`
retains the declared primary key and is empty for a unique-key fallback. A
missing initial/final field means no row at that key. SQL NULL is a typed value
inside a row, distinct from an absent row.

For a table without a usable unique key, `rowIdentity.kind` is `fullRow`.
`beforeKey` and `afterKey` are absent. `fullRowChanges` retains each operation in
order, including identical images. These rows are not folded into `expectations`.
The records do not identify one physical copy or prove the total target row
count. Reconcile duplicate counts as well as values before a recovery action.

Compare this evidence to target rows while independent writes are stopped.
Expectations use exact encoded keys: collation-equivalent keys may alias, and
later pending transactions may overwrite earlier effects. A plausible final row
match is evidence, **not proof of commit**. The tool does not classify target
rows or infer which resolution to choose.

| Action | Required GTIDs | Meaning |
| --- | --- | --- |
| `mark-applied` | Exactly the earliest pending GTID | DBA accepts its effects as applied; advance past it. |
| `skip` | Exactly the earliest pending GTID | DBA accepts omitting it after reconciling the target; advance past it. |
| `retry` | The complete unresolved GTID set | DBA has restored/reconciled every pending transaction so replay is safe; keep the previous applied checkpoint and re-fetch those GTIDs on resume. |

Every action requires a nonempty `--reason`. Resolve accepted/skipped transactions
in source order; remaining pending transactions leave the state BLOCKED. Retry
names the **whole remaining batch**, since a crash can lose SQLite acknowledgements
for several committed transactions. `retry --gtids none` is for blocked or crashed
state with no pending intents; it publishes a clean stop at the saved checkpoint.
It also supports an empty startup state with a saved archive failure before target
binding. See [startup recovery](OPERATIONS.md#retry-an-archive-failure-before-target-setup).
Source binlogs must still cover any transactions to be retried.

`recovery_audit` in the same SQLite database stores the action, exact GTID set,
reason, time and the full pre-resolution report (`evidence_json`). Audit insertion,
checkpoint changes and journal resolution commit atomically. Original relay bytes
referenced by intents are retained. Extra bytes beyond SQLite's durable relay
length are archived as `recovery-tail-<audit-id>.bin`, synchronized, then removed
from the active relay before resolution. An interrupted resolution can leave an
unreferenced tail archive; preserve it with the rest of the state directory.

`transactionsApplied` counts processed groups, including explicitly skipped ones;
skips add no applied rows. The audit distinguishes skipped groups from accepted
commits. Audit history is not automatically pruned; include it in storage planning.
Recovery accepts formats 9 through 14 for InnoDB-profile DML. All four profiles
also support [retry of DDL rejected before an intent was saved](OPERATIONS.md#retry-ddl-rejected-before-a-target-write).
DDL with a saved intent, MyISAM row recovery, and automatic repair remain outside
this command's scope.

SQLite state format 14 records the GTID preservation setting, table filters, and DML transport. It also retains
tagged source GTIDs and the profile and table-name
case settings from format 10. Older state requires `target.preserveSourceGTIDs: false` and
can upgrade with `source.lowerCaseTableNames: 0`. It cannot adopt mode 1 or a
different replication profile. Runtimes without format-14 support reject this state. Back up the
stopped state before upgrading.

## Demo

From a checkout with Docker and the build prerequisites in
[CONTRIBUTING](../CONTRIBUTING.md):

```sh
export PROFILE=mysql57-to-mysql84-innodb
make lab-demo ACTION=up
make lab-demo ACTION=start
make lab-demo ACTION=sql ARGS=examples/reverse-demo/01-success.sql
```

`up` prepares matching InnoDB tables, an isolated source 5.7, native reference
5.7, destination 8.4 and a running idle applier shell container. It prints source/target SQL-shell commands and the path
to generated `apply.yaml`. Replication starts separately with `demo start`;
status before that says `NOT_STARTED`. Repeating `up` reuses the existing session
and repairs a missing applier container without resetting data. Use the preloaded `reverse_poc.items` and
`reverse_poc.aux` tables for the workbook's data comparison. Supported source DDL
also works in newly built sessions; use InnoDB instead of the original workbook's
explicit MyISAM clauses. Existing retained demos keep their pinned image and
original user grants until deliberately recreated.

- `make lab-demo ACTION=compare`: wait for catch-up and compare rows/schema and the saved source boundary
  without interrupting the writer. Pause source writes during comparison.
- `make lab-demo ACTION=status`: show containers, logs and native status.
- `make lab-demo ACTION=stop`: drain to a clean checkpoint; `demo start` resumes.
- `make lab-demo ACTION=inspect`: inspect stopped/blocked/crashed state without MySQL.
- `make lab-demo ACTION=resolve ARGS="retry --gtids UUID:N --reason 'DBA reconciled all pending rows'"`:
  record a deliberate resolution, then use `demo start`.
- `make lab-demo ACTION=down`: archive evidence and delete only this disposable stack.

For a controlled recovery exercise, stop source writes, drain the applier, insert
a target-only row into `reverse_poc.aux`, then issue a source transaction that first
inserts a different key and then that conflicting key. Restart the applier: it
blocks and rolls back both inserts. Inspect the report, remove the target-only
conflict, resolve `retry` for the reported GTID set and restart. The automated
reverse suite performs this exercise against both appliers.

Follow the [four-terminal reverse workbook](../PLAN/REVERSE_DEMO_WORKBOOK.md) for
SQL prompts, expected rows, clean resume and a complete recovery exercise. The
existing [8.4 → 5.7 workbook](../PLAN/DEMO_WORKBOOK.md) remains separate.

## Developer qualification

```sh
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite recovery"
make lab-benchmark PROFILE=mysql57-to-mysql84-innodb ARGS="--events 10000"
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite demo"
```

The recovery adapter omits the embedded benchmark; benchmark mode is selected
separately. Omit `--skip-build` when executable or fixture inputs change.
The fixture uses one 5.7 source feeding native 5.7 InnoDB and our 8.4 InnoDB target.
All three run linux/amd64 with durable InnoDB settings and one ordered applier.
It checks multi-table transactions, composite keys/PK moves, repeated updates,
unsigned BIGINT, decimal/ENUM/SET/binary data, clean resume, duplicate-key rollback,
then offline inspection and audited retry/resume.

The common benchmark defaults to single-row INSERT transactions. Add
`--workload multi-table-transaction` to generate one INSERT and one UPDATE on
different tables per transaction. It replays the backlog sequentially through each path.
It records wall time, throughput, final data/checkpoints, target server counter deltas and our stage timings.
Timings include container/client startup and control-command overhead, and compare
**different destination versions**; they are not isolated applier overhead or CPU
time. No artificial network latency is injected. Evidence and the exact workload
are saved under `artifacts/lab-benchmark/mysql57-to-mysql84-innodb/`; demo
qualification evidence is under `artifacts/lab/RUN_ID/PROFILE/demo/default/`.
The specialized recovery adapter retains `artifacts/reverse-suite/`.

Unit fault tests cover lost commit replies, failed rollback, incomplete relay,
crashed RUNNING state, ordered resolution and atomic audit/checkpoint updates.
Live source/target reconnect qualification uses the shared profile runner:

```sh
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite lifecycle"
```

Its 11 cases cover socket loss, source rotation and restart, target restart,
active-group drain/resume, backoff shutdown, settings revalidation and lost target
mutation replies. The InnoDB case observes a provisional write, disconnects the
writer, and checks rollback, pending-row evidence and refusal of ordinary resume.
See [the test lab](TEST_LAB.md) for scope and evidence under `artifacts/lab/`.

Managed-service privileges, realistic WAN latency, full-chain operation and
process-kill-at-COMMIT qualification remain untested. The downstream MyISAM profile
still rejects multi-statement/multi-table source groups; that extension is deferred.

## Shared correctness suite

```sh
make correctness PROFILE=mysql57-to-mysql84-innodb
```

This uses the forward profile's database-creation, DDL compatibility, DML type/
operation matrix and MODIFY/index case definitions against a **5.7 InnoDB source,
5.7 native reference and 8.4 InnoDB target**. CREATE DATABASE/TABLE and subsequent
schema changes run on the source and must reach both replicas. Each step checks
GTID catch-up, exact row bytes, normalized columns/defaults/indexes, and the shared
independent expectations. The suite also checks saved-schema restart, trigger
skip behavior, and refused DDL with durable diagnostics and no checkpoint advance
or following DML. Successful work must leave no unfinished intents.

Use `ARGS="--skip-build --family database"` (or select another family from
`make lab-list`) while iterating. The default runs all applicable correctness
scenarios. Evidence lives beneath `artifacts/lab/`: incremental `cases.json`,
per-step SQL/checks/snapshots, logs, SQLite/relay evidence, and `result.json`.
A failed run exits nonzero.

This is not full parity with every forward-suite scenario: forward-only 8.4
collation translation and MyISAM limits do not apply. The historical forward
capture variants describe an 8.4 source; reverse qualification uses GTIDs with
5.7 metadata. Filters and bootstrapped DML are shared correctness families;
reconnect runs in `--suite lifecycle`. Foreign keys remain a refusal contract.
5.7 has no FULL optional table-map metadata. Its missing metadata uses the target
schema, which the tests establish through both replicated DDL and equivalent
bootstrap snapshots. The temporary CREATE LIKE
case uses an InnoDB template for this profile. MySQL 5.7's logged conditional
`DROP TEMPORARY TABLE IF EXISTS` cleanup is an audited no-op (`ddl_skips`); the
suite checks that a permanent table with the same name survives. Other temporary
DDL syntax is not broadened. Binary-default hex rendering,
integer display widths, temporal-default presentation and partition identifier quoting are normalized for
schema comparison; actual row bytes are not normalized.

DDL commits independently of DML even on InnoDB. Failed or uncertain DDL remains
blocked with its journal/diagnostic; the offline row-recovery commands do not
resolve pending DDL intents automatically.
