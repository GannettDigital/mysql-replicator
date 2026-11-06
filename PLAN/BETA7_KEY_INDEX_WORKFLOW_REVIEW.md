# Key and index workflows: area completion and next changes

Status: shared index execution is implemented. All 57 original assertions and
the shared restart check passed on 8.4 → 5.7 MyISAM. Eleven focused unit tests
passed. The source and saved-evidence review preceded this implementation at
`97da9d6`. Case selection and CI jobs remain unchanged.

## Type/value area completion

All 23 matrix type/value cases now use the shared execution workflow. Their
saved local reports contain 391 passing named assertions. Nineteen cases ran
on 8.4 → 5.7 MyISAM. The four legacy floating AUTO_INCREMENT cases ran on
5.7 → 5.7 MyISAM. These are selected local results, not four-profile results.

Twenty-two reports include a passing saved-schema restart check. `matrix-json`
passed its case assertions, but its first fixture stopped at a later typed-JSON
expectation failure. That fixture did not reach the outer restart check. The
corrected `matrix-typedjson` run passed its own restart check. Keep this limit
when reporting completion.

Partial JSON retains source-event and offset checks. The isolated
`json-year-compatibility` and `large-values` runners are unchanged from the
successful CI baseline. Their restart, replay and recovery checks remain.
See [the type/value results](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md).

The generated full matrix remains 183 jobs, 1,545 catalog obligations and
182 integration coverage collections. The type/value area owns 30 IDs after
the related JSON and spatial cases moved into its existing fixture. No new
whole-area timing or coverage measurement exists for these conversions.

## Fixture decision

Use the existing `keys-rows-gtids` group and its `LabFixture`. It already owns
all 12 standalone index cases. They share containers and the ordinary applier.
There is no need to move them to another group or add a CI job.

Use the execution pattern in `ModifyColumnsWorkflow.swift`. Prepare distinct
tables on the source, send source changes in batches, and compare results in
batches. Drain and save state at the shared boundary. The previous index runner
drained and restarted the applier after every case. The new runner uses one
shared checkpoint and restart.

Do not move these cases into the generic final-row helper without their other
checks. Their contract includes independent metadata expectations, SQLite
schema history and normalized binlog comparisons. Here, normalization removes
MySQL's printed type annotations before comparing the decoded SQL and row
values from source, native replica and target.

Consult the MySQL manuals before changing feature names. Use CREATE INDEX,
DROP INDEX, ALTER TABLE, UNIQUE indexes, index prefixes and primary keys as the
feature names. A feature section does not require a separate container group.

## Saved measurements

The baseline is complete CI run `40454033524`, commit `efb3458`. All 12 index
definitions still match that commit, including seed SQL, metadata expectations,
following writes and expected rows. All 48 default SQL executions passed.

These totals cover only the 12 cases. SQL calls are harness client calls, not
statements executed by the applier. Case time excludes the separate fixture
setup phase. Differences between machines prevent a direct speed comparison
with a future local run.

| Profile | Case seconds | Client calls | Schema-comparison calls |
|---|---:|---:|---:|
| 8.4 → 5.7 MyISAM | 213.75 | 1,692 | 360 |
| 5.7 → 8.4 InnoDB | 260.32 | 1,692 | 360 |
| 5.7 → 5.7 MyISAM | 252.43 | 1,692 | 360 |
| 5.7 → 5.7 InnoDB | 256.87 | 1,692 | 360 |

Coverage was collected for the whole `keys-rows-gtids` fixture. It cannot show
which index case owns a line. The four saved fixtures execute 11,144–12,379
lines. They retain 26–145 lines absent from other default SQL correctness
groups on the same profile. These counts do not prove any case is redundant.

The local audit is `artifacts/key-index-completion-review/review.json`.
Its `review.py` reads saved results and source definitions. It does not build
or start containers. The audit includes all 24 current group IDs, per-case
measurements, coverage line sets and the 23 local type/value reports.

## Index workflow: retained cases and checks

Keep these 12 case IDs and their selection rules:

