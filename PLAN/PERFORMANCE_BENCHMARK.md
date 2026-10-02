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
| `--batch-transactions` | 32 | Maximum source groups per journal batch; 1–256 |
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

## Journal batching

Journal batching uses DBA-led reconciliation as its recovery contract. Before
target writes, one relay sync and one SQLite FULL transaction record source group
identities, ordered row references, schema/affected-table identities and individual
relay ranges. A second transaction records acknowledged rows and advances the
contiguous whole-group applied boundary. Target SQL remains individual and ordered;
this does not combine source transactions into a MySQL transaction. DDL is a barrier.
Detected failures retain the acknowledged prefix and unresolved intents. A crash
before the completion commit leaves the whole prepared batch uncertain and blocks
automatic replay. Existing lock epoch limits still apply between groups.

The default `batch` configuration collects at most 32 groups, 4,096 rows, 8 MiB
of wire events or 25 ms (checked at capture callbacks). Idle capture flushes
immediately; there is no deliberate wait for a full batch. Table/schema changes,
filtered groups, DDL and finite stop boundaries also flush. An oversized source
group runs alone within existing decoder limits. `apply.batch` measures execution,
including journal preparation/completion, but excludes time collecting groups.

Compare `--batch-transactions 1` and `--batch-transactions 32` on identical burst
workloads using the same image and transport. Size 1 still uses the new two-commit
path for all rows of a source group; it does not restore the old per-row journal.
Check `sqlite.commit`, `relay.sync`, `apply.batch` and exact final data as well as
catch-up time. The full configuration and selected transaction limit are archived.

The journal identifies recorded work and boundaries, not the exact crash instant
or MyISAM's physical durability. DBA restoration requires a consistent source
snapshot and a matching GTID boundary, coordinated with tables that were not
restored. See [DML apply](DML_APPLY.md) for inspection and failure semantics.

### Journal batching validation, 2026-10-01

The static Linux release build, 178 Swift tests, 16 live GTID DML cases and 79
ordered GTID DDL cases passed. Journal fault tests cover rollback during preparation
and completion, acknowledged prefixes, partial rows, unresolved restart refusal and
collection limits. The live process-kill case interrupted a 2,000-row group after
58 target rows: all 2,000 intents remained PENDING, the applied checkpoint remained
unchanged, and restart refused replay without changing those 58 rows. This tests
process-crash evidence, not MySQL/host power-loss durability.

Four sequential 1,000-event single-row INSERT bursts used the same release image
and TCP+TLS transport, in size order 1, 32, 32, 1. All passed exact comparison,
clean STOPPED checkpoints and cleanup.

| Maximum groups | Completion, run 1 / run 2 | SQLite commits | Relay syncs | Actual DML batches |
| --- | ---: | ---: | ---: | ---: |
| 1 | 25.555 / 25.656 s | 2,021 / 2,021 | 1,003 / 1,003 | 1,000 / 1,000 |
| 32 | 19.645 / 19.335 s | 552 / 544 | 269 / 265 | 266 / 262 |

Observed catch-up took about 24% less time; SQLite commits fell about 73%.
Collection averaged 3.8 groups because time/idle boundaries flushed before the
count limit. Inclusive `apply.batch` time fell from 16.6 s to 10.1–10.6 s.
Target SQL still took 6.4–6.8 s and capture decoding 4.6 s in the size-32 runs;
these nested stage totals must not be added together as independent elapsed time.
Polling was about three seconds, and the applier/MySQL 5.7 ran under x86_64
emulation on an ARM Docker host. This is a local comparison, not production capacity.

Machine-readable measurements, the common runtime digest and all four evidence
paths are in `artifacts/performance/batch-comparison-20261002.json`. Qualification
evidence is under `artifacts/dml-suite/20261002T050948Z-3ff4c9e3-auto-autocommit-myisam/`
and `artifacts/ddl-suite/20261002T050832Z-60df0bea-auto-autocommit-myisam/`.

