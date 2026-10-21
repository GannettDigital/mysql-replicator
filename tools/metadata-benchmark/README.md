# Schema discovery measurements

Use `replicator-lab benchmark --mode discovery`. Build the local
`mysql-replicator` binary first. This command uses local MySQL fixture images.
It creates and removes its own containers. It does not accept an existing server.

```sh
swift run replicator-lab benchmark --mode discovery \
  --profile mysql57-to-mysql84-innodb --binary .build/debug/mysql-replicator \
  --tables 8 --events 128 --foreign-key-group-size 4 --target-rtt-ms 20
```

Set `--dml-transport binlog` to repeat the same workload with BINLOG transport.
All four profiles are accepted. FK groups require an InnoDB target. A group has
one parent and the remaining tables reference that parent. Tables have primary
keys, a secondary index, and integer columns. The test compares every final row
with the source. It is not a complete data-type or DDL test.

The test runs with zero added delay, then with the specified added RTT. A local
TCP proxy delays each direction by half this value. It forwards bytes unchanged
and bounds its queues. It does not simulate packet loss or bandwidth limits.
Ten MySQL `COM_PING` samples, after one warm-up ping, measure the actual RTT
through the proxy. The proxy is used by both target connections. The source
archive is local, so source network delay is excluded.

The first write to each table requires discovery. Later writes reuse the table
cache. The test requires one outer discovery per table. It records per-table
query counts and checks all result rows. A separate phase reopens the saved
state, updates a row, adds a column with ALTER, and inserts another row. This
checks new-session validation and DDL invalidation. Its time is excluded from
the initial throughput result. It does not inject a lost connection or COMMIT.

Results are under `artifacts/metadata-benchmark/PROFILE/RUN/`:

- `result.json`: versions, image IDs, timings, RTT samples, and checks.
- `0ms/result.json` and `20ms/result.json`: discovery query counts, reused reads,
  query-family times, write time, and complete stage timings.
- `stdout.ndjson`, `stderr.ndjson`, and `resume.*.ndjson`: applier output.
- `state/` and `bundles/`: copied state and automatic support bundles on failure.
- `archive/` and `resume-archive/`: synthetic source binlogs.

The applier uses a short temporary state path to fit the Unix control socket
limit. The tool copies state into the output directory before it removes this
path. The saved config records the original temporary path; do not use it to
resume the copied state without review.

`target.metadata.*` times include network waits and server execution.
`target.metadata.cache_hit` counts reads reused within one discovery; it is not
a network query. A first prepared query can need a separate prepare request.
Thus, metadata query counts are SQL command counts, not packet counts or exact
network round trips. `target.sql.write` measures mutation statements;
`target.sql.read_or_control` includes metadata, session setup, and transaction
control. Nested stages overlap. Do not add them to obtain total elapsed time.

The benchmark accepts up to 6,000 tables and 100,000 row transactions. Set
`--events` to at least the table count. Large runs can take much longer than the
small example. A small run does not establish performance for 5,000 tables.
The target table cache defaults to 6,000 entries. Use the top-level
`maximumCachedTables` setting to change it for normal run or replay.
