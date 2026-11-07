# INSERT SELECT and JOIN overlap review

Status: implemented. The focused JSON case, saved-schema restart and complete
lab report passed on 8.4 → 5.7 MyISAM, default SQL. The standalone matrix-select
case is retired. Migration and selection checks retain all ten original SQL
selections. Other profiles and variants remain for CI.

The earlier proposal to rename and convert `matrix-select` as a standalone
workflow is withdrawn. Leave `matrix-load` and its proposed
`dml-load-data-infile` name aside for now.

## Decision

Do not build `dml-insert-select-update-join-delete-join` as another independent
case. Most of its behavior already has coverage. Preserve the remaining source
SQL conditions inside the existing JSON generated-column/index case, then retire
`matrix-select` after its replacement passes.

There is no current catalog ID `dml-insert-select-update-json`. The relevant
existing case is `ddl-compat-json-indexes`, titled **Secondary indexes on
generated columns derived from JSON**. It already includes INSERT ... SELECT,
UPDATE and DELETE. Its INSERT SELECT copies JSON documents into a table with
generated columns and indexes.

The separate JSON value cases remain necessary. Their JSON null/type, exact
numeric/temporal values, partial-update events and generated-index conditions
are not replaced by plain integer INSERT/UPDATE/DELETE tests.

## What actually overlaps

| Condition in matrix-select | Existing test | Assessment |
|---|---|---|
| Two inserted rows with integer PRIMARY KEY and NOT NULL integer value | `ddl-compat-constraints`, `matrix-integers` and other type cases | Already tests the ordinary row mutations and exact values. |
| INSERT ... SELECT from another table | `ddl-compat-json-indexes`, primary-key prefix, partition, collation and FULLTEXT cases | Source SQL form already exists. The JSON case also checks copied values and generated indexes. |
| Derive IDs/values from SELECT input | `ddl-compat-temporary-create-select` | Computes id+10 and changed values; checks exact permanent rows. The literal sums 90 and 32 do not add an applier operation. |
| UPDATE with JOIN and untouched neighboring rows | `ddl-compat-temporary-create-select` | Positive case with exact rows, including unaffected rows. Its input is temporary. |
| UPDATE JOIN involving ordinary permanent tables | `wild-ignore` | Positive mixed-filter case; compares exact native/target binlog row operations. Both source tables change, with one excluded from replication. |
| One changed permanent table with a permanent read-only JOIN input | No exact counterpart among those cases | Retain this condition in the JSON workflow using its existing t/copy pair. |
| Successful DELETE with JOIN | Only matrix-select in the current positive workloads | Retain this source SQL form before deleting the old case. Ordinary DELETE is already covered. |

The filter case is positive coverage, not an expected-rejection case. It updates
an included table and an ordinary table in the ignored `temp` database. That
schema name does not make the table temporary.

Relevant existing assertions are `like-copy-before-update` in the JSON case,
`insert-from-temporary-rows` and `update-join-rows` in the temporary-table case,
and `normalized-binlog` in `wild-ignore`.

## Product code versus SQL catalog coverage

In the ROW profile, source MySQL computes the SELECT expressions and JOIN
conditions. Our target execution chooses INSERT, UPDATE or DELETE from
`row.operation` in `TargetSession.swift`. It does not evaluate those source
expressions or run the original joined SQL. Transaction assembly handles the
resulting table-map and row events.

This explains why a separate arithmetic sequence on ordinary integer rows has
little additional product value. It does not prove byte-for-byte equality of
all binlog events. Keep one end-to-end check of the source SQL forms, including
the previously unmatched DELETE JOIN, inside an existing workflow.

JSON is different. Its decoding, SQL value transport, type preservation,
partial-update events and generated-column/index handling have separate
conditions. Keep `matrix-json`, `matrix-typedjson`, `matrix-jsonpartial` and the
JSON index checks. Repeated INSERT/UPDATE verbs are not a reason to remove
those data-type assertions.

The saved coverage is for complete fixture groups. It cannot identify exclusive
lines for matrix-select. The removal recommendation comes from source SQL,
row/data shapes, existing assertions and profile scopes, not a per-case line
coverage claim.

