# Positional replication with GTID-enabled sources — 2026-09-29

## Question

Can a source keep GTIDs ON while a native MyISAM replica uses OFF_PERMISSIVE/WARN, starts at the actual binlog file/offset, and resets GTID_NEXT to AUTOMATIC so that incoming GTIDs no longer affect application?

The file/offset part is supported. It does not make incoming GTID events anonymous or stop the native applier assigning their GTIDs. The tests below separate connection positioning, applier session initialization and source transaction boundaries.

## Documentation and source review

- [MySQL 8.4 CHANGE REPLICATION SOURCE TO](https://dev.mysql.com/doc/refman/8.4/en/change-replication-source-to.html): `SOURCE_AUTO_POSITION=0` uses file/position coordinates. Auto-positioning selects which transactions to request during connection setup.
- [MySQL 8.4 GTID lifecycle](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-lifecycle.html): the native applier reads a received GTID and assigns it to its own session's GTID_NEXT before application. A previously issued client-session reset does not override that event.
- [MySQL 8.4 init_replica](https://dev.mysql.com/doc/refman/8.4/en/replication-options-replica.html#sysvar_init_replica): SQL can also run at the actual applier thread's startup. We tested this stronger variant, rather than relying only on a separate administrative client session.
- [Percona: GTIDs benefits and limitations, part 1](https://www.percona.com/blog/replication-in-mysql-5-6-gtids-benefits-and-limitations-part-1/): its experiment distinguishes file-based positioning from GTID-based positioning while GTIDs remain enabled. This is a 2013 MySQL 5.6 article; its all-servers-ON/OFF limitation predates the modern permissive modes and is not the current compatibility rule.
- [MySQL 8.4 mode compatibility](https://dev.mysql.com/doc/refman/8.4/en/replication-mode-change-online-concepts.html) and [GTID restrictions](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-restrictions.html) distinguish allowed mode combinations from transactional/nontransactional engine restrictions. OFF_PERMISSIVE accepts received GTIDs; WARN does not disable all native replication error checks.

The inspected 8.4.8 server commit is `0896fcd61dec11a0904166911a0126f59daaa1bf`, matching the research pin. In [`Gtid_log_event::do_apply_event`](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/sql/log_event.cc#L13380), handling the event calls `set_gtid_next(thd, spec)` without an auto-positioning-only condition. In [`gtid_pre_statement_checks`](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/sql/rpl_gtid_execution.cc#L504), an undefined consumed GTID causes rejection of a subsequent statement; the nearby explanation specifically discusses transactional source tables and nontransactional replica tables. This corroborates the observed failure class; we did not instrument every internal commit path.

## Experiments

All tests use the existing pinned 8.4.8 source/native and 5.7.42 future Swift target. Source GTID mode/consistency is ON/ON; both targets use OFF_PERMISSIVE/WARN; ROW/FULL and CRC32 remain configured. Every administrative target client session explicitly initializes GTID_NEXT=AUTOMATIC. Native replicated changes remain binlogged, and native error skipping remains disabled.

The positional bootstrap starts at the recorded post-seed source file/offset and does **not** set gtid_purged. Thus these results do not depend on the auto-positioning seed-GTID handoff.

1. **Exact file/position, original multi-statement transaction:** `20260929T194629Z-e0b51c4d`. Source boundary was `binlog.000003:1593`; source workload ended at offset 2474. Native status reports Auto_Position=0, receiver offset 2474 and applied group offset 1593. IO error is 0; SQL error is 1837. The first insert survives, while the later update/delete do not apply. Native gtid_executed contains the first workload GTID even though the source transaction is only partially applied.
2. **Same positional test, reset inside the actual applier thread:** `20260929T194843Z-761429b9`. Before START REPLICA, the harness sets `init_replica` to `SET @@SESSION.GTID_NEXT = 'AUTOMATIC'` and verifies the configured initializer. Auto_Position=0; IO error 0; SQL error 1837. Receiver reaches 2472 while the applied group boundary remains 1591. Initialization of the native thread does not prevent the next received GTID event from assigning an explicit GTID.

3. **Same DML with separate source commits:** `20260929T194926Z-d55e93a1`. With the source still ON/ON and targets OFF_PERMISSIVE/WARN, file/position replication into MyISAM passed. Auto_Position=0, SQL/IO errors are 0, exact source/native rows match, and all four committed workload GTIDs are present on the native replica. Both MyISAM rollback probes passed and the 5.7 application table stayed at its seed. The manifest records four separate committed transactions instead of grouping the first three DML operations into one transaction. Each tested DML statement affects one row; broader multi-row and mixed-engine cases are not established by this control.

All three runs retained checksummed raw binlogs and cleaned up their isolated containers/volumes. Saved digests were verified. Python syntax and Compose configuration validation passed. The direct offset case ran in the repository; the two added controls ran in staging before installation. No Swift/Rust code changed.

Both failed cases preserve raw binlogs, settings, errors and partial row readback. Cleanup passed. The existing successful InnoDB control remains relevant but does not establish MyISAM correctness.

## Reproduction

```sh
# Actual file/offset, no gtid_purged bootstrap; original transaction.
python3 tests/harness/native_smoke.py --positioning file-position

# Reset GTID_NEXT inside the native SQL thread before it reads events.
python3 tests/harness/native_smoke.py --positioning file-position --native-init-automatic

# Diagnostic control: change the first three DML statements into separate commits.
python3 tests/harness/native_smoke.py --positioning file-position --workload autocommit
```

The autocommit control deliberately changes source transaction boundaries and adjusts the expected-operation manifest. It is not a proposed rewrite of production source traffic. The autocommit control passed, establishing a useful restricted MyISAM reference case. The user subsequently accepted the original multi-statement failure as an expected negative reference: Swift may also reject the corresponding case. Keep both positive and negative scenarios, according to the [initial compatibility contract](NATIVE_REFERENCE_CONTRACT.md).

## Implication for the direct Swift replicator

Keep cloud-compatible source GTIDs ON and retain the requested target settings. An external Swift consumer can track received GTIDs and file/offsets in SQLite while issuing target SQL through its own AUTOMATIC session. Native replication instead processes the GTID events itself. Positional startup alone does not remove this distinction. Safe complete-transaction checkpoints, MyISAM partial effects, target binlogs and repair/resume still need their planned tests; this investigation neither establishes Swift correctness nor completes Phase 1.
