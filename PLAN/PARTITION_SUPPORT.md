# Partition and subpartition support

Status: branches 37 through 40 passed selected integration checks. They add
subpartitions, KEY algorithms, maintenance, evaluated bounds, unchecked
exchange, and exact binary/charset COLUMNS bounds. See the results below.
These increments do not complete all partition operations.

## Implementation

`MySQLSyntax.SQLPartitionClause` parses partition methods, counts, definitions,
subpartitions and physical options. It does not select an engine or a server
version. The applier checks those rules and retains the original SQL.

The saved schema keeps each parent partition and its ordered subpartitions.
Each subpartition has a name, method and expression. Existing saved schemas
without the optional subpartition field still decode. No SQLite schema migration
is required. Discovery reads `information_schema.PARTITIONS` in native ordinal
order and groups its rows by parent partition.

This increment adds:

- RANGE/LIST subpartitioning by HASH, LINEAR HASH, KEY or LINEAR KEY.
- Explicit subpartition names and native default names such as `p0sp0`.
- Subpartition metadata through CREATE LIKE, ADD, DROP and REORGANIZE.
- TRUNCATE of selected subpartitions and EXCHANGE of one subpartition.
- Named HASH/KEY partitions, ADD PARTITION PARTITIONS, and implicit KEY columns.
- Partition-level engine checks against the selected target engine. The old
  parser accepted only MyISAM in this clause.
- Parsed partition comments and physical options. The target executes these
  options; they are not part of the saved row schema.

The parser and schema model limit the total number of leaf partitions to 8192.
They check names and consistent subpartition counts. Native MySQL still checks
partition bounds, permitted functions, unique-key dependencies and engine limits.
There is no engine substitution.

## Native references

The local 5.7 and 8.4 sources provide the reference behavior:

- `sql/sql_yacc.yy` in 5.7: `opt_sub_part`, `opt_num_subparts`, `part_defs`, and
  the partition option productions.
- `sql/partition_info.cc` in both versions:
  `create_default_subpartition_name` uses the parent name plus `sp` and the
  zero-based subpartition number.
- `sql/sql_partition_admin.cc` in 5.7: EXCHANGE requires a leaf partition.
  A subpartition is a valid leaf; its parent is not.

A direct 5.7.42 probe confirmed generated names, REORGANIZE, subpartition
TRUNCATE and EXCHANGE, ADD PARTITION PARTITIONS, and empty metadata expression
for implicit KEY columns. Source and target must still support the selected
engine and partition form.

## Tests

- `SQLPartitionClauseTests`: typed methods and options, nested definitions,
  malformed input, incomplete input and count limits.
- `PartitionCompatibilityTests`: native names, engine policy, saved JSON,
  legacy JSON, ADD/DROP/REORGANIZE, TRUNCATE/EXCHANGE and invalid manifests.
- `ddl-compat-subpartitions`: row effects after TRUNCATE, EXCHANGE, DROP,
  REORGANIZE and ADD; CREATE LIKE; repartitioning; saved-state restart; offline
  replay that stops after TRUNCATE and resumes with an unreachable source.
- `ddl-compat-partition-hash-forms`: named HASH partitions, ADD counts,
  COALESCE, implicit KEY columns, named ADD and restart.
- Existing `ddl-compat-partitions` and `ddl-compat-hash-list` remain regression
  cases. The ignored-CHECK case checks the shared offline replay helper.

The initial affected unit run passed 470 tests. After the native metadata and
syntax corrections, 25 focused apply, syntax and catalog tests passed. The
independent syntax target passed 29 tests with 818/824 executable lines covered
(99.27%). Periphery found no unused code after the correction.
See the final integration results below.

## Remaining partition work

- Remaining native partition expression and constant-bound forms.
- Tablespace import/export operations.
- Further misplaced-row cases beyond the tested native UPDATE/DELETE errors.
  Do not treat invalid partition placement as an ordinary DML guarantee.
- Full bootstrap, error and interrupted-DDL qualification. The normal DDL
  journal records the complete before/after schema. This work does not add
  automatic repair for an uncertain DDL result.

### Native metadata difference found during the first run

Run `20261015T155740Z-0174762d` reached BLOCKED on the 8.4 target after
`ALTER TABLE ddlcompat.t PARTITION BY KEY() PARTITIONS 2`.
The automatic support bundle records an acknowledged statement and a pending
DDL intent. The current saved schema still describes the preceding LINEAR HASH
partitions. The checkpoint did not pass the failed DDL.

