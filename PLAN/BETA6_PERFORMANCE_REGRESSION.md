# Investigate the possible beta.6 apply slowdown

Status: open. A regression is suspected, but no commit or cause is confirmed.
Record date: 2026-10-17. Complete the BINLOG transport work first.

## Evidence

Fresh 10,000-transaction backlog runs used one release binary, single-row INSERTs,
source GTID preservation, batch size 8, and preparation queue size 8. Each run
compared the source, native replica, target, and saved position successfully.

| Profile | Transport | Native seconds | Applier seconds | target.sql seconds | Target SQL calls |
| --- | --- | ---: | ---: | ---: | ---: |
| 8.4 → 5.7 MyISAM | SQL | 17.74 | 40.77 | 26.47 | 50,037 |
| 8.4 → 5.7 MyISAM | BINLOG | 7.82 | 37.72 | 25.79 | 40,032 |
| 5.7 → 8.4 InnoDB | SQL | 12.96 | 48.50 | 34.37 | 50,033 |
| 5.7 → 8.4 InnoDB | BINLOG | 13.31 | 49.10 | 36.84 | 40,038 |

The native reference uses the source version and the target engine. Thus the
cross-version comparison also includes a server-version difference. Native times
varied between fixtures. These are single runs, not stable regression estimates.
See [the measurement report](BINLOG_TRANSPORT_MEASUREMENTS.md#fresh-native-sql-and-binlog-comparison)
for the settings and local result paths. The combined extract is
`artifacts/mysqlbinlog-fresh-comparison.json` in the beta.7 worktree.

Earlier project runs were closer to native replication. They are not a controlled
baseline for this change. In particular, source GTID preservation became the
default in beta.6. With it enabled, SQL currently makes approximately five calls
per single-row transaction. Earlier automatic-GTID runs could use one write call.
This is a possible explanation to measure, not a confirmed cause.

## Investigation order

1. Select an earlier fast commit and the beta.6 release tip. Record exact SHAs,
   binary hashes, fixture versions, and effective configuration for each run.
2. Use the same host, workload, engine, indexes, packet limits, batch and queue
   sizes, TLS/socket transport, durability settings, and logging settings.
   Run fixtures sequentially without unrelated test load.
3. Compare SQL with `target.preserveSourceGTIDs: false` at both commits. Compare
   preservation enabled only where both commits support it. Report this option
   separately; do not remove preservation to claim an equivalent speed gain.
4. Repeat 10K runs and confirm with 25K runs. Report median, range, native time,
   target SQL time/calls, preparation time, queue waits, and SQLite time. Include
   the same-version profiles to separate target-version effects.
5. If a slowdown remains under equal settings, bisect the commits. Test one
   change at a time. Check correctness and GTIDs for each comparison.
6. For the current tip, compare native replication, SQL, BINLOG, and a separate
   `mysqlbinlog | mysql` replay. Do not merge source transactions or weaken
   durable-state requirements to reduce protocol calls.

## Completion criteria

Identify a reproducible cause, or show that changed settings explain the observed
cost. Record the commands and results. If a code regression exists, fix it and
rerun the affected correctness cases. Keep performance tuning separate from the
initial BINLOG transport acceptance checks.
