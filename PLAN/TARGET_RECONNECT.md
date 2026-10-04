# Target reconnect, drain, and failure evidence

This increment reconnects at proven safe boundaries. It does not reconcile row
images, replay uncertain statements, recover crashed replicator processes, or
repair MyISAM tables.

## Reconnect contract

The top-level `targetReconnect` setting in `apply.yaml` is optional and defaults to:

```yaml
targetReconnect:
  enabled: true
  initialDelaySeconds: 1
  maximumDelaySeconds: 30
  maximumAttempts: 0
```

The policy has an independent target retry budget. Zero attempts means unlimited
retries; a positive limit counts retries without applied progress. Delays double
to the cap. Authentication, TLS verification, protocol, schema, native-channel,
identity, storage, and SQL errors remain fatal. An unavailable Unix socket during
connection establishment is retryable. Target ownership contention waits using
the same bounded backoff policy.

The coordinator stops capture, joins the target worker, and records its known
acknowledged prefix before deciding whether reconnect is safe. Reconnect requires
no unresolved target intents. Entire groups proven never issued can be removed
from the pending journal and downloaded again; partially acknowledged groups
remain BLOCKED. This proof exists only within the running process.

The old target session is destroyed. Each new connection repeats target
preflight, compares its UUID with saved state, reacquires the writer advisory
lock, restores session settings, revalidates saved schemas, and starts with new
schema/plan/prepared-statement caches. A surviving old server session must release
writer ownership before the new connection can apply. Source capture resumes
from the durable applied GTID/file-position checkpoint. The configured transaction
limit applies across all reconnect attempts in the invocation.

An already closed connection detected before SQL submission is safe to reconnect.
Once mutation SQL is submitted, failure is conservatively treated as possibly
executed, even if the failure may actually have occurred while preparing SQL.
MyISAM can apply a prefix before returning an error. A successful reply remains
our acceptance signal; this feature adds no post-write row verification and no
stronger storage-durability guarantee. A lost reply cannot be repaired merely by
reconnecting. Acknowledged DDL whose subsequent validation failed stays blocked.

Target UUID identifies the server, not a particular backup generation. Restoring
a target backup, local writes, and crash-related MyISAM corruption/loss still
require DBA intervention; a successful preflight does not certify table data.

## Planned target maintenance

Request a drain on the running applier:

```sh
kill -USR1 APPLIER_PID
# For an applier running as the container's main process:
docker kill --signal USR1 APPLIER_CONTAINER
```

The applier stops consuming new capture work, finishes its active journaled batch
(or synchronous DDL), persists the applied checkpoint, discards unjournaled
capture/preparation, and exits successfully with `lifecycle: STOPPED` and
`drainRequested: true`. `DRAINING` is progress, not permission to stop MySQL.
Wait for the successful exit and final STOPPED report before target maintenance.
A target/journal failure during draining still blocks. SIGINT/SIGTERM retain
existing cancellation semantics; SIGKILL is not a drain.

After MySQL restarts, use the same configuration and state directory, without
`--initialize`:

```sh
mysql-replicator run --config APPLY.yaml
```

This command may be started while MySQL is still unavailable; it waits and retries.
Drain also interrupts reconnect backoff. On a brand-new run that has never
established target identity, interrupted initialization cannot produce resumable
STOPPED state and fails instead.

## Failure evidence

`targetReconnectEnabled`, `targetReconnectAttempts`, and `targetReconnectReason`
are included in apply summaries. Waiting reports `TARGET_RECONNECTING`, and
`target.reconnect_wait` measures time spent in backoff. `automaticRecovery` remains
false: it describes process-crash and uncertain-write recovery, not reconnect.

A failed DML batch includes `targetFailure` in the summary and stores the latest
report in SQLite:

```sh
sqlite3 STATE_DIR/state.sqlite 'SELECT diagnostic_json FROM target_failure'
```

