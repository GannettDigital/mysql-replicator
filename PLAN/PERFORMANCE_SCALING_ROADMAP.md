# Performance scaling: future work

Recorded 2026-10-02, following the decoder pipeline checkpoint `f0a2e31`.
This is a proposed implementation and qualification sequence, not a claim that
SQL batching or parallel target application is already supported.

Update, 2026-10-02: the workload matrix, bounded multi-row INSERT execution,
overlapping preparation with one target writer, and journal batches spanning
table changes are now implemented. See the current
[implementation and benchmark evidence](PERFORMANCE_BENCHMARK.md#insert-execution-and-preparation-overlap-2026-10-02).
The baseline and sequence below preserve the original proposal; table-based
parallel appliers remain future work.

## Objective and baseline

Increase capacity for the production source streams listed in
[data/binlog_sizes.csv](data/binlog_sizes.csv), while retaining explicit source
transaction identities, durable pre-write intents and fail-stop behavior.

The latest local benchmark applied 10,000 single-row INSERT transactions in
60.733 seconds, compared with 115.797 seconds before overlapping decoding and
application. Each source transaction generated 425 binlog bytes. Effective
throughput was approximately 165 transactions/s or 70 kB/s. See
[the benchmark evidence and methodology](PERFORMANCE_BENCHMARK.md).

| Measured work | Elapsed time |
| --- | ---: |
| Decoder, 90,006 calls | 48.778 s |
| Relay append, exclusive | 18.827 s |
| Target SQL | 13.041 s |
| SQLite commits | 2.102 s |

Capture and apply overlap: these durations must not be added as wall time.
Decoder cost alone corresponds to an optimistic ceiling of roughly 205
transactions/s for this workload before other capture work. Adding appliers
cannot remove that producer bottleneck.

Treating the CSV as seven days of byte counts, its 15 sources total 303.8 GB.
The INSERT-equivalent average rates for platform USA KW, USA RP and Australia
are approximately 354, 283 and 165 transactions/s. Provisional targets with
2x average headroom would be approximately 710, 566 and 330 transactions/s.
These are workload scenarios, not measured production TPS or peak rates.
The CSV is one inventory snapshot; it does not establish hourly peaks, row
sizes, operation mix, table distribution or supported schema compatibility.

The benchmark ran with an emulated x86_64 target/applier on an ARM host. Repeat
on representative native Linux hardware before treating these numbers as
deployment capacity. Per-source comparisons assume comparable independent
resources; scaling several colocated replicators has not been measured.

## 1. Reduce decoder and relay overhead

First optimize work that benefits both one-table and many-table workloads:

- Reduce repeated format-event and table-map probes. The current 10K workload
  invokes the decoder about 90K times for approximately 50K physical events.
- Reuse validated format context without weakening CRC, filtering, wire-type,
  rotation, table-map reuse or historical-schema checks.
- Replace per-byte `String(format:)` fingerprint formatting with inexpensive
  hex conversion that produces identical hashes.
- Carry original event bytes internally instead of encoding them as base64
  and decoding them again for relay writes. Preserve external diagnostic formats
  where required.
- Measure relay framing, allocation and write-call costs before considering
  additional buffering. Preserve synchronization before target write intents
  become executable.

Acceptance: existing codec/capture/apply qualifications pass, relay bytes remain
equivalent, and the same 10K benchmark reports decoder calls and stage timings.
Record actual improvement rather than predicting speedup from call count alone.

## 2. Expand the workload model and tune journal batches

Develop the benchmark alongside the decoder work. Include:

- One hot table, eight evenly loaded tables, and eight tables with 80% of writes
  concentrated on one table.
- INSERT-only and mixed INSERT/UPDATE/DELETE workloads, larger payloads,
  multi-row statements, key changes and secondary indexes.
- Burst and sustained offered rates, followed by catch-up measurement.
- Representative source-binlog samples to measure transactions, changed rows,
  bytes, operation mix and per-table/per-minute load.

Measure batch flush reasons: transaction/row/byte limit, age, idle, table change,
DDL, filtering and shutdown. Current DML batches average 9.68 source groups,
below the maximum of 32, with a 25 ms collection deadline. Raising the maximum
alone may accomplish little if age or another barrier causes most flushes.

Compare bounded combinations such as 32/64/128 groups and 25/50/100 ms collection
deadlines. Keep reader-blocking lock limits separate from collection limits.
Measure throughput, lag, reader waits, queue high-water marks, commits and syncs.
Larger batches increase delay and the possible unresolved recovery scope.
SQLite commit time is already small, so journal tuning alone is unlikely to
close the production capacity gap.

## 3. Introduce bounded multi-row INSERT statements

Journal batching currently groups durability work; target SQL still executes
one INSERT per row. Add a separate SQL batching layer for consecutive compatible
INSERTs to the same table and schema version, preserving source row order:

```sql
INSERT INTO t (...) VALUES (...), (...), (...);
```

Start with a modest row limit, for example 32 or 64, and independent byte and
parameter-count limits. Respect target packet limits and DDL/table/operation
barriers. Retain bound parameters, strict SQL behavior and affected-row checks.
Do not initially fuse UPDATEs or DELETEs: their before-image and key-change
checks need separate design and qualification.

Correctness requirements:

- Persist every source group and row intent before issuing the combined SQL.
- On an unambiguous successful response with the expected affected-row count,
  acknowledge all represented rows and advance only completed source groups.
- On SQL error, timeout or disconnect, do not infer a successful row prefix from
  the combined statement. MyISAM may have written some rows. Retain the affected
  chunk as unresolved, preserve earlier known acknowledgments and stop.
- Never retry the uncertain statement automatically. Retain enough identities,
  row data and relay references for DBA inspection and repair.
- Keep source identities separate even when target statement/binlog grouping
  changes. Explicitly qualify that grouping change and partial-failure behavior.

Wrapping statements in BEGIN/COMMIT does not make MyISAM transactional. The
intended savings are fewer SQL executions and round trips. See MySQL's
[INSERT optimization guidance](https://docs.oracle.com/cd/E17952_01/mysql-5.7-en/insert-optimization.html)
and [nontransactional rollback behavior](https://docs.oracle.com/cd/E17952_01/mysql-5.7-en/nontransactional-tables.html).

## 4. Add table-based applier workers

Evaluate after measuring table distribution and improving the producer. A first
scheduler can use `stable_hash(database, table) % worker_count`, retaining source
order within each table. Use table identity, not the reusable binlog table ID.
Start with 1/2/4 workers and compare against the same workloads and hardware.

Each worker owns its target connection and statement cache. One coordinator
owns relay/journal operations and instance-level writer exclusion. Worker
connections must remain subordinate to that ownership; they cannot each acquire
the existing exclusive advisory lock independently. Keep queue memory and the
number of outstanding source groups bounded across all workers.

The coordinator must:

1. Durably prepare intents before dispatching any target write.
2. Record worker completions, including out-of-order completion, through a
   single SQLite writer.
3. Advance the applied position/GTID checkpoint only through a consecutive
   completed source prefix. If 102 completes before 101, record 102's completion
   while keeping the checkpoint at 100.
4. Initially drain all workers at DDL, apply and record it, invalidate affected
   caches and then resume. This covers rename, drop/recreate and template-table
   dependencies as well as ordinary column changes.
5. Stop dispatch on failure, settle or record in-flight outcomes, and retain all
   incomplete or uncertain groups. Do not lose completed groups beyond a gap or
   silently replay them. Adapt the current journal/resume invariants explicitly.

The current single-statement/single-table source-group restriction remains in
place. Multi-table transactions need dependency scheduling before support can
be expanded; hashing one of their tables is insufficient.

This design helps when writes are spread across tables. A single hot table stays
on one worker. Splitting that table by primary key does not bypass MyISAM's
single-writer table locking and introduces key/index dependencies. See
[MySQL's locking behavior](https://docs.oracle.com/cd/E17952_01/mysql-5.7-en/internal-locking.html).

### Reader-visible ordering decision

Table workers can expose later source changes on one table before earlier
changes on another. An ordered SQLite checkpoint does not hide those effects
from readers or make MyISAM writes rollbackable. Decide and document this
visibility contract before enabling parallel apply; the dedicated-replica
assumption excludes external writes but does not itself authorize reordered
cross-table observations.

Native replication provides useful coordinator/worker and dependency-scheduling
precedents, but does not eliminate this limitation: MySQL documents that commit
order preservation does not preserve nontransactional DML order. See
[native parallel replication options and limitations](https://docs.oracle.com/cd/E17952_01/mysql-8.0-en/replication-options-replica.html).

## Qualification gates

For each increment, retain exact final-row/schema comparison, source-group
identity and checkpoint checks, and stage/queue measurements. Exercise duplicate
keys, before-image mismatches, disconnects, process death, journal failures,
DDL barriers, cancellation and clean resume. Parallel apply additionally needs
slow-worker/out-of-order completion tests, failures with later groups already
written, and bounded backpressure behind a checkpoint gap.

Run concurrency sanitizers where the toolchain permits them. The current macOS
environment refused to load Thread Sanitizer into SwiftPM's test helper; that
attempt was not a sanitizer pass.

Recommended implementation order: decoder/raw-byte improvements and workload
expansion, measured journal tuning, bounded multi-row INSERTs, then table workers
if table distribution and the agreed visibility contract justify them.
