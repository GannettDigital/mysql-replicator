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

## mysqlbinlog execution change

Branch `beta/7/03-gtid-call-reduction` now follows mysqlbinlog's transaction
sequence for supported BINLOG groups. It removes the per-group target GTID query
and AUTOMATIC reset. It does not add a batch GTID lookup protocol.

- Assign each recorded source GTID separately. Do not merge GTID transactions.
- Reproduce source BEGIN, COMMIT/XID, and ROLLBACK boundaries. Do not add a
  transaction wrapper merely because the preparation queue contains a batch.
- Emit complete table-map/row statements in source order. Preserve statement-end
  boundaries. The target's BINLOG interface does not accept raw GTID or XID events;
  those events require the SQL forms that mysqlbinlog uses.
- Assign the next GTID directly. Reset AUTOMATIC at the required stream or
  session boundaries, not after every successful group. MySQL also permits
  ordinary SET/SHOW/SELECT statements between GTID transactions; do not add a
  reset for every metadata read without checking that it is necessary.
- Keep format-description and source session context. Match mysqlbinlog's
  special handling for filtered or incomplete groups where applicable.
- Keep local preparation and SQLite checkpoint batches. These are storage and
  scheduling operations, not new target transaction boundaries.

The relay files already retain source event bytes. SQLite retains the checkpoint
and pending row intents. On failure, preserve the last acknowledged transaction,
the pending GTID, the submitted source event range, the target error, and whether
the write or commit reply was received. A failed BINLOG request does not always
identify the exact failing row event. Do not present an inferred offset as an
exact failure position.

Do not automatically resend an uncertain target write. MyISAM can retain part of
a failed request. Keep ordinary resume blocked until the operator resolves the
pending state. A target GTID alone cannot prove that the full group was applied.
MySQL now handles already-executed source GTIDs in BINLOG mode. The existing
SQL path still checks target GTIDs before application.

The implementation sends each complete source row statement in one BINLOG
request. It keeps BEGIN and COMMIT/XID boundaries from the source. It resets
GTID_NEXT before initial or changed format descriptions and at clean shutdown. Empty source
ROLLBACK groups keep ROLLBACK. Ordinary DDL no longer gets an extra COMMIT in
BINLOG mode; inactive whole version comments still complete an empty GTID.

Validation on 2026-10-17 UTC:

- 23 focused Swift tests passed. The request comparison uses saved output from
  `mysqlbinlog 8.4 --no-defaults` on `source-positive.binlog`. The prepared row
  bytes and statement boundaries match its four selected transactions.
- 8.4 → 5.7 MyISAM: `positive` and
  `ddl-compat-executable-comments-target-gate` passed.
  Report: `artifacts/lab/20261017T070057Z-2fea4130/result.json`.
- 5.7 → 8.4 InnoDB: `positive`, `foreign-keys`, and `live-skip-errors` passed.
  This includes multiple source statements under one GTID and confirmed rollback
  before an allowed duplicate skip.
  Report: `artifacts/lab/20261017T070346Z-bad610a4/result.json`.
- MyISAM: `source-reconnect`, `target-uncertain`, and `target-uncertain-resume`
  passed. Report: `artifacts/lab/20261017T070707Z-2e211a00/result.json`.
- InnoDB: `target-uncertain` and `target-uncertain-resume` passed.
  Report: `artifacts/lab/20261017T071007Z-7a9476a4/result.json`.

The first MyISAM run found error 1837 when a lazily installed FDE followed DDL.
The support bundle showed `notStarted`, one pending row intent, and a failed
format request. The fix resets GTID_NEXT before the first FDE as well as a changed
FDE. It does not reset on an unchanged-format cache hit. The corrected cases
passed. Original evidence: `artifacts/lab/20261017T065721Z-5a90d8d1/result.json`.
Only selected cases ran locally. The full suite remains for CI.

## Fresh native, SQL, and BINLOG comparison

