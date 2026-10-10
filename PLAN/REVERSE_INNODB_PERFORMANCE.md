# Reverse InnoDB performance investigation

Date: 2026-10-09 (local); evidence directory timestamps use UTC, 2026-10-10.

## Method

Replay 10,000 source transactions from a fixed backlog, first through native
replication, then through mysql-replicator. Compare final rows and schemas against
the source and check the final source GTID checkpoint. The default workload is one
single-row INSERT per transaction into `reverse_poc.aux`.

- Source: MySQL 5.7.42, InnoDB.
- Native reference: MySQL 5.7.42, InnoDB, one SQL applier thread.
- External target: MySQL 8.4.8, InnoDB, one client connection for writes.
- Release Linux x86_64 binaries and containers on Docker Desktop / Apple Silicon.
- TCP with TLS; all three servers have `sync_binlog=1` and
  `innodb_flush_log_at_trx_commit=1`.
- Native `log_slave_updates=ON`; our target also has binary logging enabled and
  the applier requires `sql_log_bin=1`.
- SQLite and relay durability settings are unchanged. Journal batches default to
  eight transactions in this harness (the application default is 32).

This measures the supported topologies, including the difference between MySQL
versions. It is not an isolated comparison of two appliers on identical servers.
Startup and Docker control overhead are included. Runs are sequential, with no
other lab fixtures active; unrelated existing Docker containers were left alone.
These local measurements do not establish Cloud SQL throughput or network latency.

## Native commits and binary logging

Native replication does commit transactions and write a replica binlog. It avoids
the external client's SQL protocol requests, not the storage engine's commit work.

The local upstream checkouts are MySQL 5.7.44 and 8.4.8 (the 5.7 runtime fixture is
5.7.42). In `sql/log_event.cc`, the row applier calls `ha_write_row()`;
`Xid_log_event::do_commit()` calls `trans_commit()` and finishes GTID accounting.
In 5.7 `sql/handler.cc`, `handler::ha_write_row()` calls the engine's `write_row()`
and then `binlog_log_row()`. `MYSQL_BIN_LOG::prepare()` in `sql/binlog.cc` explicitly
uses `log_slave_updates` for the replica thread. The binlog coordinator has flush,
sync and commit stages; its group-commit machinery does not remove transaction
boundaries.

