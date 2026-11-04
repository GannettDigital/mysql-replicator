# Connection character sets and schema object names: workflow review

Status: the encoded Query case is implemented and tested on forward MyISAM.
See [the focused results](#encoded-query-implementation-and-focused-results).
The identifier cases remain separate. The DEFAULT workflow was committed as `5d315a1`.

## Decision and scope

Convert `ddl-compat-query-encodings` with existing phase/final-observation
helpers. Keep all ten original source operations first, all four explicit query
checks, both restarts and the forced FULL metadata setting. Keep its ID, group,
profile/variant selections and engine choices. No production decoder, parser,
encoding helper or cache change belongs in this slice.

The proposal has 25 source operations in three body batches: 2/4/19. Five
retained tables preserve earlier states. Final queries compare those states and
confirm that the two original table names are absent. Each operation keeps one
source transaction. Do not add an offline replay path.

The identifier cases have different assertions and server-setting requirements.
Keep them as separate selections. Review their retained states after the encoded
Query case passes. This review establishes ownership and order; it does not
remove cases or merge their obligations.

The initial review used saved CI measurements and source inspection. No build,
unit test or integration test ran during that review. The saved source audit and proposed byte sequences
are static evidence. Check actual Query events in the focused implementation run.

## MySQL feature names

Consult MySQL documentation before naming features. Use:

- [Connection Character Sets and Collations](https://dev.mysql.com/doc/refman/8.4/en/charset-connection.html).
- [Schema Object Names](https://dev.mysql.com/doc/refman/8.4/en/identifiers.html).
- [Identifier Case Sensitivity](https://dev.mysql.com/doc/refman/8.4/en/identifier-case-sensitivity.html).
- [Identifier Length Limits](https://dev.mysql.com/doc/refman/8.4/en/identifier-length.html).

Use the encoded case title **Connection character sets: latin1 and Shift-JIS
Query events**. Keep the case ID unchanged. These MySQL features are more
specific than a generic "Unicode" or "encoding" test. Do not use the same name
for SQL byte decoding, column character sets and identifier case matching.

## Saved measurements

CI run `40454033524`, commit `efb3458`, has complete measurements and coverage,
with no failed or missing shards. At review time, all four source files for the
five cases below matched that commit byte-for-byte. The report contains 40 passing
executions: ten encoded Query, six Unicode table-name, four lower-case table-name,
ten column/index case and ten Unicode column/index executions.

Default/SQL measurements, except the table-name case which requires mode 1:

| Case | Forward 8.4→5.7 seconds / calls | Reverse 5.7→8.4 seconds / calls | 5.7→5.7 MyISAM seconds / calls | 5.7→5.7 InnoDB seconds / calls |
|---|---:|---:|---:|---:|
| ddl-compat-query-encodings | 40.97 / 217 | 33.46 / 216 | 39.98 / 216 | 35.46 / 216 |
| ddl-compat-unicode-names | 29.78 / 213 | 23.39 / 212 | 28.93 / 212 | 24.13 / 212 |
| ddl-compat-table-name-case, lowercase-tables | 35.56 / 160 | 29.99 / 159 | 33.63 / 159 | 28.60 / 159 |
| matrix-identifiercase | 16.61 / 148 | 11.95 / 147 | 17.19 / 162 | 14.11 / 162 |
| matrix-unicodeidentifiers | 16.44 / 148 | 12.09 / 147 | 17.41 / 162 | 13.82 / 162 |

Calls are harness SQL client calls, not statements issued by the applier.
Do not sum these separate case times and describe the sum as a newly measured
group time. Full CI later measures the changed group.

Coverage belongs to the larger character-set group. Zero globally exclusive
lines do not prove that any of these assertions are redundant. Keep the scope
limits in the [character-set review](BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#coverage-comparison-scope).
No new per-case line-coverage comparison is claimed here.

Evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/query-identifier-workflow-review/baseline.json`: all 40 executions.
- `artifacts/query-identifier-workflow-review/source-review.json`: original SQL,
  exact encoded bytes, retained histories, query map, batches and cleanup.
- `artifacts/query-identifier-workflow-review/review.py`: source and byte audit.

## Feature ownership

| Case | Conditions owned by this case | Why another case does not replace it |
|---|---|---|
| ddl-compat-query-encodings | latin1 E9/FC and Shift-JIS 955C in Query SQL; non-ASCII table/column names; text versus binary defaults; text/binary ENUM members; CREATE-to-ALTER restarts; FULL metadata. | Ordinary UTF-8 SQL does not test original non-UTF-8 bytes or a multibyte character whose last byte is 5C. |
| ddl-compat-unicode-names | Separate precomposed/decomposed table names in mode 0; row/cache identity after UPDATE, RENAME and DROP; CREATE LIKE with a quoted reserved word; existing native conversion of the supplementary-character name to `?`. | Column/index case checks do not exercise separate table identities or retired table caches. Preserve the existing supplementary-name test; do not describe it as general support for supplementary characters in identifiers. |
| ddl-compat-table-name-case | lower_case_table_names=1; mixed-case database and table references; non-ASCII case changes; LIKE, INSERT SELECT, multi-table RENAME, row writes and two restarts. | It needs a distinct server setting. The mode-0 Unicode table-name case is excluded from this variant. |
| matrix-identifiercase | Case-insensitive column, PRIMARY KEY and index references; ALTER default/ADD/CHANGE/RENAME INDEX/DROP; following row results. | Table-name case settings and table renames do not replace column/index name lookup. |
| matrix-unicodeidentifiers | Distinct precomposed/decomposed column and index names; non-ASCII column case matching; CJK names; a quoted backtick; a 64-character CJK name; NULL/default rows; index rename and column drop. | ASCII case changes do not test exact Unicode identity, escaped quoting or length in characters. |

Keep the current `LabScenario.reason` rules. The table-name case requires
`lowercase-tables`; Unicode table names require mode 0. Keep the two DML cases
in their existing runner until a separate phase/assertion map is complete.
That runner already keeps one applier active across its phases. Do not claim it
restarts the applier after every DML phase.

Use byte comparisons for names and SQL. Swift String equality can treat
precomposed and decomposed Unicode as equal. `LabSQLName.equal` deliberately
compares UTF-8 bytes. Do not normalize the names, replace the combining mark or
use the production parser to generate the expected names.

## Encoded Query SQL and session rules

`DDLCompatibilityCases.encodedSQL` sends an ASCII script. It sets the connection
character set, converts a hex literal into that character set, then PREPAREs,
EXECUTEs and DEALLOCATEs the statement. The original byte replacements are:

- latin1 `{e}` → E9, for the table name, text/binary defaults and ENUM labels.
- latin1 `{u}` → FC, for the later binary default.
- Shift-JIS `{name}` → 955C, for the table name, defaults and later column name.

Preserve the helper, templates, replacements and PREPARE sequence. The 5C byte
is part of the Shift-JIS character. It must not become an escape delimiter.
Do not decode the templates to UTF-8 and then use that text as the source SQL.
Do not enable NO_BACKSLASH_ESCAPES or change the source SQL mode.

The phase runner prepends `LabProfile.session` before every write. This restores
UTF-8 names before an ordinary INSERT, UPDATE or DROP following an encoded write.
The encoded write then applies its own SET NAMES. Keep that order. The existing
common resets for timestamps and auto-increment settings remain unchanged.
Prepared statements are deallocated before the next write. No selected-database
or collation_database override is added by this case.

Keep `ddl-compat-query-encodings` in the shared runner's FULL metadata set.
Both ordinary and binary ENUM labels require that metadata. Do not let a minimal
metadata variant change the existing override.

## Original operations and retained states

Keep original operations 1–10 first and unchanged:

1. Encoded latin1 CREATE of table é with text, binary and ENUM defaults.
2. INSERT row 1 using defaults.
3. Encoded latin1 ALTER of the binary default to FC, after the first restart.
4. INSERT row 2 using the changed default.
5. Encoded Shift-JIS CREATE of table 表 with text and binary defaults.
6. INSERT row 1 using defaults.
7. Encoded Shift-JIS ADD of column 表 DEFAULT 7, after the second restart.
8. UPDATE that added column to 8.
9. DROP original table é.
10. DROP original table 表.

Append these independent histories. Each history executes only the original
operations listed, in their original order:

| Original operations | Retained table | State kept |
|---|---|---|
| 1–2 | qe_latin1_created_é | One row before the binary-default ALTER. |
| 1–4 | qe_latin1_altered_é | Original row 1 with E9; new row 2 with FC. |
| 5–6 | qe_sjis_created_表 | One row and the original two non-key columns. |
| 5–7 | qe_sjis_added_表 | Existing row receives the added column's value 7. |
| 5–8 | qe_sjis_updated_表 | Added column updated to 8. |

The extra ADD-state history preserves the row comparison after operation 7.
Keeping only value 8 at the end would discard the materialized default 7 result.
Likewise, the first latin1 query selects all rows. Do not map it to the later
two-row table or weaken it with a new WHERE clause.

Retarget only the qualified table-name token. In encoded templates, add an ASCII
prefix inside the table-name backticks, before the existing marker. Keep
the marker bytes in that identifier. For example, the retained latin1 CREATE
uses quoted `qe_latin1_created_{e}` while its defaults still contain `{e}`.
The retained Shift-JIS ALTER uses table `qe_sjis_added_{name}` but keeps the
added column named `{name}`. Do not globally replace marker text or the decoded
character: it also occurs in defaults, ENUM labels and column names.

The audit verifies that each retained payload differs from its original only
at the qualified table reference. Compare exact Data/byte sequences in unit
tests. Normal UTF-8 row statements must use the corresponding retained table
name while keeping the original column names and literal values.

## Final observations, phases and cleanup

Map the four old predicates without changing their selected fields, ordering,
WHERE clauses or expected strings:

1. HEX(v/b/c/eb) on qe_latin1_created_é: C3A9 / E9 / C3A9 / E9.
2. HEX(b) WHERE id=2 on qe_latin1_altered_é: FC.
3. HEX(v/b) on qe_sjis_created_表: E8A1A8 / 955C.
4. Column 表 on qe_sjis_updated_表: 8.

Add four final checks:

- Both rows of qe_latin1_altered_é, including text/binary/ENUM bytes. Row 1 must
  keep binary E9; row 2 must use FC. The text and ordinary ENUM bytes remain
  C3A9, and binary ENUM bytes remain E9.
- All row fields of qe_sjis_added_表: id 1, v E8A1A8, b 955C, added column 7.
- All row fields of qe_sjis_updated_表: the same defaults, added column 8.
- Both original names é and 表 are absent from INFORMATION_SCHEMA.TABLES.

Use eight read-only final query checks and a full schema/index/row comparison
across all five retained tables. Keep original DROP operations; do not omit them
because retained tables exist.

Body batches:

1. **create-latin1-defaults:** original operations 1–2.
2. **alter-latin1-default-and-create-sjis:** original operations 3–6, after the
   first deliberate restart.
3. **alter-sjis-drop-and-retain-results:** original operations 7–10 and all 15
   retained operations, after the second deliberate restart.

The sizes are 2/4/19, for 25 source operations. Retained histories do not add
applier restarts. Preserve one transaction per operation and source warning
capture without requiring empty warnings. Keep default engine selection on all
four profiles. No case-specific replay or no-op count needs to be changed.

Saved-state checks must find the five retained current schemas and retired
original names. Verify all 25 source GTIDs, exact file/end offsets, DONE DDL
intents and the original DROP outcomes. After saved-state assertions, drop only
the five retained tables in one cleanup operation:

```sql
DROP TABLE ddlcompat.`qe_latin1_created_é`,ddlcompat.`qe_latin1_altered_é`,ddlcompat.`qe_sjis_created_表`,ddlcompat.`qe_sjis_added_表`,ddlcompat.`qe_sjis_updated_表`;
```

The old case leaves no original table. Do not introduce a synthetic surviving
original table merely for the shared saved-schema restart. Keep that restart
and verify it still passes after cleanup.

## Focused implementation and validation

1. Convert only encodedQueryText. Keep encodedSQL, other case definitions and
   the shared runner unchanged. Use the proposal's exact source bytes.
2. Add focused unit tests for original transport/DDL bytes, ASCII transport,
   exact retained-name edits, unchanged defaults/ENUM/column markers, all four
   old predicates, added-column value 7, later value 8, original DROP operations,
   restarts, transactions, FULL metadata selection and owned cleanup. Include
   native SJIS 955C bytes explicitly. Compare Data, not canonical String equality.
3. Run the changed workflow and phase/final-observation unit tests only. Run
   selection tool tests only if their code or inventory changes. No separate
   syntax suite is needed for this lab-only slice.
4. Run only this case on forward MyISAM/default/SQL with coverage. It exercises
   an 8.4 source, a 5.7 target, binary ENUM metadata and original encoded DDL.
   Keep other profiles, variants and the full group for GitHub Actions.
5. Inspect captured Query payloads and connection charset status, not only the
   ASCII SQL trace. The proposal has four original plus eight retained encoded
   DDL statements. Verify their original bytes and following UTF-8 row sessions.
   Use the support bundle before rerunning a failed case. Preserve the evidence.
6. Inspect GTIDs/offsets, current/retired schemas, raw engines, defaults and row
   bytes, completed intents, saved-schema restart and cleanup. Confirm catalog
   and matrix selections: 183 jobs, 1,545 obligations and 182 coverage collections.
7. Record SQL client calls and case time separately from setup, coverage export
   and cleanup. Added native DDL can offset fewer waits and client startups.
   Do not claim per-case coverage parity from the old whole-group report.

Focused command:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-query-encodings --coverage"
```

Next after this implementation: review Unicode table-name workflows, then the
lower-case table-name variant. Review the two DML identifier cases with their
own phase/assertion map. Keep native collation/encoding inventories, ENUM/SET,
remaining type/value and key/index reviews, full-matrix validation, final
balancing and short PR selection in the overall consolidation plan.

## Encoded Query implementation and focused results

The case now uses three body batches of 2/4/19 operations. Its first ten source
operations remain byte-for-byte unchanged, including both original DROPs.
Five retained histories preserve the reviewed intermediate schemas and row
values. All four original predicates remain. Four further queries check old/new
binary defaults, the added column's value 7, the later value 8 and absence of
the original table names. Both restarts, FULL metadata and all selections remain.
The helper, shared runner, production code and identifier cases are unchanged.
No new replay path was added.

The forward MyISAM/default/SQL run passed all 15 named assertions. The latin1
rows retained E9 for the old binary default and FC for the new one. Text/ordinary
ENUM bytes remained C3A9; binary ENUM bytes remained E9. Shift-JIS defaults
produced text E8A1A8 and binary 955C. Retained rows confirmed both materialized
value 7 after ADD and value 8 after UPDATE. Full schema/index/row comparisons
included all five retained tables. Original é and 表 were absent.

Read-only relay inspection confirmed 12 exact encoded DDL payloads, including
four original and eight retained statements. Only qualified table-name bytes
changed in retained payloads. Query status recorded latin1 client/connection
collation IDs 8/8 or Shift-JIS IDs 13/13. All 13 following row/DROP Query events
recorded UTF-8 connection IDs 46/46. This checks the captured events as well as
the ASCII PREPARE scripts and final database results.

Saved-state inspection confirmed all 25 body groups APPLIED with exact GTIDs
and file/end offsets, the final checkpoint, five current retained schemas and
retired original names. All DDL intents were DONE. Raw table data confirmed
source InnoDB and native/target MyISAM. Saved-schema restart and cleanup passed.
Cleanup dropped only the five retained tables. The run used one fixture and
five source batches: setup, three body batches and cleanup.

| Measurement | Saved CI | Focused local run |
|---|---:|---:|
| Case seconds | 40.97 | 27.45 |
| Harness SQL client calls | 217 | 62 |

These hosts differ. The times are not a controlled speed comparison. Retained
histories add eight encoded DDL statements and real native work. Setup, coverage
export and cleanup times are separate in
`artifacts/query-identifier-workflow-review/results.json`.

The selected run executed 8,398 of 20,880 mapped first-party lines. The old
coverage belongs to the larger character-set group. This run does not establish
whole-group coverage parity or a loss from cases which did not run. The source,
byte, predicate and retained-state audits preserve the selected conditions.

All 19 selected Swift tests passed. They check original SQL/payload bytes,
ASCII transport, edits limited to qualified table names, unchanged default and
column markers, four original predicates, added-default/update outcomes, DROP,
cleanup and per-write UTF-8 session setup. Formatting, source-preservation,
catalog and matrix checks passed. The matrix retains 183 jobs, 1,545 obligations
and 182 coverage collections, with unchanged exclusions and groups. Selection
tool tests were not repeated because their code and inventory did not change.
No other case/profile, full suite, benchmark or syntax suite ran locally.

Evidence:

- `artifacts/lab/20261104T061357Z-8e6b289b/result.json`
- `artifacts/query-identifier-workflow-review/results.json`
- `artifacts/query-identifier-workflow-review/state-results.json`
- `artifacts/query-identifier-workflow-review/query-byte-results.json`
- `artifacts/query-identifier-workflow-review/relay-records.jsonl`
- `artifacts/query-identifier-workflow-review/source-preservation.json`
- `artifacts/query-identifier-workflow-review/matrix-comparison.json`
- `artifacts/query-identifier-workflow-review/unit.log`

The [Unicode table-name workflow](BETA7_UNICODE_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed the forward case with exact name bytes and retained row results. The
[lower-case table-name workflow](BETA7_LOWERCASE_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed its forward mode-1 case. The [ASCII DML identifier pilot](BETA7_DML_IDENTIFIER_WORKFLOW_REVIEW.md#pilot-implementation-and-focused-results)
passed its forward case with all 16 named assertions. Next: convert only
matrix-unicodeidentifiers with the same helper. Keep exact Unicode name bytes,
NULL/default rows and index identities. Native inventories, ENUM/SET, remaining
type/value and key/index reviews, full-matrix validation, final balancing and
short PR selection remain in the overall plan.
