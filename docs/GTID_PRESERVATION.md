# Preserve source GTIDs

Set this target option in the run or replay configuration:

```yaml
target:
  preserveSourceGTIDs: true # Default.
```

With `true`, the applier assigns the source GTID to each target transaction with
`SET SESSION GTID_NEXT`. It retains the source UUID and sequence number. It also
retains the tag when the target supports tagged GTIDs and permits their use.
Target writes must remain in the binary log.

With `false`, the applier tracks source GTIDs only in SQLite. The target uses its
normal GTID assignment. An InnoDB target generates its own GTIDs. A MyISAM target
with `gtid_mode=OFF_PERMISSIVE` can write anonymous transactions. This setting
does not disable target binary logging.

SQLite remains the replication checkpoint in both cases. The target GTID set
does not replace it. A MyISAM statement can fail after some writes and still
record its GTID. A recorded GTID alone does not prove that all rows were applied.

## Target privileges

These privileges are additional to the data, DDL and discovery privileges that
the selected profile requires. Grant them to the target connection account.

| Target | Privilege for `SET SESSION GTID_NEXT` |
|---|---|
| Self-managed MySQL 5.7 | `SUPER` |
| Self-managed MySQL 8.4, ordinary GTIDs | One of `SESSION_VARIABLES_ADMIN`, `REPLICATION_APPLIER`, `SYSTEM_VARIABLES_ADMIN`, or `SUPER` |
| Self-managed MySQL 8.4, tagged GTIDs | `TRANSACTION_GTID_TAG`, plus one of `SESSION_VARIABLES_ADMIN`, `REPLICATION_APPLIER`, or `SYSTEM_VARIABLES_ADMIN` |

For example, an administrator can grant ordinary GTID assignment on MySQL 8.4:

```sql
GRANT SESSION_VARIABLES_ADMIN ON *.* TO 'applier'@'REPLACE_CLIENT_HOST';
```

Add `TRANSACTION_GTID_TAG` only if tagged GTIDs must be preserved. On 5.7, the
corresponding grant is `SUPER ON *.*`. These are server-wide privileges. Choose
the account and allowed client hosts as part of target deployment.

The startup check sets `GTID_NEXT=AUTOMATIC` on the apply connection. This checks
ordinary GTID assignment permission without adding a GTID. Tagged assignment has
an additional privilege check when a tagged transaction arrives. There is no
automatic fallback to `preserveSourceGTIDs: false`.

The SQL MyISAM path also needs `CREATE`, `DROP`, `SELECT`, `INSERT`, `CREATE ROUTINE`,
`ALTER ROUTINE` and `EXECUTE` on the reserved `_mysql_replicator_gtid` database.
It uses `SUPER` to change `sql_log_bin` for scratch preparation and to create
stored functions with binary logging enabled. Do not use this database for
application objects. Focused integration tests cover multi-row writes, JSON documents and keyless
duplicates. They do not prove that every MyISAM value type works in this helper.

