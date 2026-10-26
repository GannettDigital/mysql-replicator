# Beta.7 test suite consolidation

Status: approved; implementation proceeds in slices. Do not remove tests during
the baseline slice. Keep changes local until the user requests a push.

## Goal

Build a test suite organized by MySQL features and replication behavior. Each
group must state what it tests. A feature workflow can contain DDL, DML, restart
and replay checks. Remove separate cases when that workflow can check all their
required conditions with less repeated work.

Keep the current four profiles, source variants and SQL/BINLOG transport
selections. Do not expand every case into every combination. Keep existing
applicability limits and expected native behavior. Do not change runtime
replication code as part of this work.

Use the existing shared catalog, planner, runners and measurement tools. Do not
build a second test framework. Finish the full-suite organization before choosing
the short PR selection.

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
- These local changes are not yet committed. Preserve them as the starting
  change. See [the grouping study](BETA7_INTEGRATION_GROUP_PROPOSAL.md).

The saved coverage is at group level. It cannot prove that an individual case
is redundant. Review SQL, expected values, failures and restart conditions too.

## Target structure and names

Keep the existing three levels:

1. A **case** is an ordered experiment with named assertions. Keep a case ID
   when its experiment remains. Do not rename every case to improve job names.
2. An **execution group** runs compatible cases in one fixture invocation.
   Its name describes their behavior. It must not hide several sequential
   container setups under one test step.
3. A **CI job** runs one execution group. Independent jobs run in parallel.
   Keep this model while measuring the new groups.

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
replacement would make the receiving workflow harder to understand or slower.

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
migration; a move alone must retain the selected execution set.

## Step 5 — Set fixture boundaries and remove repeated setup

- Combine compatible cases within the same profile, variant, transport and
  server settings. Each execution group starts its MySQL containers once.
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
  and images. Split slow groups at independent case boundaries. Combine small
  related groups. Retain and explain longer inseparable recovery workflows.
- Fix failed cases and rerun only affected jobs. Repeat the full suite only if
  the fixes or grouping changes justify it.

Done when the final matrix passes and the report accounts for removed cases,
coverage changes and remaining long jobs. Do not promise a job count before
measuring the final selections.

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
