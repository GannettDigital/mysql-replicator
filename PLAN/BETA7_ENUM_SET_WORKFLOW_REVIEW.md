# ENUM and SET: value and workflow review

Status: all seven local conversions are complete. Six passed their focused
forward tests; legacybinaryset passed on the 5.7 MyISAM profile. Choiceboundaries
is committed as `247bbbe`; legacybinaryset is committed as `88ff87c`. Full-matrix
validation remains. The [character and binary value review](BETA7_CHARACTER_BINARY_VALUE_WORKFLOW_REVIEW.md#implementation-results)
and all three local conversions are complete. The [data-type review](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md) is also complete.
The [type/value workflow results](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md#temporal-fractional-second-and-automatic-value-implementation-results)
record fifteen completed conversions. All focused checks passed.
Next: binarydefaults, textdefaults, fixed and lob. The
[native inventory workflows](BETA7_NATIVE_ENCODING_INVENTORY_REVIEW.md#native-encoding-implementation-and-focused-results)
passed their focused checks before this review.

## Decision and scope

Keep all seven case IDs and their existing selections. The source review found
shared values, but no case whose complete conditions are replaced by another.
They already share the character-sets-collations fixture and running applier.
Combining their IDs alone would not remove container startup or a CI job.

Use the existing DMLExecutionWorkflow in separate implementation slices. Keep
original definitions, scripts, predicates and profile limits. Retain earlier
rows in separate tables, run source writes in batches, then compare results once.
Do not route these cases through the DDL loop or set replicatedReplacement.
Do not change production replication or the independent native schema parser.

The initial review used source inspection, MySQL documentation and saved CI
results without new builds or tests. The results below confirm choices,
widechoices, binarychoices, exactchoices, enumzero, choiceboundaries and
legacybinaryset on their stated profiles.

## MySQL terms and test titles

Consult [The ENUM Type](https://dev.mysql.com/doc/refman/8.4/en/enum.html) and
[The SET Type](https://dev.mysql.com/doc/refman/8.4/en/set.html) before naming a
feature. In this plan, an ENUM ordinal means MySQL's index value within its label
list. It does not mean a table index. SET uses a numeric bitmask. Use unsigned
decimal results for masks which can reach the high bit or all 64 bits.

Use these shared titles in inventory and execution. Keep IDs unchanged.

| Case ID, after matrix- | Reader-facing title |
|---|---|
| choices | ENUM and SET: quoted values, comma labels, empty members and NULL |
| widechoices | ENUM and SET: two-byte ENUM ordinals and 64-bit SET values |
| exactchoices | ENUM and SET: encoded labels, numeric and quoted defaults |
| choiceboundaries | ENUM and SET: trimmed labels, escapes and multibyte boundaries |
| binarychoices | ENUM and SET: binary labels and hex/bit defaults |
| legacybinaryset | SET: non-UTF-8 binary members on MySQL 5.7 |
| enumzero | ENUM: ordinal zero, empty members and primary-key changes |

The pinned 5.7 and 8.4 sql/field.h functions get_enum_pack_length use one byte
below 256 declared labels and two bytes from 256. get_set_pack_length uses eight
bytes for 64 declared members. Thus widechoices has a different row layout from
choiceboundaries even when both exercise the same SET mask.

## Saved results and coverage limits

The seven definitions/scripts match saved CI commit efb3458. The current
DMLChoiceCases.swift file is unchanged; the three relevant case blocks in
DMLCompatibilityCases.swift are also unchanged. Other parts of that file have
changed since CI and are outside this comparison.

Saved CI run 40454033524 has complete measurements, no failed/missing shards and
no missing coverage. These seven cases have 64 passing SQL executions:

- Six cases have ten executions each: four default, four lowercase-tables and
  two forward positioning/metadata variants.
- legacybinaryset has four executions: the two 5.7-to-5.7 profiles, with default
  and lowercase-tables variants. Keep its 8.4 exclusions.

| Default case | 8.4→5.7 MyISAM seconds / calls | 5.7→8.4 InnoDB | 5.7→5.7 MyISAM | 5.7→5.7 InnoDB |
|---|---:|---:|---:|---:|
| exactchoices | 14.98 / 133 | 10.79 / 132 | 13.99 / 132 | 11.51 / 133 |
| choiceboundaries | 12.15 / 106 | 8.53 / 105 | 11.13 / 105 | 9.03 / 105 |
| binarychoices | 13.27 / 118 | 9.66 / 117 | 12.36 / 117 | 10.75 / 118 |
| legacybinaryset | Excluded | Excluded | 10.08 / 96 | 8.33 / 96 |
| enumzero | 17.94 / 163 | 12.27 / 162 | 18.75 / 177 | 16.13 / 178 |
| choices | 14.50 / 130 | 9.67 / 129 | 14.97 / 141 | 12.16 / 141 |
| widechoices | 14.46 / 130 | 9.91 / 129 | 14.91 / 141 | 12.12 / 141 |

These are harness MySQL client calls, not target applier SQL. The six applicable
forward cases total 87.30 seconds and 780 calls in the saved group. Existing poc
tables accumulate across cases. A local single-case conversion has different
comparison inputs, so it cannot establish a controlled speed comparison.

Coverage is collected for the larger group, not each case. Keep the
[same-profile comparison limits](BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#coverage-comparison-scope).
Overlapping line sets cannot show that ordinal 1 replaces 256, an empty member
replaces ordinal zero, or ASCII SET members replace non-UTF-8 members.

Evidence under artifacts/enum-set-workflow-review/:

- baseline.json: all 64 passing executions and call counts.
- source-review.json: exact definitions/scripts/predicates and predicted effects.
- value-maps.json: all ordered label bytes and every phase's complete row values.
- review.py and maps.py: source checks and independent expectation calculations.

Large masks in value-maps.json are decimal strings. Do not pass them through
floating-point arithmetic. The maps below summarize that file. Empty hex means
zero bytes; it differs from NULL.

## Feature ownership and overlap

| Case | Conditions which must remain | Why another case does not replace it |
|---|---|---|
| choices | Literal apostrophe, comma inside an ENUM label, non-ASCII UTF-8 value, empty member, empty SET, multi-member SET and NULL; bulk DELETE of four rows. | choiceboundaries declares an apostrophe label but never writes it. Other cases do not write this complete literal/ordinal mix. |
| widechoices | ENUM ordinal 256→255 with the two-byte type; SET all 64 bits→high bit; final empty table. | choiceboundaries also has 64 members, but its ENUM has only four labels and its high-bit write is a default. |
| exactchoices | Supplementary UTF-8 versus question mark; latin1/UTF-16 bytes; ENUM PRIMARY KEY; numeric versus quoted defaults; ALTER default swaps; added SET default; DELETE followed by key reuse. | Generic ordinal writes do not check those default and key changes. |
| choiceboundaries | Trailing spaces removed from a declared label; backslash bytes; UTF-16LE, UTF-32 and gb18030; SET zero versus NULL; bit 64 and maximum mask. | exactchoices uses different encodings/defaults and lacks these escaped/trimmed values. |
| binarychoices | Raw FF binary ENUM label, declared empty binary member, ASCII binary SET, hex/bit declarations and changed defaults; latin1 raw bytes. | Textual labels do not exercise binary SHOW CREATE normalization. This SET has valid ASCII members on 8.4. |
| legacybinaryset | Raw FF inside a binary SET member and its default; UPDATE/DELETE after ALTER. | 8.4 rejects this definition with native error 3507. Binary ENUM FF support does not imply binary SET FF support. |
| enumzero | Ordinal-zero error value versus declared empty member, both as PRIMARY KEY values; NULL; non-strict source writes; key reuse after DELETE. | HEX alone sees the same empty bytes for ordinals zero and one. exactchoices has no zero error value. |

Retain all seven now. A future retirement must transfer every condition, expected
value, metadata input and catalog reference first. A shared SET mask is a candidate
for a later assertion review, not sufficient evidence to remove a whole case.

## Ordered label and default maps

All positions below are one-based ENUM ordinals. SET positions use bit 1, 2, 4
and so on in declaration order. Preserve that order, not input-list order.

| Fixture and column | Ordered encoded labels | Default/transition to preserve |
|---|---|---|
| exactchoices.id | F09F9880, 3F, 61 | PRIMARY KEY ordinals 1,2,3; row 1 moves to 3 after DELETE frees it. |
| exactchoices.e | E9, FF (latin1) | Default ordinal 1; numeric assignments preserve bytes. |
| exactchoices.s | F09F9880, 3F, 61 | Input default a,😀 becomes mask 5 and bytes F09F98802C61. Mask 7 includes all three labels. |
| exactchoices.w | 2020, 4E2D (UTF-16) | Default ordinal 2. |
| exactchoices.n and q | 32, 61 | n DEFAULT 2 selects ordinal 2; q DEFAULT '2' selects ordinal 1. ALTER reverses these defaults. |
| exactchoices.extra | E9, FF (latin1) | Added default mask 3; retrieved bytes E92CFF. Existing rows receive the new default. |
| choiceboundaries.e | empty, 61, 69742773, 615C62 | Declared a plus two spaces becomes a. Numeric 4 writes the backslash label. |
| choiceboundaries.w | 2020, 2D4E (UTF-16LE) | Default ordinal 1; ordinal 2 writes 中. |
| choiceboundaries.s | 00002020, 00004E2D (UTF-32) | Default mask 3 has bytes 000020200000002C00004E2D. Mask 2 has 00004E2D. |
| choiceboundaries.g | 9439FC36, 3F (gb18030) | Supplementary-character default ordinal 1 versus question-mark ordinal 2. |
| choiceboundaries.bits | ASCII s1 through s64 | Default mask 9223372036854775808; second row starts at 18446744073709551615, then changes to 1. |
| binarychoices.e | FF, 61, empty (binary) | Default ordinal 1→2. Empty is declared ordinal 3, not ordinal zero. |
| binarychoices.s | 41, 61 (binary) | Hex/bit labels; default mask 3→1; mask 3 has bytes 412C61. |
| binarychoices.l | E9, FF (latin1) | Default ordinal 1. |
| legacybinaryset.s | FF, 61 (binary) | Default mask 3→1; FF2C61 becomes FF. |
| enumzero.id | empty, 6F6E65, 74776F | Ordinal 0 is also empty bytes; keep it distinct from declared member 1. |
| enumzero.e | empty, 796573, 6E6F | Keep ordinal 0, declared member 1 and NULL distinct. |
| choices.e | empty, 6F6E65, 69742773, 782C79, C3A9 | Preserve numeric and quoted assignments, including it's and x,y. |
| choices.s | 61, 62, 63 | Masks 0,7,5,2, then row 3 changes to 6. |
| widechoices.e | ASCII e1 through e256 | Ordinal 256 has hex 65323536; ordinal 255 has 65323535. |
| widechoices.s | ASCII s1 through s64 | Maximum mask→high bit; preserve exact unsigned values and all ordered labels. |

For wide SET text, generate the expected ASCII list s1,...,s64 from the declared
range in the test oracle. Numeric masks remain fixed constants. Do not use the
production label parser, character converter or target result as the oracle.

## Phase results to retain

The JSON value maps contain every field of every row. The following table names
are proposals; verify ownership before implementation. Keep the original matrix
name for the final phase. Retain one table per earlier phase prefix.

| Case | Retained histories | Important final and earlier results |
|---|---|---|
| choices | ch_after_insert, ch_after_update | Keep all five inserted rows. Keep row 3's apostrophe/mask 5 before UPDATE and comma-label/mask 6 afterward. The original final row is id 4 with both fields NULL. |
| widechoices | wc_after_insert, wc_after_update | Keep id 1 at ordinal 256/maximum mask and 255/high-bit mask. Original final table is empty. |
| binarychoices | bc_after_insert, bc_after_default | Keep all four initial rows, including empty binary member 3 and NULL row 4. After ALTER, row 2 has e=2, s=1, l=1. Final rows are 2,3,4; row 3 has e=1, s=3, l=2. |
| legacybinaryset | ls_after_insert | Keep initial masks 3,1,2,NULL. Final rows 2,3,4 have masks 1,1,NULL. |
| exactchoices | ex_after_insert, ex_after_update, ex_after_default | Keep all three initial rows and updated row 2. After ADD, every existing row has extra mask 3. Final rows use key ordinals 2 and 3; v values are 21 and 10. |
| enumzero | ez_after_insert, ez_after_update, ez_after_delete | Keep zero/empty key rows before DELETE. Final rows are key 0/e=0/v=20 and key 1/e=1/v=11. |
| choiceboundaries | cb_after_insert, cb_after_update | Keep default row 1, initial zero SET/maximum bits on row 2 and NULL row 3. After UPDATE, row 2 has e=4,w=2,s=2,g=2,bits=1. Final rows are 2 and 3. |

Move each old predicate to its matching retained prefix, except the final
predicate, which stays on the original table. Change only the qualified table
token. Keep the original scripts first, then copied histories. Retained tables
use the complete original definition, including type size, charset, collation,
defaults and key. Do not shorten the 256-label or 64-member definitions.

Add full ordered row queries. For each ENUM, record both ordinal and HEX bytes.
For each SET, record CAST(column AS UNSIGNED) and HEX bytes. Use explicit NULL
markers for both numeric and hex values. Empty hex is a real field; retain tabs
and trailing empty fields with preserveWhitespace. Order ENUM keys by id+0.
A final empty table must have an explicit empty-result assertion.

Keep full schema/index comparisons on all owned tables. For binary labels,
retain the existing raw SHOW CREATE and NativeChoiceDefinition oracle. Do not
replace it with INFORMATION_SCHEMA's decoded string or the production parser.
Use final read-only metadata/default checks to confirm the old and changed
n/q, e/s and added-extra defaults. No proposed row predicate replaces schema
label order or raw binary default checks.

## Helper, session and metadata requirements

The current helper accepts only orderBy=id. Five cases fit that condition.
Before exactchoices or enumzero opt in, add narrow support for their declared
id+0 order and unit-test it. Keep rejection of unrelated custom ordering, setup
SQL, replacement cases and JSON diff checks. Do not drop these guards wholesale.
The runner's full comparison already derives primary-key ordering from MySQL;
new fixed row queries must still make the ordinal order explicit.

Six cases require rowMetadata=FULL: all except legacybinaryset. Preserve that
property in both live workflows and cold metadata fixtures. The shared runner
sets it before it enters the opt-in workflow. A positioning/metadata variant
named MINIMAL does not make these six cases MINIMAL label tests. A 5.7 source
has no optional FULL metadata; keep its target-baseline schema path.

Keep SET SESSION sql_mode='' inside each original enumzero script that uses it.
LabSQLPhase resets the profile session before every write. That reset must remain
before the original script; its explicit non-strict setting then takes effect.
Do not strip, hoist or leak the mode into later requests or retained histories.
Capture source warnings; do not require them to be empty for ordinal-zero writes.
Session SET statements do not add a source transaction to the declared counts.

Keep metadata-labels-defaults inputs. It contains the six distinct choice
fixtures, subject to version exclusions. enumzero maps to exactchoices for cold
metadata; it remains a distinct DML test. Do not add its full workload to cold
metadata discovery or remove its DML assertions because of that mapping.

The existing final fixture drain/restart loads saved schemas and writes to
reverse_poc.aux. It does not write to every ENUM/SET table after restart. Preserve
it, but do not describe it as a dedicated ordinal-zero restart/replay test.
No new per-case restart or offline replay is required for this batching work.

## Source effects and checkpoint predictions

These scripts have autocommit DML and implicit DDL commits. Preserve each
multi-statement script; do not split on semicolons or add BEGIN/COMMIT.
Counts below come from source inspection and the proposed retained prefixes.
The results below confirm all seven cases on their stated profiles. Other
profiles and variants remain for full-matrix validation.

| Case | GTIDs per original phase | Original total with CREATE | Preparation writes | Body writes / GTIDs | Before cleanup: GTIDs / DDL / rows | After cleanup GTIDs |
|---|---|---:|---:|---:|---:|---:|
| choices | 1/1/1 | 4 | 3 | 6 / 6 | 9 / 3 / 21 | 10 |
| widechoices | 1/1/1 | 4 | 3 | 6 / 6 | 9 / 3 / 6 | 10 |
| binarychoices | 1/2/2 | 6 | 3 | 6 / 9 | 12 / 5 / 16 | 13 |
| legacybinaryset | 1/3 | 5 | 2 | 3 / 5 | 7 / 3 / 10 | 8 |
| exactchoices | 1/1/2/2 | 7 | 4 | 10 / 13 | 17 / 6 / 19 | 18 |
| enumzero | 1/2/1/1 | 6 | 4 | 10 / 13 | 17 / 4 / 21 | 18 |
| choiceboundaries | 1/1/1 | 4 | 3 | 6 / 6 | 9 / 3 / 12 | 10 |

Each cleanup is one DROP TABLE listing only that case's retained tables. It adds
one GTID and one DDL, with no changed row events. Leave the original matrix table
current. A batch is a set of client requests, not one source transaction.

Keep body and cleanup assertions for exact GTID sets, file offsets and counter
deltas. Expand multi-GTID intervals when checking saved state. Only each request's
last GTID must have the recorded request end offset. Read SQLite after the existing
shared stop, using read-only mode. Check completed intents, current originals,
retired histories and the latest saved label/default bytes and ordinals.

On failure, read the printed support bundle before rerunning: failure.json,
bundle.json, bundled SQLite read-only and logs. Keep the failed evidence. Keep
a clear case/assertion/phase name in harness output.

## Implementation slices and local validation

1. Pilot only matrix-choices. It fits the helper without ordering changes. Keep
   the original definition and three scripts, add two retained histories, preserve
   all three predicates and add complete row/ordinal/mask queries. Check one final
   NULL row and earlier empty/member/literal results. Leave other six cases alone.
2. Add focused unit checks for exact SQL and label bytes, counts 3/6/1, retained
   queries, NULL versus empty fields, cleanup and shared title. Include the helper,
   existing opt-in fixture tests and metadata-discovery tests. Update tests which
   enumerate opt-in IDs. Check catalog/matrix membership and strict format lint.
3. Run only matrix-choices on forward/default/SQL with coverage. Inspect boundaries,
   predicted counts, complete rows, schemas, cleanup and the shared final restart.
   Record calls, case time and setup/coverage/cleanup costs with the comparison
   limits above. Leave other profiles and whole-group checks to GitHub Actions.
4. Convert widechoices next. Keep its own two-byte ENUM plus 64-bit SET row layout.
   Unit-test full ordered label lists, fixed unsigned values and empty final rows.
   Use one focused forward integration case. Then convert binarychoices with its
   raw SHOW CREATE checks, NativeChoiceDefinitionTests and one forward case.
5. Convert exactchoices after adding tested, narrow id+0 ordering support. Preserve
   FULL metadata and every encoded/default/key transition. Use one forward case.
   Then convert enumzero with focused session-reset, numeric/empty and key-reuse
   checks and its own forward case. Do not rerun the ordinary cases locally.
6. Convert choiceboundaries with fixed multibyte label/default maps and a forward
   case. Convert legacybinaryset separately on mysql57-to-mysql57-myisam. Keep
   both 8.4 exclusions with native error 3507. Leave its InnoDB repeat to CI.
7. Keep the existing 183 jobs, 1,545 catalog obligations and 182 instrumented
   collections. Do not change feature-group boundaries during these conversions.
   Run selection tooling tests only if their code or wiring changes. Run no syntax
   suite for fixture-only changes. After these slices, review remaining type/value
   and key/index work before full-matrix validation, balancing and PR selection.

Pilot command, after implementation:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case matrix-choices --coverage"
```

No tests or native version exclusions are removed by this review. The
implementation results below identify the cases and profiles tested locally.

## Choices pilot implementation and focused results

Steps 1–3 are complete. At this step, only matrix-choices was newly enabled on the existing DML workflow
helper. It retains its exact definition, three scripts, three predicates and
FULL row-metadata setting. The other six choice cases, shared helper/runner,
metadata selection and native-encoding work were unchanged. No production decoder, parser or applier code changed.

Preparation creates the original table and ch_after_insert/ch_after_update.
The body runs the three original scripts first, then the original prefixes on
the histories. Three full ordered row queries record all five fields: id, ENUM
ordinal, ENUM hex bytes, unsigned SET mask and SET hex bytes. They preserve
empty fields, NULLs and values removed by the bulk DELETE. The old predicates
remain separate named assertions. Full schema/row comparison covers all three
tables. Cleanup drops only the two histories.

Focused checks passed:

- 36 Swift tests: six pilot tests and the existing helper, identifier, inventory
  and metadata-discovery tests.
- Strict Swift format lint on the changed source and five changed test files.
- Catalog structure and normalized matrix comparison: 183 jobs, 1,545 catalog
  obligations and 182 instrumented collections. Selections and order are unchanged.
- Source audit: original definition/scripts/predicates, the other six choice
  cases, metadata inputs, helper/runner and pending native-encoding source work
  are preserved. Inventory normalization excludes display names, source locations,
  assertion descriptions and the source-input fingerprint.

The new unit tests check exact SQL/UTF-8 bytes, 3/6/1 request/transaction counts,
all retained queries, complete row fields, cleanup and a shared case title.
They reject ordinal zero in place of the declared empty member, removed trailing
empty fields, wrong UTF-8 bytes, NULL-to-empty substitutions and an unchanged
row after UPDATE. Metadata tests keep the original definition and first phase
with FULL metadata on every applicable profile.

One integration case ran with coverage: mysql84-to-mysql57-myisam, default
variant, SQL transport, matrix-choices. All 12 named assertions passed. Source,
native and target agree on all old predicates, complete rows and schema results.
Raw engine checks confirm source InnoDB and native/target MyISAM. The existing
shared saved-schema restart passed.

| Measurement | Result |
|---|---:|
| Case execution | 4.07 seconds |
| Case SQL client calls | 27 |
| Source batches / client write requests | 3 / 10 |
| Applied transactions before cleanup / after cleanup | 9 / 10 |
| Applied DDL before cleanup / after cleanup | 3 / 4 |
| Changed rows before cleanup / after cleanup | 21 / 21 |
| Fixture setup | 14.55 seconds |
| Container startup, included in setup | 11.87 seconds |
| Coverage export | 1.69 seconds |
| Fixture cleanup | 10.76 seconds |
| Instrumented Swift lines executed / mapped | 7,713 / 20,880 |

Saved CI reported 14.50 seconds and 130 calls. That run compared more accumulated
poc tables. The local run selected one case and added retained tables. These
measurements do not establish a controlled speed comparison. Coverage includes
setup and the shared restart; it does not prove individual-case equivalence with
the old group-level report.

Both checkpoint assertions confirm exact applied GTID sets, offsets and counter
deltas. Read-only inspection of final SQLite state confirms all ten GTIDs are
APPLIED with their recorded end offsets. DDL and row intents are DONE. Saved
schemas retain exact label order/bytes, nullable fields, NULL defaults and
utf8mb4_bin encoding. Cleanup retires the two histories and keeps matrix_choices
current. Final state is STOPPED with no active GTID, at the shared restart
check's later offset.

Two successful applier invocations are recorded: initial apply and the existing
shared restart, whose write uses reverse_poc.aux. This case adds no drain,
restart, snapshot or offline replay. No other integration case/profile, full
suite, benchmark or syntax suite ran locally. Selection tooling and runner code
did not change, so their Python tests were not repeated. Leave other profiles,
variants and whole-group validation to GitHub Actions.

Evidence:

- `artifacts/lab/20261104T174230Z-52f54f51/result.json`
- `artifacts/choices-workflow-review/results.json`
- `artifacts/choices-workflow-review/state-results.json`
- `artifacts/choices-workflow-review/source-manifest.json`
- `artifacts/choices-workflow-review/inventory-results.json`
- `artifacts/choices-workflow-review/verify.py`
- `artifacts/choices-workflow-review/unit.log`

This pilot is committed as `87320df`, together with the native-encoding work.
The next section records its separate widechoices follow-up. Keep full-matrix
validation, final balancing and short PR selection later.

## Wide ENUM and SET implementation and focused results

The first part of Step 4 is complete. matrix-widechoices now uses the existing
helper. The original definition keeps all 256 ENUM labels and 64 SET members.
The original scripts, predicates and FULL metadata setting are unchanged. Other
source cases and the shared helper/runner are unchanged. No production parser,
decoder or applier code changed in this slice.

Two retained tables keep the original INSERT result and the result after UPDATE.
The ENUM definition keeps its two-byte field layout during both phases. Three
full row queries require ordinal 256/label e256 with the maximum SET mask,
ordinal 255/label e255 with only bit 64, and an empty original table after DELETE.
The maximum-mask label bytes include all 64 members in declaration order.
Unsigned values stay as exact decimal strings, with no floating-point conversion.
All three old predicates remain separate named assertions.

Focused checks passed:

- 42 Swift tests: six new wide-case tests and the 36 existing workflow/metadata
  tests selected for the pilot.
- Strict Swift format lint on the changed source and six changed test files.
- Catalog structure and normalized matrix comparison: 183 jobs, 1,545 catalog
  obligations and 182 instrumented collections. Selection and order are unchanged.
- Source audit: the complete wide definition, three scripts/predicates, other
  source cases, metadata inputs and shared helper/runner remain unchanged.
  Inventory normalization excludes display names, source locations, assertion
  descriptions and the source-input fingerprint.

The new tests preserve full label lists and exact source SQL. Fixed expectations
check UInt64.max, bit 64, the 492 hex digits of the maximum-mask member list and
both boundary labels. Negative checks reject signed output, changed label bytes,
extra bytes and rows remaining in the final table. Counter/offset checks include
the cleanup boundary. Metadata tests retain the original definition and first
INSERT/check with FULL metadata on every applicable profile.

The same forward/default/SQL case was attempted twice. The first attempt failed
before any test SQL: OrbStack could not create the 5.7 target container because
an image-layer parent snapshot was missing. The failure report and lifecycle
files were inspected before retrying. Support-bundle collection also failed:
setup had not yet produced a stateDirectory setting. No usable bundle existed.
The local MySQL 5.7 fixture image was rebuilt without cache. A mysql --version
container check passed. The source code was unchanged for the retry.

The retry selected only matrix-widechoices on mysql84-to-mysql57-myisam with
coverage. All 12 named assertions passed. Source, native and target agree on
both retained rows, exact unsigned masks and bytes, schema results and the empty
final table. Raw engine checks confirm source InnoDB and native/target MyISAM.
The existing shared saved-schema restart passed.

Successful-attempt measurements:

| Measurement | Result |
|---|---:|
| Case execution | 3.93 seconds |
| Case SQL client calls | 27 |
| Source batches / client write requests | 3 / 10 |
| Applied transactions before cleanup / after cleanup | 9 / 10 |
| Applied DDL before cleanup / after cleanup | 3 / 4 |
| Changed rows before cleanup / after cleanup | 6 / 6 |
| Fixture setup | 13.25 seconds |
| Container startup, included in setup | 10.73 seconds |
| Coverage export | 1.68 seconds |
| Fixture cleanup | 10.70 seconds |
| Instrumented Swift lines executed / mapped | 7,506 / 20,880 |

Saved CI reported 14.46 seconds and 130 calls. Its group compared more accumulated
poc tables. The local run selected one case and added retained tables. This is
not a controlled speed comparison. Coverage includes setup and the shared restart;
it does not prove individual-case equivalence with the old group-level report.

Both checkpoint assertions confirm exact GTID sets, offsets and counter deltas.
Read-only final SQLite inspection confirms all ten GTIDs are APPLIED at their
recorded end offsets. DDL and row intents are DONE. Each latest saved schema keeps
all 256 ENUM labels, all 64 SET members, label order, NULL defaults and utf8mb4_bin
encoding. Cleanup retires the two histories and keeps matrix_widechoices current.
Final state is STOPPED with no active GTID, at the shared restart check's later
offset. Two successful applier invocations are recorded: initial apply and that
existing restart. This case adds no per-case lifecycle transition or offline replay.

No other integration case/profile, full suite, benchmark or syntax suite ran
locally. Selection tooling and runner code did not change, so their Python tests
were not repeated. Leave other profiles, variants and whole-group validation to CI.

Evidence:

- `artifacts/lab/20261104T185923Z-a4f18c11/result.json`: successful retry.
- `artifacts/lab/20261104T180058Z-7b5f8f41/result.json`: setup failure, preserved.
- `artifacts/wide-choices-workflow-review/results.json`
- `artifacts/wide-choices-workflow-review/state-results.json`
- `artifacts/wide-choices-workflow-review/source-manifest.json`
- `artifacts/wide-choices-workflow-review/inventory-results.json`
- `artifacts/wide-choices-workflow-review/verify.py`
- `artifacts/wide-choices-workflow-review/unit.log`
- `artifacts/wide-choices-workflow-review/fixture-rebuild.log`
- `artifacts/wide-choices-workflow-review/fixture-check.log`

The wide conversion is committed as `9bcd237`. The next section records its
separate binarychoices follow-up. Keep the remaining slices above.

## Binary ENUM and SET implementation and focused results

Step 4 is complete. matrix-binarychoices now uses the existing helper with two
retained histories. Its original definition keeps the binary FF/61/empty ENUM
labels, ASCII binary SET members, latin1 labels and hex/bit default syntax.
The three original scripts and predicates remain unchanged, with FULL metadata.
Other source cases, the shared helper/runner and NativeChoiceDefinition are
unchanged. No production parser, decoder or applier code changed.

Three full row queries retain all inserted fields, the result after ALTER, and
the final three rows. They include ENUM ordinals, SET masks, raw hex bytes and
explicit NULL markers. Two separate queries read HEX(DEFAULT(column)) from the
retained tables. These confirm e/s defaults FF/412C61 before ALTER and 61/41
afterward; the latin1 default remains E9. Full schema comparison continues to
read raw SHOW CREATE bytes through the independent native parser.

Focused checks passed:

- 51 Swift tests: seven new binary workflow tests, two NativeChoiceDefinition
  tests and the 42 existing workflow/metadata tests selected for widechoices.
- Strict Swift format lint on the changed source and seven changed test files.
- Catalog structure and normalized matrix comparison: 183 jobs, 1,545 catalog
  obligations and 182 instrumented collections. Selection and order are unchanged.
- Source audit: original binary definition/scripts/predicates, other source cases,
  metadata inputs, shared helper/runner and raw schema oracle are unchanged.
  Inventory normalization excludes display names, source locations, assertion
  descriptions and the source-input fingerprint.

The new tests check fixed raw values, exact original SQL, 3/9/1 source transaction
counts, multi-statement request order, default queries and cleanup ownership.
Negative checks reject UTF-8 replacement of FF/E9 bytes, ordinal zero in place of
the declared empty member, NULL-to-empty substitutions and missing row updates.
A new oracle test confirms that raw 5.7 bytes and 8.4 hex forms produce the same
ordered binary labels, while the changed defaults remain distinct.

One integration case ran with coverage: mysql84-to-mysql57-myisam, default
variant, SQL transport, matrix-binarychoices. All 14 named assertions passed.
Source, native and target agree on all original predicates, complete rows,
default bytes and schema results. The SQL trace records nine raw SHOW CREATE
requests: each of the three tables on each role. This confirms the existing
binary schema oracle remains active. Raw engine checks confirm source InnoDB and
native/target MyISAM. The existing shared saved-schema restart passed.

| Measurement | Result |
|---|---:|
| Case execution | 5.53 seconds |
| Case SQL client calls | 37 |
| Source batches / client write requests | 3 / 10 |
| Applied transactions before cleanup / after cleanup | 12 / 13 |
| Applied DDL before cleanup / after cleanup | 5 / 6 |
| Changed rows before cleanup / after cleanup | 16 / 16 |
| Fixture setup | 14.92 seconds |
| Container startup, included in setup | 11.96 seconds |
| Coverage export | 1.77 seconds |
| Fixture cleanup | 10.78 seconds |
| Instrumented Swift lines executed / mapped | 7,979 / 20,880 |

Saved CI reported 13.27 seconds and 118 calls. That group compared more
accumulated poc tables. The local run selected one case and added retained tables.
These are observations across different inputs, not a controlled speed comparison.
Coverage includes setup and the shared restart. It does not establish individual
case equivalence with the old group-level report.

Both checkpoint assertions confirm exact GTID sets, offsets and counter deltas.
Read-only final SQLite inspection confirms all 13 expanded GTIDs are APPLIED.
For each multi-GTID request, its last group has the recorded request end offset.
DDL and row intents are DONE. Latest schemas retain ordered binary/latin1 label
bytes, including the empty member, and the correct default ordinals. Binary
default bytes change from FF/412C61 to 61/41; latin1 stays at ordinal 1/E9.
Cleanup retires the two histories and keeps matrix_binarychoices current. Final
state is STOPPED with no active GTID, at the shared restart check's later offset.
Two successful applier invocations are recorded: initial apply and that existing
restart. This case adds no per-case lifecycle transition or offline replay.

No other integration case/profile, full suite, benchmark or syntax suite ran
locally. Selection tooling and runner code did not change, so their Python tests
were not repeated. Leave other profiles, variants and whole-group validation to CI.

Evidence:

- `artifacts/lab/20261104T193007Z-e2bd6c79/result.json`
- `artifacts/binary-choices-workflow-review/results.json`
- `artifacts/binary-choices-workflow-review/state-results.json`
- `artifacts/binary-choices-workflow-review/source-manifest.json`
- `artifacts/binary-choices-workflow-review/inventory-results.json`
- `artifacts/binary-choices-workflow-review/verify.py`
- `artifacts/binary-choices-workflow-review/unit.log`

The binary conversion is committed as `72f5a15`. The next section records its
separate exactchoices follow-up. Keep the remaining slices above.

## Encoded ENUM and SET implementation and focused results

The exactchoices part of Step 5 is complete. matrix-exactchoices now uses the
existing helper with three retained histories. Its original definition, four
scripts, four predicates, id+0 ordering and FULL metadata remain unchanged.
The definition keeps utf8mb4, latin1 and utf16 labels, supplementary characters,
numeric versus quoted ENUM defaults, an added SET default and PRIMARY KEY reuse.
No production parser, decoder or applier code changed.

The shared helper adds an explicit Order setting. Existing workflows keep id;
exactchoices selects idOrdinal, which means id+0. The setting must match the
case's existing orderBy. Other expressions still fail validation. Setup SQL,
replacement cases and JSON difference checks still require a separate plan.
The helper's execution code, shared runner and native schema oracle are unchanged.

Four fixed row queries retain every column after INSERT, UPDATE and ALTER, and
in the final table. They check ENUM ordinals, unsigned SET masks, raw hex bytes,
NULL fields and the reused primary key. Two further queries read
HEX(DEFAULT(column)) from the retained tables. These confirm n/q default bytes
61/32 before ALTER and 32/61 afterward. The other defaults stay E9, F09F98802C61
and 4E2D. The added SET default is E92CFF in declared member order.

Focused checks passed:

- 59 Swift tests: seven new exactchoices tests, one new helper ordering test and
  the 51 workflow, metadata and native-schema tests selected for binarychoices.
- Strict Swift format lint on both changed source files and nine test files.
- Catalog structure and normalized matrix comparison: 183 jobs, 1,545 catalog
  obligations and 182 instrumented collections. Selection and order are unchanged.
- Source audit: original exactchoices definition/scripts/predicates, other cases,
  metadata inputs, helper execution, runner and native schema oracle are unchanged.
  Inventory normalization excludes display names, source locations, assertion
  descriptions and the source-input fingerprint.

The unit tests check exact SQL and encoded bytes, source transaction counts,
multi-statement request order, session resets, complete results, default queries,
cleanup ownership and the shared title. Negative checks reject wrong UTF-8 bytes,
changed UTF16 bytes, NULL-to-empty substitutions, unchanged defaults, reversed SET
member order and an earlier row set in place of the final primary-key result.
Helper tests require a matching explicit ordering setting and reject other orders.

One integration case ran with coverage: mysql84-to-mysql57-myisam, default
variant, SQL transport, matrix-exactchoices. All 16 named assertions passed.
Source, native and target agree on all original predicates, complete row results,
default bytes and schema comparisons. Raw engine checks confirm source InnoDB
and native/target MyISAM. The existing shared saved-schema restart passed.

| Measurement | Result |
|---|---:|
| Case execution | 4.69 seconds |
| Case SQL client calls | 29 |
| Source batches / client write requests | 3 / 15 |
| Applied transactions before cleanup / after cleanup | 17 / 18 |
| Applied DDL before cleanup / after cleanup | 6 / 7 |
| Changed rows before cleanup / after cleanup | 19 / 19 |
| Fixture setup | 18.79 seconds |
| Container startup, included in setup | 16.02 seconds |
| Coverage export | 1.99 seconds |
| Fixture cleanup | 10.92 seconds |
| Instrumented Swift lines executed / mapped | 8,130 / 20,880 |

Saved CI reported 14.98 seconds and 133 calls. Its group compared more accumulated
poc tables. The local run selected one case and added retained tables. This is
not a controlled speed comparison. Coverage includes setup and the shared restart;
it does not establish individual-case equivalence with the old group-level report.

Both checkpoint assertions confirm exact GTID sets, offsets and counter deltas.
Read-only final SQLite inspection confirms all 18 expanded GTIDs are APPLIED.
For each multi-GTID request, its last group has the recorded request end offset.
DDL and row intents are DONE. Latest saved schemas retain ordered label bytes,
the numeric/quoted default transition and the added SET default. Cleanup retires
all three histories and keeps matrix_exactchoices current. Final state is STOPPED
with no active GTID, at the shared restart check's later offset. Two successful
applier invocations are recorded: initial apply and that existing restart. The
restart writes reverse_poc.aux; it does not write each ENUM/SET table. This case
adds no per-case lifecycle transition or offline replay.

No other integration case/profile, full suite, benchmark or syntax suite ran
locally. Selection tooling and runner code did not change, so their Python tests
were not repeated. Leave other profiles, variants and whole-group validation to CI.

Evidence:

- `artifacts/lab/20261104T195419Z-5649176b/result.json`
- `artifacts/exact-choices-workflow-review/results.json`
- `artifacts/exact-choices-workflow-review/state-results.json`
- `artifacts/exact-choices-workflow-review/source-manifest.json`
- `artifacts/exact-choices-workflow-review/inventory-results.json`
- `artifacts/exact-choices-workflow-review/verify.py`
- `artifacts/exact-choices-workflow-review/unit.log`

The exactchoices conversion is committed as `a8bf116`. The next section records
its separate enumzero follow-up. Keep the remaining slices above.

## Ordinal zero implementation and focused results

Step 5 is complete. matrix-enumzero now uses the existing helper with three
retained histories. Its definition, four scripts, four predicates, id+0 ordering
and FULL metadata remain unchanged. The helper, shared runner and native schema
oracle are unchanged. No production parser, decoder or applier code changed.

Preparation creates the original table and ez_after_insert/ez_after_update/
ez_after_delete. The body keeps the original scripts first, then their prefixes
on the retained tables. Each request resets the profile session before its own
SET SESSION sql_mode=''. Non-strict mode is not hoisted to a whole batch.
Multi-statement updates keep their original transaction boundaries. Source
warnings remain in the phase records; ordinal-zero writes need not be warning-free.

Four complete row queries read numeric ordinals and hex bytes together. Ordinal
zero and declared member one both have empty bytes. The queries keep these values
distinct and also check NULL. They retain the rows before DELETE and confirm
key reuse afterward: final key 0/e=0/v=20 and key 1/e=1/v=11. The original predicates
remain separate named assertions. Cleanup drops only the three retained tables.
Cold metadata discovery still maps enumzero to exactchoices; it does not acquire
another definition or the full ordinal-zero workload.

Focused checks passed:

- 66 Swift tests: seven new enumzero tests and the 59 tests selected for exactchoices.
- Strict Swift format lint on the changed source file and nine test files.
- Catalog structure and normalized matrix comparison: 183 jobs, 1,545 catalog
  obligations and 182 instrumented collections. Selection and order are unchanged.
- Source audit: original enumzero definition/scripts/predicates, all other cases,
  metadata inputs, helper, runner and native schema oracle are unchanged. Inventory
  normalization excludes display names, source locations, assertion descriptions
  and the source-input fingerprint.

The unit tests check exact SQL, original predicates, transaction counts, session
resets, non-strict mode placement, retained warnings, complete fixed rows,
checkpoint checks, cleanup ownership and the shared title. Negative checks reject
removed empty fields, changed zero/empty ordinals, NULL-to-empty substitutions,
the row set before key reuse, wrong counters and a wrong saved offset.

One integration case ran with coverage: mysql84-to-mysql57-myisam, default
variant, SQL transport, matrix-enumzero. All 14 named assertions passed. Source,
native and target agree on original predicates, complete row results and schema
comparisons. Raw engine checks confirm source InnoDB and native/target MyISAM.
The existing shared saved-schema restart passed.

| Measurement | Result |
|---|---:|
| Case execution | 4.06 seconds |
| Case SQL client calls | 27 |
| Source batches / client write requests | 3 / 15 |
| Applied transactions before cleanup / after cleanup | 17 / 18 |
| Applied DDL before cleanup / after cleanup | 4 / 5 |
| Changed rows before cleanup / after cleanup | 21 / 21 |
| Fixture setup | 14.85 seconds |
| Container startup, included in setup | 11.95 seconds |
| Coverage export | 1.72 seconds |
| Fixture cleanup | 11.00 seconds |
| Instrumented Swift lines executed / mapped | 7,716 / 20,880 |

Saved CI reported 17.94 seconds and 163 calls. Its group compared more accumulated
poc tables. The local run selected one case and added retained tables. This is
not a controlled speed comparison. Coverage includes setup and the shared restart;
it does not establish individual-case equivalence with the old group-level report.

Both checkpoint assertions confirm exact GTID sets, offsets and counter deltas.
Read-only final SQLite inspection confirms all 18 expanded GTIDs are APPLIED.
For each multi-GTID request, its last group has the recorded request end offset.
DDL and row intents are DONE. Latest schemas retain ordered empty-member ENUM
labels, utf8mb4_bin and the unsigned integer column. Cleanup retires all three
histories and keeps matrix_enumzero current. Final state is STOPPED with no active
GTID, at the shared restart check's later offset. Two successful applier invocations
are recorded: initial apply and that existing restart. The restart writes
reverse_poc.aux; it does not write each ENUM/SET table. This case adds no per-case
lifecycle transition or offline replay.

No other integration case/profile, full suite, benchmark or syntax suite ran
locally. Selection tooling and runner code did not change, so their Python tests
were not repeated. Leave other profiles, variants and whole-group validation to CI.

Evidence:

- `artifacts/lab/20261104T201646Z-353a7ebf/result.json`
- `artifacts/enum-zero-workflow-review/results.json`
- `artifacts/enum-zero-workflow-review/state-results.json`
- `artifacts/enum-zero-workflow-review/source-manifest.json`
- `artifacts/enum-zero-workflow-review/inventory-results.json`
- `artifacts/enum-zero-workflow-review/verify.py`
- `artifacts/enum-zero-workflow-review/unit.log`

The enumzero conversion is committed as `a315703`. The next section records its
separate choiceboundaries follow-up. Keep the remaining slice above.

## Multibyte boundary implementation and focused results

The choiceboundaries part of Step 6 is complete. matrix-choiceboundaries now uses
preparation and body batches with two retained histories. Its definition, three
scripts, three predicates and FULL metadata remain unchanged. Keep all 64 SET
members, the untrimmed source declaration and its doubled backslash/apostrophe
syntax. The helper, shared runner, metadata inputs and native schema oracle are
unchanged. No production parser, decoder or applier code changed.

Three complete row queries check every column after INSERT, after UPDATE and in
the final table. They preserve numeric ordinals, exact bytes, empty fields, NULL,
UTF-16LE/UTF-32/gb18030 values, the high-bit SET mask and the maximum unsigned
64-bit mask. A fourth query checks default bytes, including trimmed a and SET
members in declaration order. Cleanup drops only cb_after_insert/cb_after_update.
The original matrix table remains current.

Focused checks passed:

- 73 Swift tests: seven new boundary workflow tests and the 66 tests selected for enumzero.
- Strict Swift format lint on the changed source file and ten test files.
- Catalog structure and normalized matrix comparison: 183 jobs, 1,545 catalog
  obligations and 182 instrumented collections. Selection and order are unchanged.
- Source audit: original definition/scripts/predicates, all other cases, cold
  metadata inputs, helper, runner and native schema oracle are unchanged. Inventory
  normalization excludes display names, source locations, assertion descriptions
  and the source-input fingerprint.

The tests check exact source SQL, fixed encoded results, session resets, source
transaction counts, original predicates, default queries, cleanup ownership and
the shared title. Negative checks reject reversed UTF-16LE bytes, changed UTF-32
or gb18030 bytes, doubled stored backslashes, lost empty fields, NULL-to-empty
substitutions, signed masks, untrimmed default bytes and reversed SET member order.

One integration case ran with coverage: mysql84-to-mysql57-myisam, default
variant, SQL transport, matrix-choiceboundaries. All 13 named assertions passed.
Source, native and target agree on original predicates, complete row results,
default bytes and schema comparisons. Raw engine checks confirm source InnoDB
and native/target MyISAM. The existing shared saved-schema restart passed.

| Measurement | Result |
|---|---:|
| Case execution | 3.73 seconds |
| Case SQL client calls | 27 |
| Source batches / client write requests | 3 / 10 |
| Applied transactions before cleanup / after cleanup | 9 / 10 |
| Applied DDL before cleanup / after cleanup | 3 / 4 |
| Changed rows before cleanup / after cleanup | 12 / 12 |
| Fixture setup | 13.92 seconds |
| Container startup, included in setup | 11.28 seconds |
| Coverage export | 1.66 seconds |
| Fixture cleanup | 10.81 seconds |
| Instrumented Swift lines executed / mapped | 7,782 / 20,880 |

Saved CI reported 12.15 seconds and 106 calls. Its group compared more accumulated
poc tables. The local run selected one case and added retained tables. This is
not a controlled speed comparison. Coverage includes setup and the shared restart;
it does not establish individual-case equivalence with the old group-level report.

Both checkpoint assertions confirm exact GTID sets, offsets and counter deltas.
Read-only final SQLite inspection confirms all ten GTIDs are APPLIED at their
recorded end offsets. DDL and row intents are DONE. Latest schemas retain trimmed
and escaped ENUM labels, exact multibyte labels, all 64 SET members in order and
their defaults. Cleanup retires both histories and keeps matrix_choiceboundaries
current. Final state is STOPPED with no active GTID, at the shared restart check's
later offset. Two successful applier invocations are recorded: initial apply and
that existing restart. The restart writes reverse_poc.aux; it does not write each
ENUM/SET table. This case adds no per-case lifecycle transition or offline replay.

No other integration case/profile, full suite, benchmark or syntax suite ran
locally. Selection tooling and runner code did not change, so their Python tests
were not repeated. Leave other profiles, variants and whole-group validation to CI.

Evidence:

- `artifacts/lab/20261104T202737Z-a949ecd8/result.json`
- `artifacts/choice-boundaries-workflow-review/results.json`
- `artifacts/choice-boundaries-workflow-review/state-results.json`
- `artifacts/choice-boundaries-workflow-review/source-manifest.json`
- `artifacts/choice-boundaries-workflow-review/inventory-results.json`
- `artifacts/choice-boundaries-workflow-review/verify.py`
- `artifacts/choice-boundaries-workflow-review/unit.log`

The choiceboundaries conversion is committed as `247bbbe`. The next section
records its separate legacybinaryset follow-up and local completion review.

## Legacy binary SET implementation and local completion

Step 6 is complete. matrix-legacybinaryset now uses preparation and body batches
with one retained history. Its definition, two scripts, two predicates and both
8.4 exclusions remain unchanged. Its row-metadata override remains unset; do not
claim FULL optional metadata on this 5.7 source. The helper, shared runner,
cold metadata inputs and raw schema parser are unchanged. No production parser,
decoder or applier code changed.

Preparation creates the original table and ls_after_insert. The original compound
ALTER/UPDATE/DELETE remains one client request with three source GTIDs. The body
runs both original scripts before the retained INSERT. Each request keeps its
session reset. Two complete row queries check raw FF/61 bytes, SET masks and NULL.
Two default queries check FF2C61 before ALTER and FF afterward. Cleanup drops
only ls_after_insert; the original matrix table remains current.

Focused checks passed:

- 80 Swift tests: seven new legacy workflow tests and the 73 tests selected for choiceboundaries.
- Strict Swift format lint on the changed source file and eleven test files.
- Catalog structure and normalized matrix comparison: 183 jobs, 1,545 catalog
  obligations and 182 instrumented collections. Selection and order are unchanged.
- Source audit: original definition/scripts/predicates and version exclusions,
  all other cases, metadata inputs, helper, runner and raw schema oracle are
  unchanged. Inventory normalization excludes display names, source locations,
  assertion descriptions and the source-input fingerprint.

The tests check exact SQL, compound request boundaries, source transaction counts,
original predicates, complete fixed rows, raw defaults, checkpoint counters,
cleanup ownership and the shared title. Negative checks reject UTF-8 conversion
or replacement of FF, wrong masks, NULL-to-empty substitutions, missing row updates,
an unchanged default, wrong transaction counts and a wrong cleanup offset.
They also confirm all seven value cases use the helper, while both 8.4 exclusions
and cold metadata inputs remain in place.

One integration case ran with coverage: mysql57-to-mysql57-myisam, default
variant, SQL transport, matrix-legacybinaryset. All 12 named assertions passed.
Source, native and target agree on original predicates, complete rows, default
bytes and schema comparisons. The SQL trace records six raw SHOW CREATE requests:
each of the two tables on each role. Raw engine checks confirm source InnoDB and
native/target MyISAM. The existing shared saved-schema restart passed.

| Measurement | Result |
|---|---:|
| Case execution | 4.82 seconds |
| Case SQL client calls | 32 |
| Source batches / client write requests | 3 / 6 |
| Applied transactions before cleanup / after cleanup | 7 / 8 |
| Applied DDL before cleanup / after cleanup | 3 / 4 |
| Changed rows before cleanup / after cleanup | 10 / 10 |
| Fixture setup | 14.85 seconds |
| Container startup, included in setup | 12.09 seconds |
| Coverage export | 1.66 seconds |
| Fixture cleanup | 10.83 seconds |
| Instrumented Swift lines executed / mapped | 7,897 / 20,880 |

Saved CI on this same profile reported 10.08 seconds and 96 calls. Its group
compared more accumulated poc tables. The local run selected one case and added
a retained table. This is not a controlled speed comparison. Coverage includes
setup and the shared restart; it does not establish individual-case equivalence
with the old group-level report.

Both checkpoint assertions confirm exact GTID sets, offsets and counter deltas.
Read-only final SQLite inspection confirms all eight expanded GTIDs are APPLIED.
The compound request's last GTID has its recorded request end offset. DDL and row
intents are DONE. Latest schemas retain ordered raw FF/61 SET members, default
mask 3/bytes FF2C61 in the history and mask 1/bytes FF in the current table.
Cleanup retires the history. Final state is STOPPED with no active GTID, at the
shared restart check's later offset. Two successful applier invocations are
recorded: initial apply and that existing restart. The restart writes
reverse_poc.aux; it does not write the binary SET table. This case adds no
per-case lifecycle transition or offline replay.

No other integration case/profile, full suite, benchmark or syntax suite ran
locally. Selection tooling and runner code did not change, so their Python tests
were not repeated. Leave the 5.7 InnoDB repeat, other variants and whole-group
validation to CI. Keep both native 8.4 exclusions with error 3507.

Evidence:

- `artifacts/lab/20261104T205048Z-5f1d809b/result.json`
- `artifacts/legacy-binary-set-workflow-review/results.json`
- `artifacts/legacy-binary-set-workflow-review/state-results.json`
- `artifacts/legacy-binary-set-workflow-review/source-manifest.json`
- `artifacts/legacy-binary-set-workflow-review/inventory-results.json`
- `artifacts/legacy-binary-set-workflow-review/verify.py`
- `artifacts/legacy-binary-set-workflow-review/unit.log`

### Completion check for the seven cases

All seven IDs remain, each with its original definition, scripts, predicates,
metadata input and version rules. The cases retain earlier values until final
queries, share their existing fixture/applier and add no per-case restart.
The focused runs below were separate runs, not one whole-group test. Runtime
line sets include fixture work and cannot prove per-case coverage equivalence.

| Case | Focused profile | Passed assertions | Seconds | SQL client calls |
|---|---|---:|---:|---:|
| matrix-choices | 8.4→5.7 MyISAM | 12 | 4.07 | 27 |
| matrix-widechoices | 8.4→5.7 MyISAM | 12 | 3.93 | 27 |
| matrix-binarychoices | 8.4→5.7 MyISAM | 14 | 5.53 | 37 |
| matrix-exactchoices | 8.4→5.7 MyISAM | 16 | 4.69 | 29 |
| matrix-enumzero | 8.4→5.7 MyISAM | 14 | 4.06 | 27 |
| matrix-choiceboundaries | 8.4→5.7 MyISAM | 13 | 3.73 | 27 |
| matrix-legacybinaryset | 5.7→5.7 MyISAM | 12 | 4.82 | 32 |

Step 7 retains the same 183 jobs and existing feature boundaries. It does not
require another local whole-group run. Full-matrix validation, new group timing,
balancing and short PR selection remain later work in the overall plan.

The [character and binary value review](BETA7_CHARACTER_BINARY_VALUE_WORKFLOW_REVIEW.md#implementation-results)
is complete. It keeps encodings, widestrings and zerowidth with their distinct
values and schema transitions. It records 30 saved passing executions, coverage
limits, complete row maps and a conversion order. No new build or database run
was needed for the initial review. Its later conversions passed 101 unit tests
and 48 forward assertions. The [data-type review](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md)
keeps all 25 IDs. The [type/value workflow results](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md#temporal-fractional-second-and-automatic-value-implementation-results)
record fifteen completed conversions. Next: binarydefaults, textdefaults, fixed and lob.
Continue remaining type/value and key/index work before full-matrix validation.