Sources: [MySQL 5.7 GTID variables](https://dev.mysql.com/doc/refman/5.7/en/replication-options-gtids.html),
[MySQL 8.4 GTID variables](https://dev.mysql.com/doc/refman/8.4/en/replication-options-gtids.html),
and [stored program binary logging](https://dev.mysql.com/doc/refman/5.7/en/stored-programs-logging.html).
The local 5.7 and 8.4 `sql/sys_vars.cc` checks agree with these assignment rules.

## Cloud SQL

Documentation reviewed on 2026-10-16. No live Cloud SQL instance was tested.

Cloud SQL does not give customer accounts `SUPER`. Its documented
`cloudsqlsuperuser` role does not list `SESSION_VARIABLES_ADMIN`,
`SYSTEM_VARIABLES_ADMIN`, or `REPLICATION_APPLIER`. It does list
`CLOUDSQL_SPECIAL_VARIABLES_ADMIN`, but the cited documentation does not establish
that this privilege permits explicit `GTID_NEXT` assignments. Do not assume that
the role name gives the same rights as a self-managed MySQL administrator.
See [Cloud SQL user privileges](https://docs.cloud.google.com/sql/docs/mysql/users).

Treat source GTID preservation as unavailable under the documented Cloud SQL
customer permissions. Use this setting for a Cloud SQL target:

```yaml
target:
  preserveSourceGTIDs: false
```

SQLite still retains the source GTIDs for resume and duplicate checks. Cloud SQL
assigns its own GTIDs to the writes. Use a new state directory and a verified data
baseline when changing this setting. Do not change it on an existing state
directory. Enable preservation only if a test on the actual service version and
account confirms that explicit assignment is permitted.

For an initial permission check, connect as the intended applier user and run:

```sql
SELECT VERSION(), CURRENT_USER(), @@GLOBAL.gtid_mode, @@SESSION.gtid_next;
SHOW GRANTS;
SET SESSION GTID_NEXT='AUTOMATIC';
```

These statements do not add a GTID or change rows. A successful result is not a
full Cloud SQL test. Explicit source-GTID assignment and the data commit still
need a disposable-instance test. Do not use an arbitrary source GTID on a
production target as a permission probe.

Cloud SQL 8.4 explicitly does not support tagged GTIDs and does not grant
`TRANSACTION_GTID_TAG`. A version check alone is not sufficient for that service.
See [Cloud SQL feature limits](https://docs.cloud.google.com/sql/docs/mysql/features).

Google documents two related procedures:

| Procedure | Documented purpose |
|---|---|
| `mysql.skipTransactionWithGtid(gtid_set)` | Set imported GTID history during external-replica setup. |
| `mysql.skipReplicationError()` | Skip a failed native replication transaction and restart native replication. For GTID replication, it inserts an empty transaction. |

The first procedure appears in the
[custom import workflow](https://docs.cloud.google.com/sql/docs/mysql/replication/custom-import-replication-from-external).
That workflow installs replication procedures after `demoteMaster` and removes
them after `promoteReplica`. The second is described in the
[stored procedure reference](https://docs.cloud.google.com/sql/docs/mysql/stored-procedures).
Neither procedure is documented as an interface that assigns a source GTID to
arbitrary application writes on our connection.

Do not call a skip procedure after each applied transaction to simulate
preservation. That would separate the data commit from the source GTID record.
It would also leave the data transaction in the binlog under a different GTID.
The applier does not use these procedures or change Cloud SQL replication roles.

## Tagged GTIDs

With preservation enabled, MySQL 5.7 cannot represent `UUID:TAG:NUMBER`. The
applier blocks before application writes. It does not remove the tag or allocate
a replacement source sequence number.

With preservation disabled, the same events can be applied to MySQL 5.7. SQLite
retains the complete identity for duplicate checks, restart and replay. For
example, `uuid:9`, `uuid:blue:1` and `uuid:green:1` remain three different GTIDs.
Write order remains the captured source order in both cases.

## State and recovery

State format 14 records `preserveSourceGTIDs`, the table filters, and the DML transport. Format 12 introduced the GTID setting. Resume and recovery must use the
same value. Older state used target-assigned GTIDs and requires explicit `false`
to upgrade. Enabling preservation needs a new, verified baseline. The applier
does not backfill source history from before that baseline or erase target GTIDs.
The DBA must establish the snapshot's GTID history separately if the target must
also report source transactions from before this run. Other target transactions
can add GTIDs under other UUIDs, so the entire target GTID set can differ from
the source set.

With SQL transport, a per-transaction check blocks if the target already has a
source GTID that SQLite has not completed. BINLOG transport follows `mysqlbinlog`:
it omits this query and lets MySQL skip an already-executed GTID. A transaction
selected for SQL compatibility handling retains the SQL check. In both modes,
pending SQLite intents still block ordinary restart after an uncertain write.
Keep the saved intents and inspect the target rows. A recorded target GTID is
not proof that a failed MyISAM group applied in full.

Filtered and intentionally skipped groups record an empty source GTID when
preservation is enabled. An offline operator recovery action queues this marker
in SQLite. The next run writes the marker before it applies new groups. Filters
and skips can therefore make target data differ even when the source GTID sets
match. The same concern applies to filtered native replication.

## MyISAM statement boundaries

Native replication applies row events within the source statement boundary. A
normal SQL client can need several target statements for the same rows. MySQL
5.7 completes an explicit GTID after the first MyISAM statement, even inside
`BEGIN` and `COMMIT`.

The SQL transport uses one direct statement when possible. For larger groups,
it prepares typed values in an unlogged scratch table and creates a stored
function. One outer `SELECT` executes the ordered writes under the source GTID.
Scratch objects are not a second replication journal. SQLite still records all
pending work before execution. The helper does not make MyISAM writes atomic.
The local function probe's binlog contained its INSERT, UPDATE and DELETE under
one explicit GTID, followed by one COMMIT.

A local native 5.7 test used an InnoDB source and a MyISAM replica with
`log_slave_updates=ON` and `gtid_mode=OFF_PERMISSIVE`. One three-row INSERT and one
three-row UPDATE each retained the source GTID. A source transaction with two
statements applied its first statement, recorded the GTID, then stopped with
error 1837. Keep the existing one-source-statement MyISAM restriction.

## Test results

On 2026-10-16, `ddl-compat-source-gtid-preservation` passed on all four profiles.
It checked DDL, a 40-row INSERT, multi-row UPDATE and DELETE, keyless duplicate
rows, process restart, replay stop/resume, and source GTIDs on the target.
The local report is `artifacts/lab/20261016T211104Z-ae86561f/result.json`.
No Cloud SQL instance or performance benchmark was included in this run.
