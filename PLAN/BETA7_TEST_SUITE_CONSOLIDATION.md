# Beta.7 test suite consolidation

Status: implementation proceeds in slices. Keep changes local until the user
requests a push.

Current progress:

- Baseline, feature ownership, migration checks and generated-column changes:
  committed as `a0a130a` (Slices 1–3).
- Step 2: generated-column and FULLTEXT migrations pass focused local checks.
  FULLTEXT changes were committed as `615ed94` (Slice 4). Full CI is still required.
- Step 3: the `matrix-values` migration passes focused local checks (Slice 5);
  committed as `0bd7c2e`.
- Composite and text PRIMARY KEY cases are combined in
  `ddl-compat-primary-key-row-matching` (Slice 6). Focused tests passed on both
  InnoDB and MyISAM targets. Local validation is complete. Next: define shared
  groups for key and conflict workflows, then review conflict and GTID checks.
- Feature ownership is explicit. Existing family and execution-group names remain
  until Step 4. Fixture changes, full-CI balancing and PR selection follow in
  Steps 5–7. Cleanup is Step 8.

## Goal

Build a test suite organized by MySQL features and replication behavior. Each
group must state what it tests. A feature workflow can contain DDL, DML, restart
and replay checks. Remove separate cases when that workflow can check all their
required conditions with less repeated work or a clearer structure for future
extensions. Fewer CI jobs and shared fixture setup take priority over a small
increase in test-body time. A lower case count alone is not a smaller CI matrix.

Keep the current four profiles, source variants and SQL/BINLOG transport
selections. Do not expand every case into every combination. Keep existing
applicability limits and expected native behavior. Do not change runtime
replication code as part of this work.

Use the existing shared catalog, planner, runners and measurement tools. Do not
build a second test framework. Finish the full-suite organization before choosing
the short PR selection.

## Growth and acceptance criteria

Design the suite so that a new case normally extends an existing feature group.
It must not create a CI job by default. A new profile or variant reuses the same
reviewed groups. Keep exclusions explicit; do not multiply every case by every
profile, transport and setting.

Assess each change in this order:

1. Preserve required assertions, failure conditions and applicable combinations.
2. Reduce execution groups and CI jobs. Leave room for new profiles and variants.
3. Reuse container setup where the state and server settings are compatible.
4. Keep cases visible by name, with their own results, SQL and coverage records.
5. Balance job time. Accept a few extra seconds for a useful reduction in jobs
   or a clearer structure for future additions. Do not reject a merge on elapsed
   time alone. Check total runner time and the longest job too.

Before Step 6, add planner checks for a fifth profile and an additional source
variant. These are planning checks, not extra test combinations to run now.
Use them to choose a job budget below the planner's 256-job limit. Do not aim for
255 jobs or require an emergency redesign each time a profile is added.

The current four-profile plan has 240 execution groups and 240 jobs. Its profiles
contribute 50, 47, 50 and 93 groups. The current policy keeps 85 groups in areas
that must run alone. With those exclusions unchanged, planning the same selection
with `max_groups` set to 2, 3 or 4 produces 164, 142 or 129 jobs, respectively.
These are planning counts, not validated runtime recommendations. They show that
job assignment can provide room for growth without removing tests. They do not
prove reduced container startup cost or acceptable job duration.

Do not change `max_groups` alone and call fixture reuse complete. Review which
areas really need isolation. Prefer coherent shared feature groups. Use multiple
separately reported groups per job when their fixtures must remain separate.

## Starting evidence

- Full CI run `40170659705` passed all 250 integration groups. It has all 263
  expected integration coverage collections and 2,095 catalog obligations.
  Unit coverage is missing because the unit job was cancelled. This run is not
  a complete passing CI result.
- The current local grouping changes produce 240 groups and 253 coverage
  collections. They retain the same obligations and selected case executions.
  They combine index cases, balance bootstrap groups, and omit unrelated main
  applier setup from reviewed bootstrap-only selections.
- Focused local comparisons passed. The combined MODIFY selection saved about
  70 seconds. The bootstrap setup change saved about 25 seconds. No runtime
  line was lost from the union of those compared selections.
- The starting changes and Slices 1–3 were committed as `a0a130a`. See
  [the grouping study](BETA7_INTEGRATION_GROUP_PROPOSAL.md).

The saved coverage is at group level. It cannot prove that an individual case
is redundant. Review SQL, expected values, failures and restart conditions too.

## Target structure and names

Keep the existing three levels:

1. A **case** is an ordered experiment with named assertions. Keep a case ID
   when its experiment remains. Do not rename every case to improve job names.
2. An **execution group** runs compatible cases in one fixture invocation.
   Its name describes their behavior. It must not hide several sequential
   container setups under one test step.
3. A **CI job** runs one or more compatible execution groups. Independent jobs
   run in parallel. Each group must report its own setup, test and cleanup time.
   Packing groups into a job reduces matrix entries, but does not itself share
   containers. Prefer a shared execution group when cases can safely reuse setup.

