# Identifier case sensitivity: lower-case table workflow review

Status: implemented and tested on forward MyISAM with lowercase-tables. See
[the focused results](#implementation-and-focused-results). The review records
the approved design.
The Unicode table-name workflow was committed as `1ab3497`.

## Decision

Convert only `ddl-compat-table-name-case`. Keep all ten original source
operations first and unchanged. Keep both explicit result predicates, restarts
before operations 3 and 8, case ID, group, engine choices and selections.

Use three body batches of 2/5/26 operations. Four retained databases keep six
earlier tables. The proposal has 33 source operations and ten final query
checks. Do not add a restart, offline replay path, metadata override, production
name-conversion change or shared runner change.

The initial review used saved CI measurements and source inspection. No build,
unit test or integration test ran during that review. The proposal is static evidence; confirm its new
fixed metadata expectations in the focused native run.

## MySQL names and server setting

Consult MySQL documentation before naming features. Use
[Identifier Case Sensitivity](https://dev.mysql.com/doc/refman/8.4/en/identifier-case-sensitivity.html).
Use the title **Identifier case sensitivity: lower_case_table_names=1, LIKE and RENAME**.
Keep the case ID unchanged.

With lower_case_table_names=1, MySQL stores and looks up database and table
names in lowercase. This does not mean that every identifier should be rewritten
in lowercase. Keep the original column name ID and its case-insensitive uses.
The shared column/index cases test their wider native rules separately.

The harness sets this server option through the lowercase-tables variant.
LabFixture passes REPLICATOR_LOWER_CASE_TABLE_NAMES to the compose files, which
set the option on source, native and target. On MySQL 8.4, the setting belongs
to server initialization. Do not replace this fixture setup with SET GLOBAL or
combine it with mode-0 tests in the same initialized servers.

Keep LabScenario.reason: this case is excluded from every variant except
lowercase-tables. The distinct Unicode table-name case remains excluded from
this variant. All four profile selections remain. This test does not establish
replication across different source/target case settings or arbitrary host
filesystem behavior.

## Saved evidence

At review time, TableNameCaseCases.swift matched CI commit `efb3458` byte-for-byte.
CI run `40454033524` has complete measurements and coverage, with no failed
or missing shards. All four applicable executions passed:

| Profile | Variant | Case seconds | SQL client calls |
|---|---|---:|---:|
| mysql84-to-mysql57-myisam | lowercase-tables | 35.56 | 160 |
| mysql57-to-mysql84-innodb | lowercase-tables | 29.99 | 159 |
| mysql57-to-mysql57-myisam | lowercase-tables | 33.63 | 159 |
| mysql57-to-mysql57-innodb | lowercase-tables | 28.60 | 159 |

The default variant excludes this case. Compare its new timing with the saved
lowercase-tables result, not a default-variant result. Calls are harness mysql
client calls, not target SQL statements.

Coverage belongs to the whole character-set group for each profile/variant.
It cannot identify this case's individual lines or prove that a mode-0 case
replaces it. Keep the limits in the [character-set review](BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#coverage-comparison-scope)
and [identifier ownership map](BETA7_QUERY_IDENTIFIER_WORKFLOW_REVIEW.md#feature-ownership).
No per-case coverage equivalence is claimed.

Evidence:

- `artifacts/lowercase-table-workflow-review/baseline.json`: four saved runs.
- `artifacts/lowercase-table-workflow-review/source-review.json`: original SQL,
  checks, retained histories, case-preserving edits, phases and cleanup.
- `artifacts/lowercase-table-workflow-review/review.py`: source and byte audit.

## Original SQL and retained histories

Keep the exact mixed-case source references. These include ddlcompat and
DDLCOMPAT, MiXÉ/mixé/MIXÉ, CoPy/COPY, Final/FINAL/final and Old/OLD. Keep ID/id,
n and extra as written. Do not lowercase the source SQL to make copying easier.
The accented uppercase/lowercase characters must remain unchanged.

Use retained databases so the original table names stay intact. Create each
with CHARACTER SET utf8mb4 COLLATE utf8mb4_bin, as in the original database.
Replace only database qualifiers when copying:

- `ddlcompat.` becomes the lowercase retained database qualifier.
- `DDLCOMPAT.` becomes its uppercase ASCII qualifier.

For example, INSERT INTO DDLCOMPAT.`mixé` becomes INSERT INTO
LC_AFTER_INSERT.`mixé`. Do not replace both forms with a lowercase qualifier.
Preserve every table/column spelling, quoted name, literal and clause order.
Use fixed expected native names; do not use Swift lowercased() on the accented
table name as the test oracle. Compare SQL and name bytes with Data.

Keep original operations 1–10 first, through both DROP statements. Append these
histories, each preceded by its own CREATE DATABASE:

| Original prefix | Retained database | State kept |
|---|---|---|
| 1–2 | lc_after_insert | mixé has ID 1/n 7, before extra exists. |
| 1–3 | lc_after_add | ALTER materializes extra=3 on the existing row. |
| 1–6 | lc_after_copy | mixé has extra=9; LIKE/INSERT SELECT creates copy with the same row. |
| 1–8 | lc_after_rename | Multi-table RENAME leaves old and final; following UPDATE changes only final.n to 8. |

The extra=3 history preserves a value overwritten by operation 4. The copy
history preserves both the source UPDATE result and INSERT SELECT result.
Keep the original LIKE followed by INSERT SELECT. Final row checks must reject
extra copied rows; do not replace the pair with a final CREATE or literal row.

The last history keeps the old and final names with distinct n values. This
checks that the following UPDATE uses the renamed copy while old stays at n=7.
Keep the original RENAME statement intact, including both rename pairs.

Ten original operations, four CREATE DATABASE operations and 19 copied
operations give 33 body operations. Each remains one source transaction.
All writes use the normal UTF-8 session. Capture source warnings without adding
an empty-warning requirement. Keep metadata selection unchanged.

## Phases and final observations

Body batches:

1. **insert-through-mixed-case-names:** original operations 1–2.
2. **alter-copy-and-rename-tables:** original operations 3–7, after the first
   deliberate restart.
3. **update-drop-and-retain-results:** original operations 8–10 and all 23
   retained setup/history operations, after the second deliberate restart.

The sizes are 2/5/26. Retained histories add no applier restarts.

Map the two old queries by database qualifier only:

1. SELECT ID,n from lc_after_insert.`MIXÉ`: `1\t7`.
2. SELECT ID,n,extra from lc_after_rename.`final`: `1\t8\t9`.

Keep their original selected fields, WHERE/order clauses and expected strings.
Add eight read-only checks:

- ID/n/extra from lc_after_add.`mixé`, ordered by ID: `1\t7\t3`.
- The same fields from lc_after_copy.`MIXÉ`: `1\t7\t9`.
- The same fields from lc_after_copy.`COPY`: `1\t7\t9`.
- The same fields from lc_after_rename.`OLD`: `1\t7\t9`.
- HEX(TABLE_NAME), ordered by BINARY TABLE_NAME, in lc_after_copy:
  `636F7079\n6D6978C3A9` (copy and mixé).
- The same name query in lc_after_rename: `66696E616C\n6F6C64` (final and old).
  Original mixé/copy names must be absent after RENAME.
- HEX(COLUMN_NAME), in ordinal order, for the single lc_after_add table:
  `4944\n6E\n6578747261` (ID, n, extra). This distinguishes table-name folding
  from the stored spelling of column names.
- COUNT(*) from INFORMATION_SCHEMA.TABLES for original ddlcompat: 0.

Use ten final query checks and full schema/index/row comparisons in all five
databases. Check actual native name/column bytes before accepting the new fixed
expectations. Raw metadata must show lowercase database/table names while the
source SQL retains its original mixed-case references.

The saved snapshot must have six current tables: one mixé in lc_after_insert,
one in lc_after_add, mixé/copy in lc_after_copy, and old/final in lc_after_rename.
No table may remain current under original ddlcompat. Retired mixé/copy names
in lc_after_rename must not remain current. Inspect all 33 APPLIED groups,
GTIDs/file/end offsets, the checkpoint and completed DDL intents. Keep the
shared saved-schema restart.

## Cleanup and focused validation

After saved-state checks, one cleanup batch executes four source operations:

```sql
DROP DATABASE lc_after_insert;
DROP DATABASE lc_after_add;
DROP DATABASE lc_after_copy;
DROP DATABASE lc_after_rename;
```

Drop only those owned databases. Leave original ddlcompat intact and empty.
Verify that cleanup retires all six owned schemas in the final state. Add no
synthetic original table or offline replay path.

Implementation checks:

1. Convert only tableNameCase with existing helpers. Leave the Unicode table
   case, DML identifier cases, case settings, native map and shared runner unchanged.
2. Add focused unit tests for original SQL bytes, uppercase/lowercase database
   qualifier edits, unchanged accented table and column spellings, both old
   predicates, extra=3 before UPDATE, copy/rename rows, fixed name/column bytes,
   33 transactions, both restart positions and owned cleanup. Check rejection
   outside lowercase-tables and acceptance on that variant for all four profiles.
3. Run the changed workflow and phase/final-observation unit tests only. Do not
   run syntax tests. Repeat selection tool tests only if their code or inventory changes.
4. Run one forward MyISAM case with the explicit lowercase-tables variant and
   coverage. Confirm lower_case_table_names=1 on all three roles from runtime
   evidence. Keep other profiles and the full suite for GitHub Actions.
5. Inspect retained/retired name bytes, old/new column values, LIKE/INSERT SELECT
   rows, both restart results, raw engines, 33 GTIDs and offsets, completed intents,
   saved-schema restart and cleanup retirement. Use the support bundle before
   rerunning a failed case. Preserve the original evidence.
6. Confirm unchanged matrix/catalog selection: 183 jobs, 1,545 catalog obligations
   and 182 coverage collections. Compare with the saved mode-1 case. Record case
   time and client calls separately from setup, coverage export and cleanup.
   Update the test guide and current plan after the focused run.

Focused command:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-table-name-case --variant lowercase-tables --coverage"
```

The extra databases add real source/native work. Fewer waits and client startups
do not guarantee a lower time. Measure before claiming a speed improvement.
Do not remove original predicates or earlier row states to improve timing.
The old coverage belongs to a whole group, not this case alone.

Next after this implementation: review the two DML identifier cases and their
phase/assertion map. Keep native collation/encoding inventories, ENUM/SET,
remaining type/value and key/index reviews, full-matrix validation, final
balancing and short PR selection in the overall consolidation plan.

## Implementation and focused results

The case now uses three body batches of 2/5/26 operations. Its first ten source
operations remain byte-for-byte unchanged. Four retained databases execute the
reviewed prefixes. Copied SQL changes only database qualifiers and keeps their
uppercase/lowercase forms. All accented table spellings, column names, literals,
RENAME pairs and original DROP statements remain. Both old predicates and both
original restart points remain. Eight further queries check earlier values,
copy/rename results and exact stored name bytes.

The mysql84-to-mysql57-myisam/lowercase-tables/SQL case passed all
21 named assertions. Runtime evidence confirmed lower_case_table_names=1
on source, native and target. Raw names were lowercase copy/mixé and final/old.
The fixed column-name query confirmed ID/n/extra, retaining the uppercase ID
spelling. Native results confirmed added-column value 3 before UPDATE, value 9
after UPDATE and INSERT SELECT, final.n=8 and unchanged old.n=7. Original
ddlcompat was empty. Full schema/index/row comparisons covered all five databases.

Saved-state inspection confirmed all 33 body groups APPLIED, exact GTIDs and
file/end offsets, the checkpoint, six current retained tables with exact name
bytes, retired rename/original names and DONE DDL intents. Raw table data
confirmed source InnoDB and native/target MyISAM. Both deliberate restarts and
the shared saved-schema restart passed. Cleanup dropped only the four retained
databases and retired all six owned table schemas. The run used one fixture
and five source batches: setup, three body batches and cleanup.

The Unicode table-name case, DML identifier cases, case settings and selection
rules are unchanged. No production code, shared runner, metadata override,
extra restart or replay path changed.

| Measurement | Saved CI, lowercase-tables | Focused local run, lowercase-tables |
|---|---:|---:|
| Case seconds | 35.56 | 30.89 |
| Harness SQL client calls | 160 | 74 |

The hosts differ. These times are not a controlled speed comparison. Retained
databases add real DDL/DML work. Setup, coverage export and cleanup costs are
separate in `artifacts/lowercase-table-workflow-review/results.json`.

The selected run executed 7,578 of 20,880 mapped first-party lines.
The old coverage belongs to the whole character-set group on this variant.
This run does not establish whole-group coverage parity or a loss in cases
which did not run. The source, predicate and retained-state audits preserve
the reviewed conditions.

All 19 selected Swift tests passed. They check original SQL bytes, edits limited
to database qualifiers with preserved case, accented spellings, two old queries,
new row/name checks, 33 transactions, both restart positions, variant selection
and owned cleanup. Formatting, source-preservation, catalog and matrix checks
passed. The matrix retains 183 jobs, 1,545 catalog obligations and 182 coverage
collections. Groups, ordering and exclusions remain unchanged. Selection tool
tests were not repeated because their code and inventory did not change.
No other case/profile, full suite, benchmark or syntax suite ran locally.

Evidence:

- `artifacts/lab/20261104T070256Z-50506be0/result.json`
- `artifacts/lab/20261104T070256Z-50506be0/mysql84-to-mysql57-myisam/correctness/lowercase-tables/20261104T070711Z-56053e06-auto-autocommit-myisam/runtime.json`
- `artifacts/lowercase-table-workflow-review/results.json`
- `artifacts/lowercase-table-workflow-review/state-results.json`
- `artifacts/lowercase-table-workflow-review/source-preservation.json`
- `artifacts/lowercase-table-workflow-review/matrix-comparison.json`
- `artifacts/lowercase-table-workflow-review/unit.log`

The [DML identifier workflows](BETA7_DML_IDENTIFIER_WORKFLOW_REVIEW.md#unicode-implementation-and-focused-results)
passed their focused forward cases: 16 ASCII assertions and 20 Unicode assertions.
Both keep the original SQL and metadata inputs, check GTID intervals and add no
applier restart. Next: review the native collation/encoding inventories with
explicit value and ID maps, then ENUM/SET. Keep remaining type/value and key/index
reviews, full-matrix validation, final balancing and short PR selection later.
