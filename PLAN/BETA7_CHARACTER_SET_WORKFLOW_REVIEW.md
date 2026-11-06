# Character sets and collations: workflow review

## Decision

Keep the 21 case IDs in `character-sets-collations` while converting their
execution in slices. The source review found distinct assertions, not a safe
case deletion. Start with `ddl-compat-table-charset` and
`ddl-compat-compound-charset`. Run them together in one forward fixture.

Keep their 16 original source operations first within each case, seven explicit
predicates, four live restarts, source transaction counts and all four profiles.
Neither case has offline replay today. Add no replay path for this conversion.
Use retained tables to keep overwritten column metadata and row bytes available
for final observations. No production encoding or parser change belongs here.

The initial review used saved evidence. The first pair is now converted; focused
results follow below. The temporary-table conversion was committed as `b5ed288`.

## Names and feature boundaries

Consult the MySQL documentation before naming features. Use
[Table Character Set and Collation](https://dev.mysql.com/doc/refman/8.4/en/charset-table.html),
[Column Character Set Conversion](https://dev.mysql.com/doc/refman/8.4/en/charset-conversion.html)
and [Connection Character Sets and Collations](https://dev.mysql.com/doc/refman/8.4/en/charset-connection.html).
Keep table defaults, conversion of existing columns and source SQL encoding as
separate features. They have different metadata and byte checks.

Use these first-slice titles:

- **Table character set and collation: defaults, new columns and CREATE TABLE ... LIKE**.
- **Column character set conversion: compound CONVERT and table defaults**.

The area also contains identifier rules, ENUM/SET values and binary/zero-length
fields. Their names and placement need a later review. Keep existing case IDs
and scheduling now. Do not create more jobs merely to give features clearer
names. Use feature titles for reader-facing descriptions; do not use an opaque
number or the word `choices` as the only explanation of an ENUM/SET test.

## Saved timing, SQL and coverage

CI run `40454033524`, commit `efb3458`, has no failed or missing shards and no
missing coverage. It contains 77 passing default/SQL executions for this area.
There are 21 IDs, but not every ID applies to every default profile:

- `table-name-case` requires the `lowercase-tables` variant and is excluded from default.
- `charset-defaults` excludes the 8.4 source, which rejects that old DEFAULT syntax.
- `legacybinaryset` excludes profiles involving 8.4, with native dictionary error 3507.

At review time, the four encoding-DDL case definitions in
`TableEncodingCases.swift` matched the saved commit. Their saved forward
measurements are:

| Case | Original operations / predicates | Restarts before operations | Seconds | SQL trace calls |
|---|---|---|---:|---:|
| `table-charset` | 9 / 4 | 4, 8 | 37.39 | 184 |
| `compound-charset` | 7 / 3 | 4, 6 | 34.25 | 151 |
| `charset-conversion` | 10 / 6 | 4, 7, 9 | 47.30 | 222 |
| `charset-defaults` | 10 / 4 | 6, 9 | Not applicable | Not applicable |

On reverse, DEFAULT used 30.87s and 168 calls. On forward, the proposed pair
used 335 calls. Table-default changes made 11 schema-comparison requests per
role; compound conversion made nine per role. These match their body operations
plus two setup operations. Reducing repeated observation requests is a concrete
target. These counts are harness mysql client calls, not target applier SQL.

### Coverage comparison scope

The saved test-value report shows zero globally exclusive lines for this area.
Its comparison includes all other measured rows, including copies of this area
on other profiles and variants. Zero in that report does not establish that
another feature replaces these tests.

For this review, compare each default/SQL area only with other default
correctness groups on the same profile. Exclude this area from that baseline:

| Profile | Area lines hit | Lines absent from other default correctness groups | Of these, DDLTableEncoding.swift |
|---|---:|---:|---:|
| mysql84-to-mysql57-myisam | 9,743 | 96 | 53 |
| mysql57-to-mysql84-innodb | 9,975 | 191 | 143 |
| mysql57-to-mysql57-myisam | 9,853 | 188 | 143 |
| mysql57-to-mysql57-innodb | 9,941 | 188 | 143 |

The largest individual overlap is with `table-column-index-changes`: 95.11–96.20%
of this area's lines. The remaining lines include table encoding, schema changes,
DDL parsing and SQL client encoding. Their exact file/line sets are saved.
The 5.7-source comparison includes more table-encoding paths than forward.

This is historical group-level coverage. It cannot attribute a line to one case,
prove branch/value equivalence, or establish the new post-conversion baseline.
Earlier migrations changed other groups after that run. The raw unit line sets
are not available in this review directory, so no new unit-plus-area comparison
is claimed. Keep native result assertions and use the later full CI run for the
updated group comparison.

## What each feature adds

| Feature | Existing case IDs | Conditions to preserve |
|---|---|---|
| Table defaults and compound conversion | `ddl-compat-table-charset`, `ddl-compat-compound-charset` | Both ALTER clause orders; existing versus newly added column collations; CONVERT collation distinct from later table default; LIKE inheritance; following row bytes. First conversion slice. |
| Conversion of existing columns | `ddl-compat-charset-conversion` | TEXT widening; defaults; ENUM/SET labels; generated column; prefix index; binary bytes; conversion to binary and later text conversion; three restarts. Keep forced FULL row metadata. |
| Old DEFAULT syntax | `ddl-compat-charset-defaults` | Database inheritance; no selected database versus USE; session collation_database override; 5.7-to-8.4 syntax translation; native 8.4-source exclusion. |
| Encoded source SQL | `ddl-compat-query-encodings` | Exact latin1 and Shift-JIS Query bytes; 0x5c as part of a multibyte character; encoded names; text/binary/ENUM defaults; ALTER; two restarts; FULL metadata. |
| Identifier identity and case | `ddl-compat-unicode-names`, `ddl-compat-table-name-case`, `matrix-identifiercase`, `matrix-unicodeidentifiers` | Composed/decomposed names; table versus column/index case rules; quoted reserved words; long names; Unicode name conversion; rename and DROP identity; lower_case_table_names=1. These are not interchangeable. |
| Collation inventory | `matrix-collations` | Independently listed native collation IDs; defaults; non-ASCII and NUL/trailing-space bytes; case-insensitive primary-key matching; collation change and NULL. Do not derive test membership from the apply registry. |
| Native encoding byte vectors | `matrix-nativeencodings` | Independent native byte vectors for CHAR/VARCHAR/TEXT and multibyte primary keys; CHAR trimming; defaults; NULL; added gb18030 column. UTF-8/latin1 cases do not replace this inventory. |
| Character and binary values | `matrix-encodings`, `matrix-widestrings` | latin1/ascii/utf8 and binary distinctions; case-insensitive key updates; NUL/high bytes; CHAR padding; JSON DECIMAL subtype; 18,000-byte values and size transitions. |
| ENUM and SET | `matrix-exactchoices`, `matrix-choiceboundaries`, `matrix-binarychoices`, `matrix-legacybinaryset`, `matrix-enumzero`, `matrix-choices`, `matrix-widechoices` | Exact label bytes; quoting and trailing spaces; binary members; native exclusions; ordinal zero versus empty member versus NULL; numeric versus quoted defaults; ordinal 256 and 64-bit SET masks. Separate overlap review required. |
| Zero-length fields | `matrix-zerowidth` | CHAR/BINARY/VARCHAR/VARBINARY length zero, NULL versus empty, fixed-width Unicode, widening and shrinking. A normal empty-string INSERT does not replace this sequence. |

The ordinary DML runner already keeps one applier running across these cases.
It currently waits, reads the phase predicate and compares schema/rows after each
phase. Do not describe that cost as an applier restart after every phase. Later
DML conversion needs retained outcomes for overwritten/deleted values, not the
removal of distinct byte or ordinal checks.

## Keep collation translation and collision tests separate

`collation-translation-collisions` uses `SharedCollation.swift` and a forward-only
compatibility mapping. It also changes the target configuration and deliberately
blocks on a uniqueness collision. Its native and external results differ by
policy. Keep that fixture boundary and its named subcases. The ordinary area
must not enable translation merely to make a positive encoding case pass.

The cleanup workflow checks dynamic CREATE/LIKE/INSERT SELECT/RENAME behavior,
retained mapping policy and changed/removed-policy restart refusal. The collision
workflow checks NO PAD source values, target error 1062, a stopped checkpoint
and pending rows. Ordinary `matrix-collations` values do not replace those checks.
No collision or mapping test is removed or rerun by the first slice.

## First slice: table defaults

Keep all nine original operations first in `table-charset`, through DELETE of
original row 1. Append independent histories in `ddlcompat`:

| Original prefix | Retained table | Required old observations |
|---|---|---|
| 1–3 | `tc_after_default` | Exactly two collated columns: v latin1_bin, next_v utf8mb4_bin; row bytes `636166E9`, `6E6577`. |
| 1–5 | `tc_after_update` | Updated v/next_v/last_v bytes `E974E9`, `C3A974C3A9`, `E974E9`. |
| Original final objects | `t`, `copy` | Original copy TABLE_COLLATION remains latin1_swedish_ci; original t is empty; LIKE copy keeps its inserted default row. |

Replace qualified table references consistently in copied SQL. Keep all literal
text, ALTER clause order, types and defaults. Map the old INFORMATION_SCHEMA
TABLE_NAME predicate to `tc_after_default`; it selects all collated columns and
would fail if moved to the later three-column table. The updated bytes require
the second history because original row 1 is deleted. Keep the old LIKE table
collation predicate on original `copy`.

Add explicit final metadata checks for original t's table default and all three
column collations. Add final row checks for t's empty state and copy's default
row if they make the retained behavior clearer. These supplement full schema/row
comparison; they do not replace any of the four old predicates.

This case has 17 source operations in batches of 3, 4 and 10. Preserve restarts
before original operations 4 and 8. Cleanup uses one statement:

```sql
DROP TABLE ddlcompat.tc_after_default,ddlcompat.tc_after_update;
```

Leave original `t` and `copy` for the existing saved-schema restart.

## First slice: compound conversion and defaults

Keep all seven original operations first. Append original operations 1–3 with
qualified `ddlcompat.t` references changed to `ddlcompat.cc_after_convert`.
The copy must execute the original CONVERT/default/ADD statement. Do not replace
it with a CREATE declaring the desired final collations.

Keep the old table-default predicate on original t: utf8mb4_general_ci. Map the
old two-column collation query to the retained table; both v and n must use
utf8mb4_bin. Keep the old `follows` column predicate on original t; it must use
utf8mb4_general_ci. The retained table has two character columns; original t
also has `follows` and therefore cannot replace that old two-column result.

Add an explicit final original-row byte query for v, n and follows. The existing
UPDATE and DELETE leave one row; compare it with native and the expected bytes.
Keep the default `'café'`, later value `'été'`, `'new'` and `'later'` literals.

This case has ten source operations in batches of 3, 2 and 5. Preserve restarts
before original operations 4 and 6. Cleanup drops only
`ddlcompat.cc_after_convert`. No new database, replay or lifecycle step is needed.

## Later slices and session hazards

1. Review `charset-conversion` independently. Retain type transitions and earlier
   bytes before UPDATE/DELETE or conversion to binary removes them. Keep all
   six predicates, three restarts, generated values, labels and FULL metadata.
2. Review `charset-defaults` with an explicit session map. The old runner opened
   a new client for each operation. Some operations have no selected database;
   later ones USE ddlcompat and set collation_database. A shared client can leak
   that override into subsequent statements or retained histories. Preserve both
   the no-selected-database context and logged override. Do not prepend USE to
   every operation as a shortcut. Define phase/session boundaries before coding.
3. Review encoded SQL and identifier cases. Preserve ASCII hex transport through
   PREPARE, logged connection settings, original bytes and exact Unicode identity.
   Do not convert the encoded test to ordinary UTF-8 text for easier copying.
   Keep the separate lower-case-table fixture and encoded CREATE-to-ALTER restarts.
4. Review collation/encoding inventories and ENUM/SET groups. Map every numeric
   ID, byte vector, boundary and expected value before combining cases. Shared
   setup and final observations can reduce client calls without deleting members.
   Move identifier and binary/type cases only with an explicit feature-owner map.
5. Review the mapping/collision area separately. Keep policy/configuration and
   failure/restart boundaries. Then use full instrumented CI to compare the new
   logical groups and decide final scheduling and short PR selections.

These are ordered reviews, not authorization to merge all 21 cases into a single
SQL script or remove the matrix cases based on line overlap.

## First-slice validation

1. Convert only `table-charset` and `compound-charset` with existing phase/final
   helpers. Preserve original SQL first, all seven predicates, four restarts,
   source transaction counts, profile selections and default engine behavior.
2. Add focused lab unit tests for retained dependencies, metadata query scopes,
   both ALTER orders, exact HEX expectations, restart positions and cleanup.
   Run only affected workflow and phase/final-observation tests. No syntax suite.
3. Run the pair once on forward MyISAM/default/SQL with coverage. This slice adds
   no 5.7-only source syntax or session override. Existing shared helpers have
   representative InnoDB validation; do not repeat unchanged profiles locally.
   Read the support bundle before a failed-case rerun.
4. Check DONE DDL intents, applied groups, exact source GTIDs/offsets, retained
   schemas, raw engine metadata, saved-schema restart and cleanup. Compare matrix
   and catalog selection. Record setup, case, coverage export, cleanup and SQL
   client counts. Keep whole-group timing and coverage comparison for full CI.

Focused command:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-table-charset --case ddl-compat-compound-charset --coverage"
```

No other case/profile, full suite, benchmark, mapping/collision run or syntax
suite is needed for the first slice. Keep all original CI selections. The review
and proposal artifacts are under `artifacts/charset-workflow-review/`: baseline,
area-review, coverage-review, source-review and pilot-proposal JSON files, plus
`review.py`.

## First-slice implementation and focused results

`table-charset` and `compound-charset` passed together in one forward
MyISAM/default/SQL fixture with coverage. The cases retain all 16 original source
operations first, all seven old predicates and all four live restart positions.
No production apply or syntax code changed. The DEFAULT-syntax and full-conversion
case definitions remain byte-for-byte unchanged from saved CI.

Table defaults now use 17 source operations in batches of 3, 4 and 10. Compound
conversion uses ten operations in batches of 3, 2 and 5. Every operation retains
one source transaction. The fixture has ten source phases: six body batches,
two setup batches and two retained-table cleanup batches. Neither case gained
an offline replay path or another lifecycle step.

All 26 named assertions passed. Table defaults passed 15, and compound conversion
passed 11. The original two-column metadata checks still read the correct retained
state. Original data/default literals and expected HEX values remain intact.
Additional explicit checks passed for the final table default, three original
column collations, deletion of original t's row, LIKE defaults and the final
compound-conversion row.

The final table-default case kept latin1_bin on v and last_v, utf8mb4_bin on
next_v, and latin1_swedish_ci as the table default. LIKE copied that table
default and inserted row 2 with the expected default bytes. The compound case
kept utf8mb4_bin on converted v/n, while table default and later follows used
utf8mb4_general_ci. The final row retained the expected UTF-8 bytes.

| Case | Saved CI calls | Local calls | Saved CI seconds | Local seconds | Named assertions |
|---|---:|---:|---:|---:|---:|
| Table defaults | 184 | 56 | 37.39 | 27.75 | 15 |
| Compound conversion/defaults | 151 | 55 | 34.25 | 25.20 | 11 |

SQL trace calls fell from 335 to 111 for this pair. Old times came from CI and
new times from a local machine; they do not establish a controlled speed
comparison or a new whole-area time. Local fixture setup took 14.89s, including
11.94s for container startup and 2.42s for database setup. Coverage export took
4.83s and fixture cleanup took 10.87s. Image build time is separate.

Read-only SQLite checks confirmed STOPPED state, no active GTID, all body groups
APPLIED, every source GTID/file offset, and all DDL intents DONE. The saved
current schemas contained exactly t/copy plus the two retained tables for table
defaults, and t plus the retained table for compound conversion. Raw metadata
confirmed InnoDB source tables and MyISAM native/target tables. Cleanup removed
only the three owned retained tables. Original objects remained intact within
each case. The shared saved-schema restart and fixture cleanup passed.

Combined runtime coverage for this pair was 7,948 of 20,880 mapped Swift lines
(38.07%). This is a narrower selection than the saved 21-ID area. It cannot
establish whole-area coverage parity or a loss from cases which were not run.
The source and predicate audit preserves the selected original conditions.

All 17 selected Swift tests and 18 feature/migration tool tests passed.
Formatting, catalog and matrix checks passed. The matrix retains 183 jobs,
1,545 catalog obligations and 182 instrumented collections. Case ordering,
profile exclusions and group selection remain unchanged. No other case/profile,
full suite, benchmark, mapping/collision run or syntax suite ran for this slice.

Evidence:

- `artifacts/lab/20261103T233917Z-69acbce2/result.json`
- `artifacts/charset-workflow-review/results.json`
- `artifacts/charset-workflow-review/state-results.json`
- `artifacts/charset-workflow-review/source-preservation.json`
- `artifacts/charset-workflow-review/matrix-comparison.json`
- `artifacts/charset-workflow-review/unit.log`

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
The [type/value workflow results](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md#temporal-fractional-second-and-automatic-value-implementation-results)
record fifteen completed conversions. All focused checks passed.
Next: binarydefaults, textdefaults, fixed and lob.
Keep all seven IDs and their metadata/version rules.
Keep remaining type/value and key/index work, full-matrix validation, final
balancing and short PR selection later.
