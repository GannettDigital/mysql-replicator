# Beta.7 CI fixes and test-suite feedback

Status: full CI run `40454033524` passed at `efb3458`. All 2,039 selected catalog
obligations passed; all 186 integration coverage collections are present.
The first reorganization review is recorded in
[Smaller table metadata test group](BETA7_METADATA_GROUP_REVIEW.md).
The metadata slice replaces 47 repeated DML cases with three focused cases.
Their DML workloads remain in the feature groups. Focused local checks passed.
Use the [per-step validation scope](BETA7_TEST_SUITE_CONSOLIDATION.md#validation-scope-for-each-step)
for subsequent work. Do not repeat the completed local profile checks.

## Current grouping direction

The MODIFY pilot and failure diagnostics are committed as `30f3a16`.
Follow the [revised execution plan](BETA7_TEST_SUITE_CONSOLIDATION.md#current-execution-plan-after-the-modify-pilot)
for remaining work. It takes priority over the earlier next-step notes below.

Group cases by MySQL feature. Prepare schemas together, keep one applier running,
execute source changes in batches, and compare at the end. Preserve transaction
boundaries. Keep explicit checkpoints where final results cannot prove a required
condition. Combine small related groups that can share the fixture and settings.
A combined job must not repeat container setup or restart the applier for each
ordinary correctness case.

The next slice is implemented: column/index syntax and ALTER column keys use
named SQL phases. Both passed in one forward MyISAM fixture, including restart
and offline replay. Harness SQL calls fell from 686 in the saved CI run to 351
in the local run. See [the results](BETA7_TABLE_COLUMN_INDEX_REVIEW.md#focused-integration-results).

Generated dependencies now use 18 named observation phases and four retained
live restarts. All 22 assertions and offline replay passed locally. Calls fell
from 365 in the saved CI run to 273. Database lifecycle now belongs to the
database family; all seven applicable cases passed in one shared fixture.
The planner retains 187 jobs and all 1,545 current obligations.

Database creation batching also passed. Six cases now share one running applier
and one snapshot/restart. Local creation time fell from 109.5 to 40.5 seconds;
SQL calls fell from 416 to 205. The full database group passed with five applier
processes instead of ten. Its executed runtime line set is identical: 7,317 lines.

The phase and database work is committed as `f62a9a4`. Generated expressions
and simultaneous column renames now also pass focused checks: 26 named
assertions, six live restarts and both offline replay sequences. Harness SQL
calls fell from 415 in saved CI data to 336 locally. This slice is committed
as `99fb9d6`. The small SQL selections now share a fixture per profile. All four
rename workflows also passed their focused checks with batched observations.
See the [latest results and next review](BETA7_RENAME_WORKFLOW_REVIEW.md#column-rename-results).
Continue with table options and maintenance before full CI and final PR selection.

## Agreed order

1. Record the feedback in this document.
2. Correct stale catalog references and validate the catalog before matrix
   generation. Keep the existing group names, cases and fixture boundaries.
3. Check affected unit tests and planner tests. Run one small integration case
   in each failed variant, `gtid-full` and `position-minimal`.
4. Commit the fixes separately, push the branch, and start a new full CI run.
   Fix any remaining failures before test reorganization. Read failure bundles
   before retrying affected cases.
5. Save a passing run's results, coverage, SQL and timings as the comparison
   baseline. Then implement the feedback below in small changes. The baseline
   and first assertion map are now saved under `artifacts/ci-review/40454033524/`.

## Acceptance after the full CI run passes

- Names identify the MySQL feature or tested operation. Consult MySQL documentation
  when choosing feature names. Avoid unexplained project terms and numbered
  names such as `dml-1`. Failure messages identify the operation, table and
  expected versus observed result.
- Metadata discovery is a small group. It checks metadata reads, cache reuse and
  invalidation, with a few row writes to verify the result. It does not repeat
  the DML matrix. Representative metadata definitions belong in this same group,
  across the supported profiles, not in many repeated DML groups.
- Group balance uses setup time, test-body time and required assertions. Merge
  compatible small selections into one fixture. Reduce redundant work in large
  groups before adding more jobs. One parent case can contain many operations.
- Every removed check has an identified replacement or a recorded reason.
  Compare SQL, assertions, applicability and line coverage. Preserve profiles,
  variants and transport checks. Update all catalog and migration references.
- Select the final short PR suite only after the full suite is organized and
  its measurements are complete.

## Evidence from run 40434437616


Run: https://github.com/GannettDigital/mysql-replicator/actions/runs/40434437616
Commit: `4bb6351`.

The run passed 161 integration groups and failed 26. All failures were in the
forward `gtid-full` and `position-minimal` correctness variants. The other three
profiles passed their complete catalog selections. Coverage was collected for
160 of 186 expected apply groups; native-only observations do not produce it.
This is incomplete evidence for coverage-based removal of tests.

### Catalog failure

The unit log reports 949 tests, 24 failed assertions and 15 failed test methods.
Every reported unit error refers to the retired `matrix-composite` case.
The support catalog had not been updated after migration to
`ddl-compat-primary-key-row-matching`. After that reference was corrected, the
catalog check also found missing classifications for that case and
`ddl-compat-key-conflicts`.

The linked job `121962268143` selected 18 cases. Its saved result records the
same catalog error during fixture setup, before the first case started. Its
SQL trace contains setup calls only. No applier failure bundle was created:
the applier had not entered BLOCKED. This job is not a one-case selection.
Both failing variants load this catalog before their selected cases execute.

Local fixes update the three catalog entries and run `ddl-catalog check` before
CI matrix generation. All 27 affected catalog unit tests pass. The 92 focused
CI/selector tests pass. The focused database checks are recorded below.

### Local validation after the fixes

- `ddl-catalog check` passes: 63 scenarios, 244 registered cases and 56 support
  requirements.
- The full generated plan matches the previous plan: 187 groups, 2,039 scenario
  obligations and 186 coverage collections. Names and selections are unchanged.
- The `positive` case passes for `mysql84-to-mysql57-myisam` with both
  `gtid-full` and `position-minimal`. Each checks INSERT, UPDATE and DELETE,
  compares rows, binlogs and SQLite checkpoints, and restarts from saved state.
- Both local cases collected coverage. The second reused the first image with
  `--skip-build`. No full integration suite was run locally.

Local results:

- `artifacts/lab/20261027T042733Z-6bb81a6d/result.json` (`gtid-full`).
- `artifacts/lab/20261027T045025Z-87fd74e1/result.json` (`position-minimal`).

The first check required a local coverage-image rebuild. Rust, Swift dependencies
and MySQLSyntax used cached layers. The application stage built all Swift test
executables as well as the applier. It used release optimization, coverage and
indexing, with two build jobs. The image targets x86_64, but this Mac is arm64.
Swift compilation took 1,229 seconds; the first test case took 13 seconds,
excluding fixture setup and coverage collection. Keep this build cost separate
from test execution when comparing group times. Consider a smaller local
integration build separately from this CI failure fix.

### Follow-up: files required by the shared test image

Run `40452455015` passed the stale-catalog checks but failed one Swift assertion:
`SupportCatalogTests.testRequirementsReferenceExistingImplementationFiles`.
The shared CI image did not contain `PLAN/JSON_TRANSPORT_INVESTIGATION.md`, which
the support catalog references. The host checkout contains it, so local host
tests did not detect the omission. The run was cancelled before another retry.

The CI image now copies that document after compilation. An image preparation
check verifies all support-catalog file references before the image is published.
The exact assertion failed in the cached Linux build without the document.
With the document present, all four `SupportCatalogTests` passed in the same
prebuilt Linux test binary. No Swift compilation was needed for this check.

The syntax-coverage upload error was secondary. The unit-test script stopped at
the Swift failure before it could run the isolated syntax tests.

### Group size and names

There are genuine small selections as well as the early failures. With source
GTIDs disabled, SQL testing is split between one row-application group and one
generated-column group per profile. These should share one fixture after a
focused check of their combined order. Benchmarks, native observations and
recovery workflows can report one parent case with many operations; case count
alone is not a useful cost measure.

For the default 5.7-to-5.7 InnoDB profile, the existing-table group has 46 cases.
Its measured fixture work was 1,241 seconds, including 15 seconds of setup and
1,125 seconds of test execution. The table/column/index group had 30 cases and
took 1,216 seconds, including 12 seconds of setup and 1,108 seconds of execution.
Repeated container startup is not the main cost in these two groups.

Group and case renaming is deferred until the full CI run passes. A label-only
change does not justify the existing large selection. Do not use "bootstrap"
as the name of a feature or as the only description of a failed operation.

### User correction: test metadata behavior, not a second DML matrix

In this runner, "bootstrap" means that CREATE TABLE is outside the captured
binlog range. It is not MySQL server bootstrap. After the applier reads the table
metadata, row application uses the same path as the normal DML cases.

The baseline `bootstrapDML()` runner repeats every fixture phase with a new
applier state. Thus it repeatedly reads table metadata before INSERT, UPDATE and
DELETE. A separate run is useful only if it checks a distinct metadata behavior.
Repeating all value and statement tests is not justified by cache initialization.
Do not merely split these 46 cases into more CI jobs.

Revise the selection around **table metadata discovery and cache invalidation**:

1. Map each existing-table assertion to the metadata fields it checks. Retain
   field coverage for signedness, precision, charset/collation, ENUM/SET labels,
   generated columns and row identity. Identify source-version differences in
   TABLE_MAP metadata. Put pure parsing and validation combinations in unit tests
   where possible; use MySQL integration only for real metadata reads and writes.
2. Add one shared-fixture workflow: read metadata for an existing table, apply a
   row, reuse cached metadata for later rows, apply ALTER TABLE, and check that
   following DML uses the changed schema. Check query counts or named metadata
   observations; final row equality alone does not prove cache reuse.
3. Retain rename/drop and restart checks where not already tested by the DDL and
   resume workflows. Do not add copies of those sequences solely to this group.
   Existing cache unit tests already check reuse and table/database invalidation.
4. Use descriptive assertions such as `read-column-metadata`,
   `reuse-cached-table-metadata` and `refresh-metadata-after-alter`.
   Messages must name the operation, table, expected metadata and observed value.
   A numbered phase may remain an internal artifact ID, but must not be the only
   description in logs. Do not use "bootstrap failed".
5. Compare retained assertions, SQL and line coverage before retiring repeated
   cases. Update support references, catalog classifications, migration records,
   feature ownership and docs in the same change. The newly added catalog check
   must pass before any database run.

Do this reduction before deciding whether the two longest groups need to be
split. Merge compatible small selections without adding a second fixture setup.
Keep benchmarks separate to avoid contamination from preceding test workloads.
Do not select the final short PR suite from this incomplete CI run.

## Metadata slice implemented

The replacement cases, DML-owner checks and selection updates are implemented.
See [the metadata review](BETA7_METADATA_GROUP_REVIEW.md#implementation-of-this-slice).
Focused local checks passed on both target engines. Continue the remaining
reviews with the saved passing run. A new full CI run is not a prerequisite.
Group balancing and short PR selection remain later steps in this plan.

## Continue with saved measurements

Use run `40454033524` at `efb3458` for groups whose case bodies, selected cases,
settings and fixture order have not changed. It contains passing results, SQL
cost records, per-case times and exact runtime line sets. Check those inputs
against the current source before carrying a group's evidence forward.

The former `bootstrap-schema-discovery` group is the exception. Its replacement
has local assertion results, but no new full-matrix timing or coverage result.
Do not assign the old group's time or line set to the replacement. When checking
whether another group supplies a removed assertion or line, exclude the old
bootstrap executions. Keep any dependency on the new metadata coverage pending.
Coverage is measured per group, not per case. Use source SQL and named assertions
to decide whether individual cases repeat the same checks.

Proceed in this order without another push or full run between reviews:

1. Review `table-column-index-changes` against the related type/value and key
   cases. Map each proposed removal to retained SQL and assertions. Inspect
   whole-group line overlap within the same profile and variant. Reduce repeated
   work before splitting this large group.
2. Review the small `without-source-gtids` SQL selections for one shared fixture.
   Keep `positive`, `ddl-compat-generated` and the applicable tagged-GTID case.
   Their assertions differ; this is a setup-sharing change, not case removal.
3. Continue group balancing from the saved times. Mark changed groups as needing
   new measurement. Do not treat estimates as measured savings.
4. After a useful batch of changes, push and run one full instrumented CI suite.
   Check changed groups and full-suite behavior, including the metadata group.
   Then select the short PR suite from the reviewed cases and measured times.

Initial evidence from the saved run:

| Candidate | Observed cost | Review target |
|---|---|---|
| Forward default `table-column-index-changes` | 1,200.3 lab seconds; 5,647 harness SQL calls. | Repeated column, index and key setup/assertions. The slowest case bodies include ALTER column keys (82.8 s), generated-column dependencies (80.1 s) and column/index syntax (67.7 s). |
| Three 5.7-source `without-source-gtids` SQL selections | `positive` takes 8.3–9.3 s; generated columns take 15.9–19.5 s. Each currently has a separate fixture. | Combine their order while retaining both case results. |
| Forward `without-source-gtids` SQL selections | Tagged GTIDs plus `positive` take 42.5 s; generated columns take 19.9 s in another fixture. | Keep the source-specific tagged-GTID check in the combined selection. |

Lab seconds include setup, test work, cleanup and coverage export. Case-body
seconds exclude those surrounding phases. Harness SQL calls are not applier
statement counts. These figures identify review candidates; they do not prove
that assertions are redundant or predict the final elapsed time.

Validation for the next review: no build, containers or test execution. Read the
saved artifacts and current case source, then record an assertion map and a
proposed combined order. Before implementation, select the focused checks under
the [per-step validation scope](BETA7_TEST_SUITE_CONSOLIDATION.md#validation-scope-for-each-step).
No new full run is needed to complete that review.


## Table/column/index review complete

See [the detailed review](BETA7_TABLE_COLUMN_INDEX_REVIEW.md). The group has
substantial distinct coverage after the old metadata group is excluded.
Do not remove its ALTER behavior or merge it wholesale with type/value tests.
The first implementation slice combines the ten MODIFY cases as
`ddl-modify-columns`. It preserves per-ALTER assertions and shares setup, state
export and binlog file reads. The review records its one-profile local validation
results and the original case-to-assertion map. No new full CI run is needed
between these slices. The follow-up review confirms that per-step observation
and control calls dominate the combined MODIFY run. Next: pilot source execution
phases with batched result queries and explicit observation boundaries. Use one
running applier for ordinary correctness cases. Keep named restart/replay checks.
See the detailed review for measured call costs and the one-profile pilot scope.
Database-case ownership and the remaining restart boundaries follow that pilot.


The MODIFY phase pilot now passes all 56 assertions in 21.6 local case seconds,
with 63 SQL client calls instead of 918. It keeps one running writer across setup,
ALTER and DML phases and one explicit saved-state restart. Shared correctness
failures now request a support bundle and print its path. The detailed review
records timing, coverage differences and the passing deliberate failure check.
The bundle contains a valid stopped-state SQLite snapshot and the original
assertion failure. Apply this model in the order in the revised execution plan
above. Retain explicit lifecycle assertions and profile-specific session behavior.


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
[ENUM/SET workflows](BETA7_ENUM_SET_WORKFLOW_REVIEW.md#ordinal-zero-implementation-and-focused-results)
passed choices/widechoices with 12 assertions each, binarychoices with 14,
exactchoices with 16 and enumzero with 14 on forward MyISAM.
Next: convert only matrix-choiceboundaries with fixed multibyte label/default
maps. Keep all seven IDs and their metadata/version rules.
Keep remaining type/value and key/index work, full-matrix validation, final
balancing and short PR selection later.

### Follow-up: support reports before applier setup

The first widechoices attempt failed while creating the target container because
OrbStack lacked an image-layer parent snapshot. No test SQL or applier state
existed. The harness kept harness-failure.json and fixture-lifecycle.json, but
its support-bundle invocation failed because stateDirectory was not configured.
The repaired-image retry passed. See the [attempt records](BETA7_ENUM_SET_WORKFLOW_REVIEW.md#binary-enum-and-set-implementation-and-focused-results).

Future work: collect setup logs, fixture configuration and lifecycle results when
state is unavailable. Avoid a state-dependent bundle command until its required
configuration exists. Test this with a focused pre-applier setup failure; a full
SQL correctness run is not required for that diagnostics change.
