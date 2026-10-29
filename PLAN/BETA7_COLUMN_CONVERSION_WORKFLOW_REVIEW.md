# Review of column definitions and ALTER conversions

## Decision

The table-option work is committed as `05c520b`. Both column-conversion slices
below are implemented and pass focused local checks. The reviewed order was:

1. Convert `ddl-compat-types` and `ddl-compat-alter` to source batches and final
   checks. Preserve the fixed timestamp used by the ALTER, but reset source
   session state before the next operation.
2. Convert `ddl-compat-alter-conversions`. Retain intermediate column types and
   values in independent tables. Keep its three explicit restarts.

Keep all three case IDs, catalog assignments and profile applicability. They
already share a fixture in `table-column-index-changes`. Do not create new CI
jobs. The implementation removes no tests.

## Names and scope

Consult the MySQL manual before changing case titles. Use these names:

| Case suffix | Proposed title | Scope |
|---|---|---|
| `types` | Column definitions, defaults and automatic DATETIME values | Mixed column definitions, omitted defaults, exact values, timestamp-dependent ADD, UPDATE and DELETE. This is not a complete data-type range test. |
| `alter` | ALTER TABLE: compound column and primary-key changes | ADD, CHANGE, SET/DROP DEFAULT, secondary indexes and replacement of a primary key. |
| `alter-conversions` | ALTER TABLE: convert existing indexed column values | MODIFY/CHANGE through VARCHAR, DECIMAL, DOUBLE, INT and BIT, with following writes and saved-schema restart. |

