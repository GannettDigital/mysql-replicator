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

The `matrix-exactchoices` and `matrix-choiceboundaries` cases check exact ENUM/SET
labels, defaults and ordinal writes. The corresponding `bootstrap-matrix-*` cases
check discovery from an existing schema. These replace the old non-BMP DDL refusal
cases. They cover latin1, UTF16, UTF16LE, UTF32, GB18030 and supplementary UTF-8.

Bootstrap-only selections use their own applier states. They omit the unrelated
main-applier database setup and general saved-schema restart. Each bootstrap
phase still starts with fresh state and checks its own rows and checkpoint.
Target-specific bootstrap cases retain their explicit restart and replay checks.
A selection that also contains a case that needs the main applier keeps the
general setup and restart. The catalog records this requirement as
`requires_main_applier`. Other selections keep their current setup.

Full CI assigns related cases to named groups such as
`table-column-index-changes` and `bootstrap-schema-discovery`.
Cases in each group share MySQL containers. The groups retain all selected SQL,
per-case assertions and state boundaries. See [CI measurements](CI_MEASUREMENTS.md)
for group counts, timing scope and coverage comparison rules.

The `binarychoices` live and bootstrap cases check raw binary ENUM labels, binary
SET labels, hex/bit literals and defaults. The `legacybinaryset` cases add non-UTF-8
SET bytes on the two 5.7-to-5.7 profiles. MySQL 8.4.8 rejects that SET definition
with native error 3507. Binary choice schema comparisons read raw SHOW CREATE
output through a separate test parser.

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

`matrix-bits` and `bootstrap-matrix-bits` use the same BIT workload for replicated
CREATE and existing-table discovery. They check widths through 64 bits, defaults,
primary-key changes, ADD/MODIFY, and DML. Full CI includes these cases; inspect
the results for the exact commit. See [BIT support](../PLAN/BIT_SUPPORT.md).

`matrix-floating` and `bootstrap-matrix-floating` add FLOAT/DOUBLE DML and DDL
cases for all four profiles. `matrix-fixedfloating` and
`bootstrap-matrix-fixedfloating` check fixed-scale forms, defaults, rounding and
ALTER. They replace the fixed-scale refusal cases. Full CI includes these cases; inspect the results for the exact commit. See
[FLOAT/DOUBLE support](../PLAN/FLOATING_POINT_SUPPORT.md).

`matrix-decimaldefaults` and `bootstrap-matrix-decimaldefaults` check native
DECIMAL default rounding, scientific notation, quoted constants, unsigned and
ZEROFILL forms. They include CREATE, ALTER DEFAULT, ADD, MODIFY and row changes.

`matrix-binarydefaults` and `bootstrap-matrix-binarydefaults` check exact binary
default bytes, NUL, empty values, BINARY padding, CREATE and ALTER. The lab reads
stored native defaults because displayed metadata can omit bytes.

`matrix-textdefaults` and `bootstrap-matrix-textdefaults` check CHAR/VARCHAR
defaults with supplementary characters, NUL, byte literals, numeric constants,
legacy/wide encodings and CHAR padding modes. Metadata comparisons use stored
defaults and preserve exact Unicode bytes.

`matrix-zerowidth` and `bootstrap-matrix-zerowidth` check zero-width CHAR,
VARCHAR, BINARY and VARBINARY columns. They distinguish empty values from NULL
and exercise width changes before and after DML.

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

`matrix-json` and `bootstrap-matrix-json` check ordinary JSON values.
`matrix-typedjson` and `bootstrap-matrix-typedjson` check DECIMAL, temporal and
binary JSON types. All four profiles select these cases. `matrix-jsonpartial`
and `bootstrap-matrix-jsonpartial` check partial updates on an 8.4 source.
They inspect mysqlbinlog output to confirm that the source emitted a change
record. These cases passed on the applicable profiles. The old `matrix-reject-json-opaque` case
is removed. See [JSON support and limits](JSON_SUPPORT.md).

`matrix-spatial` and `bootstrap-matrix-spatial` check all eight spatial types,
SQL NULL, empty collections, SRIDs 0 and 4326, INSERT/UPDATE/DELETE, primary-key
changes, added columns, and SPATIAL index changes. They compare stored bytes
and SRIDs with the native replica. They do not compare WKT output across server
versions. See [spatial support and limits](../PLAN/SPATIAL_SUPPORT.md).
The former `reject-geometry` and `reject-fulltext` refusal cases have positive
coverage. The refusal selection now uses `reject-engine`.

`ddl-compat-fulltext` checks index creation, changes, parser metadata, search
results, CREATE TABLE LIKE and restart. It also checks explicit ngram index
creation and searches after multirow INSERT, UPDATE and DELETE. These named
assertions replace `matrix-fulltext`. `bootstrap-matrix-fulltext` retains all
three original row-change phases with initial discovery of an existing ngram
index. See [FULLTEXT scope](../PLAN/FULLTEXT_SUPPORT.md) and the
[migration review](../PLAN/BETA7_TEST_SUITE_CONSOLIDATION.md).

