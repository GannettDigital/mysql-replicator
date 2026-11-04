# Schema object names: Unicode table workflow review

Status: implemented and tested on forward MyISAM. The review below records the
approved design. See [the focused results](#implementation-and-focused-results).
The encoded Query workflow was committed as `71b8aab`.

## Decision

Convert only `ddl-compat-unicode-names`. Keep its ID, group, engine choices and
profile/variant selections. Keep all 15 original source operations first and
unchanged. Keep all four explicit result predicates. The case has no deliberate
applier restart or offline replay path; add neither.

Use one body batch with 48 source operations. Five retained databases preserve
nine earlier tables without changing their original names. Final queries check
the retained results and the original DROP outcomes. Use the existing phase and
final-observation helpers. No production name parser, cache, conversion rule or
shared runner change belongs in this slice.

The initial review used saved measurements, source inspection and the existing
native identifier notes. No build, unit test or integration test ran during that review. The proposal and
its source audit are static evidence. Native results remain to be checked in
the focused implementation run.

## MySQL feature names and native limits

Consult MySQL documentation when naming features. Use
[Schema Object Names](https://dev.mysql.com/doc/refman/8.4/en/identifiers.html)
and [Identifier Case Sensitivity](https://dev.mysql.com/doc/refman/8.4/en/identifier-case-sensitivity.html).
Use the case title **Schema object names: Unicode table identity, RENAME and CREATE TABLE LIKE**.
Keep the ID unchanged.

The MySQL manual limits identifiers to Basic Multilingual Plane characters.
It does not promise supplementary-character identifiers. The existing native
probes in [IDENTIFIER_SUPPORT.md](IDENTIFIER_SUPPORT.md#native-checks) observed
conversion of the supplementary character to `?`, with a warning, on 5.7.42 and
8.4.8. The case explicitly queries the resulting `?` table and column. Preserve
that observed behavior and its source SQL. Do not turn it into a general claim
that supplementary characters are permitted in identifiers.

The native notes also show separate precomposed and decomposed names, native
column case matching and system-charset conversion. Their source references
include IDENT_sys in sql_yacc.yy and THD::convert_string. The production code
already implements these rules. This slice changes only the harness workflow.

## Saved measurements and source audit

At review time, the whole UnicodeIdentifierCases.swift file matched CI commit
`efb3458` byte-for-byte. That includes the separate matrix-unicodeidentifiers case, which
must remain unchanged. CI run `40454033524` has complete measurements and
coverage, with no failed or missing shards. All six applicable executions passed:

| Profile | Variant | Case seconds | SQL client calls |
|---|---|---:|---:|
| mysql84-to-mysql57-myisam | default | 29.78 | 213 |
| mysql57-to-mysql84-innodb | default | 23.39 | 212 |
| mysql57-to-mysql57-myisam | default | 28.93 | 212 |
| mysql57-to-mysql57-innodb | default | 24.13 | 212 |
| mysql84-to-mysql57-myisam | gtid-full | 29.63 | 213 |
| mysql84-to-mysql57-myisam | position-minimal | 24.38 | 213 |

Calls are harness mysql client calls, not target SQL statements. Keep the
lowercase-tables exclusion in LabScenario.reason. This case needs mode 0 to
check separate table identities. The distinct mode-1 case comes later.

Coverage belongs to the larger character-set group. It cannot identify this
case's individual lines or establish that another identifier case replaces it.
Keep the limits in the [character-set review](BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#coverage-comparison-scope)
and the [identifier ownership map](BETA7_QUERY_IDENTIFIER_WORKFLOW_REVIEW.md#feature-ownership).

Evidence:

- `artifacts/unicode-table-workflow-review/baseline.json`: six saved executions.
- `artifacts/unicode-table-workflow-review/source-review.json`: original SQL and
  checks, exact code points, retained histories, final queries and cleanup.
- `artifacts/unicode-table-workflow-review/review.py`: unchanged-source and
  retained-reference audit.

## Exact names and retained databases

Keep the original name bytes:

- Precomposed é: UTF-8 C3A9.
- Decomposed e followed by U+0301: UTF-8 65CC81.
- 中: UTF-8 E4B8AD, used unquoted in the original RENAME and later statements.
- `select`: keep the quoted reserved word itself.
- 😀: UTF-8 F09F9880 in the source SQL. Keep the quoted CREATE/INSERT and the
  unquoted DROP. Preserve the column name and the query of stored name `?`.
- 值: keep the original column name and every literal value.

Swift String equality can equate precomposed and decomposed names. Compare Data
or UTF-8 bytes in unit tests, source audits and fixed metadata expectations.
Keep LabSQLName's byte comparison. Do not normalize names or use the production
parser to produce expected names.

Use retained databases so no table-name prefix changes the identifier under
test. A prefix would change the actual reserved word or the supplementary-name
conversion result. Each retained database must use the same explicit defaults
as ddlcompat: CHARACTER SET utf8mb4 COLLATE utf8mb4_bin. That preserves the
implicit defaults of the original CREATE statements.

Keep original operations 1–15 first, including all DROP statements. Append the
following independent histories. For each history, create its database, then
copy the listed original operations. Replace only qualified `ddlcompat.`
references with the retained database qualifier.

| Original operations | Retained database | Tables and rows kept |
|---|---|---|
| 1–4 | un_after_insert | Precomposed table has id 1/value 10; decomposed table has id 1/value 20. |
| 1–5 | un_after_update | Precomposed value is 11; decomposed value is still 20. |
| 1–7 | un_after_rename | Precomposed name moved to 中, with values 11 and 12; decomposed table remains at value 20. |
| 1–10 | un_after_like | Decomposed table dropped; 中 retains its two rows; quoted `select` LIKE table has id 1/value 30. |
| 13–14 | un_supplementary | Native stored table/column `?`, with id 1/value 40. |

The first history preserves value 10 before UPDATE overwrites it. The second
keeps both explicit UPDATE predicates. The third keeps the old two-row RENAME
predicate. The fourth keeps the LIKE/INSERT result before both tables are
dropped. The last needs only the independent supplementary CREATE and INSERT;
it does not need to repeat the unrelated earlier tables.

Keep the full CREATE/RENAME/LIKE/DROP statements in each history. Do not replace
an earlier state with a final CREATE or literal rows. Keep `select` empty at
creation by executing the original LIKE followed by INSERT. Final fixed row
checks must reject extra copied rows. Do not replace that pair with CREATE AS
SELECT.

There are 15 original operations, five CREATE DATABASE operations and 28 copied
operations, for 48 body operations. Use one phase named
`unicode-table-names-and-retained-results`. Each operation remains one source
transaction. All writes use the normal UTF-8 session. Add no USE statement,
charset override, metadata override or applier restart. Capture warnings without
requiring empty warnings from native name conversion.

## Final observations

Map the four old predicates by database qualifier only:

1. SELECT 值 from precomposed table in un_after_update: 11.
2. SELECT 值 from decomposed table in un_after_update: 20.
3. SELECT 值 from 中 in un_after_rename, ORDER BY id: 11 followed by 12.
4. SELECT `?` from table `?` in un_supplementary: 40.

Keep the exact selected fields, row order and expected strings. Add these eight
read-only checks:

- id/value rows for precomposed table in un_after_insert: `1\t10`.
- id/value rows for decomposed table in un_after_insert: `1\t20`.
- HEX(TABLE_NAME), ORDER BY BINARY TABLE_NAME, in un_after_update:
  `65CC81\nC3A9`.
- The same name query in un_after_rename: `65CC81\nE4B8AD`. This also checks
  that the precomposed source name is absent after RENAME.
- id/value rows for quoted `select` in un_after_like: `1\t30`, with no extra row.
- The name query in un_after_like: `73656C656374\nE4B8AD`. The decomposed name
  must be absent while the reserved-word table and rename destination remain.
- HEX(TABLE_NAME),HEX(COLUMN_NAME) for the non-id column in un_supplementary:
  `3F\t3F`. Confirm the existing native replacement result in the focused run.
- COUNT(*) from INFORMATION_SCHEMA.TABLES for original ddlcompat: 0.

This gives 12 final query checks. Compare full schemas, indexes and rows in all
six databases: original ddlcompat plus the five retained databases. Exact name
bytes must remain visible in raw evidence. Do not use a case/accent-insensitive
TABLE_NAME equality predicate to distinguish precomposed/decomposed names.
Use HEX or binary comparisons instead.

Saved-state inspection must find these nine current tables:

- un_after_insert and un_after_update: precomposed and decomposed tables in each.
- un_after_rename: 中 and the decomposed table.
- un_after_like: 中 and `select`.
- un_supplementary: `?`.

No original table may remain current under ddlcompat. Within retained databases,
old names removed by RENAME or DROP must also be retired. Check exact UTF-8 name
bytes, all 48 APPLIED groups, GTIDs/file/end offsets, the final checkpoint and
DONE DDL intents. Keep the shared saved-schema restart.

## Cleanup

After saved-state assertions, use one cleanup batch with five source operations:

```sql
DROP DATABASE un_after_insert;
DROP DATABASE un_after_update;
DROP DATABASE un_after_rename;
DROP DATABASE un_after_like;
DROP DATABASE un_supplementary;
```

Drop only those owned databases. Do not drop or recreate original ddlcompat.
The original case already drops all of its tables. Do not introduce a synthetic
surviving original table for restart checks. Do not add an offline replay path.

## Focused implementation and validation

1. Convert only unicodeNames with existing helpers. Leave unicodeIdentifiers,
   the mode-1 case, native name rules and case selection unchanged.
2. Add focused unit tests for original source bytes and all Unicode scalar
   sequences, database-only edits in copied histories, the exact reserved word,
   supplementary source names versus stored `?`, four old predicates, pre-update
   value 10, renamed/LIKE rows, final name sets and owned cleanup. Verify one
   transaction per operation, no new restart and the unchanged mode-1 exclusion.
3. Run the affected workflow and phase/final-observation unit tests. Do not run
   syntax tests. Run selection tool tests only if their code or inventory changes.
4. Run only ddl-compat-unicode-names on forward MyISAM/default/SQL with coverage.
   Keep other profiles, positioning variants, the lower-case case and full suite
   for GitHub Actions. Use the support bundle before a failed-case rerun.
5. Inspect current/retired schema names as bytes, original DROP outcomes,
   pre-update/updated/renamed/LIKE rows, source name-conversion warnings, raw engines,
   48 source GTIDs and offsets, completed intents, restart and cleanup. Preserve
   the original evidence. Do not treat a name's visual appearance as byte identity.
6. Confirm unchanged matrix/catalog selection: 183 jobs, 1,545 catalog obligations
   and 182 coverage collections. Record client calls and case time separately
   from setup, coverage export and cleanup. Update the test guide and plan with
   the focused results.

Focused command:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-unicode-names --coverage"
```

The retained histories add five databases and real DDL/DML work. Fewer client
startups and waits do not guarantee a lower elapsed time. Measure before claiming
a speed improvement. Do not discard byte checks or earlier row states to obtain
a lower time. The old coverage belongs to a whole group; do not claim per-case
coverage parity from this selected run.

Next after this implementation: review the lower-case table-name variant, then
the DML identifier phases. Keep native collation/encoding inventories, ENUM/SET,
remaining type/value and key/index reviews, full-matrix validation, final
balancing and short PR selection in the overall consolidation plan.

## Implementation and focused results

The case now uses one body batch of 48 source operations. All 15 original SQL
operations remain first and byte-for-byte unchanged. Five retained databases
execute the reviewed histories with edits limited to database qualifiers.
The original reserved word, precomposed/decomposed names and supplementary
source names remain intact. All four original result predicates remain.
Eight further queries check pre-update values, exact name sets, LIKE rows,
the native stored `?` name and original DROP outcomes.

The forward MyISAM/default/SQL case passed all 20 named assertions. Full
schema/index/row comparisons covered all six databases. Raw name bytes confirmed
C3A9 and 65CC81 as separate tables, E4B8AD as the RENAME destination and
73656C656374 as the quoted LIKE table. Retained rows confirmed values 10 before
UPDATE, 11 after UPDATE, 20 in the separate decomposed table, 11/12 after RENAME
and 30 in the LIKE table. Native stored table/column names were 3F/3F with value
40. The original database had no remaining tables.

Saved-state inspection confirmed all 48 body groups APPLIED, exact GTIDs and
file/end offsets, the final checkpoint, nine current retained tables with exact
name bytes and all expected retired names. All DDL intents were DONE. Raw table
data confirmed source InnoDB and native/target MyISAM. Saved-schema restart and
cleanup passed. Cleanup used five DROP DATABASE operations in one batch and
retired all owned schemas in the final state. The source phase captured warning
output for five operations. All were warning 1300 for conversion from utf8mb4
to utf8mb3; see the saved warning evidence.

The run used one fixture and three source batches: setup, body and cleanup.
No deliberate applier restart or replay path was added. The separate Unicode
column/index case, mode-1 case, selection rules, metadata settings, shared runner
and production name/cache logic are unchanged.

| Measurement | Saved CI | Focused local run |
|---|---:|---:|
| Case seconds | 29.78 | 13.12 |
| Harness SQL client calls | 213 | 60 |

The hosts differ. The times are not a controlled speed comparison. The retained
databases add real DDL/DML work. Setup, coverage export and cleanup costs are
recorded separately in `artifacts/unicode-table-workflow-review/results.json`.
Do not add times from different fixtures and present the sum as a group result.

The selected run executed 7,417 of 20,880 mapped first-party lines.
The old coverage belongs to the larger character-set group. This selected run
does not establish whole-group parity or a loss in cases which did not run.
The source, predicate and retained-state audits preserve the reviewed conditions.

All 19 selected Swift tests passed. They check original Unicode bytes, edits
limited to database qualifiers, the four old predicates, new row/name checks,
48 separate transactions, absence of added restarts, mode-1 exclusion and owned
cleanup. Formatting, source-preservation, catalog and matrix checks passed.
The matrix retains 183 jobs, 1,545 catalog obligations and 182 coverage
collections. Groups, ordering and exclusions are unchanged. Selection tool tests
were not repeated because their code and inventory did not change. No other
case/profile, full suite, benchmark or syntax suite ran locally.

Evidence:

- `artifacts/lab/20261104T064141Z-4702a869/result.json`
- `artifacts/unicode-table-workflow-review/results.json`
- `artifacts/unicode-table-workflow-review/state-results.json`
- `artifacts/unicode-table-workflow-review/source-preservation.json`
- `artifacts/unicode-table-workflow-review/matrix-comparison.json`
- `artifacts/unicode-table-workflow-review/unit.log`

The [lower-case table-name workflow](BETA7_LOWERCASE_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed its forward mode-1 case. The [DML identifier workflows](BETA7_DML_IDENTIFIER_WORKFLOW_REVIEW.md#unicode-implementation-and-focused-results)
passed their focused forward cases: 16 ASCII assertions and 20 Unicode assertions.
Both keep the original SQL and metadata inputs, check GTID intervals and add no
applier restart. Next: review the native collation/encoding inventories with
explicit value and ID maps, then ENUM/SET. Keep remaining type/value and key/index
reviews, full-matrix validation, final balancing and short PR selection later.