The report contains the mutation SQL template (without bound values), its
submission/reply phase, and spans of source GTIDs, database/table names, zero-based
row ordinals, counts, and dispositions:

- `acknowledged`: validated successful writes recorded by the executor;
- `possiblyExecuted`: the outstanding mutation chunk, including all source groups
  coalesced into a multi-row INSERT;
- `notIssued`: remaining work that was never submitted.

DDL reports include the pending GTID and source SQL. When the logged query
context decodes successfully, `ddlContext` also records `database`,
`clientCharsetID`, `connectionCollationID`, `serverCollationID`,
`databaseCollationID` (when present), and `defaultUTF8MB4CollationID`.
`serverCollationName` identifies the known MySQL 8.x default, ID 255
(`utf8mb4_0900_ai_ci`); unfamiliar IDs remain numeric. These are the event's
settings, not a later read of the source's current defaults.

With collation mapping omitted, a bare `CREATE DATABASE foobar` inheriting
collation 255 stops with
`unsupported source server collation: collation_server=ID 255 (utf8mb4_0900_ai_ci), database=foobar; unavailable on target; no substitution`.
The JSON output and `target_failure.diagnostic_json` retain the context; the
readable reason is also saved in `state.diagnostic`. This strict default performs
no substitution; see [optional collation mapping](DDL_COMPATIBILITY.md#optional-collation-translation-and-table-replacement)
for the explicit compatibility policy.

A preparation failure has `statement.phase: notIssued` and can leave
`ddl_intents` empty: that table records prepared target execution intents.
`schemas` records table definitions, not a database catalog. Inspect
`target_failure` for the failed SQL and `groups` for its source coordinates:

```sql
SELECT diagnostic_json, created_at FROM target_failure;
SELECT gtid, source_file, start_position, end_position, status
FROM groups WHERE status = 'PENDING';
```

Relay frames and existing row/DDL intents retain source positions, row images,
and schema references.
The report is written only on failure; it adds no SQLite commit per statement.
The most recent report is retained even after a safe reconnect, as incident
history. On abrupt process death, there may be no report: pending journal entries
remain the conservative evidence, and normal resume still refuses them.

Do not use `skip` to bypass uncertain writes: it continues to refuse groups with
write intents. DBA resolution/resynchronization tooling remains separate work.

## Qualification

```sh
swift test
.build/debug/replicator-lab dml-suite --slice target-reconnect --positioning both
```

The live slice includes baseline DML, idle target disconnection, target restart,
active-group drain, drained-state resume while target is unavailable, drain during
backoff, loss of a submitted INSERT reply, and refusal to resume uncertain state.
Unit fault tests additionally cover transport classification, safe removal of
entirely unissued groups, partial-group refusal, coalesced GTID diagnostics,
acknowledgment retention after unlock failure, and interruptible drain/backoff.

Final validation (2026-10-03): 263 Swift tests and 41 live cases passed; static
Linux/musl runtime build passed. All fixture stacks were cleaned up.
- target / file-position: 8 cases, `artifacts/dml-suite/20261003T080420Z-568e6756-position-autocommit-myisam/`.
- target / GTID: 8 cases, `artifacts/dml-suite/20261003T080614Z-27e553e8-auto-autocommit-myisam/`.
- source reconnect: 5 cases, `artifacts/dml-suite/20261003T080439Z-13a7f21e-auto-autocommit-myisam/`.
- extended safety: 20 cases, `artifacts/dml-suite/20261003T080420Z-d6167316-auto-autocommit-myisam/`.

DDL diagnostic follow-up (2026-10-03): 290 Swift tests passed. The GTID database
slice passed all 10 cases, including persisted collation-255 context, explicit
unsupported collation names, unchanged checkpoints/no target creation after
rejection, and the existing permission-failure intent checks. Evidence:
`artifacts/ddl-suite/20261003T192335Z-1af60264-auto-autocommit-myisam/`.
