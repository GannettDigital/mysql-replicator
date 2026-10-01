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
BLOCKED or interrupted work still requires future recovery support.
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

When finished, exit the SQL sessions and run on the host:

```sh
make demo-down
```

For a fresh rehearsal, run `make demo-up ARGS=--skip-build` and repeat the setup
block in each terminal. Use this reset for a new rehearsal after the deliberate failure; clean STOPPED
state can instead be resumed without resetting the stack.
See [the full runbook](DEMO.md) for artifacts and qualification details.
