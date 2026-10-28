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

Next, review generated expressions and simultaneous column renames. See the
[next slice and validation scope](BETA7_TABLE_COLUMN_INDEX_REVIEW.md#next-slice-generated-expressions-and-simultaneous-column-renames).
Continue through other feature groups before full CI and final PR selection.

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
