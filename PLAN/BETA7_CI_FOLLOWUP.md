# Beta.7 CI fixes and test-suite feedback

Status: failure fixes are prepared locally. Naming and test reorganization wait
for a passing full CI run. No test has been removed by this plan.

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
   baseline. Then implement the feedback below in small changes.

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

The current `bootstrapDML()` runner repeats every fixture phase with a new
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
