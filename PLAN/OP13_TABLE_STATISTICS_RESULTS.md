# OP-13 table statistics measurements

Date: 2026-10-21. Branch: `beta/7/04-compatible-sql-routing`, after OP-12 commit
`cfcf917`. These measurements use the local OP-13 implementation and a macOS debug
binary. They do not establish release-binary throughput.

## Method

The existing discovery harness generated 10,000 INSERT transactions over four
tables. The profile was MySQL 5.7 → MySQL 8.4 InnoDB, with SQL transport and
`preserveSourceGTIDs: false`. Replay read local closed binlogs. Added target RTT
was zero. Both target connections used the local proxy. Source and target were
disposable Docker fixtures. No external server was used.

The runs used the same source archive and server pair. Each run reset the target
schema and used new local state. Collection order was off, on, on, off. The
harness compared every final row with the source. A separate restart phase
applied UPDATE, ALTER, and INSERT. Its time is excluded from the table below.
Runs with collection enabled also checked the saved INSERT, UPDATE, and ALTER
counts after that restart.

The observer read compact status every 0.5 seconds. Enabled runs also read one
detailed page at the same interval. The detailed requests add some work to those
runs. Debug stage timings and normal progress output were enabled in all runs.

Evidence directory:
`artifacts/operability/op13-overhead-10k/`. Each `0ms/RUN` directory contains
results, source/target comparison results, state, logs, and status samples.
Enabled runs contain `table-statistics.json`. The top-level result includes
server versions and image IDs. The containers were removed after the test.

## Results

| Run | Detail | Elapsed seconds | `target.sql` seconds | `sqlite.statement` seconds | SQLite commits |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | off | 22.690 | 20.758 | 0.280 | 1617 |
| 2 | on | 24.223 | 22.442 | 0.325 | 1621 |
| 3 | on | 29.762 | 27.565 | 0.414 | 1621 |
| 4 | off | 20.145 | 18.528 | 0.269 | 1617 |

All four runs applied 10,000 rows and transactions. Each restart phase ended at
10,003 transactions. All row comparisons and enabled counter checks passed.

Mean elapsed time was 21.417 seconds off and 26.992 seconds on: a 26.0% increase.
Most of the difference appeared inside target SQL waits. These short local
runs cannot separate counter CPU cost, host scheduling, and server variation.
Do not report the difference as a pure serialization cost. The direct SQLite
statement measurements increased by about 0.045–0.145 seconds across these runs.
Stage times overlap; do not add them to calculate elapsed time.

The four additional SQLite commits occur during statistics setup and final
snapshot handling. The unit test confirms that a prepared batch still uses one
completion commit with statistics enabled. There is no extra commit per row or
source transaction. Collection remains off by default.

| Run | Compact reply maximum, bytes | Detailed reply maximum, bytes | Slowest status reply, ms | Progress stdout, bytes |
| --- | ---: | ---: | ---: | ---: |
| 1 off | 4878 | — | 1.75 | 5849560 |
| 2 on | 5059 | 9319 | 1.35 | 6081233 |
| 3 on | 5056 | 9287 | 6.83 | 6080488 |
| 4 off | 4876 | — | 1.64 | 5849794 |

Normal status grew by about 180 bytes in this workload. Progress stdout grew by
about 232 KB over 10,000 transactions. The detailed page contained all seven
entries: four tables, one schema entry, the unattributed entry, and overflow.
These are measured samples, not response-size or latency guarantees.

## Focused checks

Twenty-one Swift tests pass. They cover:

- INSERT, UPDATE, DELETE, planned operations, and encountered type sets.
- Known filtered rows versus filtered events without a decoded row count.
- Error skips, policy skips, and restart without repeated applied counts.
- Failed checkpoint rollback, including saved and in-memory counters.
- CREATE/ALTER, pending DROP, rename history, and retained statistics after
  completed journal history is pruned.
- Process counter reset on restart and explicit gaps while collection is off.
- The configurable limit, exact UTF-8 name identity, one warning at the limit,
  overflow totals, and a restored full registry.
- Six thousand named entries with compact status below 512 bytes for its
  statistics summary and a 100-entry page below 200 KB in the test fixture.
- Status pages, option validation, configuration examples, and benchmark options.

Four Python harness helper tests also pass. A first commit-failure test attempt
used a read-only test helper to install its failure trigger. The corrected test
uses a writable fixture connection and verifies that the trigger is installed.
This was a test setup failure, not an apply failure.

The 6,000-name check is an in-memory unit test. It does not measure 6,000 physical
MySQL tables or a full snapshot of that size on remote storage. The full profile
suite, BINLOG transport performance, and a release-build comparison remain for
later CI or focused measurement. No test used customer data.

## Repeat a measurement

Build the local binary, then run the same command with `on` and `off`:

```sh
swift run replicator-lab benchmark --mode discovery \
  --profile mysql57-to-mysql84-innodb --binary .build/debug/mysql-replicator \
  --tables 4 --events 10000 --target-rtt-ms 0 --table-statistics on
```

The standard command creates its own fixtures for each invocation. For a precise
comparison, retain logs, reverse the order, and use several runs. Investigate
server and host variation before attributing elapsed-time differences to one
counter or SQLite statement.