| Case ID | Distinct check | Following writes |
|---|---|---:|
| `ddl-index-create` | CREATE INDEX with BTREE and ascending key part | 3 |
| `ddl-index-unique` | Composite UNIQUE index | 2 |
| `ddl-index-prefix` | Character and binary index prefixes | 2 |
| `ddl-index-rename` | RENAME KEY and retained rows | 0 |
| `ddl-index-drop` | DROP INDEX and retained rows | 0 |
| `ddl-index-drop-alter` | ALTER TABLE DROP KEY | 0 |
| `ddl-index-replace` | Replace an index with a composite UNIQUE index | 2 |
| `ddl-modify-indexed` | Widen an indexed column | 1 |
| `ddl-index-like` | Copy indexes with CREATE TABLE LIKE | 1 |
| `ddl-index-table-rename` | Retain indexes through RENAME TABLE | 1 |
| `ddl-index-truncate` | Retain indexes through TRUNCATE TABLE | 1 |
| `ddl-index-unique-null` | Nullable prefixed UNIQUE index and duplicate NULL values | 3 |

There are 16 following SQL statements and 18 affected rows. Keep all 57 existing
assertions: schema effects, following DML where present, source boundary, schema
history and normalized binlogs. The three cases without following DML still
check retained rows and index metadata.

Implement the shared workflow with these conditions:

1. Give each case distinct table names. Preserve the source SQL apart from
   those names. Replicate setup from the source. Do not seed target and native
   independently or restore the seed's unused `sql_log_bin=0` setting.
2. Batch setup and DDL. Compare metadata, warnings and retained rows before
   following DML can overwrite them. Keep separate single-table DROP statements;
   the compound DROP case tests a different condition.
3. Batch following writes by operation position across the cases. Keep exact
   intermediate rows on all three servers. Keep unaffected rows and duplicate
   NULL checks. Final rows alone do not replace these assertions.
4. Capture each source write's GTID and offsets. At one shared drain/snapshot,
   check applied groups, counters, the saved checkpoint and DONE intents.
   Scope history queries by each case's GTIDs, not the latest DDL in the group.
5. Check the saved schema and row-intent references for each case. RENAME uses
   several schema transitions and has no single `after_schema_id`. Keep that
   transition check when extending the MODIFY helper.
6. Decode each role's bounded binlog range once. Compare each case's exact DDL
   and affected row blocks. Filter by its table set, including both names for
   LIKE/RENAME. Do not compare an unfiltered group range as if it held one DDL.
7. Replace the per-case restarts with one saved-state restart and subsequent
   write check for the combined workflow. Preserve named case results and SQL
   trace attribution. Keep the separate index resume/drift-refusal test.

Reuse the MODIFY helpers where their contracts match. Extend helpers for
RENAME, LIKE and index DDL. Do not change the native-only fixtures.

## Remaining group review

The other 12 IDs require separate assertion checks before conversion:

| Cases | Decision and next review |
|---|---|
| `ddl-compat-primary-key-row-matching`, `ddl-compat-constraints` | Ordinary candidates after indexes. Preserve exact composite/text-key rows and named single-row/multirow assertions. |
| `ddl-compat-key-conflicts` | Ordinary candidate with no-op statements. Preserve zero-new-transaction boundaries and warning expectations for INSERT IGNORE and INSERT ON DUPLICATE KEY UPDATE. |
| `matrix-select`, `matrix-load` | Review joined DML, INSERT SELECT, and LOAD DATA separately. Preserve input-table setup, the server file path and row predicates. Do not treat them as repeated integer-value tests. |
| `ddl-compat-primary-key-parts`, `ddl-compat-grouped-constraints`, `ddl-compat-unique-row-identity` | Keep deliberate live restarts and offline replay. Grouped constraints also has a source-version exclusion and InnoDB-specific FK SQL. |
| `ddl-compat-keyless-rows` | Keep duplicate-row, restart, replay and recovery conditions. These are not replaced by primary-key tests. |
| `positive`, `ddl-compat-source-gtid-preservation`, `ddl-compat-tagged-gtids` | Retain the earlier GTID review decisions. Exact counters, target GTID membership, tag intervals and isolated state differ. |