## Smallest replacement in the existing JSON workflow

Use its existing permanent `ddlcompat.t` and `ddlcompat.copy` tables. Add no
fixture, standalone case, retained integer tables or generic setup API.

1. Keep the existing INSERT SELECT and `like-copy-before-update` assertion.
   It already checks copied rows, including a SQL NULL JSON document.
2. Change the final copy UPDATE to use a JOIN with t as the read-only input.
   For example, derive n=50 from the source row's n=40 while keeping the expected
   final name/value. Keep `renamed-index-updated-lookup` and the stored/virtual
   profile definitions unchanged.
3. Add a DELETE JOIN against copy, with t as the read-only input. Delete one
   copied row while keeping the source row and the other copy rows.
4. Add named assertions for exact final copy rows, an unchanged t input and
   absence of the deleted value through the renamed generated-column index.
   Keep the existing pre-update copy state and all prior JSON/index assertions.
5. Keep the two deliberate restarts, the phase structure and engine-specific
   STORED/VIRTUAL definitions. Update explicit operation counts for the one
   added DELETE. Do not add a restart or a container setup.

The source sequence is:

```sql
UPDATE ddlcompat.copy c JOIN ddlcompat.t s ON c.id=s.id
SET c.doc=JSON_OBJECT('name','final','n',s.n+10) WHERE c.id=4;
USE ddlcompat;
DELETE c FROM ddlcompat.copy c JOIN ddlcompat.t s ON c.id=s.id WHERE s.id=1;
```