A concurrent mixed run also passed exact comparison and cleanup: 300 transactions,
two clients, 20 events/s and three rows per statement (900 row mutations), using
the default batch limit of 32. Native and custom replication were both observed
complete at 19.3 s. Evidence:
`artifacts/performance/20261002T052129Z-0b463815/20261002T052129Z-c930aae7-auto-autocommit-myisam/`.

## Local target transport comparison

The recorded transport comparison below predates journal batching and keeps the
then-current per-group journal behavior.

`benchmark --target-transport tcp-tls|unix-tls|unix` selects loopback TCP with
verified TLS (default), a Unix socket with the same TLS verification, or a plain
Unix socket. The applier already shares the target's network namespace; all three
modes run beside MySQL 5.7 in the same Docker VM. A project-scoped volume exposes
only its socket directory to the applier. No host MySQL socket is mounted.

Compare equal workloads sequentially with the same runtime image; reverse mode
order on a repeat to expose shared-host variability. `result.json` records the
requested mode and MySQL's observed connection type. Applier preflight checks the
session cipher against the requested TLS policy. Exact source/native/target data
comparison and SQLite progress checks remain enabled for every mode. The source
connection always uses TLS. The plain socket fixture account is local-only; the
TCP account still requires TLS and the server retains `require_secure_transport`.

```sh
swift run replicator-lab benchmark --events 1000 --rate 0 --sample-seconds 2 --target-transport tcp-tls
swift run replicator-lab benchmark --skip-build --events 1000 --rate 0 --sample-seconds 2 --target-transport unix-tls
swift run replicator-lab benchmark --skip-build --events 1000 --rate 0 --sample-seconds 2 --target-transport unix
```

A socket changes per-exchange overhead, not SQL command count. Separating Unix
socket with TLS from plain Unix socket distinguishes transport overhead from TLS
cost. ARM-host emulation of the x86_64 applier and MySQL 5.7 remains a limitation;
repeat on the intended deployment host before treating the result as a capacity
estimate.

### Local transport results, 2026-10-01

The Linux release build and 170 Swift tests passed. Two 1,000-event single-row
INSERT bursts per mode used the same image. Order was TCP+TLS, Unix+TLS, Unix,
then Unix, Unix+TLS, TCP+TLS, with one fixture running at a time. All six passed
exact source/native/target data comparison, clean STOPPED checkpoints and cleanup.

| Target transport | Completion observed, run 1 | Run 2 | Row-apply stage, run 1 / run 2 |
| --- | ---: | ---: | ---: |
| Loopback TCP + TLS | 31.724 s | 28.879 s | 2.549 / 2.327 s |
| Unix socket + TLS | 34.815 s | 31.920 s | 2.567 / 2.568 s |
| Plain Unix socket | 28.897 s | 29.031 s | 2.229 / 2.200 s |

There is no demonstrated end-to-end throughput gain beyond host/polling variation:
the faster TCP run matched both plain-socket runs. The fixed 1,000-row apply stage
averaged about 9% less time for plain sockets than TCP+TLS. Total target SQL time
averaged 7.486 s versus 8.535 s, but command counts vary with time-bounded lock
epochs, so that comparison includes fewer schema/lock commands as well. Unix+TLS
showed no benefit; its first run also spent 7.244 s decoding versus roughly
4.7–4.8 s in the other runs, illustrating unrelated host variation. Every run
retained 3,021 SQLite commits and 1,003 relay syncs.

This supports an optional local transport, not a claimed major speedup or a new
default. These measurements isolate transport from the later journal batching change.
Machine-readable summary, runtime digest and all six evidence paths:
`artifacts/performance/socket-comparison-20261002.json`.

A plain-socket mixed run also passed exact comparison and cleanup: 300 source
transactions, two threads, 20 events/s and three rows/event (900 row mutations).
Both replicas were observed complete at 19.5 s. Evidence:
`artifacts/performance/20261002T031131Z-80709d4e/20261002T031131Z-c381e5dd-auto-autocommit-myisam/`.

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
