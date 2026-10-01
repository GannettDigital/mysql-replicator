# Demo workbook: four terminals

`make demo-up` starts all four containers, including an idle applier.
The `mysql-replicator` process remains unstarted. Run the setup
block below in each host terminal. It reads the current session, so container names
stay correct after rebuilding the demo.

```sh
cd /Users/k.antselovich/REPO/mysql-replicator
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
cat /evidence/apply.json
mysql-replicator run --config /evidence/apply.json --initialize
```

The password environment variables are already set. Leave this command running
in the foreground; progress and errors appear in this terminal. Continue with
terminals 2–4. Do not run `make demo-start` as well.

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
mysql-replicator run --config /evidence/apply.json
```

This uses saved applied GTID/position, falling back to the saved baseline when no
work was applied. `make demo-start` on the host also resumes a clean stop. Keep the
same state directory; do not rerun the successful SQL script after resuming.
General BLOCKED/partial-work recovery is not implemented. For the deliberately
rejected demo DDL, see [the manual SQLite skip below](#optional--skip-the-rejected-demo-ddl-in-sqlite).
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

## Finish with the failure demonstration

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

## Optional — skip the rejected demo DDL in SQLite

Use this for the demo's rejected CREATE TABLE, which failed before executing any
SQL on the target and has no row/DDL intents. Keep the replicator stopped until
all three statements below have completed. No audit table is needed.

**Inside the applier container**, open SQLite:

```sh
flock -n /evidence/state/writer.lock sqlite3 /evidence/state/state.sqlite
```

Find the values to copy before deleting the pending group:

```sql
.mode line
SELECT lifecycle, active_gtid, applied_sequence FROM state WHERE id=1;
SELECT gtid, source_file, end_position FROM groups WHERE status='PENDING';
```

Replace the placeholders in the three statements below:

| Placeholder | Where to copy it from | Original demo example |
| --- | --- | --- |
| `<FAILED_GTID>` | `state.active_gtid`, also shown as `groups.gtid` and `pendingGTID` in the failure output. Copy the full UUID and number. | `2d7c9265-bd4d-11f1-ad69-6e5c8a8d99ba:18` |
| `<APPLIED_SEQUENCE>` | `state.applied_sequence`; keep this value unchanged, not the pending group's sequence. | `8` |
| `<BINLOG_FILE>` | The pending group's `source_file`. | `binlog.000003` |
| `<END_POSITION>` | The pending group's `end_position`, not its start position or the old applied position. | `4004` |
| `<COVERED_GTID_SET>` | Take `appliedGTIDSet` from the failure output and add the failed GTID. In this demo, change the same UUID's interval `:1-17` to `:1-18`. Preserve all other intervals if present. | `2d7c9265-bd4d-11f1-ad69-6e5c8a8d99ba:1-18` |

Do not use the latest snapshot's GTID set alone: in this example it still contains
only the baseline `:1-9`, while the failure output includes the completed work.

1. Delete the pending group for the copied failed GTID:

```sql
DELETE FROM groups
WHERE gtid='<FAILED_GTID>' AND status='PENDING';
```

2. Insert a snapshot covering the completed work plus the skipped GTID:

```sql
INSERT INTO snapshots(covered_sequence,gtids,source_file,source_position,created_at)
VALUES(<APPLIED_SEQUENCE>, '<COVERED_GTID_SET>', '<BINLOG_FILE>', '<END_POSITION>',
       strftime('%Y-%m-%dT%H:%M:%fZ','now'));
```

3. Advance the saved position and clear the blocked state:

```sql
UPDATE state
SET applied_file='<BINLOG_FILE>', applied_position='<END_POSITION>',
    lifecycle='STOPPED', active_gtid=NULL, diagnostic=NULL,
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
WHERE id=1 AND lifecycle='BLOCKED' AND active_gtid='<FAILED_GTID>';
```

Applied counters stay at 8 transactions, 6 rows, and 3 DDL statements in this
example; `applied_sequence` stays 8. Leave schemas, completed groups/intents, and
relay files unchanged. With this version-4 workaround, `appliedGTIDSet` and
`appliedPosition` include the skipped event even though its SQL was not applied.

Type `.exit`, then resume at the applier shell without initialization:

```sh
mysql-replicator run --config /evidence/apply.json
```

Swift can now apply the following marker row `999`; `demo.explicit_innodb` remains
absent on its target. The native 8.4 replica is still blocked, so the three-way
`make demo-compare` is not expected to pass after this Swift-only skip.

## Clean up

When finished, exit the SQL sessions and run on the host:

```sh
make demo-down
```

For a fresh rehearsal, run `make demo-up ARGS=--skip-build` and repeat the setup
block in each terminal. Use this reset for a new rehearsal after the deliberate failure; clean STOPPED
state can instead be resumed without resetting the stack.
See [the full runbook](DEMO.md) for artifacts and qualification details.
