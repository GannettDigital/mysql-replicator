# Character sets and collations: inventory workflow review

Status: both inventory workflows passed their focused forward tests. The
collation pilot is committed as `6574be6`. The [ENUM/SET workflows](BETA7_ENUM_SET_WORKFLOW_REVIEW.md#legacy-binary-set-implementation-and-local-completion)
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

Keep both case IDs, all inventory members and existing profile/variant selections.
These cases test different conditions. They already share the MySQL fixture and
running applier with the character-sets-collations group. Combining them into one
wide table would mix their schemas and metadata inputs without removing fixture
startup. Convert their repeated observations; do not add or split CI jobs here.

Use DMLExecutionWorkflow to retain intermediate rows and schemas until final
queries. Keep the original definitions and phases. Neither case has setup SQL,
a JSON diff check, a replacement case or a special metadata override. Both fit
the helper's existing prerequisites. Keep metadata-labels-defaults membership:
its cold metadata reads use the same definitions and initial INSERT/check.

The initial review used source and saved measurements without builds or tests.
The implementation results below confirm both workflows' new rows and counts.
No replication implementation change belongs in this work.

## MySQL names and sources

Consult MySQL documentation before naming a feature. Use
[Character Sets and Collations in MySQL](https://dev.mysql.com/doc/refman/8.4/en/charset-mysql.html)
and the [INFORMATION_SCHEMA COLLATIONS table](https://dev.mysql.com/doc/refman/8.4/en/information-schema-collations-table.html).
The latter distinguishes a collation ID from its name and character set.

Use one shared title for inventory and execution:

- matrix-collations: **Character sets and collations: collation IDs, stored bytes and case-insensitive keys**.
- matrix-nativeencodings: **Character sets: CHAR, VARCHAR and TEXT byte values and multibyte keys**.

Keep IDs unchanged. Do not call either case a complete test of all MySQL
collations, languages, conversions or invalid byte sequences.

The review checked the local pinned MySQL 5.7.44 and 8.4 source trees:
strings/ctype-extra.c, ctype-utf8.c, ctype-uca.c and the other ctype files, plus
the corresponding 8.4 .cc files. All selected collation IDs match both trees.
The source audit resolves the native MY_UTF8MB3/MY_UTF8MB4 name macros and the
8.4 utf8mb3 spelling. It does not consult the replicator's apply registry.
The pins are recorded in tests/Upstream/mysql57.json and
tests/DDLCoverage/upstream.json. The review source check is narrower than a
complete server COLLATIONS inventory check: compiled definitions alone do not
prove which optional collations a server exposes.

## Saved results and coverage limits

Both Swift fixture files are unchanged from CI commit efb3458. Saved CI run
40454033524 has complete measurements, no failed/missing shards and no missing
coverage. It contains ten passing SQL executions per case: four default, four
lowercase-tables and two forward positioning/metadata variants.

| Default profile | matrix-collations seconds / calls | matrix-nativeencodings seconds / calls |
|---|---:|---:|
| mysql84-to-mysql57-myisam | 12.13 / 104 | 15.34 / 134 |
| mysql57-to-mysql84-innodb | 8.97 / 103 | 11.21 / 132 |
| mysql57-to-mysql57-myisam | 11.49 / 104 | 14.38 / 133 |
| mysql57-to-mysql57-innodb | 9.24 / 104 | 11.92 / 134 |

Calls are harness MySQL client calls, not target applier SQL. The saved runs
select the whole group, so later cases compare more accumulated tables in poc.
A single-case local pilot has different inputs. Record both measurements without
claiming a controlled speed gain.

Coverage is collected for the group, not these individual cases. Use the
[existing same-profile coverage comparison](BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#coverage-comparison-scope).
It finds 96–191 group lines absent from other default correctness groups.
It cannot assign those lines to these inventories. Line overlap does not prove
that one numeric ID, encoding or value can replace another.

Evidence is saved under artifacts/native-encoding-inventory-review/:

- baseline.json: 20 passing saved executions and SQL call categories.
- inventory.json: every collation ID, byte vector, default and upstream source.
- source-review.json: expanded original SQL/checks, proposed batches and counts.
- review.py: source equality, native ID map and saved-result checks.

## Collation ID map

Keep every listed member. The fixture uses the 5.7 names. MySQL 8.4 uses
utf8mb3 names for the utf8 entries; the numeric IDs remain the same. Normalize
only that documented alias when comparing names. Do not change an ID or choose
a different collation to make a comparison pass.

| ID | Character set | Collation |
|---:|---|---|
| 5 | latin1 | latin1_german1_ci |
| 8 | latin1 | latin1_swedish_ci |
| 11 | ascii | ascii_general_ci |
| 15 | latin1 | latin1_danish_ci |
| 31 | latin1 | latin1_german2_ci |
| 33 | utf8 | utf8_general_ci |
| 45 | utf8mb4 | utf8mb4_general_ci |
| 46 | utf8mb4 | utf8mb4_bin |
| 47 | latin1 | latin1_bin |
| 48 | latin1 | latin1_general_ci |
| 49 | latin1 | latin1_general_cs |
| 65 | ascii | ascii_bin |
| 83 | utf8 | utf8_bin |
| 94 | latin1 | latin1_spanish_ci |
| 223 | utf8 | utf8_general_mysql500_ci |

The following suffixes identify paired utf8 and utf8mb4 collations. Prefix the
suffix with utf8_ or utf8mb4_ to obtain the full 5.7 name.

| Suffix | utf8 ID | utf8mb4 ID |
|---|---:|---:|
| unicode_ci | 192 | 224 |
| icelandic_ci | 193 | 225 |
| latvian_ci | 194 | 226 |
| romanian_ci | 195 | 227 |
| slovenian_ci | 196 | 228 |
| polish_ci | 197 | 229 |
| estonian_ci | 198 | 230 |
| spanish_ci | 199 | 231 |
| swedish_ci | 200 | 232 |
| turkish_ci | 201 | 233 |
| czech_ci | 202 | 234 |
| danish_ci | 203 | 235 |
| lithuanian_ci | 204 | 236 |
| slovak_ci | 205 | 237 |
| spanish2_ci | 206 | 238 |
| roman_ci | 207 | 239 |
| persian_ci | 208 | 240 |
| esperanto_ci | 209 | 241 |
| hungarian_ci | 210 | 242 |
| sinhala_ci | 211 | 243 |
| german2_ci | 212 | 244 |
| croatian_ci | 213 | 245 |
| unicode_520_ci | 214 | 246 |
| vietnamese_ci | 215 | 247 |

Total: 8 latin1, 2 ASCII, 27 utf8 and 26 utf8mb4 entries. The PRIMARY KEY
uses utf8mb4_unicode_520_ci, ID 246. After MODIFY, only c49 changes its
collation to latin1_spanish_ci, ID 94. c94 already uses that collation; keep
both columns and check each result. The other 62 member mappings stay unchanged.
After MODIFY there are still 63 member columns, but only 62 distinct member IDs:
ID 94 occurs twice. Compare ordered column mappings, not just a set of IDs.

| Character set | Updated bytes for each VARCHAR column | Initial default bytes |
|---|---|---|
| ASCII | 410020 | 41 |
| latin1 | E900FF20 | 41 |
| utf8 / utf8mb4 | C3A9E4B8AD0020 | 41 |

These inputs include NUL, non-ASCII bytes and a trailing space. They check
storage and transport for every listed collation. They do not establish every
language-specific comparison or sort rule. Keep the existing case-insensitive
PRIMARY KEY conditions as a separate assertion.

## Native character-set byte map

Each row below produces one CHAR(4), one VARCHAR(12) and one TEXT column.
Keep all 36 rows and all 108 fields. These constants come from the fixture;
do not generate them with the production converter. The two pinned source
trees confirm each selected collation name and ID. That source check does not
replace native value assertions.

| Character set | Selected collation | ID | VARCHAR/TEXT input and stored bytes | Retrieved CHAR bytes |
|---|---|---:|---|---|
| armscii8 | armscii8_bin | 64 | B20020 | B200 |
| big5 | big5_bin | 84 | A4A40020 | A4A400 |
| cp1250 | cp1250_polish_ci | 99 | C00020 | C000 |
| cp1251 | cp1251_general_cs | 52 | C00020 | C000 |
| cp1256 | cp1256_bin | 67 | C10020 | C100 |
| cp1257 | cp1257_general_ci | 59 | C00020 | C000 |
| cp850 | cp850_bin | 80 | 820020 | 8200 |
| cp852 | cp852_bin | 81 | 800020 | 8000 |
| cp866 | cp866_bin | 68 | 800020 | 8000 |
| cp932 | cp932_bin | 96 | 82A00020 | 82A000 |
| dec8 | dec8_bin | 69 | C40020 | C400 |
| eucjpms | eucjpms_bin | 98 | A4A20020 | A4A200 |
| euckr | euckr_bin | 85 | B0A10020 | B0A100 |
| gb18030 | gb18030_unicode_520_ci | 250 | D6D00020 | D6D000 |
| gb2312 | gb2312_bin | 86 | D6D00020 | D6D000 |
| gbk | gbk_bin | 87 | D6D00020 | D6D000 |
| geostd8 | geostd8_bin | 93 | C00020 | C000 |
| greek | greek_bin | 70 | C10020 | C100 |
| hebrew | hebrew_bin | 71 | E00020 | E000 |
| hp8 | hp8_bin | 72 | C40020 | C400 |
| keybcs2 | keybcs2_bin | 73 | 800020 | 8000 |
| koi8r | koi8r_bin | 74 | C10020 | C100 |
| koi8u | koi8u_bin | 75 | C10020 | C100 |
| latin2 | latin2_bin | 77 | A10020 | A100 |
| latin5 | latin5_bin | 78 | D00020 | D000 |
| latin7 | latin7_bin | 79 | C00020 | C000 |
| macce | macce_bin | 43 | 800020 | 8000 |
| macroman | macroman_bin | 53 | 800020 | 8000 |
| sjis | sjis_bin | 88 | 82A00020 | 82A000 |
| swe7 | swe7_bin | 82 | 5B0020 | 5B00 |
| tis620 | tis620_bin | 89 | A10020 | A100 |
| ucs2 | ucs2_general_mysql500_ci | 159 | 202000000020 | 20200000 |
| ujis | ujis_bin | 91 | A4A20020 | A4A200 |
| utf16 | utf16_vietnamese_ci | 124 | D83DDE00202000000020 | D83DDE0020200000 |
| utf16le | utf16le_bin | 62 | 0020202000002000 | 002020200000 |
| utf32 | utf32_vietnamese_ci | 183 | 000020200000000000000020 | 0000202000000000 |

Initial c_* defaults store A as 0041 for ucs2/utf16, 4100 for utf16le,
00000041 for utf32 and 41 for the other listed sets. Initial
v_* and t_* fields are NULL. The CHAR result removes trailing encoded spaces;
VARCHAR/TEXT keep the listed suffix. Internal NUL bytes remain.

The PRIMARY KEY uses utf16_bin, ID 55. Check the stored UTF-16 bytes for first,
changed and second. ALTER adds extra with gb18030_bin, ID 249; its value is
9439FC36. Do not replace this four-byte value with the earlier gb18030 vector
D6D00020 or remove the multibyte primary key.

## Source phases and retained results

Before conversion, both cases created one table, then ran four phase scripts.
The applier stayed running throughout. Each script opened a new source client,
set USE poc, waited and compared the database. There was no per-case restart.

| Operation | Source transactions |
|---|---:|
| CREATE original table | 1 |
| INSERT two rows | 1 |
| UPDATE the first row and its key | 1 |
| ALTER then UPDATE the second row | 2 |
| DELETE the changed first row | 1 |
| Original total | 6 |

Keep phase counts 1/1/2/1. Do not reuse the identifier cases' 1/2/3/2 counts.
Keep the original ALTER/UPDATE scripts intact, with implicit DDL commits and
no added BEGIN/COMMIT. All original operations run first in their current order.
Create the original table first in preparation, then the three retained tables.
Copied histories follow the four original scripts in the body batch.

### Collation histories

| Phase prefix | Table | Results to retain |
|---|---|---|
| 1 | poc.cl_after_insert | first and second; all 63 values default to A. Keep the initial ID/name map, including c49 at ID 49. |
| 1–2 | poc.cl_after_update | Stored key FirstX; every updated hex vector; second keeps all defaults. Keep the original c49 collation. |
| 1–3 | poc.cl_after_modify | Same updated FirstX row; second has c49=NULL. c49 now uses ID 94, while all other member mappings remain. |
| Original final table | poc.matrix_collations | Only second; c49=NULL and all other member fields still default A. |

Move predicates 1/2/3 to their retained table. Keep predicate 4 on the original.
Change only the controlled qualified table reference. Keep all original mixed-case
key predicates: UPDATE matches FIRST, stored key becomes FirstX, its check uses
firstx and DELETE matches FIRSTX. These test case-insensitive key matching; a
binary or lowercased replacement key would change the condition.

Add four full ordered HEX row queries. Include HEX(id) so stored key case cannot
be hidden by the collation. Use IFNULL(HEX(column),'NULL') to distinguish NULL
from empty bytes. Build expected values from the fixed map, not from the target
result or production converter. Use explicit binary ordering for read-only result
queries; leave the original write predicates unchanged.

Add explicit numeric collation metadata checks before and after MODIFY. Join
column collation names with INFORMATION_SCHEMA.COLLATIONS, and compare ID,
character set and collation name in column order. Include the key's ID 246.
Use only the utf8/utf8mb3 alias normalization described above. Do not infer the
current ID from the column suffix: c49 becomes ID 94. Full schema comparisons
on all four tables also keep defaults and the original VARCHAR lengths.

### Character-set histories

| Phase prefix | Table | Results to retain |
|---|---|---|
| 1 | poc.ne_after_insert | first and second; all 36 c_* defaults in native encoding; all v_*/t_* NULL. |
| 1–2 | poc.ne_after_update | changed has every listed CHAR/VARCHAR/TEXT vector; second retains defaults and NULLs. |
| 1–3 | poc.ne_after_add | changed keeps every vector and extra=NULL; second has all 108 old fields NULL and extra=9439FC36. |
| Original final table | poc.matrix_nativeencodings | Only second, with all 108 old fields NULL and the added four-byte value. |

Keep predicates 1/2/3 on the corresponding histories and predicate 4 on the
original table. Add four full ordered HEX row queries with explicit NULL markers.
Keep all 108 fields. Check the CHAR result separately from VARCHAR/TEXT; their
trailing-space results differ. Include HEX(id) to confirm UTF-16 key storage:

| Key text | Stored UTF-16 bytes |
|---|---|
| first | 00660069007200730074 |
| changed | 006300680061006E006700650064 |
| second | 007300650063006F006E0064 |

Add explicit character-set/collation ID maps before and after ADD. Check all
three column kinds for each of the 36 entries, the key at ID 55 and extra at
ID 249. Full schema comparison keeps CHAR(4), VARCHAR(12), TEXT and defaults.
Do not reduce this fixture to one column per character set.

## Batches, state and failure handling

The existing helper can describe both cases without a new runner. Keep the two
case IDs and their own tables. Do not set replicatedReplacement.

Per case:

| Batch | Client write requests | Source transactions |
|---|---:|---:|
| Preparation | 4 | 4 |
| Body | 10 | 12 |
| Before cleanup | 14 | 16 |
| Cleanup | 1 | 1 |

Body counts are original 1/1/2/1, then retained prefixes 1, 1/1 and 1/1/2.
Expected before-cleanup deltas are 16 applied transactions, 6 DDL and 14 changed
rows. After cleanup: 17 transactions, 7 DDL and 14 rows. Both focused inventory
runs confirmed these counts.

Preparation uses the exact original definition and the existing table default
utf8mb4/utf8mb4_bin. Keep each body request's USE poc and source-session setup.
Cleanup is one DROP TABLE listing only that case's three retained tables.
The original matrix table remains for later shared checks.

Keep body and cleanup checkpoint assertions for exact GTID sets, file offsets
and counters. Preserve every multi-GTID request's interval. Read final SQLite
state only after the existing shared stop. Check all expanded GTIDs are APPLIED,
all DDL/row intents are DONE, latest retained schemas have the correct IDs/bytes,
and cleanup retired only owned histories. Compare the last GTID of each request
with its saved end offset. Preserve the shared saved-schema restart.

Add no per-case drain, restart, snapshot or offline replay. If a test fails, use
the printed support-bundle path first. Read failure.json and bundle.json, then
query bundled SQLite read-only. Preserve the failed evidence before rerunning.

## Implementation order and local validation

1. Convert only matrix-collations. Keep its original fixture inputs and four
   predicates. Add the three retained histories, complete row/ID maps and shared
   title. Keep matrix-nativeencodings unchanged for this pilot.
2. Add focused lab unit tests for all 63 IDs, defaults and byte vectors, exact
   original scripts, mixed-case key predicates, c49 49→94, retained queries,
   4/12/1 transaction counts and cleanup ownership. Include the existing helper,
   identifier and metadata-discovery tests. Update identifier tests which
   enumerate the opt-in cases. Do not change the production apply registry.
3. Check catalog and matrix membership. Keep 183 jobs, 1,545 catalog obligations
   and 182 instrumented collections. Check descriptions share the same title.
   Run selection tool tests only if their code or wiring changes. Do not build
   or run the syntax suite for fixture-only changes.
4. Run one forward/default/SQL collation case with coverage. Inspect source
   boundaries, rows, all numeric IDs, saved schemas, cleanup and shared restart.
   Record case time, calls and setup/coverage/cleanup costs. Keep other profiles,
   variants and full-group validation for GitHub Actions.
5. After the pilot passes, convert only matrix-nativeencodings with the same
   helper. Add focused unit checks for all 36 fixed vectors and 108 fields,
   native default A bytes, CHAR trimming, NULLs, UTF-16 key bytes and gb18030
   extra. Run its single forward/default/SQL case with coverage and inspect state.
6. Review ENUM/SET overlap next. Keep each label, byte and ordinal boundary map
   before combining execution. Remaining type/value and key/index reviews,
   full-matrix validation, final balancing and short PR selection remain later.

Commands, after each separate implementation:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-collations --coverage"
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-nativeencodings --coverage"
```

No test is removed by this review. A future group-level measurement must use the
same selected cases and comparable inputs before claiming coverage or timing
savings. Do not rerun all profiles locally for these ordinary value workflows.

## Collation pilot implementation and focused results

Steps 1–4 are complete for matrix-collations. This pilot added only that case to
the existing DML workflow helper. At that step, the helper, shared runner,
metadata-discovery selection and all other source cases were unchanged. The original 63-member list,
definition generation, four scripts and four predicates remain unchanged.
The case shares its title between catalog inventory and execution.

Preparation creates the original and three retained tables with the original
definition. The body runs all original scripts first, then the retained prefixes.
Four ordered HEX row queries check every member, default, NULL result and stored
key case. Two metadata queries check the PRIMARY KEY and all member columns
before and after MODIFY. They normalize only the utf8/utf8mb3 name alias.
The old predicates remain separate named assertions. Full schema/row comparisons
cover all four tables. Cleanup drops only the three retained histories.

Focused checks passed:

- 24 Swift tests: six collation tests, four helper tests, five ASCII identifier
  tests, six Unicode identifier tests and three metadata-discovery tests.
- Strict Swift format lint on the changed source and three changed test files.
- Catalog structure and normalized matrix comparison: 183 jobs, 1,545 catalog
  obligations and 182 instrumented collections. Selections and order are unchanged.
- Source audit: original inventory/definition/scripts/predicates, all other source
  fixtures and the helper/runner are unchanged. Metadata discovery still uses the
  original definition and first INSERT/check on every profile.

The new unit tests keep an independent fixed list of all 63 expected IDs and
names. They check exact original scripts, case-insensitive key predicates,
4/12/1 transaction counts, complete rows and metadata mappings. Negative checks
reject a missing member, altered bytes and the old c49 mapping after MODIFY.
The metadata test keeps 63 member columns after MODIFY, with ID 94 used twice.

One integration case ran with coverage: mysql84-to-mysql57-myisam, default
variant, SQL transport, matrix-collations. All 16 named assertions passed.
Source, native and target agree on all original predicates, full rows and numeric
collation mappings. Raw engine checks confirm source InnoDB and native/target
MyISAM. The existing shared saved-schema restart passed.

| Measurement | Result |
|---|---:|
| Case execution | 8.20 seconds |
| Case SQL client calls | 53 |
| Source batches / client write requests | 3 / 15 |
| Applied transactions before cleanup / after cleanup | 16 / 17 |
| Applied DDL before cleanup / after cleanup | 6 / 7 |
| Changed rows before cleanup / after cleanup | 14 / 14 |
| Fixture setup | 15.07 seconds |
| Container startup, included in setup | 12.12 seconds |
| Coverage export | 1.57 seconds |
| Fixture cleanup | 10.31 seconds |
| Instrumented Swift lines executed / mapped | 7,654 / 20,880 |

Of the 53 calls, 24 are batched native default-value probes: eight calls and
252 values per role. All four tables retain 63 defaults for comparison. Keep
these assertions when interpreting the larger cost than the identifier cases.
No default check was removed to reduce the call count.

Saved CI reported 12.13 seconds and 104 calls for this case. That run compared
more accumulated poc tables. The local run selected one case and added retained
tables. These values are observations across different inputs, not a controlled
speed comparison. Coverage includes fixture setup and the shared restart. It does
not establish individual-case coverage equivalence with the old group report.

Both checkpoint assertions confirm exact applied GTID sets, offsets and counter
deltas. Read-only inspection of final SQLite state confirms all 17 expanded GTIDs
are APPLIED. The last group in each request has the recorded request end offset.
All DDL and row intents are DONE. Latest saved schemas preserve all 63 member
names, types, defaults and collation mappings, including c49's change. Cleanup
retires the three retained tables and keeps matrix_collations current. Final
state is STOPPED with no active GTID, at the shared restart check's later offset.

Two successful applier invocations are recorded: initial apply and the existing
shared saved-schema restart. This case adds no drain, restart, snapshot or offline
replay. No other integration case/profile, full suite, benchmark or syntax suite
ran locally. Selection tooling and runner code did not change, so their Python
tests were not repeated. Leave other profiles/variants and whole-group checks
to GitHub Actions.

Evidence:

- `artifacts/lab/20261104T162611Z-238bb8bf/result.json`
- `artifacts/collation-inventory-workflow-review/results.json`
- `artifacts/collation-inventory-workflow-review/state-results.json`
- `artifacts/collation-inventory-workflow-review/source-manifest.json`
- `artifacts/collation-inventory-workflow-review/inventory-results.json`
- `artifacts/collation-inventory-workflow-review/verify.py`
- `artifacts/collation-inventory-workflow-review/unit.log`

This collation pilot is committed as `6574be6`. The next section records its
separate native-encoding follow-up. Keep full profile/group validation and the
remaining reviews in the overall plan.

## Native-encoding implementation and focused results

Step 5 is complete. The native-encoding case now uses the same helper with three
retained histories. Its original 36 tuples, definition generation, four scripts
and four predicates are unchanged. The collation and identifier source fixtures,
shared helper/runner and metadata-discovery selection are unchanged. No decoder,
applier or production conversion code changed in this slice.

Four complete HEX row queries retain all 108 fields. They distinguish CHAR's
retrieved bytes from VARCHAR/TEXT bytes. They also check native default A bytes,
NULL fields, the stored UTF-16 keys and extra=9439FC36 after ADD. Earlier changed
rows remain available after the original DELETE. Two metadata queries check all
109 original columns, then all 110 columns after ADD, with fixed native IDs.
The key uses ID 55; the utf16 member fields use ID 124. The added column uses
ID 249; the original gb18030 member fields use ID 250. Keep these distinctions.

The six new unit tests contain an independent fixed 36-member ID/byte/default
map. They verify all three field kinds, exact original SQL, original predicates,
4/12/1 transaction counts, final rows, metadata IDs and cleanup ownership.
Negative checks reject untrimmed CHAR results for each of the 36 members,
missing fields, a wrong key collation and a substituted gb18030 value.

Focused checks passed:

- 30 Swift tests: six native-encoding tests, six collation tests, four helper
  tests, five ASCII identifier tests, six Unicode tests and three metadata tests.
- Strict Swift format lint on the changed source and four changed test files.
- Catalog structure and normalized matrix comparison: 183 jobs, 1,545 catalog
  obligations and 182 instrumented collections. Selection and order are unchanged.
- Source audit: original vector list, schema/SQL generation and phase checks are
  unchanged. All other source fixtures, the helper/runner and metadata inputs
  match the collation pilot commit. Display names, source locations, assertion
  descriptions and the source-input fingerprint are excluded from inventory
  normalization.

One integration case ran with coverage: mysql84-to-mysql57-myisam, default
variant, SQL transport, matrix-nativeencodings. All 16 named assertions passed.
Source, native and target agree on every retained row field and numeric metadata
mapping. Full schema/row comparison and raw engine checks passed. The existing
shared saved-schema restart passed.

| Measurement | Result |
|---|---:|
| Case execution | 6.64 seconds |
| Case SQL client calls | 44 |
| Source batches / client write requests | 3 / 15 |
| Applied transactions before cleanup / after cleanup | 16 / 17 |
| Applied DDL before cleanup / after cleanup | 6 / 7 |
| Changed rows before cleanup / after cleanup | 14 / 14 |
| Fixture setup | 14.89 seconds |
| Container startup, included in setup | 12.03 seconds |
| Coverage export | 1.60 seconds |
| Fixture cleanup | 10.74 seconds |
| Instrumented Swift lines executed / mapped | 7,648 / 20,880 |

The call count includes 15 batched default-value probes: five calls and 144
values per role. All 36 CHAR defaults remain checked on each of the four tables.
Saved CI reported 15.34 seconds and 134 calls. The old whole-group run had more
accumulated tables in poc; the local run selects one case and adds retained
tables. This is not a controlled speed comparison. Coverage includes setup and
the shared restart. It does not establish individual coverage equivalence.

Both checkpoint assertions confirm exact GTID sets, offsets and counter deltas.
Read-only final SQLite inspection confirms all 17 expanded GTIDs are APPLIED,
with each request's last group at its recorded end offset. DDL/row intents are
DONE. Latest schemas preserve every CHAR/VARCHAR/TEXT type, character set,
collation and default, plus the UTF-16 key and added gb18030 field. Cleanup
retires only the three retained tables; matrix_nativeencodings remains current.
Final state is STOPPED with no active GTID, at the shared restart check's later
offset. Two successful applier invocations are recorded: initial apply and that
existing restart. No per-case lifecycle transition or offline replay was added.

No other integration case/profile, full suite, benchmark or syntax suite ran
locally. Selection tooling and runner code did not change, so their Python tests
were not repeated. Leave other profiles/variants and whole-group checks to
GitHub Actions.

Evidence:

- `artifacts/lab/20261104T164023Z-99853e79/result.json`
- `artifacts/native-encoding-workflow-review/results.json`
- `artifacts/native-encoding-workflow-review/state-results.json`
- `artifacts/native-encoding-workflow-review/source-manifest.json`
- `artifacts/native-encoding-workflow-review/inventory-results.json`
- `artifacts/native-encoding-workflow-review/verify.py`
- `artifacts/native-encoding-workflow-review/unit.log`

The [ENUM/SET review](BETA7_ENUM_SET_WORKFLOW_REVIEW.md) records the label/byte maps,
phase results, overlap and implementation order. Its matrix-choices pilot passed
all 12 assertions. Widechoices also passed 12, binarychoices passed 14 and
exactchoices passed 16. Enumzero passed 14 and choiceboundaries passed 13.
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
Next: review conflict statements and their no-op GTID/offset boundaries. Keep all seven IDs,
cold metadata inputs, FULL overrides and native version
exclusions. Keep remaining type/value and key/index work, full-matrix validation,
final balancing and short PR selection in the overall plan.
