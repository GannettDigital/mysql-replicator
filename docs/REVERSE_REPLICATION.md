# Experimental 5.7 → 8.4 InnoDB profile

This is an initial DML implementation, not Cloud SQL qualification or a complete
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
particular, text is limited to the supported utf8mb4 collations. Composite keys,
PK updates, multiple source statements and multiple tables per transaction are
supported in this profile. Target triggers and foreign keys (including incoming
references/cascades) are rejected. Dynamic DDL is blocked before execution in
this first increment; schema reconciliation and DDL qualification are next work.

The source needs its normal replication privileges. The target needs DML and
schema visibility privileges, including explicit TRIGGER visibility and
REPLICATION CLIENT to exclude native replication. The reverse harness uses no
SUPER grant for the applier and does not assign GTID_NEXT. Managed-service
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
command still refuses groups with write intents. The planned inspection and
audited mark-applied/retry/skip commands are not implemented yet; do not edit
SQLite lifecycle fields to bypass that refusal.

SQLite state format 9 pins the profile. Cleanly stopped older MyISAM state can
upgrade in place; older state cannot be adopted as an InnoDB checkpoint. Older
runtimes reject format 9. Back up the stopped state before upgrading.

## Developer qualification

```sh
make test
make reverse-suite
```

The Docker fixture seeds two servers at a known boundary, exercises multi-table
transactions, composite keys, repeated row updates, unsigned BIGINT values,
decimal/ENUM/SET/binary values and clean resume. A deliberate target duplicate
key checks that an earlier successful statement is rolled back, SQLite remains
at the prior commit, and failed intents survive. Unit fault tests cover lost
commit replies and failed rollback. Evidence goes to `artifacts/reverse-suite/`.

No native 5.7 → 8.4 replica is assumed as a reference. Final row equality and
transaction/failure assertions are checked directly. Full-chain, realistic
latency/performance, crash reconciliation and Cloud SQL tests remain planned.
The downstream MyISAM profile currently rejects multi-statement/multi-table
source groups, so the complete three-server chain is not yet supported for
those workloads.
