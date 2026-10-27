# Smaller table metadata test group

Status: focused replacement implemented; focused local checks passed.
The passing baseline below describes the old suite. Full CI comparison is pending.
Keep a small group for metadata reads, cache reuse and DDL invalidation.
Ordinary DML assertions belong in the related feature groups.

## Passing baseline

[Run 40454033524](https://github.com/GannettDigital/mysql-replicator/actions/runs/40454033524)
passed at `efb345845e752b2bb218b8fd4a54fc694bebffd5`.
All 2,039 selected catalog obligations passed. All 186 expected integration
coverage collections are present. There were 187 execution groups.

The ten `bootstrap-schema-discovery` executions total 200.0 runner-minutes,
excluding job setup. This is instrumented test time, not production throughput.

| Profile | Variant | Cases | Lab seconds | Harness SQL calls |
|---|---|---:|---:|---:|
| `mysql57-to-mysql57-innodb` | `default` | 46 | 1195.7 | 2653 |
| `mysql57-to-mysql57-innodb` | `lowercase-tables` | 46 | 1153.0 | 2653 |
| `mysql57-to-mysql57-myisam` | `default` | 46 | 1242.3 | 2660 |
| `mysql57-to-mysql57-myisam` | `lowercase-tables` | 46 | 1239.8 | 2660 |
| `mysql57-to-mysql84-innodb` | `default` | 45 | 1311.1 | 2571 |
| `mysql57-to-mysql84-innodb` | `lowercase-tables` | 45 | 1238.0 | 2571 |
| `mysql84-to-mysql57-myisam` | `default` | 42 | 1144.8 | 2479 |
| `mysql84-to-mysql57-myisam` | `gtid-full` | 42 | 1154.2 | 2485 |
| `mysql84-to-mysql57-myisam` | `lowercase-tables` | 42 | 1159.9 | 2479 |
| `mysql84-to-mysql57-myisam` | `position-minimal` | 42 | 1161.8 | 2485 |

## DML assertion map

There are 47 unique `bootstrap-matrix-*` fixtures and four separate target-only
workflows. Each profile selects the applicable subset.

- 39 matrix fixtures share their SQL phases and checks with an existing
  `matrix-*` case through `DMLCompatibilityCases`.
- Eight fixtures have named DDL replacements. These retain the source statements
  and the original predicates or stronger exact-row checks. `LabProfileTests`
  checks these migrations.
- All 434 applicable profile/variant selections have an applicable DML owner
  outside this group. There are no missing selection scopes.
- The 47 fixtures define 158 phases, repeated 1,448 times across the selection.
  The existing-table runner starts a fresh applier state for each phase that
  emits transactions. These are repeated cold reads, not cache-reuse checks.

No ordinary source-DML assertion gap was found in these 47 fixtures. The new
metadata assertions replace their cold reads. See the implementation section.

`SharedCorrectness.dml()` executes the phase predicate on source, native and
target and compares schema and row snapshots. The former `SharedBootstrapDML.bootstrapDML()`
uses the same predicate and row comparison after creating tables without
binlogging. Both verify partial-JSON event emission. The LOAD DATA output path
changes only to avoid an existing output file.

| Existing suffix (`bootstrap-matrix-`) | Phases | DML owner outside the group | Current group |
|---|---:|---|---|
| `binarychoices` | 3 | `matrix-binarychoices` | `character-sets-collations` |
| `binarydefaults` | 3 | `matrix-binarydefaults` | `data-types-values` |
| `bits` | 4 | `matrix-bits` | `data-types-values` |
| `choiceboundaries` | 3 | `matrix-choiceboundaries` | `character-sets-collations` |
| `choices` | 3 | `matrix-choices` | `character-sets-collations` |
| `collations` | 4 | `matrix-collations` | `character-sets-collations` |
| `composite` | 4 | `ddl-compat-primary-key-row-matching` | `keys-rows-gtids` |
| `decimal` | 3 | `matrix-decimal` | `data-types-values` |
| `decimaldefaults` | 3 | `matrix-decimaldefaults` | `data-types-values` |
| `defaults` | 3 | `matrix-defaults` | `data-types-values` |
| `encodings` | 4 | `matrix-encodings` | `character-sets-collations` |
| `enumzero` | 4 | `matrix-enumzero` | `character-sets-collations` |
| `exactchoices` | 4 | `matrix-exactchoices` | `character-sets-collations` |
| `fixed` | 3 | `matrix-fixed` | `data-types-values` |
| `fixedfloating` | 4 | `matrix-fixedfloating` | `data-types-values` |
| `floatbounds` | 3 | `matrix-floatbounds` | `data-types-values` |
| `floating` | 5 | `matrix-floating` | `data-types-values` |
| `floatingautodouble` | 4 | `matrix-floatingautodouble` | `data-types-values` |
| `floatingautofixedfloat` | 4 | `matrix-floatingautofixedfloat` | `data-types-values` |
| `floatingautofloat` | 4 | `matrix-floatingautofloat` | `data-types-values` |
| `floatingautounsigneddouble` | 4 | `matrix-floatingautounsigneddouble` | `data-types-values` |
| `fulltext` | 3 | `ddl-compat-fulltext` | `table-column-index-changes` |
| `generated` | 3 | `ddl-compat-generated` | `table-column-index-changes` |
| `identifiercase` | 4 | `matrix-identifiercase` | `character-sets-collations` |
| `ignore` | 3 | `ddl-compat-key-conflicts` | `keys-rows-gtids` |
| `integers` | 3 | `matrix-integers` | `data-types-values` |
| `json` | 4 | `matrix-json` | `data-types-values` |
| `jsonpartial` | 4 | `matrix-jsonpartial` | `data-types-values` |
| `legacybinaryset` | 2 | `matrix-legacybinaryset` | `character-sets-collations` |
| `load` | 1 | `matrix-load` | `keys-rows-gtids` |
| `lob` | 3 | `matrix-lob` | `data-types-values` |
| `nativeencodings` | 4 | `matrix-nativeencodings` | `character-sets-collations` |
| `precision` | 2 | `matrix-precision` | `data-types-values` |
| `replace` | 2 | `ddl-compat-key-conflicts` | `keys-rows-gtids` |
| `select` | 3 | `matrix-select` | `keys-rows-gtids` |
| `spatial` | 4 | `matrix-spatial` | `data-types-values` |
| `temporal` | 3 | `matrix-temporal` | `data-types-values` |
| `textdefaults` | 3 | `matrix-textdefaults` | `data-types-values` |
| `textkey` | 3 | `ddl-compat-primary-key-row-matching` | `keys-rows-gtids` |
| `typedjson` | 4 | `matrix-typedjson` | `data-types-values` |
| `unicodeidentifiers` | 4 | `matrix-unicodeidentifiers` | `character-sets-collations` |
| `upsert` | 3 | `ddl-compat-key-conflicts` | `keys-rows-gtids` |
| `values` | 3 | `ddl-compat-constraints` | `keys-rows-gtids` |
| `widechoices` | 3 | `matrix-widechoices` | `character-sets-collations` |
| `widestrings` | 3 | `matrix-widestrings` | `character-sets-collations` |
| `zerofill` | 4 | `matrix-zerofill` | `data-types-values` |
| `zerowidth` | 4 | `matrix-zerowidth` | `character-sets-collations` |

## Keep the four target-only workflows

Three workflows use 8.4 target schema features that the 5.7 source cannot create.
The fourth tests a target-specific ALTER restriction on a foreign-key parent.
Do not remove them as repeated ordinary DML. They need to remain in the smaller
metadata group or move intact to the corresponding feature group after a
fixture review.

| Case | Assertions that must remain | Feature |
|---|---|---|
| `json-target84-schema` | Read JSON expression defaults and functional indexes; preserve them through writes, ALTER and restart; query the index and execute the default. | JSON defaults and functional indexes |
| `target84-index-spatial-metadata` | Preserve invisible indexes and SRID constraints through DML, ALTER, restart and replay; check saved metadata. | Index and spatial metadata |
| `expression-target84-dependencies` | Refuse unsafe column changes; apply supported compound ALTER; preserve expressions, defaults and row effects through restart and replay. | Expression dependencies during ALTER TABLE |
| `alter-rename-target84-refusal` | Refuse the target-specific parent rename defect before SQL; keep rows, table name and checkpoint unchanged. | Foreign-key parent ALTER restrictions |

## Coverage of the whole group

This comparison unions all ten discovery executions before subtracting the
other integration groups. It does not use each job's zero-exclusive-line count.
That count can hide lines also reached by another discovery job.

| Profile | Lines reached by discovery group | Lines absent from other integration groups |
|---|---:|---:|
| `all` | 11981 | 60 |
| `mysql57-to-mysql57-innodb` | 9525 | 0 |
| `mysql57-to-mysql57-myisam` | 9526 | 0 |
| `mysql57-to-mysql84-innodb` | 11510 | 60 |
| `mysql84-to-mysql57-myisam` | 9584 | 0 |

The 60 lines occur only in the 5.7-to-8.4 profile. Source inspection associates
them with target-only expressions, functional indexes and SRID metadata:

| File | Lines exclusive to this group | Behavior |
|---|---:|---|
| `SQLExpressionParser.swift` | 27 | CAST width/charset and COLLATE expressions |
| `ColumnExpressionDependencies.swift` | 14 | Functional-index and expression-default dependency checks |
| `Configuration.swift` | 9 | Saved expression-default and functional-index validation |
| `DDLExpressionMetadata.swift` | 4 | Target-version check for functional indexes |
| `TargetSession.swift` | 6 | Read SRID, expression defaults and functional-index expressions |

This attribution follows source inspection, not per-case coverage. Keep the four
workflows and verify the same lines after the change. Zero lost lines is not
proof of equivalent assertions. Rust and lab code are outside this measure.
The report's separate PR-baseline comparison is unavailable; `unmeasured` is
not zero and is not used here.

## Replacement design

Name the group `table-metadata-discovery`. Use MySQL terms for fields:
[INFORMATION_SCHEMA COLUMNS](https://dev.mysql.com/doc/refman/8.4/en/information-schema-columns-table.html)
and [INFORMATION_SCHEMA STATISTICS](https://dev.mysql.com/doc/mysql-infoschema-excerpt/5.7/en/information-schema-statistics-table.html).
The cache under test is the replicator's metadata cache, not MySQL's cache.

Use a small set of representative tables and row writes in one shared fixture:

1. **Column and index reads.** Check unsigned types, numeric/temporal precision,
   NULL/default values, character sets/collations, generated columns and key
   parts. Include a composite key and a text key. Check saved metadata directly.
2. **Encoded labels and defaults.** Keep representative ENUM/SET ordinals,
   escaped/non-UTF-8 labels, and binary/text defaults. Preserve source-version
   TABLE_MAP differences. Keep value-range DML with its existing owner.
3. **Cache reuse and invalidation.** Keep one applier running. Apply an initial
   row to an existing table, then another row. Assert that schema-read counters
   do not increase for the second write. Apply ALTER TABLE, check changed
   metadata and following DML, and verify the required read after invalidation.
   Keep rename/drop and saved-state restart checks once where not already tested.

Do not create one replacement case per old fixture. Map metadata fields to the
three responsibilities above and combine definitions where possible. A distinct
read branch can justify another table; another value or DML spelling does not.

`DryRunTests` checks cache retention and table/database invalidation.
`DiscoveryReadsTests` checks query reuse and failure cleanup. Integration still
must prove that a real DDL operation invalidates the cache. `schema-cache` in
`SharedMyISAMRecovery` tests reuse after idle lock release, but does not cover
InnoDB. Apply the replacement workflow to both engines and both source versions.

## Execution order

Use the [per-step validation scope](BETA7_TEST_SUITE_CONSOLIDATION.md#validation-scope-for-each-step).
Local verification for this slice is complete; the list below records the work
order and does not require another local run.

1. Add the focused metadata assertions and check them locally. Retain the four
   target-only workflows. No new full local suite is needed.
2. Map every retired metadata condition to an explicit replacement assertion.
   Keep the DML owner map as a separate obligation; it cannot stand in for cold
   discovery. Update migrations, support references, names, selectors and docs.
3. Remove the repeated existing-table DML phases. Check the changed sequence on
   the representative profile selected in the validation scope. Cases share one
   fixture. Leave the remaining profile/variant combinations to CI.
4. Compare full CI line sets, SQL and setup/test/coverage times with this run.
   Inspect any lost lines and retain every required assertion.
5. Balance the remaining groups. Select the short PR suite last.

Evidence is under `artifacts/ci-review/40454033524/`: `measurements/`, `jobs/`,
`correctness-catalog.json`, `metadata-dml-map.json` and
`metadata-family-coverage.json`. The assertion map records the 434 scope matches.
The whole-group line comparison uses all 187 job records and 186 coverage sets
from the same commit. The JSON retains exact file/line locations.

## Implementation of this slice

The group is now `table-metadata-discovery`; its selectable family is `metadata`.
The three new cases are `metadata-columns-indexes`, `metadata-labels-defaults`
and `metadata-cache-ddl`. The four target-only workflows are unchanged.

This first slice keeps 39 distinct existing-table definitions across all
profiles. It combines eight duplicate metadata conditions with representatives.
Each cold-read case uses one applier session for all applicable definitions.
Only the initial INSERT remains. No repeated UPDATE, DELETE or ALTER value
phases remain in this group. The original DML owners retain those phases.
This is a conservative reduction of process starts and repeated value checks;
further combination of column definitions is not part of this slice.

The column assertions compare saved types, precision, nullability, character
sets, collations, key order, index parts, AUTO_INCREMENT and generated expressions
with INFORMATION_SCHEMA. Additional assertions check exact encoded label bytes,
label order, ENUM default ordinals, binary defaults and text defaults.
Each case checks one cold schema read per table and the saved checkpoint.
The cache case compares query counters between writes and across DDL.
It uses INFO schema-read records and general query log statement counts while
the process runs. Running progress reports omit stage timings; final reports
provide the counters for the cold-read cases. It checks
recreation of the same table name with a different column type, then resumes
from saved state. The first write after ALTER can validate a new DML plan.
The following write must reuse both that plan and the refreshed schema.

| Retired metadata suffix | Representative cold-read assertion | Reason |
|---|---|---|
| `ignore`, `replace`, `values`, `select`, `load` | `metadata-upsert` | Integer primary key and non-NULL integer value; includes the unique key used by conflict cases. DML syntax does not change discovery. |
| `jsonpartial` | `metadata-json` | Same `id INT PRIMARY KEY, doc JSON` definition. Partial-event assertions stay in `matrix-jsonpartial`. |
| `typedjson` | `metadata-json`, plus existing BIT, temporal, LOB and fixed-binary definitions in the same group | JSON value tags do not change column metadata. Typed JSON values stay in `matrix-typedjson`. |
| `enumzero` | `metadata-exactchoices` and `metadata-choices` | ENUM labels, primary key and empty label. Ordinal-zero row behavior stays in `matrix-enumzero`. |
| All other suffixes | `metadata-<suffix>` | Retain the distinct definition and its initial row/default predicate. |

`tools/test_case_migrations.json` records all 47 retirements and their 434
original profile/variant selections. `retained_cases` requires the DML owner
and cache case to remain applicable and planned in every original scope.
The complete plan contains 1,635 case selections, down from 2,039. It still has
187 jobs and 186 integration coverage collections. This change reduces work
inside the metadata jobs; group balance is a later step.

Local preflight checks pass: 37 focused Swift tests, 56 lab-tool tests and
122 CI-tool tests. The full plan passes migration, feature-owner, fixture-count
and growth checks. The DDL support catalog passes. Integration results are
recorded below.

## Local integration checks

The two cold-read cases passed on all four default profiles. Evidence:
`artifacts/lab/20261027T174114Z-62734dd8/`. That run also contains an earlier
cache-case assertion failure; do not treat the whole run as passing.
The cache case is checked separately after its assertion fixes.

| Profile | Column/index case seconds | Label/default case seconds |
|---|---:|---:|
| `mysql84-to-mysql57-myisam` | 51.0 | 29.0 |
| `mysql57-to-mysql84-innodb` | 63.8 | 36.6 |
| `mysql57-to-mysql57-myisam` | 66.1 | 36.5 |
| `mysql57-to-mysql57-innodb` | 67.2 | 37.1 |

These are local case times with coverage under amd64 emulation. They exclude
fixture setup and coverage export. Do not compare them directly with GHA times.
The next full CI run must compare the exact line sets, assertion results, SQL
and timing against run `40454033524`.

The cache case passed on `mysql84-to-mysql57-myisam` and
`mysql57-to-mysql84-innodb` in `artifacts/lab/20261027T184754Z-20046577/`.
Both runs passed all five assertions, including table recreation and saved-state
resume. The case took 26.8 and 29.1 seconds respectively.

| Profile | Queries after first INSERT | After second INSERT | After ALTER | After first UPDATE | After second UPDATE |
|---|---:|---:|---:|---:|---:|
| `mysql84-to-mysql57-myisam` | 11 | 11 | 30 | 36 | 36 |
| `mysql57-to-mysql84-innodb` | 10 | 10 | 33 | 41 | 41 |

These are cumulative INFORMATION_SCHEMA query counts for the applier account.
Each profile had one schema read across the two INSERTs, then three cumulative
reads after ALTER. Both following UPDATEs kept that schema-read count unchanged.
The first UPDATE validated the new DML plan; the second made no metadata queries.

At the user's request, the remaining local profile expansion was stopped.
The 5.7-to-5.7 MyISAM case completed before the stop, but the overall run and its
coverage collection were interrupted. Do not report that run as fully passing.
The extra file-position/MINIMAL run was not repeated after a fixture setup
failure. The two completed cache runs cover both target engines. Leave remaining
profile/variant and full coverage comparisons to GHA.

No application code changed. The test catalog, migration checks, selectors and
docs now use the focused metadata cases. This completes the implementation slice;
it does not complete the overall suite reorganization.
