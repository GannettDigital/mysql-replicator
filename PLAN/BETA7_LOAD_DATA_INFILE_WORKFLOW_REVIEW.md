# LOAD DATA INFILE workflow

Status: implemented after the JOIN consolidation commit `5956130`. The focused
8.4 → 5.7 MyISAM default SQL run passed, including its saved-schema restart and
complete report. All eight selected Swift tests and 62 Python tests passed.
Other profiles and variants remain for CI.

## Existing checks and overlap

`matrix-load` has one source phase. It exports `(1,10),(2,20)` with SELECT INTO
OUTFILE, then imports that file with LOAD DATA INFILE. The table has an integer
PRIMARY KEY and a non-NULL integer value. The old predicate requires two rows
and a value sum of 30. The ordinary runner also compares schema and rows on
source, native replica and target.

The integer row format is covered elsewhere. The source file import is unique:
no other lab case uses LOAD DATA. Keep this operation. Do not remove it because
it produces INSERT row events. The saved evidence reviewed for the preceding
slice contains passing executions in all ten original SQL selections. It has
no per-case exclusive line set. Do not infer zero added code coverage.

The name follows the MySQL [LOAD DATA Statement](https://dev.mysql.com/doc/refman/8.4/en/load-data.html).
This is a server-side file import, without LOCAL. The source reads the file.
The profiles use row-based binlogs. Native MySQL applies the logged rows rather
than reading this source file on the replica. See
[Replication and LOAD DATA](https://dev.mysql.com/doc/refman/8.4/en/replication-features-load-data.html).
The pinned 8.4 source also flushes pending row events in `sql/sql_load.cc`.

## Fixture and execution

Use the existing `keys-rows-gtids` fixture. The old case already belongs there.
Its source versions, engines, GTID settings and table filters need no change.
Do not create another CI area, fixture, container setup or applier.

Replace the catalog ID with `dml-load-data-infile`. Keep one public case because
the file operation is a distinct source condition. Keep its primary feature as
Data Manipulation Statements. Other cases need no additional LOAD DATA variants.

Use the existing running applier. Submit one source batch with three operations:

1. Create the same table definition as before, named `poc.load_data_infile`.
2. Write the same rows to `/var/lib/mysql-files/replicator-dml.tsv`.
3. Import that file with the original LOAD DATA INFILE statement.

The expected source transaction counts are `[1,0,1]`. File export must leave
both the GTID set and file/offset unchanged. Separate operation markers retain
this proof inside one client batch. Do not wrap the operations in a transaction.
Do not restart or drain the applier inside the case.

At the end, compare the original count/sum predicate and exact rows `(1,10)` and
`(2,20)` on source, native and target. Compare schema and all rows in one final
snapshot. Check counter deltas: two transactions, one DDL and two inserted rows.
Require the exact applied GTIDs, binlog file and offset at the batch end.
The existing outer saved-schema restart checks durable state after this case.

Keep the source file until fixture cleanup. Each case runs once per fixture;
the source volume is separate for each profile and variant. No second file,
history table or file-removal command is needed. Setup and source-SQL failures
use the existing harness report and support-bundle collection path.

## Selection and migration

Keep the original ten SQL profile/variant selections. Rename the case in the
existing CI area. Do not add BINLOG transport or without-source-gtids selections
in this slice. Keep the old definition for metadata equivalence and migration
history. Requests for matrix-load must name the replacement.

Map every retained condition to its named assertion. Update the old metadata
migration's retained DML owner. Require `load-source-operations`,
`load-import-count-and-sum`, `load-imported-rows`, `final-schema-poc` and
`load-applied-checkpoint` in every original selection. Keep one primary feature
assignment and no duplicate scheduling.

Verified plan: 183 jobs, 1,535 catalog obligations and 182 coverage collections.
The only selection change is matrix-load to dml-load-data-infile in ten scopes.
The JSON migration and its 11 old observations remain unchanged.

## Local verification

Run the focused LOAD DATA unit tests, metadata-owner checks and Python migration,
feature, selection and matrix checks. Compare the generated before/after plans.
Verify old CLI requests report the replacement. Finish all code and test edits
before integration. Hold those inputs unchanged until the complete report ends.

Then run only the changed case on forward default SQL, with coverage:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam \
  ARGS="--suite correctness --case dml-load-data-infile --coverage"
```

Use the support bundle before any failed-run retry. Leave the other profiles,
variants and full group to CI. No parser tests are needed. This slice does not
claim tests of LOCAL, custom file delimiters, import errors or all LOAD DATA
options. These are untested source combinations, not new support restrictions.

Evidence belongs in `artifacts/load-data-infile-review/`.

## Focused results

Eight focused Swift tests passed. They check the original SQL and definition,
exact final rows, unlogged export, GTID transaction counts, applied counters,
exact positions, CLI replacement and metadata owners. All 62 focused Python
migration, feature, selection and matrix tests passed.

The generated before/after plans retain 183 jobs, 1,535 catalog obligations and
182 coverage collections. The only case-list changes rename matrix-load to
dml-load-data-infile in ten existing keys-rows-gtids selections. All other case
lists and group IDs match. No BINLOG selection is added. Old CLI requests return
the replacement name. See `selection-results.json`, `before-plan.json` and
`after-plan.json` under `artifacts/load-data-infile-review/`.

Unit logs are `unit.log` and `selection-unit.log` in that directory.

The focused default SQL integration run passed on 8.4 → 5.7 MyISAM. All five
named assertions passed. Source operation counts were exactly `[1,0,1]`; the
export left both GTIDs and the file/offset unchanged. Exact rows and schema
matched source, native and target. The applied counters and checkpoint matched.
The shared saved-schema restart, coverage collection and final input check also
passed. The case uses the existing containers and applier. It adds no extra
table or case restart.

The case took 2.13 seconds, excluding fixture setup. Saved CI measurements for
the old case were 2.33–3.00 seconds on different profiles and hardware. These
numbers do not establish a speed improvement. The purpose is clear selection,
shared execution and retained assertions. Coverage for the selected fixture is
7,030/20,880 runtime lines (33.67%), not an exclusive contribution from LOAD DATA.

Passing report: `artifacts/lab/20261107T010924Z-be2c48ef/result.json`.
Case evidence is under
`mysql84-to-mysql57-myisam/correctness/default/20261107T011333Z-176dbc4e-auto-autocommit-myisam/`
inside that run. The fixture contains `cases.json`, per-assertion files, the
captured source phase and `code-coverage/combined/index.html`.
`workflow-results.json` records the result and `integration.log` keeps the run
output in `artifacts/load-data-infile-review/`.

Next: keep the other profiles and variants for CI. Review the remaining group
boundaries before full-matrix validation, final balancing and PR test selection.
Do not add another LOAD DATA fixture.
