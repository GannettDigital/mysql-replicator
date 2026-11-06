# Identifier case sensitivity and Unicode columns: DML workflow review

Status: both identifier workflows passed their focused forward tests.
The ASCII pilot is committed as `e4d54e9`; Unicode is committed as `2729752`.
Both [inventory workflows](BETA7_NATIVE_ENCODING_INVENTORY_REVIEW.md#native-encoding-implementation-and-focused-results)
passed their focused forward cases. The [ENUM/SET workflows](BETA7_ENUM_SET_WORKFLOW_REVIEW.md#legacy-binary-set-implementation-and-local-completion)
passed choices/widechoices with 12 assertions each, binarychoices with 14,
exactchoices with 16, enumzero with 14 and choiceboundaries with 13.
Legacybinaryset passed 12 on the 5.7 MyISAM profile.
The [character and binary value review](BETA7_CHARACTER_BINARY_VALUE_WORKFLOW_REVIEW.md#implementation-results)
records all three conversions: 101 unit tests and 48 forward assertions passed.
The [data-type review](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md) keeps all 25 IDs.
The [type/value workflow results](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md#partial-json-event-checks-in-the-shared-workflow)
record twenty-three completed conversions. All focused checks passed.
JSON and spatial cases share the data-types-values fixture.
Partial JSON now keeps bounded event proofs.
The [index workflow results](BETA7_KEY_INDEX_WORKFLOW_REVIEW.md#implementation-and-focused-results)
record all 12 conversions. All 57 original assertions and the shared restart
passed on forward MyISAM. Eleven focused unit tests passed.
The [primary-key and constraint results](BETA7_PRIMARY_KEY_CONSTRAINT_WORKFLOW_REVIEW.md#implementation-and-focused-results)
record both conversions. All 23 operation states and 15 original named assertions
passed on forward MyISAM. Fourteen focused unit tests passed.
Next: review conflict statements and their no-op GTID/offset boundaries.

## Decision and scope

Keep both case IDs and their existing group/profile/variant selections. Neither
case replaces the table-name tests. Their column and index conditions differ.
Do not set replicatedReplacement or remove their original fixture definitions.
Metadata discovery still uses those definitions and the first INSERT/check.

Add a small opt-in DML workflow. Create the original and retained schemas in a
preparation batch. Execute original phase scripts first in a body batch, followed
by the retained histories. Compare results at the end, then clean up only the
retained tables. Keep one running applier and one fixture. Cases which do not
opt in must keep their existing execution path.

The initial review used saved CI measurements and source inspection. It did not
run builds or tests. The implementation results below confirm the pilot's row
values and counters. The Unicode follow-up results are recorded below.

## MySQL feature names

Consult MySQL documentation when naming features. Use
[Identifier Case Sensitivity](https://dev.mysql.com/doc/refman/8.4/en/identifier-case-sensitivity.html),
[Schema Object Names](https://dev.mysql.com/doc/refman/8.4/en/identifiers.html)
and [Identifier Length Limits](https://dev.mysql.com/doc/refman/8.4/en/identifier-length.html).
Use these reader-facing titles in both test selection output and execution logs:

- matrix-identifiercase: **Identifier case sensitivity: column, PRIMARY KEY and index references**.
- matrix-unicodeidentifiers: **Schema object names: Unicode columns, indexes and quoted identifiers**.

Keep IDs unchanged. Share each title between inventory and execution; do not
create separate descriptions which can disagree. Changing a description does
not justify a new case, job or group.

## Saved measurements and source audit

The identifierCase definition and phases still match CI commit `efb3458`.
The unicodeIdentifiers portion of UnicodeIdentifierCases.swift also matches;
its separate DDL table-name case has already changed and is outside this slice.
CI run `40454033524` has complete measurements and coverage, with no failed or
missing shards. It contains ten passing executions per case: four default,
four lowercase-tables and two forward positioning/metadata variants.

Default/SQL case measurements:

| Case | Forward 8.4→5.7 seconds / calls | Reverse 5.7→8.4 seconds / calls | 5.7→5.7 MyISAM seconds / calls | 5.7→5.7 InnoDB seconds / calls |
|---|---:|---:|---:|---:|
| matrix-identifiercase | 16.61 / 148 | 11.95 / 147 | 17.19 / 162 | 14.11 / 162 |
| matrix-unicodeidentifiers | 16.44 / 148 | 12.09 / 147 | 17.41 / 162 | 13.82 / 162 |

Calls are harness mysql client calls. The saved runs selected the whole area.
Earlier matrix tables accumulate in poc, and each comparison reads that database.
A local single-case pilot has different comparison inputs. Report its calls and
time, but do not attribute every difference to batching alone. Later full CI
measures the changed group with its complete selection.

Coverage belongs to the larger character-set group, not individual cases. Overlapping lines do not show that
ASCII case matching replaces Unicode identity or quoting. Keep the comparison
limits in the [character-set review](BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#coverage-comparison-scope).

Evidence:

- `artifacts/dml-identifier-workflow-review/baseline.json`: 20 saved executions.
- `artifacts/dml-identifier-workflow-review/source-review.json`: exact definitions,
  original scripts/checks, retained histories, batches and transaction counts.
- `artifacts/dml-identifier-workflow-review/review.py`: unchanged-source audit.

## Original execution and transaction boundaries

SharedCorrectness.Run.dml keeps the main applier running across both cases and
all their phases. Each case creates its table, then executes four phase scripts.
Each script gets a fresh mysql client, USE poc, a wait, its boolean predicate
on all three roles and a full comparison of poc. Do not describe this as an
applier restart after each phase.

Both cases have these source transaction counts:

| Operation | Source transactions |
|---|---:|
| Original CREATE TABLE | 1 |
| Phase 1: INSERT two rows | 1 |
| Phase 2: one ALTER and one UPDATE | 2 |
| Phase 3: CHANGE, RENAME INDEX and UPDATE | 3 |
| Phase 4: one combined ALTER and DELETE | 2 |
| Original case total | 9 |

Unicode phase 2 puts UPDATE before ALTER; the ASCII case puts ALTER before
UPDATE. Preserve that order. These scripts use autocommit and implicit DDL
commits. They are not four explicit transactions. Do not add BEGIN/COMMIT or
split/reorder an original script for easier counting. Declare phase counts
1/2/3/2; do not infer production transaction boundaries with semicolon parsing.

## Opt-in helper and source batches

Use a nullable workflow plan on DMLCompatibilityCases.Case, or an equivalent
small opt-in interface. It should describe retained table names, the original
phase prefixes, explicit transaction counts, final observations and the title.
Reuse LabSQLPhase and the existing read-only comparison helpers. Keep DDL callers
unchanged. If final-query validation is separated from DDL phase validation,
retain the old DDL checks and test both entry points.

Do not route these cases through the DDL loop, which recreates ddlcompat. Keep
poc creation, native engine setup, profile filters and row-metadata selection
where the current DML runner applies them. Neither case has setup SQL, a JSON
diff assertion or a metadata override. Validate the pilot's prerequisites rather
than silently dropping such behavior in a future opt-in case.

Per case, execute:

1. **prepare:** four original-definition CREATE TABLE requests: the original
   table and three retained tables. Use the exact original definition and
   DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin for each.
2. **body:** the four original phase scripts first, unchanged, then prefixes
   of one, two and three original phases on the retained tables. Keep USE poc
   and the original multi-statement script in every request.
3. **final observations:** four old predicates plus fixed full-row and metadata
   checks. Compare poc once across source, native and target.
4. **cleanup:** one DROP TABLE request listing only the three retained tables.

Preparation adds independent tables before the original phase scripts. The
original table is created first, and its four scripts retain their exact order.
This is an intentional change from a contiguous original history. Extra tables
have independent data and per-table index names. Do not claim that all original
operations remain contiguous. This layout also keeps CREATE requests in a
client with no selected database. Every body request has its original USE poc,
so no selected-database override leaks between the two kinds of request.

Retarget only the controlled fixture reference poc.matrix_identifiercase or
poc.matrix_unicodeidentifiers. Preserve all column/index names, quoted bytes,
clauses and literals. Do not use the production parser to generate expected
names or rows. These two fixtures have no table-reference text inside SQL
literals; another case needs its own review before using this replacement rule.

A batch is a group of client requests, not a combined source transaction:

| Batch | Client write requests | Source transactions |
|---|---:|---:|
| Prepare | 4 | 4 |
| Body | 10 | 18 |
| Before cleanup | 14 | 22 |
| Cleanup | 1 | 1 |

The body counts are original 1/2/3/2, then retained prefixes 1, 1/2 and 1/2/3.
Expected before-cleanup source effects are 12 DDL events and 14 changed rows.
Cleanup adds one DDL/GTID and no row events. Confirm these counts against the
focused native run. A request spanning several GTIDs must preserve the whole
interval and its final file/offset; never equate write count with GTID count.

## ASCII column and index case matching

Keep the original definition:

```sql
id INT,Value INT DEFAULT 7,PRIMARY KEY(ID),KEY ValueKey(VALUE)
```

It tests ID/id, Value/VALUE, valuekey/ValueKey and RenamedKey/renamedkey without
changing their native reference rules. Keep ADD extra AFTER VALUE, CHANGE to
BIGINT, default changes 7→9→5, index rename, DROP COLUMN and DELETE.

Retain:

| Original phase prefix | Table | Rows and schema kept |
|---|---|---|
| 1 | poc.ic_after_insert | id/Value: (1,7), (2,7); original index and default. |
| 1–2 | poc.ic_after_alter | id/Value/extra: (1,9,4), (2,7,3); new default and added column. |
| 1–3 | poc.ic_after_rename | id/renamed/extra: (1,9,4), (2,5,3); BIGINT, default 5 and RenamedKey. |
| Original final table | poc.matrix_identifiercase | id/renamed: (2,5); extra and secondary index removed. |

Map old predicates 1/2/3 to the corresponding retained table. Keep predicate 4
on the original final table. Change only the qualified table token; each old
predicate must still return 1. Add full ordered row queries for all four tables
with the values above. This preserves rows deleted later and fields not listed
in a boolean predicate. Keep full native schema/index comparison, and add a
fixed check of the retained RenamedKey plus its absence from the final table.
Do not normalize integer display widths in fixed values by changing types;
use the existing schema comparison rules.

Cleanup drops only ic_after_insert, ic_after_alter and ic_after_rename in one
DROP TABLE request. Leave the original table for later shared checks.

## Unicode column and index identity

Preserve the entire original definition, including:

- Separate precomposed é (C3A9) and decomposed e+U+0301 (65CC81) columns and indexes.
- Native case reference É to the precomposed column/index, without selecting
  the separate decomposed name.
- 值, 列, 改名 and 键 as written.
- Quoted column `a``b`, whose stored name contains one backtick.
- The original column name with 64 repetitions of 中. Keep 64 characters;
  do not replace it with a shorter ASCII name or a byte-length test.
- NULL fields in row 2 and the original two index key-part orders.

Retain:

| Phase prefix | Table | Important row results |
|---|---|---|
| 1 | poc.ui_after_insert | Row 1: é=10, decomposed=20, 值=30, backtick column=40, long column=50. Row 2 keeps defaults 10/20 and NULL in the other three fields. |
| 1–2 | poc.ui_after_add | Row 1: é=11, decomposed=21, 值=31, 列=7. Row 2 keeps NULL fields and also receives 列=7. |
| 1–3 | poc.ui_after_rename | 改名 replaces the precomposed column; row 2 uses default 15 and backtick value 41. 键 replaces only the precomposed index. The decomposed column/index remain distinct. |
| Original final table | poc.matrix_unicodeidentifiers | Row 2 remains: 改名=15, decomposed=20, 值=NULL, backtick value=41, long column=NULL. 列 and 键 are removed. |

Map old predicates 1/2/3 to those retained tables. Keep predicate 4 on the
original final table. Add full ordered row queries, including NULL fields and
the long name. Inspect column/index names and key-part order as bytes. In the
phase-3 history, indexes must include both decomposed 65CC81 and 键 E994AE.
The final table must keep the decomposed index and lose only 键.

Compare Data or UTF-8 bytes, not Swift canonical String equality. Keep exact
source escapes/code points in unit fixtures. Cleanup drops only ui_after_insert,
ui_after_add and ui_after_rename. Leave the original table.

## Lifecycle, saved state and failures

Do not add a per-case drain, stop/start or snapshot which requires stopping the
writer. The main applier stays active between preparation, body, observations,
cleanup and the next case. Preserve the existing shared final drain and
saved-schema restart.

Record source boundaries and each request's GTID interval. Check the applied
boundary after the body, then after cleanup. Inspect SQLite only when the shared
fixture has stopped, using its final copied state in read-only mode. The original
table should remain current; owned histories should be retired after cleanup.
Check latest saved history schemas, completed DDL/row intents and all expanded
GTIDs. For a multi-GTID request, its last group's end position must equal the
request's saved end position. Do not assert that every GTID in the interval has
the same end position.

Keep the support bundle path visible on failure. Existing BLOCKED bundle
collection must remain enabled. Use failure.json, bundle.json and read-only
SQLite before any failed-case rerun. Preserve phase SQL and boundary evidence.

## Implementation order and focused checks

1. **Pilot:** add the opt-in helper and enable only matrix-identifiercase.
   Keep the Unicode case and all other DML cases on the old path. Preserve
   definitions/phases and metadata-discovery membership. Use one shared title
   for inventory and execution.
2. Add unit tests for exact CREATE/phase bytes, request order, retained reference
   edits, four old predicates, all earlier rows, 4/18/1 source transaction counts,
   cleanup ownership and rejection of unsupported opt-in prerequisites. Test
   multi-GTID intervals and shared final-query validation. Include metadata
   discovery tests because it reads the same Case definitions.
3. Run affected helper, identifier, LabSQLPhase, final-observation and metadata
   discovery unit tests. Check catalog and matrix selection. Do not run syntax
   tests. Repeat selection tooling tests if selection/description wiring changes.
4. Run only the ASCII pilot on forward MyISAM/default/SQL with coverage. Check
   source transaction counts, actual row/default/index results, latest progress,
   final saved state, cleanup and the shared restart. Confirm that the helper
   adds no applier lifecycle transitions.
5. Record calls, case time and setup/coverage/cleanup costs against the correct
   saved default result. Added schemas and repeated DDL can offset fewer waits.
   Do not claim a controlled speed gain across different hosts or individual
   coverage equivalence with the old group report.
6. **Follow-up:** after the pilot passes, enable only matrix-unicodeidentifiers
   with the same helper. Run its focused unit tests and one forward case. Verify
   exact name bytes, NULL/default rows, 64-character name and surviving index.
7. Keep other profiles/variants and whole-group validation for GitHub Actions.
   Preserve 183 jobs, 1,545 catalog obligations and 182 coverage collections.
   Do not change group boundaries or retire cases in either implementation slice.

Pilot command:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-identifiercase --coverage"
```

Follow-up command, after its separate implementation:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-unicodeidentifiers --coverage"
```

Next after both cases: review the native collation/encoding inventories and
ENUM/SET groups with explicit value/ID maps. Keep remaining type/value and
key/index reviews, full-matrix validation, final balancing and short PR selection
in the overall consolidation plan.

## Pilot implementation and focused results

The ASCII pilot uses `DMLExecutionWorkflow`. It is an opt-in helper on the existing
DML case. It submits preparation, body and cleanup requests through `LabSQLPhase`.
It reuses final read-only queries and schema comparisons. At this step, all other
DML cases, including matrix-unicodeidentifiers, kept their existing execution path.

The original definition, all four phase scripts and all four predicates are
unchanged. The helper changes only the controlled table reference for retained
histories. Metadata discovery still uses the original definition and first phase.
The case title is shared by inventory and execution. IDs, groups, profiles and
variants are unchanged. No decoder, applier or production parser code changed.

The helper requires explicit source transaction counts. It validates every
request's SQL bytes and GTID count. It rejects opt-in cases with setup SQL,
custom ordering, a replacement case or JSON diff checks until they have an
explicit plan. Final-query validation is shared with DDL callers. Their existing
source-phase and hidden-check guards remain.

Focused checks passed:

- 27 Swift tests: DML workflow, ASCII fixture, source batches, final observations
  and metadata discovery.
- 41 Python tooling tests: features (10), migrations (8), selection (11) and
  groups (12).
- Catalog structure and matrix comparison: 183 jobs, 1,545 catalog obligations
  and 182 instrumented collections. Job selections and normalized inventory
  match the saved plan. Display names, source locations, assertion descriptions
  and the expected source-input fingerprint are excluded from that comparison.
- Strict Swift format lint on all changed source and test files.

One integration case ran with coverage: mysql84-to-mysql57-myisam, default
variant, SQL transport, matrix-identifiercase. All 16 named assertions passed.
Source, native and target agree on all four old predicates, full ordered rows,
defaults and indexes. Raw engine checks confirm InnoDB on source and MyISAM on
native and target. The final shared saved-schema restart passed.

| Measurement | Result |
|---|---:|
| Case execution | 3.81 seconds |
| Case SQL client calls | 25 |
| Source batches | 3 |
| Client write requests | 15 |
| Source GTIDs before cleanup / after cleanup | 22 / 23 |
| Applied DDL before cleanup / after cleanup | 12 / 13 |
| Changed rows before cleanup / after cleanup | 14 / 14 |
| Fixture setup | 14.38 seconds |
| Container startup, included in setup | 11.77 seconds |
| Coverage export | 1.62 seconds |
| Fixture cleanup | 10.75 seconds |
| Instrumented Swift lines executed / mapped | 7,871 / 20,880 |

Saved CI reported 16.61 seconds and 148 calls for this case. That run selected
the whole area and compared more accumulated tables. The local run selected one
case and added retained schemas. These values are observations across different
runs, not a controlled speed comparison. Local line coverage includes fixture
setup, the case and the shared restart. It does not establish coverage equivalence
with the old whole-group report.

The body and cleanup assertions check exact applied GTID sets, file offsets and
counter deltas. Read-only inspection of final SQLite state confirms all 23
expanded GTIDs are APPLIED. For each multi-GTID request, the last group's offset
matches the recorded request end. DDL and row intents are DONE. The original
table remains current; all retained table versions are retired. Their latest
saved schemas preserve the earlier defaults, BIGINT change and index names.
The final state is STOPPED with no active GTID. Its later offset includes the
existing shared restart check's write.

The fixture used two successful applier invocations: initial apply and the
existing shared saved-schema restart. This case added no drain, restart,
snapshot or offline replay. No other case/profile, full suite, benchmark or
syntax suite ran locally. Leave those checks to GitHub Actions.

Evidence:

- `artifacts/lab/20261104T080241Z-8b45ad51/result.json`
- `artifacts/dml-identifier-workflow-review/results.json`
- `artifacts/dml-identifier-workflow-review/state-results.json`
- `artifacts/dml-identifier-workflow-review/inventory-results.json`
- `artifacts/dml-identifier-workflow-review/verify.py`
- `artifacts/dml-identifier-workflow-review/unit.log`
- `artifacts/dml-identifier-workflow-review/tool-*.log`

This pilot is committed as `e4d54e9`. The next section records its separate
Unicode follow-up. Keep full group/profile validation and the other remaining
reviews in the overall plan.

## Unicode implementation and focused results

The Unicode case now uses the same helper. Its original definition, four scripts
and four predicates keep their exact UTF-8 bytes. The new workflow retains the
first one, two and three phases in ui_after_insert, ui_after_add and
ui_after_rename. It leaves matrix_unicodeidentifiers for the original final
result. No shared helper or execution code changed in this slice. The separate
DDL table-name fixture is unchanged.

The four original predicates run against the appropriate retained or final table.
Ten additional queries check full ordered rows and name metadata. They include:

- Original and changed defaults, NULL fields and values from the deleted row.
- Separate C3A9 and 65CC81 column/index names before rename.
- The renamed column 改名 and renamed index 键, while the decomposed name remains.
- The escaped backtick name as stored bytes 616062.
- The long column's full 192 UTF-8 bytes and length of 64 characters.
- Column order and both index key-part orders, including the id suffix.
- The final decomposed index after the other index and added column are dropped.

The query expectations are fixed independently of the production parser.
Queries use HEX for names and BINARY ordering for indexes. Unit tests compare
SQL and definition bytes with Data, rather than Swift String canonical equality.
They reject substituted composed names, reversed key parts, changed row results
and a shortened column name.

Focused checks passed:

- 18 Swift tests: six Unicode workflow tests, five ASCII fixture tests, four
  workflow helper tests and three metadata-discovery tests.
- Catalog structure and matrix comparison: 183 jobs, 1,545 catalog obligations
  and 182 instrumented collections. Existing selections and normalized inventory
  are unchanged. The normalization excludes display names, source locations,
  assertion descriptions and the source-input fingerprint.
- Strict Swift format lint on the three changed Swift files and git diff checks.

Selection tooling and runner code did not change, so their Python tests were not
repeated. The ASCII source fixture and shared helper/runner match the pilot
commit. Metadata discovery still reads the original Unicode definition and first
INSERT/check on every profile.

One integration case ran with coverage: mysql84-to-mysql57-myisam, default
variant, SQL transport, matrix-unicodeidentifiers. All 20 named assertions passed.
The final full schema/row comparison agrees across source, native and target.
Raw engine checks confirm InnoDB on source and MyISAM on native and target.

| Measurement | Result |
|---|---:|
| Case execution | 3.96 seconds |
| Case SQL client calls | 25 |
| Source batches / client write requests | 3 / 15 |
| Source GTIDs before cleanup / after cleanup | 22 / 23 |
| Applied DDL before cleanup / after cleanup | 12 / 13 |
| Changed rows before cleanup / after cleanup | 14 / 14 |
| Fixture setup | 15.05 seconds |
| Container startup, included in setup | 12.23 seconds |
| Coverage export | 1.77 seconds |
| Fixture cleanup | 9.71 seconds |
| Instrumented Swift lines executed / mapped | 7,973 / 20,880 |

Saved CI reported 16.44 seconds and 148 calls. As with the ASCII pilot, the old
whole-area run had more accumulated tables in poc. The local run selects one
case. These measurements do not establish a controlled speed comparison or
individual coverage equivalence. Coverage includes setup and the shared restart.

Both checkpoint assertions confirm exact applied GTID sets, file offsets and
counter deltas. Read-only inspection of final SQLite state confirms all 23
expanded GTIDs are APPLIED. Each request's last GTID has its recorded end offset.
All DDL and row intents are DONE. The latest schemas keep exact column/index
name bytes, defaults and index key order. Cleanup retired all three retained
tables and kept the original table current. The final state is STOPPED without
an active GTID, at the shared restart check's later offset.

The shared saved-schema restart passed. Two successful applier invocations are
recorded: initial apply and that existing restart. This case added no drain,
restart, snapshot or offline replay. No other integration case/profile, full
suite, benchmark or syntax suite ran locally. Leave those checks to GitHub Actions.

Evidence:

- `artifacts/lab/20261104T155903Z-2120a00f/result.json`
- `artifacts/unicode-dml-workflow-review/results.json`
- `artifacts/unicode-dml-workflow-review/state-results.json`
- `artifacts/unicode-dml-workflow-review/source-manifest.json`
- `artifacts/unicode-dml-workflow-review/inventory-results.json`
- `artifacts/unicode-dml-workflow-review/verify.py`
- `artifacts/unicode-dml-workflow-review/unit.log`

The [native inventory review](BETA7_NATIVE_ENCODING_INVENTORY_REVIEW.md) records
both complete value/ID maps, saved measurements and both implementation results.
Each inventory passed all 16 named assertions on forward MyISAM. The
[ENUM/SET workflows](BETA7_ENUM_SET_WORKFLOW_REVIEW.md#legacy-binary-set-implementation-and-local-completion)
passed choices, widechoices, binarychoices, exactchoices, enumzero and
choiceboundaries. Legacybinaryset passed 12 on the 5.7 MyISAM profile.
The [character and binary value review](BETA7_CHARACTER_BINARY_VALUE_WORKFLOW_REVIEW.md#implementation-results)
records all three conversions: 101 unit tests and 48 forward assertions passed.
The [data-type review](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md) keeps all 25 IDs.
The [type/value workflow results](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md#partial-json-event-checks-in-the-shared-workflow)
record twenty-three completed conversions. All focused checks passed.
JSON and spatial cases share the data-types-values fixture.
Partial JSON now keeps bounded event proofs.
The [index workflow results](BETA7_KEY_INDEX_WORKFLOW_REVIEW.md#implementation-and-focused-results)
record all 12 conversions. All 57 original assertions and the shared restart
passed on forward MyISAM. Eleven focused unit tests passed.
The [primary-key and constraint results](BETA7_PRIMARY_KEY_CONSTRAINT_WORKFLOW_REVIEW.md#implementation-and-focused-results)
record both conversions. All 23 operation states and 15 original named assertions
passed on forward MyISAM. Fourteen focused unit tests passed.
Next: review conflict statements and their no-op GTID/offset boundaries.
Keep remaining key/index reviews, full-matrix validation, final balancing
and short PR selection in the overall plan. Do not
remove an inventory because its line coverage overlaps another case.