Direct probes confirmed that 5.7 returns an empty string for the implicit KEY
expression, while 8.4 returns SQL NULL. Both mean that KEY uses the implicit key
columns. Discovery must accept either representation for KEY methods. Missing
expressions for other methods must remain errors.

The 5.7 grammar and a direct probe also confirmed that repeated partition
options use the last value. Subpartition names and engine names can use string
literals. Parent partition names still require identifiers. These syntax forms
have focused regression coverage. The corrected HASH/KEY integration case also
uses repeated comments and quoted engine names.

The first outer result recorded 15 passed cases, one failed case, three cases
not run after that failure, and one inapplicable CHECK case. All four profiles
passed `ddl-compat-subpartitions`, including offline stop/resume. Its input
digest was `c9beb3ac5215c5fc202eccae978b2269f8ce0cc740aca5dc58963c5a70e217af`.
The failed run and its support bundle remain intact.

## Final integration results

Run `20261015T161915Z-0bc77dd1` passed the corrected
`ddl-compat-partition-hash-forms` case on all four profiles. This includes the
8.4 NULL representation for implicit KEY columns, repeated options, and quoted
engine names on the InnoDB targets.

Run `20261015T162141Z-c6d0b319` passed the three 5.7 to 8.4 cases that the first
failure prevented from running: `ddl-compat-ignored-checks`,
`ddl-compat-partitions`, and `ddl-compat-hash-list`.

Both final outer results are `passed`, with no build-input error. They used
input digest `eca76748e2c7f2f37261da03ca7da933caeb96c509f29c05490b37060de3eb50`.
The earlier four-profile subpartition and replay results remain evidence for
that workflow. The corrections change implicit-KEY metadata handling and add
accepted syntax; they do not change that workload. The run IDs and input
digests distinguish the two builds. These selected checks do not constitute
full release qualification.

## Branch 38: KEY algorithms and partition maintenance

The optional `keyAlgorithm` schema field stores algorithm 1. An omitted field
means algorithm 2, the native default. Old saved schemas remain readable.
The algorithm affects row placement. A different algorithm can make TRUNCATE
PARTITION remove different rows.
CREATE, repartitioning, CREATE LIKE, ADD and REORGANIZE retain this value.
Discovery reads SHOW CREATE TABLE for KEY tables. The native output stores the
algorithm in a version comment. The metadata lexer expands this comment;
source SQL still cannot use executable comments.

Schema equality now compares ordered subpartitions and KEY algorithms. The
branch 37 equality operator did not compare its new subpartition field. New
unit tests check each child field, child order, and exact identifier bytes.
The earlier integration evidence alone did not detect this omission.

`SQLPartitionMaintenance` parses REBUILD, ANALYZE, CHECK, OPTIMIZE and REPAIR
PARTITION. It checks the full action and its native options. The applier
validates partition names and uses the normal DDL intent and checkpoint path.
ANALYZE, CHECK, OPTIMIZE and REPAIR can return errors in result rows even when
the SQL protocol reports success. The applier requires a successful status
row. An error, missing result, or incomplete result leaves the DDL pending.
Notes and warnings do not replace the required success status.

Local native source references are `sql/sql_yacc.yy`, `sql/partition_info.cc`,
`sql/sql_admin.cc` and `sql/sql_partition_admin.h` in MySQL 5.7. Direct 5.7.42
probes confirmed that REBUILD, ANALYZE, OPTIMIZE and REPAIR PARTITION each add
a GTID. CHECK PARTITION does not add a GTID. LOCAL/NO_WRITE_TO_BINLOG operations
are not replayed from source events. A target engine can return an OPTIMIZE
note followed by a successful result; the applier accepts that native result.

Direct probes on 5.7.42 and 8.4.8 also confirmed the algorithm-1 SHOW CREATE
format and integer-key placement. The live KEY case checks placement before
TRUNCATE, metadata through ALTER and CREATE LIKE, saved-state restart, and
offline replay with an unreachable source. It checks parent and subpartition
algorithm fields in SQLite. The maintenance case checks logged operations,
unlogged CHECK and LOCAL operations, and DML after restart.