`--case ddl-compat-constraints` exercises named PRIMARY/UNIQUE constraints in
CREATE and ALTER, explicit index-name precedence, unnamed constraints, and DML
after the changes on all profiles. Named assertions distinguish single-row
UPDATE/DELETE from multirow INSERT/UPDATE/DELETE. The multirow phases replace
`matrix-values`; they retain its separate integer-primary-key table and non-NULL
value column. Each phase checks exact rows, including unaffected rows.
`bootstrap-matrix-values` retains the original existing-schema workload.

`ddl-compat-key-conflicts` combines the former `matrix-upsert`, `matrix-replace`
and `matrix-ignore` cases. It keeps separate tables and the original SQL for each
starting state. Named assertions check mixed insert/update effects, REPLACE
conflicts with two different rows, skipped duplicate rows, and no-op statements.
Each check compares exact rows on source, native and target. The three
`bootstrap-matrix-*` cases retain their existing-schema and resume checks.

The `keys-rows-gtids` group contains the `positive` single-row case and related
key, row and GTID cases. The SQL `without-source-gtids` variant runs `positive`
and any applicable tagged-GTID case in this group. That case also tests INSERT, counters,
binlogs and saved state; it is not an UPDATE/DELETE-only test. Other single-row
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

`bootstrap-matrix-composite` and `bootstrap-matrix-textkey` retain existing-schema
discovery and resume. Prefix-key and UNIQUE-key workflows remain separate. The
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
| `bootstrap` | `bootstrap-matrix-*`: the DML matrix against preexisting table snapshots, with isolated checkpoints for each phase |
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
Use shared `correctness`, its `bootstrap` family and capture variants instead.
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
groups. `--variant all` expands capture variants; `PROFILE=all` expands profiles.
Neither option adds BINLOG transport automatically.

The local CLI does not yet accept a CI group name such as `keys-rows-gtids`.
`lab-plan` selects catalog cases; it does not reproduce CI group boundaries or
transport policy. To reproduce an exact CI group, use its case list, profile,
variant and transport from `matrix.json`. See
[generated CI commands](PR_TEST_SELECTION.md#change-or-inspect-the-selection).
Local matrix commands run in sequence. CI runs groups in parallel.

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
These checks do not prove that two tests have the same behavior. Each migration
also needs a review of its SQL, expected results and measured code coverage.

`ddl-compat-generated` replaces the replicated `matrix-generated` case. It checks
multirow INSERT, NULL propagation, UPDATE and DELETE with stored generated
columns. It retains its virtual-column and ALTER checks. Three named assertions
save SQL, expected values and observed values from the source, native replica
and target. `bootstrap-matrix-generated` retains all three original phases for
an existing table. A selection of the retired ID fails and names its replacement.
See [the consolidation plan](../PLAN/BETA7_TEST_SUITE_CONSOLIDATION.md) for the
comparison results and coverage review.

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

`matrix-enumzero` and `bootstrap-matrix-enumzero` distinguish ENUM ordinal zero
from a declared empty-string label. They check multi-row INSERT, ordinal changes,
NULL, primary-key changes, DELETE and schema restart on all four profiles. The
former `matrix-reject-enum-error-value` case is removed. Ordered-label and
missing-label refusal cases remain.

`matrix-zerofill` and `bootstrap-matrix-zerofill` check integer display widths,
implicit UNSIGNED, padded defaults, numeric boundaries, ALTER and DML. The
included-DDL refusal case uses an explicit engine outside the selected profile.
This keeps a real policy failure after ZEROFILL becomes supported.

The `matrix-collations` and `bootstrap-matrix-collations` cases test all 63 native
5.7 collations for utf8mb4, utf8mb3, latin1 and ASCII. They compare schema metadata
and bytes after each phase. The case includes a collated key, defaults, NULL,
INSERT, UPDATE, ALTER and DELETE. It does not test every language-specific sort rule.

The `matrix-nativeencodings` and `bootstrap-matrix-nativeencodings` cases add the
remaining 36 native 5.7 text encodings. They check raw CHAR/VARCHAR/TEXT bytes,
encoding-specific CHAR padding, NUL, defaults, NULL and DML/DDL phases. A UTF16
primary key checks binary parameter conversion in key predicates.

The `floatingauto*` DML cases test native 5.7 floating-point AUTO_INCREMENT.
The live and bootstrap cases run on both 5.7-to-5.7 profiles. The inventory gives
native error 1063 as the exclusion reason for a profile with an 8.4 source or target.
The common selection code and both execution paths use these profile exclusions.

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
partitions, ADD counts and implicit KEY columns. Existing `ddl-compat-partitions`
and `ddl-compat-hash-list` cover the earlier partition operations. See
[partition scope](../PLAN/PARTITION_SUPPORT.md) for limits and native references.

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

`target84-index-spatial-metadata` checks an existing 8.4 target with invisible
indexes and SRID constraints. `ddl-compat-absent-definers` checks invoker results
and native error 1449. Both include restart and offline replay.

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
