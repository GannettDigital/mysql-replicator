# Demo workbook: four terminals

For common profile-based test, demo and benchmark commands, see the [test lab](../docs/TEST_LAB.md).
Both profiles use the shared retained-session implementation. Set `PROFILE` in each host terminal as shown below.

This workbook covers **8.4 → 5.7 MyISAM**. For **5.7 → 8.4 InnoDB**, use the
[reverse demo workbook](REVERSE_DEMO_WORKBOOK.md).

The shared demo starts three databases and an idle applier. Repeating `up`
reuses its pinned image and repairs a missing shell without resetting the saved
state. Use `down` before creating a fresh rehearsal. An old `artifacts/demo/`
session is not adopted; clean it up with `make lab-demo PROFILE=mysql84-to-mysql57-myisam ACTION=legacy-down`.
Run the setup block below in each host terminal. It reads the current session, so container names
stay correct after rebuilding the demo. `current.json` stores the demo session
identifier; the replicator configuration is `/evidence/apply.yaml`.

```sh
cd /path/to/mysql-replicator
export PROFILE=mysql84-to-mysql57-myisam
make lab-demo ACTION=up
export DEMO_STACK="replicator-lab-$(swift -e '
import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: "artifacts/demos/mysql84-to-mysql57-myisam/current.json"))
let session = try JSONSerialization.jsonObject(with: data) as! [String: Any]
print((session["identifier"] as! String).lowercased())
')"
```

## Terminal 1 — log in and start replication manually

**Run on the host** to enter the already-running Ubuntu applier container:

```sh
docker exec -it "${DEMO_STACK}-applier" /bin/bash
```

**Inside that container**, inspect the config and start the replicator:

```sh
cat /evidence/apply.yaml
mysql-replicator run --config /evidence/apply.yaml --initialize
```

The password environment variables are already set. Leave this command running
in the foreground; progress and errors appear in this terminal. Continue with
terminals 2–4. Do not run `make lab-demo ACTION=start` as well.

From another host terminal, inspect or gracefully stop that process without
finding its PID:

```sh
docker exec "${DEMO_STACK}-applier" mysql-replicator ctl status --config /evidence/apply.yaml
docker exec "${DEMO_STACK}-applier" mysql-replicator ctl stop --config /evidence/apply.yaml
```

