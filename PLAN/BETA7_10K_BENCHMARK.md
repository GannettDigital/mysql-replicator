# beta.7 — 10K replication benchmark

## Test and limit

The `performance/backlog-10k` case applies 10,000 single-row INSERT
transactions. All four profiles run with SQL and BINLOG transport. Each job
uses one fixture. The native replica and the external applier consume the same
backlog in sequence. The test checks source row count, target/native rows and
schema, completed transaction count, and applied GTID progress.

The ratio is external elapsed time divided by native elapsed time. The default
limit is 2.0. `--max-native-ratio` changes it. `--report-only` accepts a ratio
above the limit but retains `over_limit` in the result. Other failures still
fail the test. Full CI initially uses report-only mode. The fast PR selection
is unchanged.

```sh
make lab-performance ARGS="--max-native-ratio 2 --report-only"
make lab-performance ARGS="--dml-transport binlog --max-native-ratio 2 --report-only"
```

These commands run all four profiles with a non-coverage application image.
Use `PROFILE=<profile>` to run one profile. Add `--coverage --skip-build` to
reuse a matching coverage image. Remove `--report-only` to enforce the limit.
Do not run both commands at the same time on one host.

## Local measurement conditions

The local run on 2026-10-26 uses the CI coverage application build and a rebuilt
host lab executable. It uses the same group commands and measurement wrapper as
CI. The eight jobs run sequentially. The production application code is unchanged
by this work. The image source check compared 163 application Swift files and
found no differences from the reused image.

The host is ARM macOS with Docker Desktop. The applier and MySQL 5.7 fixtures
use amd64 images. The MySQL 8.4 fixture does not force an architecture. Emulation and coverage
instrumentation affect these results. They are not production throughput figures.
Each selection runs once. These runs do not establish normal timing variation.
Other existing user containers were left in place.

The workload is INSERT-only, with integer keys and values in one table. It does
not measure large rows, UPDATE/DELETE, DDL, multi-table transactions, cold schema
discovery across many tables, or network latency between hosts. Source GTID
preservation is enabled. Both batch limits are 8. Applier function timing is enabled; decoder function
timing is disabled. Native replication uses no
parallel SQL workers. `sync_binlog=1` and `innodb_flush_log_at_trx_commit=1`
remain enabled. The native server uses the source version and target engine.

Replay timing excludes fixture setup, workload generation, final row comparison,
coverage export and cleanup. It includes native restart/control calls, external
process startup, capture shutdown and drain. Worker stage timings overlap; do
not add them to calculate elapsed time.

## Evidence

`artifacts/performance-10k/` contains the local matrix, runner log, image details,
source comparison, and per-profile logs. Each log points to the fixture under
`artifacts/lab/`. The fixture retains `result.json`, `runtime.json`, configuration,
`workload.sql`, stage timings, counters, application logs, SQLite state, and
coverage files. CI measurement records are under `artifacts/ci/measurements/`.

The first trial read periodic stdout progress instead of the final stderr
summary. The applier completed 10,000 transactions, but the reader rejected the
`RUNNING` record. The harness now reads the final summary from stderr and saves
the two streams separately. No applier change was needed. The corrected runs
use new fixtures. Earlier failed evidence is retained.

## Results

All eight runs passed the data and checkpoint checks. Each produced one fixture
record and one coverage collection. Every ratio exceeded the provisional 2×
limit. Report-only mode retained `over_limit` and allowed the runs to pass.
The combined report is complete for these eight jobs only. The full correctness
suite was not run.

| Profile | Transport | Native seconds | Replicator seconds | Ratio |
|---|---|---:|---:|---:|
| `mysql57-to-mysql57-innodb` | BINLOG | 13.04 | 53.72 | 4.12× |
| `mysql57-to-mysql57-innodb` | SQL | 13.73 | 49.28 | 3.59× |
| `mysql57-to-mysql57-myisam` | BINLOG | 7.89 | 31.18 | 3.95× |
| `mysql57-to-mysql57-myisam` | SQL | 9.51 | 41.76 | 4.39× |
| `mysql57-to-mysql84-innodb` | BINLOG | 15.65 | 44.69 | 2.86× |
| `mysql57-to-mysql84-innodb` | SQL | 14.26 | 50.03 | 3.51× |
| `mysql84-to-mysql57-myisam` | BINLOG | 7.19 | 32.95 | 4.58× |
| `mysql84-to-mysql57-myisam` | SQL | 7.74 | 42.52 | 5.49× |

BINLOG was faster than SQL in three profiles. In the 5.7 → 5.7 InnoDB profile,
BINLOG took 53.72s and SQL took 49.28s. Do not treat one sample as a stable
difference. The native times also varied between the two runs for each profile.
Counters confirm 10,000 BINLOG row operations in each BINLOG selection.

| Profile | Transport | Target SQL calls | Target SQL seconds | Capture shutdown seconds |
|---|---|---:|---:|---:|
| `mysql57-to-mysql57-innodb` | BINLOG | 40,033 | 41.45 | 5.00 |
| `mysql57-to-mysql57-innodb` | SQL | 50,028 | 33.08 | 5.00 |
| `mysql57-to-mysql57-myisam` | BINLOG | 40,030 | 19.00 | 5.00 |
| `mysql57-to-mysql57-myisam` | SQL | 50,035 | 25.83 | 5.00 |
| `mysql57-to-mysql84-innodb` | BINLOG | 40,034 | 31.47 | 5.00 |
| `mysql57-to-mysql84-innodb` | SQL | 50,029 | 33.67 | 5.00 |
| `mysql84-to-mysql57-myisam` | BINLOG | 40,030 | 20.51 | 5.00 |
| `mysql84-to-mysql57-myisam` | SQL | 50,035 | 25.98 | 5.00 |

SQL transport made approximately 50,000 target calls for 10,000 transactions.
BINLOG transport made approximately 40,000 calls. These counts include GTID
and transaction control, not only row writes. Each run spent approximately
five seconds in capture connection shutdown. These are useful points for a
later performance review; this change does not modify the applier.

Keep CI in report-only mode until the first Linux CI samples are reviewed.
Then choose limits from repeated runs under the intended build conditions.
Keep a separate non-coverage benchmark for production speed. Do not raise the
limit only to make these first local measurements pass.

The local `summary.md` and `report.json` contain coverage and phase times.
`results.json` contains the exact fixture paths and target SQL counters.
Setup, cleanup and coverage times are separate from replay elapsed time.