`ddl-index-resume` already runs in `table-filters-index-resume`. It checks
saved-schema reload and refusal after external schema changes. Keep that
fixture and its required restart. Index byte-limit, duplicate-target and timeout
failures also remain in their failure groups. None is removed by this review.

## Verification scope

First add focused unit checks for table mapping, scoped history queries and
binlog selection. Build once after the workflow changes. Run the 12 changed
index cases together on 8.4 → 5.7 MyISAM, default SQL, in one fixture. Require
all 57 original assertions plus the shared restart check. Check final GTIDs,
offsets and counters. Use the support bundle first if the run fails.

The index definitions have no profile-specific SQL branches. Do not rerun all
four profiles locally for this execution change. If a new helper introduces a
version/engine branch, select only the case that exercises it. Leave the complete
group, variants, cross-profile checks and matrix timing to CI. Do not run syntax
tests unless MySQLSyntax changes.

## Implementation and focused results

`IndexOperationsWorkflow.swift` implements the shared execution. All 12 original
case definitions and native fixtures remain unchanged. Each case gets a distinct
table set. LIKE and RENAME retain both names in the binlog check. The shared
MODIFY helpers now support published schemas, including RENAME transitions.
Their existing retired-schema behavior remains covered by unit tests.

The runner sends setup, DDL and three DML phases through the running applier.
It captures metadata and retained rows after DDL. It captures exact rows after
each following operation. Assertions check those captured values at the end.
It decodes one bounded binlog file per server. One shared checkpoint replaces
12 per-case snapshots. One restart then checks a following UPDATE against the
fixed row expectation. Workflow-only selections skip the repeated outer restart.
Mixed selections retain the outer check.

All 12 IDs remain independently selectable. The first selected case owns the
shared execution time and client calls. Other cases retain their own assertion
results. SQL traces include `workflow_id=index-operations` and `shared_case_ids`.
Batch query names and source-phase results identify each participating case.
Do not interpret the first case's shared cost as its standalone cost.

Local default SQL results on 8.4 → 5.7 MyISAM:

| Check | Result |
|---|---|
| Cases and assertions | 12 cases; all 57 original assertions plus shared restart passed |
| Focused unit tests | 11 passed: IndexOperationsWorkflowTests, ModifyColumnsTests, LabSQLPhaseTests |
| Case execution time | 16.27 seconds across the 12 reported case records |
| Harness SQL calls within cases | 59; saved CI baseline: 1,692 |
| Source body | 28 distinct GTIDs: 12 DDL and 16 following writes; 18 affected rows |
| Saved state | All 28 APPLIED groups match source file/offset; no unfinished row or DDL intents |
| Containers and applier | One container setup; two applier starts, including the shared restart |
| Binlog comparison | Three bounded decoded files; all 12 case comparisons passed |
| Fixture setup | 14.54 seconds, including 12.03 seconds for container startup |
| Coverage | 8,056/20,880 runtime lines from this 12-case selection and its fixture checks |
| Catalog and matrix | Exact catalog and selection match; 183 jobs, 1,545 obligations, 182 collections |

The saved CI case time was 213.75 seconds. Different machines and fixture scope
prevent a controlled speed comparison. The coverage count above is not the
coverage of the full 24-case keys-rows-gtids group. No other profile or full group
ran locally for this slice.

Evidence: `artifacts/key-index-completion-review/index-results.json`,
`inventory-results.json`, `unit.log` and `integration.log`. The passed lab result
is `artifacts/lab/20261106T210334Z-f3cacf47/result.json`.

The index workflow is committed as `dae01c2`. The
[primary-key and constraint results](BETA7_PRIMARY_KEY_CONSTRAINT_WORKFLOW_REVIEW.md#implementation-and-focused-results)
record both retained-table conversions. All 23 operation states, 16 fixed
predicates and 15 original named assertions passed in the existing fixture.
Fourteen focused unit tests passed. The generic phase guard remains unchanged.

Next: review conflict statements, preserving no-op boundaries. Keep matrix counts
and profile/transport selections unchanged.
