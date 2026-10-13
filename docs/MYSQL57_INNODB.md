# MySQL 5.7 InnoDB → MySQL 5.7 InnoDB

Select `profile: mysql57-to-mysql57-innodb` in the [live](../examples/run.minimal.yaml)
or [replay](../examples/replay.minimal.yaml) configuration. The lab uses MySQL
5.7.42 for the source, native reference and external target.
This profile is available in source builds. It is not in beta.3 binaries.

Prepare the source with ROW binlogs, FULL row images, GTID mode ON and enforced
GTID consistency. Use `source.mode: gtid`. Set `source.start.executedGTIDs` to the
full GTID set from the matching snapshot. A 5.7 source cannot use file-position
capture. Offline replay uses the same profile and does not connect to the source.

Prepare a dedicated 5.7 target with InnoDB tables, GTID mode ON and GTID
consistency ON. Set `default_storage_engine` and `default_tmp_storage_engine` to
`InnoDB`. Stop native replication on the target and disable automatic restart.
Follow the [installation guide](INSTALL.md) for credentials, connection security
and state storage. Copy the initial data and schemas with an external tool.
Preserve column definitions, defaults, keys and foreign-key constraints.

The applier uses the matching target baseline or saved schemas to supply metadata
that 5.7 binlogs omit. An incorrect baseline can escape checks for omitted fields.
Source transactions can change more than one table. The target uses local GTIDs;
SQLite stores source GTID progress. A target commit and the SQLite checkpoint are
not atomic. After an uncertain result, inspect the evidence and repair the target
before you resolve recovery. Do not assume that automatic retry is safe.

Foreign keys use the same [supported subset](../PLAN/MYSQL57_FOREIGN_KEYS.md) as
the 5.7 → 8.4 InnoDB profile. The applier does not support every native 5.7
foreign-key definition. DDL with an explicit MyISAM engine is rejected.

## Shared lab

The native comparison is **5.7 InnoDB → native replication → 5.7 InnoDB**.
Run the full shared suite or start the demo:

```sh
make lab-test PROFILE=mysql57-to-mysql57-innodb ARGS="--suite all"
make lab-demo PROFILE=mysql57-to-mysql57-innodb ACTION=up
make lab-demo PROFILE=mysql57-to-mysql57-innodb ACTION=start
```

Use the [InnoDB workbook](../PLAN/REVERSE_DEMO_WORKBOOK.md) with this profile in
each command. The external target is 5.7 in this topology. Use `SHOW SLAVE STATUS`
on the native reference. Remove the demo with the same profile and `ACTION=down`.
The shared benchmark accepts `insert` and `multi-table-transaction` workloads.
See the [test lab guide](TEST_LAB.md) for case selection and evidence.
