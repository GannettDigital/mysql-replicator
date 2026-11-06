# Testing replication by profile

Use `swift run replicator-lab --help` to list commands. Each command and demo
action has its own `--help`. Help does not start containers. See
[command help](COMMAND_LINE.md#test-lab-commands).

Use `--dml-transport binlog` to run selected correctness, lifecycle, or performance
cases through the opt-in BINLOG path. The default is `sql`. Profiles and case
selection stay the same. The report records `dml_transport`. Read the
[BINLOG transport limits](BINLOG_TRANSPORT.md) before selecting cases.

Full CI adds selected BINLOG jobs for each profile. Their names include
`binlog-rows-json-replay`, `binlog-gtids-disabled`, `binlog-reconnect`, or
`binlog-replication-backlog-10k`.
The exact case lists are in `tools/ci_matrix.json` under `binlog_selections`.
These jobs use the coverage binary and supplement the SQL transport checks.
PR selection stays unchanged. The full plan fits the GitHub matrix limit.
See [release testing](RELEASE_TESTING.md) for production package checks.
Use `--variant without-source-gtids --case positive` to check basic DML without
target GTID preservation. Add `--case ddl-compat-generated` to check SQL selection
for generated columns. SQLite still tracks source GTIDs in that variant.
The BINLOG correctness selections also include SQL compatibility cases. The
`sql_transport_groups` SQLite table records why a transaction used SQL.

Shared fixtures enable automatic support bundles when the applier enters
`BLOCKED`. They use `format: directory` so you can read the files without extraction.
After a test, look in its `support-bundles/` artifact directory. Start with
`failure.json`, then check `state.sqlite`, `relay.frames`, and `bundle.json`.
The rejection tests check that the bundle preserves the failure and the blocked
checkpoint. A test failure outside the applier does not cause a support bundle.

The lab runs shared experiments against a source, an external-applier target,
and a native reference. A profile identifies the topology and replication
contract; it does not mean every feature of those MySQL versions is supported.

| Profile | Source | External target | Native reference |
| --- | --- | --- | --- |
| `mysql84-to-mysql57-myisam` | 8.4 InnoDB | 5.7 MyISAM | 8.4 MyISAM |
| `mysql57-to-mysql84-innodb` | 5.7 InnoDB | 8.4 InnoDB | 5.7 InnoDB |
| `mysql57-to-mysql57-myisam` | 5.7 InnoDB | 5.7 MyISAM | 5.7 MyISAM |
| `mysql57-to-mysql57-innodb` | 5.7 InnoDB | 5.7 InnoDB | 5.7 InnoDB |

Partition experiments explicitly use an InnoDB native reference on all profiles
to preserve the same fixture; 8.4 cannot create the corresponding MyISAM table. Both MyISAM temporary-table LIKE cases
also declare a MyISAM source template explicitly. These exceptions are checked
before metadata comparison. The actual servers, settings, image IDs,
and applier binary hash are recorded. The native reference is a behavior/control
comparison; its version matches the source. In the 5.7 → 5.7 profiles, all three servers use 5.7.

Test SQL uses file-backed standard input. This preserves UTF-8 bytes on macOS,
where process arguments can change composed Unicode characters. The mysql client
uses one delimiter for each request, including stored routine bodies.

The `matrix-exactchoices` and `matrix-choiceboundaries` cases check ENUM/SET
labels, defaults and ordinal writes. `metadata-labels-defaults` reads the same
metadata from existing tables. These cases include latin1, UTF16, UTF16LE,
UTF32, GB18030 and supplementary UTF-8.

The `metadata` family contains three focused cases:

| Case | Checks |
|---|---|
| `metadata-columns-indexes` | Read existing columns and indexes. Compare saved types, nullability, names, key order, index parts and generated expressions with MySQL metadata. Check numeric defaults and AUTO_INCREMENT. |
| `metadata-labels-defaults` | Read character sets, collations, ENUM/SET labels and stored defaults. Check exact label bytes, label order, default ordinals, binary padding, NUL and text defaults. |
| `metadata-cache-ddl` | Read a table once. Reuse its cache entry for a second write without more metadata queries. Refresh it after ALTER. Check RENAME, DROP, recreation under the old name, and saved-state resume. |

A cold read is the first metadata read for a table in a new applier session.
The first two cases share table definitions with the DML fixtures. Each uses
only the initial INSERT to trigger discovery. Each case keeps one applier
session for all its tables. It saves one assertion per distinct metadata
definition and checks the final GTID and source-position checkpoint.
The complete DML phases remain in the related feature groups. The cache case
uses INFO schema-read records and the target general query log to count reads.
It allows the first write after ALTER to validate a new DML plan. The next
write must reuse the plan and schema. It restores the log settings after the case.

The family also retains four target-specific workflows:
`json-target84-schema`, `target84-index-spatial-metadata`,
`expression-target84-dependencies` and `alter-rename-target84-refusal`.
They retain their own restart, replay or refusal checks.
All cases in the group share the same MySQL containers. A metadata-only
selection omits the general correctness applier setup.

Run one case, the family on one profile, or the family on all profiles:

```sh
make lab-test ARGS="--profile mysql57-to-mysql84-innodb --suite correctness --case metadata-cache-ddl"
make lab-test ARGS="--profile mysql84-to-mysql57-myisam --suite correctness --family metadata"
make lab-test ARGS="--profile all --suite correctness --family metadata"
```

Use `make lab-plan ARGS="--profile all --suite correctness --family metadata"`
to inspect the selected groups without starting containers. Add `--coverage`
to a test run to collect code coverage. After the first build, add `--skip-build`
if the build inputs have not changed. See the
[metadata migration review](../PLAN/BETA7_METADATA_GROUP_REVIEW.md).

Full CI assigns related cases to named groups such as
`table-column-index-changes` and `table-metadata-discovery`.
Cases in each group share MySQL containers. The groups retain all selected SQL,
named assertions and explicit saved-state boundaries. See [CI measurements](CI_MEASUREMENTS.md)
for group counts, timing scope and coverage comparison rules.

`ddl-modify-columns` is one ordered test in `table-column-index-changes`.
It tests VARCHAR and VARBINARY width changes, integer type changes, primary-key
width changes, NOT NULL, and FIRST/AFTER column positions. Each ALTER retains its
starting table definition, warning checks, metadata checks and following DML.
Each condition uses its own table. Source statements run in setup, ALTER and
DML phases. Each phase waits once, then batches its result queries on all three
servers. INSERT/UPDATE/DELETE retain their intermediate row checks. Named
assertions check each statement's GTID and file offset, saved schema and normalized
source/native/target binlogs. The test exports state once and checks one saved-state
restart followed by an UPDATE. A MODIFY-only run omits the outer runner's duplicate
restart. It replaces the ten separate column MODIFY cases;
`ddl-modify-indexed` remains separate.

Run this case on one profile, or select `all` to run it across profiles:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-modify-columns"
make lab-plan ARGS="--profile all --suite correctness --case ddl-modify-columns"
```

`ddl-compat-column-index-syntax` uses three source batches. It retains table
states for column keys, index creation/removal and SERIAL insert/update/delete.
`ddl-compat-alter-column-keys` uses four source batches. It retains implicit
values, key changes and AUTO_INCREMENT rebuild results. Final queries and the
full schema/row comparison check those states against the native replica.

The cases keep two and three live restarts. Both offline replay checks stop
after transaction four, resume, and repeat the final observations. Each source
operation keeps its transaction boundary and resets session AUTO_INCREMENT
settings before any operation-specific override. The SQLite check still requires
the original rebuild intent to store increment 3 and offset 2.

Run both cases in one fixture:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-column-index-syntax --case ddl-compat-alter-column-keys --coverage"
```

`ddl-compat-generated-dependencies` and `ddl-compat-column-swaps` each use five
source batches. Separate tables retain the results before later ALTER statements
replace expressions, column names, positions or keys. One final query batch per
server checks the expected values. The full comparison also checks all rows,
column definitions and key references. Each case keeps four live restarts and
an offline replay stop/resume check. Replay repeats the final observations.
The source statements keep their separate transaction boundaries.

Run both cases in one fixture:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-generated-dependencies --case ddl-compat-column-swaps --coverage"
```

`ddl-compat-partition-hash-forms`, `ddl-compat-subpartitions` and
`ddl-compat-partition-expressions` use three, four and four source batches.
Separate tables retain earlier partition definitions and rows. Final queries
check evaluated bounds, tuple routing, subpartition names and methods, and both
sides of EXCHANGE. The full comparison checks all retained schemas and rows.
The cases keep two, three and three live restarts. Subpartition and expression
replay each stop after transaction three, resume, and repeat the final checks.
The original source transaction boundaries remain unchanged.

Run the three cases in one fixture:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-partition-hash-forms --case ddl-compat-subpartitions --case ddl-compat-partition-expressions --coverage"
```

`ddl-compat-partition-column-renames`, `ddl-compat-partition-rename-syntax`
and `ddl-compat-partition-column-bounds` use five, three and three source batches.
Retained tables preserve column swaps, partition replacement/removal and binary
bounds before later changes or DROP. Final checks compare partition references,
row placement and exact byte values. The bounds case retains its connection
character-set override and the session reset before the next operation.

The cases keep four, two and two live restarts. Offline replay stops after
transactions five, five and three, then resumes and repeats the final checks.
RENAME COLUMN keeps its exclusions for MySQL 5.7 sources.

Run all three cases in one fixture:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-partition-column-renames --case ddl-compat-partition-rename-syntax --case ddl-compat-partition-column-bounds --coverage"
```

`ddl-compat-partition-key-algorithm`, `ddl-compat-partition-exchange-unchecked`
and `ddl-compat-partition-maintenance` use four, three and three source batches.
Retained tables preserve KEY algorithms, misplaced rows after unchecked EXCHANGE,
and rows after each maintenance operation. The cases keep three, two and two
live restarts. KEY and EXCHANGE replay stop after transactions three and five,
then resume and repeat the final checks.

The maintenance case has 44 source operations and 39 transactions. Its five
unlogged CHECK/LOCAL operations must leave GTIDs and file offsets unchanged.
The body assertion records how many unlogged operations it checked.

Run all three cases in one fixture:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-partition-key-algorithm --case ddl-compat-partition-exchange-unchecked --case ddl-compat-partition-maintenance --coverage"
```

`ddl-compat-views` and `ddl-compat-routines` each use one source batch.
Retained views and routines live in separate databases. This preserves the
original checks that DROP leaves no views or routines in `ddlcompat`. Final
queries check each retained view result, function output and routine security.
Empty retained tables confirm that CREATE did not execute procedure bodies.
The original CALL checks the procedure's row effect. Compound BEGIN/END bodies
remain in one source operation. Cleanup drops only the retained databases.

Run both cases in one fixture:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-views --case ddl-compat-routines --coverage"
```

`ddl-compat-stored-objects` uses four source batches. It retains routine ALTER
characteristics and LOCAL/CASCADED view metadata in `stored_alter_results`.
The original operations remain first, including multi-view DROP, routine DROP
and DELETE. Final checks preserve all earlier values and the original absence
queries in `ddlcompat`. Three live restarts remain. Offline replay stops after
transaction four, resumes, and repeats the final checks. The journal still
requires the three original DDL records to preserve their SQL. Cleanup drops
only the retained database.

Run this case alone:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-stored-objects --coverage"
```

`ddl-compat-view-renames` uses four source batches. Retained histories in
`view_rename_results` keep complete view/view and table/view rename chains,
including the temporary alias inside each multi-pair RENAME. Final queries check
row values, object types and view security. Current view identities must stay
out of the row-schema cache; renamed base-table identities must remain in it.

The case keeps three live restarts, error 1450 checks on source/native/target,
and an offline replay stop after transaction seven. Replay repeats the final
checks. The original journal count still selects four original RENAME statements.
Cleanup drops only the retained database.

Run this case alone:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-view-renames --coverage"
```

`ddl-compat-conditional-routines` uses three source batches. Retained histories
in `conditional_routine_results` preserve ignored replacement attempts, procedure
DROP and recreation, and row effects from the old and new procedure bodies.
Final queries read metadata and function results; they do not CALL procedures.

The case keeps two live restarts and replay stop after transaction four, the
first CREATE skipped on the target. That operation still counts as a source
transaction. The journal checks use captured source GTIDs to select the original
five compatibility records and two skipped statements. Replay repeats final
observations. Cleanup drops
only the retained database. The three 5.7-source exclusions remain.

Run this case alone:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-conditional-routines --coverage"
```

`ddl-compat-absent-definers` uses three source batches. One retained history
keeps the INVOKER view's initial rows and the INVOKER function result available
for final queries. The original function changes to DEFINER security, and the
original view reads the updated rows.

The case keeps two live restarts and replay stop after transaction four. It
checks ERROR 1449 for the original DEFINER view and function on source, native
and target, before and after replay. Each failed query must leave GTIDs and
binlog offsets unchanged. Twelve named assertions and separate text files
preserve both error stages. Cleanup drops only `absent_definer_results`.

Run this case alone:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-absent-definers --coverage"
```

`ddl-compat-generated-expressions` uses three source batches and final checks on
retained tables. It keeps values from before NULL inputs change. Its two live
restarts and offline replay stop/resume check remain.

The `database` family includes `ddl-compat-database`. CI runs it in
`database-defaults-transactions` with the database creation cases. All cases in
that group use one MySQL fixture. The six creation cases share one running
applier and one saved-state export/restart. They check database/table defaults,
conditional CREATE warnings and rows after each INSERT, UPDATE and DELETE. The
shared snapshot checks every source operation's GTID/file offset and each
CREATE DATABASE intent. Each case keeps its named assertions. The final selected
creation case records the shared `creation-checkpoints` assertion; it contains
all selected case IDs. A shared-check failure fails the fixture.

The lifecycle case still checks inherited defaults, saved table schemas before
DROP DATABASE, and writes after recreation. Its explicit restart is separate
from the creation workflow.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-generated-dependencies"
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --family database"
```

A shared correctness failure prints the case and assertion or source phase, the
original error, and a local support-bundle path. The harness stops the applier
before it calls `support-bundle`. This also collects a bundle for an assertion
failure when the applier did not enter `BLOCKED`. Automatic `BLOCKED` bundles
remain available. Read `harness-failure.json`, the failed assertion or phase file,
and the printed bundle. Its logs include the harness failure and applier logs.
If state is not available or collection fails, output reports the collection
error and keeps the original test error. Setup failures cannot always produce a
state bundle.

The `matrix-binarychoices` and metadata cases check raw binary ENUM labels, binary
SET labels, hex/bit literals and defaults. The `legacybinaryset` cases add non-UTF-8
SET bytes on the two 5.7-to-5.7 profiles. MySQL 8.4.8 rejects that SET definition
with native error 3507. Binary choice schema comparisons read raw SHOW CREATE
output through a separate test parser.

`matrix-binarychoices` uses preparation and body batches with one running applier.
Two retained tables keep all inserted rows and the result after ALTER changes
the defaults. Final queries compare raw bytes, ENUM ordinals, SET masks, the
declared empty member and NULL rows. Separate queries check default bytes before
and after ALTER. Full schema comparison keeps the raw SHOW CREATE parser.
The original scripts, three predicates and FULL metadata remain. Cleanup drops
only the retained tables. The case adds no applier restart.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-binarychoices --coverage"
```

`matrix-legacybinaryset` uses the same workflow with one retained table on the
two 5.7-to-5.7 profiles. Final queries compare raw FF/61 member bytes, SET masks
and NULL rows. Separate queries check default bytes FF2C61 before ALTER and FF
afterward. The original compound ALTER/UPDATE/DELETE request, both predicates
and profile exclusions remain. Full schema comparison keeps the raw SHOW CREATE
parser. Cleanup drops only the retained table. The case adds no applier restart.

```sh
make lab-test PROFILE=mysql57-to-mysql57-myisam ARGS="--suite correctness --case matrix-legacybinaryset --coverage"
```

The `ddl-compat-tagged-gtids` case uses the 8.4 source profile with
`--variant without-source-gtids` (`target.preserveSourceGTIDs: false`). It compares tagged
DDL/DML results with the native reference, then checks rotation, process restart,
archive replay and a tagged stop limit. It checks source GTIDs in SQLite
separately from the target server's GTIDs.

The `gtids` family contains these two cases. Within that family,
`without-source-gtids` selects only the tagged case. Without the family filter,
the variant also selects `positive` and `ddl-compat-generated`, where applicable.
It does not repeat the full correctness suite.

The `ddl-compat-source-gtid-preservation` case uses the default setting
`target.preserveSourceGTIDs: true`. It checks the target GTID set after DDL,
multi-row INSERT/UPDATE/DELETE, keyless duplicate rows, restart, and archive replay.
It retains a 40-row source transaction. The `positive` case separately checks
exact source/target GTID delta equality, or the absence of source GTIDs on the
target when preservation is disabled. CI keeps these cases in `keys-rows-gtids`
so that they share container setup. The dedicated preservation and tagged cases
use SQL transport; `positive` also runs in the selected BINLOG groups. See the
[GTID test review](../PLAN/BETA7_TEST_SUITE_CONSOLIDATION.md#slice-8--gtid-review).
Run it for all four profiles:

```sh
make lab-test ARGS="--profile all --suite correctness --case ddl-compat-source-gtid-preservation"
```

## List and run

Build prerequisites are in [CONTRIBUTING](../CONTRIBUTING.md). From the checkout:

```sh
make lab-list
make correctness TIER=smoke
make correctness
```

The list is an offline JSON inventory: no Docker provisioning or implicit use of
old evidence. `make correctness` runs the shared full correctness catalog for
all profiles; `TIER=smoke` selects a small representative subset. Use the full
tier for every applicable family. Unit tests remain `make test`. Select one topology or an ordered scenario with:

```sh
make correctness PROFILE=mysql57-to-mysql84-innodb ARGS="--case ddl-index-create"
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--family database"
```

Equivalent CLI: `swift run replicator-lab test --profile PROFILE --suite correctness`.
Use `--list`, `--tier smoke|full`, `--family FAMILY`,
repeated `--case ID`, `--skip-build`, or `--coverage`. Cases include dependent
statements as a unit; prerequisite cases are selected automatically. Unknown IDs
and invalid combinations fail before provisioning. The default uses GTID
positioning, FULL row images, FULL optional metadata on 8.4, and the metadata available on 5.7. Historical forward capture variants are
also available, as described below; unsupported combinations are not inferred.

The shared runner creates schemas through source-side DDL, executes the same
DML/index/DDL fixtures, compares row values and expected metadata, checks
catch-up and intent completion, and reopens saved schemas before applying another
transaction. Engine differences are checked against the profile before schema
comparison; arbitrary data/DDL differences are not normalized away.

Ordinary columns use exact row bytes. JSON comparisons read every path, type,
and scalar value from each server. Only DOUBLE display text is normalized to
its binary value because 5.7 can print `1` where 8.4 prints `1.0`. Integer,
DECIMAL, string, temporal and binary values remain exact. These checks keep
JSON null separate from SQL NULL and detect changes in JSON scalar types.
The large-value case checks blocked-state retention on all profiles. InnoDB
uses audited retry. MyISAM checks restart refusal, verifies that the target row
is absent, then uses a separate state at the saved source boundary. This is a
controlled test of manual reconciliation, not automatic MyISAM recovery.

The full `dml` family includes `large-values` on all four profiles. This case
checks large TEXT/BLOB values, packet limits, restart, offline replay, and
recovery inspection. It requires GTID mode. See [large-value limits and tests](LARGE_VALUES.md).

`matrix-integers` checks signed and unsigned TINYINT, SMALLINT and MEDIUMINT
limits, a signed primary-key change, NULL and DELETE. `matrix-decimal` checks
all 65 digits of DECIMAL(65,30), unsigned values, exact scale, NULL and DELETE.

`matrix-bits` checks widths through 64 bits, defaults, primary-key changes and
ADD/MODIFY. Queries check the full unsigned values, the widened declaration and
the new defaults. See [BIT support](../PLAN/BIT_SUPPORT.md).

These three cases use preparation, body and cleanup batches on one running
applier. Retained tables preserve every earlier result. Final comparisons keep
the original predicates, exact numeric strings and native schema/default checks.
Cleanup removes only the retained tables. No case adds an applier restart or
changes its cold metadata definition and first INSERT. Select all three in one
fixture with:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-integers --case matrix-decimal --case matrix-bits --coverage"
```

`matrix-floatbounds` checks FLOAT(M,D) boundary rounding and primary-key changes.
`matrix-zerofill` checks implicit UNSIGNED, numeric defaults, display-width changes
and unsigned limits. `matrix-fixedfloating` checks fixed-scale FLOAT/DOUBLE,
rounded defaults, large exponents and ALTER. `matrix-floating` checks ordinary,
smallest positive and maximum FLOAT/DOUBLE values, NULL and precision changes.
See [FLOAT/DOUBLE support](../PLAN/FLOATING_POINT_SUPPORT.md).

These four cases use the same shared runner, profile and batch approach as the
integer, DECIMAL and BIT cases. Each keeps its own name, original SQL and
predicates. Retained tables keep earlier results. Final queries check every row,
numeric attributes, declarations and defaults. MySQL evaluates approximate
values with SQL equality/range checks. The native row comparison also remains
active. The tests do not convert expected values through host Double arithmetic.

Select only the four changed cases in one fixture with:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-zerofill --case matrix-floatbounds --case matrix-fixedfloating --case matrix-floating --coverage"
```

The regular data-types-values CI group shares its fixture and ordinary applier
across all selected cases. These conversions add no separate CI job, container
restart or per-case applier restart. Cold metadata inputs stay unchanged.

`matrix-temporal` checks DATE, DATETIME, TIMESTAMP, TIME and YEAR values,
including time-zone changes, zero values and NULL. `matrix-precision` checks
fractional seconds. `matrix-defaults` checks AUTO_INCREMENT, constant defaults
and automatic TIMESTAMP initialization/updates under fixed source timestamps.
These cases belong to data-types-values on all four existing profiles. They
share the group's fixture and applier; they require no additional profile.

All three cases submit preparation, body and cleanup batches. Retained tables
keep each earlier result. Final queries read in UTC and check every column,
including signed subsecond TIME values, zero dates, unchanged rows and NULL.
Metadata checks retain fractional precision, AUTO_INCREMENT, constant defaults
and automatic TIMESTAMP initialization/update attributes.

Original scripts keep their time-zone and timestamp settings. The profile session
resets the time zone before each source request. Fixed `SET timestamp` statements
stay immediately before their original INSERT or UPDATE. Cleanup drops only
retained tables. The cases add no applier restart and keep cold metadata inputs.

Select only the three changed cases in one fixture with:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-temporal --case matrix-precision --case matrix-defaults --coverage"
```

`matrix-decimaldefaults` checks native
DECIMAL default rounding, scientific notation, quoted constants, unsigned and
ZEROFILL forms. It includes CREATE, ALTER DEFAULT, ADD, MODIFY and row changes.
Preparation and body batches share one running applier. Two retained tables keep
the INSERT result and the first default change. Final queries compare every
numeric field, actual stored defaults and declared scales/attributes. Metadata
and saved-state checks verify the removed default. They keep
the three original predicates and the compound SQL requests. Cleanup drops only
the retained tables. The case adds no applier restart. Cold metadata keeps the
original definition and first INSERT.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-decimaldefaults --coverage"
```

The `matrix-binarydefaults`, `matrix-textdefaults`, `matrix-fixed` and
`matrix-lob` cases belong to the same data-types-values group as the numeric
and temporal cases. One group/profile run shares its containers and ordinary
applier across these cases. Selecting the four cases together starts one fixture;
it does not start a new set of containers for each case.

All four use preparation and body batches through the shared execution workflow.
Two retained tables per case keep the INSERT result and the next changed result.
Final queries check these results after all source writes complete. Cleanup drops
only the retained tables. The original SQL requests and predicates stay in place.

`matrix-binarydefaults` checks exact binary default bytes, NUL, empty values,
BINARY padding, binary CHAR declarations, numeric versus quoted constants,
changed widths and removed defaults. It compares every row field and actual
stored defaults. Metadata checks verify that DROP DEFAULT removed the default.

`matrix-textdefaults` checks CHAR/VARCHAR defaults with supplementary and
decomposed Unicode, NUL, byte literals, numeric constants, latin1 and UTF-16.
The original request keeps PAD_CHAR_TO_FULL_LENGTH. Each following request resets
the session mode. Final reads check exact bytes, CHAR trimming, VARCHAR spaces
and the changed declarations. Queries do not evaluate a removed default.

`matrix-fixed` checks all CHAR(255) and BINARY(8) bytes before and after UPDATE.
It keeps the empty and NULL rows separate. The final result must contain only
the empty CHAR row with eight zero bytes in its BINARY field.

`matrix-lob` checks TINYTEXT, TEXT, MEDIUMTEXT, LONGTEXT and all four BLOB types.
Queries compare every byte of the large repeated values, including 70 KB fields.
They also check NUL, quotes, a backslash, Unicode, empty values, NULL and the TEXT
prefix index. The original table must be empty after DELETE. Native schema,
stored-default and complete row comparisons remain active for all four cases.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-binarydefaults --case matrix-textdefaults --case matrix-fixed --case matrix-lob --coverage"
```

`matrix-encodings` checks latin1, ASCII, UTF-8 and binary fields. Three retained
tables keep the results after INSERT, key UPDATE and ADD COLUMN. Final queries
check every field, stored key bytes, case-insensitive matching, CHAR trimming,
BINARY zero padding and JSON DECIMAL types and values. Separate queries check
the original UTF-8 default and the added CHAR default. The server-based JSON
comparison remains active.

`matrix-widestrings` checks VARCHAR(20000) and VARBINARY(20000). Two retained
tables keep the complete 18,000-byte payloads and their short replacements.
The large-value query compares every byte with fixed REPEAT patterns. Final
queries also require the original table to be empty after DELETE. The column
declarations stay unchanged; this is not a packet-limit test.

`matrix-zerowidth` checks zero-length CHAR, VARCHAR, BINARY and VARBINARY columns,
including UTF-16. Three retained tables keep INSERT, UPDATE and wider-column
results. Final queries distinguish every empty field from NULL and check the
wider schema, its defaults and the restored zero-length declarations.

All three cases use preparation and body batches with one running applier.
They keep their original SQL, predicates and metadata settings. Cleanup drops
only the retained tables. They add no per-case restart. Cold metadata tests
keep each original definition and its first INSERT.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-encodings --coverage"
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-widestrings --coverage"
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-zerowidth --coverage"
```

`json-year-compatibility` checks the optional 5.7 to 8.4 YEAR conversion inside
JSON. It includes default refusal, native type checks, restart, UPDATE/DELETE,
policy-change refusal and offline replay. Run it with:

```sh
make lab-test ARGS="--profile mysql57-to-mysql84-innodb --suite correctness --case json-year-compatibility"
```

`ddl-compat-json-indexes` checks indexed generated columns, JSON extraction,
ALTER, CREATE LIKE, row changes, and restart on all four profiles. It uses a
STORED indexed column on MyISAM targets and a VIRTUAL indexed column on InnoDB
targets. It also adds a STORED indexed column on all profiles.
The case sends three source batches around its two deliberate restarts. Separate
tables retain the initial index lookup and the LIKE copy before its final UPDATE.
One final query batch checks forced-index results and generated-column metadata.
The final schema comparison also checks the complete JSON values and types.

`json-target57-limits` uses the 8.4 source and native InnoDB replica to accept
JSON expression defaults, functional indexes, and an indexed VIRTUAL column.
The 5.7 MyISAM target must reject each statement before target SQL. The test
checks that no target table exists and the transaction count remains zero.

`json-target84-schema` checks an existing 8.4 target table with functional
indexes and a JSON expression default. It checks INSERT, UPDATE, DELETE,
restart, indexed queries, and offline replay. The source and native reference
are 5.7; their tables have the same visible columns, without the 8.4-only index
and default definitions. Target-side queries verify these extra definitions.

`expression-target84-dependencies` uses the same target-baseline method. It
checks column renames and drops with dependent index/default removal, both clause
orders, index replacement, later DML, restart and offline replay. It also checks
that unchanged dependencies stop apply without a target change or checkpoint advance.
Run it with `--profile mysql57-to-mysql84-innodb --suite correctness --case expression-target84-dependencies`.

```sh
make lab-test ARGS="--profile mysql57-to-mysql84-innodb --suite correctness --case ddl-compat-json-indexes --case json-target84-schema"
```

`matrix-json` checks ordinary JSON values.
`matrix-typedjson` checks DECIMAL, temporal and
binary JSON types. All four profiles select these cases. `matrix-jsonpartial` checks partial updates on an 8.4 source.
It inspects mysqlbinlog output to confirm that the source emitted a change
record. These cases passed on the applicable profiles. The old `matrix-reject-json-opaque` case
is removed. See [JSON support and limits](JSON_SUPPORT.md).

`matrix-spatial` checks all eight spatial types,
SQL NULL, empty collections, SRIDs 0 and 4326, INSERT/UPDATE/DELETE, primary-key
changes, added columns, and SPATIAL index changes. It compares stored bytes
and SRIDs with the native replica. It does not compare WKT output across server
versions. See [spatial support and limits](../PLAN/SPATIAL_SUPPORT.md).
The former `reject-geometry` and `reject-fulltext` refusal cases have positive
coverage. The refusal selection now uses `reject-engine`.

`ddl-compat-fulltext` checks index creation, changes, parser metadata, search
results, CREATE TABLE LIKE and restart. It also checks explicit ngram index
creation and searches after multirow INSERT, UPDATE and DELETE. These named
assertions replace `matrix-fulltext`. `metadata-columns-indexes` checks initial
discovery of an existing ngram index and saves its parser metadata. See [FULLTEXT scope](../PLAN/FULLTEXT_SUPPORT.md) and the
[migration review](../PLAN/BETA7_TEST_SUITE_CONSOLIDATION.md).

The FULLTEXT case uses three source batches and keeps both deliberate restarts.
Separate tables retain positive and negative search results before UPDATE,
DELETE or index removal. Final `SHOW CREATE TABLE` checks read the `ngram`
parser on the named index after explicit CREATE, ALTER ADD and LIKE. The saved
assertions include the raw metadata. These checks do not prove all search terms
or parser settings.

`ddl-compat-spatial-prefix-indexes` checks ordinary BTREE prefixes on geometry
columns between two MySQL 5.7 servers. It retains the original point, line and
NULL values, then checks the changed compound prefix and its LIKE copy. It uses
three source batches and two deliberate restarts. Exact geometry bytes enter
the final comparison. This is not a SPATIAL index search test. Profiles with an
8.4 source or target exclude it because native 8.4 rejects this index definition.

Run these related cases in one fixture, then reuse the same coverage image for
the InnoDB SQL branch:

```sh
make lab-test PROFILE=mysql57-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-spatial-prefix-indexes --case ddl-compat-json-indexes --case ddl-compat-fulltext --coverage"
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite correctness --case ddl-compat-json-indexes --case ddl-compat-fulltext --coverage --skip-build"
```

These cases keep their existing case IDs and CI assignments. They check live
apply and saved-state restart. They do not add offline replay checks.

`--case ddl-compat-constraints` exercises named PRIMARY/UNIQUE constraints in
CREATE and ALTER, explicit index-name precedence, unnamed constraints, and DML
after the changes on all profiles. Named assertions distinguish single-row
UPDATE/DELETE from multirow INSERT/UPDATE/DELETE. The multirow phases replace
`matrix-values`; they retain its separate integer-primary-key table and non-NULL
value column. Each phase checks exact rows, including unaffected rows.
`metadata-columns-indexes` checks initial discovery of integer and unique keys.

`ddl-compat-key-conflicts` combines the former `matrix-upsert`, `matrix-replace`
and `matrix-ignore` cases. It keeps separate tables and the original SQL for each
starting state. Named assertions check mixed insert/update effects, REPLACE
conflicts with two different rows, skipped duplicate rows, and no-op statements.
Each check compares exact rows on source, native and target. The metadata group
checks discovery once for the shared primary-key and unique-key definition.

The `keys-rows-gtids` group contains the `positive` single-row case and related
key, row and GTID cases. The SQL `without-source-gtids` variant instead uses
`source-gtid-preservation-disabled`. That group combines `positive`,
`ddl-compat-generated` and the applicable tagged-GTID case in one fixture.
The `positive` case also tests INSERT, counters, binlogs and saved state; it is not an UPDATE/DELETE-only test. Other single-row
operations run in cases that check specific keys, types and schema changes:

| Case | Row-write conditions |
|---|---|
| `positive` | Single-row INSERT, UPDATE and DELETE; exact counters, binlog operations and saved checkpoints |
| `ddl-compat-constraints` | Named `primary-key-single-row-update` and `primary-key-single-row-delete` assertions; separate `primary-key-multirow-*` assertions |
| `ddl-compat-primary-key-row-matching` | Changes to each composite-key part and DELETE by the complete key; case-only text key UPDATE and case-insensitive DELETE |
| `ddl-compat-keyless-rows` | Single-row and multirow changes without a usable unique key, including duplicate rows |

`ddl-compat-primary-key-row-matching` replaces `matrix-composite` and
`matrix-textkey`. It keeps their separate table definitions and source statements.
Named assertions check exact rows after each operation. They retain equal IDs
on different dates, separate changes to each part of `PRIMARY KEY(report_date,id)`,
and unaffected rows. The text table uses a `VARCHAR(20)` PRIMARY KEY with
`utf8mb4_unicode_ci`. Assertions check exact key bytes after a case-only change
and a case-insensitive DELETE.

`metadata-columns-indexes` retains cold reads of the composite and text key
definitions. Prefix-key and UNIQUE-key workflows remain separate. The
[measured review](../PLAN/BETA7_TEST_SUITE_CONSOLIDATION.md#slice-6--composite-and-text-primary-key-review)
records preserved coverage and the accepted time increase. These cases now share
the `keys-rows-gtids` fixture with related key and row tests.

Cases in a group share MySQL containers. They do not all share an applier state
directory. Bootstrap, failure and replay cases keep their own state and starting
positions. A required resume reuses that case's saved state. The continuous
writer stops before isolated cases start. An unexpected failure stops the group;
remaining cases are reported as not run. Other CI jobs can continue. The runner
does not reuse an uncertain fixture after an unexpected failure.

Here, single-row means one changed row per statement. It does not mean MySQL's
single-table statement syntax, which can change many rows. Select cases with
`--case`; named assertions describe the recorded checks within each case and
cannot be selected separately. A multirow test does not replace a distinct
single-row key, type, restart or failure condition merely because coverage overlaps.

`ddl-compat-ignored-checks` checks ignored 5.7 CHECK clauses, compound DDL,
violating rows, the durable no-op ALTER record, restart and offline replay.
`check-target57-limits` checks that an enforced 8.4 constraint stops before
target DDL. See [native compatibility rules](NATIVE_COMPATIBILITY.md).
InnoDB profiles support foreign keys with the limits below.

The `foreign-keys` family applies to both InnoDB target profiles. It compares
parent/child rows, constraint metadata and supporting indexes with native 5.7
replication, exercises cascades, composite references, ordered DDL and restart,
and checks exclusions, rollback and offline recovery relationship evidence.
It runs as its own parallel CI area. Use
`make correctness PROFILE=mysql57-to-mysql84-innodb ARGS="--family foreign-keys"`.
The family also includes `ddl-compat-foreign-key-controls`. It checks
self-references, cycles, source check settings, restart and offline replay.
`ddl-compat-foreign-key-ddl` checks supporting indexes, FK-column renames, internal
database DROP and replay through the saved schema history. It also checks journal
records for FK tables with no captured events. The safety case adds an incoming
FK only on the target. It checks that DROP fails before SQL and keeps the checkpoint.
`ddl-compat-foreign-key-missing-parent` checks missing parents, parent recreation,
restart and replay while the parent is absent.
`ddl-compat-foreign-key-parent-keys` checks native nonunique, composite-prefix and
extended parent keys, cascades, restart and replay.
`ddl-compat-foreign-key-syntax-columns` checks constraint and index names, MATCH
action translation, native-compatible column types, cascades, restart and replay.
`ddl-compat-foreign-key-cross-database` checks child database DROP, parent DROP
with source checks disabled, surviving relationships, parent recreation, restart
and replay while the parent database is absent. It compares both databases.
`ddl-compat-foreign-key-generated` checks stored generated parent and child columns,
cascades, native virtual/action rejection, restart and replay.
`ddl-compat-generated-dependencies` checks compound generated-column changes,
stored/ordinary conversion, text literals, later DML, restart and offline replay
on all four profiles. Native 5.7 DROP restrictions remain.

`ddl-compat-alter-column-keys` checks inline primary keys, implicit values,
AUTO_INCREMENT session settings, later DML, restart and offline replay on all
four profiles. Native rebuild order remains a cross-engine limit.

`ddl-compat-foreign-key-compound-indexes` checks multiple FK additions mixed with
index and column changes. It checks the index-choice journal, actual saved schema,
restart and replay.
`reject-foreign-key` tests a missing parent index on InnoDB and
foreign-key DDL refusal on MyISAM.

The `filters` family runs wildcard exclusions, saved-state resume and included-DDL
refusal on all profiles. It keeps the independent native/target binlog oracle as
well as row, checkpoint and intent checks. MySQL 8.4 `mysqlbinlog` must be on PATH
(or set `MYSQLBINLOG` to its path); this is checked before fixture startup. Smoke
includes the wildcard workload; full includes resume and refusal. Selecting
`--case wild-ignore-included-rejection` automatically includes both prerequisites.
These cases bootstrap equivalent tables without logging, then use isolated state
directories for their measured source workload.

## Ordered and isolated experiments

The full correctness inventory includes these additional families. Use `--list`
for applicability reasons and the selected variant; source-version and engine
specific refusals are not silently reused with different expectations.

| Family | Experiment |
| --- | --- |
| `ordered` | `ddl`: 70 dependent table-lifecycle steps, conditional no-ops, LIKE, cross-schema moves, defaults, schema history and independent binlog comparisons |
| `collation` | Forward 0900 translation, cleanup/table swap, policy-change resume refusal and PAD collision |
| `metadata` | Read existing columns, indexes, labels and defaults; reuse and invalidate the metadata cache; retain target-only schema workflows |
| `dml-refusals` | Forward `matrix-reject-*`: incompatible metadata, generated values and decoder refusals, with target effects and unchanged checkpoint checks |
| `discovery` | `ddl-index-resume`: saved indexed schema, resumed DML and external index-drift refusal |
| `offline` | `offline-replay`: finite fetch, external raw files, replay/resume without source credentials, native comparison, and support-bundle extraction |
| `policy` | `live-skip-errors`: live capture with optional audit, DDL skip, InnoDB rollback/resume, exact GTID stop and MyISAM refusal |
| `offline` | `offline-skip-errors`: optional per-GTID audit, DDL skip-and-continue, InnoDB duplicate rollback/resume and MyISAM duplicate refusal |
| `offline` | `runtime-control`: exact GTID stop/resume, live/offline reload, refusal of checkpoint changes, and acknowledged stop while target writes are blocked |
| `failures` | `forward-failures`: restricted grants, target SQL errors, uncertain DDL, skip refusal, trigger policies and generated-value divergence |
| `recovery` | `myisam-recovery`: exact values, discovery/cache/explicit locks, partial writes, killed groups and refused replay; GTID variants only |

`positive` preserves the bootstrapped INSERT/UPDATE/DELETE sample, direct YAML
credentials, exact counters and independent source/native/target binlogs. It is
included in smoke. Smoke also checks database retirement immediately after
resuming saved schemas. The other isolated experiments run after the continuous
writer has drained. Explicit restart pairs share a state directory; unrelated failures
use distinct directories. Group child cases retain individual results in
`cases.json`; selecting the group runs its required ordered setup and assertions.
The MyISAM group runs last because its expected native failures deliberately leave
the native channel blocked. Native-only resets between independent refusal
experiments are fixture cleanup, never an applier recovery action.

The old DDL/DML runners have been retired after matched runtime coverage,
[assertion/variant mapping](../PLAN/TEST_SUITE_RETIREMENT_MAP.md), and named catalog
checks. Historical evidence and the precise limits remain in the retirement report.

## Outcomes and scope

Each selected scenario/profile has a stable ID, expected behavior and status:
`not_run`, `running`, `passed`, `failed`, `not_applicable` with a reason, or
`not_implemented` with a visible gap. Expected rejection is a passing test only
when it confirms the diagnostic, unchanged checkpoint and documented target
effects. Refusals before execution require no target writes; a post-write MyISAM
failure must preserve evidence of any retained writes.
A source success, native success and applier refusal are distinct outcomes.

A selected obligation that is missing or never ran makes the aggregate incomplete
and exits nonzero. Suite setup, restart, evidence collection and cleanup failures
also fail the run even if individual cases passed. Partial selections identify
their scope and do not claim full MySQL compatibility.

The reverse multi-table/defaults workflow is profile-specific. Foreign keys remain
an expected refusal; the support proposal is [MYSQL57_FOREIGN_KEYS](../PLAN/MYSQL57_FOREIGN_KEYS.md).
Bootstrap-table DML tests and replicated-CREATE tests prove different things:
both remain available, without presenting one as a substitute for the other.

## Existing specialized qualification

These suites use the common profile interface. Correctness, lifecycle and demo run
shared, individually declared cases on all profiles. Both MyISAM profiles use the
shared recovery workflow. Other specialized suites retain their established
runners/assertions and are labeled adapters in the inventory.

| `--suite` | Scope |
| --- | --- |
| `correctness` | Shared replicated-DDL, DML, indexes, policies, filters and refusals |
| `lifecycle` | Shared source/target reconnect, restart, drain and uncertain-write cases |
| `recovery` | Shared MyISAM workflow; retained InnoDB rollback/inspection/audited retry runner |
| `demo` | Shared workbook, manual start, heartbeats, signals/resume, shell repair; profile-specific failure/skip and recovery |
| `native` | Original 8.4-source native DDL observation suite |
| `performance` | 10K backlog benchmark against native replication, with a configurable elapsed-time ratio limit |
| `all` | All of the above; any missing required case makes the run incomplete |

For example: `make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite recovery"`.
Recovery qualification omits the old embedded benchmark. MyISAM `recovery` selects
the same `myisam-recovery` group included in full correctness; `--suite all` runs
that group once. Its ordered child cases are listed in the offline inventory.
The `dml-suite`, `ddl-suite`, `legacy-dml` and `legacy-ddl` commands are removed.
Use shared `correctness`, its `metadata` family and capture variants instead.
The old `reverse-suite` and `reverse-correctness` CLI aliases remain, but their
Make targets are removed. Use the shared suite and an explicit profile.
The former `demo-*` and `reverse-demo-*` commands are replaced by `demo ACTION
--profile PROFILE`; their rehearsals are now named cases in `test --suite demo`.
Existing legacy sessions are never adopted or overwritten. To archive and remove
one, use `make lab-demo PROFILE=PROFILE ACTION=legacy-down`.

Demo selection supports `--family lifecycle|workbook|failure|resume` and `--case ID`.
Dependencies are included automatically; profile-specific cases report
`not_applicable` on topologies without the required capabilities. For example:

```sh
make lab-list ARGS="--suite demo" | jq '.scenarios'
make lab-test ARGS="--suite demo --coverage"
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite demo --case demo-skip-and-resume"
```

Demo test evidence lives under `artifacts/lab/RUN_ID/PROFILE/demo/default/`.
Each independent session records assertions, comparisons, pinned runtime metadata,
archived SQLite/relay state and, when enabled, `code-coverage/combined/`. These
workbook checks do not claim additional MySQL catalog coverage.

Run reconnect qualification for all profiles, or select one:

```sh
make lab-test ARGS="--suite lifecycle"
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite lifecycle --skip-build"
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite lifecycle --case source-reconnect --case target-reconnect --dml-transport binlog --skip-build"
```

Lifecycle selection accepts `--case ID` and `--family source|target`. A resume
case also selects its setup case. Use `--list` to inspect the selected cases.

The 11 lifecycle cases use equivalent bootstrapped integer tables and default to
GTIDs; capture variants below also exercise file-position starts.
They cover source socket loss, rotation, clean/crash restart, interruption during
an active group, backoff cancellation, and changed source settings; target
socket loss/restart, active-group drain, saved-state resume with an unavailable
target, backoff drain, lost mutation replies and changed target settings.
InnoDB tests wait for partial progress in an 8,000-row group. MyISAM tests first
apply one row to load table metadata. They then hold a table lock and wait for
an issued 128-row helper-function request before the interruption. This removes
the need to catch a short interval between individual writes. The lock is released
after the interruption or drain request.
Successful cases compare source/native/target rows and saved checkpoints.
The InnoDB lost-reply case observes a provisional write before disconnecting,
then checks rollback and durable pending-row evidence. The applier still reports
an unconfirmed rollback and blocks ordinary resume; this does not authorize
automatic replay or qualify a lost COMMIT reply. The forward case uses a table
lock on INSERT instead of an InnoDB row lock on UPDATE. All cases run in order, with distinct state
directories except the explicit resume pairs. DDL timeout and skip-refusal
fixtures run in the shared `forward-failures` group.

The [DDL catalog](../tests/DDLCoverage/README.md) still distinguishes case passes
from named assertion qualification. Its historical profile IDs describe specific
variants of the forward lab profile. Shared-run results qualify only explicitly
migrated bindings through the named assertion bundles described below.

The [coverage migration review](../PLAN/TEST_SUITE_COVERAGE_MIGRATION.md) compares
legacy and shared runtime line sets separately from catalog assertions and lists
the gates for retiring old runners. Declaration overlap alone is not parity.
The [retirement assessment](../PLAN/TEST_SUITE_RETIREMENT_ASSESSMENT.md) records
the original gaps, measured migration checkpoints and final removal evidence.

### Capture variants and catalog evidence

Correctness and lifecycle accept `--variant default|position-minimal|gtid-full|lowercase-tables|without-source-gtids|all`.
The default keeps each topology's usual GTID start with a file/offset. The two
historical forward variants use file-position with MINIMAL optional row metadata,
or GTID-only start with FULL metadata. `--variant all` lists/runs each separately;
the historical variants are explicitly not applicable to the 5.7-source profile.
MySQL 5.7 has no `binlog_row_metadata` setting. Lifecycle's default integer-only
workload uses MINIMAL on the 8.4 source; explicit variants preserve their setting
across restarts. Matrix fixtures that require FULL labels declare that override.

DDL cases that write ENUM/SET values also request FULL metadata: encoded SQL,
charset conversion, and keyless rows. They still use file-position capture when
that variant is selected. They do not test ENUM/SET with MINIMAL metadata. Other
DDL cases restore the variant's metadata setting. The existing types-case rule
excludes that case from the position-minimal variant.

Offline replay uses GTID positioning, including the replay phase of a live
file-position test. It uses the saved starting GTID set. When a case restores
target seed data for an independent replay, it also resets the disposable target's
GTID history to that starting set. Resume tests retain both target GTIDs and
SQLite state. These fixture resets are not production recovery instructions.

```sh
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--variant position-minimal --family filters --coverage"
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite lifecycle --variant gtid-full --coverage --skip-build"
```

Forward historical correctness runs also write `catalog/coverage-evidence.json`.
Only explicitly migrated database/MODIFY/index and ordered table-lifecycle bindings accept the
`shared-correctness` producer. Their named checks include source warnings,
following rows, and (for MODIFY/index) normalized source/native/target binlogs,
durable boundaries and schema history. All required cases for a binding must
pass; selecting one representative case does not qualify the entire family.
Default/reverse runs retain their lab assertions but cannot fill historical
catalog profile slots. Import one bundle per historical profile with the existing
DDL catalog report command; do not combine passing subsets of different runs.
The logical catalog suite IDs and all 730 required obligations remain intact;
those identifiers do not retain old runner entry points.

## Local test commands

Use `PROFILE=all` to select all applicable profiles. Use one profile ID to limit
that selection. `ARGS` supplies options to the runner. Catalog and plan commands
write JSON to stdout, so you can pipe their output to `jq`.

```sh
# List cases for one profile. This does not start containers.
make lab-list PROFILE=mysql57-to-mysql84-innodb | jq '.scenarios'

# Inspect an index-family selection across the four profiles.
make lab-plan PROFILE=all ARGS="--family indexes" | jq

# Run that selection across the four profiles, or on one profile.
make lab-test PROFILE=all ARGS="--suite correctness --family indexes"
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite correctness --family indexes"

# Select a case, capture variant and BINLOG transport.
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--case positive --variant gtid-full --dml-transport binlog"

# Run the 10K benchmark. Report a ratio above the limit without failing for it.
make lab-performance PROFILE=all ARGS="--dml-transport binlog --max-native-ratio 2 --report-only"

# Create a demo, then start its applier. A demo requires one profile.
make lab-demo PROFILE=mysql57-to-mysql84-innodb ACTION=up
make lab-demo PROFILE=mysql57-to-mysql84-innodb ACTION=start
```

A suite selects a runner, such as `correctness` or `lifecycle`. A family selects
related catalog cases. A CI group is a reviewed list of cases that share a
fixture for one profile, variant and transport. A family can span several CI
groups. Without `GROUP`, `--variant all` expands capture variants and
`PROFILE=all` expands profiles. Neither option adds BINLOG transport automatically.

### Multi-table rename and DROP workflow

`ddl-compat-multi-table` uses independent tables to retain moved, updated,
swapped and copied results. It compares their exact rows and both databases'
metadata at the end. The original DROP and name-reuse sequence remains. The
case keeps five saved-state restarts and checks the SQLite record for a DROP
that affects three tables. It removes its retained tables before the next case.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-multi-table --coverage"
```

The source runs six batches, separated only by those restart checks. Statements
keep their own source GTIDs and commit boundaries. Each final query has a named
assertion. Its evidence identifies the query, server role, expected value and
actual value. The final schema assertions retain separate snapshots for
`ddlcompat` and `otherdb`. A failed case reports its artifact and support-bundle
paths through the shared runner.

### Compound table renames and cross-database foreign keys

Run the two related workflows in one fixture:

```bash
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite correctness --case ddl-compat-alter-table-rename --case ddl-compat-cross-schema-relationships --coverage"
```

Use `mysql84-to-mysql57-myisam` to check the MyISAM branch. Each case retains
four saved-state restart points. Separate parent/child table sets retain moved
and returned results until the final queries. The InnoDB branch checks exact
UPDATE cascade values and FK definitions. Both branches compare schema metadata
and rows in `ddlcompat` and `otherdb`.

The compound ALTER case also tests offline replay. It removes its retained
tables from the target, stops replay after the original parent move, and resumes
with an unreachable source. Replay repeats the final checks for both databases.
Named results appear under `assertions/<case-id>/`; replay checks use the
`replay-` prefix. The normal failure handler prints the support-bundle path.

### Select the same groups as CI

Set `GROUP` to use the shared CI plan. `GROUP=all` lists or selects all existing
CI groups. A named group retains its full case list, prerequisites and fixture
boundary. No containers start when you list or plan groups.

```sh
# List group names, then inspect one group across all profiles and CI variants.
make lab-list GROUP=all | jq '[.groups[].area] | unique'
make lab-plan GROUP=keys-rows-gtids PROFILE=all | jq

# Inspect one profile and one variant. Add --commands for copyable commands.
make lab-plan GROUP=keys-rows-gtids PROFILE=mysql57-to-mysql84-innodb ARGS="--variant default --commands"

# Run that group. This runs one fixture, with the same cases as CI.
make lab-test GROUP=keys-rows-gtids PROFILE=mysql57-to-mysql84-innodb ARGS="--variant default"

# Plan both existing 10K transport groups on the four profiles.
make lab-plan GROUP=replication-backlog-10k ARGS="--group binlog-replication-backlog-10k"

# Run a BINLOG benchmark and report a ratio above the chosen limit.
make lab-test GROUP=binlog-replication-backlog-10k PROFILE=mysql57-to-mysql84-innodb ARGS="--max-native-ratio 2 --report-only"
```

The `source-gtid-preservation-disabled` SQL group uses one fixture per profile.
The variant is still named `without-source-gtids`. It disables target preservation,
not source GTIDs. SQLite still tracks source GTIDs. Generated-column checks use
the main applier. Basic DML uses separate state and stops after four transactions.
The 8.4-source profile also checks tagged GTIDs, live restart and offline replay.
These required process boundaries do not start another database fixture.

```sh
make lab-plan GROUP=source-gtid-preservation-disabled PROFILE=all
make lab-test GROUP=source-gtid-preservation-disabled PROFILE=mysql84-to-mysql57-myisam ARGS="--skip-build"
```

The planner reads `correctness_variant_groups` in `tools/ci_matrix.json` for
complete SQL selections that span feature areas. Each applicable case must have
one owner. Profile exclusions and prerequisites still come from the catalog.
BINLOG selections remain separate. Adding a case to this variant requires an
explicit group assignment; planning fails if the assignment is missing.

Group mode uses coverage binaries by default, as CI does. Add `--no-coverage`
for normal binaries. Add `--skip-build` only when the required images already
exist. Use `--lab .build/debug/replicator-lab` to use a built runner for planning
and execution. Without this option, commands use `swift run replicator-lab`.

Repeat `--group`, `--profile` or `--variant` in `ARGS` for several values.
The default is all profiles and all variants in the CI plan. The
`--dml-transport sql|binlog` option filters existing groups; it does not create
new transport combinations. BINLOG group names start with `binlog-`. These
supplemental groups can have different case lists from the SQL groups.
For example, selecting a SQL-only group with `--dml-transport binlog` fails.
Unknown names and filter combinations with no matching groups fail before setup.

Group mode does not accept `--case` or `--family`: use the catalog commands above
for those selections. Benchmark options apply only when a performance group is
selected. The CI benchmark policy is report-only. Use `--enforce-ratio` to fail
when the ratio exceeds the limit. Data and checkpoint failures still fail in
report-only mode.

Plans contain exact commands, selected groups, dependency case IDs and reasons
for excluded groups. `catalog_not_applicable` retains the full catalog's
inapplicable cases and reasons; group filters do not narrow this reference list.
Local runs execute groups in sequence and stop at the first failure. Test output
goes to stderr; the JSON plan stays on stdout. CI runs its groups in parallel.
The `GROUP` interface is in Make and `tools/lab_groups.py`, not the Swift CLI.

The Makefile no longer exposes `integration-smoke`, `reverse-correctness`,
`reverse-suite`, `native-ddl-suite`, `native-smoke`, `native-suite` or `live-suite`.
Use `lab-test` with a suite and profile for current integration checks. Use
`lab-plan ARGS="--selection pr --commands"` to inspect the explicit PR baseline.
The native-only and live-capture CLI reference runners remain available for
separate investigations; this Makefile cleanup does not remove their assertions.
`ubuntu-smoke` and `upstream-tests` remain separate installation and upstream
source checks. Build, package, unit, coverage and parser targets also remain.

## Plan a selection before running it

`make lab-plan` reads the case catalog and prints JSON. It does not start
containers. It uses a built lab binary when you provide `--lab`; otherwise it
uses `swift run replicator-lab` to read the catalog.

```sh
make lab-plan PROFILE=mysql57-to-mysql57-innodb ARGS="--family indexes --case database-existing-different"
make lab-plan ARGS="--selection pr"
```

Repeat `--family` or `--case` to select their union. Repeat `--profile`, `--suite`
or `--variant` to select several values. The defaults are all profiles, the
correctness suite and the default variant. Use `--variant all` for all variants.

The plan lists `requested_cases`, `dependency_cases` and the final ordered
`cases`. `required_by` identifies the cases that need each dependency. Excluded
cases retain their profile-specific reasons. Unknown selections fail instead of
silently selecting a larger or smaller test set.

Plans also include `feature_catalog`. It assigns each suite/case identity to one
primary feature. Each execution group lists its `features`. The feature catalog
covers the queried catalog, including excluded cases; the group's `cases` list
shows what will run. Cases that contain several operations keep one primary
feature and retain their original descriptions and assertions.

`tools/test_features.json` holds the assignments and documentation references.
MySQL feature names follow the Reference Manual. Application behavior, such as
archive replay and runtime control, uses `kind: project` and a project guide.
The reference version documents terminology; it does not claim that all cases
apply to that server version. Existing profile exclusions still control selection.

```sh
make lab-plan ARGS="--suite all --variant all" | jq '.feature_catalog.definitions[] | {id, title, reference}'
```

Local and CI plans use the same ownership check. Missing or duplicate assignments
fail before a test starts. A full CI plan also rejects assignments for cases
absent from the complete catalog. These fields currently describe features;
existing families and group names remain in use during consolidation.

`tools/test_case_migrations.json` records each retired case, its replacement,
its original profile/variant/transport selections, and the assertions that keep
its test conditions. Planning rejects missing replacement assertions. Full CI
planning also checks that each replacement runs in the original selections.
For metadata migrations, `retained_cases` also requires the separate DML owner
and cache workflow in each original selection. A manual selection can run only
the metadata case.
These checks do not prove that two tests have the same behavior. Each migration
also needs a review of its SQL, expected results and measured code coverage.

`ddl-compat-generated` replaces the replicated `matrix-generated` case. It checks
multirow INSERT, NULL propagation, UPDATE and DELETE with stored generated
columns. It retains its virtual-column and ALTER checks. The three migration
assertions save SQL, expected values and observed values from the source, native replica
and target. `metadata-columns-indexes` checks the saved generated expression
for an existing table. A selection of a retired ID fails and names its replacement.
See [the consolidation plan](../PLAN/BETA7_TEST_SUITE_CONSOLIDATION.md) for the
comparison results and coverage review.

The generated-column cases use source batches and final checks. The basic case
uses one body batch. Separate tables retain the initial NULL values, updated
values, values after ADD, and the NULL row before its final DELETE. Final checks
also verify STORED and VIRTUAL metadata. The complete schema and row comparison
runs on source, native and target.

`ddl-compat-generated-expressions` uses three body batches around its two
deliberate restarts. Retained tables keep the original expression values and the
NULL inputs before later updates. Final checks cover the LIKE copy and the last
DELETE too. The snapshot includes all generated columns, including date and
binary expressions. Offline replay still stops after transaction three, then
resumes with an unreachable source and checks the retained results again.
Cleanup follows replay and the saved-state checks.

Run both cases in one fixture with coverage:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-generated --case ddl-compat-generated-expressions --coverage"
```

The basic case has no offline replay sequence. It remains in the
`without-source-gtids` selection. All four profiles keep these case IDs and CI
assignments.

Each `groups` entry is one lab invocation, not one CI job. It includes a command
that runs its cases. Add `--commands` to print shell commands instead of JSON.
Add `--skip-build` only when you want those commands to reuse a matching lab image.
The named `pr` selection uses the current reviewed PR case list and coverage
mode. Native and recovery adapters require complete case groups.

The local planner and CI share the dependency resolver in
`tools/lab_selection.py`. CI assigns complete execution groups to jobs with a separate policy. See the [test organization plan](../PLAN/BETA7_TEST_ORGANIZATION.md)
for the next changes.

For local timing, assertion and coverage comparisons, use the
[local comparison guide](LOCAL_TEST_COMPARISON.md). It supports existing results
and new measurements with prebuilt images.

## Evidence and code coverage

`artifacts/lab/RUN_ID/result.json` records the selected matrix and overall outcome.
Shared runs store per-profile `cases.json`, per-step SQL/observations, `runtime.json`,
logs, SQLite/relay state and final `result.json` beneath that directory.
The harness also writes `sql-trace.jsonl`. It links SQL client calls to active
case IDs, assertion IDs and server roles. See [SQL records for each test case](CI_MEASUREMENTS.md#sql-records-for-each-test-case)
for the scope and report command. The trace can contain credentials and row data.
Failure artifacts include source boundaries/binlogs when available. Adapter suites retain
their established artifact categories; the runners provide their own evidence paths to the aggregate, keeping concurrent
runs separate.
The native adapter lists registered cases; reverse recovery and other specialized
adapters explicitly report suite-level inventory.

For shared correctness, lifecycle and performance, `--skip-build` reuses `mysql-replicator-packaging:lab` only if its input fingerprint
matches the checkout. All profiles use the same pinned image in a combined run. Changing fixture or
implementation inputs during qualification fails the aggregate.
For `correctness`, `lifecycle`, `performance`, and MyISAM `recovery`, `--coverage` builds the instrumented image and exports each profile's coverage
separately. Merge explicitly selected reports with the existing `make coverage-report`
command. Its published runtime views exclude `ReplicatorLab*`; a separate harness
view uses only unit-test coverage. Raw per-fixture collections remain available
for provenance and migration comparisons. A combined line-coverage number does
not replace per-profile scenario results.
Instrumented timings include coverage overhead. Do not compare them with production binary timings. Specialized adapters retain
their original image tags and build controls; build those suites before reusing
their images with `--skip-build`.

The PR baseline runs unit tests, Periphery and two explicit correctness selections. The
profiles are `mysql84-to-mysql57-myisam` and `mysql57-to-mysql84-innodb`.
Both use the default variant and run in parallel after one shared image build.
Unit tests and Periphery reuse the common build and run in parallel with
integration tests. Coverage and timing reports remain enabled. This scope does
not build release packages or run the full catalog.
Each integration job runs 11 named cases in the `ddl-dml-policy-replay` area.
See [PR test selection](PR_TEST_SELECTION.md) for case IDs, assertions, timing
estimates, limits, and commands to reproduce the selection.
Documentation, listed report tools, and test selectors use Python checks without
an application build. `Makefile` and `ci.yml` use the two-profile PR checks.
Exact component paths add matching groups from the full catalog. These use
`pr-selected` scope and keep applicable profiles, variants and BINLOG tests.
Shared runtime code, dependency/package builds, shared fixtures, other workflows,
and unknown paths select full CI. The same changed-file
rules are available locally through `make test-selection` and `make test-selected`.

PRs with the `ci-full` label and manual runs with `suite=full` use the full catalog.
Main builds production packages and runs short production-binary checks.
See [release testing](RELEASE_TESTING.md) for the stack workflow and evidence.
Correctness and
source/target reconnect run for all default profiles, plus the forward
`position-minimal` and `gtid-full` capture variants. Demo, reverse recovery and
the applicable native-reference DDL suite run in the same workflow. There is no
separate weekly or release-tag qualification workflow.

The lab catalog generates both matrices. PR planning resolves the explicit
`pr_smoke` case IDs in `tools/ci_matrix.json` against the full catalog and adds
prerequisites. New cases do not enter the baseline automatically. They enter component checks
when they belong to a selected family or complete execution group.
Full CI collects coverage from each apply group. It does not add separate
coverage copies of the PR baseline. Local `--tier smoke` is a separate convenience
selection; it does not select the same cases as PR CI.
`tools/ci_matrix.json` assigns full CI cases to shared-fixture feature groups.
An area with an explicit `cases` list can select related cases across DDL, DML
and index families. Those cases have one explicit owner. Remaining cases keep
their family area. New cases normally extend an existing named group. Unknown
cases, duplicate owners and missing named-group assignments fail planning.

The generated `ci-lab` artifact contains `matrix.json`, with all obligations,
not-applicable entries and exact group selections in `include`. Each applicable
obligation has one owning group; prerequisites can also run in dependent groups.
The planner preserves catalog order within each group.

`tools/ci_jobs.json` assigns exactly one execution group to each job. All cases
in that group reuse its MySQL containers and environment setup. Bootstrap state
isolation and required restart/replay operations remain explicit test steps.
A job does not run a second fixture group. The `growth_check` report models one
extra profile or one extra source variant without adding either to the test run.
See [execution groups and CI jobs](CI_MEASUREMENTS.md#execution-groups-and-ci-jobs)
for group scope, budgets, coverage counts and time limits.

Jobs show profile, area, capture variant and image type. Up to 16 jobs run in
parallel. Ordered scenarios and the forward failure → recovery → offline/control
sequence stay together. CI builds the lab once and each applier image once.
Test jobs pull images from GHCR by digest; fork PRs use checksummed image archives.
Release jobs verify they use the packaged binary. See [CI build caching](CI_BUILD_CACHE.md).

Generate and inspect the same plan locally:

```sh
swift build --product replicator-lab
CI_SUITE=pr-smoke python3 tools/ci_lab.py --plan .build/debug/replicator-lab
jq '.include[] | {profile, variant, area, suite, cases}' artifacts/ci/matrix.json
```

Use `CI_SUITE=full` for the pre-merge full plan. It is also the local default.
Use `CI_SUITE=production` to inspect the two post-merge package checks.
The manifest and timing report identify the scope. A complete smoke report means
that all selected smoke obligations passed. It does not certify all profiles.

Reproduce a shard with the usual `make lab-test PROFILE=...` command
and its `ARGS="--suite ... --variant ... --case ..."` selections. Only correctness
and lifecycle accept `--variant`. Lifecycle and demo also accept named cases.
Omit case selectors to run all cases in those suites. Specialized adapters run
their complete suite.

The forward negative suites archive the native reference's error and the source
boundary before reseeding that disposable reference past rejected transactions.
Applier failure states remain intact. To check the recovery-to-offline transition locally:

```sh
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--case myisam-recovery --case offline-replay --case runtime-control"
```

CI uploads each shard's evidence separately. Published code coverage combines
unit tests with instrumented smoke runs. Full CI adds sample and demo coverage.
Full correctness and reconnect
runs use the release image and do not contribute to line coverage.
See [coverage reports and publication](../CONTRIBUTING.md#code-coverage) for PR
comments and downloading the HTML/LCOV reports linked from the README.
Publishing does not require GitHub Pages.

## Interactive demo

Select one profile explicitly. Each has a separate retained session:

```sh
make lab-demo PROFILE=mysql57-to-mysql84-innodb ACTION=up
make lab-demo PROFILE=mysql57-to-mysql84-innodb ACTION=start
make lab-demo PROFILE=mysql57-to-mysql84-innodb ACTION=sql ARGS=examples/lab-demo.sql
```

Use `ACTION=status`, `compare`, `stop`, or `down`. `up` prints SQL-shell commands
and the generated YAML configuration. Repeating `up` repairs a missing idle
container while preserving its pinned image and saved state. `down` archives
state and removes only that disposable session. Pause source writes for comparison.

`compare` verifies `demo.items` (when present) and the preloaded `reverse_poc.items`
and `reverse_poc.aux`, including schema, expected engine differences and checkpoints.
It reads SQLite in its Docker volume after the completed boundary without
interrupting either a foreground or detached writer. The example also creates `lab_example` through replication;
inspect it in the printed shells or use the correctness suite for automated DDL
assertions. The fixture database name is retained across profiles for shared SQL.
Audited `inspect`/`resolve` actions are available only for the InnoDB profile.

The [forward workbook](../PLAN/DEMO_WORKBOOK.md) and
[reverse workbook](../PLAN/REVERSE_DEMO_WORKBOOK.md) use these same commands for
multi-terminal experiments. Both MyISAM profiles also provide `fail`, `skip GTID`
and `compare --expect-blocked` actions for their controlled explicit-engine rejection.

For instrumentation, create the session with `ACTION=up ARGS=--coverage`.
Coverage mode and the image are pinned in `artifacts/demos/PROFILE/current.json`;
subsequent commands preserve that choice. `down` drains the writer and exports
coverage before archiving/removing its volume. Recreate sessions made before this
migration to obtain the SQLite-equipped demo image; retained sessions never rebuild
or switch their image implicitly.

## Comparable benchmarks

The `performance` suite has one case: `backlog-10k`. It applies 10,000 single-row
INSERT transactions. It compares all target rows with the native replica and
checks the saved GTID checkpoint. It then checks the ratio of replicator elapsed
time to native elapsed time. The default limit is **2.0**. A ratio equal to the
limit passes.

```sh
# All four profiles, SQL transport, enforce the limit.
make lab-performance ARGS="--max-native-ratio 2"
# All four profiles, BINLOG transport, allow a result above the limit.
make lab-performance ARGS="--dml-transport binlog --report-only"
```

Use `PROFILE=<profile>` for one topology. Use `--case backlog-10k` to select the
case by name. `--report-only` changes only the time limit check. Row differences,
checkpoint errors, timeouts, and setup or cleanup errors still fail the test.
The evidence retains `over_limit` even when report-only mode accepts the run.

Full CI runs eight jobs: four profiles × SQL and BINLOG transport. Each job uses
one fixture. It runs native replication first, then the replicator. Image download,
fixture setup, workload generation, final comparison, and coverage export are
outside the measured replay intervals. Startup and polling are inside them.
The native replica uses the source MySQL version and the profile's target engine.
Thus, a cross-version comparison is not a comparison of identical server versions.

CI starts with a provisional 2× limit and report-only mode. Change
`performance` in `tools/ci_matrix.json` to set the limit and policy. CI uses the
coverage binary, as do other integration tests. These times include instrumentation
overhead. Use a separate non-coverage run to assess production performance.
Run local comparisons sequentially. Do not run other database tests at the same time.

Results appear in `artifacts/lab/<run>/`, each CI job summary, and the combined
CI measurement report. They include both elapsed times, the ratio, the limit,
the policy, transport, and coverage status. Add `--coverage --skip-build` to
reuse a coverage image that matches the current build inputs.

Backlog benchmarks accept `--dml-transport sql|binlog`. SQL is the default.
The workload, native reference, and timing method are the same for both modes.
The result records `dml_transport`. Run comparisons sequentially to avoid CPU
and disk contention between fixtures. Streaming and capture benchmarks do not
accept this option.

```sh
make lab-benchmark PROFILE=mysql84-to-mysql57-myisam ARGS="--events 10000"
make lab-benchmark PROFILE=mysql57-to-mysql84-innodb ARGS="--events 10000"
```

Both use `--mode backlog --workload insert`: generate a fixed backlog, replay it
through native replication and the external applier sequentially, verify final
rows/checkpoints, and record wall time, target counters and stage timings. Startup
and polling overhead are included. `--workload multi-table-transaction` is an
explicit InnoDB-only experiment, never silently substituted for `insert`.

Backlog profiling controls keep the historical defaults: `--applier-profile on`,
`--decoder-profile off`, and `--batch-transactions 8`. For a detailed 10K run:

```sh
make lab-benchmark PROFILE=mysql57-to-mysql84-innodb ARGS="--events 10000 --decoder-profile on"
```

Repeat with `--skip-build --applier-profile off --decoder-profile off` to measure
without detailed profiling. `--batch-transactions 32` changes the execution batch
limit and scales the journal preparation window; InnoDB still commits each source
transaction separately. The 25 ms age limit can produce smaller batches. Results include `stage-timings.json`,
optional `applier-profile.tsv` / `decoder-profile.tsv`, server durability settings,
and native/target binlog boundaries. `apply.detail.transaction.begin` and
`apply.detail.transaction.commit` include the SQL round trip; `capture.schema_wait`
measures time waiting for historical schema interpretation in the apply loop.

For server-side SQL profiling, add `--server-profile on` (backlog mode only;
default off). This enables timed Performance Schema statements, SQL stages,
transactions and waits on the disposable native and target servers. It writes
`server-profile-{native,target}.json`, sorted `.tsv` reports, and instrument
settings. Target foreground counters use the `apply_fixture` user, retaining
results after disconnect; native foreground counters use its new SQL/worker
threads. File I/O is server-wide and includes background redo work. Background
waits include idle time. These are nested elapsed timers, not additive CPU costs;
file `misc` includes sync and other operations, not just fsync. Autocommit commit
work appears inside INSERT execution and server commit stages, not a separate
client COMMIT. No durability settings change.

```sh
make lab-benchmark PROFILE=mysql57-to-mysql84-innodb ARGS="--events 10000 --applier-profile off --server-profile off"
make lab-benchmark PROFILE=mysql57-to-mysql84-innodb ARGS="--skip-build --events 10000 --applier-profile off --server-profile on"
```

Compare profiling off/on to assess overhead. Statement and stage names differ
between native row replication and SQL clients, and the reverse reference is
MySQL 5.7 while the external target is 8.4. The gap between client `target.sql`
and server statement time includes scheduling, protocol and transport overhead;
it is not a direct measurement of network latency. `target.connect`,
`capture.resolve`, `capture.connect` and `capture.preflight` separately time
connection and source setup before useful replay work. `capture.shutdown.receiver`,
`capture.shutdown.connection` and `capture.shutdown.event_loop` measure teardown
in the final apply timings. Snapshot queries run outside
the timed replay windows and use the separate root observer account.

The application and benchmark default to eight source transactions per execution
batch. `batch.maximumPreparedBatches` accepts 1..16 and defaults to eight. It bounds
all submitted batches, including completed batches awaiting a checkpoint. One
slot retains overlap of row planning but serializes durable preparation with
completion. `batch.overlapPreparation: false` also disables coordinator planning
overlap at batch handoff and uses one slot.

With four or more slots, the coordinator collects a preparation window of up to
half the queue capacity, shares one relay sync and one FULL SQLite commit across
that window, then submits its execution batches in order. For example, eight
slots and eight transactions per execution batch can prepare four batches (32
source transactions) together. The existing row, byte, age and table-change
limits apply to the whole preparation window; a single oversized source group
still runs alone. DDL, schema, stop and reconnect barriers retain their ordering.
Published completions can also share one SQLite checkpoint commit. Larger queues
increase the bounded set of durable intents that can remain pending after a crash.

For a backlog comparison with the same binary, use `--prepared-batches 2` and
`--prepared-batches 8`, keeping `--batch-transactions 8` and profiling settings
unchanged. This controls durable preparation and queue depth, not the number of
target connections or InnoDB source transactions committed together. MyISAM
INSERT coalescing remains bounded by each execution batch. Timer and size limits
can produce smaller batches.

The final summary's `applyQueue` reports the current target session's queue
capacity, maximum outstanding batches, executed/unissued batch counts, and
worker `busySeconds`, `idleSeconds`, and `spanSeconds`. Span covers the first
batch start through the last completed batch, excluding startup before the first
batch and shutdown afterward. Idle includes any gap between batches, including
source starvation and DDL barriers; it is most useful on a DML-only backlog.
Busy includes target execution and its checks. These are elapsed durations,
not CPU measurements. While execution is active, busy time includes only
completed batches and idle time includes gaps preceding batches already started.

The decoder caches those interpretations by database, table and wire column
metadata. `capture.schema_cache.hit` / `.miss` report reuse; a repeated numeric
table ID alone is insufficient. DDL, new format contexts and skipped ranges
invalidate the cache; reconnect creates a new cache. Retention uses
`maximumCachedTables` (default 6,000 entries). Eviction causes a fresh ordered
lookup. Checksums,
table-map decoding and consumer-side schema validation still run for each map.
The live/offline stream reuses the codec's validated format context for TABLE_MAP
probes. With no table filter, each included map uses one metadata probe and one
normal decode that installs the resolved schema. With a filter, an identity probe
runs first so excluded tables can retain opaque unsupported columns. Probes do
not advance the decoder or change its live table cache; framing/CRC and schema
checks remain enforced. The old per-map `decode.call.probe_format` calls disappear;
`decode.call.probe_identity` is needed only when a table-filter callback is present.
GTID UUID text is cached for the last source SID, with byte comparison on each GTID.

Apply/replay carry raw event bytes directly to the relay writer. External inspection
output still uses Base64 when requested; the internal byte buffer is not a JSON
field. Decoded-queue byte accounting includes that buffer. Existing relay files
and recovery/inspection formats are unchanged.

Timers from different workers overlap. Inclusive and self times are elapsed time,
not CPU time, and must not be summed as end-to-end duration.
See the [reverse InnoDB investigation](../PLAN/REVERSE_INNODB_PERFORMANCE.md)
for the 10K measurements, native binlog behavior, and proposed optimization order.

The historical forward sysbench streaming and blackhole capture experiments are
available with `--mode streaming` and `--mode capture`, respectively. These are
separate measurements and are currently unavailable for the 5.7-source profiles.
All modes require one explicit profile. For example:

```sh
make lab-benchmark PROFILE=mysql84-to-mysql57-myisam ARGS="--mode streaming --events 10000"
make lab-benchmark PROFILE=mysql84-to-mysql57-myisam ARGS="--mode capture --events 10000"
```

Streaming/capture retain their transport and tuning options from the
[benchmark guide](../PLAN/PERFORMANCE_BENCHMARK.md), and share a dedicated forward
measurement fixture rather than the interactive demo implementation.
Backlog evidence lives in `artifacts/lab-benchmark/PROFILE/`; historical measurement
adapters retain their original categories. Do not compare timings across different
workloads, modes, instrumentation, durability settings or transports as applier
speed alone.

## Adding a profile

Production `ReplicationProfile` selects a `SourceContract` and a target engine/version
contract independently. The lab declares the same topology in `LabProfile` and its
Compose overlay. `LabMySQLVersion` supplies server administration SQL; engine
capabilities select rollback, failure and recovery expectations. Add the profile
to these registries, then run the existing catalog. Do not copy a suite.

The full CI matrix is generated from this catalog. New profiles automatically receive
applicable correctness, lifecycle and demo jobs; update `tools/ci_matrix.json` for
the expected demo coverage report count. Keep version-specific exclusions explicit.
The 5.7 MyISAM profile reuses MyISAM recovery and the GTID demo resume workflow.
8.4 optional-metadata refusals, 0900 translation and the historical 8.4-specific
failure group do not apply. Streaming/capture benchmarks remain 8.4-only; the
shared backlog benchmark supports all profiles.

See [5.7 MyISAM setup](MYSQL57_MYISAM.md) for deployment boundaries.

## CI cost and coverage reports

See [CI measurements](CI_MEASUREMENTS.md) for case and shard timing, profile
catalog results, line coverage, and test-area cost comparisons.
The same catalog drives selected PR checks, full tests and production checks.
All selected apply tests collect coverage. Main runs small package checks. These measurements do not change the supported
profiles or assertions.

## Support requirements

Use `make ddl-catalog-check` to validate the DDL and support inventories. Use
`make ddl-catalog-report ARGS="--format json"` to inspect the `support` section.
It separates specific tool gaps, target limits, native restrictions, policies and
incomplete tests for the four profiles. `untested` means not fully tested; selected
cases can already pass. The summary counts confirmed tool gaps and incomplete
test groups separately. These are inventory counts, not a support percentage.
Code coverage measures executed code, not MySQL feature support.
The audit is partial. Candidate tests do not qualify a requirement. Implementation
status and exact-build qualification are separate. See
[status definitions](SUPPORT.md#support-status).
See [the catalog guide](../tests/DDLCoverage/README.md#beta6-support-audit).

`matrix-enumzero` distinguishes ENUM ordinal zero
from a declared empty-string label. It checks multirow INSERT, ordinal changes,
NULL, primary-key changes and DELETE on all four profiles. Preparation and body
batches share one running applier. Three retained tables keep the results after
INSERT, UPDATE and DELETE. Final queries compare numeric ordinals and hex bytes
together; both ordinal zero and the declared empty member have empty bytes.
The original scripts keep their own non-strict SQL mode after each session reset.
All four original predicates and FULL metadata remain. Cleanup drops only the
retained tables. The shared fixture
also restarts from saved state and verifies a write to reverse_poc.aux. The
former `matrix-reject-enum-error-value` case is removed. Ordered-label and
missing-label refusal cases remain.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-enumzero --coverage"
```

The [ENUM and SET workflow review](../PLAN/BETA7_ENUM_SET_WORKFLOW_REVIEW.md)
maps the seven value cases, ordered labels, exact bytes, defaults and ordinal
boundaries. It keeps all seven IDs and their version limits.

`matrix-choices` uses preparation and body batches with one running applier.
Two retained tables keep all five inserted rows and the result after UPDATE.
Final queries compare ENUM ordinals and bytes, unsigned SET masks, empty members
and NULL fields. They retain the apostrophe label, comma label and UTF-8 value
which the final DELETE removes. The case keeps all three original predicates,
the original scripts and FULL row metadata. Cleanup drops only the two retained
tables. The case adds no applier restart.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-choices --coverage"
```

`matrix-widechoices` uses the same workflow with two retained tables. Final
queries check ENUM ordinal 256 before UPDATE and 255 afterward. They also check
the full 64-bit SET mask, the high bit and exact label bytes. A separate query
requires the original table to be empty after DELETE. The case keeps all 256
ENUM labels, 64 SET members, original scripts and FULL metadata. Cleanup drops
only the retained tables.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-widechoices --coverage"
```

`matrix-exactchoices` uses the same workflow with three retained tables. Final
queries check utf8mb4, latin1 and utf16 label bytes, ENUM ordinals, unsigned SET
masks and NULL fields. They also check numeric versus quoted defaults before
and after ALTER, the added SET default and primary-key reuse. Row queries use
the original `id+0` ordering. The helper requires an explicit matching order
setting; it does not accept arbitrary SQL expressions. All four original
predicates, original scripts and FULL metadata remain. Cleanup drops only the
retained tables.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-exactchoices --coverage"
```

`matrix-choiceboundaries` uses the same workflow with two retained tables. Final
queries check trimmed and escaped ENUM labels, UTF-16LE, UTF-32 and gb18030 bytes,
empty members, empty SET values and NULL fields. They compare the high-bit and
maximum 64-bit SET masks as unsigned decimal values. A separate query checks
default bytes and declared SET member order. All three original predicates,
original scripts and FULL metadata remain. Cleanup drops only the retained
tables. All seven ENUM/SET value cases now use the shared workflow.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-choiceboundaries --coverage"
```

`matrix-zerofill` checks integer display widths,
implicit UNSIGNED, padded defaults, numeric boundaries, ALTER and DML. The
included-DDL refusal case uses an explicit engine outside the selected profile.
This keeps a real policy failure after ZEROFILL becomes supported.

The `matrix-collations` case tests 63 MySQL
5.7 collations for utf8mb4, utf8mb3, latin1 and ASCII. Preparation and body batches
share one running applier. Three retained tables keep initial defaults, updated
bytes and the schema after MODIFY. Final queries compare all 63 member fields,
stored key case, NULL values and numeric collation mappings across source,
native and target. The case keeps the original four predicates and scripts.
It checks c49 at ID 49 before MODIFY and ID 94 afterward. Cleanup drops only
the retained tables. The case adds no applier restart. It does not test every
language-specific sort rule.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-collations --coverage"
```

The `matrix-nativeencodings` case adds the
remaining 36 native 5.7 text encodings. It checks raw CHAR/VARCHAR/TEXT bytes,
encoding-specific CHAR padding, NUL, defaults, NULL and DML/DDL phases. A UTF16
primary key checks binary parameter conversion in key predicates.
Preparation and body batches share one running applier. Three retained tables
keep defaults, updated byte vectors and the result after ADD COLUMN. Final
queries check all 108 original fields, UTF-16 key bytes, numeric collation IDs
and the added four-byte gb18030 value. The original scripts and four predicates
remain. Cleanup drops only the retained tables. The case adds no applier restart.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-nativeencodings --coverage"
```

The [inventory workflow review](../PLAN/BETA7_NATIVE_ENCODING_INVENTORY_REVIEW.md)
records every selected collation ID and character-set byte vector. It defines
the conversion steps and focused results for both cases. Both definitions remain
inputs to metadata-discovery tests.

The `floatingauto*` DML cases test native 5.7 floating-point AUTO_INCREMENT.
The DML cases and their metadata definitions run on both 5.7-to-5.7 profiles. The inventory gives
native error 1063 as the exclusion reason for a profile with an 8.4 source or target.
The common selection code and both execution paths use these profile exclusions.
The four IDs belong to the existing data-types-values group. They share its
fixture and ordinary applier with the other applicable cases. No separate
profile or CI job is required.

All four declarations use the same batch template. Three retained tables per
case keep the INSERT, key-change and ALTER results. Final comparisons check all
rows, explicit zero, generated IDs after a high explicit ID, fractional keys,
the added default, AUTO_INCREMENT attributes and each table's next generated
value staying above the retained keys. Reserved gaps are permitted. Original
scripts and predicates stay intact. Cleanup drops only retained tables. This
conversion adds no restart and keeps the cold metadata inputs.

Select only these four cases in one 5.7-to-5.7 MyISAM fixture with:

```sh
make lab-test PROFILE=mysql57-to-mysql57-myisam ARGS="--suite correctness --case matrix-floatingautofloat --case matrix-floatingautodouble --case matrix-floatingautofixedfloat --case matrix-floatingautounsigneddouble --coverage"
```

The source session uses `NO_AUTO_VALUE_ON_ZERO` for every request. The case
therefore keeps an explicit zero separate from a generated AUTO_INCREMENT ID.

The `lowercase-tables` variant starts all three MySQL servers with
`lower_case_table_names=1`. Use `--case ddl-compat-table-name-case` to check
mixed-case database/table references, native lowercase storage, LIKE, RENAME,
row events and restart. This is separate from the default mode-0 Unicode case.

Selected table-option and conversion checks:

```sh
make lab-test ARGS="--profile mysql57-to-mysql84-innodb --suite correctness --case ddl-compat-table-options --case ddl-compat-alter-conversions"
```

These shared cases check comments, row format, AUTO_INCREMENT, CREATE LIKE,
selected cross-family column conversions, following row changes and restart.
They apply to all four profiles. Other physical options and conversion pairs
need separate qualification.

`ddl-compat-multi-table` checks cross-schema moves, swaps, DROP lists, name
reuse and saved schema retirement. `ddl-compat-cross-schema-relationships`
checks parent/child moves and ordered DROP. InnoDB profiles also check a
foreign-key cascade. MyISAM profiles use the same table layout without FKs.
Both cases include saved-state restart.

```sh
make lab-test ARGS="--profile mysql57-to-mysql84-innodb --suite correctness --case ddl-compat-multi-table --case ddl-compat-cross-schema-relationships"
```

### Partition cases

Select `ddl-compat-subpartitions` for subpartition metadata and data-changing
DDL on all four profiles. It also tests restart and offline replay through a
TRUNCATE boundary. Select `ddl-compat-partition-hash-forms` for named HASH/KEY
partitions, ADD counts and implicit KEY columns. See
[partition scope](../PLAN/PARTITION_SUPPORT.md) for limits and native references.

`ddl-compat-partitions` checks RANGE COLUMNS, DROP, TRUNCATE, REORGANIZE,
EXCHANGE WITH VALIDATION, following UPDATE and REMOVE PARTITIONING.
`ddl-compat-hash-list` checks HASH, COALESCE, repartitioning to KEY and LIST,
and INSERT into an added LIST partition. Each case uses one source body batch.
Separate tables retain the earlier row and partition states for final queries
and a full schema/row comparison. Both sides of EXCHANGE remain visible.
Source operations keep their separate transaction boundaries. The cases retain
the shared checkpoint, completed-DDL and saved-schema restart checks.

Run the pair in one fixture:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-partitions --case ddl-compat-hash-list --coverage"
```

Select `ddl-compat-partition-key-algorithm` to check KEY algorithm 1 row
placement, ALTER, CREATE LIKE, saved schemas and offline stop/resume. Select
`ddl-compat-partition-maintenance` to check logged partition administration,
unlogged CHECK and LOCAL operations, and DML after restart. All four profiles
use an InnoDB native reference for these partition cases. The external target
uses the profile engine.

Select `ddl-compat-partition-expressions` for computed partition bounds and
native metadata comparison. Select `ddl-compat-partition-exchange-unchecked`
for unchecked exchange, misplaced rows, the two-table journal and following
DML. Both cases restart the applier and use offline stop/resume. The unchecked
exchange case stops replay while the row is still in the wrong partition.

`ddl-compat-partition-column-bounds` checks binary RANGE and latin1 LIST
bounds, REORGANIZE, partition routing, DATE spelling, connection-charset
literals, explicit charset introducers, escaped and empty bytes, restart, and
offline replay. For single
binary-column fixtures, the harness reads raw SHOW CREATE bounds with its
own parser. It does not rely on the truncated I_S values that 5.7 can return.

`ddl-compat-column-index-syntax` runs on all four profiles. It checks inline keys,
grouped ADD, native index names, serial columns, index/execution options, following
row changes, saved-state restart and offline replay. Select it with
`--suite correctness --case ddl-compat-column-index-syntax`.

`ddl-compat-alter-table-rename` runs on all four profiles. It checks standalone
and compound ALTER renames, column changes, final-name selection, cross-schema
moves, restart and replay. InnoDB variants also check FK metadata and cascades.

`alter-rename-target84-refusal` runs on the 5.7 to 8.4 profile. It checks that
the native parent-rename defect stops before target SQL. It also checks the
saved checkpoint and unchanged target. This case runs after the normal writer
stops, so its intentional failure does not enter another case.

`ddl-compat-grouped-constraints` tests grouped FK and ignored CHECK clauses on
the three 5.7-source profiles. It also checks reserved index names, later rows,
restart and replay.

`ddl-compat-primary-key-parts` checks primary-key prefixes, updates within a
prefix, key replacement, column rename, CREATE LIKE, restart and replay.

The selected cases `ddl-compat-column-renames` and `ddl-compat-alter-options`
check translated column renames, ORDER BY and validation clauses. They include
later DML, saved-state restart and offline stop/resume. Column renames require
a MySQL 8.4 source.

The column rename workflow uses five retained table sets for final checks of
column definitions, encodings, generated values, index prefixes and defaults.
It keeps four saved-state restart points. Offline replay stops after transaction
three, immediately after the first compound RENAME COLUMN, then resumes with an
unreachable source. Live and replay results have separate named assertions.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-column-renames --coverage"
```

One fixture runs five source batches between the restart points. Setup and
cleanup each use one additional batch. Each source statement keeps its own GTID.
The final checks include exact row bytes and a complete `ddlcompat` snapshot.
Failure output identifies the assertion and the support-bundle path.

`target84-index-spatial-metadata` checks an existing 8.4 target with invisible
indexes and SRID constraints. `ddl-compat-absent-definers` checks invoker results
and native error 1449. Both include restart and offline replay.

### Column definitions and compound ALTER

`ddl-compat-types` and `ddl-compat-alter` share the fixture and running applier.
Each case sends its source operations in one batch. Independent tables retain
values and definitions that later UPDATE, DELETE or ALTER operations would
replace. Final queries compare those tables with the source and native replica.

The `types` case checks mixed defaults and exact row values. It also adds an
automatic DATETIME column at a fixed source timestamp. The phase runner resets
`SESSION timestamp=DEFAULT` before each operation, then runs the original SQL.
Thus, the following UPDATE uses current time and changes the automatic value.
The reset does not change the applier's target-session policy. Warning collection
still follows the source operation directly.

The `alter` case retains the original column definition, compound ADD/CHANGE
results, new defaults and indexes, and replacement composite primary key. It
then checks DROP COLUMN, DROP DEFAULT and DELETE on the original table. These
cases keep their saved-state checks. They add no deliberate restarts or replay.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-types --case ddl-compat-alter --coverage"
```

See the [assertion map and validation plan](../PLAN/BETA7_COLUMN_CONVERSION_WORKFLOW_REVIEW.md).

### Conversion of existing indexed values

`ddl-compat-alter-conversions` keeps its three deliberate applier restarts. Four
source batches convert and update the original table, then prepare six separate
tables that retain the intermediate INT, VARCHAR, DECIMAL, DOUBLE and BIT states.
The final queries check values, defaults, nullability and index-column names.
The shared snapshot compares every retained row and definition with native
replication, including the fractional row after its conversion to INT.

The retained INT table keeps ID 3. The original sequence later deletes that row,
so checking only the original final table would miss a wrong conversion. The
BIT table retains the state after DELETE. Cleanup follows the saved-state checks.
This case adds no offline replay.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-alter-conversions --coverage"
```

### Table options, index maintenance and ignored CHECK clauses

These cases stay in the `table-column-index-changes` group. They batch source
statements between required applier restarts. Each statement keeps its own GTID.
Separate tables retain results that later statements would change. The harness
compares rows and schemas at the end, with explicit queries for metadata that
the shared snapshot does not include.

| Case | Final checks |
|---|---|
| `ddl-compat-table-options` | Table and column comments, row format, defaults, source-assigned AUTO_INCREMENT IDs, CREATE TABLE LIKE, UPDATE and DELETE. |
| `ddl-compat-table-maintenance` | MyISAM nonunique-index state after DISABLE/ENABLE KEYS, writes with disabled keys, forced-index lookup, standalone FORCE and compound FORCE/ADD. |
| `ddl-compat-alter-options` | Accepted ORDER BY and validation clauses, virtual generated values, following UPDATE and DROP. The InnoDB variant also includes COMPRESSION and ENCRYPTION options. |
| `ddl-compat-ignored-checks` | Violating rows accepted by a 5.7 source, no target CHECK constraints, CREATE TABLE LIKE, later writes and the saved no-op DDL record. |

The first two cases keep two and three restart points respectively. The last
two keep two restart points each. Their offline replay stops after transaction
three, then resumes with an unreachable source. Live and replay checks have
separate assertion records. The CHECK case uses archive label `checks` and case
ID `ddl-compat-ignored-checks`.

Run the table-option and maintenance cases together on the forward profile:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-table-options --case ddl-compat-table-maintenance --coverage"
```

Run the ALTER-options and ignored-CHECK cases together on the reverse profile:

```sh
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite correctness --case ddl-compat-alter-options --case ddl-compat-ignored-checks --coverage"
```

The ignored-CHECK case excludes an 8.4 source because that source enforces CHECK
constraints. Run `ddl-compat-alter-options` separately on the forward profile
to check its MyISAM SQL branch. These tests do not prove physical row ordering,
effective compression or encryption, or rejection of invalid generated values.
See the [assertion map and local validation plan](../PLAN/BETA7_TABLE_OPTIONS_WORKFLOW_REVIEW.md).

### Simultaneous column renames

Select `ddl-compat-column-swaps` to test CHANGE swaps and rename chains on any
profile. The case checks key identities, FIRST/AFTER placement, new columns,
generated expressions and following DML. `ddl-compat-column-renames` also tests
a RENAME COLUMN swap from MySQL 8.4.

Select `ddl-compat-foreign-key-column-swaps` on an InnoDB target to test parent,
child and self-reference swaps. The case checks cascades and FKs added during
the swap. These cases include saved-state restart and offline replay with an
unreachable source. See [scope and limits](../PLAN/SIMULTANEOUS_COLUMN_RENAMES.md).

### Partition-column renames

Select `ddl-compat-partition-column-renames` on any profile. The case checks
CHANGE with replacement/removal of partitioning, subpartitions, swaps, implicit
KEY(), row movement and later DML. Select `ddl-compat-partition-rename-syntax`
on the forward profile to check RENAME COLUMN translation. Both cases include
saved-state restart and offline replay. See
[scope and results](../PLAN/PARTITION_COLUMN_RENAMES.md).

### Executable comment cases

Select `ddl-compat-executable-comments` for active comments, literal preservation,
DML, restart and replay on all four profiles. Add
`ddl-compat-executable-comments-target-gate` for a whole statement ignored by the
5.7 target, and `ddl-compat-executable-comments-source-gate` for comments disabled
by a 5.7 source. The latter includes the 8.4 target. The tests compare the saved
source and target SQL and check native gate outcomes. See
[the implementation contract](../PLAN/EXECUTABLE_COMMENTS.md).

The main case uses three source batches and retains its earlier UPDATE result
in `executable_comment_results`. The two version-specific cases each use two
batches. All four original restart points remain. Replay stops after transaction
two in each case, then resumes through 13, 4 and 4 operations respectively.
Final queries run again after replay. Journal checks use the original source
GTIDs and require unchanged logged SQL. Named checks record the different
TABLE_COMMENT values on source/native 8.4 and target 5.7.

Run the forward pair in one fixture, and the source-version case on reverse:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-executable-comments --case ddl-compat-executable-comments-target-gate --coverage"
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite correctness --case ddl-compat-executable-comments-source-gate --coverage"
```

The forward pair shares containers. Only the main case needs retained-database
cleanup. Profile exclusions and all eight applicable CI selections remain.
See [the conversion results](../PLAN/BETA7_EXECUTABLE_COMMENT_WORKFLOW_REVIEW.md#implementation-and-focused-results).


### Table character set and collation workflows

`ddl-compat-table-charset` uses three source batches. Retained tables keep the
column collations and row bytes from before later ALTER and DELETE statements.
It checks both orders of ADD COLUMN and table-default clauses, existing column
encodings, LIKE inheritance and inserted defaults.

`ddl-compat-compound-charset` also uses three batches. It checks that CONVERT
uses its own collation while a later table default applies to a following ADD
COLUMN. A retained table keeps the earlier two-column metadata available.

The pair keeps four deliberate restarts and all seven original query checks.
Cleanup removes only the retained tables. These cases use ordinary compatible
collations; they do not enable a translation policy. The DEFAULT-syntax,
encoded-query and column-conversion cases remain separate selections.

Run the pair in one forward fixture:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-table-charset --case ddl-compat-compound-charset --coverage"
```

See [the character-set workflow results](../PLAN/BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#first-slice-implementation-and-focused-results).

### Column character set conversion

`ddl-compat-charset-conversion` uses four source batches and three deliberate
restarts. It keeps the original ten operations first. Three retained tables
repeat earlier operations to keep their results available for final queries.
The checks cover TEXT widening, inserted defaults, ENUM/SET labels, generated
values and binary bytes. They also check that a later CONVERT does not turn
binary columns back into text, and that DELETE removes the second row.

The case keeps FULL row metadata. Final queries retain all six original result
checks. A full schema, index and row comparison includes all four tables.
Cleanup drops only the three retained tables after saved-state checks. The
case does not add an offline replay path.

Run the case on forward MyISAM:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-charset-conversion --coverage"
```

Retaining earlier results adds five native CONVERT statements. Compare elapsed
time as well as SQL client calls when assessing this change. See the
[conversion review](../PLAN/BETA7_CHARSET_CONVERSION_WORKFLOW_REVIEW.md).

### MySQL 5.7 DEFAULT character set syntax

`ddl-compat-charset-defaults` uses five source batches. The first ten operations
keep their original order and both deliberate restarts. Five retained tables
keep earlier table defaults, column collations and INSERT/UPDATE row bytes for
final comparison. DELETE still removes the row from the original table.

Source session boundaries are part of this test. The first table-default clauses
run without a selected database. Later CONVERT statements use USE ddlcompat and
an explicit collation_database override. A new client clears both before the
following row operations. The retained histories keep those same conditions.

Final queries check four original charset results, both retained row values,
the final table collation and the DELETE result. Full schema and row comparisons
include all six tables. Cleanup drops only the five retained tables after saved
state checks. The case does not add an offline replay path.

Run the case against an 8.4 target:

```sh
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite correctness --case ddl-compat-charset-defaults --coverage"
```

This also tests translation of the old DEFAULT-name syntax. The 8.4-source
profile is excluded because native 8.4 rejects that syntax. See the
[session and workflow review](../PLAN/BETA7_CHARSET_DEFAULTS_WORKFLOW_REVIEW.md).

### Connection character sets and Query events

`ddl-compat-query-encodings` uses three source batches. It keeps the original
ten operations and both deliberate restarts. The source client sends ASCII hex
through PREPARE, so MySQL receives exact latin1 E9/FC and Shift-JIS 955C bytes.
The 5C byte remains part of the Shift-JIS character. Each following row operation
restores the normal UTF-8 connection settings.

Five retained tables keep earlier defaults and row values for final queries.
The checks include text/binary and ENUM defaults, the binary-default change,
the added column's value 7, and its later value 8. Both original DROP statements
remain. Full schema/index/row comparisons include all five retained tables.
Cleanup drops only those tables after saved-state checks. No offline replay
path is added.

This case keeps FULL optional metadata for ENUM labels on an 8.4 source. The
identifier and lower-case table-name cases remain separate selections.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-query-encodings --coverage"
```

See the [encoded Query and identifier review](../PLAN/BETA7_QUERY_IDENTIFIER_WORKFLOW_REVIEW.md).

### Unicode table names

`ddl-compat-unicode-names` uses one source body batch. It keeps all 15 original
operations. Five retained databases keep earlier rows without changing the
original table names. Final queries compare precomposed and decomposed name
bytes, rows before and after UPDATE, RENAME results and the quoted `select`
table created with LIKE.

The case also checks the existing native conversion of a supplementary-character
name to `?`. It captures source warnings. This is not a claim that MySQL permits
supplementary characters in identifiers.

Twelve final queries and full schema/index/row comparisons cover the original
empty database and all five retained databases. The snapshot keeps nine current
tables and the retired original names. Cleanup drops only the five retained
databases after saved-state checks. The case adds no restart or offline replay.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-unicode-names --coverage"
```

The case needs lower_case_table_names=0. Keep the separate lower-case table-name
variant for mode 1. See the [Unicode table-name review](../PLAN/BETA7_UNICODE_TABLE_WORKFLOW_REVIEW.md).

### Lower-case table names

`ddl-compat-table-name-case` uses three source body batches. It keeps all ten
original operations and both deliberate restarts. Four retained databases keep
earlier defaults, copied rows and rename results. Copied statements preserve
uppercase/lowercase database qualifiers and the original accented table names.

The final queries check the added column's value 3 before UPDATE, later value 9,
LIKE/INSERT SELECT rows and the renamed table's value 8. They also check stored
lowercase table names and the original uppercase column spelling ID. Full
schema/index/row comparisons cover all five databases. Cleanup drops only the
four retained databases after saved-state checks.

This case requires lower_case_table_names=1 on source, native and target.
Select the fixture explicitly:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-table-name-case --variant lowercase-tables --coverage"
```

The default variant excludes this case. Keep the separate Unicode table-name
case on mode 0. See the [lower-case table-name review](../PLAN/BETA7_LOWERCASE_TABLE_WORKFLOW_REVIEW.md).

### Column and index case sensitivity

`matrix-identifiercase` uses preparation and body batches with one running
applier. The original SQL keeps its column, PRIMARY KEY and index references
with different letter cases. Three retained tables keep earlier rows, defaults
and index names for final checks. The case compares all four original predicates,
full ordered rows and schemas across source, native and target.

Preparation has four source transactions. The ten body requests have 18 source
transactions. Multi-statement scripts keep their original autocommit and implicit
DDL commits. A batch does not combine them into one transaction. The case checks
applied GTIDs, file offsets and counters after the body and after cleanup.
Cleanup drops only the three retained tables. The shared final drain and
saved-schema restart remain. The case adds no applier restart.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-identifiercase --coverage"
```

The original definitions and first INSERT remain inputs to metadata-discovery
tests.
See the [DML identifier workflow review](../PLAN/BETA7_DML_IDENTIFIER_WORKFLOW_REVIEW.md).

### Unicode column and index names

`matrix-unicodeidentifiers` uses the same preparation/body workflow. Three
retained tables keep earlier rows and schemas. Final queries check the original
predicates, all row fields, NULL values and defaults. They read column and index
names as hex bytes. They also check index key-part order and the 64-character
column name. These checks keep precomposed and decomposed names distinct.

The original multi-statement scripts and their source transaction counts remain.
Cleanup drops only the retained tables. The case adds no applier restart.

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-unicodeidentifiers --coverage"
```

### Temporary-table cases

`ddl-compat-temporary` uses one body batch. It checks permanent INSERT ... SELECT
rows, an empty LIKE clone, a following clone INSERT and the permanent `tmp` row
which the temporary table hides. Its setup batch creates that permanent table
before the body checkpoint interval. The template uses explicit MyISAM for
MyISAM target profiles and explicit InnoDB for InnoDB target profiles.

`ddl-compat-temporary-create-select` uses two body batches. Retained tables keep
the INSERT ... SELECT and UPDATE JOIN results until final comparison. The case
keeps its restart and replay stop after transaction three. Final queries run
again after replay. Each temporary CREATE/use/DROP script stays in one request.

On 5.7, source scripts can log extra temporary-table cleanup transactions.
The lab compares actual source GTID counts and file offsets. It also checks the
recorded cleanup skips and the permanent `tmp` row. An INFORMATION_SCHEMA.TABLES
query cannot by itself establish temporary-table lifetime; the explicit DROP
and successful name reuse in one session supply separate checks.

Run both cases together, with one fixture per profile:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-temporary --case ddl-compat-temporary-create-select --coverage"
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite correctness --case ddl-compat-temporary --case ddl-compat-temporary-create-select --coverage"
```

Cleanup drops only the retained tables. The separate `create-select-contract`
case still tests native permanent CREATE TABLE ... SELECT restrictions. See
[the temporary-table results](../PLAN/BETA7_TEMPORARY_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results).

### Measure schema discovery with target network delay

`benchmark --mode discovery` runs a local applier against disposable MySQL
containers. It compares zero added delay with a configurable target RTT. It
checks repeated writes, FK groups, DDL invalidation, and reopening saved state.
Use the same profile names and `--dml-transport sql|binlog` options as backlog
benchmarks. Supply `--binary` with the local applier path.

Use `--table-statistics on` to measure optional table statistics; the default is
`off`. For a 10K comparison, use `--events 10000 --target-rtt-ms 0` with each
setting. The harness also checks the saved counters after DDL and restart.

See [the discovery benchmark guide](../tools/metadata-benchmark/README.md) for
commands, output fields, and timing limits. This focused measurement does not
replace the correctness suite or native-replication performance comparisons.
