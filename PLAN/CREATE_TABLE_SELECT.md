# CREATE TABLE SELECT: native contract

Branch: `beta/6/41-create-select-contract`, based on branch 40.

Scope: the four current profiles, ROW binlogs and GTID consistency. These
restrictions also apply when capture starts from a file position.

## Permanent tables

MySQL 5.7 rejects logged, non-temporary `CREATE TABLE ... SELECT` with error
1786 when `enforce_gtid_consistency=ON`. It creates no table and commits no
GTID for that statement. The applier has no source change to apply.

MySQL 8.4 permits this operation with InnoDB. A probe on 8.4.8 records one
GTID with this sequence:

```text
GTID
BEGIN
CREATE TABLE ... (generated column and index definitions) START TRANSACTION
TABLE_MAP
WRITE_ROWS
XID
```

The generated query does not contain the SELECT. The row events contain its
result. If the source statement omits ENGINE, the generated query also omits
ENGINE. An explicit engine is a separate case. Do not assume that generated
CTAS always specifies InnoDB.

The `START TRANSACTION` clause makes the CREATE part of the atomic DDL group.
MySQL 5.7 rejects this syntax with error 1064. MySQL 8.4 rejects the clause
with error 3979 when its selected engine does not support atomic DDL. This
includes MyISAM. Thus, an 8.4 native replica with default MyISAM cannot apply
the default-engine CTAS group either.

Do not remove this clause and split the group into a permanent CREATE and row
writes. That would change the atomicity contract. The forward profile cannot
preserve this source operation. The support catalog classifies it as a target
limit, not a missing positive feature for that profile.

Capture currently rejects the query inside the row transaction. It emits no
complete apply group. The checkpoint stays before the CTAS. No DDL or row
intent reaches the target write path. The saved state is BLOCKED. A normal
restart refuses this state and requires explicit resolution.

A future 8.4-to-8.4 InnoDB profile would need an implementation for combined
DDL and row groups. That work would include the durable journal and restart
contract. The current rejection is not a claim that atomic CTAS is impossible
on all target versions or engines.

## Temporary tables

ROW logging omits temporary-table creation and local row changes. Permanent
row effects from `INSERT ... SELECT` or a joined UPDATE are still replicated.
MySQL 5.7 can also log temporary-table cleanup. The existing cleanup policy
handles those events without dropping a permanent target table.

The shared `ddl-compat-temporary-create-select` case checks populated and
empty temporary CTAS, temporary row changes, permanent inserts and updates,
following DELETE, clean restart and offline replay. Replay uses an unreachable
source. Target and native schemas and rows must match.

The separate `create-select-contract` case checks permanent-table restrictions.
For 5.7 sources, it checks source error 1786, no new object or GTID, and a
successful following row group. For the 8.4 source, it records the generated
binlog events, checks native MyISAM error 3979 and target 5.7 error 1064, and
checks the unchanged target, journal and checkpoint after capture failure and
a refused restart.

## Native source references

- 5.7 and 8.4 `sql/binlog.cc`: `THD::is_ddl_gtid_compatible`.
- 8.4 `sql/sql_insert.cc`: `Query_result_create::binlog_show_create_table`.
- 8.4 `sql/sql_show.cc`: `store_create_info`, including the atomic-DDL clause.
- 8.4 `sql/sql_table.cc`: `ER_NOT_ALLOWED_WITH_START_TRANSACTION`.
- 5.7 `sql/sql_yacc.yy`: `create2` and table options.

The local upstream trees and pinned fixture versions are the reference.
Selected test results do not replace full release qualification.

## Verification

Both selected cases passed on each profile:

| Profile | Lab run |
| --- | --- |
| 5.7 → 8.4 InnoDB | `20261015T213054Z-807707ff` |
| 8.4 → 5.7 MyISAM | `20261015T213608Z-7e1d6507` |
| 5.7 → 5.7 MyISAM | `20261015T213741Z-2c44d2e1` |
| 5.7 → 5.7 InnoDB | `20261015T213924Z-f9f8cc17` |

The final build-input digest is
`8749359d46f457103243eb8e154831c25dd10fb400d76f5469498355100559a6`.
The reverse run used `f5f220b88e7ebfc8218bc6088482ce209f4e23b4dd8b716400af058001320227`.
The difference is a harness fix: the direct target syntax probe now uses the
target version's session settings. The 5.7-source branch of this case only
probes the source. No replication code changed.

The first forward run, `20261015T205258Z-d3b3c390`, failed at that direct
probe because it sent an 8.4 session variable to 5.7. Its evidence remains in
place. This was a fixture error, before the intended CTAS capture failure.

All 101 lab unit tests passed. Syntax tests were not run because syntax code
did not change. The successful forward run produced an automatic support
bundle for the expected capture failure. A read-only SQLite check confirmed
BLOCKED state, zero applied transactions, the prior GTID set and zero DDL or
row intents. The saved event listing confirms the atomic source sequence.

To run the two cases on all profiles:

```sh
swift run replicator-lab test --profile all --suite correctness \
  --case ddl-compat-temporary-create-select --case create-select-contract
```