References: [5.7 log_event.cc](https://github.com/mysql/mysql-server/blob/mysql-5.7.44/sql/log_event.cc),
[5.7 handler.cc](https://github.com/mysql/mysql-server/blob/mysql-5.7.44/sql/handler.cc),
[5.7 binlog.cc](https://github.com/mysql/mysql-server/blob/mysql-5.7.44/sql/binlog.cc),
[8.4 log_event.cc](https://github.com/mysql/mysql-server/blob/mysql-8.4.8/sql/log_event.cc),
[replica update logging](https://dev.mysql.com/doc/mysql-replication-excerpt/5.7/en/replication-options-binary-log.html).

Our InnoDB path currently sends `START TRANSACTION`, each row statement, and
`COMMIT` for every source transaction. Source GTIDs live in SQLite; these writes
generate target-local GTIDs. Native replication retains the source GTIDs.

## Instrumentation

The backlog harness now accepts `--decoder-profile on|off`,
`--applier-profile on|off`, and `--batch-transactions 1..256`. Historical defaults
are retained: decoder off, applier on, batch limit eight. Example:

```sh
make lab-benchmark PROFILE=mysql57-to-mysql84-innodb ARGS="--events 10000 --decoder-profile on"
make lab-benchmark PROFILE=mysql57-to-mysql84-innodb ARGS="--skip-build --events 10000 --decoder-profile off --applier-profile off"
make lab-benchmark PROFILE=mysql57-to-mysql84-innodb ARGS="--skip-build --events 10000 --decoder-profile off --applier-profile off --batch-transactions 32"
```

`apply.detail.transaction.prepare`, `.begin`, `.commit`, and `.rollback` separate
the InnoDB transaction operations. Use their inclusive `seconds` to see SQL wait
time: the nested SQL timer accounts for most of it. `capture.schema_wait` measures
the decoder's wait for the consumer to supply historical column interpretation.

The harness exports `stage-timings.json`, optional applier/decoder TSV reports,
native/target binlog boundaries, server settings, and counter deltas before row
verification. The original baseline counter window included final verification;
small differences in status/Questions totals across that boundary are not workload
changes. Global handler counters include internal server work, not just our table.

All timings are elapsed time, not CPU time. Workers overlap. Inclusive parent and
child timings must not be added together. Schema-wait time can include downstream
execution and journal backpressure; it is not a prediction of cache savings.

## Results

The original release-image baseline passed with 12.671 s native and 41.806 s
external apply (3.30x elapsed time). Both recorded 10,000 commits. Our path made
20,000 text SQL calls and 10,026 prepared executions including setup/schema work.
Only 23 target statements were prepared. Repeated SQL preparation or schema
discovery is not evident in this workload.

Original evidence: `artifacts/lab-benchmark/mysql57-to-mysql84-innodb/20261010T043040Z-7834efd3-auto-transaction-innodb/`.

The detailed run passed in 48.182 s external / 12.686 s native. Its transaction
counters and binlog boundaries independently confirm 10,000 target transactions
on both paths. The native binlog grew by 2,570,000 bytes and retained the source
GTID SID; the 8.4 target binlog grew by 3,010,000 bytes with its own SID. The binary
log byte difference includes different server versions and row-metadata settings;
it does not demonstrate disproportionate binlog I/O time.

| Detailed-run stage | Calls | Inclusive elapsed seconds |
| --- | ---: | ---: |
| Target batch execution | 1,251 | 32.193 |
| COMMIT, including response wait | 10,000 | 19.887 |
| Row application | 10,000 | 7.275 |
| START TRANSACTION, including response wait | 10,000 | 4.035 |
| Per-transaction preparation | 10,000 | 0.303 |
| Capture waiting for schema interpretation | 10,000 | 26.695 |
| Decoder, including probes | 90,002 | 11.302 |
| SQLite journal preparation | 1,251 | 4.336 |
| SQLite journal completion | 1,251 | 4.461 |
| Target schema verification | 1 | 0.046 |
| Progress output | 1,252 | 0.849 |

The rows overlap and must not be summed. Commit time is about 62% of target
execution time, but it includes protocol, scheduling and server time; it is not a
measurement of fsync alone. The original `capture.process` self time concealed
schema waits. Adding a separate timer shows that most of the apparent capture
cost is waiting, not decoding CPU.

Every included 5.7 TABLE_MAP requests historical interpretation from the consumer,
even for an unchanged table. The consumer already caches discovered schema and
SQL plans, so these requests do not each issue schema SQL. They still require a
cross-thread handoff and can wait behind relay writes, journal work, or the join
of a previous target batch. Cache savings cannot be equated to the full 26.695 s.

The stream decodes 50,001 ordinary events plus 40,001 format/probe calls. For every
TABLE_MAP it constructs a probe decoder, decodes the format twice, probes identity
and probes metadata, before the main decode. Detailed decoder measurements put
Swift control conversion at 3.181 s self time, Rust decoding at 2.716 s inclusive,
and SHA-256 computation at 0.183 s. Hash computation is not a leading target.

Detailed evidence: `artifacts/lab-benchmark/mysql57-to-mysql84-innodb/20261010T043637Z-7ec04829-auto-transaction-innodb/`.

### Profiling-off and batch-size checks

Four further runs used the same instrumented release binary with both detailed
profilers disabled. The batch limits followed an 8, 32, 32, 8 order. Coarse timers,
including schema-wait accounting, stayed enabled.

| Batch limit | Native seconds | External seconds | External/native | Actual batches | SQLite commits | Target SQL seconds |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8 | 12.988 | 38.032 | 2.93x | 1,251 | 2,532 | 22.488 |
| 32 | 12.840 | 42.365 | 3.30x | 521 | 1,072 | 28.640 |
| 32 | 12.407 | 34.824 | 2.81x | 494 | 1,018 | 22.253 |
| 8 | 12.749 | 38.235 | 3.00x | 1,250 | 2,530 | 22.575 |

Batch eight reproduced the roughly 3x gap. Batch 32 reduced journal operations,
but its end-to-end results varied by 7.5 seconds; the target SQL time varied by
6.4 seconds. Both batch-32 runs flushed every batch on age, averaging only 19–20
transactions per batch. Do not infer a reliable overall speedup or regression
from these two samples. The lower journal cost is measured, but it is not the
main explanation for the gap, and this experiment does not justify a default
change. Detailed profiling also affected the observed timings; use the runs
without detailed profiling for throughput comparisons, not the 48.182 s profile.

All six 10K runs passed exact row/schema comparison, checkpoint verification,
and clean shutdown. Each recorded 10,000 commits on both native and target.
All five runs with the new instrumentation showed 10,000 schema waits and
10,000 additional GTIDs in each replica's own binlog boundary. All 372 Swift
unit tests passed after the instrumentation and harness changes.

Remaining evidence directories under
`artifacts/lab-benchmark/mysql57-to-mysql84-innodb/`:

- `20261010T043918Z-6eea6445-auto-transaction-innodb`: batch 8, profiling off.
- `20261010T044106Z-5c48042f-auto-transaction-innodb`: batch 32, profiling off.
- `20261010T044348Z-c26aead6-auto-transaction-innodb`: batch 32 repeat.
- `20261010T044533Z-795e54d9-auto-transaction-innodb`: batch 8 repeat.

`artifacts/reverse-performance-20261009/comparison.json` collects the six results
and the shared instrumented binary hash. That directory also retains the unit
test log. Generated artifacts remain local and are not committed.

## Proposed order after the baseline

1. Cache repeated historical TABLE_MAP interpretations on the decode side, and
   avoid reconstructing/probing an unchanged map. Invalidate at DDL and reconnect/
   resume boundaries; validate wire shape rather than trusting reused numeric
   table IDs. Preserve the ordered consumer lookup on misses. Qualify ALTER,
   RENAME, DROP/recreate, rotation, filtered tables, and offline replay. This is
   the clearest unnecessary coordination found so far, not a promised speedup.
2. Reduce target transaction-control round trips while preserving each source
   transaction. Investigate a narrowly eligible single-statement autocommit path
   or session transaction mode. Generated-column checks, before-image reads,
   DDL barriers, skips and lost-commit responses need explicit semantics and fault
   tests. The 4.035 s BEGIN time is an observed cost; eliminating a separate COMMIT
   request would not eliminate the server's durable commit work.
3. Recheck journal batching after reducing schema handoffs. The current batch-32
   measurements are inconclusive for end-to-end throughput. The 25 ms age limit
   flushes before the count limit; changing the count is not equivalent to
   merging target transactions.
4. If target commits still dominate, first measure server-side commit waits to
   separate MySQL/redo/binlog work from client protocol and scheduling costs. Then
   consider dependency-aware parallel apply as a separate design. Multiple
   concurrent commits may share flush work, but source
   transaction boundaries, dependencies, error handling and a contiguous durable
   checkpoint still matter. Table hashing alone cannot safely schedule the
   supported multi-table transactions.

The initial profiling increment adds measurement only. It does not change apply semantics, relax
durability, disable target binlogging, merge transactions, or add apply workers.

## Parallel InnoDB apply and comparable decoding

Parallel apply is feasible for independent transactions. A conservative first
scheduler can serialize transactions that touch any common table while allowing
disjoint table sets to execute concurrently. A transaction touching tables A and B
must reserve both and execute atomically on one connection; hashing only its first
table is insufficient. DDL and schema changes need a drain barrier. Each worker
needs its own connection, prepared statements and timing collector, with schema
cache invalidation coordinated across workers. The coordinator should remain the
single SQLite writer and own the target writer lease.

Current completion logic accepts an acknowledged prefix of one pending batch.
Parallel workers require durable accounting for completed transactions after a
gap, a checkpoint that never advances past that gap, and fail-stop diagnostics for
all in-flight transactions. Out-of-order commit visibility is a separate semantic
choice. Waiting for each earlier COMMIT acknowledgment preserves order but keeps
that commit bottleneck serial; potential group-commit benefits require overlapping
server commits and cannot be promised by adding worker threads alone. Native 5.7
also implements dependency-aware parallel scheduling: its
`sql/rpl_mts_submode.cc` logical-clock scheduler uses the GTID event's
`last_committed` and `sequence_number` values.

The current INSERT benchmark writes only one table, so table-based partitioning
would still use one worker. The current `multi-table-transaction` workload is also
deliberately dependent: every transaction updates `items.id=1`. To evaluate
parallelism, first add an independent multi-table workload, retain these dependent
controls, and compare one/two/four workers with full row/checkpoint verification.
Keep the native reference's worker count explicit (currently one).

Raw decoding cost should be broadly comparable for an equivalent row workload,
but 5.7 and 8.4 source binlogs are not byte-identical simply because both use GTIDs.
The 8.4 profile carries FULL optional table metadata. The 5.7 profile lacks that
information and resolves historical column interpretation through the consumer.
In this experiment, actual unprofiled `capture.decode` is around 7–8 seconds;
the additional 10,000 schema handoffs and their waits are a pipeline dependency,
not inherently slower GTID or row decoding. A comparison with forward decoding
needs the same workload, release build, profiling settings and timing scope.

## Historical schema cache

The implementation caches historical column interpretations inside each stream
processor. Keys use database/table identity, with an exact comparison of decoded
wire columns before reuse. Table IDs, event offsets and event checksums are not
schema keys; each new event still gets its own schema binding and checksum checks.
The consumer continues validating each TABLE_MAP against its historical schema.

All non-transaction-control query events clear the cache before publication, so a
subsequent miss waits behind the DDL in the ordered consumer queue. New format
contexts, heartbeat gaps and skipped archive groups clear it too. Reconnect and
resume create a new processor. The cache holds at most 1,024 table entries and
evicts entries by clearing on capacity; eviction only repeats the ordered lookup.

This implements the interpretation-cache portion of the first recommendation.
It leaves the existing table-map probe decodes in place. It changes no SQL,
transaction, journal, error-skip or durability policy.

The detailed 10K run passed with **one schema lookup and 9,999 cache hits**, versus
10,000 lookups before. Schema-wait time fell from 26.695 s to 0.136 s. Decoder work
still made 90,002 calls (10.166 s inclusive). End-to-end time was 37.985 s external
versus 13.323 s native, compared with the earlier detailed 48.182/12.686 s run.
Target SQL time also fell from 29.908 to 21.946 s, so this single comparison must
not attribute the entire wall-time reduction to caching. Producer enqueue time
rose to 19.171 s: a faster producer now waits at the bounded queue rather than
requesting schema at every map. Moving that wait is not itself a speedup.

Detailed cache evidence:
`artifacts/lab-benchmark/mysql57-to-mysql84-innodb/20261010T045407Z-0b0e57d9-auto-transaction-innodb/`.

Two subsequent runs used the same cache binary with both detailed profilers off,
batch limit eight, and no concurrent lab suites:

| Run | Native seconds | External seconds | External/native | Target SQL seconds | Decoder seconds |
| --- | ---: | ---: | ---: | ---: | ---: |
| Before cache, first | 12.988 | 38.032 | 2.93x | 22.488 | 7.728 |
| Before cache, repeat | 12.749 | 38.235 | 3.00x | 22.575 | 7.849 |
| Cache, first | 12.192 | 37.502 | 3.08x | 22.006 | 6.922 |
| Cache, repeat | 11.842 | 36.336 | 3.07x | 21.068 | 6.912 |

All final rows, schema, source checkpoints and 10,000 commits on each target were
verified. Each cache run performed one lookup and 9,999 hits. Raw wall time fell
slightly, but native also ran faster: these samples do not establish a significant
throughput improvement. The stable benefit is eliminating repeated coordination;
the roughly 3x native gap remains. Target execution and transaction-control calls
are the next performance targets. Additional probe-decode optimization remains
possible, but this change does not remove those decodes.

Profiling-off cache evidence under the same benchmark directory:

- `20261010T045634Z-9e6ef7f8-auto-transaction-innodb`.
- `20261010T045820Z-3188a893-auto-transaction-innodb`.

### Why 30,026 SQL calls remain

`InnoDBExecution.run` unconditionally starts and commits each source group. In
this single-row INSERT workload that is 10,000 START TRANSACTION requests, 10,000
INSERT executions and 10,000 COMMIT requests, plus 26 setup/schema requests.
Native row replication writes through internal storage-engine APIs and commits
the transaction; it does not send this client SQL sequence.

A source group that can be applied by exactly one target statement can use
autocommit, reducing this workload to roughly 10,026 requests while retaining
10,000 durable commits. Eligibility must be based on the actual target plan, not
whether source SQL used explicit BEGIN: a large source INSERT can be split into
multiple target statements. Multi-statement plans and post-write validation that
requires rollback retain explicit transactions. Lost autocommit responses must
be treated as uncertain commits, and known statement failures need appropriate
rollback/skip classification. This was the proposed execution change at the
schema-cache checkpoint; its performance experiment follows below.

### Cache validation

All 377 Swift unit tests passed, including five new cache tests for changing table
IDs, wire metadata changes, DDL, rotation, reconnect through a fresh processor,
excluded ranges, filtering and checksum validation. Periphery's strict scan found
no unused code.

The selected reverse correctness run passed all seven scenarios: database charset
defaults, database/table defaults, ordered DDL, wildcard exclusions and resume,
included-statement rejection, and offline replay. The ordered DDL scenario also
exercises changes that reuse a table name, including drop/recreate and conditional
CREATE. Evidence: `artifacts/lab/20261010T050037Z-af987ff3/result.json`.

Shared correctness smoke tests passed all 27 scenarios (nine each for
8.4 → 5.7 MyISAM, 5.7 → 8.4 InnoDB, and 5.7 → 5.7 MyISAM).
Evidence: `artifacts/lab/20261010T050039Z-2f9487f2/result.json`.

All 11 reverse lifecycle scenarios passed, including source disconnect/rotation/
restart, target reconnect, draining and resume, lost-write uncertainty, and
incompatible-setting rejection. Evidence:
`artifacts/lab/20261010T051639Z-b87fae7e/result.json`.

Local comparison data and validation logs are collected under
`artifacts/schema-cache-20261009/`.

## Autocommit experiment and prepared-batch follow-up

The schema-cache/profiling checkpoint was committed as `f427997`. The subsequent
uncommitted experiment removes explicit BEGIN/COMMIT around groups with one
target write. Single-row INSERT, UPDATE and DELETE qualify. INSERT chunks qualify
only when the existing chunk planner can execute the entire source group in one
statement. That planner is shared with normal execution, including row/byte limits
and power-of-two prepared-statement shapes. Source transactions remain separate.

UPDATE/DELETE retain their pre-write image and key checks under the existing
exclusive-writer contract. INSERT/UPDATE on generated columns retain explicit
transactions because their post-write value checks must be able to roll back.
Groups needing multiple target writes also retain explicit transactions.

Autocommit success acknowledges the group even if cancellation arrives while the
request is running. A lost response remains `commitUncertain`; sending a later
ROLLBACK cannot prove that the write did not commit. A received MySQL 1062 on an
issued ordinary InnoDB mutation establishes statement rollback and can use the
existing authorized skip policy. Post-response validation failure retains the
intent and reports `committed`, without advancing the source checkpoint.

### Performance first

Per the requested order, this experiment has been built and benchmarked, but its
unit-test expectations and broader correctness qualification are still pending.
The benchmark itself checks final rows/schema and the source checkpoint. These
results do not qualify failure handling, generated columns, or UPDATE/DELETE
autocommit; the measured workload is 10,000 single-row INSERT transactions.

All runs below used sequential native/external backlog replay with no concurrent
lab tests. Native remains MySQL 5.7 InnoDB; the external target is MySQL 8.4 InnoDB.
The first run enabled only applier profiling; the others disabled both detailed
profilers. The row/byte/age limits and durability settings were unchanged.

| Execution | Journal batch limit | Native seconds | External seconds | Target SQL seconds | Target SQL requests |
| --- | ---: | ---: | ---: | ---: | ---: |
| Autocommit, initial profiled run | 8 | 12.264 | 41.473 | 22.090 | 10,026 |
| Autocommit, profiling off | 8 | 12.663 | 29.923 | 15.711 | 10,026 |
| Fresh committed BEGIN/COMMIT baseline | 8 | 12.669 | 36.248 | 21.009 | 30,026 |
| Autocommit, repeat with slower native too | 8 | 24.068 | 41.561 | 22.721 | 10,026 |
| Autocommit, existing application batch default | 32 | 12.381 | 25.425 | 14.819 | 10,026 |

The first profiling-off run and fresh baseline have nearly identical native
timings. That comparison suggests about 17% lower elapsed time and 25% lower
target SQL time. The slower repeat shows considerable host variability, so these
are observations, not a stable throughput guarantee. The request reduction is
consistent across all runs. The target's `Com_commit` delta becomes zero because
there are no explicit COMMIT commands; it still commits and binlogs 10,000 target
transactions. Target binlog boundaries and GTID sets are in each result.

With the existing batch limit of 32, execution batches fell from 1,250 to 313,
SQLite commits from 2,530 to 656, and progress reports from 1,251 to 314. All source
transactions still commit separately in MySQL. No production default changed.

Evidence under `artifacts/lab-benchmark/mysql57-to-mysql84-innodb/`:

- `20261010T052526Z-78104c67-auto-transaction-innodb`: initial INSERT-only prototype,
  before extending eligibility to UPDATE/DELETE.
- `20261010T052833Z-2d66c45c-auto-transaction-innodb`: profiling off, batch eight.
- `20261010T053329Z-83113103-auto-transaction-innodb`: repeat, batch eight.
- `20261010T053608Z-b78bd0b4-auto-transaction-innodb`: batch 32.

The fresh baseline is in the isolated `f427997` worktree at
`../autocommit-baseline/artifacts/lab-benchmark/mysql57-to-mysql84-innodb/20261010T053050Z-4db46549-auto-transaction-innodb/`.
Combined local evidence is in `artifacts/autocommit-performance-20261009/`.

### Keep the target worker busy

The current overlap covers decoding and row planning, but not all journal work.
`ApplyRun` joins the prior executor, records its completion, emits progress,
syncs the next relay prefix, persists its intents, and only then starts the next
executor. `StateStore.beginBatch` requires no pending GTID, enforcing this serial
handoff. At batch 32, target execution took 15.796 seconds, while the consumer's
aggregate elapsed time was 19.030 seconds; full benchmark time was 25.425 seconds.
These scopes overlap and are not a complete wall-time decomposition. In
particular, the difference must not all be labeled CPU or startup cost.

The next proposed increment is a bounded queue of durably prepared batches,
initially one executing and one ready:

1. Keep SQLite ownership on the coordinator. Record future intents and sync
   their relay data while the target worker executes an earlier batch.
2. Let the target worker consume ready batches in order and return completion
   results. Keep its connection, statement cache and timings worker-local.
3. Track multiple outstanding batches in the state store, assigning unique
   sequence numbers and advancing the applied checkpoint only through the
   acknowledged prefix. Preparing a batch must never advance applied progress.
4. Persist earlier completions while target execution continues. On failure,
   stop later work and preserve all outstanding intents and known outcomes;
   never infer success or retry an uncertain write.
5. Drain the queue for DDL/schema barriers. Account for every queued group when
   enforcing transaction/GTID stop limits, cancellation, and reconnect behavior.
6. Measure queue starvation, writer idle time, durable preparation/completion,
   and steady-state replay wall time separately from process startup/shutdown.

This queue is not implemented by the autocommit experiment. It changes the
outstanding-intent model and needs crash/stop/skip tests before qualification.

The autocommit checkpoint sets the application and benchmark journal batch
defaults to eight, as requested. The measured batch-32 run remains an explicit
experiment. Correctness qualification remains deferred until performance work
is complete.

## Bounded prepared-batch queue

Autocommit and the default batch size of eight were committed as `a974f0b`.
The following uncommitted increment implements the prepared-batch proposal above.
`batch.maximumPreparedBatches` accepts one or two, defaulting to two. The bound
includes the executing batch and completed batches awaiting coordinator
acknowledgment. `overlapPreparation: false` uses one slot and waits at each handoff.

`DMLExecutor` owns a serial target queue and ordered completion tickets. The
coordinator durably syncs/journals each batch before submitting its ticket; it can
do that while the worker executes the previous batch. The coordinator remains the
only SQLite writer. It can record earlier completions while the worker executes
the next durable batch. Target schema validation/locking remains on the target
worker or behind drained schema barriers, avoiding concurrent session access.

The state store retains the bounded outstanding groups and their batch boundaries.
Preparation assigns sequences after the outstanding tail and leaves applied
progress unchanged. Completion updates only the acknowledged head prefix, leaving
the oldest outstanding GTID active. This uses the existing groups, row intents and
relay format; pending-state crash recovery remains fail-stop.

A target failure latches the executor stopped before its result is published, so
later queued tickets do not issue SQL. Coordinator/checkpoint failure cancels and
joins remaining work; outstanding durable intents are retained even if a target
write raced the failure. DDL, schema discovery, finite input, drain and reload
barriers drain all submitted batches. The existing capture limits still bound the
number/GTID boundary of source groups admitted to the pipeline.

### Measured reverse performance

All three runs used the same release binary, batch size eight, 10,000 single-row
INSERT transactions, and both detailed profilers disabled. Only queue depth
changed. Each run passed the benchmark's final row/schema/checkpoint comparison,
issued 10,026 target SQL requests, and executed all 1,250 journal batches.

| Prepared slots | Native wall seconds | External wall seconds | Target SQL seconds | Worker busy seconds | Worker idle seconds | Worker span seconds |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 2, first | 11.917 | 24.623 | 17.551 | 18.712 | 0.039 | 18.751 |
| 1, comparison | 12.667 | 31.321 | 16.411 | 17.604 | 7.829 | 25.432 |
| 2, repeat | 28.833 | 30.472 | 23.441 | 24.550 | 0.036 | 24.586 |

Worker idle share fell from about 31% to 0.15–0.21%. The first comparison reduced
external wall time by about 21%, despite slightly higher target SQL time. Native
and target SQL times varied substantially on the repeat, so wall throughput is
not a stable guarantee. Both two-slot runs demonstrate that durable preparation
no longer leaves material gaps between reverse-profile SQL batches. Worker span
was within roughly 5–7% of aggregate target SQL time, which also includes setup
queries outside that span. This is approximate scope comparison, not an exact
partition of elapsed time.

About 5.9 seconds of each external run were outside the first-to-last target-batch
window. That includes startup, initial preparation and shutdown/control work; it
has not been separately attributed. The queue metrics should be used alongside
full wall time when assessing steady-state replay throughput.

Evidence under `artifacts/lab-benchmark/mysql57-to-mysql84-innodb/`:

- `20261010T055610Z-8f294878-auto-transaction-innodb`: two slots.
- `20261010T055817Z-f513716d-auto-transaction-innodb`: one slot.
- `20261010T060044Z-0371ad18-auto-transaction-innodb`: two-slot repeat.

Binary SHA-256:
`bad6cf7a682cf1acc5ec140316dfb6545b3bd945b2bc7a606225bfe8120b9882`.

### MyISAM profile confirmation (10K)

The same binary, batch size eight and two prepared slots also passed both MyISAM
backlog benchmarks. Each compared final rows/schema/checkpoints, applied 10,000
source transactions, executed all 1,250 journal batches, and issued 1,274 target
SQL requests. MyISAM INSERT groups can be coalesced across source transactions;
the reverse InnoDB profile retains separate target transactions.

| Profile | Native wall seconds | External wall seconds | Target SQL seconds | Worker busy seconds | Worker idle seconds | Worker span seconds |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| mysql84-to-mysql57-myisam | 7.845 | 16.721 | 2.109 | 2.571 | 8.383 | 10.954 |
| mysql57-to-mysql57-myisam | 8.014 | 16.648 | 2.082 | 2.547 | 8.339 | 10.886 |

Unlike reverse InnoDB, MyISAM target writes are faster than batch production, so
these workers still wait for prepared work. The queue does not remove that
bottleneck. These are profile confirmations, not measured queue speedups: no
same-binary one-slot MyISAM comparison was run. The forward native reference is
8.4 MyISAM; the new 5.7-to-5.7 profile uses 5.7 MyISAM for both target and native.

Evidence under `artifacts/lab-benchmark/<profile>/`:

- `20261010T060325Z-6d7c812a-auto-autocommit-myisam`: forward 8.4 source.
- `20261010T060916Z-a76b7c2a-auto-autocommit-myisam`: 5.7 source.

### Longer backlog confirmation (25K)

At the user's request, repeat all three profiles with 25,000 single-row INSERT
transactions to reduce the relative contribution of fixed overhead. These runs
used the same binary and settings as the two-slot 10K runs, sequentially on the
same host. All passed final row/schema/checkpoint comparisons and executed all
3,125 journal batches with no unissued batches.

| Profile | Native wall seconds | External wall seconds | External/native | Target SQL seconds | Worker span seconds | Worker idle seconds |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| mysql57-to-mysql84-innodb | 28.798 | 51.171 | 1.78× | 42.240 | 45.362 | 0.089 |
| mysql57-to-mysql57-myisam | 18.761 | 33.345 | 1.78× | 5.137 | 27.558 | 21.184 |
| mysql84-to-mysql57-myisam | 18.677 | 42.093 | 2.25× | 7.094 | 36.282 | 27.969 |

Reverse InnoDB issued 25,026 target SQL requests; each MyISAM profile issued
3,149. InnoDB's worker idle share remained about 0.2%, confirming that batch
preparation keeps pace with target execution in this workload. Its worker span
was about 7% above total target SQL time, subject to the timing-scope caveat above.

Time outside the worker window remained approximately 5.8 seconds for each run.
That is about 11–17% of external wall time at 25K, versus about 24–35% in the
first two-slot 10K runs. The 5.7-source profiles both measured 1.78× native wall
time. The forward 8.4-source profile measured 2.25× and retained substantial
worker idle time. This longer forward run was slower per transaction than its
10K run; one sample cannot distinguish host variability from scaling effects.
Do not claim a uniform ratio, a forward speedup, or target-SQL-limited performance
for MyISAM. Further performance tuning is deferred in favor of correctness work.

Evidence under `artifacts/lab-benchmark/<profile>/`:

- `20261010T061047Z-1e6b02e8-auto-transaction-innodb`: `mysql57-to-mysql84-innodb`.
- `20261010T061352Z-b0413392-auto-autocommit-myisam`: `mysql57-to-mysql57-myisam`.
- `20261010T061617Z-4d96a53c-auto-autocommit-myisam`: `mysql84-to-mysql57-myisam`.

`artifacts/prepared-queue-performance-20261009/` collects all eight queue
comparison/profile runs, runtime provenance, stage timings, benchmark logs, the
host build log and `comparison.json`. All runs used the binary hash recorded
above. No runtime code changed between these measurements.

### Deferred correctness qualification

No unit, lifecycle, recovery, or broad correctness suite has been run for this
increment, per the requested performance-first order. Benchmark success does not
qualify the failure paths. Before release, update the autocommit unit expectations
and cover one/two-slot ordering, limits and capacity; partial acknowledgments and
error skips with a prepared tail; worker failure before the next ticket; SQLite
failure while another batch executes; generated-column rollback; before-image
checks; and DDL/reconnect/drain/reload/GTID-stop barriers. Run these against the
shared profiles, including live and offline replay. Retain the one-slot mode as a
performance comparison and conservative scheduling option.
