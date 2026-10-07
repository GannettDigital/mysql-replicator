# Experimental 5.7 → 8.4 InnoDB profile

This is an experimental DML/DDL implementation, not Cloud SQL qualification or a complete
migration/recovery solution. The default 8.4 → 5.7 MyISAM profile is unchanged.
The implementation plan is [INNODB_REVERSE_REPLICATION.md](../PLAN/INNODB_REVERSE_REPLICATION.md).

## Configuration and bootstrap

Start with `examples/apply.example.yaml`, use the endpoints of your 5.7 source
and 8.4 destination, and set:

```yaml
profile: mysql57-to-mysql84-innodb
```

Both servers require GTID mode ON, enforce_gtid_consistency ON, ROW/FULL logging
and CRC32 checksums. Target binary logging remains enabled with target-local
GTIDs. The source GTID checkpoint lives exclusively in SQLite. TLS is required
for TCP connections. Do not configure collation translation or explicit table
locks for this profile. GTID positioning is required.

Load matching InnoDB tables and data externally, recording a consistent source
GTID/file/position boundary. Preserve source character sets and collations in
the destination definitions. MySQL 5.7 does not provide the modern optional
table-map metadata, so the destination schema supplies missing signedness,
encoding and ENUM/SET definitions. Independent destination writes or schema
changes invalidate this assumption.

The supported scalar types, collations and primary-key requirements remain the
existing applier subset. This does not imply support for every 5.7 type. In
particular, text is limited to the supported utf8mb4 collations. DDL ENUM/SET labels
outside the Unicode BMP are rejected: MySQL COLUMN_TYPE metadata replaces them
with `?`, preventing reliable definition verification. Ordinary utf8mb4 text can
still contain supplementary characters such as emoji. Composite keys,
PK updates, multiple source statements and multiple tables per transaction are
supported in this profile. Target triggers and foreign keys (including incoming
references/cascades) are rejected. Supported database/table DDL, generated columns,
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
schema visibility privileges, including explicit TRIGGER visibility and
REPLICATION CLIENT to exclude native replication. DDL also needs the corresponding
CREATE/ALTER/DROP/index/view/routine privileges. Preserving source DEFINER clauses
may need `SET_ANY_DEFINER` on 8.4; stored functions with binary logging have additional
server privilege/flag requirements. The disposable harness grants ALL PRIVILEGES
plus SET_ANY_DEFINER; this is not a least-privilege Cloud SQL recipe. The applier
does not assign GTID_NEXT. Managed-service
privileges, network access and failover must still be tested on Cloud SQL.

## Transaction and failure behavior

The coordinator synchronizes relay files and persists write intents before the
worker starts any target transaction. Each source transaction uses its own
START TRANSACTION/COMMIT. Multi-row INSERT chunks never cross source transaction
boundaries. SQLite completion can still be batched after acknowledged commits.

Successful individual statements are provisional until COMMIT succeeds. On a
statement failure, the worker attempts ROLLBACK and records `rolledBack` or
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
schemas, each mutation's old/new primary key and before/after row images, and
saved failure/statement diagnostics. Decimal and integer values remain strings
with explicit types; binary values are base64. Expectations fold repeated writes
and primary-key changes within each transaction into initial/final images. A
missing initial/final field means no row at that key. SQL NULL is a typed value
inside a row, distinct from an absent row.

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
for several committed transactions. `retry --gtids none` is only for a crashed
state with no pending intents; it publishes a clean stop at the already committed
checkpoint. Source binlogs must still cover any transactions to be retried.

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
Recovery currently accepts format-9 reverse-profile DML only. DDL reconciliation,
MyISAM recovery and automatic repair remain outside this command's scope.

SQLite state format 9 pins the profile. Cleanly stopped older MyISAM state can
upgrade in place; older state cannot be adopted as an InnoDB checkpoint. Older
runtimes reject format 9. Back up the stopped state before upgrading.

## Demo

From a checkout with Docker and the build prerequisites in
[CONTRIBUTING](../CONTRIBUTING.md):

```sh
make reverse-demo-up
make reverse-demo-start
make reverse-demo-sql FILE=examples/reverse-demo/01-success.sql
```

`up` prepares matching InnoDB tables, an isolated source 5.7, native reference
5.7, destination 8.4 and a running idle applier shell container. It prints source/target SQL-shell commands and the path
to generated `apply.yaml`. Replication starts separately with `reverse-demo-start`;
status before that says `NOT_STARTED`. Repeating `up` reuses the existing session
and repairs a missing applier container without resetting data. Use the preloaded `reverse_poc.items` and
`reverse_poc.aux` tables for the workbook's data comparison. Supported source DDL
also works in newly built sessions; use InnoDB instead of the original workbook's
explicit MyISAM clauses. Existing retained demos keep their pinned image and
original user grants until deliberately recreated.

