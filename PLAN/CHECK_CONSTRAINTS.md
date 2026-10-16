# CHECK constraints: native behavior and implementation work

Status: implemented on `beta/6/36-check-compatibility`. Selected live and offline
checks passed. Native 5.7 to 8.0 behavior is confirmed.

MySQL 5.7.42 accepts the following SQL. It also accepts the rows that violate the
expressions. SHOW CREATE TABLE omits both constraints.

```sql
CREATE TABLE check_probe (
  id INT PRIMARY KEY,
  v INT CHECK (v > 0),
  CONSTRAINT positive CHECK (id > 0)
) ENGINE=InnoDB;
INSERT INTO check_probe VALUES (-1, -1);
ALTER TABLE check_probe ADD CONSTRAINT newer CHECK (v > 10);
INSERT INTO check_probe VALUES (-2, -2);
```

The pinned 5.7 `sql/sql_yacc.yy` has `check_constraint` and
`opt_check_constraint` productions. They parse the expression but do not create
an enforced constraint. This applies to both column and table forms.

## Native replication result

A live GTID/ROW test used MySQL 5.7.42 as the source and MySQL 8.0.43 as the
native replica. The replica started at the source's current executed GTID set.
The workload created a new database and used the CREATE, ALTER and violating
rows above. It also added a column and a CHECK in one ALTER.

The source binlog retained all CHECK clauses in its Query events. The replica
applied all seven workload GTIDs. It had zero CHECK constraints, retained all
three violating rows, and showed no IO or SQL worker errors. The compound ALTER
added the column with its default. SHOW CREATE TABLE omitted the checks.

MySQL implements an explicit replication rule. The function
`is_slave_with_master_without_check_constraints_support` checks both conditions:

- Execution is in a native replication SQL thread or worker.
- The original server version is unknown or older than 8.0.16.

The CREATE and ALTER preparation paths then clear the check specification list.
This is not a NOT ENFORCED constraint. No constraint object is created.

References in Oracle's MySQL 8.0.45 source:

- [Version and thread check](https://github.com/mysql/mysql-server/blob/mysql-8.0.45/sql/sql_check_constraint.cc#L95-L100).
- [CREATE and ALTER constraint preparation](https://github.com/mysql/mysql-server/blob/mysql-8.0.45/sql/sql_table.cc#L17527-L17540).

The local pinned 8.4 source contains the same rule in `sql/sql_check_constraint.cc`
and `sql/sql_table.cc`. The external applier must reproduce it for 5.7 sources.
An ordinary target client does not get this behavior. A direct 8.0.43 test still
created a CHECK after `SET SESSION original_server_version=0`.

## Implementation

The central `NativeReplicationRules` type owns the 8.0.16 boundary and the
version-specific decision. `MySQLSyntax.SQLCheckClause` identifies clause
boundaries without applying version policy. The applier uses byte-range edits
for column and table CHECK forms, including compound ALTER statements.

Check-only ALTER statements retain a normal DDL intent and the original source
SQL. They record the rule ID, execute no target DDL, keep the schema ID and
complete the checkpoint. Both run and replay use this path. See the
[native compatibility guide](../docs/NATIVE_COMPATIBILITY.md).

## Verification

- 462 affected apply, syntax and lab tests passed before the final byte-encoding
  test and replay fixture additions.
- Six focused compatibility tests then passed, including latin1 byte retention
  and native version sentinels. The updated lab and compatibility run passed
  105 tests.
- The independent syntax target passed 25 tests with 638/641 executable lines
  covered (99.53%).
- The shared positive case applies to all three 5.7-source profiles. It includes
  violating rows, CREATE LIKE, column removal, a durable no-op ALTER, restart,
  and offline stop/resume with an unreachable source.
- The 8.4-source negative case requires rejection before target DDL.

These checks do not qualify all expression forms, SQL modes, crash windows or
chained-source topologies.

Local probe SQL and the 8.0 result are saved under
`artifacts/beta6-native-checks/` in the branch 35 worktree.

### Initial live fixture correction

Run `20261015T152023Z-c8cc23bb` passed the 8.4-source target-limit case.
Each 5.7 source rejected `MODIFY v INT CHECK(v>100)` with error 1064. The
applier did not enter BLOCKED, so no support bundle was expected. Saved steps
show successful CREATE, check-only ALTER, violating inserts and compound ADD
before the source syntax error.

The pinned 5.7 grammar permits `opt_check_constraint` in CREATE/ADD field lists,
but not in the MODIFY field definition used here. The fixture now uses the
native-valid `MODIFY v INT, ADD CHECK(v>100)` form. A direct 5.7.42 probe accepted
it. The corrected focused parser and catalog run passed nine tests.

### Final live and replay results

Run `20261015T152824Z-b1b3342b` passed `ddl-compat-ignored-checks` on all
three applicable profiles:

- MySQL 5.7 to MySQL 8.4 InnoDB.
- MySQL 5.7 to MySQL 5.7 MyISAM.
- MySQL 5.7 to MySQL 5.7 InnoDB.

Each profile passed the live restart checks and offline replay. Replay stopped
after three transactions, at the check-only ALTER, then resumed to the final
GTID after 12 transactions. The target had no CHECK constraints. The final row
and schema comparisons passed. The replay configuration used an unreachable
source address.

The outer lab result is `passed`, with no build-input error. Its input digest is
`384f787603b35c8c57b27ac931a26c2dbe4f9d18bb50890f30242ce2fd7de6a9`.
The 8.4-source positive case is not applicable. Its separate target-limit case
passed in the initial run recorded above. Periphery reported no unused code.