Use the catalog's family field for the feature. Use the plan's area for a
descriptive execution group within that feature. Local selection and CI must
resolve these definitions through the same planner. DDL, DML, bootstrap,
restart and replay are conditions to show in the case list, not competing
implementations of the same feature suite.

Before assigning or changing a MySQL feature name, consult the MySQL Reference
Manual. Use its feature names and link the relevant section in the feature
definition. Check the applicable 5.7 and 8.4 versions when behavior differs.
Check the resolved manual version: an old documentation URL can redirect to a
newer manual. Use the pinned upstream source or archived manual for version
details if the old manual is unavailable. A group can add a plain description
of the behavior it tests; do not present that description as a MySQL term.

Initial naming references:

- [CREATE TABLE and Generated Columns](https://dev.mysql.com/doc/refman/8.4/en/create-table-generated-columns.html):
  use **Generated Columns** as the feature name.
- [Full-Text Search Functions](https://dev.mysql.com/doc/refman/8.4/en/fulltext-search.html):
  use **Full-Text Search** as the feature name; retain `FULLTEXT` in SQL names.
- [Partitioning](https://dev.mysql.com/doc/refman/8.4/en/partitioning.html):
  use **Partitioning**, with documented subareas such as **Partition Management**
  and **Partition Selection**. Name the tests for the specific operations they run.

The following names define the intended feature boundaries. They are not a
requirement to create one job for each row. Small related selections can share
a group. Long selections can split at independent case boundaries.

| Feature | Group names and contents |
|---|---|
| Databases and tables | `database-defaults-and-lifecycle`; `table-options-renames-and-maintenance` |
| Row keys and indexes | `primary-unique-and-keyless-row-matching`; `unique-key-conflicts-and-no-op-writes`; `index-create-change-drop-and-resume` |
| Column changes | `column-types-order-and-renames`; `generated-columns-and-row-values`; `check-constraints-and-version-rules` |
| Partitions | `partition-routing-and-bounds`; `partition-maintenance-and-exchange` |
| Character data | `character-sets-collations-and-conversion`; `enum-set-values-and-metadata`; `binary-text-values-and-size-limits` |
| Numeric and temporal data | `numeric-limits-and-defaults`; `temporal-precision-and-time-zones` |
| JSON | `json-values-defaults-and-indexes`; `json-partial-updates-and-compatibility` |
| Search and spatial data | `fulltext-indexes-and-search`; `spatial-types-and-indexes` |
| Other source writes | `insert-select-join-writes-and-load-data` |
| Stored objects | `views-routines-and-temporary-tables`; `executable-comments-and-version-rules` |
| Foreign keys | `foreign-key-definitions-and-row-actions`; `foreign-key-parent-rules-and-recovery` |
| GTIDs | `source-gtid-preservation-and-replay`; `tagged-gtid-tracking` where independent cases remain necessary |
| Filtering | `table-filters-and-resume` |
| Replay and control | `archive-replay-and-saved-position`; `error-skipping-and-resume`; `runtime-status-stop-and-reload` |
| Connection and failure handling | `source-reconnect-and-rotation`; `target-reconnect-and-uncertain-writes`; `innodb-rollback-and-recovery`; `myisam-partial-writes-and-recovery` |
| User and native checks | `demo-workbook-and-control`; `native-source-restrictions` |

Keep ordered DDL sequences intact and name them for their sequence, for example
`ordered-schema-changes-and-restart`. Keep bootstrap conditions visible with a
name such as `existing-schema-numeric-and-temporal-values` when they need their
own group. Do not silently replace fresh discovery with cached schema use.

Job names use this format:

```text
Integration / <profile> / <group> / <variant> / <transport>
```

Use no numbered suffixes, `misc`, or broad names such as `ddl` and `dml` in final
job names. Do not call a group `smoke` without also showing its selected cases.
All normal test jobs use the coverage binary; show that fact in report metadata.

## Rules for replacing a case

A replacement must retain the original conditions that matter:

- Column types, value boundaries, NULLs, exact bytes and key shape.
- Source statements, including no-op statements and writes to multiple rows.
- Source/native/target outcomes and intermediate expected values.
- Transaction boundaries, target GTID assertions and saved file offsets.
- Required initial schema, cold discovery, restart, replay or failure state.
- Profile, capture variant, transport and native engine.

For example, DROP PARTITION does not replace a row DELETE. A UNIQUE key does not
replace a PRIMARY KEY condition. Normal-parser FULLTEXT checks do not establish
ngram update behavior. A CREATE with DECIMAL does not establish extreme decimal
value fidelity.

Record each proposed retirement in one machine-readable migration file, planned
as `tools/test_case_migrations.json`. Include the old case ID, applicable scopes,
replacement case IDs, named assertions, retained conditions and evidence paths.
Validate references against the catalog and results. An old assertion can be
covered by several replacement cases. A name in this file alone is not a pass.

Before deleting a case, its replacements must pass the focused checks. Update
full, PR, component and BINLOG selections together. Check bootstrap users of
shared case definitions. Remove obsolete runner code only when no retained
selection needs it. Unknown retired IDs must fail with a useful replacement
message; do not leave a second runnable copy as a compatibility alias.

Case counts can decrease. The initial 2,095 count is not a permanent target.
Reports must explain which obligations moved and which experiments were removed.
Do not report a retired case as executed or let a smaller denominator hide a gap.

## Step 0 — Save the current baseline

- Finish the current grouping change as its own reviewable commit when the user
  requests a commit. Keep this plan separate from claims of implementation.
- Save the current live catalog, full/PR plans and focused comparison results.
- Check that the plan still retains all current applicable executions.

Done when the starting code and measurements can be identified by commit and
artifact path. No new full run is needed for this step.

## Step 1 — Establish feature ownership and selection checks

- Assign every current case one primary feature. List secondary conditions in
  its description or explicit metadata. Do not duplicate execution for each tag.
- Add the migration file and validation for missing replacements, invalid
  scopes, missing assertions and stale selection references.
- Preserve current executions while adding the feature mapping. Identify any
  applicability logic that depends on old family names. Make those rules
  explicit before changing the family names.
- Use shared feature definitions for catalog output, local plans and CI areas.
  Keep scheduling estimates separate from feature membership.

Done when every case is assigned, existing executions are unchanged, and focused
catalog/planner tests pass. Show requested cases and added dependencies separately.

## Step 2 — Consolidate generated-column and FULLTEXT workflows

These are the first two small replacements:

1. Extend `ddl-compat-generated` with deletion of an updated non-NULL row while
   a NULL row remains. Retain exact generated-value checks. Replace replicated
   `matrix-generated` after validation. Keep `bootstrap-matrix-generated`.
2. Extend `ddl-compat-fulltext` with explicit ngram CREATE coverage and ngram
   UPDATE/DELETE search checks. Retain existing ALTER/parser and normal-parser
   checks. Replace replicated `matrix-fulltext` after validation. Keep its
   existing-schema counterpart.

Run before/after selections with the same runtime binary and server settings.
Map old assertions to replacement assertions. Record lost runtime lines and
their disposition. Do not run the whole suite locally.

Done when both migrations pass, retained bootstrap definitions still resolve,
and the obsolete replicated cases have no selection or documentation references.

## Step 3 — Consolidate row-key, conflict and GTID checks

- Fold `matrix-values` into an existing suitable row-key workflow. Retain exact
  multirow UPDATE/DELETE results and unaffected rows.
- Fold `matrix-composite` only after equal IDs on different dates and separate
  changes to both primary-key components are checked.
- Fold `matrix-textkey` only after a text PRIMARY KEY, case-only key change and
  case-insensitive DELETE are checked. Existing UNIQUE-key coverage is insufficient.
- Put upsert, REPLACE and IGNORE in the unique-key conflict area. Keep their
  mixed effects, multiple conflicts and no-op checks. Reuse table setup only
  where this does not change the required initial state.
- Add GTID preservation checks to retained live/restart/replay workflows. Retain
  the 40-row source transaction condition before retiring the separate preserved
  GTID workload. Keep tagged GTID conditions separate where required.
- Keep the `positive` test's exact counters, normalized binlog, transport and
  credential checks until their replacements are explicit. Do not remove it
  merely because its INSERT/UPDATE/DELETE statements look simple.

Done when the selected row and GTID migrations pass and the case list shows which
key, transaction and conflict conditions remain. Leave a case in place if a
replacement would lose a distinct condition or obscure the workflow. A small
time increase is acceptable for fewer groups or easier extension. Compare CI
job and fixture counts; do not decide from case runtime alone.

## Step 4 — Organize all remaining feature workflows

- Combine database CREATE/default checks with ALTER/DROP/recreate checks under
  database lifecycle. Keep warning, inheritance, journal and restart assertions.
- Move type/value cases beside their column/index cases. Retain numerical,
  temporal, spatial, encoding and JSON boundary checks that DDL does not replace.
- Give partition, foreign-key and stored-object groups descriptive names.
  Keep each ordered sequence and required intermediate comparisons intact.
- Place index resume/drift checks in the index area. Keep filter dependencies in
  the filter area. Retain the different rejection and recovery outcomes.
- Finish the case-to-feature inventory. No case may remain in a catch-all area.

Done when every current behavior has a named home. Each deletion needs a tested
migration; a move alone must retain the selected execution set. Adding a case
to a feature must not create another execution group unless its setup requires it.

## Step 5 — Set fixture boundaries and remove repeated setup

- Combine compatible cases within the same profile, variant, transport and
  server settings. Each execution group starts its MySQL containers once.
- Review key-related DDL, row-key and conflict workflows as a shared feature
  group. Preserve individual case results. Combining their assertions in one
  catalog entry is optional; reducing separate setup and job count is the aim.
- Combine the small SQL no-preservation selections where compatible. Keep
  `positive`, generated-column and applicable tagged-GTID checks visible.
- Extend the reviewed setup requirements beyond bootstrap. Skip the main
  applier baseline only when all selected cases supply their own required state.
- Check table cleanup, global/session settings, native filters, stopped threads,
  archive files and state directories at case boundaries. Keep destructive or
  uncertain-write tests isolated when later cases cannot safely reuse the fixture.
- Do not turn required restart, cold-discovery or replay checks into warm-cache
  checks to reduce runtime. Report deliberate restarts separately from setup.

Done when combined selections pass and SQL records show which setup calls were
removed. Unrelated failures must not prevent remaining independent cases from
producing results. An unsafe fixture must stop with a clear reason.

## Step 6 — Measure the full suite and balance groups

- Run one full instrumented CI selection after the local migrations pass and
  the user has pushed the changes. Use the existing reusable build.
- Check all four profiles and all retained variants/transports. Confirm result,
  SQL, coverage and support-bundle collection completeness.
- Compare original and new runtime line sets. Explain each lost line. Keep unit
  and integration coverage separate in the comparison. Do not use the cancelled
  baseline unit job as evidence of unit coverage.
- Report image preparation, fixture setup, test body, deliberate restart,
  cleanup and coverage-export time separately. Report runner-minutes and workflow
  elapsed time separately.
- Aim for about five minutes per ordinary integration job with cached builds
  and images. Treat this as a balancing target, not a reason to create excessive
  jobs. Check the growth budget before splitting groups. Combine small related
  groups and pack incompatible fixtures into separately reported groups when
  needed. Retain and explain longer inseparable recovery workflows.
- Fix failed cases and rerun only affected jobs. Repeat the full suite only if
  the fixes or grouping changes justify it.

Done when the final matrix passes and the report accounts for removed cases,
coverage changes and remaining long jobs. The planner must also pass the
profile/variant growth checks within the selected job budget. Confirm runtime
with measurements before adopting the final job assignment.

## Step 7 — Select the short PR test set last

- Choose an explicit list of named cases from the final feature suite. Reuse
  their implementation and assertions; create no separate smoke runner.
- Keep parallel InnoDB and MyISAM selections. Include reviewed basic schema,
  row, policy and replay checks. State which profiles and transports run.
- Retain unit tests and Periphery as parallel PR checks with the shared build.
- Target about five minutes for each warm-cache PR integration job. Report build
  and queue time separately; this is not a guarantee for cold workflow time.
- Keep component-based additions and the full-suite trigger. A short PR pass
  must not be reported as a full-profile result.

Done when local planning and CI display the same explicit PR case lists, their
dependencies, exclusions and measured timing.

## Step 8 — Finish documentation and remove obsolete structure

- Update `docs/TEST_LAB.md`, `docs/CI_MEASUREMENTS.md`, PR selection instructions,
  support catalog mappings and affected command examples as their steps land.
- Remove old grouping policies, stale IDs, duplicate runners and unused helpers.
  Run Periphery after the removed entry points no longer keep helpers reachable.
- Keep the migration record and before/after report. Mark earlier proposals as
  historical and link them to this completed plan.
- Document each group's purpose, selected cases and setup conditions. Keep
  exact machine-readable case lists available through the existing plan command.

Done when there is one feature organization for local tests and CI, no stale
selectors, no unexplained coverage losses, and a passing full-suite result for
the final implementation. Production package checks retain the existing release
model; this work does not add a second qualification suite.

## Working method

Make each numbered step reviewable. Split Steps 2 and 3 into separate commits per
feature when useful. After each step, record changes, focused tests, measurement
paths and remaining work here. Do not request a full local run. Do not re-run the
syntax unit suite unless parser code or its test/build setup changes.

### Slice 1 — Baseline and naming rule

Completed the baseline capture and comparison. The existing grouping changes
remain uncommitted; this slice does not claim that a clean commit exists yet.

Evidence is in `artifacts/test-suite-consolidation/baseline/`:

- `catalogs.json` and `pr-catalogs.json`: fresh output from the built lab.
- `full-plan.json` and `pr-plan.json`: plans from the existing CI generators.
- `comparison.json`: unchanged selected executions and catalog conditions.
- `focused-comparison.json` and `focused-plan-comparison.json`: saved results
  from the previous focused integration checks.
- `manifest.json`, `input-hashes.json`, `build-inputs.txt` and
  `working-tree.patch`: source identity and file hashes. The manifest records
  HEAD `e92b8ac` and marks the working tree as modified. All saved manifest file
  hashes were verified after capture.

The comparison confirms:

| Selection | Groups / jobs | Applicable obligations | Expected coverage collections |
|---|---:|---:|---:|
| Full | 240 / 240 | 2,095 | 253 |
| PR | 2 / 2 | 22 | 2 |

The full selection retains the exact execution multiset from run `40170659705`,
including profile, variant, suite, transport and dependency executions. Its
applicability, exclusion reasons, dependencies, intent and expected outcomes
also match. Group definitions match the locally tested grouping proposal. The
PR selection is unchanged from the saved CI policy.

The naming rule now requires a MySQL manual reference and a check of its actual
version. The first three terminology references were checked. Remaining feature
names must receive the same check before assignment.

No test was removed or renamed. No containers or full suites were run in this
slice. Plans and catalogs were read from the local lab binary.

### Slice 2 — Feature ownership and selection checks

Implemented an explicit ownership map in `tools/test_features.json`. All 256
suite/case identities have one owner: 23 MySQL features and eight project
behaviors. Existing-schema and replicated-CREATE cases share the same feature
when they check the same MySQL facility. Native and recovery adapters retain
their aggregate cases and ordered child checks.

Each MySQL feature has a manual link and version. The naming review used the
8.4 manual; this is a terminology reference, not a change to 5.7 applicability.
Project behavior uses an existing project guide. The map has explicit case IDs,
so a new case cannot silently inherit ownership from a prefix rule.

`tools/lab_features.py` checks the map and adds `feature_catalog` to local and
CI plans. Each execution group lists its features. Missing or duplicate
assignments, invalid references and planned cases absent from the catalog fail.
Full catalogs also reject stale assignments. The check runs before CI writes
its plan and before local planning emits commands. It does not make network
requests or start containers.

The old families remain during this slice. The audit found family-dependent
foreign-key applicability, expected failure outcomes, bootstrap phase reporting
and setup descriptions in `LabScenario.swift`. CI grouping, component selection,
lifecycle and demo filters also use families. Make these dependencies explicit
before replacing family names. The historical DDL coverage catalog keeps its
existing identifiers and mappings; the ownership map adds no new passing-test
count and does not replace that catalog's assertions.

Validation:

- Ten feature-check tests pass, including annotation without selection changes
  and CI rejection before writing an invalid plan.
- Eleven local-selection tests, 16 CI-runner tests and 23 matrix tests pass.
- Fresh full, PR and local plans match the Slice 1 baseline after removing only
  added feature metadata and the CI build-input field. Group order, jobs, case
  order, commands generated from the selections, applicability and counts remain.
- Local and CI full feature catalogs match exactly. Full CI remains 240 groups,
  2,095 obligations and 253 expected coverage collections. PR remains two groups
  and 22 obligations.

Evidence: `artifacts/test-suite-consolidation/features/`, with `full-plan.json`,
`pr-plan.json`, `local-plan.json`, `local-pr-plan.json` and `comparison.json`.
No integration tests were run and no cases were removed or renamed. Changes
remain uncommitted.

### Slice 3 — Migration checks and generated columns

Added `tools/test_case_migrations.json` and `tools/lab_migrations.py`. Each record
names the retired case, replacement case, original execution selections and
conditions to retain. Local and CI planning check the replacement's declared
assertions and applicability. Full CI planning checks its transport selections.
A retired case cannot remain in the catalog. Its old CLI selection fails with
the replacement ID. Result validation checks that the required named assertions
passed and have evidence paths; it does not replace a review of that evidence.

The first record moves the replicated `matrix-generated` conditions into
`ddl-compat-generated`:

- Multirow INSERT with non-NULL and NULL inputs; check exact generated values.
- UPDATE the non-NULL base column; check the new generated value.
- DELETE that row while the NULL row remains; check all retained rows.

The receiving test keeps its stored and virtual generated columns, ALTER ADD,
post-ALTER INSERT, and DELETE of the NULL row. Named assertions save SQL and
expected/observed results. The stored expression and literal input values differ
from the retired fixture; the retained conditions above are the comparison basis.
`bootstrap-matrix-generated` keeps the original fixture and all three phases.
Its SQL, expected results, observations and transaction counts match the baseline.
The feature name remains **Generated Columns**, from the MySQL manual reference
already recorded in `tools/test_features.json`.

Focused validation used SQL transport and the default variant:

| Measurement | Reverse profile before | Reverse profile after |
|---|---:|---:|
| Selected cases | 3 | 2 |
| Elapsed seconds | 169.92 | 159.37 |
| SQL calls | 277 | 235 |
| SQL seconds | 56.71 | 49.33 |
| Runtime lines executed | 7,805 | 7,785 |

The reverse profile is `mysql57-to-mysql84-innodb`. Before and after runs used
the same application binary and server settings. Only four lab source files
changed. Elapsed time includes fixture setup, cleanup and coverage export; it
excludes builds. One comparison is not a stable speed estimate.

All 20 lines absent from the smaller run are in `DDLParser.swift` CREATE TABLE
option parsing, including engine, character set and collation options. The
retained `ddl-modify-primary-widen` / `ddl-modify-first` selection executed all
20 lines in its saved focused run. That run used the same application binary
and parser source. Both cases remain in the full plan. Thus the comparison found
no unexplained runtime line loss. It does not prove coverage for every profile
or variant; leave those checks to full CI.

The combined case and unchanged bootstrap case also passed on
`mysql84-to-mysql57-myisam`: 140.37 seconds, 259 SQL calls. All three replacement
assertions matched their expected results on both profiles. No before-run timing
was collected for the forward profile.

Additional checks:

- The focused Swift migration test passes.
- All 43 lab-tool Python tests, 16 CI-runner tests and 23 matrix tests pass.
- Full planning removes exactly ten `matrix-generated` executions. Their
  replacements already run in all ten original selections. No other execution,
  group ID or remaining case order changed.
- Full CI now has 240 groups, 2,085 obligations and 253 coverage collections.
  PR selection remains two groups and 22 obligations.

Evidence is in `artifacts/test-suite-consolidation/generated/`: `comparison.json`,
`coverage-review.json`, `forward-validation.json`, `plan-comparison.json`, the
before/after measurements, and test logs. The original sandbox setup failure
is retained as `reverse-before.json`; it is excluded from the comparison.
Runtime code did not change. Changes remain uncommitted.

Next slice: review the FULLTEXT replicated cases with the same migration checks.
Keep existing-schema checks and engine-specific search expectations where they
test different conditions. Compare SQL, assertions and coverage before removal.

### Slice 4 — Full-Text Search

This is the second migration in Step 2. The feature name remains **Full-Text
Search**. The naming review checked the 8.4 manual's
[ngram Full-Text Parser](https://dev.mysql.com/doc/refman/8.4/en/fulltext-search-ngram.html)
section. It documents `WITH PARSER ngram` for CREATE TABLE and ALTER TABLE.
The 5.7 manual link redirects to 9.7, so it is not used as 5.7 evidence. The
local 5.7 source at `f7680e98` includes
`mysql-test/suite/innodb_fts/t/ngram.test`, with ngram index creation and deletion
checks. Focused runs use the actual project profiles.

Review of the SQL at `a0a130a` found distinct conditions:

- `ddl-compat-fulltext` checks a multi-column default-parser index, ignored index
  prefixes, search after INSERT/UPDATE/DELETE, DROP/CREATE/RENAME INDEX, ALTER ADD
  with ngram, two applier restarts, and CREATE TABLE LIKE with INSERT SELECT.
- `matrix-fulltext` creates an ngram index in CREATE TABLE. It inserts two rows,
  updates one row and deletes the other. Each phase checks a BOOLEAN MODE search.
- `bootstrap-matrix-fulltext` uses the same three phases with an existing schema.

Keep all these conditions. A separate table in the DDL workflow retains the
explicit ngram CREATE and the exact input strings and search predicates from
`matrix-fulltext`. Do not replace the existing ALTER ADD or LIKE operations.
The bootstrap fixture is unchanged. The retained conditions now belong to one
replicated feature case; no required row write was removed.

The replicated `matrix-fulltext` case is now retired. The bootstrap definition
is unchanged. The migration record retains all ten original execution selections.
The feature map, CI selections, support catalog and test guide use the replacement.
The old ID remains only in migration checks and historical/review descriptions.

The reverse-profile comparison used `mysql57-to-mysql84-innodb`, SQL transport
and the default variant. Before and after used the same application binary,
server settings and runtime line map. Only `FulltextCases.swift` and
`DMLCompatibilityCases.swift` changed in the coverage source manifest.

| Measurement | Before | After |
|---|---:|---:|
| Selected cases | 3 | 2 |
| Elapsed seconds | 206.80 | 203.35 |
| SQL calls | 394 | 394 |
| SQL seconds | 80.59 | 76.52 |
| Runtime lines executed | 8,042 | 8,042 |

No runtime lines were lost or gained. The original DDL queries and observed
values match. All three retired row statements and search predicates match after
changing only the qualified table name and removing `USE poc`. The bootstrap
SQL, expected/observed values and transaction counts match for all three phases.
Four replacement assertions passed and saved their SQL and observed values.
The total SQL call count is unchanged. One run is not a stable timing estimate.

This replacement provides one Full-Text Search workflow. Both selections use
one fixture, so it cannot save container setup time. The first candidate added
three explicit queries and had seven more SQL calls. Its results are retained
as `reverse-after.json`, `forward-after.json` and `comparison.json`. The shared
step already compares schema and row snapshots. The final code removes these
extra queries and keeps the original search predicates. The CREATE assertion
saves the compared schema snapshot. This keeps the required conditions without
adding repeated verification queries. Further fixture reductions belong to
Step 5.

Planning removes exactly ten `matrix-fulltext` executions. Each replacement was
already selected in its original profile, variant and transport. Other execution
selections, group IDs and remaining case order are unchanged. Full CI now has
240 groups, 2,075 obligations and 253 coverage collections. The PR selection
remains two groups and 22 obligations. No new fixture groups were added.

The focused Swift migration test, four support-catalog tests, 43 lab-tool Python
tests and 23 matrix tests pass. Evidence is in
`artifacts/test-suite-consolidation/fulltext/`: before/after measurements,
`comparison-final.json`, `plan-comparison.json`, source-image inputs and test logs.
No runtime replication code changed.


The final `ddl-compat-fulltext` case also passed on
`mysql84-to-mysql57-myisam`. Its four named assertions matched the source,
native replica and target. The unchanged bootstrap fixture passed all three
phases in the earlier forward run. The final forward rerun selected only the
changed DDL case. See `forward-final.json` and `forward-validation.json`.

Step 2 is complete for the focused local checks. The full profile/variant matrix
remains for GitHub Actions. These FULLTEXT changes were committed as `615ed94`.
Next: Step 3, starting with `matrix-values`. Review exact multirow UPDATE/DELETE
results and unaffected rows before choosing a receiving row-key workflow.
Do not remove PRIMARY KEY, composite-key or conflict conditions merely because
they execute the same code. Keep final group naming, fixture boundaries,
full-CI balancing and short PR selection in their later plan steps.


### Slice 5 — Primary-key single-row and multirow writes

This is the first slice of Step 3. Keep composite keys, text primary keys,
conflicts and the GTID workload until their separate conditions are reviewed.

The suite has single-row UPDATE/DELETE checks. The four SQL
`without-source-gtids` row-operation groups select only `positive`. Default
variants combine `positive` with other row-operation cases. This case also checks
INSERT, binlogs, counters and saved state. Existing feature cases check integer and text primary keys,
unique keys, keyless matching, generated columns, FULLTEXT and post-DDL writes.
Their different schemas, lookup rules and restart conditions matter. Shared code
coverage does not make these cases interchangeable.

The terminology review used the MySQL 8.4
[UPDATE](https://dev.mysql.com/doc/refman/8.4/en/update.html) and
[DELETE](https://dev.mysql.com/doc/refman/8.4/en/delete.html) statement references.
Single-row and multirow describe how many rows a statement changes. They are
not the manual's single-table and multiple-table syntax categories. The migrated
workload changes two rows in one statement on one table.

Receiving case: `ddl-compat-constraints`, which already checks a single-row
UPDATE and DELETE through an integer primary key, with unaffected rows and
nullable UNIQUE-key values. Name those existing checks without changing their
SQL or expectations. Add `matrix-values` on a separate table with its original
`id INT PRIMARY KEY,v INT NOT NULL` definition and no secondary key. Reusing the
nullable, UNIQUE-indexed table would change the original schema conditions.
Retain the original INSERT/UPDATE/DELETE predicates and values. Use one exact
row query per phase instead of the original aggregate query, so the expected
result identifies every changed and unaffected row. Keep the shared schema/row
comparison after every statement. Do not add duplicate verification queries.

Keep `bootstrap-matrix-values` unchanged. It checks the existing-schema path
with fresh applier state. Do not create a second fixture group for single-row
writes; show these conditions in named assertions within the feature workflow.


The replicated `matrix-values` case is retired. Its four replacement assertions
are `primary-key-row-values-create` and `primary-key-multirow-insert`,
`primary-key-multirow-update`, `primary-key-multirow-delete`. The existing
single-row phases now have the names `primary-key-single-row-update` and
`primary-key-single-row-delete`. Their SQL and expected results did not change.
The replacement and `bootstrap-matrix-values` share the Indexes feature owner.
The bootstrap phase definitions are unchanged.

The reverse-profile comparison used `mysql57-to-mysql84-innodb`, SQL transport
and the default variant. It used the same application binary, server settings
and line map before and after. Only the two lab case-definition source files
changed. Exact original CREATE and row SQL match after changing the qualified
table name and removing `USE poc`. Column, index, table, partition and row
observations match for the migrated table after each statement on all three
servers. The original constraint query results and all three bootstrap phases
also match. The new exact expectations identify changed and unaffected rows;
they use the same number of check queries as the old aggregate expectations.

| Measurement | Before | After |
|---|---:|---:|
| Selected cases | 3 | 2 |
| Elapsed seconds | 163.24 | 166.37 |
| SQL calls | 331 | 331 |
| SQL seconds | 59.51 | 63.20 |
| Runtime lines executed | 8,036 | 8,036 |

No runtime lines were lost or gained. This is an organization and assertion
clarity change, not a demonstrated speed improvement. It uses one fixture before
and after. Do not infer performance changes from one timing sample.

Full planning removes exactly ten `matrix-values` executions. Each replacement
already runs in the same profile, variant and transport. Remaining case order
and group IDs are unchanged. Full CI has 240 groups, 2,065 obligations and 253
coverage collections. PR selection remains two groups and 22 obligations.
The four SQL `without-source-gtids` groups that select only `positive` remain
unchanged. No group is added for the new named row-count assertions.

The focused Swift migration test, 43 lab-tool Python tests and 23 matrix tests
pass. Swift formatting and whitespace checks pass. Evidence is in
`artifacts/test-suite-consolidation/row-values/`: before/after measurements,
`comparison.json`, `plan-comparison.json`, source-image inputs and test logs.
Runtime replication code did not change.


The changed `ddl-compat-constraints` case also passed on
`mysql84-to-mysql57-myisam`. All six named assertions passed, with matching
source/native/target schema and row snapshots. The forward run selected only
the changed case. See `forward-after.json` and `forward-validation.json`.

This completes the `matrix-values` part of Step 3. It does not complete all of
Step 3. Committed as `0bd7c2e`. Next: review `matrix-composite` and
`matrix-textkey`, including equal IDs on different dates, separate changes to
both composite-key columns, and a case-only text PRIMARY KEY change. Keep their
bootstrap cases. Conflict and GTID conditions follow. Leave full profile/variant
execution to GitHub Actions.


## Slice 6 — Composite and text PRIMARY KEY review

Decision: combine `matrix-composite` and `matrix-textkey` in
`ddl-compat-primary-key-row-matching`. Retain both bootstrap cases. This gives
PRIMARY KEY row matching one clear workflow with named exact-value assertions.
Accept the measured overhead as a tradeoff for this structure. This slice still
has 240 execution groups and jobs; it is not the job-count reduction. The next
step must combine compatible execution groups and share setup.

Use PRIMARY KEY as defined in the MySQL 8.4
[CREATE TABLE statement](https://dev.mysql.com/doc/refman/8.4/en/create-table.html).
The manual describes composite keys under
[Multiple-Column Indexes](https://dev.mysql.com/doc/refman/8.4/en/multiple-column-indexes.html).
Use `VARCHAR` and the explicit collation name for the text-key condition.

### Conditions that must remain

- The former `matrix-composite` declares columns in the order `id,report_date,v`, but uses
  `PRIMARY KEY(report_date,id)`. It inserts equal IDs on different dates and
  different IDs on the same date. Separate UPDATE statements change the date
  and integer key parts. DELETE uses both key parts.
- The former `matrix-textkey` uses a separate `VARCHAR(20)` PRIMARY KEY with
  `utf8mb4_unicode_ci`. It changes `Key` to `KEY`, checks the stored bytes, then
  deletes the row with lowercase `key`.
- `bootstrap-matrix-composite` and `bootstrap-matrix-textkey` test discovery of
  existing schemas and resume from saved state. Keep their seven phases.
- `ddl-compat-primary-key-parts` tests prefixes, binary values, ALTER, restart
  and replay. `ddl-compat-unique-row-identity` tests UNIQUE keys and key selection.
  Neither replaces these PRIMARY KEY conditions.

### Measurement and validation

The local candidate combined the two live cases in a new
`ddl-compat-primary-key-row-matching` workflow. It kept all nine source statements
and added named assertions with exact rows after each write. It did not add the
prefix workflow's replay checks. The generic DDL runner still added database
setup, a saved-state check and an applier restart.

The baseline and candidate used the same application binary and MySQL images.
Only three lab source files changed. Their runtime coverage line maps matched.
Both runs included the same two bootstrap cases.

| MySQL 5.7 → 8.4 InnoDB selection | Elapsed seconds | SQL calls | SQL seconds | Runtime lines hit |
|---|---:|---:|---:|---:|
| Two original live cases plus bootstrap | 188.84 | 306 | 56.68 | 7,592 |
| Combined DDL workflow plus bootstrap | 203.42 | 332 | 62.19 | 7,635 |

The candidate made 26 more SQL calls. One local run does not establish a stable
elapsed-time difference, but it confirms added SQL work. No source statement was
redundant. The combined workflow does not reduce jobs or fixtures yet. We accept
the overhead for the clearer structure and stronger assertions. Group reduction
and shared setup remain required follow-up work.

The comparison found no lost runtime lines. All 43 added lines were already hit
by the retained `ddl-compat-constraints` plus `bootstrap-matrix-values` run from
Slice 5. They were in `DDLSession.swift` (21), `DDL.swift` (10), `DDLParser.swift`
(9) and `SchemaMetadataCache.swift` (3). These lines add no coverage to the suite
as a whole. Coverage is preserved; future extension is the reason for the merge.

All nine replacement assertions passed. The original CREATE and row statements
matched after table/database-name substitution. Table columns, indexes,
partitions and exact rows matched at every phase on source, native and target.
All seven bootstrap comparison files matched, except for binlog positions.
The candidate also passed all nine assertions on 8.4 → 5.7 MyISAM in 102.42s.
Two focused Swift unit tests and 66 lab-tool tests passed for the candidate.

The plan comparison preserves all 20 original profile/variant selections in
ten combined executions. This reduces catalog entries, but does not remove
source SQL or fixtures. The full plan has 240 groups, 2,055 obligations and
253 coverage collections. The PR selection replaces `matrix-composite` with
the combined case, so it also gains the four text-key statements. It remains
two jobs and 22 case executions. Final PR selection remains Step 7.

Evidence is under `artifacts/test-suite-consolidation/primary-key-row-matching/`:
`candidate.patch`, `reverse-before.json`, `reverse-after.json`, `comparison.json`,
`forward-after.json`, `forward-validation.json` and `plan-comparison.json`.
The first baseline attempt stopped at Docker access checks in the sandbox. It
executed no tests; its files use the `reverse-before-sandbox` prefix.

Next: define the shared group boundary for PRIMARY KEY, UNIQUE-key and conflict
workflows. Review `matrix-upsert`, `matrix-replace` and `matrix-ignore` within
that design. Preserve their conflict and no-op conditions. Keep individually
selectable cases where useful; they can share a group without becoming one case.
Measure job count and setup reuse as well as time. Preserve the combined
workflow's exact named assertions when removing repeated setup or checkpoints.
