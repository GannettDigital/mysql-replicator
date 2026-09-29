# GTID qualification — 2026-09-29

## Required configuration

The source remains GTID-enabled for the intended cloud deployments. The requested POC settings are now the Compose and harness defaults:

| Server | gtid_mode | enforce_gtid_consistency |
| --- | --- | --- |
| 8.4 InnoDB source | ON | ON |
| 8.4 native MyISAM reference | OFF_PERMISSIVE | WARN |
| 5.7 future Swift MyISAM target | OFF_PERMISSIVE | WARN |

The native channel uses `SOURCE_AUTO_POSITION=1`. The harness verifies effective settings, captures the source snapshot GTID set after seeding, checks application rows, and appends that exact set to the fresh native target's `gtid_purged` before starting the workload. This excludes already-provisioned fixture setup, including source account setup, while preserving the target's own setup history. It is limited to this disposable, quiesced fixture and is not a general fleet bootstrap implementation. No failing workload GTID is skipped, purged or replaced.

MySQL's [mode compatibility table](https://dev.mysql.com/doc/refman/8.4/en/replication-mode-change-online-concepts.html) permits source ON with replica OFF_PERMISSIVE, ON_PERMISSIVE or ON. OFF_PERMISSIVE accepts received GTIDs while new local transactions normally remain anonymous. `enforce_gtid_consistency=WARN` allows consistency violations with warnings where the check applies; it does not suppress arbitrary replica SQL errors. See [GTID system variables](https://dev.mysql.com/doc/refman/8.4/en/replication-options-gtids.html).

## Actual local results

All cases below used source ON/ON, MySQL 8.4.8, row/full binlogging and native GTID auto-positioning. The future Swift target was MySQL 5.7.42 with its seed data unchanged. No Swift applier ran.

| Native engine | Native GTID mode / consistency | Result | Run ID |
| --- | --- | --- | --- |
| MyISAM | OFF_PERMISSIVE / ON | Apply stopped, error 1837 | `20260929T191340Z-2e92e800` |
| MyISAM | ON_PERMISSIVE / ON | Apply stopped, error 1837 | `20260929T192535Z-be292cd8` |
| MyISAM | OFF_PERMISSIVE / WARN | Apply stopped, error 1837; IO error 0, auto-position 1 | `20260929T193023Z-ed3e923e` |
| InnoDB control | OFF_PERMISSIVE / WARN | Passed exact rows, workload GTID coverage, engine and rollback-probe checks; IO/SQL errors 0, auto-position 1 | `20260929T193107Z-3d190873` |

A final rerun (`20260929T193413Z-f9e7d478`) explicitly prefixed every fixture target client call with `SET @@SESSION.GTID_NEXT = 'AUTOMATIC';`. The required OFF_PERMISSIVE/WARN MyISAM case again failed with SQL error 1837, IO error 0 and auto-position 1. Raw-binlog capture and cleanup passed. This confirms that resetting a separate client session does not repair the native applier session.

Each run's configuration, status, rows, raw binlogs/checksums and container logs are retained under ignored `artifacts/native-smoke/<run-id>/`. All five runs cleaned up their containers and volumes. The initial two permissive-mode experiments captured vertical status without column labels, leaving extracted error fields null in their JSON; error 1837 is present in their container logs. The requested-configuration run, InnoDB control and final rerun use labeled status and explicit assertions for diagnostic fields. Saved raw-file digests were verified. Tests ran in a temporary staging checkout before installation into this repository.

In the requested MyISAM configuration, the first insert of the multi-statement source transaction survives, while the update and delete do not run. The native server already lists that transaction's source GTID in `gtid_executed`; the second source transaction remains unapplied. Therefore a GTID-set check alone can incorrectly suggest progress. The harness checks coordinates, SQL errors and exact data as well, returns nonzero, and retains failed-run evidence.

The successful InnoDB control confirms the requested GTID configuration and auto-positioning work for that engine pairing. It does not satisfy the required MyISAM reference gate. The failure is consistent with MySQL's documented [GTID restrictions for transactional/nontransactional engine differences](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-restrictions.html); this experiment does not claim a complete internal root-cause analysis or establish that every MyISAM workload fails.

## Reproduce

```sh
# Required MyISAM case: currently fails with native SQL error 1837.
make native-smoke

# GTID configuration control: expected to pass; not a MyISAM substitute.
swift run replicator-lab native-smoke --native-engine InnoDB

# Coordinate positioning with the same GTID ON source and permissive targets.
swift run replicator-lab native-smoke --positioning file-position
```

The original mode/enforcement experiments were explicit Python-harness overrides; their evidence is retained. The replacement Swift runner fixes the accepted settings. Invalid native ON/WARN and anonymous-source auto-position requests are rejected before starting containers. Python syntax and Compose configuration checks passed. No Swift/Rust code changed, so the bootstrap build was not rerun.

## Implementation consequences

Keep source GTIDs ON and target OFF_PERMISSIVE/WARN as the design contract. The user has accepted the native-failing multi-statement case as an expected negative reference: Swift may also stop on the corresponding case in the initial implementation. Preserve source GTIDs and the real native error. Phase 1 must qualify the expected result rather than make native succeed. See [the accepted contract](NATIVE_REFERENCE_CONTRACT.md).

Swift should use source GTIDs as durable transaction identities in SQLite and resume capture only from complete durable source transactions. Every new/reconnected Swift SQL session must execute `SET @@SESSION.GTID_NEXT = 'AUTOMATIC';` before applying data. The fixture explicitly initializes each target client session this way. This does not change the separate native applier session, which assigns GTID_NEXT from source GTID events. A native replication error cannot be repaired by issuing this command from another client. Target SQL uses its own automatic transaction identities; with OFF_PERMISSIVE these are normally anonymous. Do not force one source GTID onto multiple MyISAM statement commits, and do not infer a fully applied source transaction from target `gtid_executed`. The remaining apply/recovery gates must prove complete row effects, correct stop behavior, and safe repair/resume under the requested settings. Native restrictions do not by themselves establish whether the external Swift design will pass those gates.

## File/position follow-up

The subsequent [positional investigation](POSITIONAL_GTID_RESEARCH.md) tests exact offsets with no gtid_purged bootstrap and also initializes GTID_NEXT=AUTOMATIC inside the native SQL thread using init_replica. Both retain source GTID ON and target OFF_PERMISSIVE/WARN and still reproduce error 1837 on the original multi-statement workload. The report includes MySQL documentation, Percona's positioning comparison, and the relevant pinned MySQL source code.

The same positional setup **passed** when the first three DML statements became separate source commits (`--workload autocommit`). This narrows the observed failure to the tested multi-statement transaction shape; it does not establish a blanket MyISAM/GTID incompatibility or qualify all multi-row statements.

## Automation update

The reproduction commands above now use the SwiftPM runner. Historical run IDs and captured paths refer to the original experiments. The current runner fixes source ON/ON and targets OFF_PERMISSIVE/WARN, and `make native-suite` classifies both successful and expected-negative cases. See [Phase 1 progress](PHASE_1_PROGRESS.md).