The affected unit run passed 478 tests. The independent syntax target passed
31 tests with 897/903 executable lines covered (99.34%). Periphery reported
no unused code.

### Branch 38 integration results

Run `20261015T164911Z-24c49dc0` passed all 12 selected cases: KEY algorithms,
partition maintenance, and the earlier subpartition workflow on all four
profiles. The KEY and subpartition cases include restart and offline
stop/resume. The input digest is
`2694dac133493df9c389ad4b0cdf1c0826d02d9c2a7e04fcfedefe31db8e2be5`.
The final outer result is `passed`, with no build-input error.

Read-only checks of the four maintenance snapshots found four completed
maintenance intents per profile. CHECK and LOCAL operations had no intents.
The check results are saved in
`artifacts/beta6-validation/partition-maintenance-journal.json`.
Three focused support-catalog tests also passed after the requirements update.
These selected cases do not constitute full release qualification.

## Branch 39: evaluated bounds and unchecked exchange

MySQL records the original CREATE/ALTER SQL in its Query event. It evaluates
constant partition bounds for the stored table definition. A local 5.7 probe
confirmed that `TO_DAYS('2026-01-01')` remains in the binlog, while
`information_schema.PARTITIONS` stores `739982`.

The applier now parses bounds with the shared expression syntax. It permits
constant arithmetic and native date/numeric functions, including TO_DAYS,
TO_SECONDS, EXTRACT, ABS, FLOOR and CEILING. The target evaluates expressions
before the DDL intent is saved. The applier restores the source SQL mode and
time zone for this query. Internal query text uses UTF-8 with escaped literals.
The execution path restores the original source client settings before DDL.

The result becomes the predicted partition description. The original DDL is
still executed, and discovery checks the stored result. This does not replace
MySQL's checks on valid partition methods, bounds, column types or functions.
Ordinary literal bounds need no SELECT. MAXVALUE and NULL remain distinct.
The saved schema format does not change. There is no new DML lookup query.

The preparation query cannot refer to columns, variables, subqueries or
stored functions. Its function list contains constant numeric/date functions
from the native partition rules. Other bound forms remain an implementation
gap until they have native evaluation and metadata checks. Binary/charset
literal bounds and the complete native column-conversion matrix still need
qualification. Do not treat selected expression tests as complete coverage.

The syntax target also accepts DATE, TIME and TIMESTAMP string literals. This
is why this increment runs the independent syntax tests.

### EXCHANGE WITHOUT VALIDATION

The parser accepts the default, WITH VALIDATION and WITHOUT VALIDATION forms.
It retains the original SQL. Native MySQL still checks the table definitions.
The applier checks both table schemas and filter membership before execution.
Both tables remain in the durable DDL transition record.

WITHOUT VALIDATION can place a row outside its partition bounds. A local 5.7
probe placed key 20 in a partition whose upper bound was 10. An explicit
partition scan found that row. `WHERE id=20` did not find it because MySQL
selected another partition. The applier does not move or repair these rows.
The live case checks this state, then exchanges the rows back before DML.
Direct DML against misplaced rows still needs a native replication comparison.

An exchange is not idempotent: a second exchange swaps the rows back. A unit
test injects a SQLite checkpoint failure and verifies that both table records
remain pending. Restart and row-recovery commands refuse that unresolved DDL.
Schema equality alone cannot establish whether the exchange ran. This work
does not add automatic recovery for an uncertain exchange.

### Native references and selected cases

- MySQL 5.7 `sql/partition_info.cc`, `add_column_list_value`: permitted
  partition functions and constant-item checks.
- MySQL 5.7 `sql/item_func.h` and `sql/item_timefunc.h`:
  `check_partition_func_processor` and the permitted arithmetic/date functions.
- MySQL 5.7 `sql/sql_partition_admin.cc`, `exchange_partition`: table checks
  remain active; ALTER_WITHOUT_VALIDATION bypasses only the row-range check.
- MySQL 5.7 `mysql-test/suite/parts/inc/part_exch_valid_range.inc`: native
  unchecked exchanges and misplaced rows.
- `ddl-compat-partition-expressions`: RANGE/LIST computed bounds, typed DATE
  and arithmetic RANGE COLUMNS bounds, ADD/REORGANIZE, HASH EXTRACT, following
  DML, saved-state restart and offline stop/resume.