All four runs used the same release binary on 2026-10-17 UTC. Each used 10,000
single-row INSERT transactions, `preserveSourceGTIDs: true`, batch size eight,
and preparation queue capacity eight. Applier profiling was enabled; server and
detailed decoder profiling were disabled. Runs were sequential. No correctness
or lifecycle test ran during these measurements. Native replay ran first in each
fixture, followed by the selected external transport.

| Profile | Transport | Native seconds | Applier seconds | Target SQL seconds | Target calls |
| --- | --- | ---: | ---: | ---: | ---: |
| 8.4 → 5.7 MyISAM | SQL | 17.74 | 40.77 | 26.47 | 50,037 |
| 8.4 → 5.7 MyISAM | BINLOG | 7.82 | 37.72 | 25.79 | 40,032 |
| 5.7 → 8.4 InnoDB | SQL | 12.96 | 48.50 | 34.37 | 50,033 |
| 5.7 → 8.4 InnoDB | BINLOG | 13.31 | 49.10 | 36.84 | 40,038 |

The native reference uses 8.4 MyISAM for the forward profile and 5.7 InnoDB for
the reverse profile. These are supported native topologies, not native replication
between the two different versions in each external profile.

All row, schema, and checkpoint checks passed. A comparison of the saved GTID
sets also confirmed that each target added exactly the 10,000 source GTIDs.

BINLOG now uses about four target calls per single-row transaction, compared with
six before this change. The SQL path still uses about five calls. SQL retains
its existing per-transaction GTID query, extra COMMIT, and AUTOMATIC reset. This
comparison measures the current implementations, not only row encoding cost.

The lower BINLOG call count did not give a clear elapsed-time gain over SQL.
InnoDB was nearly equal (48.50 seconds for SQL, 49.10 for BINLOG). MyISAM BINLOG
was 3.05 seconds faster, but its native reference varied from 7.82 to 17.74 seconds
between fixtures. These are single runs. Do not treat that difference as a stable
speed improvement. Both transports remained slower than the native reference.

The combined extract is `artifacts/mysqlbinlog-fresh-comparison.json`. Full results:

- `artifacts/lab-benchmark/mysql84-to-mysql57-myisam/20261017T071837Z-62956cdb-auto-autocommit-myisam/result.json`
- `artifacts/lab-benchmark/mysql84-to-mysql57-myisam/20261017T071122Z-f196a92f-auto-autocommit-myisam/result.json`
- `artifacts/lab-benchmark/mysql57-to-mysql84-innodb/20261017T071548Z-d609db4a-auto-transaction-innodb/result.json`
- `artifacts/lab-benchmark/mysql57-to-mysql84-innodb/20261017T071307Z-a11476b4-auto-transaction-innodb/result.json`

The possible beta.6 slowdown has a separate
[investigation plan](BETA6_PERFORMANCE_REGRESSION.md). No cause is confirmed.

## Further measurements

Repeat the timing runs and add 25K runs, the two same-version profiles, multi-row
groups, and JSON-heavy workloads. Add a `mysqlbinlog | mysql` baseline to separate
client-protocol overhead from the native replica's internal apply path. The
current results do not measure those workloads or that client baseline.

## Local results

The combined extract is `artifacts/binlog-10k-comparison.json`. Full results:

- `artifacts/lab-benchmark/mysql84-to-mysql57-myisam/20261017T062655Z-4cb1f44b-auto-autocommit-myisam/result.json`
- `artifacts/lab-benchmark/mysql84-to-mysql57-myisam/20261017T062831Z-9fa76e2d-auto-autocommit-myisam/result.json`
- `artifacts/lab-benchmark/mysql57-to-mysql84-innodb/20261017T063018Z-5b732751-auto-transaction-innodb/result.json`
- `artifacts/lab-benchmark/mysql57-to-mysql84-innodb/20261017T063258Z-14f1cfc6-auto-transaction-innodb/result.json`
