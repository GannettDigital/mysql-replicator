# Review of table, column and index tests

Status: the combined MODIFY workflow is implemented. Focused validation passed.
Use this as the next slice of [the CI follow-up plan](BETA7_CI_FOLLOWUP.md).

## Recommendation

Keep the distinct ALTER behavior. First combine the ten `ddl-modify-*` cases
in this group into one ordered column-definition workflow with named assertions.
Share database setup, applier lifetime, state export and binlog file reads.
Keep the original starting definitions, ALTER statements and following row checks.
Do not merge this whole group with the type/value or key groups, or split it
into more CI jobs before reducing the repeated work.

Next, reduce duplicate observation work in the DDL runner while retaining each
intermediate comparison. Move the database lifecycle case to the existing
database group. Keep the more complex dependency, rename, index and table-option
workflows until a specific assertion map supports further combination.

The new workflow uses the ID `ddl-modify-columns` and the title
"ALTER TABLE: change column definitions and positions". This ID is now available
through `--case ddl-modify-columns`. It remains inside the existing execution group.
Names follow the MySQL manual's
[ALTER TABLE column operations](https://dev.mysql.com/doc/refman/8.4/en/alter-table.html).
The manual distinguishes MODIFY, CHANGE, RENAME COLUMN and column defaults;
these are not interchangeable test conditions. MODIFY can also remove omitted
attributes or change column order. The 5.7 manual URL redirected to a newer
manual during this review; it was not used as 5.7 behavior evidence.

## Evidence and scope

Baseline: passing run `40454033524`, commit `efb3458`. The reviewed code is
`e28cb15`. The intervening changes affect the metadata test group and selection
records, not runtime code or the case bodies reviewed here.

Local evidence is under `artifacts/ci-review/40454033524/`:

- `measurements/report.json` and `test-value.json`.
- `jobs/`: per-group case times, harness SQL costs and exact runtime line sets.
- `table-column-index-review.json`: this review's default-profile comparisons.

The area declares 31 cases. Profile exclusions select 29 or 30 in the default
variant. The table below uses lab elapsed time, not GitHub queue or build time.
Harness SQL calls include test setup and assertions; they are not applier SQL
calls. Test time includes deliberate applier restarts and replay checks.

| Default profile | Cases | Lab seconds | Test seconds | Fixture setup seconds | Harness SQL calls |
|---|---:|---:|---:|---:|---:|
| `mysql84-to-mysql57-myisam` | 29 | 1200.3 | 1086.6 | 12.2 | 5647 |
| `mysql57-to-mysql84-innodb` | 29 | 995.8 | 906.1 | 11.3 | 5509 |
| `mysql57-to-mysql57-myisam` | 30 | 1229.1 | 1112.3 | 12.2 | 5741 |
| `mysql57-to-mysql57-innodb` | 30 | 1223.6 | 1115.3 | 12.0 | 5650 |

The containers already start once per group. Repeated container startup is not
the cause of this group's duration. The forward run also spends 61.5 seconds
exporting coverage. Do not include that in a claimed test-body saving.

## What the coverage comparison shows

For each default profile, subtract the union of the other default groups from
this group's runtime line set. Exclude all old `bootstrap-schema-discovery`
executions. Do not use another profile or variant to claim that a condition is
covered here. Unit coverage is not subtracted in this comparison.

| Profile | Lines reached | Lines absent from other default groups |
|---|---:|---:|
| `mysql84-to-mysql57-myisam` | 11554 | 472 |
| `mysql57-to-mysql84-innodb` | 11931 | 434 |
| `mysql57-to-mysql57-myisam` | 11502 | 421 |
| `mysql57-to-mysql57-innodb` | 11887 | 422 |

For the forward profile, the type/value group shares 9,860 lines with this group,
but leaves 1,694 of its lines uncovered. The key group shares 10,390 lines, but
leaves 1,164 uncovered. Conversely, those two groups contain 797 and 754 lines
that this group does not reach. Neither can replace the other based on overlap.

The 472 forward-only lines include DDL parsing (80), table options (49),
expression predicates (47), FULLTEXT metadata (42) and column renames (39).
These are file-level observations, not attribution to an individual case.
Exact locations are in the JSON report. The old report's per-job zero-exclusive
counts can be masked by the same case running in other variants or profiles.

This measures first-party Swift runtime lines. It does not measure Rust coverage
or prove assertion equivalence. SQL-cost records show calls and categories;
source inspection supplies the exact SQL and predicates below. This review does
not claim a new per-case coverage measurement.

## Case review

All IDs below have the `ddl-compat-` prefix unless stated otherwise.

| Cases | Distinct conditions to retain | Decision |
|---|---|---|
| Ten `ddl-modify-*` cases listed below | Width, signedness, nullability, column order, exact row bytes, counters, journal/schema references and normalized binlogs. | Combine surrounding work into one workflow. Keep all ten ALTER conditions. |
| `generated`, `generated-expressions`, `generated-dependencies` | Basic stored/virtual values and NULLs; expression grammar and functions; dependency rename/replacement and stored/base conversion. | Keep. Their INSERT/UPDATE statements serve different generated-column assertions. The basic case is also selected without source-GTID preservation. |
| `column-index-syntax`, `alter-column-keys` | Native implicit key names, inline/grouped keys, SERIAL, key options; implicit values when adding NOT NULL/PRIMARY KEY; logged AUTO_INCREMENT increment/offset during rebuild. | Keep. Ordinary CREATE/DROP INDEX and row-key checks do not replace these. |
| `column-renames`, `column-swaps`, `alter-table-rename`, `multi-table`, `cross-schema-relationships` | Definition-preserving RENAME COLUMN versus CHANGE cycles; compound ALTER rename versus multi-table RENAME; cross-schema moves, FK peers and complete DROP transitions. | Keep the statements and profile-specific branches. Do not collapse them to one simple rename. |
| `fulltext`, `spatial-prefix-indexes`, `json-indexes` | MATCH results and parser metadata; ordinary prefixes on spatial columns; generated JSON-column index lookup and engine-specific stored/virtual forms. | Keep. Basic index metadata or JSON/spatial value tests do not replace index behavior. FULLTEXT was already consolidated earlier. |
| `alter-options`, `table-options`, `table-maintenance`, `ignored-checks` | ORDER BY and validation clauses; comments/row format/AUTO_INCREMENT; FORCE and MyISAM disabled keys; ignored 5.7 CHECK clauses. | Keep. These include distinct engine/version behavior. |
| `types`, `alter`, `alter-conversions` | Mixed CREATE attributes and timestamp-dependent ALTER defaults; compound ADD/CHANGE/default/key changes; conversion of existing indexed values through several types. | Keep for now. Type-range DML does not replace conversion of existing rows or compound DDL. |
| `database` | New defaults affect new tables, not existing tables; DROP after resume retires two saved schemas without rediscovery; recreation with a new type. | Move intact to `database-defaults-transactions` after the first slice. Do not delete it as a duplicate CREATE DATABASE check. |

Key source locations:

- `SharedCorrectness.swift`: `step`, `compare`, `ddl` and `indexes`.
- `ModifyIndexCases.swift`: independently specified ALTER inputs and metadata.
- `SharedCatalogSupport.swift`: state export and normalized binlog assertions.
- `GeneratedExpressionCases.swift`, `GeneratedDependencyCases.swift`,
  `ColumnIndexSyntaxCases.swift`, `AlterColumnKeyCases.swift`.
- `ColumnSwapCases.swift`, `RemainingAlterCases.swift`, `AlterRenameCases.swift`,
  `MultiTableDDLCases.swift`, `TableAlterCases.swift`, `TableMaintenanceCases.swift`.
- `DDLReplayWorkflow.swift`: archive, stop/resume and unreachable-source checks.

## First implementation slice: MODIFY columns

The ten cases took 210.4 test seconds and 1,374 harness SQL calls in the forward
default run. That is about 19% of this group's test time. It is not an estimate
of the saving: the ALTER statements and their observations still need to run.
This slice alone cannot make a 20-minute group finish in five minutes.

| Existing ID suffix (`ddl-modify-`) | Required condition |
|---|---|
| `demo-varchar-120` | Widen VARCHAR; omitted nullability/collation attributes follow native behavior; accept a long value; UPDATE/DELETE preserve the seed row. |
| `narrow-text` | Narrow VARCHAR with explicit NOT NULL/collation; retain seed data and exact multibyte/NUL/trailing-space bytes. |
| `binary-width` | Widen VARBINARY; retain seed bytes and accept a value larger than the old width. |
| `binary-narrow` | Narrow VARBINARY; preserve fitting bytes and accept the following INSERT. |
| `integer-signed` | Change unsigned INT to signed BIGINT; write 4294967296. |
| `primary-widen` | Widen the primary key to unsigned BIGINT; INSERT/UPDATE/DELETE keys above the INT range. |
| `integer-narrow` | Narrow an existing BIGINT primary key to INT; retain its row and apply another row. |
| `not-null` | Change nullable VARCHAR to NOT NULL without losing its explicit collation or rows. |
| `first` | Move the text column FIRST; preserve column/value alignment through INSERT/UPDATE/DELETE. |
| `after` | Widen and move the numeric column AFTER the binary column; verify order and following values. |

Before this change, the `indexes()` runner executed these operations for every case:

1. CREATE DATABASE IF NOT EXISTS, then four individual DROP TABLE IF EXISTS calls.
2. Replicated CREATE TABLE and seed INSERT.
3. The actual ALTER and following DML, with metadata and row checks.
4. Drain the applier, copy the state directory and check its checkpoint/history.
5. Copy each server's binlog file, decode this case's range and compare it.
6. Restart the applier before the next case.

Each `step()` waits for replication and compares database schema and rows on all
three servers. Thus even absent-table cleanup repeats full comparisons. The ten
cases produce 40 cleanup DROP steps and ten conditional database CREATE steps,
before their actual table seeds and ALTER operations.

Combined workflow:

- Create the database once. Reset only the table needed for the next subcase.
  Keep seed CREATE/INSERT replicated. Retain an explicit no-op DROP check with
  its existing owner; do not use forty cleanup no-ops as implicit coverage.
- Keep the original independent starting definition for each ALTER. Do not
  accidentally turn a width or nullability test into a different transition
  because a previous ALTER changed the table. Reuse a small number of table
  names sequentially; do not precreate ten tables and compare all ten after
  every step.
- Keep the applier running across these subcases. Keep named metadata and exact
  row assertions after each ALTER and its following DML. Keep warning checks.
- Record start/end positions, GTIDs and progress counters for each subcase.
  Export durable state once at the end. Check each subcase's DDL transitions and
  row schema IDs by its GTIDs, not by the last row or only `current=1`.
- Read each server's binlog file once, then validate each recorded range. Keep
  one ALTER and the expected row-event count per range, and exact normalized
  source/native/target equality. Preserve the existing rotation checks.
- Keep one explicit saved-state restart boundary and following write. Replace
  repeated per-case STOPPED/process-lifecycle assertions with this named parent
  assertion. Record this change in the migration map; do not claim ten restart
  checks still run. Do not remove feature-specific restarts from the other DDL
  workflows in this slice.
- Give each old condition a named assertion in the parent case. Do not mark the
  parent passed until the deferred journal/binlog checks pass. Preserve old-ID
  migration hints, original applicability and native observation definitions.

Validate one representative profile: `mysql84-to-mysql57-myisam`, default
variant, SQL transport. Run only the new combined case. Its application behavior
and engine-specific branches are unchanged; do not add the other three profiles
unless implementation introduces a distinct branch that needs verification.

Build the host lab once after the harness edits. Reuse the application image if
its input checks allow it; otherwise build that image once. Run affected catalog,
migration and selector unit tests, plus a full plan without containers. Do not
build release packages, run the syntax suite, or run unrelated restart/replay
cases. Stop when the named assertions and planning checks pass. Leave remaining
profiles, variants and full line-set comparison to the batched CI run.

## Later slices

1. **Observation calls.** Review batching of independent expected-value queries
   and schema/row reads into fewer client invocations. Preserve every intermediate
   expected result and evidence entry. Do not replace each-step checks with final
   row equality. Do not cache test-oracle metadata through a DDL operation.
2. **Database ownership.** Move `ddl-compat-database` intact to the existing
   database area. This reduces the overloaded group without adding a job, but
   does not remove its workload. Check its order beside the existing cases once.
3. **Dependency and rename workflows.** Inventory the saved schema condition at
   every `restartBefore` and replay stop point. Only combine boundaries with an
   identified equivalent owner. Existing replay/resume behavior is useful here
   because it reloads different expression, key and rename metadata.
4. **Balance after reduction.** Use saved times for unchanged cases and label new
   estimates. If the group still needs redistribution, move intact workflows
   into compatible existing groups before adding jobs. No measured speedup is
   claimed until the combined changes run in CI.

No complete DDL/DML behavior was proved redundant by this review. The confirmed
repetition is setup, observation and process/state export around distinct checks.
The initial review used saved artifacts, source inspection and the MySQL manual
for terminology. Implementation checks are recorded below.


## Implementation and validation

The new parent has 50 named subcase assertions, five aggregate catalog assertions,
and one saved-state resume assertion. The aggregate assertions require all ten
subcases. Native observation fixtures and `ddl-modify-indexed` are unchanged.
The migration map retains all ten original SQL profile/variant scopes. It records
the replacement of repeated STOPPED checks with live per-subcase counters and one
final saved-state checkpoint/restart.

The full plan contains 187 execution groups and 1,545 selected catalog entries.
The ten old case IDs become one parent in each of ten scopes: 90 fewer catalog
entries, with no new jobs. This is a count change, not a coverage improvement.
The forward default table/column/index group now has 20 cases instead of 29.

Focused validation:

- 43 Swift tests passed: `ModifyColumnsTests`, `DDLCoverageEvidenceTests`, and
  `LabProfileTests`.
- 83 Python planner tests passed: `test_lab_*.py` and `test_ci_matrix.py`.
- The full CI plan passed catalog, feature ownership and migration checks.
- Forward default SQL integration passed with coverage. All 56 named assertions
  passed. The result also passes the ten migration records' assertion checks.
  Coverage export and cleanup passed.
- Swift formatting and `git diff --check` passed.

No other profile, syntax suite, release package or full integration suite is
required for this slice. Full runtime line-set comparison remains part of the
batched CI run.


Local integration command:

```sh
.build/debug/replicator-lab test --profile mysql84-to-mysql57-myisam \
  --suite correctness --case ddl-modify-columns --coverage --skip-build
```

Evidence: `artifacts/lab/20261027T191920Z-965777cc/result.json` and its forward
correctness directory. The parent case took **158.7 seconds** and made **918
harness SQL calls**. It wrote one `snapshot-ddl-modify-columns` state export and
copied three binlog files: one from each server. The standard outer runner also
retains its separate final saved-schema restart; this slice does not change it.
Fixture startup/setup took 24.5 seconds, coverage export took 8.2 seconds, and
cleanup took 11.6 seconds. Those times are outside the parent case.

For reference, the ten old cases made 1,374 SQL calls and took 210.4 test seconds
in the saved CI run. The new result is local, so this is not a controlled elapsed-
time comparison. Polling can also change SQL call counts. Use the batched CI run
for the final timing and line-set comparison. Runtime application code did not
change. The local image build reused the compiled application objects.


## Follow-up: one applier session and fewer observation points

Status: source and saved-run review only. No new test run or runtime change.
This changes the next runner-design direction. Use execution phases instead of
only combining more case IDs. A phase submits a set of source statements, waits
for its final replication position, then reads the results needed by its named
assertions. Keep source transaction boundaries unchanged.

### Current restart behavior

- `databases()` stops, exports state and restarts after each database creation case.
- `ddl()` stops, exports state and restarts after each `DDLCompatibilityCases`
  case. Some steps also set `restartBefore`; some cases run offline replay.
- `indexes()` retains that per-case stop/export/restart for standalone index cases.
- `dml()` keeps the main applier running across ordinary matrix cases. It still
  waits and compares schema and rows after each step.
- The combined MODIFY workflow keeps one applier across its ten subcases, then
  tests one saved-state restart. The outer main runner adds another restart.
  Its local coverage manifest confirms three main-applier invocations in total.
- Metadata discovery deliberately starts with a fresh state and cache. Failure,
  recovery, reconnect, replay and temporary-session tests also have distinct
  setup requirements. Do not remove these boundaries as ordinary case overhead.

The forward default `table-column-index-changes` group contains 19 compatibility
cases plus the combined MODIFY case. Thus the compatibility loop alone adds 19
stop/export/restart cycles, before explicit `restartBefore` and replay work.
These are process restarts in the existing applier container, not repeated MySQL
container setup.

### Measured cost in the combined MODIFY run

The parent took 158.7 seconds. Join `sql-trace.jsonl` start/finish records by
`call_id` and select `case_id=ddl-modify-columns`:

| Harness client call | Calls | Elapsed seconds |
|---|---:|---:|
| Source workload | 59 | 9.3 |
| GTID/file-position reads, waits and replica status | 370 | 52.2 |
| Full schema snapshots | 177 | 28.1 |
| Row and expected-value queries | 222 | 31.5 |
| Additional metadata assertions | 90 | 14.1 |
| Total | 918 | 135.3 |

The 177 schema snapshots are 59 steps times three servers. Each snapshot batches
six information_schema queries, but later reads and explicit assertions still
use other calls. `NativeHarness.sqlCommand` starts `docker compose exec ... mysql`
for every call. The times include client/process startup, connection setup,
query execution and waiting. They do not isolate server CPU time or replication
application time. About 126 seconds are in observation and control SQL calls.
The remaining case time includes non-SQL Docker calls, state/binlog checks and
file work; it must not all be attributed to restarts.

The 10K benchmark does not have this observation after each source statement.
Its elapsed time is therefore not a direct estimate for a correctness group.
The saved full-CI benchmark also uses mainly row operations; ALTER rebuild costs
can differ. The measured harness cost still supports reducing observation calls.

### Recommended design

1. **Share the running applier.** Ordinary correctness cases use one main
   applier session per fixture. Stop once for final state export. Retain explicit
   restart/replay/reset boundaries only when a named assertion requires them.
   Check earlier schema and row history by GTID/offset ranges and immutable schema
   IDs. Do not use `current=1` to check schemas that later DDL retired.
2. **Separate submission, waiting and observation.** Keep the existing `step`
   wrapper for cases that need it. Add phase operations to the shared runner:
   submit an ordered source script, wait for its captured final boundary, and
   execute named result queries in batches on source/native/target. Reuse
   `LabSQLBatch` and its result framing. Do not add another framework.
3. **Keep final results that prove the operations.** Where possible, leave
   different row IDs or independent tables for inserted, updated and deleted
   values. A final comparison can then check multiple conditions. Keep explicit
   expected results as well as native comparisons. Tables retained for a final
   comparison need not be scanned after every preceding statement.
4. **Keep required intermediate observations.** INSERT then DELETE can leave an
   empty table even if neither event was applied. An ALTER can change an attribute
   that a later ALTER restores. A final snapshot alone cannot prove those steps.
   Preserve a phase boundary, retain independent result rows/tables, or verify
   the corresponding binlog/journal interval. Binlog comparisons must retain
   profile-specific normalization; do not assume every cross-version row encoding
   can be compared without conversion.
5. **Keep session semantics.** A source script must retain autocommit, explicit
   BEGIN/COMMIT boundaries, SQL mode, character sets, time zone and warnings.
   Multiple statements in one client call must not become one new transaction.
   Existing per-call session resets and temporary-table lifetimes need explicit
   handling before calls are combined. Expected source errors must not be hidden
   by continuing a failed script.
6. **Keep diagnostics and pass conditions.** Save named phase/statement IDs,
   source boundaries and expected/actual results. Capture warnings before another
   statement overwrites them. Do not report an assertion as passed before its
   deferred state or binlog check completes. Keep failure bundles and logs.

Use one final comparison only when the workload leaves enough evidence to prove
all its conditions. Otherwise use a small number of named phase comparisons.
Remove full-database scans after setup and each DML statement where these add no
separate assertion. The test oracle must remain independent of the applier cache.

### Next implementation slice

Pilot the phase API on `ddl-modify-columns`. Start by batching independent
expected-value and metadata queries and combining setup submissions. Remove the
outer runner's duplicate restart only after the named saved-state assertion owns
that check. Then redesign transient INSERT/UPDATE/DELETE outcomes so fewer waits
can retain the same conditions. Record which assertions are final-state checks
and which need intermediate observations before changing them.

Use the existing 56 assertions and ten migration records as the comparison list.
Run affected lab unit/planner checks and this one case on forward default SQL with
coverage. Compare SQL call counts, restart counts and case time against the saved
158.7-second local run. Do not rerun other profiles unless a changed branch needs
one. Leave the full matrix and runtime line-set comparison to batched CI.

After the pilot, apply the shared lifetime and observation model to ordinary DDL,
DML, database and index workflows. Keep dedicated lifecycle tests and explicit
schema-after-resume conditions. Move such conditions to named lifecycle cases
only with an assertion map; do not silently delete them.


## Phase pilot implementation

The pilot now keeps ten independent tables. Each table retains its original
column definition, ALTER, values and following DML. Only fixture table names
change. This supersedes the earlier single-table reuse decision: the runner no
longer scans the whole database after each write.

The source submits setup, ten ALTERs, then three DML phases. It retains a session
reset before each submitted operation and does not add BEGIN/COMMIT wrappers.
The first DML phase contains ten operations. The second and third contain three
each. Each phase waits once, then reads the named results in one client call per
server. All original intermediate row checks remain. Warnings are read directly
after each ALTER in the source script.

One final comparison checks all table definitions and rows. Each statement
records its GTID and before/after file offsets. Deferred checks verify those
coordinates against applied SQLite groups and use the exact GTIDs for schema
history. Each server binlog is copied and decoded once. Per-table comparisons
retain complete row blocks, exact row counts and one ALTER per condition.
The parent still requires all 56 assertions. The named saved-state restart remains;
the outer runner omits its duplicate restart for a MODIFY-only selection.

### Local comparison

Both runs use forward default SQL transport and the coverage application image.
Neither changes runtime application code. These are single local measurements,
not production throughput or a CI timing guarantee.

| Parent-case measurement | Combined case before phases | Phase pilot |
|---|---:|---:|
| Case seconds | 158.7 | 21.6 |
| Harness SQL client calls | 918 | 63 |
| Main-applier invocations, including outer runner | 3 | 2 |
| Required named assertions passed | 56 | 56 |

The normal pilot result is
`artifacts/lab/20261027T200235Z-97f53c02/result.json`. Coverage export and cleanup
passed. The full plan still contains 187 groups and 1,545 selected catalog entries.
The original 62 focused Swift checks and 56 Python planner checks passed. The
bundle collector correction passed its seven focused failure/reporter tests,
including one new command-construction check.

Runtime line coverage changed from 7,401 to 7,367 lines: 39 old lines were not
reached and five batch-apply lines were added. The 39 lines are in existing-table
schema discovery/cache population and the existing-schema journal path. The old
outer restart writes to a baseline table that has no captured CREATE. All 39
lines occur in other saved forward/default groups, including `keys-rows-gtids`,
`ordered-schema-changes-resume` and `table-filters-index-resume`, excluding the old
bootstrap group and this DDL group. The focused metadata tests retain their own
explicit discovery assertions. Details are in
`artifacts/modify-phase-pilot/line-comparison.json`. Full-matrix confirmation
remains deferred to CI.

### Failure output and bundle check

Shared correctness failures now retain the case and assertion or source phase
in the output. The harness drains the writer and invokes `support-bundle` in a
separate container with no network access. It copies the bundle before fixture
cleanup and prints the local path. `harness-failure.json` and `result.json`
record collection status. Bundle logs include the test failure and applier logs.
This also covers a comparison failure while the applier remains healthy.
Automatic BLOCKED bundles remain separate and are retained.

The first deliberate comparison failure exposed a collection bug: the file-copy
helper container is created but not running. The collector now uses a separate
process mounted on the same state volume. The original comparison error remained
visible when collection failed. That failed probe is retained at
`artifacts/lab/20261027T202916Z-30a6ab7e/result.json`.

The repeated probe passed its failure-output checks. It changed one decoded
target row in the mysqlbinlog reference output, not the database. The run failed
at `modify-demo-varchar-120-normalized-binlog`, printed that assertion and the
bundle path, and saved collection status `created`. The bundle contains
`state.sqlite`, `relay.frames`, `configuration.json`, `diagnostics.json`, the
harness failure and applier logs. SQLite integrity passed and its lifecycle was
`STOPPED`. Cleanup passed. This proves collection for a harness comparison
failure while the applier has no BLOCKED error.

Probe result: `artifacts/lab/20261027T205021Z-278e5d50/result.json`.
The console log is `/tmp/modify-phase-failure-fixed.log`. The local fault injector
is `artifacts/modify-phase-pilot/fail-reference.py`; it uses the existing
`MYSQLBINLOG` override and changes only the first target row in decoded output.
No test-only fault switch was added to the application or the lab CLI.

All ten migration records validate against the normal pilot's 56 passing
assertions. Formatting and diff checks passed. No additional profile or full
suite was run. Next: apply the shared phase/observation design to another ordinary
DDL workflow, with a condition map for any required intermediate observation or
restart.