- `ddl-compat-partition-exchange-unchecked`: misplaced-row observations, an
  exchange back, valid-row exchange, following DML, both journal transitions,
  restart and offline replay that stops immediately after the first exchange.

### Initial branch 39 verification

The affected unit run passed 483 tests. The independent syntax target covered
903/909 executable lines (99.34%). Periphery reported no unused code.

Run `20261015T182249Z-9d29e84e` passed both new cases on the two 5.7 to 5.7
profiles, including offline stop/resume. Both cross-version profiles stopped
at the first CREATE because the harness compared native expression spelling
literally. MySQL 5.7 returned `TO_DAYS(d)`; 8.4 returned ``to_days(`d`)``.
The saved DDL intent was DONE and the saved bound was `739982` on both targets.
The failure occurred outside the applier, so no BLOCKED bundle was generated.
The original comparison files and SQLite state remain intact.

The harness now normalizes only the TO_DAYS and EXTRACT forms observed in
these fixtures. It does not use the production expression renderer. Tests
verify that it still detects differences in column names, grouping, literals
and bounds. Eight focused comparison and catalog tests passed after this fix.
Only harness comparison code changed. The syntax tests were not repeated.

The initial run used input digest `1ab7baffa3a885abbb023e9c39d05e0527210c70414da9fe2f89fd5dd47910d7`.
A native 5.7 probe accepted `FLOOR(10.5)` as an integer bound but rejected
`FLOOR(1e1)` with error 1697 (the bound must have type INT). General native
column coercion remains a separate test obligation.

### Final branch 39 results

The corrected cross-version runs passed both new cases:

- 8.4 to 5.7 MyISAM: `20261015T183927Z-d8f89a5f`.
- 5.7 to 8.4 InnoDB: `20261015T184228Z-5072afa3`.

Both outer results are `passed`. They used input digest
`a81a009937ac59f1f46057fd37a15d9d418279c33cf65fbb653964a1754cd274`.
Together with the four same-version cases from the initial run, this gives
passing results for both workflows on all four profiles. The applier code is
identical across these runs. The final change only corrects the harness
comparison and adds its unit test.

Read-only SQLite checks found three completed unchecked-exchange intents per
profile. Each intent retains both table transitions. These checks are saved
in `artifacts/beta6-validation/partition-exchange-journal.json`.
The final Periphery check passed. No additional syntax run was needed after
the harness-only correction. These selected results do not replace full
release qualification.

## Increment 40: binary and charset column bounds

Branch: `beta/6/40-partition-column-bounds`.

RANGE/LIST COLUMNS bounds now accept byte literals and charset introducers.
The saved schema uses hex literals for binary bounds. It retains decoded text
for character bounds. Connection-charset bytes remain available during DDL
planning. This includes an empty byte string and bytes that are not valid UTF-8.

MySQL 5.7 can truncate a binary bound in `INFORMATION_SCHEMA.PARTITIONS` at the
first invalid UTF-8 byte. MySQL 8.4 can return `_binary 0x…` for the same bound.
Schema discovery now reads raw `SHOW CREATE TABLE` output for COLUMNS bounds.
It restores the result charset before it returns. The independent harness
parser also compares exact bytes for its single binary-column fixtures.
Neither path treats two truncated descriptions as evidence of equal bounds.

### Native conversions

MySQL validates a COLUMNS bound through the declared field. It checks result
types and rejects field conversions that produce a warning. However, its
metadata retains the constant's value, not a padded or normalized field value.
For example, a DATE bound written as `'20260101'` retains that spelling. A CHAR
bound can retain trailing spaces. Do not replace these values with values read
from a temporary column: that can change the schema comparison.

Native 5.7 checks confirmed these cases:

- An INT COLUMNS bound of `10.5` fails with error 1654.
- A DATE COLUMNS bound of `'20260101'` is accepted and retains that spelling.
- A latin1 bound `_latin1 X'E9'` displays as `é`.
- A binary bound `X'80FF'` can appear as only a quote in I_S. Raw SHOW CREATE
  retains the bytes. The 8.4 form uses a binary charset introducer and hex.

The target still executes the original DDL. Native type, range, charset and
partition-order checks remain active. The applier does not round bounds or
substitute invalid bytes.

References in the local 5.7 source:

- `sql/partition_info.cc`: `get_column_item` and
  `fix_column_value_functions`.
