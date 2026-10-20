# Cross-database foreign-key drops

Branch: `beta/6/52-cross-database-foreign-keys`, based on branch 51.

## Native behavior

Disposable probes confirmed these rules on MySQL 5.7.42 and 8.4.8:

- DROP DATABASE can remove child tables that reference a parent in another database.
  The parent remains. The dropped child constraints disappear.
- With `foreign_key_checks=0`, DROP DATABASE can remove a parent database while
  children remain in another database. Each child keeps its FK metadata.
- A later CREATE DATABASE and CREATE TABLE can restore that parent. New row
  operations use the restored relationship.

With checks enabled, a surviving incoming FK prevents a parent database drop.
The applier checks this before it sends the DROP. Native MySQL 5.7 can partly
complete a failing DROP DATABASE, so detecting the dependency first is useful.
Native engine and privilege errors still apply.

## Implementation

DROP discovers FK participants inside the database. The shared graph planner
then discovers related outside tables. It predicts the surviving relationships.
The DDL intent records dropped tables and surviving participants before execution.
It also records a surviving child when its FK metadata does not change.

After target success, the applier checks the surviving schemas. SQLite retires the
removed schemas and saves changed outside schemas with the same source GTID.
The in-memory cache uses those same results. An unchanged child keeps its schema
version and its missing-parent relationship. Restart validates the saved schemas.

The existing FK metadata limits, table filters and global REFERENCES requirement
remain in effect. No SQLite format change or new setting is required.

## Verification

The selected apply and lab unit run passed 488 tests. One test checks a database
DROP with an unchanged outside child. It checks the pending intent, retired parent,
surviving relationship and completed intent.

The shared `ddl-compat-foreign-key-cross-database` workflow compares both databases
across source, native replica and target. It checks disabled-check parent DROP,
child DML while the parent is absent, parent recreation, cascades, child database
DROP, restart and offline replay. Replay stops while the parent database is absent.

The safety case adds an unexpected incoming FK only on the target. The source and
native replica accept DROP. The applier must fail before a DDL intent and retain
its checkpoint and target rows. The fixture saves the failure support bundle.

Periphery found no unused code. Both InnoDB profiles passed the new workflow,
`ddl-compat-foreign-key-ddl` and `foreign-key-safety`. Each run completed 45 reported
workflow steps, plus isolated safety checks. The full profile matrix was not run.

The expected DROP failure bundles report `statement.phase=notIssued`. A read-only
query of each bundled SQLite database confirms `BLOCKED`, zero applied transactions
and no DDL intent. No target DROP was issued.

| Profile | Local artifact root |
| --- | --- |
| 5.7 → 8.4 InnoDB | `artifacts/lab/20261016T043431Z-afd4c789` |
| 5.7 → 5.7 InnoDB | `artifacts/lab/20261016T043609Z-bed7fbc7` |

Both runs used binary SHA-256
`f482092553809392468c3ea264f786c260129ddb83ab804a51cfbeadd3649036`.

## Remaining FK limits

Branch 53 adds [stored generated FK columns](GENERATED_COLUMN_FOREIGN_KEYS.md).
Some compound supporting-index changes need further work.
Partitioned InnoDB FK tables remain subject to native engine restrictions.
