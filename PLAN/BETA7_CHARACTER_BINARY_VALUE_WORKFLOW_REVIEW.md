# Character and binary strings: value and workflow review

Status: all three conversions passed focused unit and forward integration tests
and are committed as `415e94d`.
The seven ENUM/SET conversions are also locally complete; legacybinaryset is
committed as `88ff87c`. Full-matrix validation remains later.

## Decision and scope

Keep matrix-encodings, matrix-widestrings and matrix-zerowidth as separate named
cases in their current shared character-sets-collations fixture. None is fully
replaced by another case. All three fit DMLExecutionWorkflow without helper
changes: no setup SQL, custom ordering, replacement case or JSON-diff check.
Their original definitions and scripts match the saved CI commit efb3458.

Convert in this order: encodings, widestrings, zerowidth. Keep original definitions,
scripts and predicates. Run original scripts first, then their prefixes on
retained tables. Compare retained rows and schemas after the body batch. Keep
all four profiles and current variants. Leave feature-group changes, balancing
and short PR selection until the later full CI comparison. No production parser,
decoder, applier, JSON transport or native schema oracle change belongs here.

## MySQL terms and titles

Consult the MySQL manuals before assigning feature names. Use
[The CHAR and VARCHAR Types](https://dev.mysql.com/doc/refman/8.4/en/char.html),
[The BINARY and VARBINARY Types](https://dev.mysql.com/doc/refman/8.4/en/binary-varbinary.html),
[String Data Type Syntax](https://dev.mysql.com/doc/refman/8.4/en/string-type-syntax.html)
and [JSON value attributes](https://dev.mysql.com/doc/refman/8.4/en/json-attribute-functions.html).

The implementations use these reader-facing titles. IDs remain unchanged.

| Case | Title |
|---|---|
| matrix-encodings | Character and binary strings: encodings, key changes and JSON DECIMAL values |
| matrix-widestrings | VARCHAR and VARBINARY: large values, short updates and DELETE |
| matrix-zerowidth | String data types: zero-length columns, NULL values and width changes |

Character column lengths use characters; binary column lengths use bytes.
CHAR retrieval removes trailing spaces under the fixture session settings.
BINARY pads with zero bytes; VARBINARY preserves the supplied bytes.
CHAR CHARACTER SET binary creates a BINARY column. It does not merely select a
_bin collation. Keep these differences in the encoding case.

VARCHAR(20000) has a two-byte length prefix. Updating an 18,000-byte value to two
bytes does not change the declaration or its prefix size. The wide-string case
tests large-to-short values in those columns. The zero-length case changes the
actual declarations, from length zero to four and back. Do not call either test
a packet-limit test. The separate large-values workflow tests packet limits,
fragmentation, restart and replay.

JSON_TYPE distinguishes DECIMAL from DOUBLE. Keep that type check with the
numeric value; serialized JSON text alone is insufficient. Keep the existing
server-based JSON comparison. Do not derive expectations with the production
character converter, JSON decoder or schema parser.

## Saved measurements and coverage limits

The complete saved run is 40454033524 at efb3458. It has no failed or missing
shards and no missing coverage. These three cases have 30 passing SQL executions:
four default and four lowercase-tables executions per case, plus the two forward
positioning/metadata variants. All 12 default executions passed.

The table shows seconds / harness SQL client calls. These are not applier SQL
statement counts.

| Default case | 8.4→5.7 MyISAM | 5.7→8.4 InnoDB | 5.7→5.7 MyISAM | 5.7→5.7 InnoDB |
|---|---:|---:|---:|---:|
| matrix-encodings | 19.07 / 172 | 13.98 / 171 | 19.66 / 186 | 17.20 / 186 |
| matrix-widestrings | 14.42 / 130 | 10.17 / 129 | 14.98 / 141 | 13.48 / 141 |
| matrix-zerowidth | 16.72 / 148 | 12.06 / 147 | 17.08 / 162 | 14.35 / 163 |

Forward encodings/zerowidth each make 15 schema-comparison client calls;
widestrings makes 12. These correspond to one full schema read per role after
CREATE and each original phase. Additional row and default reads are recorded
separately. Later cases also compare more accumulated poc tables. A future
single-case run with retained tables will have different inputs. Do not present
that comparison as a controlled speed measurement.

Coverage belongs to the whole character-sets-collations group, not each case.
Rechecking the saved default/SQL groups gives:

| Profile | Group lines hit | Absent from other same-profile default correctness groups |
|---|---:|---:|
| mysql57-to-mysql57-innodb | 9,941 | 188 |
| mysql57-to-mysql57-myisam | 9,853 | 188 |
| mysql57-to-mysql84-innodb | 9,975 | 191 |
| mysql84-to-mysql57-myisam | 9,743 | 96 |

The largest individual overlap is with table-column-index-changes, at
95.11–96.20% of this group's executed lines. The remaining lines include table
encoding, SQL encoding and DDL/schema paths. This does not assign any line to
one of these three cases. It cannot prove that one byte value, schema width,
NULL transition or JSON scalar type replaces another. No per-case line-coverage
claim or unit-plus-group comparison is made. New full-group measurements remain
part of the later CI run.

## Feature ownership and overlap

| Case | Distinct conditions to retain | Why nearby tests do not replace it |
|---|---|---|
| encodings | latin1/ascii/utf8, NUL/high bytes, CHAR trimming, BINARY zero padding, stored primary-key bytes with case-insensitive UPDATE/DELETE, JSON DECIMAL, added CHAR default | Native encoding vectors use other table/key layouts and do not include this combined JSON/key/binary/default sequence. fixed uses different padding and Unicode boundaries. |
| widestrings | VARCHAR(20000)/VARBINARY(20000), both 18,000-byte values, full large payload, short replacements with NUL/high bytes, empty final table | Small vectors do not exercise these large values. TEXT/BLOB and packet-limit tests use different column metadata and deliberate lifecycle checks. |
| zerowidth | CHAR(0)/VARCHAR(0)/BINARY(0)/VARBINARY(0), UTF-16 VARCHAR(0), empty versus NULL, widening and shrinking with following DML | Ordinary empty values in nonzero-width columns do not test zero-length column metadata or its schema transitions. |

The current runner already shares containers and an ordinary applier. It waits,
checks a predicate and compares schemas/rows after CREATE and every phase.
Do not describe this cost as restarting the applier after every phase. Retained
histories replace repeated observations; they preserve values which later writes
would destroy. They add source writes and state. Keep that cost visible.

Keep all three cold metadata fixtures, definitions and first INSERTs. None maps
to another representative in MetadataDiscoveryCases. Keep rowMetadata unset on
all three; 8.4 inherits the selected variant, and 5.7 uses its existing metadata
path. Encodings and zerowidth belong to metadata-labels-defaults; widestrings
belongs to metadata-columns-indexes. Do not silently force FULL or add later DML phases to discovery.

## Retained results and fixed expectations

All byte values below are hex. Empty hex means zero bytes; it differs from SQL
NULL. value-maps.json records every field of every row. Its JSON values keep
DECIMAL type and decimal strings. These are review expectations, not new runtime
observations.

### encodings

Create ev_after_insert, ev_after_update and ev_after_add with the original
definition. Retain the original matrix table for its final phase. Keep every
original predicate on the matching history, changing only the table token.

| Prefix | First row | Other row |
|---|---|---|
| INSERT | id E9; c E9; v 0080FF20; t E980FF00; a 410020; u E4B8AD; b FF200000; JSON n DECIMAL 1.25 | id 7365636F6E64; c/t/b/doc NULL; v/a/u empty |
| UPDATE | id C958; c E9; v FF00E9; t E980FF00; a 4E657874; u C3A9; b FF200000; JSON n DECIMAL 2.50 | Unchanged |
| ADD and UPDATE | Updated row above, t E900FF and extra 5A | Original other row plus extra 78 from the added default |
| DELETE | First row absent, using the original case-insensitive predicate | Other row remains, including extra 78 |

Use complete row queries with HEX for all string/binary columns, explicit NULL
markers, JSON_TYPE and a fixed decimal value check. Keep the full server-based
JSON comparison and document shape check. JSON numeric formatting must not be
normalized through a host floating-point value. Read the retained initial and
added column defaults in schema comparisons. Verify stored key C958 separately
from the case-insensitive predicates; equality alone can hide changed case bytes.

### widestrings

Create ws_after_insert and ws_after_update. Keep exact large patterns: v is E9
repeated 18,000 times; b is FF00 repeated 9,000 times. Check lengths and complete
payloads, not only RIGHT(v,1) and RIGHT(b,2). Fixed SQL equality against those
REPEAT patterns can report a small boolean result without exporting huge strings.
Use no hash or production converter as the value oracle.

The updated history keeps v 00FF and b FF. The original final table must be
empty. Keep all three old predicates. Its column declarations stay unchanged.

### zerowidth

Create zw_after_insert, zw_after_update and zw_after_widen. Keep all four old
predicates and the original compound requests.

| Prefix | Row 1 | Row 2 | Schema |
|---|---|---|---|
| INSERT | c/v/b/w/u all empty | All NULL | All five lengths zero |
| Two UPDATEs | All NULL | All empty | Unchanged |
| Widen and UPDATE | c/b NULL; v 6869; w FF00; u 4E2D | All empty | v/w/u length four; defaults 78/FF/4E2D |
| Clear, shrink and DELETE | c/b NULL; v/w/u empty | Absent | All lengths zero; empty defaults restored |

Check every field with explicit NULL markers. Retain both the wider schema and
its defaults until the final read. Keep c CHAR(0) and b BINARY(0) unchanged
throughout. Do not move the clear UPDATE after the shrinking ALTER. It prevents
truncation of nonempty values. Cleanup drops only the retained histories.

## Source effects and checkpoints

Do not split original scripts or add BEGIN/COMMIT. Client requests and source
GTIDs are different counts. Histories run the exact original prefixes after the
original scripts. Each batch write keeps the profile session reset. The proposed
counts include original and retained tables:

| Case | GTIDs per original phase | Prepare writes | Body writes / GTIDs | Before cleanup: GTIDs / DDL / rows | After cleanup: GTIDs / DDL / rows |
|---|---|---:|---|---|---|
| matrix-encodings | 1/1/2/1 | 4 | 10 / 12 | 16 / 6 / 14 | 17 / 7 / 14 |
| matrix-widestrings | 1/1/1 | 3 | 6 / 6 | 9 / 3 / 6 | 10 / 4 / 6 |
| matrix-zerowidth | 1/2/2/3 | 4 | 10 / 17 | 21 / 7 / 18 | 22 / 8 / 18 |

The focused runs below confirm these source-inspection predictions on the
forward/default/SQL profile. Each cleanup is one DROP TABLE listing only that case's retained tables.
It adds one DDL and one GTID, with no row events. Keep the original table current.

Keep exact GTID-set, file/offset and counter-delta assertions before and after
cleanup. Expand multi-GTID intervals in saved-state inspection. Only the last
GTID of a compound request must match its recorded request end offset. Read
SQLite in read-only mode after the existing shared stop. Check APPLIED groups,
DONE intents, current originals, retired histories and saved schemas/defaults.
The shared restart writes reverse_poc.aux; it does not write these tables after
restart. Add no per-case restart or replay for this fixture-only conversion.

## Implementation slices and local validation

1. Convert only matrix-encodings. Use the existing helper with three histories.
   Keep all four old predicates and add complete field, key-byte, typed JSON and
   default checks. Add focused unit tests for original SQL/bytes, metadata inputs,
   session resets, request order, counts, fixed results and cleanup. Run helper
   and existing opt-in fixture tests when their membership list changes. Check
   catalog structure, normalized matrix membership/order and strict format lint.
2. Run only matrix-encodings on mysql84-to-mysql57-myisam/default/SQL with coverage.
   Inspect its complete observations, GTIDs/offsets, counters, saved schemas,
   cleanup, engine checks and existing shared restart. Record case time, client
   calls, setup/startup/coverage/cleanup and runtime line counts. Keep the saved
   comparison limits above. Leave other profiles and variants to CI.
3. Convert widestrings separately. Unit-test both complete repeated byte patterns,
   exact short values and empty final state. Run only that forward case with
   coverage. Do not rerun encodings locally after unrelated fixture edits.
4. Convert zerowidth separately. Unit-test all NULL/empty fields, both intermediate
   schemas/defaults, compound SQL order, counts and cleanup. Run only that forward
   case with coverage. Leave other profiles and whole-group checks to CI.
5. Keep the same 183 jobs, 1,545 catalog obligations and 182 instrumented
   collections. Do not change feature boundaries in these slices. Run selection
   tooling tests only when that tooling or its wiring changes. Run no syntax
   suite for fixture-only edits. Continue remaining type/value and key/index
   reviews before full-matrix validation, balancing and short PR selection.

On failure, inspect the printed support bundle before a rerun: failure.json,
bundle.json, read-only SQLite and logs. Keep the original evidence. Check the
harness error and collection error if no bundle exists.

The initial review ran only source/evidence scripts. They verified the original
inputs, 30 saved passing executions and same-profile group coverage sets. The
later implementation checks and their limits are recorded below.

Evidence under artifacts/character-binary-values-review/:

- baseline.json: all 30 saved executions, case timings and client call counts.
- source-review.json: exact definitions/scripts/predicates and predicted effects.
- value-maps.json: fixed full row maps, large-byte patterns and schema/default maps.
- coverage-review.json: historical group-level intersections and file/line sets.
- review.py and review.log: reproducible source, measurement and coverage checks.
- maps.py: independent byte-pattern and row-map calculations.

All three implementation slices below are complete locally. Keep the stated
profile and whole-group limits; these results do not replace full CI validation.


## Implementation results

The three cases now use the existing DMLExecutionWorkflow. No helper, native
schema/JSON oracle, production parser, decoder or applier code changed. Original
definitions, scripts, eleven predicates, first-INSERT metadata inputs and source
metadata settings remain. Existing opt-in membership tests now include the three
cases. No case, profile, variant or native version limit was removed.

Encodings retains three histories. Four complete row queries check stored key
case, all character/binary fields, JSON object shape, DECIMAL type and exact
numeric values. Two further queries check UTF-8 and added CHAR default bytes.
The server-based JSON comparison remains active and checks scalar text bytes.

Widestrings retains two histories. Its fixed REPEAT comparisons check every byte
of both 18,000-byte payloads. The other queries require exact short replacements
and an empty original table after DELETE. No hash or production converter is used.

Zerowidth retains three histories. Four row queries keep empty fields and NULL
separate. Three schema queries check the initial, widened and final declarations.
Three default queries check all five defaults, including all-empty result fields.
The clear UPDATE still precedes the shrinking ALTER. It preserves the original
compound source request and transaction order.

### Focused verification

- 101 Swift tests passed: 12 new character/binary workflow tests, the 80 existing
  helper/fixture/metadata/native-schema tests selected for legacybinaryset, and
  nine JSON comparison tests.
- Strict Swift format lint passed for both changed source files and 12 test files.
- Catalog structure passed. Normalized planning retains 183 jobs, 1,545 catalog
  obligations and 182 instrumented collections, with unchanged membership/order.
- The source audit restores the old files by removing only the added workflows.
  It confirms original definitions/scripts/predicates, other cases, metadata,
  helper, runner and native schema/JSON oracles are unchanged. Matrix comparison
  excludes display names, source locations, assertion descriptions and inputs.

The tests reject changed key case, wrong encodings, lost BINARY padding,
DECIMAL-to-DOUBLE substitutions, unchanged JSON values, NULL-to-empty changes,
lost trailing fields, incomplete large payloads, a missed DELETE, wrong widths,
wrong counters and wrong saved offsets. Exact SQL tests retain compound request
boundaries and session resets. Cold metadata tests cover all four profile mappings.

Three selected integration runs completed in order on
mysql84-to-mysql57-myisam/default/SQL, each with coverage. They used separate local
fixtures to retain per-case evidence. The regular CI group still shares one
fixture and ordinary applier across its cases. One coverage compilation served
all three runs; the second and third Docker builds reused its cached Swift layer.

| Case | Passed assertions | Seconds | SQL client calls | Saved CI seconds / calls |
|---|---:|---:|---:|---:|
| matrix-encodings | 16 | 6.72 | 51 | 19.07 / 172 |
| matrix-widestrings | 12 | 3.26 | 25 | 14.42 / 130 |
| matrix-zerowidth | 20 | 3.81 | 30 | 16.72 / 148 |

The saved cases compared more accumulated poc tables. The new local runs select
one case and add retained tables. These are observations across different inputs,
not controlled speed comparisons. Coverage includes shared setup and restart.
It cannot establish per-case equivalence with the old group-level line sets.

| Measurement | encodings | widestrings | zerowidth |
|---|---:|---:|---:|
| Source client writes | 15 | 10 | 15 |
| Applied transactions before / after cleanup | 16 / 17 | 9 / 10 | 21 / 22 |
| Applied DDL before / after cleanup | 6 / 7 | 3 / 4 | 7 / 8 |
| Changed rows before / after cleanup | 14 / 14 | 6 / 6 | 18 / 18 |
| Fixture setup, seconds | 14.78 | 9.96 | 12.88 |
| Container startup, included in setup | 11.93 | 7.33 | 10.35 |
| Coverage export, seconds | 1.67 | 1.56 | 1.57 |
| Fixture cleanup, seconds | 10.81 | 10.77 | 10.77 |
| Swift runtime lines hit / mapped | 8,047 / 20,880 | 7,339 / 20,880 | 7,905 / 20,880 |

All 48 named assertions passed across the three runs. Each run confirms complete
source/native/target results, exact GTID sets and offsets, counter deltas and the
existing saved-schema restart. Raw engine checks confirm source InnoDB and
native/target MyISAM.

Read-only SQLite checks confirm all 17/10/22 case GTIDs are APPLIED. For compound
requests, each final GTID has its recorded request end offset. DDL and row intents
are DONE. Latest saved schemas keep character sets, collations, widths and defaults.
Encodings keeps the added CHAR default and the normalized BINARY(4) declaration.
Widestrings keeps both 20,000-length declarations. Zerowidth keeps the wider schema
in its history and zero lengths in the current table. Empty binary defaults use
the existing empty-string metadata; FF uses binaryDefaultBytes. These represent
the confirmed empty/FF default values without a new state format.

Cleanup retires only retained histories and leaves original tables current.
Final state is STOPPED with no active GTID, at the shared restart's later offset.
Each run records two successful applier invocations: initial apply and that shared
restart. The restart writes reverse_poc.aux; it does not write these three tables.
These changes add no per-case restart or offline replay.

No other integration case/profile, full suite, benchmark or syntax suite ran.
Selection tooling and runner code did not change, so their Python tests were not
repeated. Leave other profiles, variants and whole-group validation to CI.

Implementation evidence under artifacts/character-binary-values-implementation/:

- specs.json: frozen original SQL, retained histories, fixed checks and counts.
- encodings-results.json, widestrings-results.json and zerowidth-results.json:
  measurements, saved schemas and final-state checks.
- inspect.py and schema_check.py: read-only state and schema inspection.
- verify.py and inventory-results.json: original-input and matrix checks.
- unit.log, encodings.log, widestrings.log and zerowidth.log: selected run logs.
- build-results.json: identical image inputs and cached second/third build layers.

Selected lab results:

- `artifacts/lab/20261105T001524Z-d2c46d07/result.json`
- `artifacts/lab/20261105T002041Z-2da41b32/result.json`
- `artifacts/lab/20261105T002134Z-c9ac457d/result.json`

The [data-type review](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md) is complete.
It records 23 unchanged matrix fixtures, two isolated lifecycle workflows,
211 saved SQL executions and ten additional BINLOG executions. It keeps all
25 IDs and required event/restart/replay/recovery checks. The initial review
needed no new build or database run.
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
The [conflict workflow results](BETA7_KEY_CONFLICT_WORKFLOW_REVIEW.md#implementation-and-focused-results)
record all 11 original assertions and both exact no-op boundary checks passing.
Fifteen focused unit tests passed. Next: review INSERT SELECT, joined
UPDATE/DELETE and LOAD DATA in matrix-select/matrix-load.
Full-matrix validation, balancing and short PR selection stay later.
