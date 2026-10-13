# MySQL 5.7 InnoDB → MySQL 5.7 MyISAM

Select `profile: mysql57-to-mysql57-myisam` in the [live](../examples/run.minimal.yaml)
or [replay](../examples/replay.minimal.yaml) configuration. This profile combines
5.7 capture and metadata handling with the existing 5.7 MyISAM target contract.
The lab uses MySQL 5.7.42 for all three servers.

Prepare the source with ROW binlogs, FULL row images, GTID mode ON and enforced
GTID consistency. Use `source.mode: gtid` and seed `source.start.executedGTIDs`
from the matching snapshot. File/position-only capture is not supported for a
5.7 source. Offline replay uses the same profile and never connects to the source.

Prepare a dedicated 5.7 target with MyISAM tables, matching column definitions,
GTID mode OFF_PERMISSIVE, GTID consistency WARN and native replication stopped
with automatic restart disabled. Set `default_storage_engine` and
`default_tmp_storage_engine` to `MyISAM`. Follow the [installation guide](INSTALL.md)
for credentials, TLS and state storage. Initial copying and engine conversion
are external operations. DDL with an explicit InnoDB engine is rejected; the
applier does not rewrite engine clauses. Tables created without an explicit
engine use the target's MyISAM default.

5.7 binlogs omit optional signedness, charset and ENUM/SET label metadata. The
applier uses the matching target baseline or saved schema for these fields and
checks the metadata present in the binlog. A wrong baseline can therefore escape
checks for omitted information; clone schemas consistently before replay.

The MyISAM boundaries remain: one table and one statement per source transaction,
no transactional rollback, and fail-stop handling for uncertain or partial writes.
SQLite keeps the checkpoint and recovery evidence. A target commit does not make
the target and SQLite one atomic transaction. DBA repair can be required.

## Shared lab

The native comparison is **5.7 InnoDB → native replication → 5.7 MyISAM**.
Run the same catalog with the new profile:

```sh
make correctness PROFILE=mysql57-to-mysql57-myisam
make lab-demo PROFILE=mysql57-to-mysql57-myisam ACTION=up
make lab-demo PROFILE=mysql57-to-mysql57-myisam ACTION=start
```

The [MyISAM demo workbook](../PLAN/DEMO_WORKBOOK.md) also applies. Use this profile
in each terminal; on the native server use `SHOW SLAVE STATUS`, `STOP SLAVE` and
`START SLAVE`. Stop and remove the demo with the same profile and `ACTION=down`.
The shared backlog benchmark accepts this profile with `--workload insert`.
See the [test lab guide](TEST_LAB.md) for selection, exclusions and evidence.