After editing only the run limits in YAML, use `ctl reload` with the same config
path. See [process controls](../docs/OFFLINE_REPLAY.md#controlling-a-running-process)
for exact GTID stopping, reload restrictions, and acknowledgment timeouts.

New demo setups grant the applier full privileges on the disposable 5.7 target,
including databases other than `demo`. Use explicit 5.7-compatible collations
when creating databases, such as `CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci`.
An existing demo keeps its old grants; recreate it to pick up setup changes.
For experiments with inherited 8.4 defaults, add the optional
[`compatibility.collations` mapping](DDL_COMPATIBILITY.md#optional-collation-translation-and-table-replacement)
to `/evidence/apply.yaml` before the first `--initialize`. A mapping cannot be
changed on saved state; use a fresh demo/baseline for that experiment.

The applier connects to the `target57` service over the fixture network using TLS.
Its container starts with `sleep infinity`; starting or restarting the container
never automatically starts replication. The binary runs only when you launch it.

If you prefer a detached process, use **on the host** instead of the manual launch:

```sh
make lab-demo ACTION=start
docker exec "${DEMO_STACK}-applier" tail -f /evidence/applier.ndjson /evidence/applier.stderr
```

Ctrl-C in this log viewer stops viewing only. Ctrl-C in the foreground replicator
stops replication. While idle or between complete transactions, it prints a
`STOPPED` summary, exits successfully, and persists `STOPPED` with no error
diagnostic. Interrupting a partial transaction or apply still leaves `BLOCKED`.
After STOPPED, resume in the same shell without the initialization flag:

```sh
mysql-replicator run --config /evidence/apply.yaml
```

This uses saved applied GTID/position, falling back to the saved baseline when no
work was applied. `make lab-demo ACTION=start` on the host also resumes a clean stop. Keep the
same state directory; do not rerun the successful SQL script after resuming.
General BLOCKED/partial-work recovery is not implemented. For the deliberately
rejected demo DDL, see [the skip command below](#skip-the-rejected-ddl-and-resume).
`docker logs` shows the idle container's output, not output from `docker exec`.

To inspect live state, open another shell in the applier, then run:

```sh
sqlite3 -readonly -header -column /evidence/state/state.sqlite \
  'SELECT lifecycle,transactions_applied,rows_applied,ddl_applied,applied_file,applied_position,diagnostic FROM state;'
```

SQLite appears only after the first launch. `make lab-demo ACTION=status` on the host shows
container state, whether the binary is running, and SQLite state separately.

## Terminal 2 — source MySQL 8.4 (InnoDB)

**Run on the host** to open SQL:

```sh
docker exec -it -e MYSQL_PWD=fixture-root-only "${DEMO_STACK}-source-1" \
  mysql --no-defaults -uroot --default-character-set=utf8mb4 --prompt='source84> '
```

Paste the statements from [01-success.sql](../examples/demo/01-success.sql) here,
once, in order. It includes CREATE DATABASE/TABLE, INSERT/UPDATE/DELETE and ADD COLUMN.
Alternatively, leave SQL with `exit` and run the entire file from the host:

```sh
make lab-demo ACTION=sql ARGS=examples/demo/01-success.sql
make lab-demo ACTION=compare
```

Use either pasted SQL or the file command, not both on the same stack. Comparison
waits for the completed source boundary and reads SQLite inside the volume;
it leaves your foreground or detached applier running.

## Terminal 3 — native MySQL 8.4 replica (MyISAM)

**Run on the host** to open SQL:

```sh
docker exec -it -e MYSQL_PWD=fixture-root-only "${DEMO_STACK}-native-1" \
  mysql --no-defaults -uroot --default-character-set=utf8mb4 --prompt='native84> '
```

**At the SQL prompt**, after the source workload:

```sql
SELECT * FROM demo.items ORDER BY id;
SHOW CREATE TABLE demo.items\G
SHOW REPLICA STATUS\G
```

## Terminal 4 — MySQL 5.7 target (MyISAM)

**Run on the host** to open SQL:

```sh
docker exec -it -e MYSQL_PWD=fixture-root-only "${DEMO_STACK}-target57-1" \
  mysql --no-defaults -uroot --default-character-set=utf8mb4 --prompt='swift57> '
```

**At the SQL prompt**, after the source workload:

```sql
SELECT * FROM demo.items ORDER BY id;
SHOW CREATE TABLE demo.items\G
SHOW SLAVE STATUS\G
```

`SHOW SLAVE STATUS` is empty on 5.7: Swift owns replication, so there is no native
channel. Use `make lab-demo ACTION=status` on the host for Swift's checkpoint and diagnostics.
Both replicas should contain `(1, updated, 11, after DDL)` and `(3, third, 30, NULL)`.
Their tables should be MyISAM; the source table should be InnoDB. Make changes on
the source only.

## Failure demonstration

**On the host**, after a successful comparison:

```sh
make lab-demo ACTION=fail
make lab-demo ACTION=status
```

This runs [02-failure.sql](../examples/demo/02-failure.sql) on source: explicit
InnoDB table creation, then marker row 999. Native stops with error 3161; Swift
stops with a BLOCKED diagnostic and unchanged applied checkpoint. On each open
SQL session, run:

```sql
SELECT * FROM demo.items WHERE id=999;
SHOW TABLES FROM demo LIKE 'explicit_innodb';
```

Only source should have the marker and new table. The replicator exits (or returns you to the shell if you resumed it manually); both that container and the 5.7 server stay up. To paste the failure SQL manually instead, first save the good
boundary with `make lab-demo ACTION=compare`, paste 02-failure.sql into source, then run
`make lab-demo ACTION=compare ARGS=--expect-blocked` on the host. Do not also run `ACTION=fail`.

## Skip the rejected DDL and resume

In the **applier container shell**, copy the full
`pendingGTID` (UUID and number) from the JSON failure output. For a detached
process, read `/evidence/applier.stderr`, or query SQLite:

```sh
sqlite3 -readonly /evidence/state/state.sqlite 'SELECT active_gtid FROM state WHERE id=1;'
```

Replace `<FAILED_GTID>` with that value, then run inside the applier container:

```sh
mysql-replicator skip '<FAILED_GTID>' --config /evidence/apply.yaml
mysql-replicator run --config /evidence/apply.yaml
```

For example, if the failure reports `2d7c9265-bd4d-11f1-ad69-6e5c8a8d99ba:18`,
the first command is `mysql-replicator skip '2d7c9265-bd4d-11f1-ad69-6e5c8a8d99ba:18' --config /evidence/apply.yaml`.
Use your own run's GTID, not this example. Do not use `--initialize` when resuming.

`skip` prints a `skip_summary` with `lifecycle: STOPPED`, `skippedGTIDSet`,
`resumeGTIDSet` and `resumePosition`. It holds the writer lock and atomically
removes the pending group, stores the full completed-plus-skipped GTID coverage,
advances to that group's end position, and clears the blocked diagnostic.
It neither creates the rejected table nor starts replication. Counters remain
8 transactions, 6 rows and 3 DDL statements; schemas and relay bytes are unchanged.
The `appliedGTIDSet`/`appliedPosition` fields now include the skipped
event as restart coverage, even though its SQL was not applied.

The command accepts GTID-set syntax, but this serial applier currently permits
exactly the one captured pending GTID. Wider ranges, uncaptured GTIDs, an active
writer, and groups with any row/DDL write intents are refused. Partial or
uncertain target writes still require manual resolution. This demo's explicit
InnoDB rejection happens before any write intent, so it qualifies.

After resuming, Swift applies the previously queued marker `999`. On the **host**,
send one more transaction while the resumed replicator is running:

```sh
make lab-demo ACTION=sql ARGS=examples/demo/03-after-skip.sql
make lab-demo ACTION=status
```

In the **source and 5.7 SQL terminals**, verify both rows match:

```sql
SELECT * FROM demo.items WHERE id IN (999,1000) ORDER BY id;
SHOW TABLES FROM demo LIKE 'explicit_innodb';
```

Swift's target has rows `999` and `1000`, but no `explicit_innodb` table.
Expected counters are now 10 transactions, 8 rows and 3 DDL statements.
The native 8.4 replica remains blocked and has neither row, so the three-way
`make lab-demo ACTION=compare` is not expected to pass after this Swift-only skip.

## MODIFY COLUMN and secondary indexes

With Swift still running after the skip and new INSERT, run once **on the host**:

```sh
make lab-demo ACTION=sql ARGS=examples/demo/04-modify-index.sql
make lab-demo ACTION=status
```

The [prepared SQL](../examples/demo/04-modify-index.sql) widens `value` from 100 to
120 characters, creates and renames a prefix index, replaces it with a composite
index, then inserts, updates and deletes a 110-character value. SQL is forwarded
unchanged; the server's table defaults supply omitted encoding attributes.

In the **source and 5.7 SQL terminals**, compare:

```sql
SHOW COLUMNS FROM demo.items;
SHOW INDEX FROM demo.items;
SELECT * FROM demo.items ORDER BY id;
```

Both should show `value VARCHAR(120) NOT NULL` and the nonunique BTREE index
`value_prefix(value(30),quantity)`. Ignore index cardinality estimates when
comparing. Row 1001 has been deleted; rows 1, 3, 999 and 1000 remain. After catching
up, Swift reports 17 transactions, 11 rows and 7 DDL statements. Native 8.4 remains
blocked on the earlier intentional failure, so compare source with 5.7 here.

New state uses SQLite format 6 with versioned binary relay metadata. Clean STOPPED
format-4/5 state upgrades on resume, preserving existing relay bytes and offsets;
BLOCKED format-4 state must be resolved using its original binary first. For this
workbook, use a fresh demo built from the current code. Do not change SQLite's
version number manually. See [relay format and compatibility](PERFORMANCE_BENCHMARK.md#binary-metadata-and-cached-timestamps).

## Longer DDL/DML validation on separate stacks

```sh
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--variant all"
make lab-list
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--case ddl-modify-demo-varchar-120 --variant gtid-full"
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--family filters --variant gtid-full"
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--family bootstrap --variant gtid-full"
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite demo --coverage"
```

These run on disposable stacks separate from the interactive session. The shared
demo suite automates the workbook plus idle heartbeats, shell repair, SIGINT/SIGTERM,
GTID/file-position resume, duplicate-writer rejection and exact counter checks.
Use `--suite demo --list` to inspect named cases and dependencies, or
`--suite demo --case demo-skip-and-resume` for its prerequisite workflow.
See [the test lab](../docs/TEST_LAB.md) for applicability and evidence paths.

To exclude a scratch schema in your own apply config, add
`replicateWildIgnoreTable: ['temp.%']` in `/evidence/apply.yaml` before starting
the replicator.
Stop cleanly before changing the config; exclusions affect subsequent events and
advance the checkpoint. Removing the rule later does not backfill earlier data.
See [filter semantics and limits](WILDCARD_FILTERS.md).

The [catalog guide](../tests/DDLCoverage/README.md) explains importing named
correctness evidence. Demo case results and Swift line coverage do not substitute
for catalog qualification. Demo coverage is collected with `ACTION=up ARGS=--coverage`
and exported when `ACTION=down` drains and archives the session.

## Clean up

When finished, exit the SQL sessions and run on the host:

```sh
make lab-demo ACTION=down
```

For a fresh rehearsal, run `make lab-demo ACTION=up ARGS=--skip-build` and repeat the setup
block in each terminal. Use this reset for a new rehearsal after the deliberate failure; clean STOPPED
state can instead be resumed without resetting the stack.
See [the full runbook](DEMO.md) for artifacts and qualification details.
