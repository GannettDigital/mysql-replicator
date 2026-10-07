# Reverse demo workbook: four terminals

This workbook exercises **5.7 InnoDB → replicator → 8.4 InnoDB**, alongside a
native **5.7 → 5.7 InnoDB** reference. It uses preloaded tables and DML only.
The original [demo workbook](DEMO_WORKBOOK.md) covers the separate MyISAM profile.

## Prepare the demo

On the host, from the repository root:

```sh
make reverse-demo-up
make reverse-demo-status
```

`up` prepares three databases and an idle Ubuntu applier container. Expected status:
`Applier container: running`, `Replication: NOT_STARTED`, and native IO/SQL `Yes`.
Replication starts only when requested. Rerunning `up` reuses the current session;
it can add an applier missing from an older setup without resetting databases,
configuration, or SQLite. It uses that session's pinned image. To deliberately
start fresh, use `make reverse-demo-down`, then `make reverse-demo-up`.

Run this setup in **each host terminal** so the container names match your session:

```sh
cd /path/to/mysql-replicator
export REVERSE_STACK="replicator-lab-$(python3 -c 'import json; print(json.load(open("artifacts/reverse-demo/current.json"))["identifier"].lower())')"
```

The shared Compose service names are inherited from the original test stack:

| Role | Container suffix | Version / engine |
| --- | --- | --- |
| Source | `-target57-1` | 5.7 InnoDB |
| Native reference | `-native-1` | 5.7 InnoDB |
| Replicator destination | `-source-1` | 8.4 InnoDB |
| Applier shell | `-applier` | Ubuntu with mysql-replicator |

## Terminal 1 — start replication and watch logs

On the host:

```sh
make reverse-demo-start
docker exec -it "${REVERSE_STACK}-applier" /bin/bash
```

Inside the applier container:

```sh
cat /evidence/apply.yaml
tail -f /evidence/applier.ndjson /evidence/applier.stderr
```

Ctrl-C exits the log viewer; the replication process keeps running. `docker logs`
shows the idle shell container's output; use the files above for detached
replication logs. Exit the shell to return to host commands.

`reverse-demo-start` initializes state only on the first launch. Later launches
resume a clean STOPPED checkpoint. Do not initialize again or replay the successful
SQL example after it has already committed.

For a **foreground** process instead of `reverse-demo-start`, enter the idle
container and run:

```sh
mysql-replicator run --config /evidence/apply.yaml --initialize
```

On later starts, omit `--initialize`. Do not also start a detached process. Status
and `reverse-demo-stop` detect either launch method. Foreground output appears in
that terminal, not in the detached log files. For comparison in this mode, wait
until the workload is reflected in the progress output, run `reverse-demo-stop`
on the host, then `reverse-demo-compare`; resume manually afterward.

## Terminal 2 — source MySQL 5.7

On the host:

```sh
docker exec -it -e MYSQL_PWD=fixture-root-only "${REVERSE_STACK}-target57-1" \
  mysql --no-defaults -uroot --default-character-set=utf8mb4 --prompt='source57> '
```

Paste [01-success.sql](../examples/reverse-demo/01-success.sql) once. It inserts
multiple rows, updates a composite primary key, updates values, deletes a row and
writes another table, all within one transaction.

Alternatively, execute the file **on the host**, instead of pasting it:

```sh
make reverse-demo-sql FILE=examples/reverse-demo/01-success.sql
make reverse-demo-compare
```

The comparison waits for the source GTID, drains the detached applier, compares
all three databases and restarts the previously running applier. Pause other
source writes during comparison.

Tables `reverse_poc.items` and `reverse_poc.aux` already exist on all servers.
Do not run the original demo's CREATE/ALTER examples here: reverse-profile DDL
and foreign keys remain unsupported.

## Terminal 3 — native MySQL 5.7 reference

On the host:

```sh
docker exec -it -e MYSQL_PWD=fixture-root-only "${REVERSE_STACK}-native-1" \
  mysql --no-defaults -uroot --default-character-set=utf8mb4 --prompt='native57> '
```