- `make reverse-demo-compare`: wait for catch-up, drain, compare rows/schema and source GTID coverage,
  then restart an applier that was running. Pause source writes during comparison.
- `make reverse-demo-status`: show containers, logs and native status.
- `make reverse-demo-stop`: drain to a clean checkpoint; `reverse-demo-start` resumes.
- `make reverse-demo-inspect`: inspect stopped/blocked/crashed state without MySQL.
- `make reverse-demo-resolve ARGS="retry --gtids UUID:N --reason 'DBA reconciled all pending rows'"`:
  record a deliberate resolution, then use `reverse-demo-start`.
- `make reverse-demo-down`: archive evidence and delete only this disposable stack.

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
make reverse-suite ARGS="--events 10000"
make reverse-demo-suite ARGS="--skip-build"
```

The default reverse suite uses 100 benchmark transactions for CI. `--skip-build`
reuses `mysql-replicator-packaging:reverse`; omit it when executable code changes.
The fixture uses one 5.7 source feeding native 5.7 InnoDB and our 8.4 InnoDB target.
All three run linux/amd64 with durable InnoDB settings and one ordered applier.
It checks multi-table transactions, composite keys/PK moves, repeated updates,
unsigned BIGINT, decimal/ENUM/SET/binary data, clean resume, duplicate-key rollback,
then offline inspection and audited retry/resume.

The benchmark generates a backlog of two-statement transactions (one INSERT and
one UPDATE on different tables), then replays it sequentially through each path.
It records wall time, throughput, final data/checkpoints, target server counter deltas and our stage timings.
Timings include container/client startup and control-command overhead, and compare
**different destination versions**; they are not isolated applier overhead or CPU
time. No artificial network latency is injected. Evidence and the exact workload
are saved under `artifacts/reverse-suite/`; demo lifecycle evidence is under
`artifacts/reverse-demo-suite/`.

Unit fault tests cover lost commit replies, failed rollback, incomplete relay,
crashed RUNNING state, ordered resolution and atomic audit/checkpoint updates.
Managed-service privileges, realistic WAN latency, full-chain operation and
process-kill-at-COMMIT qualification remain untested. The downstream MyISAM profile
still rejects multi-statement/multi-table source groups; that extension is deferred.

## Shared correctness suite

```sh
make reverse-correctness
```

This uses the forward profile's database-creation, DDL compatibility, DML type/
operation matrix and MODIFY/index case definitions against a **5.7 InnoDB source,
5.7 native reference and 8.4 InnoDB target**. CREATE DATABASE/TABLE and subsequent
schema changes run on the source and must reach both replicas. Each step checks
GTID catch-up, exact row bytes, normalized columns/defaults/indexes, and the shared
independent expectations. The suite also checks saved-schema restart, trigger
skip behavior, and refused DDL with durable diagnostics and no checkpoint advance
or following DML. Successful work must leave no unfinished intents.

Use `ARGS="--skip-build --slice database"` (or `ddl`, `dml`, `indexes`, `policy`,
`rejections`) while iterating. The default is `all`. Evidence lives under
`artifacts/reverse-correctness/`: incremental `cases.json`, per-step SQL/checks/
snapshots, logs, SQLite/relay evidence, and `result.json`. A failed run exits nonzero.

This is not full parity with every forward-suite scenario: forward-only 8.4
collation translation and MyISAM limits do not apply; file-position, filters,
reconnect/timeout qualification and foreign keys are not covered here. 5.7 has no
FULL optional table-map metadata. Its missing metadata uses the target schema,
which these tests first create through replicated DDL. The temporary CREATE LIKE
case uses an InnoDB template for this profile. MySQL 5.7's logged conditional
`DROP TEMPORARY TABLE IF EXISTS` cleanup is an audited no-op (`ddl_skips`); the
suite checks that a permanent table with the same name survives. Other temporary
DDL syntax is not broadened. Binary-default hex rendering,
integer display widths, temporal-default presentation and partition identifier quoting are normalized for
schema comparison; actual row bytes are not normalized.

DDL commits independently of DML even on InnoDB. Failed or uncertain DDL remains
blocked with its journal/diagnostic; the offline row-recovery commands do not
resolve pending DDL intents automatically.