MySQL describes CHANGE and MODIFY as operations that can change column types
and convert existing values. Replacement definitions must restate attributes
that must remain. These rules make conversion of populated tables distinct from
inserting values into a table that already has the final type.
[ALTER TABLE manual](https://dev.mysql.com/doc/refman/8.4/en/alter-table.html).

DATETIME columns can have automatic initialization and automatic update clauses.
An update to another value can therefore change the DATETIME value. Preserve
that effect in both the source workload and final checks.
[Automatic initialization and updating](https://dev.mysql.com/doc/refman/8.4/en/timestamp-initialization.html).

## Baseline and coverage limits

Use successful full CI run `40454033524`, commit `efb3458`. Its summary and
report are complete. Source comparisons confirm that all three case bodies are
unchanged from that baseline. The shared runner has since changed.

Each cell is **case seconds / harness SQL client calls**, for default SQL runs.

| Case | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 InnoDB | 5.7 → 5.7 MyISAM |
|---|---:|---:|---:|---:|
| `types` | 18.07 / 114 | 14.61 / 113 | 18.09 / 113 | 18.16 / 113 |
| `alter` | 22.51 / 153 | 17.98 / 152 | 22.61 / 152 | 22.29 / 152 |
| `alter-conversions` | 47.90 / 231 | 40.35 / 230 | 48.06 / 230 | 48.81 / 230 |

Together, these cases used 498 calls on forward MyISAM and 495 on each other
profile. These counts are harness calls, not target-applier statements. The
forward case times total 88.48 s. Added source statements can offset some of the
saving from fewer client calls; measure the result instead of predicting it.

Saved artifacts:

- `artifacts/column-conversion-review/baseline.json`: case costs and SQL categories.
- `artifacts/column-conversion-review/source-comparison.json`: unchanged case bodies.
- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.

Runtime coverage belongs to the whole table/column/index group. It cannot show
which of these cases owns a line. The existing group analysis records hundreds
of lines absent from other default groups. Shared lines do not establish that
these assertions are redundant. See the
[group coverage analysis](BETA7_TABLE_COLUMN_INDEX_REVIEW.md#what-the-coverage-comparison-shows).

## Session-state requirement

`types` currently sends this as one operation:

```sql
SET SESSION timestamp=1700000000.123456;
ALTER TABLE ddlcompat.t
  ADD observed DATETIME(6) NOT NULL
  DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6);
```

The next UPDATE uses a new source client in the old `step` runner. It therefore
uses current time. `LabSQLPhase` instead reuses a client. Its profile session
setup resets encoding, time zone and SQL mode, but not `timestamp`.
`DDLExecutionPhase.writes` resets the two AUTO_INCREMENT session variables only.
A direct conversion to one batch would leave the fixed timestamp active.

Reset `SESSION timestamp=DEFAULT` before each DDL phase operation, beside the
existing per-operation AUTO_INCREMENT resets. Then append the original operation
unchanged. Its explicit SET overrides the reset for that operation alone. Add
unit checks for the reset order and for the following operation. This is a lab
source-session change; it does not change the applier's target session policy.

MySQL documents that a constant timestamp remains active until changed, while
DEFAULT restores the current time when accessed.
[Timestamp session variable](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_timestamp).

Do not append the reset after the ALTER: the phase recorder reads SHOW WARNINGS
immediately after an operation, and an extra statement there can replace those
diagnostics. Do not replace the timestamp-dependent ALTER with a fixed literal
default. That would remove the behavior being tested.

## Slice 1: definitions and compound ALTER

### `types`

Keep all five original operations in order. There are no explicit restarts and
no offline replay in this case. Keep its FULL optional-metadata selection on an
8.4 source; ENUM/SET label checks still require it.

Use three retained tables. Each executes the full original prefix with only the
table name changed. Do not create these with CREATE TABLE LIKE after an ALTER.

| Table state | Prefix length | Final observations |
|---|---:|---|
| Initial inserted row | 2 | ID 1, tiny default -7, DECIMAL 1.250, payload bytes 00FF, ENUM default `a`, SET `x,y`, VARCHAR default `hello`; compare all other stored values and initial schema. |
| After timestamp-dependent ADD | 3 | `observed=2023-11-14 22:13:20.123456`, numeric default 7 and BINARY bytes 6869000000. Check DATETIME precision, default and ON UPDATE metadata. |
| After UPDATE | 4 | Amount 42.125, note `changed`, VARCHAR `next`; require the automatic DATETIME value to differ from the earlier fixed value and match native/source rows. |
| Original table after DELETE | 5, original sequence | Zero rows, complete final definition and indexes. |

The retained tables add nine operations, for fourteen total. Run the whole source
sequence in one phase, followed by one final set of queries. The session reset
prevents the timestamp override from reaching a following UPDATE or retained
CREATE/INSERT. Use exact values for fixed inputs. Do not require a wall-clock
range for the automatic update; compare the source and replica values instead.

The generic snapshot covers full row bytes, column types/defaults/extra fields,
column order and index definitions. Keep explicit assertions for the known
numeric, padded binary and timestamp values. Text/binary defaults in the shared
snapshot use normalization, so row-value checks must not be removed.

### `alter`

Keep all eight original statements in order. There are no explicit restarts and
no offline replay. Use three retained tables, with prefixes of two, four and six
statements. These add twelve statements, for twenty total.

| State | Final observations |
|---|---|
| Original CREATE and first INSERT | Original VARCHAR default `seed`, primary key and `by_label` index; row `(1,seed)`. |
| Compound ADD/CHANGE/default/index and second INSERT | Rows `(1,seed,-2.50)` and `(2,renamed,-2.50)`. Check renamed column, both secondary indexes, new defaults including ID default 10. Preserve ALGORITHM=COPY and LOCK=EXCLUSIVE in the source SQL. |
| Replacement primary key and UPDATE | Rows with dates `2026-01-01` for ID 1 and `2026-02-01` for ID 2; caption `moved` for ID 2. Check primary-key order `(report_date,id)`. |
| Original DROP COLUMN/DROP DEFAULT and DELETE | Only ID 1 remains. Caption and its dependent index are absent, amount has no default, and the composite primary key remains. |

Use one phase and final checks. The second retained table must run the compound
ALTER before the omitted-column INSERT. Merely creating the final definition
would not check preservation of `seed` in the existing row. Check ID default 10
through metadata; the existing workload does not insert an omitted ID, so do not
claim that it tests this default through DML.

### Validation for slice 1

- Add focused unit tests for the two workloads and timestamp reset. Check original
  SQL order, retained prefixes, expected values and absence of invented restarts.
- Run the existing `DDLExecutionPhaseTests` and affected final-observation tests.
  The helper's unit checks must preserve both AUTO_INCREMENT resets and its
  transactional-SQL selection. Do not run parser tests.
- Check the DDL catalog and matrix. Build the host lab and matching coverage image
  through the lab wrapper in OrbStack, so the input-digest label is present.
- Run only `ddl-compat-types` and `ddl-compat-alter` together on forward MyISAM,
  default variant, SQL transport, with coverage. This includes an InnoDB source
  and MyISAM targets. There is no alternate transactional SQL in these cases.
- Require named final checks, exact GTID counts, saved-schema restart, one fixture,
  cleanup and coverage export. Compare SQL calls and separate setup/test times.
- Leave 5.7-source and remaining variants to CI. Add another local profile only
  if implementation introduces a distinct engine/version path or finds a defect.

## Slice 2: conversions of existing indexed values

Keep all fourteen original statements and the three restarts: before the VARCHAR
UPDATE, the DOUBLE UPDATE, and the BIT UPDATE. There is no offline replay today;
this conversion does not need to add one.

Use six retained tables and the original final table. Each retained table runs
the entire original prefix through its listed operation. These add 39 statements,
for 53 total. Keep the original fourteen first, with their restart boundaries.
Put retained-table preparation into the last phase.

| Retained state | Prefix length | Required result |
|---|---:|---|
| Initial INT | 2 | Rows 12 and 34, default 7, non-null column and `by_n` index. |
| VARCHAR | 3 | Text values `12` and `34`, default `9`, original index. |
| DECIMAL after default INSERT | 6 | Existing values 56.00 and 34.00 through FORCE INDEX(by_n); separate ID 3 default value 3.50. Index now refers to `amount`. |
| DOUBLE after UPDATE | 8 | Values 56, 78 and 3.5. Compare the native stored values, default 4 and index metadata. |
| INT before DELETE | 9 | Native conversion of all three rows, including fractional ID 3. Keep this row: deleting it before comparison would hide a wrong conversion. |
| BIT after DELETE | 11 | IDs 1 and 2 with numeric values 56 and 78; ID 3 absent. Check BIT(8), binary default and index metadata. |
| Original final INT | 14 | Rows `(1,100)`, `(2,78)` and `(4,5)`, final default 5, non-null definition and index. |

Do not infer a fixed INT rounding result from the source SQL alone. Compare the
retained fractional row with source and native first, and record that result if
an explicit value is added. Preserve the existing DECIMAL formatting assertion
and numeric BIT query (`amount+0`). Keep exact row/schema comparison for every
retained table. A final INT-only table cannot prove the intermediate types or
defaults.

The extra source statements are deliberate. They allow a final comparison
without a client read and replica wait after every original operation. Measure
the cost. Do not discard an assertion solely to reduce statement count.

### Validation for slice 2

- Add focused unit checks for all six prefixes, three restarts, default values,
  renamed index column, fractional row retention and final DELETE/INSERT effects.
- Reuse the existing final-observation and phase helpers. Run only affected unit
  tests and catalog/matrix checks.
- Run only `ddl-compat-alter-conversions` on forward MyISAM/default/SQL with
  coverage and one fixture. It has no profile exclusion or transactional-SQL
  alternative. Leave the other profiles to CI unless a new distinct path appears.
- Require existing checkpoint and saved-schema checks, final comparisons, cleanup
  and coverage export. Inspect a support bundle before retrying an applier failure.

## Next step

The implementation followed the reviewed order: slice 1, measurement, then
slice 2. Case IDs and job assignments remain unchanged. The initial review
required no build or database run. Results below record the focused checks.
The remaining index-specific cases still need review.

## Slice 1 implementation and results

`types` and `alter` now use one source batch each and final observations.
Their original five and eight operations are unchanged. Retained tables execute
complete prefixes; no post-ALTER CREATE LIKE replaces an operation under test.
The case IDs, FULL optional-metadata rule for `types`, saved-state checks and
profile applicability remain unchanged.

The phase writer resets the source timestamp before each operation, alongside
its existing AUTO_INCREMENT resets. The original timestamp-dependent ALTER
still sets its fixed timestamp. The final check confirms that a later UPDATE
changes the automatic DATETIME value and matches native replication. SHOW
WARNINGS still follows the operation directly. No target-session policy changed.

Both cases passed in one forward MyISAM/default/SQL fixture in OrbStack with
coverage. All 22 named assertions, GTID/checkpoint checks, saved-schema restart,
coverage export and cleanup passed.

| Case | Saved CI SQL calls | Local SQL calls | Saved CI seconds | Local seconds | Named assertions |
|---|---:|---:|---:|---:|---:|
| Column definitions | 114 | 37 | 18.07 | 11.24 | 9 |
| Compound ALTER | 153 | 35 | 22.51 | 10.74 | 13 |

Together, client calls fell from 267 to 72. These are harness calls, not target
SQL statements. The local and CI hosts differ, so the elapsed times do not
establish a speed ratio. The fixture used six source batches including setup
and cleanup. Total fixture setup took 14.21 s: files 0.35 s, container startup
11.67 s and database setup 2.19 s. Coverage export took 2.58 s; cleanup took
10.28 s. These costs are separate from the case times.

Runtime coverage reached 8,659 of 20,880 mapped Swift lines. The saved CI data
covers the larger table/column/index group. It is not a per-case line baseline.
Do not infer added or lost coverage from those totals.

Evidence:

- `artifacts/lab/20261029T171253Z-df5b70b7/result.json`: passing selection.
- `artifacts/column-conversion-review/slice1-results.json`: assertions, SQL calls,
  fixture count, timing and coverage.
- `artifacts/column-conversion-review/source-preservation.json`: unchanged
  original operations and statement counts.
- `artifacts/column-definitions-forward.log`: source phases and coverage export.

## Slice 2 implementation and results

`alter-conversions` now uses four source batches between its three original
restart points. All fourteen original statements are unchanged and remain first.
Six retained tables execute the reviewed prefixes. Final checks include exact
values, DECIMAL formatting, BIT numeric values, defaults, nullability and the
index's renamed column. The shared snapshot compares every retained row and
column definition with source and native replication.

The retained fractional row is present after conversion to INT. The saved
snapshot records `(3,4)` on source, native and target. This result would be lost
if the harness checked only the original table after DELETE. The test compares
native/source/target values instead of imposing that rounding result on every
profile without observation.

The forward MyISAM/default/SQL case passed in one OrbStack fixture with coverage.
All 20 named assertions, GTID/checkpoint checks, saved-schema restart and cleanup
passed. Harness SQL calls fell from 231 to 63. Case time was 34.01 s locally,
compared with 47.90 s in saved CI. The hosts differ; these times do not establish
a speed ratio.

The run used six source batches including setup and cleanup. Fixture setup took
12.84 s: files 0.32 s, container startup 10.64 s and database setup 1.88 s. Coverage
export took 3.90 s; cleanup took 10.95 s. Runtime coverage reached 8,180 of 20,880
mapped Swift lines. The per-case baseline coverage limit also applies here.

Evidence:

- `artifacts/lab/20261029T171913Z-a89bc10f/result.json`: passing selection.
- `artifacts/column-conversion-review/slice2-results.json`: counts and timings.
- The fixture's `assertions/ddl-compat-alter-conversions/final-schema-ddlcompat.json`:
  matching intermediate rows and definitions, including the fractional row.
- `artifacts/column-conversions-forward.log`: source phases and coverage export.

## Completion and next review

Both slices are complete. Across three case executions, all 42 named integration
assertions passed. The 20 focused unit tests passed, including phase planning,
session reset order, both SQL selections, retained prefixes, wrong-value detection
and final-observation validation. The original 27 operations and three deliberate
restarts remain. No case was removed and no replay workflow was added.

Harness SQL calls fell from 498 to 135. Case times total 55.99 s locally versus
88.48 s in saved CI, on different hosts. Each selection used one fixture and
finished cleanup and coverage export. Coverage-image application builds took
217.41 s and 223.33 s; dependency layers were reused. No full suite was run.

The DDL catalog check and `git diff --check` passed. The matrix still has 183 jobs,
1,545 obligations and 182 runtime coverage collections. All job assignments and
profile exclusions are unchanged. `source-preservation.json` confirms original
SQL order; focused unit tests verify the retained prefixes.

Next: review the remaining index-specific cases in `table-column-index-changes`,
starting with spatial-column prefix indexes and generated JSON-column indexes.
Check the existing FULLTEXT workflow's execution boundaries in the same review.
Map assertions and required observations before selecting another conversion.
Use saved SQL, timings and group-level coverage; this review needs no build or
database run. Keep the later full suite in GitHub Actions.
