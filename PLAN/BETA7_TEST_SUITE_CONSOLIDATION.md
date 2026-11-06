# Beta.7 test suite consolidation

Status: implementation proceeds in slices. Keep changes local until the user
requests a push.

The [current execution plan](#current-execution-plan-after-the-modify-pilot)
sets the order for remaining work. Earlier slice records describe completed
work; their next-step notes are historical.

Current progress:

- Current table/column/index conversion work is locally complete: 20
  compatibility cases use final observations, and the MODIFY pilot uses shared
  preparation, observations and binlog checks. See the
  [completion review](BETA7_TABLE_COLUMN_INDEX_COMPLETION.md). Full-matrix
  validation remains. Slice 3 has started: the RANGE/exchange and HASH/KEY/LIST
  workflows pass one focused fixture. The
  [partition forms conversion](BETA7_PARTITION_FORMS_WORKFLOW_REVIEW.md#implementation-and-focused-results)
  also passed its three cases, including both replay paths. The
  [partition rename/bounds conversion](BETA7_PARTITION_RENAME_BOUNDS_REVIEW.md#implementation-and-focused-results)
  passed its three cases and all replay paths. The
  [partition completion audit](BETA7_PARTITION_ADMINISTRATION_REVIEW.md#partition-area-local-completion-audit)
  confirms all 11 partition cases now use final observations. Local conversion
  work is complete; full-matrix validation remains. The
  [stored-object pilot](BETA7_STORED_OBJECT_WORKFLOW_REVIEW.md#pilot-implementation-and-focused-results)
  passed views and routines in one fixture. The
  [stored-object ALTER conversion](BETA7_STORED_OBJECT_ALTER_REVIEW.md#implementation-and-focused-results)
  also passed its focused case, including replay and journal checks. The
  [view rename conversion](BETA7_VIEW_RENAME_WORKFLOW_REVIEW.md#implementation-and-focused-results)
  also passed its focused case, including error and cache checks. The
  [conditional routine conversion](BETA7_CONDITIONAL_ROUTINE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
  also passed its focused case, including replay and journal checks.
  The [absent definer conversion](BETA7_ABSENT_DEFINER_WORKFLOW_REVIEW.md#implementation-and-focused-results)
  also passed its focused case, including both error stages and replay.
  The [executable-comment conversion](BETA7_EXECUTABLE_COMMENT_WORKFLOW_REVIEW.md#implementation-and-focused-results)
  also passed its two focused fixtures, including source/target version rules.
  The [temporary-table conversion and group audit](BETA7_TEMPORARY_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
  also passed both focused fixtures. All 11 stored-object group cases now use
  final observations. The [first character-set slice](BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#first-slice-implementation-and-focused-results)
  also passed its focused pair: table defaults and compound conversion.
  The [charset-conversion results](BETA7_CHARSET_CONVERSION_WORKFLOW_REVIEW.md#implementation-and-focused-results)
  also passed its focused case. The [DEFAULT workflow](BETA7_CHARSET_DEFAULTS_WORKFLOW_REVIEW.md#implementation-and-focused-results)
  passed its reverse case, including source session checks. The
  [encoded Query workflow](BETA7_QUERY_IDENTIFIER_WORKFLOW_REVIEW.md#encoded-query-implementation-and-focused-results)
  passed its forward case, including original byte and session checks. The
  [Unicode table-name workflow](BETA7_UNICODE_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
  passed its forward case, including name bytes and retained rows. The
  [lower-case table-name workflow](BETA7_LOWERCASE_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
  passed its forward mode-1 case, including both restarts and retained rows.
  The [DML identifier workflows](BETA7_DML_IDENTIFIER_WORKFLOW_REVIEW.md#unicode-implementation-and-focused-results)
  passed both focused forward cases. The
  [inventory workflows](BETA7_NATIVE_ENCODING_INVENTORY_REVIEW.md#native-encoding-implementation-and-focused-results)
  passed both focused forward cases, each with all 16 named assertions. The
  collation pilot is committed as `6574be6`. The
  [ENUM/SET workflows](BETA7_ENUM_SET_WORKFLOW_REVIEW.md#legacy-binary-set-implementation-and-local-completion)
  passed choices/widechoices with 12 assertions each, binarychoices with 14,
  exactchoices with 16, enumzero with 14 and choiceboundaries with 13 on forward
  MyISAM. Legacybinaryset passed 12 on the 5.7 MyISAM profile.
  The [character and binary value review](BETA7_CHARACTER_BINARY_VALUE_WORKFLOW_REVIEW.md#implementation-results)
  records all three conversions: 101 unit tests and 48 forward assertions passed.
  The [data-type review](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md) keeps all 25 IDs.
  The [type/value workflow results](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md#spatial-values-and-shared-spatial-fixture-results)
  record twenty-two completed conversions. All focused checks passed.
  JSON and spatial cases share the data-types-values fixture. Next: partial-JSON event checks.
  Keep all seven ENUM/SET IDs, cold metadata inputs, FULL overrides and version exclusions.

- Baseline, feature ownership, migration checks and generated-column changes:
  committed as `a0a130a` (Slices 1–3).
- Step 2: generated-column and FULLTEXT migrations pass focused local checks.
  FULLTEXT changes were committed as `615ed94` (Slice 4). Full CI is still required.
- Step 3: the `matrix-values` migration passes focused local checks (Slice 5);
  committed as `0bd7c2e`.
- Composite and text PRIMARY KEY cases are combined in
  `ddl-compat-primary-key-row-matching` (Slice 6). Focused tests passed on both
  InnoDB and MyISAM targets. Committed as `c3c8c3d`.
- Slice 7 combines conflict statements, adds cross-family shared fixtures and
  growth checks. Focused local checks passed. The plan has 179 jobs, each
  with one fixture group. Committed as `a273f44`.
- Slice 8 completes the Step 3 GTID review. Keep the preservation, tagged-GTID
  and `positive` cases: they have different assertions and already share setup.
  No test or selected execution was removed. Full CI is still required.
- Feature ownership is explicit. Slice 7 implements the first shared feature
  groups from Steps 4–5. Slice 9 completes the source review of group names and
  state isolation. The larger combined groups still require full-CI validation.
  Timing and coverage checks are Step 6. Final PR selection remains Step 7;
  cleanup is Step 8.

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

## Current execution plan after the MODIFY pilot

The pilot and failure diagnostics are committed as `30f3a16`. On the forward
MyISAM profile, `ddl-modify-columns` passed all 56 assertions. Local case time
fell from 158.7 to 21.6 seconds. Harness SQL client calls fell from 918 to 63.
It used two applier starts: one for the workflow and one for its restart check.
These are case measurements, not full-job or full-matrix results.

The next slice also passes focused local checks: column/index syntax and ALTER
column keys use 23 named observation phases and five deliberate live restarts.
Both retain offline replay. See [the results and remaining work](BETA7_TABLE_COLUMN_INDEX_REVIEW.md#focused-integration-results).
Generated dependencies also passed: 18 phase observations, four live restarts
and offline replay. Database lifecycle now belongs to the database group; all
seven applicable cases passed together on forward MyISAM. The matrix still has
187 jobs and 1,545 obligations. Database creation now shares one running applier
and one snapshot/restart across its six cases. All seven database cases passed
locally. Creation time fell from 109.5 to 40.5 seconds and SQL calls from 416 to
205. The full database group's executed runtime line set is unchanged.

The phase and database work is committed as `f62a9a4`. The next slice,
generated expressions and simultaneous column renames, passed all 26 named
assertions and both offline replay sequences on forward MyISAM. It retains
all six live restarts. SQL calls fell from 415 in the saved CI run to 336 locally.
This slice is committed as `99fb9d6`.

The small SQL selections with source GTID preservation disabled now share one
fixture per profile. See the [implementation results](BETA7_GTID_PRESERVATION_GROUP_REVIEW.md#implementation-results).
The four workflows in the [rename review](BETA7_RENAME_WORKFLOW_REVIEW.md) now
use independent table sets and final batched observations. Their focused checks
passed. The [table-option conversions](BETA7_TABLE_OPTIONS_WORKFLOW_REVIEW.md)
also pass focused checks. The [column-conversion slices](BETA7_COLUMN_CONVERSION_WORKFLOW_REVIEW.md)
are complete and pass focused checks. The [index-workflow review](BETA7_INDEX_WORKFLOW_REVIEW.md)
is complete. Continue Slice 2 with the three reviewed index cases, then validate
them with one image and two selected profile fixtures. Other areas still need review.

This direction retains Steps 4–5, but strengthens their execution rule. Sharing
containers alone is not sufficient. Ordinary correctness tests must also share
the running applier and batch source operations and result queries. Combine
small related groups when they can use the same fixture and settings.

### Default correctness workflow

1. Prepare the required schemas and seed rows together. Give independent cases
   separate tables or row keys. Preserve cold metadata reads where required.
2. Start one applier for the ordinary correctness sequence. Do not drain and
   restart it between cases solely to obtain a result or state snapshot.
3. Execute the source changes in batches. A batch reduces client invocations;
   it does not combine source transactions. Preserve session settings,
   transaction boundaries, statement order and expected errors.
4. Wait for the final source position once, then compare expected results,
   source, native replica and target as applicable. Batch the result queries.
   Export state and read binlog files once where the assertions permit it.
5. Report each named assertion, source operation and GTID/offset. On failure,
   show the failed operation and reason. Collect a support bundle and print its
   path. If collection fails, report that failure without hiding the test error.

Use an intermediate checkpoint only when the final observations cannot prove
an assertion. For example, an INSERT followed by DELETE can leave an empty
result even if both operations were omitted. Keep distinct rows, binlog checks
or an explicit comparison at that boundary. The MODIFY pilot retains such
phase comparisons. Do not remove an assertion merely to compare only once.

Restart, replay, rejected writes, recovery and metadata invalidation can need
specific state boundaries. Keep those boundaries named and justified. Separate
an unsafe fixture from later work. Keep performance tests separate from other
workloads. These exceptions do not justify restarting ordinary DDL/DML cases.

### Remaining slices, in order

| Slice | Work and result |
|---|---|
| 1 — Finish the table and column map | Use the saved SQL, assertions and coverage for `table-column-index-changes`. Record the final feature owner, required checkpoints and settings for each case. Start with column/index syntax and ALTER column keys beside the MODIFY workflow. Review database CREATE/ALTER/DROP ownership with `database-defaults-transactions`. Consult the MySQL manuals before assigning final names. No build or database run for this review. |
| 2 — Apply the workflow to table and column changes | Convert compatible cases to shared preparation, one running applier, batched changes and final comparisons. Keep generated-column, index and key assertions visible. Implement in small slices; verify each changed sequence on one representative profile. Do not merge the whole group with data-type tests solely because coverage overlaps. |
| 3 — Apply the workflow to remaining feature areas | Review partition management, stored objects, character sets/collations, data types and row-key/index operations. Keep each feature's DDL and DML together. Move or retire repeated DML only after mapping its assertions to the retained workflow. Retain engine/version-specific checks and the small metadata group. |
| 4 — Combine small compatible selections | Review small groups during each preceding slice. Include the `without-source-gtids` SQL selections: keep `positive`, generated-column and applicable tagged-GTID assertions. A merge must share fixture setup and ordinary applier execution, not concatenate separate runners. Preserve required lifecycle steps. Record any settings that prevent a merge. |
| 5 — Check the full suite and balance jobs | After the local slices pass, use one full instrumented CI run. Compare assertion results, SQL, coverage, setup time, applier starts, test time and runner time. Balance logical groups using the new measurements. Select the short PR case list last. |

Before changing a group, record its old cases, replacement assertions, required
settings, phase boundaries and proposed name. Use saved run `40454033524` for
unchanged groups. Exclude the retired bootstrap group when assigning retained
coverage. Mark changed groups as pending new measurements. Case counts and
coverage overlap alone do not establish redundant behavior.

Use the validation scope below for each implementation slice. Run only affected
unit/planner checks and one changed integration sequence locally. Add another
profile only for a changed engine/version path. Do not build or rerun tests for
this plan revision. Do not run full CI between individual slices.

## Validation scope for each step

Use this section for all remaining slices. Earlier validation records describe
completed work; they do not require those runs again. Full matrix coverage is a
CI requirement. It is not a local test list for each edit.

Before implementation, record the following in the slice:

- **Changed behavior:** the assertion, selection rule or fixture boundary.
- **Local checks:** exact test names or commands, profile, variant and transport.
- **Build:** the required product or image, or `none`.
- **CI checks:** combinations deferred to CI and the reason they are needed.
- **Stop condition:** the results that complete local verification.

Choose one profile that exercises the changed behavior. For a shared SQL path,
use `mysql84-to-mysql57-myisam`, default variant, SQL transport. For an
InnoDB-only or 8.4-target behavior, use `mysql57-to-mysql84-innodb`, default
variant, SQL transport. Add another profile only when the changed code or
assertion has a distinct engine or version branch. Name that branch in the
slice before starting the extra run. A source metadata change can require both
source versions; a generic cache assertion does not require all four profiles.
Use a non-default variant or BINLOG transport only when that path changed.

| Plan step | Local verification | Build required | Checks left to CI |
|---|---|---|---|
| 0 — Save baseline | Read saved results, SQL, timing and coverage. Check that required artifacts are present. | None. | Obtain a new baseline only if the saved run is incomplete or no longer applies. |
| 1 — Feature ownership and selection | Run affected catalog, migration and selector unit tests. Generate the full plan without containers; check applicability and owners. | Build the host lab only if its source or catalog code changed. | Existing profile matrix; no extra local database run for catalog-only edits. |
| 2–4 — Combine feature cases | Review old/new assertions and SQL. Run affected catalog/migration tests, then the changed case or combined sequence on one representative profile. Use a second profile only for a changed engine/version branch. | Host lab for Swift harness edits. Reuse a valid application image; build one if required by its inputs. | Remaining profiles, variants and transports; exact coverage comparison. |
| 5 — Share fixtures | Run the changed combined order once in one fixture. Check setup count, settings and state at case boundaries. Use the variant affected by the change. | Same build rule as Steps 2–4. | Other combinations and full-suite interaction checks. |
| 6 — Compare coverage and balance groups | Analyze saved reports. Run planner, assignment, fixture-count and growth tests after assignment changes. A pure job-label or assignment change needs no database run. A changed case order uses Step 5. | None for report or Python planner edits. | One full instrumented run after the reviewed changes are pushed. Rerun affected jobs for fixes; do not repeat successful jobs without a reason. |
| 7 — Select PR cases | Check explicit case lists, dependencies and profile applicability with planner tests. Do not rerun unchanged case bodies locally. | None unless selection code in the lab changed. | Measure the selected MyISAM and InnoDB jobs in parallel, with the shared build. |
| 8 — Docs and obsolete code | For docs, check links, command names and the diff. For code removal, run affected unit tests and compile affected targets. | None for docs. Build affected targets for code removal. | Periphery and the regular selected checks. Packaging checks only if packaging changed. |

### Build and retry limits

- Do not build for documentation, report analysis or Python-only planner edits.
- Build the host lab once after a batch of Swift harness edits. Run focused unit
  tests in the same build directory so they reuse compiler output.
- Check the application image inputs before integration. Reuse a valid image
  with `--skip-build`. Do not change its input label to bypass validation. If
  the image is invalid, record why and build the required image once. Reuse it
  for subsequent runs while its inputs remain valid.
- Do not build Debian packages, static release binaries or unrelated products
  for test-group changes. Do not run the syntax suite unless syntax code or its
  test/build setup changed.
- After a failure, read its saved evidence first. Fix and rerun that case on the
  same profile. Do not rerun successful cases or add profiles to debug a shared
  assertion. Expand only for a concrete unresolved difference.
- Stop when the listed local checks pass. Leave unchanged restart, recovery and
  replay checks to their existing cases in CI. Do not add them to a local run
  merely because the changed case uses the same applier.

### Current metadata slice: local checks complete

The metadata-read cases already passed locally. The cache case passed on
`mysql84-to-mysql57-myisam` and `mysql57-to-mysql84-innodb`, with the default
variant and SQL transport. These checks cover both target engines. No further
local profile, restart, file-position/MINIMAL or full-group run is required for
this slice. No further build is required while build inputs are unchanged.
See [the metadata results](BETA7_METADATA_GROUP_REVIEW.md#local-integration-checks).
Next, review unchanged groups with the saved passing baseline. Exclude the old
bootstrap group when assessing coverage supplied by retained groups. New metadata
coverage and timing remain pending. Batch further reviewed changes before the
next full CI run. A failure can reopen only the affected local check; it does not
restart the whole validation list.

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

Slice 7 added planner checks for a fifth profile and an additional source
variant. These are planning checks, not extra test combinations to run now.
Use them to choose a job budget below the planner's 256-job limit. Do not aim for
255 jobs or require an emergency redesign each time a profile is added.

At Slice 7, the four-profile plan had 179 execution groups and 179 jobs. Each job
ran one fixture group. That policy rejected plans above 185 jobs. It also
checked two separate growth scenarios against a 250-job budget: one additional
profile, or one additional source variant across current profiles. Both need at
most 245 jobs. These checks run during full planning and do not schedule the
hypothetical tests. They are capacity estimates, not proof that a new topology
is supported.

Do not pack separate fixture invocations into a job to reduce matrix entries.
Combine compatible cases in the same fixture. If cases cannot share setup,
keep separate jobs and include that cost in the growth budget.

## Starting evidence

- Full CI run `40170659705` passed all 250 integration groups. It has all 263
  expected integration coverage collections and 2,095 catalog obligations.
  Unit coverage is missing because the unit job was cancelled. This run is not
  a complete passing CI result.
- The starting local grouping changes produced 240 groups and 253 coverage
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
3. A **CI job** runs exactly one execution group. Independent jobs run in
   parallel. Report setup, test and cleanup time separately. Cases in a group
   share the MySQL containers. Required restart/replay operations remain named
   test steps; they must not hide repeated fixture setup.

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
  Use the default correctness workflow above: prepare schemas together, keep
  one ordinary applier running, batch source changes and compare at the end.
  Record required intermediate observations and deliberate lifecycle steps.
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

- Start with saved passing measurements for unchanged groups. Check case bodies,
  selections, settings and fixture order before reusing their evidence. Do not
  wait for a new full run to review other groups after one group changes.
- Batch reviewed changes, then run one full instrumented CI selection after
  local checks pass and the user has pushed. Use the existing reusable build.
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
  groups only when they can share a fixture. Keep incompatible fixtures in
  separate jobs. Retain and explain longer inseparable recovery workflows.
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

Record the [validation scope](#validation-scope-for-each-step) before each slice.
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


## Slice 7 — Shared feature fixtures, conflict statements and growth checks

This slice implements the next Step 3 conflict migration and the related fixture
boundaries from Steps 4–5. It does not complete all feature reviews or GTID work.

### Shared fixtures

The planner accepts an explicit `cases` area across existing catalog families.
Explicit owners take precedence over family fallback. Duplicate owners, unknown
cases, stale named-group assignments and omitted families fail planning. Required
dependencies and catalog order remain intact. New cases can join an existing
group without another job.

The new shared groups are `keys-rows-gtids`, `table-column-changes`,
`character-sets-collations`, `data-types-values` and `bootstrap-schema-discovery`.
The key group combines relevant key DDL, index changes, row operations and the
existing GTID cases. These GTID assertions have moved, not been removed or merged.
The bootstrap group retains each case's isolated state and saved-state resume,
while reusing its MySQL containers. Other groups retain their profile, source
variant, transport and applicability rules.

`max_groups` remains 1. A policy test enforces one group per job. No job starts
another fixture to run a second group. This replaces the earlier idea of packing
separate groups into fewer jobs. Required restart and replay tests remain intact.

The existing demo jobs were an exception: each started four or five fixtures.
The planner now separates their sessions into workbook, container repair,
baseline-GTID resume, applied-checkpoint resume and reverse workbook/recovery.
Each session keeps its related assertions and its fresh state. Dependencies cannot
cross demo groups. CI passes the selected cases to the demo command and expects
one combined coverage report per session.

### Conflict statements

Use the MySQL names:
[INSERT ... ON DUPLICATE KEY UPDATE](https://dev.mysql.com/doc/refman/8.4/en/insert-on-duplicate.html),
[REPLACE](https://dev.mysql.com/doc/refman/8.4/en/replace.html) and
[INSERT IGNORE](https://dev.mysql.com/doc/refman/8.4/en/insert.html).

`ddl-compat-key-conflicts` replaces the three live matrix cases. It retains all
11 CREATE/row statements and three independent tables with their original column
and key definitions. It checks exact rows after every row statement:

- INSERT ON DUPLICATE KEY UPDATE changes one existing row and inserts another.
  Repeating a value then changes no rows.
- REPLACE conflicts with two different existing rows through PRIMARY KEY and
  UNIQUE KEY. Both conflicting rows must be replaced by the expected result.
- INSERT IGNORE skips both primary-key and unique-key conflicts while inserting
  a valid row. Its later duplicate-only statement changes no rows.

The three bootstrap fixtures retain all eight phases. Three migration records
retain all 30 original profile/variant/transport executions in ten combined
executions. This changes 2,055 catalog obligations to 2,035, without removing a
source condition. The other executions and the PR selection are unchanged.

### Job count and growth

| Plan | Execution groups | CI jobs | Fixture setups | Coverage collections |
|---|---:|---:|---:|---:|
| Before Slice 7 | 240 | 240 | 254 | 253 |
| Shared feature fixtures | 179 | 179 | 179 | 178 |

The reduction removes 75 fixture invocations. Coverage collections decrease
because each combined fixture emits a union report, not because cases stop
running. The native-only fixture does not produce application coverage. Separating
the demo sessions keeps their 18 fixtures and makes each setup visible in its own
job. The planner still checks case ownership and required assertions.

Full planning enforces 185 current jobs and 250 jobs in each growth scenario.
The fifth-profile check clones each current profile in turn, including its
variants, suites and transport groups. It needs 214–245 jobs. A separate source
variant check clones the default correctness/lifecycle groups across current
profiles; it needs 242 jobs. These are separate simulations. Simultaneous profile
and variant additions need a new review.

Scheduling estimates sum prior areas. Some combined groups can be long. The full
CI run must measure their duration, memory use and coverage output before final
balancing. Keep the current one-fixture-per-job rule when adjusting boundaries.

### Validation

Evidence is under `artifacts/test-suite-consolidation/key-conflicts/`. The plan
audit compares all executions before and after the change and checks one group
per job. It retains all unrelated executions and the exact PR selection.

The selected InnoDB run combined the conflict workflow with representative
constraint, index, row-operation and bootstrap cases in one fixture. The baseline
and candidate used the same application binary and server settings. The candidate
passed all 11 conflict assertions. All eight bootstrap phases matched. The
original source statements and table observations matched after table/database
name substitution. No covered lines were lost; 28 lines were added. Runtime was
338.66s versus 322.52s, with 865 SQL calls versus 840. This comparison checks
retained behavior; it does not measure the full merged group or a reduction in
setup, because both selected local runs used one fixture.

The conflict workflow also passed on 8.4 → 5.7 MyISAM in 104.91s. Both no-op
statements retained their zero-transaction checks. The focused Swift unit test,
117 CI-tool tests, 43 lab-tool tests and 24 component/selection tests passed.

The selected `demo-container-repair` session passed on 5.7 → 8.4 InnoDB. Its
raw results contain one fixture and one combined coverage report. Fixture setup
took 28.39s, including 24.68s for container startup and 3.12s for database setup.
The `lab_compare.py record` wrapper failed after the successful test because it
expects `runtime.json` directly in the case evidence directory. Demo fixtures
are nested below that directory. `demo-validation.json` records the raw result
and coverage checks. Extend that local comparison helper before comparing whole
demo runs; this does not affect CI's recursive coverage collection.

Leave the full merged groups and complete profile/variant matrix to GitHub Actions.

Next: finish the Step 3 GTID review, then review the remaining Step 4 feature
boundaries. Use full CI for Step 6 timing and coverage checks. Select the final
short PR test set last.

## Slice 8 — GTID review

Decision: retain both GTID cases and `positive`. Step 3 allows a case to remain
when a replacement would lose a distinct condition or obscure the workflow.
These cases already use the `keys-rows-gtids` fixture. A case merge would not
remove another MySQL setup or CI job.

### Conditions and overlap

| Case | Required conditions | Why another retained case does not replace it |
|---|---|---|
| `ddl-compat-source-gtid-preservation` | One INSERT with 40 rows and JSON values; restart before a 40-row UPDATE; multirow DELETE; duplicate NULL rows in a table without keys; target source-GTID membership after live apply and replay | `positive` has small row statements. The keyless case tests more row types and failure/recovery behavior, but does not check target GTID membership for this 40-row sequence. |
| `ddl-compat-tagged-gtids` | Interleaved `blue`, `green` and untagged transactions; binlog rotation; two live restarts; six tagged APPLIED groups; two tagged DDL intents; independent tag ranges; replay stopped at a tagged GTID | Ordinary GTID preservation cannot test tags on a 5.7 target. This case uses SQLite tracking with target preservation disabled. |
| `positive` | Exact source/target GTID delta equality when preservation is enabled; no source GTIDs on target when disabled; exact counters, normalized binlog operations, saved offset, row intents, credentials and transport checks | The preservation case checks source-GTID membership, not exact delta equality or the absence of source GTIDs when preservation is disabled. Its replay checks do not replace these other assertions. |

The shared DDL runner checks transaction counts, the final applied GTID set and
completed DDL intents. These checks support the dedicated GTID conditions; they
do not replace them. `offline-replay` checks fetched and external archives,
saved-state resume, unreachable source credentials and support-bundle contents.
It does not replace the 40-row preservation sequence or tagged identities.

The preservation replay check is meaningful after live apply: `replayDDLWorkflow`
clears target binlog/GTID history and restores the starting GTID set before it
replays the case. Source GTIDs left by the live run cannot make the final replay
membership check pass. The helper also stops after two transactions, resumes
without source credentials and compares the final schema and rows.

The review used `TaggedGTIDCases.swift`, `SharedCorrectness.swift`,
`DDLReplayWorkflow.swift`, `SharedBootstrapDML.swift`, `SharedOffline.swift`,
`KeylessCases.swift` and `LabScenario.swift`. No SQL statement, assertion,
restart, replay step or source/target setting changed.

### Selection and validation

- Source-GTID preservation runs once on each of the four profiles, with the
  default variant and SQL transport. Each execution shares its fixture with
  21 or 22 other cases.
- Tagged GTIDs run once on 8.4 → 5.7 MyISAM, with `without-source-gtids` and SQL
  transport. This execution shares its fixture with `positive`.
- The dedicated GTID cases are not selected for BINLOG transport. `positive`
  provides the existing BINLOG transport GTID checks. This review does not claim
  that the full dedicated GTID sequences were tested with BINLOG transport.

The generated full plan matches the saved Slice 7 plan exactly: 179 jobs,
2,035 applicable obligations and 178 application coverage collections. The
selection report is `artifacts/test-suite-consolidation/gtid-review/selection-review.json`.
This was a source and plan review. No integration test was rerun, because test
execution did not change. Earlier coverage is supporting evidence, not a new
passing result for the larger merged groups.

Step 3 is complete for this reorganization. Next: finish Steps 4–5 by reviewing
the remaining group names and state isolation. Then use full CI for Step 6.
Keep the final PR selection last. Do not start another case migration unless the
review identifies a concrete duplicate or a missing assertion.

## Slice 9 — Group names and state isolation review

This slice changes execution-group names only. It preserves group membership,
case order, dependencies, assertions, profiles, variants and transports. It does
not add fixture setup, change replication code or change SQL workloads.

### Names

Consulted the MySQL 8.4 Reference Manual sections on
[Partitioning](https://dev.mysql.com/doc/refman/8.4/en/partitioning.html),
[Stored Objects](https://dev.mysql.com/doc/refman/8.4/en/stored-objects.html),
[FOREIGN KEY Constraints](https://dev.mysql.com/doc/refman/8.4/en/create-table-foreign-keys.html)
and [Character Sets, Collations, Unicode](https://dev.mysql.com/doc/refman/8.4/en/charset.html).
Names combine these feature names with plain descriptions of the tests. The
view/routine group also contains temporary tables; its name must not imply that
these are stored objects. Case IDs and catalog families remain unchanged.

| Previous area | Current area |
|---|---|
| `database` | `database-defaults-transactions` |
| `ddl-partitions` | `ddl-partition-management` |
| `ddl-stored-objects` | `ddl-views-routines-temporary-tables` |
| `foreign-keys` | `foreign-key-definitions-actions-recovery` |
| `refusals` | `compatibility-policies-error-skipping` |
| `ordered-ddl` | `ordered-schema-changes-resume` |
| `collation` | `collation-translation-collisions` |
| `filters-discovery` | `table-filters-index-resume` |
| `failure-recovery-offline` | `write-failures-recovery-replay-control` |
| `table-column-changes` | `table-column-index-changes` |
| `reconnect` | `connection-restarts-uncertain-writes` |
| `recovery` | `innodb-rollback-recovery` |
| `native-ddl` | `native-source-restrictions` |

Other descriptive group names stay unchanged. The explicit BINLOG and PR
selections stay unchanged. Scheduling estimates follow the renamed areas with
the same values. Historical reports retain their old names; use this table when
comparing them with the next CI run.

### State isolation

The review followed the call order in `SharedCorrectness.Run.execute`, not the
order of areas in the policy. `LabTests` creates one runner for a selected
profile, suite and variant. The runner prepares its fixture once.

| Boundary | Existing handling |
|---|---|
| Continuous and isolated writers | The main writer drains and checks saved state before isolated cases start. `LabIsolatedApply` assigns state directories and starting positions by case. Resume retains that case's state. |
| DDL tables and native engine | Each DDL compatibility case recreates `ddlcompat`. The runner sets the declared native engine and restarts the SQL thread after catch-up. DML and index families reset the engine before their cases. |
| Row metadata | DDL cases set the variant metadata or their FULL override. Matrix and bootstrap cases set their own metadata. Index cases reset to the variant setting. |
| Index fixtures | The combined column MODIFY workflow resets each starting definition through replication. It keeps per-ALTER rows, counters, binlogs and schema history, with one final saved-state restart. Standalone index cases retain their state boundaries. |
| Bootstrap discovery | Tables are seeded without binlogging. Cases retain separate schema definitions, state and resume phases. Shared containers do not turn first discovery into a warm-cache lookup. |
| Replay | Replay uses its own archive and state directory. Fresh replay restores target data and GTIDs to the baseline. Resume retains state. DDL replay restores the live configuration file before restarting the main writer. |
| Native filters | `SharedFilters` clears native filters and starts replication before its included-table rejection check. Its saved-state dependency chain remains together. |
| Expected MyISAM failures | Forward failures restore applier grants. Forward-failure and MyISAM recovery cases save native failure output, reset the rejected range and check that the SQL thread runs before returning. |
| Special settings | Permission cleanup attempts to restore the timestamp default and drop its account. Large-value tests establish and restore a known packet limit; this case remains last in its data-type group. |
| Unexpected failure | The runner stops the group, saves diagnostics and cleans up. It does not continue on possibly invalid state. Later cases remain not run; other jobs remain independent. |

No new reset was needed from this source review. This is not proof that all
combined groups pass. Permission cleanup uses best-effort cleanup, and some
tests establish a known setting instead of restoring its initial value. Review
these conditions again before moving cases across those boundaries. A generic
reset could remove saved state or a cold-discovery condition under test.

The runner still performs some common SQL preparation when no case from that
family is selected. This is not a second container setup. Measure its cost in
Step 6 before changing it; the change can affect saved schema history.

### Validation and next step

The full-plan audit confirms identical case lists and order in all 179 groups.
Inventory, dependencies, coverage counts, growth checks and job estimates are
unchanged. Every current area has an explicit estimate. The PR plan matches
Slice 7 exactly. All 117 CI-tool tests and 24 component/selection tests passed.
No MySQL integration test was rerun for these label changes.

Evidence is under `artifacts/test-suite-consolidation/group-review/`:
`area-renames.json`, `full-after.json`, `plan-review.json`, `planner-tests.log`
and `selection-tests.log`.

Steps 4–5 now have reviewed names and fixture boundaries. Runtime acceptance
remains part of Step 6. Next: after the user pushes, run one full instrumented
CI selection. Check case completeness and failures first, then coverage,
setup/test time and the longest groups. Rerun only affected jobs for fixes.
Select the final short PR case list after those measurements.


## Slice 10 — 10K replication time comparison

The user requested this group before the next push. It adds one named case,
`performance/backlog-10k`, for each of the four profiles. SQL owns the catalog
obligation. Four additional BINLOG jobs test the other transport. Each job uses
one fixture, with native replication followed by the external applier.

The case checks 10,000 INSERT transactions, all target rows and the saved GTID
checkpoint. It compares external elapsed time with native elapsed time. The
limit is configurable. CI starts with a 2× limit and report-only mode. A ratio
above the limit remains visible as `over_limit`. Report-only mode cannot accept
data differences, checkpoint failures, timeouts, or fixture errors.

Full CI now has 187 jobs, 2,039 catalog obligations, and 186 coverage collections.
The PR case list is unchanged. The job budget changes from 185 to 190
to include the eight requested runs. The projected budget changes from 250 to
255. The largest extra-profile model now reaches 255 jobs. One extra source
variant reaches 250. This leaves too little room for more large additions.
Before adding such a profile, split execution into separate matrices or reduce
the existing groups. Do not raise the budget above GitHub's 256-job limit.

The benchmark uses the existing backlog workload and native reference. CI uses
the coverage application build. Instrumented times must not be presented as
production binary times. The job and combined reports retain both elapsed times,
the ratio, transport, build instrumentation, limit, and policy.

Focused validation: 55 Swift tests, 120 CI-tool tests, 43 lab-tool tests, and
24 component/selection tests passed. The full catalog plan passes feature
ownership, dependency, coverage-count, fixture-count and growth checks. Local
10K results are recorded in [the benchmark report](BETA7_10K_BENCHMARK.md).
All eight data/checkpoint checks and coverage collections passed. All eight
ratios exceeded 2× and were accepted only by report-only mode.


## Next work after the passing full CI run

See [the CI fixes and test-suite feedback plan](BETA7_CI_FOLLOWUP.md).
Run `40454033524` passed at `efb3458`. The failure fixes are complete.
The [metadata group review](BETA7_METADATA_GROUP_REVIEW.md) maps 47 repeated
DML fixtures to existing owners and identifies four target-only workflows to
retain. Keep a small metadata group for reads, cache reuse and DDL invalidation.
The focused replacements and retirement map are now implemented. Focused local
checks passed on both target engines. Continue reviews of unchanged groups with
the saved assertions, SQL, coverage and timings. Metadata measurements remain
pending. Batch further changes before the next full CI run, then verify the new
measurements and balance groups. Select the short PR suite last.


The [table/column/index review](BETA7_TABLE_COLUMN_INDEX_REVIEW.md) is complete.
The combined `ddl-modify-columns` workflow is implemented with named per-ALTER
checks. The phase pilot and failure diagnostics are committed as `30f3a16`.
Its focused validation is recorded in that review. Follow the
[current execution plan](#current-execution-plan-after-the-modify-pilot) for the
remaining groups. Keep unchanged group measurements from the saved passing run
until the next full CI check.


## Small SQL selections: review complete

See [SQL tests with source GTID preservation disabled](BETA7_GTID_PRESERVATION_GROUP_REVIEW.md).
Combine eight SQL jobs into four, with one fixture per profile. Keep basic DML,
generated columns and the applicable tagged-GTID case. Retain the count-limited
applier and named restart/replay checks. The review maps assertions, saved
coverage and timings, execution order and validation scope. The policy selection is now implemented. Its focused results are recorded
in that review. No new full CI run
is needed before that change. Select the short PR suite after the later full run.


## Rename workflow review complete

See [the rename workflow review](BETA7_RENAME_WORKFLOW_REVIEW.md). Use independent
table sets to retain distinct outcomes until one final batch of checks. Distinct
assertions do not require separate waits. Keep mapped stop/resume and replay
conditions. The review covers destination metadata, scoped SQLite checks and
replay cleanup for surviving cross-database tables.

The `ddl-compat-multi-table` pilot passed nine unit tests and one forward
MyISAM/default/SQL run with coverage. It keeps five restart checks and passes
25 named assertions. Harness SQL calls fell from 228 to 94. The review records
the measurements and their limits. The matrix remains unchanged.

The compound table rename and cross-schema FK conversion also passed. Both
cases ran in one fixture per profile on forward MyISAM and reverse InnoDB.
Each profile passed 50 named assertions. Original restart and replay boundaries
remain. Harness SQL calls fell from 426 to 182 on forward MyISAM and from 424 to
180 on reverse InnoDB. See the review for timings, coverage scope and build notes.

The column rename conversion also passed on forward MyISAM in OrbStack:
30 named assertions, all four original restarts, and replay stopped after the
third transaction. All 12 focused unit tests passed. Harness SQL calls fell from
226 to 88. The review records timings, coverage scope and the assertion map.

The [table-option conversions](BETA7_TABLE_OPTIONS_WORKFLOW_REVIEW.md#completion-and-next-review)
are complete. Table options and index maintenance passed together on forward
MyISAM. ALTER options passed on forward MyISAM and with ignored CHECK clauses
on reverse InnoDB. All 82 named integration assertions and ten focused unit tests
passed. Harness SQL calls fell from 816 to 302 across these selected runs.
The original nine restarts, two replay stops, case IDs and matrix remain.

The [column-conversion slices](BETA7_COLUMN_CONVERSION_WORKFLOW_REVIEW.md#completion-and-next-review)
are complete. The three cases passed on forward MyISAM: 42 named integration
assertions and 20 focused unit tests. Harness SQL calls fell from 498 to 135.
The source timestamp reset preserves fresh-client behavior within each batch.
Intermediate types and the fractional row remain available for final comparison.

The [index-workflow conversions](BETA7_INDEX_WORKFLOW_REVIEW.md#focused-integration-results)
are complete. The three cases passed together on 5.7-to-5.7 MyISAM. JSON and
FULLTEXT also passed on reverse InnoDB with the same coverage image. All 97 named
integration assertions, 58 focused Swift tests and 18 migration/feature tool tests
passed. Harness SQL calls fell from 1,203 to 328. Both fixtures completed cleanup,
saved-schema restart and coverage export. The matrix and profile exclusions remain.

The [generated-column conversions](BETA7_GENERATED_COLUMN_WORKFLOW_REVIEW.md#focused-integration-results)
are complete. Both cases passed in one forward MyISAM fixture: 38 named assertions,
including ten replay checks. All 54 focused Swift tests and 18 tool tests passed.
Harness SQL calls fell from 279 in saved CI to 97. The expression case's earlier
local phase conversion used 121 calls; this conversion uses 64. The three migration
assertions, two live restarts and replay stop after transaction three remain.
Cleanup, saved-schema restart and coverage export passed. The matrix is unchanged.

The [dependency and column-swap conversion](BETA7_DEPENDENCY_SWAP_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed in one forward MyISAM fixture. Each case uses five body batches and keeps
four live restarts. All 98 named assertions, both offline replay stop/resume
checks, saved-schema restart and cleanup passed. Client calls fell from 273 to
80 for dependencies and from 215 to 82 for swaps. Case times were 46.51s and
44.74s. The matrix is unchanged.

The [column-key conversions](BETA7_COLUMN_KEY_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed in one forward MyISAM fixture. All 78 named assertions, five live restarts,
both replay stop/resume checks and the exact original AUTO_INCREMENT context
check passed. Client calls fell from 351 to 132. The combined coverage comparison
found three old-only source-rate sampling lines and one new queue-wait line;
no DDL lines were lost. The matrix, saved-schema restart and cleanup passed.

The [completion review](BETA7_TABLE_COLUMN_INDEX_COMPLETION.md) confirms all 21
current table/column/index cases use the shared workflow approach. Local slices
are complete; whole-group timing and full-matrix validation remain for CI.

The [partition pilot](BETA7_TABLE_COLUMN_INDEX_COMPLETION.md#partition-pilot-implementation-and-focused-results)
passed in one forward MyISAM fixture. Both cases use one body batch. All 41
named assertions, saved-schema restart, completed-DDL checks and cleanup passed.
Client calls fell from 282 in saved CI to 65 locally. The InnoDB native reference,
MyISAM target, case selections and matrix remain unchanged.

The [partition forms conversion](BETA7_PARTITION_FORMS_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed all three cases in one forward MyISAM/default/SQL fixture. It keeps the
15 original predicates, eight live restarts and both offline replay paths.
All 136 named assertions, saved-schema restart and cleanup passed. Harness SQL
client calls fell from 638 in saved CI to 195 locally. The matrix is unchanged.

The [partition rename/bounds conversion](BETA7_PARTITION_RENAME_BOUNDS_REVIEW.md#implementation-and-focused-results)
passed all three cases in one forward MyISAM/default/SQL fixture. All 120 named
assertions, eight live restarts, three replay stop/resume checks, saved-schema
restart and cleanup passed. Harness SQL client calls fell from 649 in saved CI
to 242 locally. The original SQL, byte predicates and matrix remain intact.

The [partition administration conversion](BETA7_PARTITION_ADMINISTRATION_REVIEW.md#implementation-and-focused-results)
passed all three cases across two focused forward MyISAM/default/SQL fixtures.
All 105 named assertions, seven restarts, both replay paths and five unlogged
boundary checks passed. Client calls fell from 591 in saved CI to 185 locally.
The original SQL, predicates and matrix remain intact.

The [partition completion audit](BETA7_PARTITION_ADMINISTRATION_REVIEW.md#partition-area-local-completion-audit)
confirms all 11 cases use final observations, with 34 body batches and 23 live
restarts. Local partition conversion work is complete. Full-matrix validation
and whole-group timing remain for CI.

The [stored-object pilot](BETA7_STORED_OBJECT_WORKFLOW_REVIEW.md#pilot-implementation-and-focused-results)
passed both views/routines cases in one forward MyISAM/default/SQL fixture.
All 23 named assertions, original absence checks, compound-body checks,
saved-schema restart and cleanup passed. Client calls fell from 222 in saved CI
to 78 locally. The eight original predicates and matrix remain intact.

The [stored-object ALTER conversion](BETA7_STORED_OBJECT_ALTER_REVIEW.md#implementation-and-focused-results)
passed its focused forward MyISAM/default/SQL fixture. All 52 named assertions,
three restarts, replay stop four/resume 79, the three original journal records,
saved-schema restart and cleanup passed. Client calls fell from 263 in saved CI
to 86 locally. The 11 original predicates and matrix remain intact.

The [view rename conversion](BETA7_VIEW_RENAME_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed its focused forward MyISAM/default/SQL fixture. All 50 named assertions,
three restarts, replay stop seven/resume 77, four original journal records,
view/base-table cache checks, error 1450 checks, saved-schema restart and cleanup
passed. Client calls fell from 251 in saved CI to 97 locally. The 11 original
predicates and matrix remain intact.

The [conditional routine conversion](BETA7_CONDITIONAL_ROUTINE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed its focused forward MyISAM/default/SQL fixture. All 38 named assertions,
two live restarts, replay stop four/resume 50, original journal counts five/two,
saved-schema restart and cleanup passed. Captured source GTIDs select the original
journal records because MySQL changes stored routine SQL formatting. Client calls
fell from 186 in saved CI to 79 locally. All six original predicates and the matrix
remain intact.

The [absent definer conversion](BETA7_ABSENT_DEFINER_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed its focused forward MyISAM/default/SQL fixture. All 38 named assertions,
two restarts, replay stop four/resume 13 and twelve ERROR 1449 checks passed.
Each error left GTIDs/offsets unchanged. Both error stages have separate evidence.
Saved-schema restart and cleanup passed. SQL trace calls fell from 177 in saved
CI to 111 locally; both totals include the twelve expected failures. All four
original predicates and the matrix remain.

The [executable-comment conversion](BETA7_EXECUTABLE_COMMENT_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed its two focused default/SQL fixtures: main/target-version on forward
MyISAM, source-version on reverse InnoDB. All 39 named assertions, four restarts,
three replay paths, original journal records, role-specific comments,
saved-schema restarts and cleanup passed. SQL trace calls fell from 359 in saved
CI to 188 locally. Original predicates, comment bytes and profile selections
remain.

The [temporary-table conversion](BETA7_TEMPORARY_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed both focused fixtures: 43 named assertions, retained row checks, engine
variants, permanent `tmp` rows, 5.7 cleanup audit, restart/replay and cleanup.
Source counts remain observed: the 12-operation SELECT workflow produced 17
transactions on 5.7. Exact replay offsets passed. SQL trace calls fell from 438
in saved CI to 173 locally. The permanent CTAS contract is unchanged. The
[group audit](BETA7_TEMPORARY_TABLE_WORKFLOW_REVIEW.md#stored-object-group-local-completion-audit)
finds all 11 cases converted with the same profile selections.

The [first character-set slice](BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#first-slice-implementation-and-focused-results)
passed table defaults and compound CONVERT/default clauses together on forward
MyISAM. All 26 named assertions, seven original predicates, four restarts,
exact GTIDs/offsets, saved-schema restart and cleanup passed. SQL trace calls fell
from 335 in saved CI to 111 locally. Matrix and profile selections remain.
The [charset-conversion results](BETA7_CHARSET_CONVERSION_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed the focused forward MyISAM case. All 17 named assertions passed.
Four batches retain six old predicates, three restarts, FULL metadata and exact
GTID/file offsets. SQL client calls changed from 222 in saved CI to
73 locally. The [DEFAULT workflow results](BETA7_CHARSET_DEFAULTS_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed the reverse case with all 17 named assertions. Five batches preserve
unselected-database statements, logged collation overrides, four old predicates
and INSERT/UPDATE row states. Captured Query events confirm the session contexts.
SQL client calls changed from 168 in saved CI to 64 locally.
The [encoded Query workflow](BETA7_QUERY_IDENTIFIER_WORKFLOW_REVIEW.md#encoded-query-implementation-and-focused-results)
passed the forward MyISAM case with all 15 named assertions. Three batches
retain four old predicates, both restarts, FULL metadata and the added-column
value before UPDATE. Captured events confirm 12 exact non-UTF-8 DDL payloads
and 13 following UTF-8 row/DROP sessions. SQL client calls changed from
217 in saved CI to 62 locally. The [Unicode table-name workflow](BETA7_UNICODE_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed the forward case with all 20 named assertions. One body batch preserves
all original names, four old predicates, pre-update/renamed/LIKE rows and DROP
outcomes. Saved state confirms nine current tables with exact bytes and retired
names. SQL client calls changed from 213 in saved CI to 60 locally.
The [lower-case table-name workflow](BETA7_LOWERCASE_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed the forward lowercase-tables case with all 21 named assertions. Three
batches preserve mixed-case references, both old predicates, both restarts and
earlier ADD/copy rows. Runtime evidence confirms mode 1 on all three servers.
SQL client calls changed from 160 in saved CI to 74 locally. The
[DML identifier workflows](BETA7_DML_IDENTIFIER_WORKFLOW_REVIEW.md#unicode-implementation-and-focused-results)
passed their focused forward cases: 16 ASCII assertions and 20 Unicode assertions.
Both keep the original SQL and metadata inputs, check GTID intervals and add no
applier restart. The [inventory workflows](BETA7_NATIVE_ENCODING_INVENTORY_REVIEW.md#native-encoding-implementation-and-focused-results)
passed both focused forward cases, each with all 16 named assertions. They keep
all 63 collation members and 36 encoding vectors. The
[ENUM/SET workflows](BETA7_ENUM_SET_WORKFLOW_REVIEW.md#legacy-binary-set-implementation-and-local-completion)
passed choices/widechoices with 12 assertions each, binarychoices with 14,
exactchoices with 16, enumzero with 14 and choiceboundaries with 13 on forward
MyISAM. Legacybinaryset passed 12 on the 5.7 MyISAM profile.
The [character and binary value review](BETA7_CHARACTER_BINARY_VALUE_WORKFLOW_REVIEW.md#implementation-results)
records all three conversions: 101 unit tests and 48 forward assertions passed.
The [data-type review](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md) keeps all 25 IDs.
The [type/value workflow results](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md#spatial-values-and-shared-spatial-fixture-results)
record twenty-two completed conversions. All focused checks passed.
JSON and spatial cases share the data-types-values fixture. Next: partial-JSON event checks.
Keep all seven IDs and their metadata/version rules.
Keep remaining type/value and key/index work, full-matrix validation, final
balancing and short PR selection later.
