# Native versus custom replication benchmark

`make benchmark` runs [sysbench](https://github.com/akopytov/sysbench) against a
fresh MySQL source while native replication and mysql-replicator consume the
same binlog. It reports source commits, applied transactions, backlog bounds,
and observed catch-up time, then compares exact final rows on all three servers.

This is a repeatable local baseline for investigating costs. No performance
threshold is currently a pass/fail requirement; a pass means the requested load
completed, both replicas caught up, final data matched, and cleanup succeeded.

## Run

Requirements: Swift, Docker Compose with Linux/amd64 support, and OpenSSL.
The load generator and SQLite CLI run in containers. No host sysbench or
mysqlbinlog installation is needed. Run from the repository root:

```sh
# 1,000 single-row INSERT transactions, offered at 100 events/sec, one client.
make benchmark

# Small harness check: concurrent writers and three rows per statement.
make benchmark ARGS='--events 60 --rate 10 --threads 2 --rows-per-event 3 --workload mixed'

# Reuse images built from these exact inputs; offer writes as fast as possible.
make benchmark ARGS='--skip-build --events 5000 --rate 0'

# Rate-controlled run with larger rows.
make benchmark ARGS='--skip-build --events 3000 --rate 100 --payload-bytes 512'
```

Each invocation creates its own stack under `artifacts/performance/`, without
using or replacing the interactive demo session. Normal completion and caught
errors stop the load generator, archive logs and local replication state, and
delete the run's containers and volumes. Abruptly killing the harness may leave
resources behind; its `compose.yaml`, run identifier, and `current.json` identify
the stack. Do not use the interactive demo commands to manage a benchmark stack.

| Option | Default | Meaning |
| --- | --- | --- |
| `--events` | 1000 | Total statements, across all clients; 1–1,000,000 |
| `--threads` | 1 | Source connections; 1–32 |
| `--rate` | 100 | Offered statements/sec across all clients; 0 means unlimited |
| `--workload` | insert | `insert`, or `mixed` INSERT/UPDATE/DELETE cycles |
| `--rows-per-event` | 1 | Rows changed by each statement; 1–100 |
| `--payload-bytes` | 100 | ASCII payload bytes per row; 0–1024 |
| `--sample-seconds` | 5 | Desired polling interval; 1–30 seconds |
| `--timeout` | 300 | Separate load and catch-up deadlines; 10–3600 seconds each |
| `--skip-build` | off | Reuse existing runtime and load-generator images |

Rebuild after code changes. The workload hash is checked even with `--skip-build`;
the replicator image digest and the skip-build choice are recorded. A reused
runtime is not automatically proven to match the current source tree.

## Workload and topology

The benchmark reuses the demo's isolated topology and verified TLS replication:

- MySQL 8.4 InnoDB source.
- Native MySQL 8.4 MyISAM replica, with parallel replication disabled.
- mysql-replicator's static release executable applying to MySQL 5.7 MyISAM.

The sysbench image uses pinned Ubuntu 24.04 and
[sysbench 1.0.20+ds-6build2](https://packages.ubuntu.com/noble/amd64/sysbench).
Its fixture account can only SELECT/INSERT/UPDATE/DELETE in the benchmark database and
must use TLS. It connects only to the disposable source. The harness does not
accept external database credentials or endpoints.

The custom Lua workload uses supported BIGINT and VARCHAR columns, a primary key,
and one autocommit statement per event. It avoids explicit multi-statement
transactions, which are outside the current MyISAM application contract. Every
event changes exactly `rows-per-event` rows. Each client owns disjoint keys.
`mixed` cycles through INSERT, UPDATE, and DELETE as separate events; a finite
run may end partway through a client's cycle. Errors are fatal rather than
silently retried. The event limit, committed GTID count, and applied row count
must agree.

Schema creation and applier startup finish before measurement. The baseline
excludes setup transactions. There is no warm-up phase yet; initial table/schema
discovery, allocation, and filesystem costs remain in the measured run.

## Read the results

The console and `samples.tsv` show source, native, and custom applied transaction
counts. Source progress comes from committed GTIDs after the baseline; native
progress comes from its executed GTIDs; custom progress comes from SQLite's
fully applied checkpoint. Received binlog position is not counted as applied.

The source is polled before and after the two replica counters. The resulting
backlog range accounts for commits during polling. `start_seconds` and
`end_seconds` delimit that observation window on the harness's monotonic clock.
The polling interval can exceed the requested interval under load; use the actual
timestamps. Resource collection and native health checks add monitoring overhead.

Artifacts include:

- `result.json`: options, images, source event rate, observed completion/drain
  times, samples, baseline/final boundaries, server settings, and outcome.
- `samples.tsv`: cumulative progress and backlog bounds for plotting.
- `sysbench.log`: source throughput and source statement latency, including p95.
- `resources-N.ndjson`: Docker CPU/memory/I/O snapshots following sample N.
- `verification.json`: bounded-page comparison of ordered IDs, exact payload
  bytes, and quantities after both replicas finish.
- `inputs.json`, `containers.json`, and `compose.yaml`: input hashes and runtime
  configuration; `captured/` retains SQLite, relay files, and applier logs.

Sysbench latency measures source statements, not replication latency. Completion
and drain times are polling observations, not exact last-commit timestamps. Native
and custom completion are checked separately, so the faster replica does not
inherit the slower replica's completion time. An already caught-up replica has
near-zero observed drain time. No p95/p99 replication latency is claimed.

For a rate sweep, keep workload, row size, client count, host, and storage fixed;
increase `--rate` between fresh runs. Watch whether backlog grows during load and
how quickly it drains afterward. Repeat runs before drawing conclusions. Use
`--rate 0` for a burst/catch-up experiment, not as a steady-state capacity claim.

## Interpretation limits and next measurements

All services share the Docker host. Native and custom targets use different
MySQL versions, and Apple Silicon runs the x86_64 applier/5.7 target through
emulation. Recordings on that setup qualify the harness, not fleet throughput or
an apples-to-apples native/custom speed ratio. Target binlogging and the current
durability checks stay enabled. Storage limits and fail-stop behavior also stay
enabled: overload, unsupported work, or uncertain writes fail the run.

Next measurements should include repeated runs on native x86_64 hardware,
representative preloaded tables and indexes, hot-key updates and replica readers,
separate generator/reference resources, and stage timings for SQL, SQLite commits,
relay synchronization, and decoding. This first harness has no fault injection,
WAN simulation, automatic recovery, or continuously loaded recovery scenario.

## Initial harness validation, 2026-10-01

153 Swift tests passed, including GTID counting, polling bounds, sysbench summary
parsing, and option validation. Two end-to-end runs passed with cleanup:

- Mixed: 60 statements, two clients, three rows per statement, offered at 10/sec.
  Source committed 60 transactions; the replicator applied 180 row changes.
- Insert burst: 1,000 single-row statements, one client, unlimited offered rate.
  Sysbench reported 1.624 seconds of load (615.8 events/sec). Native completion
  was observed at 3.860 seconds after generator launch; custom completion at
  53.053 seconds. All 1,000 final rows matched exactly.

These are single-run Apple Silicon/Docker observations with emulated x86_64
components and roughly three-second effective polling, not capacity estimates.
Local evidence is retained under `artifacts/performance/20261002T011855Z-99bb41d0/`
(mixed) and `artifacts/performance/20261002T012126Z-b2f83a63/` (burst). Artifacts are
ignored by Git. The source load duration comes from sysbench; replica completion
timestamps come from the harness, include launch overhead, and are polling bounds.

## Stage timings and optimizations

Every final STOPPED summary, or BLOCKED error progress, includes `stageTimings`.
These are monotonic, run-local counters (reset on resume), with `count`, `failures`,
`seconds` and `maximumSeconds` per stage. Failed attempts include the typed
cancellation that ends an idle capture cleanly. Ordinary per-group progress omits the
timing summary to avoid repeatedly formatting it in the apply path. The benchmark
exports the final values to `stage-timings.json` and `result.json.stage_timings`.
Timings include startup and graceful stop. They are inclusive and overlap:
`target.schema`, `target.row`, `target.lock` and `target.unlock` contain
`target.sql`; `sqlite.capacity` can contain `sqlite.checkpoint`; `capture.wait`
can contain idle lock release. Do not sum all stage durations as elapsed time.
No SQL text, bind values or credentials are included.

- `capture.wait`: waiting for dump packets (including source idle time).
- `capture.decode`, `capture.assemble`: decoding/probing and group assembly.
- `relay.append`, `relay.sync`: relay framing/writes and durable synchronization.
- `sqlite.capacity`, `sqlite.checkpoint`: full capacity inspection and WAL checkpoint.
- `storage.free_space`: filesystem free-space sampling.
- `sqlite.commit`: autocommit write execution or explicit COMMIT; includes failed
  attempts. Initialization PRAGMAs are counted as statements, not commits.
- `sqlite.statement`: statements executed inside SQLite transactions and PRAGMAs.
- `target.sql`: awaited SQL commands, including preparation on a cache miss.
- `target.read`: pre-write row reads, including the new-key check for key changes.
- `target.schema`, `target.row`, `target.lock`, `target.unlock`,
  `target.statement_invalidation`: inclusive target operations.

The initial optimization pass (commit `78546f0`) kept individual target row writes, full
before/after-image checks, strict affected-row checks, FULL SQLite durability,
relay synchronization and fail-stop/no-retry behavior:

1. WAL truncation runs at a size/capacity threshold, during pressure maintenance,
   or on clean stop/block. The normal threshold is the smaller of 1 MiB and a
   quarter of the database budget. Capacity checks still run before each write
   transaction and reserve a worst-case transaction plus WAL headers/diagnostic
   space. Pinned readers may coexist with a small WAL; they cause a safe stop if
   they prevent the required checkpoint. Autocheckpoint is disabled so these
   explicit checkpoints are measured and bounded.
2. The target connection caches at most 128 prepared statements. DDL barriers
   clear them, errors evict them without retry, and closing the connection
   releases the cache. The four native-worker status queries use one UNION ALL;
   channel and writer ownership checks still run for every DML group.
3. The last verified row's DONE update and its group's applied checkpoint commit
   together. Its PENDING intent was durably committed before the target write.
   A failed completion commit leaves the intent PENDING and cannot advance the
   checkpoint. Earlier rows retain individual durable DONE records.
4. Consecutive groups can reuse the same continuously held WRITE table lock and
   validated schema. An epoch ends after 32 groups or 50 ms, checked at safe
   boundaries; this is not a hard deadline interrupting an in-flight group or
   SQL command. Idle capture, table changes, DDL, filtering, stop and failure
   release the lock. Reacquisition revalidates the complete schema. Trigger
   visibility privileges and writer/channel checks are never cached across
   groups. Target-local DDL cannot change the locked table; after release its
   changes must pass validation before another mutation.

SQLite durability does not make a MyISAM target write atomic with its journal.
Uncertain target outcomes remain blocked for explicit operator resolution. There
is no row batching, parallel application or speculative checkpoint advancement.

The subsequent pass removes post-write SELECTs: a successful target SQL response
with the expected affected-row count permits DONE. Before-image, absent-key,
schema and strict-mode checks remain. MyISAM write acceptance does not imply crash
durability; ambiguous outcomes still block. Qualification independently compares
source, native and custom replica values and asserts the remaining read counts.

Capacity inspection now defaults to every 1,000 completed source groups or five
seconds of activity, with earlier checks near pressure. Configure
`storage.capacityCheckEveryTransactions` up to 10,000 and
`storage.capacityCheckIntervalSeconds` up to 60. In-memory WAL frame tracking and
conservative byte accounting preserve per-write limits without filesystem or
page-count queries on every write. See the [storage policy](SCHEMA_DISCOVERY_AND_RETENTION.md).

## Acknowledgment and periodic-capacity validation, 2026-10-01

168 Swift tests pass, including inspection cadence/time/headroom boundaries,
cached capacity with bounded WAL growth during unfinished groups, a pinned reader
blocking the required checkpoint, and external disk pressure detected on timer
expiry. The GTID DML suite passed all 14 cases. A selected GTID DDL run passed its
basic DML dependency, VARCHAR widening and index creation, including subsequent
INSERT/UPDATE/DELETE and independent schema/data/binlog comparisons. The full
ordered DDL suite was not repeated for this pass.

The same 1,000 single-row INSERT burst passed exact data comparison and cleanup:

| Observation | Previous pass | This pass |
| --- | ---: | ---: |
| Source load duration | 1.636 s | 1.673 s |
| Native completion observed | 3.888 s | 3.394 s |
| Custom completion observed | 38.208 s | 28.071 s |
| Full SQLite capacity inspections | 3,011 | 8 |
| Capacity inspection time | 5.471 s | 0.019 s |
| SQLite commits | 3,021 | 3,021 |
| WAL checkpoints | 44 | 44 |
| Target SQL commands, including setup | 11,329 | 9,353 |

Observed custom completion time fell about 27% in this run. Host emulation and
polling still limit timing precision; this is not isolated attribution or a
production throughput estimate. The current run sampled filesystem free space
nine times and issued exactly 1,000 pre-write row reads. Fewer lock epochs
(413 versus 535) also reduced schema-related SQL as application became faster.

Burst evidence:
`artifacts/performance/20261002T024054Z-d3c5b8b8/20261002T024054Z-596d767b-auto-autocommit-myisam/`.
DML evidence: `artifacts/dml-suite/20261002T023701Z-0505f352-auto-autocommit-myisam/`.
Selected DDL evidence: `artifacts/ddl-suite/20261002T023611Z-70c2bf7d-auto-autocommit-myisam/`;
its coverage inputs remained unchanged during the run.

The mixed workload also passed exact data comparison and cleanup: 300 source
transactions, two threads, 20 events/s, three rows/event (900 row mutations).
Source load took 14.501 s; both replicas were observed complete at 18.267 s.
This rate-limited observation is not a claim of equal maximum throughput.
Evidence: `artifacts/performance/20261002T024238Z-c8737d95/20261002T024238Z-f6c4225b-auto-autocommit-myisam/`.

## Optimization validation, 2026-10-01

164 Swift tests pass, including rollback of the combined final-row/checkpoint
commit, bounded WAL growth with a pinned reader, prepared-statement bindings and
invalidation, and lock-epoch limits. The GTID DML suite passed 14 cases, including
partial writes and a new live check that target-local index DDL succeeds during
idle capture, then blocks the next source write at schema revalidation. The
ordered GTID DDL suite passed 79 cases covering schema/data/binlog order and
expected rejections. The DDL catalog structure check also passes.

The final 1,000 single-row INSERT burst passed exact data comparison and cleanup:

| Observation | Original harness run | Optimized final run |
| --- | ---: | ---: |
| Source load duration | 1.624 s | 1.636 s |
| Native completion observed | 3.860 s | 3.888 s |
| Custom completion observed | 53.053 s | 38.208 s |

This is about 28% less observed custom completion time (1.39x ratio), not an
isolated attribution to individual optimizations or a production capacity claim.
An exploratory optimized run observed 34.807 s before the final instrumentation
changes; shared-host/emulation variation and polling remain material.

Final run stage totals include target SQL 10.709 s, capacity checks 5.471 s,
decoding 4.884 s, SQLite commits 2.803 s, relay appends 2.583 s, and relay syncs
0.672 s. There were 44 explicit WAL checkpoints (0.083 s), 535 table-lock epochs,
and 11,329 SQL commands including setup. Schema checks took 5.238 s and overlap the SQL total; these durations must
not be added together. Capture wait includes setup/idle time and is not apply
latency. These results identify remaining work; they do not justify removing
checks or weakening durability.

Final burst evidence:
`artifacts/performance/20261002T021411Z-5d924715/20261002T021412Z-21fe7c1b-auto-autocommit-myisam/`.
DML evidence: `artifacts/dml-suite/20261002T020555Z-79f95d3d-auto-autocommit-myisam/`.
Ordered DDL evidence: `artifacts/ddl-suite/20261002T020557Z-b815140b-auto-autocommit-myisam/`.

A final mixed run also passed exact data comparison and cleanup: 300 transactions,
two source clients, three rows per statement, offered at 20 transactions/sec;
900 row changes applied. Source load was 15.637 s, native completion was observed
at 19.223 s and custom completion at 22.339 s. Evidence:
`artifacts/performance/20261002T021655Z-c4964d59/20261002T021655Z-9f088254-auto-autocommit-myisam/`.