This preserves the existing final lookup `(4,final,50)`. The exact copy rows
are `(3,NULL,NULL)` and `(4,final,50)`. The read-only t rows remain
`(1,gamma,30)`, `(3,NULL,NULL)` and `(4,delta,40)`. The existing retained
`ji_copy` still preserves all three rows before the final update/delete.
The names follow MySQL's [UPDATE](https://dev.mysql.com/doc/refman/8.4/en/update.html)
and [DELETE](https://dev.mysql.com/doc/refman/8.4/en/delete.html) JOIN syntax.
The source step selects ddlcompat before the aliased DELETE JOIN.

## Safe retirement and feature records

The JSON index case has the same ten selected SQL profile/variant scopes as
matrix-select. Both cover all four profiles. Neither has an additional BINLOG
selection. The replacement therefore needs no new profile or job.

Before removal, record a migration from `matrix-select` to
`ddl-compat-json-indexes`. Require the existing INSERT SELECT assertion and the
new JOIN assertions in all ten scopes. Explain that the old integer arithmetic
predicates are intentionally retired because their row handling is covered
elsewhere and MySQL computes their expressions.

The feature registry currently allows one primary owner per case. JSON indexes
belongs to `json-data-type`; matrix-select belongs to
`data-manipulation-statements`. Preserve that distinction for scheduling, but
record the additional DML conditions and their replacement assertions. Do not
schedule the JSON case twice merely to give it two labels. Ensure feature
selection/reporting still directs engineers to the replacement JOIN checks.
Resolve those references before declaring retirement complete.

Then remove only the replicated matrix-select catalog entry and CI selection.
Keep its reviewed definition where still needed for history or metadata mapping.
Use the existing replacement error for the old CLI ID. Update the feature and
bootstrap migration references. Do not introduce another public ID for the
same scalar fixture.

Verified full-plan result: 183 jobs and 182 coverage collections remain; catalog
obligations fall from 1,545 to 1,535 because ten duplicate selections are retired.
The generated before/after plans verify this result. All mapped SQL conditions
remain in their original selections.

## LOAD DATA stays aside

Do not change or rename matrix-load in this slice. Keep its server-side file,
original LOAD DATA SQL and single data-changing phase. Its input-file behavior
is different from the JOIN sequence. No extra history or cleanup API is needed
for the proposed JSON consolidation.

## Evidence and verification scope

Source/measurement inventory: `artifacts/insert-select-load-data-review/review.json`.
Overlap and scope audit: `artifacts/insert-select-load-data-review/overlap-review.json`.
The saved baseline is complete run `40454033524` at `efb3458`. The two old cases
have 20 passing SQL executions in that run. Default matrix-select cost was
5.65–7.63 seconds and 69–70 harness calls. Do not compare whole-group coverage as
if it belonged to this case alone.

For implementation, run focused JSON workflow, migration, feature-reference and
selection unit tests. Verify all previous JSON/index assertions plus the new JOIN
checks. Check the unchanged STORED/VIRTUAL branches and complete ten-scope map.
Build once, then run only `ddl-compat-json-indexes` on default SQL,
8.4 → 5.7 MyISAM, with coverage. Use the support bundle first on failure.
Do not rerun matrix-select, LOAD DATA, other profiles or the full group locally.
Leave the cross-profile runs to CI. No parser/syntax tests are required.

The replacement must pass before retirement. The implementation results below
record the case result separately from the complete lab report.

## Implementation and focused results

The JSON case now has 21 source operations and 14 final observations. It keeps
all 11 old observations, both storage definitions, three source batches and the
two deliberate restarts. The new checks compare exact final copy rows, unchanged
input rows and absence of the deleted value through the renamed index. No table,
fixture or restart was added.

The first focused run failed on the source with error 1046, **No database
selected**, at the aliased DELETE JOIN. The support bundle had a STOPPED state
and no pending groups. The source step now selects ddlcompat before DELETE.
This USE does not add a logged transaction. The corrected focused unit test
passed. The integration retry uses the same case and forward default SQL profile.
The failed run and bundle remain under
`artifacts/lab/20261107T000937Z-56b01713/`. Attempt details are in
`artifacts/insert-select-load-data-review/attempts.json`.

The second run passed the JSON case, all 21 named assertions and the saved-schema
restart. Its outer report failed the input check because files changed during
the run. This report is not a passing integration result. Keep it under
`artifacts/lab/20261107T001549Z-c48d6e71/`. The final run uses the completed
retirement changes and holds code inputs unchanged until the report completes.

The retirement uses the existing replicatedReplacement field. It retains the
old select definition for metadata mapping and migration history. Requests for
matrix-select now name ddl-compat-json-indexes as its replacement. No new case
ID or fixture is added. The metadata migration points to the JSON replacement.
The new migration also requires `ddl-compat-constraints` and
`ddl-compat-temporary-create-select` in all ten original scopes.

Five focused Swift tests passed. They check the JSON definitions, both storage
branches, phase structure, assertions, original selections, CLI replacement
message and metadata owners. All 61 focused Python migration, feature, selection
and matrix tests passed. No parser tests, other profiles or full group ran.

The generated before/after plans retain 183 jobs and 182 coverage collections.
Catalog obligations fall from 1,545 to 1,535. The only removed selections are
the ten matrix-select selections. The JSON replacement runs in every one of
those scopes and retains all 11 old final observations. No case is added to a
different group. The feature remains json-data-type; both the JSON and Data
Manipulation Statements descriptions identify its INSERT SELECT/JOIN checks.
LOAD DATA is unchanged. See `before-plan.json`, `after-plan.json` and
`retirement-results.json` under `artifacts/insert-select-load-data-review/`.

The final run passed with unchanged code inputs. All 21 named case assertions
passed, including all 14 final observations and both planned restarts. The shared
saved-schema restart also passed. The case took 28.74 seconds; this is not a
comparison with CI hardware. The complete fixture collected runtime coverage
of 8,651/20,880 lines (41.43%). This is selected-fixture coverage, not exclusive
coverage for either source SQL form.

Passing report: `artifacts/lab/20261107T002254Z-b490d712/result.json`.
The case and per-assertion evidence are under
`mysql84-to-mysql57-myisam/correctness/default/20261107T002701Z-d7d6eef5-auto-autocommit-myisam/`
inside that run. The coverage report is `code-coverage/combined/index.html` in
the fixture. `workflow-results.json` records the passing result and required
migration assertions. Unit logs are `retirement-unit.log` and
`selection-unit.log`. All three attempts remain recorded; do not treat the
second attempt's passed case as a passed outer report.

Next: leave the other profiles and variants to CI. Keep full-matrix validation,
final balancing and short PR selection later. LOAD DATA stays aside.
