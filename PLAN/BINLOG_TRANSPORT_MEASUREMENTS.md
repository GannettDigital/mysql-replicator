# BINLOG transport: first reconnect and timing results

Date: 2026-10-17 UTC. Apply implementation: `143d3c9`.
Lab changes: `beta/7/02-binlog-validation`.

## Test scope

The 31 focused lab option and command-line tests passed. Both cross-version
profiles passed `source-reconnect`, `target-reconnect`, `target-uncertain`, and
`target-uncertain-resume` with BINLOG transport. This is eight case/profile
combinations. The failure bundles retain pending row intents and the selected
transport. See [the implementation plan](BINLOG_TRANSPORT.md) for result paths.

## First 10K comparison

Each run used the shared backlog benchmark with 10,000 single-row INSERT
transactions. Source GTID preservation was enabled. The batch limit and prepared
queue capacity were both eight. Applier profiling was enabled. Server and detailed
decoder profiling were disabled. All four runs used the same release runtime
image. The fixture configuration and runtime records are saved with each result.

The runs were sequential: forward SQL, forward BINLOG, reverse SQL, reverse
BINLOG. Each run started a new fixture and measured its native reference first.
The forward reference is 8.4 MyISAM. The reverse reference is 5.7 InnoDB.

| Profile | Transport | Native seconds | Applier seconds | Target SQL seconds | Target calls |
| --- | --- | ---: | ---: | ---: | ---: |
| 8.4 → 5.7 MyISAM | SQL | 8.37 | 38.80 | 24.62 | 50,037 |
| 8.4 → 5.7 MyISAM | BINLOG | 19.45 | 44.36 | 30.87 | 60,031 |
| 5.7 → 8.4 InnoDB | SQL | 37.57 | 50.94 | 36.82 | 50,033 |
| 5.7 → 8.4 InnoDB | BINLOG | 20.16 | 58.93 | 44.97 | 60,037 |

All runs passed the benchmark's row/schema comparisons and checkpoint checks.
Applier wall time includes container startup, connection setup, and shutdown.
Target SQL time includes request/reply time. Stage timers can overlap across
workers; do not add them to calculate wall time.

These are single runs, not medians. The native times vary substantially. Do not
use these numbers to claim a stable native/applier ratio or a release performance
guarantee. BINLOG did not improve elapsed time in these first comparisons.

## Where the time went

The apply worker waited only 0.040–0.045 seconds for prepared batches in each run.
The queue reached its configured capacity of eight. Increasing preparation depth
is not indicated by these measurements.

BINLOG preparation took 1.44 seconds on MyISAM and 1.43 seconds on InnoDB. This
work runs ahead of execution. Base64 encoding on the target worker took 0.40 and
0.46 seconds. The row request timer took 16.41 and 8.36 seconds respectively. That
timer includes base64 encoding and the nested target SQL call.

The BINLOG path made about six target calls per transaction:

1. Check whether the target already has the source GTID.
2. Set `GTID_NEXT` to the source GTID.
3. Send BEGIN.
4. Send the BINLOG row request.
5. Send COMMIT.
6. Set `GTID_NEXT` to AUTOMATIC.

The SQL path made about five calls per transaction in this workload. It uses
autocommit for the INSERT, but its shared source-GTID wrapper still sends COMMIT.
That wrapper also serves statements such as inactive executable comments, which
need an empty GTID transaction to be completed. Do not remove that behavior from
all statements without tests.

`target.binlog.format.count` counts cache checks, not FDE requests. A new
connection installs the format-description event. An unchanged FDE is reused.

## What mysqlbinlog emits

The local 5.7 and 8.4 upstream code and a generated replay script confirm this
structure for a normal row transaction. Session settings are omitted here:

```sql
SET SESSION GTID_NEXT = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:17';
BEGIN;
BINLOG '...';
COMMIT;
SET SESSION GTID_NEXT = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:18';
BEGIN;
BINLOG '...';
COMMIT;
```

The BEGIN comes from the source Query event. The XID event prints as COMMIT.
`mysqlbinlog` assigns the next GTID directly. It does not reset to AUTOMATIC
after each transaction. `end_binlog()` resets it at logical binlog/stream
boundaries. It does not emit a per-transaction `SELECT GTID_SUBSET` query.
DDL can complete its GTID through its own implicit commit. Special cases, such
as filtered or incomplete groups, need separate handling.

References: upstream [5.7 mysqlbinlog](https://github.com/mysql/mysql-server/blob/mysql-5.7.44/client/mysqlbinlog.cc),
[8.4 mysqlbinlog](https://github.com/mysql/mysql-server/blob/mysql-8.4.8/client/mysqlbinlog.cc),
and [5.7 event printing](https://github.com/mysql/mysql-server/blob/mysql-5.7.44/sql/log_event.cc).
The generated local sample is `artifacts/mysqlbinlog-replay-example.sql`.
It was generated with `mysqlbinlog --no-defaults` from the saved offline archive.

## Next work

First review the extra GTID lookup and AUTOMATIC reset calls. Keep BEGIN/COMMIT
for the initial BINLOG path; these match normal mysqlbinlog transaction replay.
Test any change on both target engines, including errors, empty groups, DDL,
disconnects, and resume. A target GTID alone cannot prove that a failed MyISAM
group applied in full. Keep the SQLite mismatch protection.

Then repeat the timing runs and add 25K runs, the two same-version profiles,
multi-row groups, and JSON-heavy workloads. Add a `mysqlbinlog | mysql` baseline
to separate client-protocol overhead from the native replica's internal apply
path. The current results do not measure those workloads or that client baseline.

## Local results

The combined extract is `artifacts/binlog-10k-comparison.json`. Full results:

- `artifacts/lab-benchmark/mysql84-to-mysql57-myisam/20261017T062655Z-4cb1f44b-auto-autocommit-myisam/result.json`
- `artifacts/lab-benchmark/mysql84-to-mysql57-myisam/20261017T062831Z-9fa76e2d-auto-autocommit-myisam/result.json`
- `artifacts/lab-benchmark/mysql57-to-mysql84-innodb/20261017T063018Z-5b732751-auto-transaction-innodb/result.json`
- `artifacts/lab-benchmark/mysql57-to-mysql84-innodb/20261017T063258Z-14f1cfc6-auto-transaction-innodb/result.json`