At the SQL prompt:

```sql
SELECT report_date,id,value,amount,choice,flags,HEX(payload)
  FROM reverse_poc.items ORDER BY report_date,id;
SELECT * FROM reverse_poc.aux ORDER BY id;
SHOW SLAVE STATUS\G
```

Native IO and SQL threads should run, with no errors. This reference has the same
source GTIDs; the 8.4 destination generates its own GTIDs when our applier commits.

## Terminal 4 — MySQL 8.4 destination

On the host:

```sh
docker exec -it -e MYSQL_PWD=fixture-root-only "${REVERSE_STACK}-source-1" \
  mysql --no-defaults -uroot --default-character-set=utf8mb4 --prompt='replicator84> '
```

At the SQL prompt, run the same SELECTs as terminal 3, plus:

```sql
SHOW CREATE TABLE reverse_poc.items\G
SHOW REPLICA STATUS\G
```

There is no native channel on this destination, so `SHOW REPLICA STATUS` is empty.
Use `make reverse-demo-status` for our process and checkpoint. All tables are
InnoDB. After the first SQL example, all three databases contain:

- Item `(2026-10-06, 1)`: `seed`, amount `1.00`, choice `ready`.
- Item `(2026-10-07, 2)`: `updated`, amount `7.75`, choice `ready`.
- No item with ID 3; auxiliary row `(1, 10)`.

## Drain and resume

On the host:

```sh
make reverse-demo-stop
make reverse-demo-status
make reverse-demo-start
make reverse-demo-sql FILE=examples/reverse-demo/02-after-resume.sql
make reverse-demo-compare
```

After stopping, the applier container stays running and available for a shell;
replication reports STOPPED. After the second SQL example, auxiliary counter 1
is `11` and item 2 has choice `done` on all three servers.

## Deliberate failure and audited retry

Run this once, after the preceding examples. Stop source writes and drain:

```sh
make reverse-demo-stop
```

In **terminal 4 (8.4 destination only)**, introduce a conflicting row:

```sql
INSERT INTO reverse_poc.aux VALUES(99,99);
```

In **terminal 2 (5.7 source)**:

```sql
START TRANSACTION;
UPDATE reverse_poc.items SET value='recovered' WHERE id=2;
INSERT INTO reverse_poc.aux VALUES(99,99);
COMMIT;
```

On the host, start replication and inspect its failure:

```sh
make reverse-demo-start
make reverse-demo-status
make reverse-demo-inspect
```

The start command may report failure if replication exits before its readiness
check. Expected state is BLOCKED with a duplicate-key error and `rolledBack`.
The shell container stays running. The native replica has applied the transaction;
our destination has rolled it back, including the earlier item update.
Inspection includes the pending GTID, composite key, row images and diagnostics.

In **terminal 4**, remove the target-only conflict:

```sql
DELETE FROM reverse_poc.aux WHERE id=99;
```

Copy the exact pending GTID from inspection. On the host, replace `<FAILED_GTID>`:

```sh
make reverse-demo-resolve ARGS="retry --gtids '<FAILED_GTID>' --reason 'Removed target-only conflict after confirmed rollback'"
make reverse-demo-start
make reverse-demo-compare
```

All three now contain item 2 with value `recovered` and auxiliary row `(99,99)`.
The resolution is recorded in SQLite's `recovery_audit`; it does not automatically
restart replication. This controlled rollback is only one recovery case. For an
uncertain COMMIT, reconcile the entire pending batch before choosing an action;
see the [recovery guide](../docs/REVERSE_REPLICATION.md#offline-inspection-and-dba-resolution).

## Clean up

On the host:

```sh
make reverse-demo-down
```

This drains any active process, archives the volume and logs, and removes only
this disposable reverse-demo stack. The original demo and other stacks are separate.
`make reverse-demo-suite ARGS=--skip-build` tests this lifecycle on its own stack,
including idle status, missing-container repair, blocked status and recovery.