- `sql/sql_partition.cc`: `add_column_list_values`.
- `sql/sql_show.cc`: `get_partition_column_description` and
  `get_cs_converted_string_value`.
- `sql/table.cc`: `append_unescaped`.

### DML on misplaced rows

Direct probes on 5.7.42 and 8.4.8 used a row with `id=20` in a partition whose
bound is `id < 10`. After EXCHANGE WITHOUT VALIDATION:

- A primary-key predicate for `id=20` did not find the misplaced row.
- On 5.7, an explicit partition scan UPDATE failed with error 1748.
- Full-scan UPDATE and DELETE failed with error 1863 on both versions.
- The 5.7 GTID set did not advance across these failed statements. The 8.4
  probe did not have GTID enabled, so it gives no GTID evidence.

These probes establish native source restrictions. They do not qualify every
row-event lookup strategy or every damaged-table state. The applier does not
move misplaced rows or repair an uncertain exchange. Restore valid placement
before normal DML. The existing unchecked-exchange workflow checks this path
by exchanging the rows back before DML.

Probe output is in `artifacts/beta6-validation/misplaced-row-native.json`.

### Verification

The new `ddl-compat-partition-column-bounds` case checks binary RANGE bounds,
REORGANIZE, movement across partitions, latin1 LIST bounds, DATE tuple routing,
connection-charset literals, escaped and empty bytes, restart and offline replay.
The harness compares native rows and schema after each statement.

An initial same-version run passed. The first reverse-profile run,
`20261015T192624Z-d4e43bd6`, found the 8.4 `_binary` metadata mismatch. Its
support bundle shows an acknowledged CREATE and a pending DDL record. The
checkpoint did not pass that DDL. The original bundle remains unchanged.
Unit tests now cover both native spellings. Final run results follow below.

The next cross-version runs reached the connection-charset case and found a
result-encoding mismatch. The saved intent contained `C3A9`; the native binary
bound was `E9`. Runs `20261015T193524Z-b31f1200` and
`20261015T193709Z-72cc5c58` retain those support bundles. The fix requests a
binary result for binary columns. It does not change the source DDL.

The lexer also retains input bytes for an explicit charset introducer. Native
5.7 returns `E9` for an ordinary `é` literal with a latin1 connection, but it
returns `C3A9` for `_latin1 'é'` sent by a UTF-8 client. The final fixture checks
both bounds. A quoted `*/` in SHOW CREATE is part of a value; it must not end
the metadata comment. The final fixture checks those bytes too.

The final affected unit run passed 494 tests. The independent syntax target
covered 922/928 executable lines (99.35%).

### Final branch 40 results

Both selected workflows passed on all four profiles. Each run includes live
DDL/DML, saved-state restart, and offline replay with stop/resume.

| Profile | Run | Cases |
| --- | --- | --- |
| mysql57-to-mysql84-innodb | `20261015T194847Z-ec4ac727` | 2 passed |
| mysql84-to-mysql57-myisam | `20261015T195028Z-158d5118` | 2 passed |
| mysql57-to-mysql57-myisam | `20261015T195342Z-dc2f29d8` | 2 passed |
| mysql57-to-mysql57-innodb | `20261015T195351Z-183c7693` | 2 passed |

All four outer results are `passed`. They used the same input digest:
`d4cb5ade718a4e941ff321739b2591a5f70f9d9f2d5a8bf95ac47c5c378fae45`.

Read-only checks of the four saved SQLite snapshots confirmed exact binary
bounds, distinct `E9` and `C3A9` literals, the empty bound, the quoted comment
delimiter, and the original DATE spelling. No DDL intent remained pending.
The checks are saved in
`artifacts/beta6-validation/partition-column-bounds-state.json`.

The final Periphery check passed. Three support-catalog tests also passed.
These selected results do not replace full release qualification. Remaining
partition forms and the broader failure matrix stay open in the catalog.

## Column renames with repartitioning

Branch 67 supports a rename when the same ALTER replaces or removes partitioning.
It also accepts the native trailing PARTITION BY/REMOVE PARTITIONING syntax.
An unchanged partition or subpartition expression still blocks a dependent
rename or drop. Implicit KEY() follows the primary key. See
[the implementation and tests](PARTITION_COLUMN_RENAMES.md).
