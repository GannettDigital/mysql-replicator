# OP-11 schema discovery results

Date: 2026-10-20 (America/Los_Angeles).
Branch: `beta/7/04-compatible-sql-routing`, after OP-08 commit `35e9967`.

## Change and scope

Identical metadata reads now reuse their results within one synchronous discovery
operation. Nested FK validation shares these results. The temporary cache is
cleared after success or failure. It does not cache session-local commands,
writes, or query failures. Existing table-cache invalidation at ordered DDL and
new-session setup remains in place.

The table-cache limit is configurable through `maximumCachedTables`. The default
is 6,000; the allowed range is 1 through 100,000. Discovery, validated plans, DDL,
saved-schema reload, and capture use the same limit. Change it before restart.
The separate temporary query cache has a 16 MiB estimated-result budget and a
2,048-query limit. It bypasses insertion when full.

The new lab command measures discovery with an isolated TCP delay proxy. It
accepts the existing four profile names and SQL/BINLOG transports. See
[the benchmark guide](../tools/metadata-benchmark/README.md) for commands.

## Workload

These runs used a local macOS debug binary, MySQL 5.7.42 and 8.4.8 containers,
8 tables, and 128 single-row INSERT transactions. Each table had a primary key,
a secondary index, and integer columns. The InnoDB workload used two FK groups
of four tables. Each group had one parent and three children. MyISAM had no FKs.
Source GTID preservation was disabled. Source binlogs were local, closed files.
The source and target used InnoDB or MyISAM as specified by the profile.

Each run used zero added delay and then 10 ms delay in each direction. Actual
MySQL COM_PING RTT was measured on the same proxy path. The zero-delay proxy
stayed in the path. There was no bandwidth or loss simulation.

The tool compared every target row with the source. A separate phase reopened
the same state, updated a row, added a column with ALTER, and inserted a row.
Both phases passed in every row of the table below. The second phase is excluded
from the throughput figures. No test deliberately interrupted COMMIT or the
network connection; the restart check created new target sessions.

## Measurements

Times are seconds. RTT is milliseconds. Throughput includes startup and shutdown.
Each row is one run, not a statistical performance result.

| Profile | Transport | Added RTT | Measured median RTT | Replay | Metadata | Mutation SQL | Transactions/s |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 5.7 → 8.4 InnoDB | SQL | 0 | 0.48 | 1.987 | 1.313 | 0.262 | 64.43 |
| 5.7 → 8.4 InnoDB | SQL | 20 | 23.32 | 15.467 | 10.088 | 3.813 | 8.28 |
| 5.7 → 8.4 InnoDB | BINLOG | 0 | 0.48 | 2.089 | 1.284 | 0.334 | 61.26 |
| 5.7 → 8.4 InnoDB | BINLOG | 20 | 23.48 | 22.040 | 10.041 | 7.022 | 5.81 |
| 8.4 → 5.7 MyISAM | SQL | 0 | 0.83 | 0.582 | 0.144 | 0.197 | 219.84 |
| 8.4 → 5.7 MyISAM | SQL | 20 | 23.22 | 6.723 | 2.011 | 3.481 | 19.04 |
| 8.4 → 5.7 MyISAM | BINLOG | 0 | 0.61 | 0.689 | 0.133 | 0.239 | 185.69 |
| 8.4 → 5.7 MyISAM | BINLOG | 20 | 22.81 | 13.369 | 2.038 | 6.642 | 9.57 |

`target.sql.write` measures mutation statements. Transaction control, session
setup, and reads are in `target.sql.read_or_control`. Metadata timings are nested
inside other stages. Do not add nested times or parallel-worker times to obtain
elapsed time. These small runs do not compare performance with native replication.

### Query counts

Both transports had the same discovery counts. Each run had eight outer
discoveries, one per table. Later writes caused no new discovery. The five other
metadata commands in each total were readiness/channel/identity checks.

| Target workload | Queries per first discovery | Reads reused per first discovery | Total metadata queries | Total reused reads |
| --- | ---: | ---: | ---: | ---: |
| InnoDB with four-table FK groups | 40 | 17 | 325 | 136 |
| MyISAM without FKs | 8 | 3 | 69 | 24 |

The reused reads remove about 30% and 27% of the metadata read requests within
these discovery operations. This is a measured cache-hit count, not a measured
before/after speedup. No pre-change binary was timed in this experiment.

Query counts are SQL commands, not exact network round trips. The first prepared
query can need a separate prepare request. FK discovery also reads related table
schemas. Thus, one table's first discovery can contain reads for several tables.

At 20 ms added RTT, the InnoDB SQL run spent metadata time as follows:

| Query family | Commands | Seconds |
| --- | ---: | ---: |
| TABLES, including encoding and existence checks | 88 | 2.806 |
| STATISTICS | 64 | 1.842 |
| KEY_COLUMN_USAGE and REFERENTIAL_CONSTRAINTS | 32 | 1.266 |
| Privilege visibility checks | 40 | 1.186 |
| COLUMNS | 32 | 0.977 |
| TRIGGERS | 32 | 0.935 |
| PARTITIONS | 32 | 0.902 |
| Replication and target identity | 5 | 0.174 |

## Conclusions and next measurements

First-table discovery dominates the small InnoDB workload at remote latency.
Warm writes reuse table metadata. Extra row workers will not remove this initial
cost. BINLOG transport did not reduce discovery work in these tests.

Possible further changes need separate checks:

1. Read primary and secondary index metadata in one query. Read engine and
   encoding together. These currently use distinct queries, so exact-query reuse
   cannot combine them.
2. Reuse validated related-table snapshots across discoveries in the same FK
   component. Before doing this, test every affected DDL invalidation path.
3. Measure 2,000–5,000 tables with representative FK components. The current
   results use eight tables. The 6,000-table retention test checks the limit and
   reuse; it does not measure database discovery or memory use at that scale.
4. Measure the remaining two profiles if their source metadata or target-version
   behavior is relevant to deployment. This run covered both target engines,
   both transports, and two target versions; it did not run all four profiles.

The existing OP-09 restricted-account/reconnect checks and OP-10 diagnostic
matrix remain separate work. No full correctness suite was run locally.

Validation also passed 20 focused Swift tests and four Python benchmark/proxy
tests. These include the 6,000-table cache, configurable limits, saved-state
reload, capture invalidation, config documentation/help, and benchmark arguments.

## Saved output

Under `artifacts/metadata-benchmark/` in this worktree:

- `mysql57-to-mysql84-innodb/20261021T062225Z-eb5190c1`: SQL.
- `mysql57-to-mysql84-innodb/20261021T062424Z-e7b6d74b`: BINLOG.
- `mysql84-to-mysql57-myisam/20261021T062558Z-2cdcc197`: SQL.
- `mysql84-to-mysql57-myisam/20261021T062700Z-7926a137`: BINLOG.

Each directory has `result.json`, stage timings, per-table query totals, source
binlogs, configs, and state copies. Failed setup attempts are also retained. The
initial failures were a wrong logging flag, a Unix socket path that was too long,
and a report parser that read the wrong output stream. They were harness defects;
the final measurements above passed.
