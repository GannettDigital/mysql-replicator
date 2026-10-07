# Demo workbook: four terminals

For common profile-based test, demo and benchmark commands, see the [test lab](../docs/TEST_LAB.md).
The commands in this document remain available; retained legacy demos are separate sessions.

This workbook covers **8.4 → 5.7 MyISAM**. For **5.7 → 8.4 InnoDB**, use the
[reverse demo workbook](REVERSE_DEMO_WORKBOOK.md).

`make demo-up` starts all four containers, including an idle applier.
The `mysql-replicator` process remains unstarted. For this revised flow, use a
demo image built from the current code. If an older rehearsal is still present,
finish it with `make demo-down` (archives evidence and removes that disposable
stack), then run `make demo-up` to build a fresh rehearsal with `skip` support.
Rebuilding an image alone does not replace an already-running container.
Run the setup block below in each host terminal. It reads the current session, so container names
stay correct after rebuilding the demo. `current.json` stores the demo session
identifier; the replicator configuration is `/evidence/apply.yaml`.

```sh
cd /path/to/mysql-replicator
export DEMO_STACK="replicator-lab-$(swift -e '
import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: "artifacts/demo/current.json"))
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
terminals 2–4. Do not run `make demo-start` as well.

New demo setups grant the applier full privileges on the disposable 5.7 target,
including databases other than `demo`. Use explicit 5.7-compatible collations
when creating databases, such as `CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci`.
An existing demo keeps its old grants; recreate it to pick up setup changes.
For experiments with inherited 8.4 defaults, add the optional
[`compatibility.collations` mapping](DDL_COMPATIBILITY.md#optional-collation-translation-and-table-replacement)
to `/evidence/apply.yaml` before the first `--initialize`. A mapping cannot be
changed on saved state; use a fresh demo/baseline for that experiment.

The applier shares MySQL 5.7's network namespace and connects to `127.0.0.1`.
Its container starts with `sleep infinity`; starting or restarting the container
never automatically starts replication. The binary runs only when you launch it.

If you prefer a detached process, use **on the host** instead of the manual launch:

```sh
make demo-start
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
work was applied. `make demo-start` on the host also resumes a clean stop. Keep the
same state directory; do not rerun the successful SQL script after resuming.
General BLOCKED/partial-work recovery is not implemented. For the deliberately
rejected demo DDL, see [the skip command below](#skip-the-rejected-ddl-and-resume).
`docker logs` shows the idle container's output, not output from `docker exec`.

To inspect live state, open another shell in the applier, then run:

```sh
sqlite3 -readonly -header -column /evidence/state/state.sqlite \
  'SELECT lifecycle,transactions_applied,rows_applied,ddl_applied,applied_file,applied_position,diagnostic FROM state;'
```

SQLite appears only after the first launch. `make demo-status` on the host shows
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
make demo-sql FILE=examples/demo/01-success.sql
make demo-compare
```

Use either pasted SQL or the file command, not both on the same stack.

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
channel. Use `make demo-status` on the host for Swift's checkpoint and diagnostics.
Both replicas should contain `(1, updated, 11, after DDL)` and `(3, third, 30, NULL)`.
Their tables should be MyISAM; the source table should be InnoDB. Make changes on
the source only.

## Failure demonstration

**On the host**, after a successful comparison:

```sh
make demo-fail
make demo-status
```

This runs [02-failure.sql](../examples/demo/02-failure.sql) on source: explicit
InnoDB table creation, then marker row 999. Native stops with error 3161; Swift
stops with a BLOCKED diagnostic and unchanged applied checkpoint. On each open
SQL session, run:

```sql
SELECT * FROM demo.items WHERE id=999;
SHOW TABLES FROM demo LIKE 'explicit_innodb';
```

Only source should have the marker and new table. The replicator exits and
returns you to the applier shell; both that container and the 5.7 server stay up. To paste the failure SQL manually instead, first save the good
boundary with `make demo-compare`, paste 02-failure.sql into source, then run
`make demo-compare ARGS=--expect-blocked` on the host. Do not also run demo-fail.

## Skip the rejected DDL and resume

After the failure returns you to the **applier container shell**, copy the full
`pendingGTID` (UUID and number) from the JSON failure output. Alternatively, read it:

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
make demo-sql FILE=examples/demo/03-after-skip.sql
make demo-status
```

In the **source and 5.7 SQL terminals**, verify both rows match:

```sql
SELECT * FROM demo.items WHERE id IN (999,1000) ORDER BY id;
SHOW TABLES FROM demo LIKE 'explicit_innodb';
```

Swift's target has rows `999` and `1000`, but no `explicit_innodb` table.
Expected counters are now 10 transactions, 8 rows and 3 DDL statements.
The native 8.4 replica remains blocked and has neither row, so the three-way
`make demo-compare` is not expected to pass after this Swift-only skip.

## MODIFY COLUMN and secondary indexes

With Swift still running after the skip and new INSERT, run once **on the host**:

```sh
make demo-sql FILE=examples/demo/04-modify-index.sql
make demo-status
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

On the **host**, from the repository root:

```sh
make ddl-suite
```

This builds the current runtime and runs the existing DDL suite, including
following INSERT/UPDATE/DELETE, in both file-position and GTID profiles.
It covers database creation, conditional CREATE/DROP, CREATE LIKE, ALTER,
RENAME, TRUNCATE, MODIFY COLUMN and secondary-index creation/change. It also
checks key-size and duplicate-key failures, DDL timeout and indexed-state resume.
The MODIFY/index cases compare exact metadata, retained rows, schema history,
normalized binlogs and checkpoints. Following DML is selected for changed row/key
behavior; rename/drop cases do not repeat a full DML loop.
Named cases show their source locations. The suite creates and cleans up its
own stacks; the interactive demo remains available. Logs and results are saved
under the printed `artifacts/ddl-suite/` directories.
For the focused DML-only qualification, use `make dml-suite` instead.

For shorter development runs on separate stacks:

```sh
make ddl-suite ARGS='--list'
make ddl-suite ARGS='--slice modify-index --positioning gtid'
make ddl-suite ARGS='--case ddl-modify-demo-varchar-120 --positioning gtid'
make ddl-suite ARGS='--slice filters --positioning gtid'
make dml-suite ARGS='--slice basic --positioning gtid'
```

These run the selected checks plus the shared four-transaction basic comparison.
They do not certify the omitted cases. Add `--skip-build` only when source/test
inputs have not changed since the last image build. See [incremental checks](INCREMENTAL_CHECKS.md).

To exclude a scratch schema in your own apply config, add
`replicateWildIgnoreTable: ['temp.%']` in `/evidence/apply.yaml` before starting
the replicator.
Stop cleanly before changing the config; exclusions affect subsequent events and
advance the checkpoint. Removing the rule later does not backfill earlier data.
See [filter semantics and limits](WILDCARD_FILTERS.md).

To see the coverage checklist and import this run's measured assertions:

```sh
make ddl-catalog-check
make ddl-catalog-report ARGS='--format json --evidence artifacts/ddl-suite/POSITION_RUN/coverage-evidence.json --evidence artifacts/ddl-suite/GTID_RUN/coverage-evidence.json'
```

Replace `POSITION_RUN` and `GTID_RUN` with the two actual directory names printed
by `make ddl-suite`. The report also shows missing assertions; a passing suite
does not imply complete MySQL coverage. See [the catalog guide](../tests/DDLCoverage/README.md).
`make demo-suite` separately automates this workbook's success → failure → skip
→ new INSERT → MODIFY/index flow, plus clean-stop/resume checks.

## Clean up

When finished, exit the SQL sessions and run on the host:

```sh
make demo-down
```

For a fresh rehearsal, run `make demo-up ARGS=--skip-build` and repeat the setup
block in each terminal. Use this reset for a new rehearsal after the deliberate failure; clean STOPPED
state can instead be resumed without resetting the stack.
See [the full runbook](DEMO.md) for artifacts and qualification details.
