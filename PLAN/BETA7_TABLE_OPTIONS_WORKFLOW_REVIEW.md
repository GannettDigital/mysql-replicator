# Review of table options, rebuilds and ignored CHECK clauses

## Decision

Both slices are implemented and pass focused local checks. See the results below.
The reviewed design keeps the four existing case IDs,
profile exclusions and CI selections. These cases already share containers in
`table-column-index-changes`. Creating a new group would add setup work.

1. Convert `table-options` and `table-maintenance` to source batches and final
   observations. Validate both in one forward MyISAM fixture.
2. Convert `alter-options` and `ignored-checks`. Validate `alter-options` on forward
   MyISAM. Then validate both cases in one reverse InnoDB fixture.

Use independent tables to retain results that later statements would erase.
Preserve all original SQL and its order. Keep the nine explicit restart points
and the two offline replay stops. Do not infer redundant assertions from shared
line coverage. The implementation removes no tests.

The preceding rename conversions are committed as `44ba25a`. This work continues
[Slice 2 of the execution plan](BETA7_TEST_SUITE_CONSOLIDATION.md#remaining-slices-in-order).

## Names and tested scope

Consult the MySQL manual before changing titles or adding assertion names.
Keep stable case IDs for selection and catalog references. Use these terms:

| Case suffix (`ddl-compat-`) | Suggested title | Scope limit |
|---|---|---|
| `table-options` | Table options: comments, row format, AUTO_INCREMENT and CREATE TABLE LIKE | Checks specified options, source-assigned row IDs and copied definitions. It does not test every storage-engine option. |
| `table-maintenance` | ALTER TABLE: FORCE and ENABLE/DISABLE KEYS | Checks rows and nonunique-index state. It does not measure disk layout or rebuild speed. |
| `alter-options` | ALTER TABLE: ORDER BY and generated-column validation clauses | Checks accepted SQL, generated values and following writes. Current values do not test out-of-range rejection. SELECT ORDER BY does not prove physical row order. |
| `ignored-checks` | CHECK clauses ignored by a MySQL 5.7 source | Checks accepted violating rows, omitted target constraints and the durable no-op rule. It is distinct from enforcement on an 8.4 source. |

MySQL describes DISABLE/ENABLE KEYS as controls for MyISAM nonunique indexes.
It also distinguishes physical row ordering from later query ordering and
provides FORCE for table rebuilds. Use those terms without claiming a physical
property from a logical row comparison.
[ALTER TABLE manual](https://dev.mysql.com/doc/refman/8.4/en/alter-table.html).

WITH/WITHOUT VALIDATION apply to generated-column operations. The current case
uses valid values, so it checks successful operations, not validation failures.
[Generated-column ALTER manual](https://dev.mysql.com/doc/refman/8.4/en/alter-table-generated-columns.html).

COMMENT, ROW_FORMAT and AUTO_INCREMENT are table/column options. PASSWORD is
unused; accepting its syntax is not a password or security test.
[CREATE TABLE manual](https://dev.mysql.com/doc/refman/8.4/en/create-table.html).

MySQL documents parsed-and-ignored CHECK syntax before 8.0.16 and constraint
support from 8.0.16. Retain the repository's observed 5.7 source cases and its
separate 8.4-source refusal case.
[CHECK manual](https://dev.mysql.com/doc/refman/8.0/en/create-table-check-constraints.html).
The requested 5.7 ALTER manual URL redirected to 9.7 during this review; it was
not used as evidence of 5.7 behavior.

## Saved measurements

Baseline: successful full CI run `40454033524`, commit `efb3458`. Its measurement
summary is complete. The four reviewed case bodies are unchanged from that run.
The shared runner has since changed. Source comparisons and extracted costs are
in `artifacts/table-options-review/source-comparison.json` and `baseline.json`.

Each cell is **case seconds / harness SQL client calls**, for default SQL runs.

| Case | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 InnoDB | 5.7 → 5.7 MyISAM |
|---|---:|---:|---:|---:|
| `alter-options` | 31.6 / 126 | 27.8 / 125 | 31.7 / 125 | 31.6 / 125 |
| `table-options` | 38.2 / 196 | 31.7 / 195 | 38.6 / 195 | 39.1 / 195 |
| `table-maintenance` | 41.5 / 174 | 36.1 / 173 | 41.3 / 173 | 42.3 / 173 |
| `ignored-checks` | Excluded | 33.1 / 195 | 39.6 / 195 | 40.1 / 195 |

The three forward cases cost 496 client calls and 111.3 case seconds. The four
reverse cases cost 688 calls and 128.7 seconds. These are not target-applier SQL
counts. Each old step submits SQL, waits, performs explicit checks and compares
the whole database. Batching can remove repeated client calls and observations.
Do not predict an elapsed-time improvement before measuring it.

Coverage belongs to the complete table/column/index group, not each case. Use
[the existing group-level analysis](BETA7_TABLE_COLUMN_INDEX_REVIEW.md#what-the-coverage-comparison-shows).
The SQL categories also contain mixed calls; do not classify all of them as
schema reads. No measured line set supports removing one of these four cases.

## Assertions that a generic snapshot cannot replace

The current `compare` helper compares rows, column definitions, indexes,
foreign keys and partitions. It does not compare TABLE_COMMENT, COLUMN_COMMENT,
ROW_FORMAT, the SHOW INDEX disabled flag, or CHECK-constraint inventory.
Keep direct named queries for those fields. A final snapshot alone would lose
existing checks.

Preserve role-specific expectations. In the forward profile, the source uses
InnoDB while the native and external targets use MyISAM. The existing disabled
index check expects an empty comment for InnoDB and `disabled` for MyISAM.
Keep SHOW INDEX field selection and trailing empty fields intact. Do not apply
one target-engine expectation to every role.

## Slice 1: table options and index maintenance

### Table options

Keep all nine original statements. Retain the restart before the table-options
ALTER and the restart before INSERT into the LIKE copy. There is no offline
replay in this case today; this conversion does not need to add one.

| Existing observation | Proposed final result |
|---|---|
| Initial table comment `table note`, Dynamic row format, column comment `value note`, and hex default `73656564` | A separate table executes the original CREATE and first INSERT. Query the original option values directly. |
| First generated ID 100, value `first`, binary default `00FF` | Keep that initial table's row `(100,first,00FF)`. |
| ALTER table comment and column comment | A second table executes the prefix through the second INSERT. Check `changed note`, `changed column`, and the modified column definition. |
| Generated IDs 100 and 200 before later UPDATE/DELETE | The second table retains both original rows. |
| LIKE copies the changed definition | Original `copy` remains with `(1,copy,00FF)` and copied table/column metadata. Check its table comment directly. |
| Following UPDATE and DELETE | Original `t` ends with `(100,last,00FF)` and no ID 200. Compare both rows and definitions. |

The proposed two retained tables require seven additional source statements.
They execute their own ALTER prefixes; do not replace them with a clone made
after the operation being tested. Keep source-assigned IDs as the assertion.
Do not substitute an equality check on engine-specific current AUTO_INCREMENT
counters after deletes.

### Table maintenance

Keep all ten original statements and the three restarts: before INSERT while
keys are disabled, before standalone FORCE, and before DELETE after FORCE/ADD.
There is no offline replay in this case today.

| Existing observation | Proposed final result |
|---|---|
| DISABLE KEYS and INSERT/UPDATE/DELETE while disabled | A separate table executes the prefix through those writes. Keep it disabled. Query SHOW INDEX with the existing engine-specific expected value and check rows `(1,11,22)` and `(3,30,60)`. |
| ENABLE KEYS restores a usable index | Another table executes the prefix through ENABLE. Require an empty disabled flag and `FORCE INDEX(by_v)` count 2. Do not apply FORCE to this table: that could hide a failed ENABLE operation. |
| Standalone FORCE retains rows and generated values | A third table executes the prefix through FORCE. Keep both expected rows. |
| Compound FORCE/ADD and following DELETE | Original `t` retains only ID 1 with `v=11`, `doubled=22`, and `note=7`. Check its final schema and rows. |

This design adds 21 source statements in three retained table sets. All final
queries can run together. It retains index-state evidence without an extra
observation wait between each ordinary write. Do not enable the retained disabled
table before checking it. Cleanup may drop it after state checks.

### Validation for slice 1

- Add focused workload/observation tests. Check original SQL order, restart points,
  retained ALTER prefixes, explicit option checks and SHOW INDEX field handling.
- Check the catalog and unchanged matrix. Build the host lab and a matching
  coverage image in OrbStack. Reuse dependency layers.
- Run only `ddl-compat-table-options` and `ddl-compat-table-maintenance` together on
  `mysql84-to-mysql57-myisam`, default variant, SQL transport, with coverage.
- This one profile exercises both InnoDB and MyISAM observation expectations.
  Neither case has alternate transactional SQL. No reverse run is needed for
  this slice unless implementation changes introduce a distinct target path.
- Require named final checks, existing saved-state/GTID assertions, one fixture,
  completed cleanup and coverage export. Inspect a support bundle before retry
  if a case fails. Record SQL calls and setup/test/export times separately.

## Slice 2: validation clauses and ignored CHECK syntax

### ALTER options

Keep all seven original statements, both restart points and replay after the
third transaction. That stop follows COMMENT/ORDER BY. Keep the original prefix
before any added table preparation so this meaning does not change.

Use two retained tables. One executes the prefix through ADD of the virtual
column WITH VALIDATION; it retains `g=n+1`. The other executes the prefix through
MODIFY WITHOUT VALIDATION and UPDATE; it retains `(1,30,32)` and `(2,20,22)`.
Check the ordered table comment, generated definitions, final rows and original
DROP. Keep COMPRESSION/ENCRYPTION in the InnoDB source-SQL alternative. Preserve
successful acceptance of PASSWORD and statistics options. Do not turn their
presence into a claim about effective compression, encryption or physical order.

Run the final queries after live apply and after replay. The two retained tables
add ten statements. Cleanup belongs after the saved-state and replay checks.

### Ignored CHECK clauses

This case can use the current tables without additional copies. Keep all twelve
statements and both restarts. Original `t` ends with three rows; original `copy`
retains the row later deleted from `t` and drops its `note` column. Final exact
queries on both tables can preserve the DML observations without per-step waits.
Keep the direct zero-CHECK-constraint query on every role.

Retain the exact SQLite assertion for the original CHECK-only ALTER:

- DONE intent and the original source SQL are present.
- Target SQL is empty.
- Before and after schema IDs match.
- The recorded rule is `source-before-8.0.16-ignores-checks`.

Replay must still stop after transaction three, the CHECK-only ALTER, then
resume with an unreachable source. Check final rows and zero target constraints.
The current archive label is `checks`, while the case ID is
`ddl-compat-ignored-checks`. When adding final replay observations, pass the real
case ID explicitly or otherwise preserve this mapping. Prefixing the archive
label alone would attach assertions to the wrong case.

Keep the forward exclusion. Do not merge the separate `check-target57-limits`
expected-failure workflow into the shared positive writer. That test has its own
BLOCKED outcome and unchanged-target assertions; it is outside this conversion.

### Validation for slice 2

- Add focused phase/observation tests for both SQL branches, restart/replay points,
  ignored-CHECK inventory and no-op journal checks, and the archive-label mapping.
- Run `alter-options` on forward MyISAM. Then run `alter-options` and
  `ignored-checks` together on reverse InnoDB. Reuse the same coverage image.
- The reverse run is required for COMPRESSION/ENCRYPTION SQL and the 5.7-source
  compatibility rule on an 8.4 target. The MyISAM branch needs the forward run.
  Do not repeat the two 5.7-to-5.7 profiles locally for this shared harness change.
- Preserve catalog applicability and the matrix. No new test group or fixture
  per case. Leave remaining profile/variant combinations to the later full CI run.

## Execution rules and next step

Keep one fixture per selected profile. Cases already share the live writer;
source batches must not launch an applier per ordinary statement. Retain named
restart boundaries and existing saved-state checks during this conversion.
Further sharing of those checkpoints needs its own assertion map.

Record source SQL, warnings, GTIDs and offsets for each statement. The old cases
do not require empty warning output for options ignored by an engine. Keep
warnings as evidence; do not accidentally reject native notes during batching.
All SQL errors must still fail the phase and report the support-bundle path.

The initial review ran no builds, unit tests or containers. It used saved passing
CI measurements, current code and MySQL documentation. The implementation and
focused checks below followed the reviewed order. Reassess the remaining
table/column cases before moving to other feature groups.

## Slice 1 implementation and local results

`table-options` and `table-maintenance` now use source batches and final
observations. Original SQL order, two plus three restarts, profile applicability
and case IDs remain unchanged. The retained tables execute the full operation
prefixes described above. The enabled-index table does not execute FORCE.

Both cases passed in one forward MyISAM fixture in OrbStack, with SQL transport
and runtime coverage. All 32 named assertions passed. Source GTID counts,
applied checkpoints, saved-schema restart and cleanup also passed. The test
image and host lab used matching inputs. No production replication code changed.

| Case | Saved CI SQL calls | Local SQL calls | Saved CI seconds | Local seconds | Named assertions |
|---|---:|---:|---:|---:|---:|
| Table options | 196 | 54 | 38.17 | 29.63 | 17 |
| Index maintenance | 174 | 62 | 41.50 | 32.02 | 15 |

These are harness client calls. The local and CI hosts differ; the times do not
prove a speed ratio. The fixture used 11 source batches, including setup and
cleanup. Fixture setup took 13.49 s: file preparation 0.36 s, container startup
11.34 s and database setup 1.79 s. Coverage export took 5.32 s; cleanup took
9.46 s. These costs are separate from the case times.

Runtime coverage reached 8,591 of 20,880 mapped lines. The saved CI measurement
covers the larger table/column/index group. It is not a per-case coverage baseline.
Do not infer added or lost lines from those two totals.

The first launch stopped before tests because the manually built image lacked
the lab input-digest label. No applier or support bundle existed. The lab wrapper
reused the compiled layers, added the label, and ran the selected cases. The
coverage application build took 229.36 s before that retry.

Evidence:

- `artifacts/lab/20261029T154102Z-b25a68ea/result.json`: passing selection.
- `artifacts/table-options-review/slice1-results.json`: assertions, SQL calls,
  timings, fixture count and coverage.
- `artifacts/table-options-review/source-preservation.json`: unchanged original
  statements and retained-prefix counts.
- `artifacts/table-options-forward-retry.log`: phases and coverage export.

## Slice 2 implementation and local results

`alter-options` now retains separate WITH VALIDATION and WITHOUT VALIDATION
results. It keeps all seven original statements, their order, both restarts and
the original replay stop after COMMENT/ORDER BY. The InnoDB branch retains
COMPRESSION and ENCRYPTION. Both live and replay runs compare the retained rows,
virtual column metadata, table comments and absence of the dropped original.

`ignored-checks` keeps all twelve original statements and both restarts. Its
final checks compare original and copied rows and require zero CHECK constraints.
The original SQLite predicate is unchanged. It now has a named assertion,
`ignored-check-no-op-record`, with its matching-intent count and compatibility
rule in the saved result. The passing reverse run recorded exactly one match.

The replay helper accepts an explicit observation case ID. This keeps archive
label `checks` while storing its four replay assertions under
`ddl-compat-ignored-checks`. Both cases still stop after transaction three and
resume with an unreachable source. The separate expected-failure CHECK case is
unchanged.

| Profile and case | Saved CI SQL calls | Local SQL calls | Saved CI seconds | Local seconds | Named assertions |
|---|---:|---:|---:|---:|---:|
| Forward MyISAM: ALTER options | 126 | 62 | 31.60 | 27.77 | 18 |
| Reverse InnoDB: ALTER options | 125 | 65 | 27.85 | 31.76 | 18 |
| Reverse InnoDB: ignored CHECK | 195 | 59 | 33.09 | 31.52 | 14 |

All assertions, saved-state checks, coverage exports and cleanup passed. The
reverse cases shared one fixture and the image built for the forward case.
The reverse ALTER case took longer than the saved CI case. These runs use
different hosts, and the retained tables add source operations. The SQL-call
reduction is measured; an elapsed-time improvement is not established.

| Measurement | Forward ALTER options | Reverse pair |
|---|---:|---:|
| Source batches, including setup/cleanup | 5 | 9 |
| File preparation | 0.42 s | 0.30 s |
| Container startup | 11.57 s | 15.64 s |
| Database setup | 2.15 s | 1.76 s |
| Total setup | 14.14 s | 17.70 s |
| Coverage export | 5.13 s | 8.03 s |
| Cleanup | 11.04 s | 11.17 s |
| Runtime Swift lines reached | 8,948 / 20,880 | 9,319 / 20,880 |

The coverage scope limit from slice 1 also applies here. Per-case baseline line
sets do not exist. The coverage application build took 217.35 s. Dependency
layers were reused; the reverse run used `--skip-build`.

Evidence:

- `artifacts/lab/20261029T161030Z-454b1271/result.json`: forward ALTER options.
- `artifacts/lab/20261029T162509Z-faaf294c/result.json`: reverse pair.
- `artifacts/table-options-review/slice2-forward-results.json` and
  `slice2-reverse-results.json`: assertions, calls, timing and coverage.
- `artifacts/table-options-unit.log`: ten focused unit tests passed.
- `artifacts/table-options-final-matrix.json`: unchanged job assignments.

## Completion and next review

Both slices are complete. All 82 named integration assertions passed across the
five selected case/profile executions. Harness SQL calls fell from 816 in the
saved CI cases to 302 locally. No case was removed. The matrix remains at 183
jobs, 1,545 obligations and 182 runtime coverage collections. Case IDs and profile
exclusions are unchanged. Titles now use the feature names listed above.

The unit tests check phase boundaries, retained operation prefixes, both source
SQL branches, generated values, index-state field selection and missing/incorrect
observations. Source comparisons also confirm unchanged original SQL and adjacent
workloads. `git diff --check` and the DDL catalog check passed.

This work is committed as `05c520b`. The following
[column-conversion slices](BETA7_COLUMN_CONVERSION_WORKFLOW_REVIEW.md) are complete
and pass focused checks. Next: review remaining index-specific cases and their
execution boundaries. The linked document records the results and next scope.
Keep the full suite for GitHub Actions.
