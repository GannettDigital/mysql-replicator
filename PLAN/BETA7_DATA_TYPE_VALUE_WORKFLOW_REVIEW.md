# Data types: value and workflow review

Status: source and saved-evidence review complete. The first nine implementation
slices are complete locally. All twenty-three matrix type/value cases now use
the shared workflow. Partial JSON also keeps explicit source-event checks. All
focused checks passed.
The numeric and floating slices are committed as `345f71f` and `92df394`.
The legacy slice is committed as `269e76f`. The temporal slice is committed as
`fbcedd7`. The string-default/BLOB slice is committed as `0f74741`. The JSON
slice is committed as `b7ffe2d`. The spatial slice is committed as `948b682`.
The partial-JSON slice is committed as `97da9d6`.
See the results below.
The character/binary conversions are committed as `415e94d`. Full-matrix
validation remains later work.

## Decision

Keep all 25 original IDs in data-types-values and their existing execution
selections. Slice 7 also moves three related JSON cases into this group. The
group owns all seven JSON feature cases. Slice 8 moves the two related spatial
cases into it too. The group now owns all three Spatial Data Types cases. See
the Slice 7 and Slice 8 results below.
The review found distinct values, metadata and lifecycle conditions. It found
no complete case replacement. Do not remove a type test because another test
executes the same Swift lines or also contains INSERT/UPDATE/DELETE.

There are 23 matrix cases. All now use DMLExecutionWorkflow with retained
histories and final observations. Slice 9 adds the explicit source-event/offset
plan required for matrix-jsonpartial. Its JSON-diff guard remains strict. Keep
json-year-compatibility and large-values on their isolated apply/replay/recovery
paths.

The first implementation slice converted matrix-decimaldefaults. Its fixed
numeric expectations and small schema supplied the pilot. dd_after_insert and
dd_after_defaults retain overwritten values/defaults. That slice kept the helper
unchanged. Slice 9 adds only the explicit source-event plan needed for partial
JSON. All slices preserve original SQL/predicates, native schema/default/JSON
oracles and production code.

These cases already share their CI fixture and ordinary applier. Repeated
per-phase waits and schema/row reads are the conversion target. The current
runner does not restart the applier after every ordinary phase. Adding another
feature label must not create another job or restart the containers.

## MySQL terms and names

Consult the MySQL manuals before naming a feature:

- [Numeric Data Types](https://dev.mysql.com/doc/refman/8.4/en/numeric-types.html):
  integer, fixed-point, floating-point, bit-value and numeric attributes.
- [Date and Time Data Types](https://dev.mysql.com/doc/refman/8.4/en/date-and-time-types.html):
  DATE, DATETIME, TIMESTAMP, TIME, YEAR and fractional seconds.
- [String Data Type Syntax](https://dev.mysql.com/doc/refman/8.4/en/string-type-syntax.html):
  character versus binary columns and declared lengths.
- [Spatial Data Types](https://dev.mysql.com/doc/refman/8.4/en/spatial-types.html):
  geometry types, collections, spatial reference systems and spatial indexes.
- [The JSON Data Type](https://dev.mysql.com/doc/refman/8.4/en/json.html):
  document values, native scalar types and partial updates.

Use descriptive case titles within the existing shared fixture. Logical feature
sections do not require separate CI jobs. Candidate sections are Numeric Data
Types, Date and Time Data Types, String Data Types, JSON, and Spatial Data Types.
Preserve existing IDs and scheduling until the later timing/balance review.

## Saved measurements

The saved run is 40454033524 at efb3458. The measurement report is complete,
with no failed/missing shards or missing coverage. The current 25-case area list
matches that saved list. All 23 matrix definitions/scripts/predicates and both
isolated workflow implementations match the saved source. There are 81 matrix
phases. At the review baseline, no matrix case in this area had opted into the
shared helper.

The saved evidence contains 211 SQL executions for these IDs, including 86
default executions. It also contains ten BINLOG executions outside the ordinary
SQL area: matrix-json and matrix-typedjson on all four default profiles, and
matrix-jsonpartial/json-year-compatibility on their applicable default profiles.
All 221 executions passed. Preserve these extra transport selections when changing
fixtures. Do not count them as additional SQL-area default tests.

Default SQL case measurements below are seconds / harness SQL client calls.
They are not target applier statement counts. A dash means the profile excludes
that case.

| Case | 8.4→5.7 MyISAM | 5.7→8.4 InnoDB | 5.7→5.7 MyISAM | 5.7→5.7 InnoDB |
|---|---:|---:|---:|---:|
| matrix-decimaldefaults | 6.90 / 58 | 6.35 / 57 | 6.41 / 57 | 6.12 / 57 |
| matrix-floatbounds | 11.76 / 106 | 10.06 / 93 | 9.82 / 93 | 9.77 / 93 |
| matrix-zerofill | 14.87 / 133 | 12.60 / 117 | 12.38 / 117 | 12.36 / 117 |
| matrix-fixedfloating | 14.97 / 133 | 12.64 / 117 | 12.36 / 117 | 12.42 / 117 |
| matrix-floating | 18.06 / 160 | 15.31 / 141 | 14.91 / 141 | 15.04 / 141 |
| matrix-bits | 14.90 / 133 | 12.84 / 117 | 12.34 / 117 | 12.38 / 117 |
| matrix-integers | 12.03 / 106 | 10.01 / 93 | 10.03 / 93 | 9.93 / 93 |
| matrix-decimal | 11.93 / 106 | 9.95 / 93 | 9.94 / 93 | 9.90 / 93 |
| matrix-temporal | 12.10 / 106 | 10.02 / 93 | 9.84 / 93 | 9.92 / 93 |
| matrix-precision | 9.09 / 79 | 7.44 / 69 | 7.34 / 69 | 7.36 / 69 |
| matrix-floatingautofloat | — | — | 12.55 / 117 | 12.61 / 117 |
| matrix-floatingautodouble | — | — | 12.58 / 117 | 12.53 / 117 |
| matrix-floatingautofixedfloat | — | — | 12.66 / 117 | 12.57 / 117 |
| matrix-floatingautounsigneddouble | — | — | 12.56 / 117 | 12.57 / 117 |
| matrix-binarydefaults | 8.32 / 70 | 7.61 / 69 | 7.67 / 69 | 7.42 / 69 |
| matrix-textdefaults | 8.31 / 70 | 7.68 / 69 | 7.71 / 69 | 7.40 / 69 |
| matrix-spatial | 10.41 / 88 | 9.62 / 87 | 9.71 / 87 | 9.41 / 87 |
| matrix-json | 13.16 / 112 | 12.00 / 111 | 12.03 / 111 | 11.70 / 111 |
| matrix-typedjson | 14.35 / 124 | 13.17 / 123 | 13.17 / 123 | 13.00 / 123 |
| matrix-jsonpartial | 16.68 / 146 | — | — | — |
| matrix-fixed | 11.84 / 106 | 10.03 / 93 | 9.85 / 93 | 9.89 / 93 |
| matrix-lob | 12.49 / 106 | 10.28 / 93 | 10.16 / 93 | 10.23 / 93 |
| matrix-defaults | 12.13 / 106 | 10.08 / 93 | 9.94 / 93 | 10.08 / 93 |
| json-year-compatibility | — | 29.76 / 60 | — | — |
| large-values | 53.64 / 74 | 55.38 / 68 | 52.55 / 73 | 54.26 / 68 |

| Default SQL group | Cases | Test execution seconds | SQL client calls |
|---|---:|---:|---:|
| mysql57-to-mysql57-innodb | 23 | 288.87 | 2315 |
| mysql57-to-mysql57-myisam | 23 | 288.49 | 2331 |
| mysql57-to-mysql84-innodb | 20 | 272.82 | 1907 |
| mysql84-to-mysql57-myisam | 20 | 287.96 | 2186 |

CREATE and every ordinary phase trigger schema/row comparison. Those reads also
include earlier accumulated poc tables. Later cases therefore have different
comparison inputs from earlier cases. Do not rank a case's feature value by its
call count alone. A future single-case run with new histories will also have
different inputs; it cannot establish a controlled before/after speed ratio.

large-values takes about 53–55 seconds, but uses only 68–74 client calls. Its
packet, restart, replay and recovery checks are deliberate work. Do not remove
those steps to make it resemble an ordinary row-value case.

## Coverage scope and limits

Compare default SQL groups only with other default SQL correctness groups on
the same profile. Exclude BINLOG groups from this comparison. The saved sets give:

| Profile | Area lines hit | Absent from other default SQL correctness groups |
|---|---:|---:|
| mysql57-to-mysql57-innodb | 11,231 | 36 |
| mysql57-to-mysql57-myisam | 10,633 | 19 |
| mysql57-to-mysql84-innodb | 11,328 | 56 |
| mysql84-to-mysql57-myisam | 10,657 | 18 |

The largest individual overlap is with keys-rows-gtids: 93.70–95.09%. The lines
outside other SQL groups include binary-default metadata, packet/target handling,
DDL parsing and recovery. On reverse InnoDB they also include JSONDocument and
JSONSQL paths. Including BINLOG groups would reduce that reverse count from 56
to 36; that is a different comparison scope.

Coverage is attributed to the whole group. It does not identify which case owns
a line or prove value/branch equivalence. It excludes the Rust decoder, which
handles binlog type layouts. It also excludes lab code. No unit-plus-area union
or per-case code-coverage claim is made. Keep native value assertions and use the
later full CI run for the changed group comparison.

## What each case adds

| Feature / IDs | Conditions to retain |
|---|---|
| DECIMAL defaults — decimaldefaults | Positive/negative half rounding; numeric, quoted and exponent defaults; ZEROFILL/UNSIGNED; SET/DROP DEFAULT; scale change; ADD fills existing rows; explicit NULL after DROP DEFAULT. |
| Integer types — integers | Signed/unsigned TINYINT, SMALLINT and MEDIUMINT extrema; signed primary key changes; NULL; unaffected row and DELETE. |
| Fixed-point values — decimal | DECIMAL(65,30) negative/positive extrema, unsigned DECIMAL, scale equal to precision, NULL and small positive fractions. Small default values do not replace these values. |
| Bit-value type — bits | BIT(1/7/8/9/63/64), high bit and unsigned maximum, BIT(64) primary key changes, NULL, width change and new bit default. SET masks use different metadata. |
| Numeric attributes — zerofill | Display widths, implicit UNSIGNED, defaults, integer/decimal/floating/YEAR fields, width changes, ADD default and maximum unsigned values. |
| Floating-point values — floatbounds | FLOAT(M,D) boundary rounding to 1,000,000; FLOAT primary key changes; signed/unsigned fields. |
| Floating-point defaults — fixedfloating | FLOAT/DOUBLE(M,D), default rounding, extreme exponents, NULL row, changed DOUBLE primary key and changed declarations/defaults. |
| Floating-point range — floating | FLOAT versus DOUBLE; normal/subnormal minima and maxima; default value, DOUBLE primary key and FLOAT(25) declaration change. |
| Legacy AUTO_INCREMENT — four floatingauto* IDs | FLOAT, DOUBLE, FLOAT(M,D) and unsigned DOUBLE AUTO_INCREMENT; explicit zero under NO_AUTO_VALUE_ON_ZERO, explicit key changes, next generated value, ADD and DELETE. Keep both 8.4 exclusions with native error 1063. |
| Binary defaults — binarydefaults | Raw bytes, NUL/empty defaults, fixed BINARY padding, binary CHAR, numeric versus quoted defaults, hex/bit syntax, changed width, ADD and DROP DEFAULT. |
| Character defaults — textdefaults | Supplementary/decomposed Unicode, retained spaces in VARCHAR, CHAR padding, latin1/UTF-16 bytes, numeric/quoted literals, NUL default, PAD_CHAR_TO_FULL_LENGTH, MODIFY/ADD/DROP DEFAULT. |
| Fixed-length strings — fixed | CHAR(255), supplementary/decomposed characters, trailing-space removal, full-length UPDATE, BINARY(8) padding, empty versus NULL and surviving empty row. |
| BLOB/TEXT types — lob | All four BLOB/TEXT length families, 70,000-byte payloads, binary/NUL/quote/backslash/Unicode data, prefix index, empty/NULL transitions and deletion. VARCHAR(20000) tests use different type metadata. |
| Date/time types — temporal | DATE, DATETIME(6), TIMESTAMP(6), TIME(6), YEAR; +05:30 source session, UTC reads, zero dates, negative TIME, range endpoints, NULL and DELETE. |
| Fractional seconds — precision | TIME precisions zero through six, DATETIME/TIMESTAMP precision variants, negative subsecond values, transition to zero and NULL. |
| Automatic values — defaults | Integer AUTO_INCREMENT, explicit zero/20, ordinary defaults and CURRENT_TIMESTAMP(6) ON UPDATE under two fixed source timestamps. |
| JSON values — json | Unsigned/signed 64-bit numbers, integer above 2^53, DOUBLE, arrays, strings, SQL NULL versus JSON null, empty object, primary key change, ADD JSON column and deletion. |
| Native JSON scalars — typedjson | DECIMAL(65,30), temporal scalars, TIMESTAMP, zero dates, unsigned integer, BLOB/BINARY/VARBINARY/BIT subtypes and empty final state. Preserve server-based type/scalar checks. |
| Partial JSON — jsonpartial | Full initial document, PARTIAL_JSON updates, DECIMAL/DATE path changes, array removal and proof of an actual source diff event. 8.4-source only. |
| JSON YEAR policy — json-year-compatibility | Reverse-only refusal before lossy write, checkpoint, explicit conversion, policy-change refusal, key change, restart, fetch, partial replay and resume; BINLOG-to-SQL routing when selected. |
| Large events and recovery — large-values | Values around 1 MiB and above the 16 MiB packet boundary, fragmented UPDATE/DELETE responses, fetch/replay/resume, source event limit, target packet refusal, pending evidence and engine-specific recovery. |

There is shared code between these rows, but no complete assertion replacement.
For example, FLOAT and DOUBLE have different row widths; BIT and SET have different
metadata; DECIMAL inside JSON has a different representation from a DECIMAL
column. Keep the different native limits, declared types and value transitions.

## Boundaries which must remain explicit

- jsonpartial has expectsJSONDiff on two phases. verifyJSONDiff reads the source
  file between saved before/end offsets and uses MySQL 8.4 mysqlbinlog to require
  JSON_REPLACE/JSON_INSERT/JSON_REMOVE output. Final rows alone cannot prove a diff
  event was emitted. The current helper rejects this flag. A later conversion
  needs request-specific saved offsets and bounded event checks; never clear the
  flag to make the helper accept it.
- json-year-compatibility has a refused state, a separate policy-enabled state,
  reset target GTIDs, three live segments, changed-policy refusal, archive fetch
  and two replay segments with source access disabled. Keep this isolation.
- large-values has three live segments, replay stop/resume, an event-size refusal,
  a target packet refusal and pending-row inspection. InnoDB uses audited retry;
  MyISAM refuses blocked-state restart and starts a reconciled state after checking
  that no write occurred. Keep the different engine paths and packet settings.
- Preserve source SET statements inside their original client requests. temporal
  changes time_zone for its INSERT; defaults sets two timestamps; textdefaults
  enables PAD_CHAR_TO_FULL_LENGTH inside its second request. Each following request
  must reset the profile session before its own SQL. Do not hoist these settings.
- Keep original metadata discovery definitions, representatives and first INSERTs.
  typedjson/jsonpartial use the json representative; other mappings must remain.
  Keep rowMetadata unset on all 23 matrix cases. Keep existing profile/variant and
  BINLOG selections. A batching change must not force FULL metadata everywhere.

## Decimal-default pilot

Title: **Fixed-point types: DECIMAL default rounding and scale changes**.
No source operation changes. The three original phase transaction counts are
1/2/3; ALTER implicitly commits. Keep original SQL first, then exact prefixes on
dd_after_insert and dd_after_defaults. These names have no current source owner.

Use full fixed row checks on both histories and the current table. Keep each of
the three old predicates on its corresponding result. Preserve numeric values
as decimal strings. Cast ZEROFILL values to DECIMAL for numeric comparisons and
check their declared attributes separately. Do not use host floating-point math.

| Result | Fixed values to preserve |
|---|---|
| INSERT | Two rows: a 1.24, b -1.24, c/d 1.01, z 10.00, u 0.01, n 0. |
| First ALTER and UPDATE | Row 1 a/b/c become 2.35/-2.35/2.68; row 2 keeps old values. Both gain extra 10.00; d stays 1.01. |
| Final ALTER, INSERT and DELETE | Row 1 keeps updated values, d becomes 1.010. Row 3 uses new defaults, d 1.235 and explicit u NULL. Row 2 is absent. |

Final schema checks must keep d's scale change from two to three, extra's default,
u's removed default and z's ZEROFILL/UNSIGNED attributes. Read actual stored
defaults through the existing native resolver. Numeric value checks alone do not
prove that metadata was kept. decimal-pilot.json records every field, exact SQL
and a decimal-arithmetic cross-check. These were proposed expectations at review time. The focused implementation
run below confirms them against source, native replica and target.

| Pilot measurement, later confirmed | Value |
|---|---:|
| Preparation client writes / GTIDs | 3 / 3 |
| Body client writes / GTIDs | 6 / 10 |
| Before cleanup GTIDs / DDL / changed rows | 13 / 6 / 10 |
| Cleanup client writes / GTIDs | 1 / 1 |
| After cleanup GTIDs / DDL / changed rows | 14 / 7 / 10 |

Cleanup drops only the two histories. Keep the original table current. Preserve
exact GTID sets, source file/offsets, counter deltas and request boundaries. Expand
multi-GTID intervals when reading SQLite. Only each request's final GTID must
match its recorded request end offset. Read the database in read-only mode after
the shared stop. Check APPLIED groups, DONE intents, current/retired schemas and
stored defaults. Preserve the shared saved-schema restart without adding a new
per-case restart or offline replay.

## Conversion order and local checks

| Slice | Change | Local validation after the change |
|---|---|---|
| 1, complete locally | Only decimaldefaults; two histories and fixed decimal/schema/default checks | Focused workflow/helper/metadata unit tests, updated opt-in membership tests, strict format lint, catalog and normalized matrix audit. One forward/default/SQL case with coverage and saved-state inspection. |
| 2, complete locally | integers, decimal and bits as separate named cases with retained outcomes | Unit-test exact numeric strings, unsigned high bits, NULL and key/width changes. Run the changed cases together in one forward fixture; reuse one build. |
| 3, complete locally | zerofill, floatbounds, fixedfloating and floating | Keep native numeric comparisons, distinct FLOAT/DOUBLE metadata, rounding and retained key results. Select only changed cases in one forward fixture. Do not convert expectations through host Double by default. |
| 4, complete locally | All four legacy floating AUTO_INCREMENT cases through their shared template | Unit-test all generated SQL, declared types, both native error-1063 exclusions and session reset. Select all four changed cases in one 5.7-to-5.7 MyISAM fixture. Leave InnoDB and excluded profiles to CI. |
| 5, complete locally | temporal, precision and defaults | Fixed time/precision, zero/NULL, generated IDs and automatic timestamp checks. Unit-test source time_zone/timestamp placement and resets. Select changed cases in one forward fixture. |
| 6, complete locally | binarydefaults, textdefaults, fixed and lob | Independent bytes/defaults, source PAD mode, complete large payloads, lengths and empty/NULL states. Preserve native schema/default comparison. Select only changed cases in one forward fixture. |
| 7, complete locally | json and typedjson | Fixed paths, native scalar types, exact decimal/integer strings and unchanged server-based JSON oracle. Select both changed cases in one forward SQL fixture. Preserve extra BINLOG selections for CI. |
| 8, complete locally | spatial | Every geometry type, SRID, empty/NULL collections, key changes and SPATIAL index metadata. One forward case with coverage. Do not substitute display WKT for exact geometry checks. |
| 9, complete locally | Explicit jsonpartial event plan and shared execution | Preserve original bounded source-binlog checks and two diff phases. Test changed offset/event validation with one forward selected case and the 8.4 decoder. Do not bypass the helper guard. |
| 10 | Reassess area completion and remaining key/index work | Source/assertion/selection audit first. Keep lifecycle cases unchanged unless their own review identifies a concrete safe change. No whole-suite local rerun. |

Each ordinary conversion needs complete retained observations, body/cleanup
checkpoint checks, final state/schema inspection and engine checks. Keep original
source definitions and statement order. Inspect the support bundle before a
failed-case rerun. Record named assertions, case time, SQL calls and separated
setup/startup/coverage/cleanup costs. Current shared restart writes reverse_poc.aux;
it is not a dedicated post-restart write to every new history table.

Do not repeat unaffected integration cases or other profiles locally. Reuse one
coverage build when several cases change together. Run selection-tool tests only
when that tooling changes, and no syntax suite for fixture-only changes. Keep
183 jobs, 1,545 catalog obligations and 182 instrumented collections during these
conversions. The later full CI run supplies new group coverage and balance data;
select the short PR checks afterward.

The initial review ran only source/evidence scripts. It made no new target
support or speed claim. Implementation checks are recorded separately below.

Evidence under artifacts/data-types-values-review/:

- source-review.json: all 23 exact definitions and 81 SQL/predicate phases,
  template expansions, metadata flags, applicability and helper eligibility.
- baseline.json: 211 SQL and ten BINLOG saved executions, timings, calls and group costs.
- coverage-review.json: same-profile default SQL intersections and exact file/line sets.
- decimal-pilot.json: original/prefix SQL, fixed row maps and predicted counts.
- review.py, review.log and pilot.py: repeatable source and saved-evidence checks.
- SharedJSONYear.swift and SharedLargeValues.swift: unchanged lifecycle source snapshots.

## Decimal-default implementation results

The first slice converted only matrix-decimaldefaults to DMLExecutionWorkflow.
The two
histories retain every earlier phase. Preparation, body and cleanup use the
existing running applier. Original source SQL, compound requests, predicates,
first-INSERT metadata inputs and profile selections remain unchanged. No helper,
runner, native schema/default/JSON oracle or production code changed.

The final observations include all three original predicates and nine added
queries. They check complete decimal rows, stored defaults, nullability, declared
scales and ZEROFILL/UNSIGNED attributes. Exact decimal strings avoid host
floating-point conversion. The final schema check verifies u's removed default;
the saved schema must also have no defaultValue for u.

The first integration run found a test-query error: DEFAULT(u) returns MySQL
error 1364 after DROP DEFAULT. The support bundle had no failure.json because
this was a harness read error. Bundle diagnostics, the body checkpoint and a
read-only SQLite inspection confirmed all 13 case GTIDs applied, DONE intents,
STOPPED state with no active GTID, and the removed default. The corrected final
query reads only defaults that still exist. Metadata and saved-state checks keep
the removed-default assertion. All original writes remain unchanged.

### Focused checks

- 99 selected Swift tests passed, including seven new DECIMAL workflow tests.
  They also cover helper behavior, cold metadata and the updated opt-in lists.
- After the query correction, only the seven DECIMAL tests ran again. All passed.
- Strict Swift format lint passed for the changed source and 13 test files.
  The corrected source and new test file passed lint again after that change.
- Catalog structure passed: 63 DDL scenarios, 235 registered cases and 56 support
  requirements. Normalized planning keeps 183 jobs, 1,545 catalog obligations and
  182 instrumented collections, with unchanged membership and order.
- The source audit removes only the added workflow and restores the original
  decimal fixture byte for byte. Other fixtures, metadata inputs, helper, runner
  and native oracles match HEAD. Display names, source locations, assertion
  descriptions and input fingerprints are excluded from matrix equality.

One corrected forward/default/SQL integration case passed with coverage:

| Case | Passed assertions | Seconds | SQL client calls | Saved CI seconds / calls |
|---|---:|---:|---:|---:|
| matrix-decimaldefaults | 18 | 3.56 | 27 | 6.90 / 58 |

The old CI case compared accumulated poc tables. This local run selects one
case and adds two retained tables. These are different inputs, so the table is
not a controlled speed comparison. The later full CI run must measure the group.

| Measurement | Result |
|---|---:|
| Source client writes | 10 |
| Case GTIDs before / after cleanup | 13 / 14 |
| DDL before / after cleanup | 6 / 7 |
| Changed rows before / after cleanup | 10 / 10 |
| Fixture setup, seconds | 14.12 |
| Container startup, seconds; included in setup | 11.70 |
| Coverage export, seconds | 1.70 |
| Fixture cleanup, seconds | 10.83 |
| Swift runtime lines hit / mapped | 7,823 / 20,880 |

All named assertions passed, including exact GTID sets, source file/offsets,
counter deltas and source/native/target comparisons. Engine checks confirm
source InnoDB and native/target MyISAM. Read-only SQLite checks confirm all 14
case GTIDs are APPLIED with source offsets. Each compound request's final GTID
matches its recorded request end offset. DDL and row intents are DONE.

Latest saved schemas preserve decimal precision/scale, unsigned/zerofill,
nullability, added defaults and the removed u default. Cleanup retires only the
two histories. The original table remains current. Final state is STOPPED with
no active GTID, at the shared restart's later offset. Both applier invocations
exited successfully. The existing restart writes reverse_poc.aux; it is not a
new restart or a post-restart write to every history table.

Coverage includes shared setup and restart, excludes lab code and the Rust
decoder, and cannot prove equivalence with the old whole-group line sets. No
other integration case/profile, full suite, benchmark or syntax suite ran.
Selection tooling did not change, so its Python tests were not repeated.

Evidence under artifacts/decimal-default-workflow-review/:

- spec.json and specs.json: original requests, histories, exact checks and counts.
- unit.log and unit-retry.log: 99 initial tests and seven corrected-query tests.
- matrix.log, catalog.log, verify.py and inventory-results.json: selection and
  source audits.
- integration.log and first-failure-review.json: retained failed-query evidence
  and read-only support-bundle findings.
- integration-retry.log, decimaldefaults-results.json, inspect.py and
  schema_check.py: passed rerun, timings, coverage, GTIDs, offsets and schemas.

Selected passed result: `artifacts/lab/20261106T063726Z-57467a70/result.json`.

Slice 2 follows below. The other profiles and complete group remain for CI.

## Integer, DECIMAL and BIT implementation results

Slice 2 converts only matrix-integers, matrix-decimal and matrix-bits. They remain
separate named cases in the same fixture. DMLNumericWorkflows supplies their
retained results through the existing DMLExecutionWorkflow. No helper, runner,
metadata discovery or production code changed. The source file changes only add
three workflow references. Original definitions, ten SQL requests, ten predicates,
compound ALTER/UPDATE, cold metadata inputs and profile selections remain.

Names follow the MySQL manual sections for
[Integer Types](https://dev.mysql.com/doc/refman/8.4/en/integer-types.html),
[Fixed-Point Types](https://dev.mysql.com/doc/refman/8.4/en/fixed-point-types.html)
and [Bit-Value Type](https://dev.mysql.com/doc/refman/8.4/en/bit-type.html).

- integers retains the INSERT and key-UPDATE results. Complete rows check signed
  and unsigned TINYINT/SMALLINT/MEDIUMINT limits, the changed primary key, NULL,
  the unchanged second row and its later deletion.
- decimal retains the INSERT and UPDATE results. Complete rows check all digits
  of DECIMAL(65,30), unsigned DECIMAL(10,2), DECIMAL(4,4), fixed-scale zero values, NULL and
  DELETE. Expected values are strings; no host floating-point conversion occurs.
- bits retains INSERT, key UPDATE and widened-column results. Exact unsigned
  queries cover BIT widths 1/7/8/9/63/64, the unsigned 64-bit maximum, high bits,
  a key with distinct bytes, NULL, DELETE and new defaults. Separate schema/default
  queries verify the change to BIT(16), default 256 and added BIT(8) default 255.

Every original predicate remains on its matching retained result. The normal
source/native/target schema and stored-default comparisons remain active. Each
case prepares its tables once, submits its source body as a batch, compares all
results at the end, and drops only its histories. The original tables stay current.

### Focused checks and measurements

The initial unit selection ran 99 methods. All numeric behavior checks passed;
14 global-membership assertions failed because the new expected list put
integers/decimal before the existing ENUM/SET cases. The correction restores the
catalog's existing order. Only those 14 methods ran again, and all passed. Thus
all 99 selected methods passed across the initial run and focused rerun. Ten
methods are new numeric tests. They check exact values, changed/missing rows,
widths/defaults, source requests, session resets, counters, GTID sets and offsets.

Strict Swift format lint passed for both changed source files and 14 test files.
Catalog structure remains 63 DDL scenarios, 235 registered cases and 56 support
requirements. Normalized planning keeps 183 jobs, 1,545 catalog obligations and
182 instrumented collections, with unchanged membership/order. Removing only
the three new references restores DMLCompatibilityCases.swift byte for byte.
Other fixtures, metadata, helper, runner and native oracles remain unchanged.

One forward/default/SQL run selected only these three cases with coverage. They
shared one fixture, one coverage build and one ordinary applier session.

| Case | Passed assertions | Seconds | SQL client calls | Saved CI seconds / calls |
|---|---:|---:|---:|---:|
| matrix-integers | 12 | 3.23 | 25 | 12.03 / 106 |
| matrix-decimal | 12 | 3.19 | 25 | 11.93 / 106 |
| matrix-bits | 18 | 3.76 | 26 | 14.90 / 133 |

The saved CI cases compared more accumulated poc tables. The new run selects
three cases and adds retained tables. These measurements use different inputs;
they are not a controlled speed comparison. All 42 named assertions passed.
Coverage belongs to the whole three-case fixture, including shared setup and
restart. It cannot identify a line set for each individual case.

| Case | Source client writes | GTIDs before / after cleanup | DDL before / after cleanup | Changed rows before / after cleanup |
|---|---:|---:|---:|---:|
| matrix-integers | 10 | 9 / 10 | 3 / 4 | 9 / 9 |
| matrix-decimal | 10 | 9 / 10 | 3 / 4 | 9 / 9 |
| matrix-bits | 15 | 16 / 17 | 6 / 7 | 19 / 19 |

| Shared fixture measurement | Result |
|---|---:|
| Fixture setup, seconds | 17.94 |
| Container startup, seconds; included in setup | 15.29 |
| Coverage export, seconds | 1.61 |
| Fixture cleanup, seconds | 10.77 |
| Swift runtime lines hit / mapped | 7,871 / 20,880 |

Read-only SQLite inspection confirms all 37 case GTIDs are APPLIED with source
file/offsets. Each compound request's final GTID matches its recorded request
end offset. Body and cleanup checkpoints match the exact source GTID sets and
positions, with expected counter deltas. All row and DDL intents are DONE.

Latest saved schemas keep all integer/decimal types, signedness, decimal scales,
BIT widths, nullability and bit defaults. The seven histories are retired; all
three original tables remain current. Engine checks confirm source InnoDB and
native/target MyISAM. Final state is STOPPED with no active GTID, at the existing
saved-schema restart's later offset. Both applier invocations exited successfully.
The shared restart writes reverse_poc.aux; it does not add a new per-case restart
or write each retained table after restart.

No other integration case/profile, full suite, benchmark or syntax suite ran.
No selection-tool code changed, so its Python tests were not repeated. Coverage
excludes lab code and the Rust decoder. Leave other profiles, variants and the
complete data-types-values group to CI.

Evidence under artifacts/numeric-values-workflow-review/:

- specs.json: original requests, exact retained values, histories and counters.
- unit.log and unit-retry.log: the initial selection and 14 corrected assertions.
- matrix.log, catalog.log, verify.py and inventory-results.json: source/selection
  audits and unchanged inventory counts.
- integration.log, inspect.py, schema_check.py and the three *-results.json files:
  the shared run, measurements, schemas, GTIDs, offsets and completed intents.

Passed result: `artifacts/lab/20261106T065247Z-9639d143/result.json`.

Slice 3 follows below. The other profiles and the complete group remain for CI.

## Floating-point and numeric-attribute implementation results

Slice 3 converts floatbounds, zerofill, fixedfloating and floating through the
same DMLExecutionWorkflow as integers, decimal and bits. DMLFloatingWorkflows
contains the new retained results. The four cases keep their IDs and existing
CI selections. One local fixture, coverage build and ordinary applier session
serve all four changed cases. The completed numeric cases did not run again.

Names follow MySQL's
[Floating-Point Types](https://dev.mysql.com/doc/refman/8.4/en/floating-point-types.html)
and [Numeric Type Attributes](https://dev.mysql.com/doc/refman/8.4/en/numeric-type-attributes.html).
The upstream Field_real::truncate implementation uses native floating-point
rounding. Tests must not select a host-side rounding result as the only correct
answer. Approximate fields use SQL equality/range checks on each server. The
existing comparison also checks complete source/native/target rows through
MySQL's text representation. Its numeric display rules are unchanged. No host Double
conversion or new floating-point normalizer was added.

- floatbounds retains INSERT and key UPDATE. Fixed DECIMAL projections check
  the rounded one-million boundaries, negative values, unsigned values, changed
  key and surviving row after DELETE.
- zerofill retains INSERT, key UPDATE and ALTER results. Complete numeric rows
  check defaults, NULL, unsigned INT/BIGINT limits, DECIMAL and YEAR values,
  changed TINYINT display width and added MEDIUMINT. Separate SQL checks verify
  unsigned/zerofill flags and stored defaults. YEAR remains in native schema
  comparison; the additional flag query covers the other numeric fields.
- fixedfloating retains INSERT, key UPDATE and ALTER results. It keeps the two
  INSERTs in the first client request, declared FLOAT/DOUBLE(M,D) forms, native
  rounding, large exponents, negative updates, NULL and added-column defaults.
  Separate queries check stored defaults and original/changed declarations.
- floating retains INSERT, key UPDATE, maximum UPDATE and ALTER results. Queries
  check every field through normal and smallest-positive values, maximum values,
  default replacement, FLOAT(25) becoming DOUBLE, added DOUBLE and the final NULL
  row. The existing row comparison remains active for every retained table.

The 16 original source scripts and predicates remain unchanged. The compound
requests retain their original transaction counts. First-INSERT metadata inputs,
profile/version rules and row-metadata settings remain. No helper, runner,
metadata discovery, native oracle or production code changed. Each case prepares
once, submits its body, reads retained results and cleans up only its histories.

### Focused checks and measurements

All 110 selected Swift tests passed, including 11 new workflow tests. Two tests
ran again after a range refinement and passed. The tests keep full requests,
session resets, old predicates, numeric/NULL/key outcomes, declared types,
defaults, exact GTID sets, file/offsets and counter checks. Strict Swift format
lint passed for the two changed source files and 15 changed test files.

Catalog structure remains 63 DDL scenarios, 235 registered cases and 56 support
requirements. Normalized planning keeps 183 jobs, 1,545 catalog obligations and
182 instrumented collections, with unchanged membership/order. Removing only
the four new references restores DMLCompatibilityCases.swift byte for byte.
The earlier numeric workflows, metadata, helper, runner and native oracles match
HEAD. This slice adds no fixture, CI job or restart.

One forward/default/SQL integration run selected only the four changed cases
with coverage. All 68 named assertions and the saved-schema restart passed.

| Case | Passed assertions | Seconds | SQL client calls | Saved CI seconds / calls |
|---|---:|---:|---:|---:|
| matrix-floatbounds | 12 | 3.33 | 25 | 11.76 / 106 |
| matrix-zerofill | 18 | 3.80 | 26 | 14.87 / 133 |
| matrix-fixedfloating | 18 | 3.92 | 26 | 14.97 / 133 |
| matrix-floating | 20 | 3.50 | 25 | 18.06 / 160 |

The saved CI cases compared more accumulated poc tables. This local run selects
four cases and adds retained tables. These are different inputs; the table is
not a controlled speed comparison. The later full CI run must measure the group.
Coverage covers this whole four-case fixture, including setup and shared restart,
and does not identify separate line sets for individual cases.

| Case | Source client writes | GTIDs before / after cleanup | DDL before / after cleanup | Changed rows before / after cleanup |
|---|---:|---:|---:|---:|
| matrix-floatbounds | 10 | 9 / 10 | 3 / 4 | 9 / 9 |
| matrix-zerofill | 15 | 16 / 17 | 6 / 7 | 19 / 19 |
| matrix-fixedfloating | 15 | 20 / 21 | 6 / 7 | 24 / 24 |
| matrix-floating | 21 | 22 / 23 | 7 / 8 | 38 / 38 |

| Shared fixture measurement | Result |
|---|---:|
| Fixture setup, seconds | 14.89 |
| Container startup, seconds; included in setup | 12.21 |
| Coverage export, seconds | 1.74 |
| Fixture cleanup, seconds | 10.71 |
| Swift runtime lines hit / mapped | 8,074 / 20,880 |

Read-only SQLite checks confirm all 71 case GTIDs are APPLIED with source
file/offsets. Every request's final GTID matches its recorded end offset. Exact
body/cleanup checkpoints and counters pass. All DDL and row intents are DONE.
Saved schemas keep the numeric declarations, unsigned/zerofill attributes,
changed widths/precision and normalized native defaults. The twelve histories
are retired; the four original tables remain current.

Engine checks confirm source InnoDB and native/target MyISAM. Final state is
STOPPED with no active GTID, at the shared restart's later offset. Both applier
invocations exited successfully. The existing restart writes reverse_poc.aux;
it is not a separate restart or post-restart write to each retained table.

No other integration case/profile, full suite, benchmark or syntax suite ran.
No selection-tool code changed, so its Python tests were not repeated. Coverage
excludes lab code and the Rust decoder. Leave other profiles, variants and the
complete group to CI.

Evidence under artifacts/floating-values-workflow-review/:

- specs.json: original requests, histories, fixed observations and counters.
- unit.log and unit-range.log: 110 selected tests and the two range checks.
- matrix.log, catalog.log, verify.py and inventory-results.json: source/selection
  audits and unchanged inventory counts.
- integration.log, inspect.py, schema_check.py and four *-results.json files:
  the shared run, measurements, GTIDs, offsets, schemas and completed intents.

Passed result: `artifacts/lab/20261106T160855Z-dda33f3e/result.json`.

Slice 4 follows below. The other profiles and the complete group remain for CI.

Keep all four IDs in the existing data-types-values group. Both 5.7-to-5.7
profiles select them; their existing exclusions remove profiles with an 8.4
source or target. A profile describes the replication topology. These cases are
a feature selection within that topology. They need no new profile or CI job.
Use the same shared fixture and applier as the other applicable numeric cases.


## Legacy floating AUTO_INCREMENT implementation results

All four cases now use DMLLegacyNumericWorkflows through their original shared
template. The source template adds only its workflow reference. Definitions,
16 scripts/predicates, compound requests, profile exclusions, cold metadata and
row-metadata flags remain unchanged. No common helper, runner, native oracle or
production code changed. Both existing 5.7-to-5.7 profiles retain these cases in
data-types-values. A profile with an 8.4 source or target keeps error 1063 as its
exclusion reason. This slice adds no profile, CI job, fixture group or restart.

Each declaration retains INSERT, key-change and ALTER results. Complete rows
check explicit zero, generated IDs 1/2, fractional key 9.5, explicit high key 100,
next generated key 101, its UPDATE to 102, unchanged rows and later DELETE.
Separate checks retain AUTO_INCREMENT/type/nullability attributes and default 7
while one stored row has explicit value 8. Source requests reset the profile
session, including NO_AUTO_VALUE_ON_ZERO. All source scripts remain intact.

### Native reservation behavior

The first integration run found a new test assumption error. Its exact next-ID
expectation was 3 after the first INSERT and 102 after the second phase. The
InnoDB source reported 4 and 103 because bulk INSERT can reserve unused values.
All original predicates, complete row checks and column/default checks had
passed. The harness failed before cleanup and did not start the other cases.

The support bundle had no failure.json because the error came from a harness
assertion. Bundle diagnostics, harness-failure.json and read-only SQLite checks
confirmed 19 case GTIDs applied, six DDL operations, 25 changed rows, exact source
checkpoint, DONE intents and STOPPED state with no active GTID. All saved row,
predicate and column/default checks before the counter assertion had passed. Original failed
evidence remains available.

The corrected counter observation requires each next value to exceed its retained
keys. It permits native reserved gaps. The row checks still require the exact
source-generated values, including 101 after explicit 100. This checks the
generated row values while permitting unused reserved IDs.
No source operation or production behavior changed for this correction.

### Focused checks and measurements

All 120 selected Swift unit tests passed, including ten new legacy workflow
methods. After the counter correction, only that changed unit method ran again;
it passed. A selection-test Set argument and a large Swift expression were also
corrected before their tests ran. Strict Swift format lint passed for two changed
source files and 16 changed test files; the counter edit passed lint again.

Catalog structure remains 63 DDL scenarios, 235 registered cases and 56 support
requirements. Normalized planning keeps 183 jobs, 1,545 catalog obligations and
182 instrumented collections, with unchanged membership and order. The source
audit restores the original shared template byte for byte. Other fixtures,
metadata/version rules, common helper and native oracles match HEAD.

The corrected integration run selected only the four legacy cases on
mysql57-to-mysql57-myisam/default/SQL, with coverage. They shared one fixture,
coverage build and ordinary applier session. All 72 assertions and the existing
saved-schema restart passed. The other three cases had not run before the retry.

| Case | Passed assertions | Seconds | SQL client calls | Saved CI seconds / calls |
|---|---:|---:|---:|---:|
| matrix-floatingautofloat | 18 | 3.95 | 24 | 12.55 / 117 |
| matrix-floatingautodouble | 18 | 4.03 | 24 | 12.58 / 117 |
| matrix-floatingautofixedfloat | 18 | 3.83 | 24 | 12.66 / 117 |
| matrix-floatingautounsigneddouble | 18 | 4.03 | 24 | 12.56 / 117 |

The saved CI cases compared more accumulated poc tables. This run selects four
cases and adds retained tables. These are different inputs, so this is not a
controlled speed comparison. The full CI run must measure the complete group.
Coverage covers the whole selected fixture, including shared setup and restart;
it does not identify separate line sets for individual cases.

| Per-case measurement | Result |
|---|---:|
| Source client writes | 15 |
| Case GTIDs before / after cleanup | 19 / 20 |
| DDL before / after cleanup | 6 / 7 |
| Changed rows before / after cleanup | 25 / 25 |

| Shared fixture measurement | Result |
|---|---:|
| Fixture setup, seconds | 14.60 |
| Container startup, seconds; included in setup | 11.64 |
| Coverage export, seconds | 1.60 |
| Fixture cleanup, seconds | 10.67 |
| Swift runtime lines hit / mapped | 7,747 / 20,880 |

Read-only SQLite inspection confirms all 80 case GTIDs are APPLIED with source
file/offsets. Each request's final GTID matches its recorded end offset. Body and
cleanup checkpoints match the source GTID sets, positions and expected counter
deltas. All DDL and row intents are DONE. Latest schemas preserve FLOAT, DOUBLE,
FLOAT(10,2) or unsigned DOUBLE, AUTO_INCREMENT, nullability and added default 7.
The twelve histories are retired; all four original tables remain current.

Engine checks confirm source InnoDB and native/target MyISAM, all MySQL 5.7.
Final state is STOPPED with no active GTID, at the existing saved-schema restart's
later offset. Both applier invocations exited successfully. The shared restart
writes reverse_poc.aux; it is not a separate restart or post-restart write to each
legacy table. Leave the 5.7 InnoDB target and version exclusions to CI. No other
integration cases/profiles, full suite, benchmark or syntax suite ran. No
selection-tool code changed, so its Python tests were not repeated. Coverage
excludes lab code and the Rust decoder.

Evidence under artifacts/legacy-floating-auto-workflow-review/:

- specs.json: original expansions, retained rows, bounds, requests and counts.
- unit.log and unit-counter.log: 120 tests and the corrected counter check.
- unit-compile.log and unit-counter-compile.log: retained compile diagnostics.
- matrix.log, catalog.log, verify.py and inventory-results.json: unchanged source
  and selection audits.
- integration.log and first-failure-review.json: failed exact-counter assertion
  and support-bundle findings.
- integration-retry.log, inspect.py, schema_check.py and four *-results.json files:
  passed shared run, timings, coverage, schema fields, GTIDs and offsets.

Passed result: `artifacts/lab/20261106T164338Z-8f06fddc/result.json`.

Slice 5 follows below. The other profiles and the complete group remain for CI.

The temporal, precision and defaults cases already belong to data-types-values
on all four existing profiles. Keep them as separate named cases in that group,
with one shared fixture and ordinary applier. They need no new profile or CI job.
The local slice above selects only the three changed cases on the forward
MyISAM profile. The regular CI matrix retains the other profiles.


## Temporal, fractional-second and automatic-value implementation results

Slice 5 converts matrix-temporal, matrix-precision and matrix-defaults through
the existing DMLExecutionWorkflow. DMLTemporalWorkflows supplies their retained
results. Removing only the three references restores DMLCompatibilityCases.swift
byte for byte. Original definitions, eight scripts/predicates, session settings,
metadata flags and profile selections remain unchanged. No common helper,
runner, native schema/default oracle or production code changed.

Names follow MySQL's
[Date and Time Data Types](https://dev.mysql.com/doc/refman/8.4/en/date-and-time-types.html),
[Fractional Seconds](https://dev.mysql.com/doc/refman/8.4/en/fractional-seconds.html)
and [Automatic Initialization and Updating](https://dev.mysql.com/doc/refman/8.4/en/timestamp-initialization.html).
The three cases remain in data-types-values on all four existing profiles. The
local run selects only these three on the forward profile. It adds no profile,
CI job, container restart or per-case applier restart.

- temporal retains INSERT and UPDATE results. Complete UTC rows keep the +05:30
  conversion, leap date, maximum DATETIME, maximum TIMESTAMP, negative/positive
  TIME limits, signed subsecond TIME, zero date/timestamp, YEAR limits and NULL.
  The UPDATE retains UTC input after the first INSERT's session time-zone change.
- precision retains its initial result. Complete rows keep TIME precision zero
  through six, DATETIME/TIMESTAMP precision zero and three, negative fractions,
  the change to positive TIME, zero microseconds, NULL and all unchanged fields.
- defaults retains INSERT and UPDATE results. Complete rows keep generated IDs,
  constant defaults, exact string bytes, fixed automatic timestamps, the untouched
  second row, explicit zero/high IDs and SQL NULL. Metadata checks retain
  AUTO_INCREMENT, defaults 7/seed, CURRENT_TIMESTAMP(6) and its ON UPDATE attribute.
  They inspect the timestamp default expression instead of evaluating it at read
  time. All row reads use UTC.

Each source write retains its original request and profile-session reset.
The +05:30 setting stays before its original INSERT. Both SET timestamp values
stay before their original INSERT/UPDATE. Histories execute only original
prefixes. Unit checks require each following request's UTC reset. Final queries
also set UTC. No host floating-point clock conversion or production formatter
supplies expected values; an independent integer-epoch check confirms them.

### Focused checks and measurements

All 131 selected Swift tests passed, including 11 new workflow methods. They
check frozen SQL, session order, all row fields, fractional declarations,
metadata/default attributes, old predicates, counter deltas, exact GTID sets and
file/offsets. Strict Swift format lint passed for two changed source files and
17 changed test files. Catalog structure remains 63 DDL scenarios, 235 registered
cases and 56 support requirements. Normalized planning keeps 183 jobs, 1,545
catalog obligations and 182 instrumented collections, with unchanged membership
and order. The source audit also confirms all earlier workflows, metadata/profile
rules, common runner and native oracles match HEAD.

The first integration attempt stalled inside swift-build before compilation or
fixture startup. Docker VM inspection showed a sleeping process with six unreaped
Git children and no compiler process. The process did not exit after TERM; only
that build process received KILL. The original failed build log and result remain.
There was no applier, database test or support bundle at that point. The retry
compiled normally with unchanged source, build configuration and cached inputs.

One completed forward/default/SQL run selected only these three cases with
coverage. They shared one fixture and ordinary applier. All 39 named assertions
and the existing saved-schema restart passed.

| Case | Passed assertions | Seconds | SQL client calls | Saved CI seconds / calls |
|---|---:|---:|---:|---:|
| matrix-temporal | 13 | 3.39 | 25 | 12.10 / 106 |
| matrix-precision | 11 | 3.33 | 25 | 9.09 / 79 |
| matrix-defaults | 15 | 3.65 | 28 | 12.13 / 106 |

The saved CI cases compared more accumulated poc tables. This run selects three
cases and adds retained tables. These are different inputs; the table is not a
controlled speed comparison. The complete group remains for the later full CI
run. Coverage belongs to this whole fixture, including shared setup/restart,
and does not identify separate line sets for individual cases.

| Case | Source client writes | GTIDs before / after cleanup | DDL before / after cleanup | Changed rows before / after cleanup |
|---|---:|---:|---:|---:|
| matrix-temporal | 10 | 9 / 10 | 3 / 4 | 9 / 9 |
| matrix-precision | 6 | 5 / 6 | 2 / 3 | 3 / 3 |
| matrix-defaults | 10 | 9 / 10 | 3 / 4 | 10 / 10 |

| Shared fixture measurement | Result |
|---|---:|
| Fixture setup, seconds | 14.77 |
| Container startup, seconds; included in setup | 11.87 |
| Coverage export, seconds | 1.76 |
| Fixture cleanup, seconds | 10.77 |
| Swift runtime lines hit / mapped | 7,637 / 20,880 |

Read-only SQLite inspection confirms all 26 case GTIDs are APPLIED with source
file/offsets. Each request's final GTID matches its recorded end offset. Body and
cleanup checkpoints match exact source GTID sets and positions, with expected
counter deltas. All DDL and row intents are DONE. Saved schemas keep every
fractional precision, YEAR/DATE declaration, nullability, constant default,
AUTO_INCREMENT and automatic timestamp attribute. The five histories are retired;
all three original tables remain current.

Engine checks confirm source InnoDB and native/target MyISAM. Final state is
STOPPED with no active GTID, at the existing saved-schema restart's later offset.
Both applier invocations exited successfully. The shared restart writes
reverse_poc.aux; it is not a separate restart or post-restart write to each retained
table. No other integration case/profile, full suite, benchmark or syntax suite
ran. No selection-tool code changed, so its Python tests were not repeated.
Coverage excludes lab code and the Rust decoder. Leave the other profiles,
variants and complete group to CI.

Evidence under artifacts/temporal-values-workflow-review/:

- specs.json: original SQL, retained values, session settings and counts.
- unit.log: 131 selected tests, including 11 new temporal workflow methods.
- matrix.log, catalog.log, verify.py and inventory-results.json: unchanged source
  and selection audits.
- integration.log and build-stall.json: retained build failure and process findings.
- integration-retry.log, inspect.py, schema_check.py and three *-results.json files:
  passed run, timings, coverage, schema fields, GTIDs and offsets.

Passed result: `artifacts/lab/20261106T182517Z-4382e639/result.json`.

Slice 6 follows below. Other profiles and the complete group remain for CI.

Keep these four IDs in the existing data-types-values group beside the numeric
and temporal cases. The shared runner prepares one fixture per group/profile;
ordinary cases reuse its containers and applier. The conversion adds no new CI
group or container startup. A focused local command starts one fresh fixture for
all four changed cases, without rerunning the completed cases.

## String defaults, fixed-length strings and BLOB/TEXT implementation results

Slice 6 converts matrix-binarydefaults, matrix-textdefaults, matrix-fixed and
matrix-lob through the existing DMLExecutionWorkflow. DMLStringValueWorkflows
supplies retained results and final observations. Removing the four workflow
references restores all three original fixture files byte for byte. Definitions,
12 original requests/predicates, session settings, metadata flags and profile
selections remain unchanged. No common runner, native oracle or production code
changed. Names use the MySQL manual's string data types: CHAR, VARCHAR, BINARY,
VARBINARY, BLOB and TEXT.

All four cases remain in data-types-values on all four existing profiles. They
share the group's containers and ordinary applier. This change adds no profile,
CI job or per-case restart. Each case retains its INSERT result and its next
changed result in two additional tables. Final reads check all retained results
and the original table after all source writes complete.

- binarydefaults checks all bytes of fixed and variable binary fields. It keeps
  zero padding, empty defaults, NUL, binary CHAR, numeric versus quoted constants,
  changed defaults, ADD COLUMN, wider BINARY and DROP DEFAULT.
- textdefaults keeps supplementary and decomposed Unicode, latin1 and UTF-16,
  CHAR trimming, VARCHAR spaces, NUL and numeric versus quoted constants. The
  original compound request keeps PAD_CHAR_TO_FULL_LENGTH. Each later request
  resets the profile session mode. Row checks use exact hexadecimal bytes.
- fixed checks complete CHAR(255) and BINARY(8) results before and after UPDATE.
  The empty and NULL rows remain distinct. DELETE must leave only the empty CHAR
  row and its eight-byte zero-padded BINARY value.
- lob keeps all four BLOB and all four TEXT families. Queries compare every byte
  of the repeated large values, including the 70 KB MEDIUMTEXT/MEDIUMBLOB fields.
  They also check quotes, backslash, NUL, Unicode, empty values, NULL, shortened
  values and the TEXT prefix index. DELETE must leave the original table empty.

Default queries inspect actual stored values separately from rows. Final queries
omit DEFAULT(e) or DEFAULT(v) after DROP DEFAULT; metadata verifies removal.
Native complete row, schema/index and stored-default comparisons remain active.
Cold metadata fixtures keep their original definitions and first INSERTs.

### Focused checks and measurements

All 145 selected Swift tests passed, including 14 new workflow methods. They
check original SQL bytes, session order, retained results, complete values,
defaults, declarations, predicates, counters, GTID sets and offsets. Strict
format lint passed. Catalog structure remains 63 DDL scenarios, 235 registered
cases and 56 support requirements. The normalized matrix keeps 183 jobs, 1,545
catalog obligations and 182 instrumented collections, with unchanged membership
and order. Source audits confirm the helper, earlier workflows, metadata/profile
rules and native oracles match HEAD.

One forward/default/SQL run selected only these four cases with coverage. They
shared one fixture and ordinary applier. All 63 named assertions and the existing
saved-schema restart passed.

| Case | Passed assertions | Seconds | SQL client calls | Saved CI seconds / calls |
|---|---:|---:|---:|---:|
| matrix-binarydefaults | 18 | 4.44 | 30 | 8.32 / 70 |
| matrix-textdefaults | 18 | 4.80 | 33 | 8.31 / 70 |
| matrix-fixed | 13 | 3.45 | 28 | 11.84 / 106 |
| matrix-lob | 14 | 3.82 | 28 | 12.49 / 106 |

The saved CI cases compared more accumulated poc tables. This run selects four
cases and adds retained tables. These are different inputs. The table does not
establish a controlled speed ratio. Coverage belongs to the whole fixture,
including shared setup/restart. It does not identify per-case line sets.

| Case | Source client writes | GTIDs before / after cleanup | DDL before / after cleanup | Changed rows before / after cleanup |
|---|---:|---:|---:|---:|
| matrix-binarydefaults | 10 | 14 / 15 | 6 / 7 | 11 / 11 |
| matrix-textdefaults | 10 | 13 / 14 | 6 / 7 | 10 / 10 |
| matrix-fixed | 10 | 9 / 10 | 3 / 4 | 13 / 13 |
| matrix-lob | 10 | 9 / 10 | 3 / 4 | 6 / 6 |

| Shared fixture measurement | Result |
|---|---:|
| Fixture setup, seconds | 14.62 |
| Container startup, seconds; included in setup | 11.80 |
| Coverage export, seconds | 1.62 |
| Fixture cleanup, seconds | 10.75 |
| Swift runtime lines hit / mapped | 8,381 / 20,880 |

Read-only SQLite inspection confirms all 49 case GTIDs are APPLIED with source
file/offsets. Each request's last GTID matches its recorded end position. Body
and cleanup checkpoints match exact source GTID sets and positions, with expected
counter deltas. All DDL and row intents are DONE. Saved schemas keep types,
widths, nullability, exact defaults, character sets, collations and prefix-index
metadata. The eight retained tables are retired. All four original tables remain
current. Engine checks confirm source InnoDB and native/target MyISAM.

Final state is STOPPED with no active GTID, at the shared saved-schema restart's
later offset. Both applier invocations exited successfully. That restart writes
reverse_poc.aux; it does not write to each retained table. No other integration
case/profile, full suite, benchmark or syntax suite ran. Selection-tool code did
not change, so its Python tests were not repeated. Coverage excludes lab code and
the Rust decoder. Leave other profiles, variants and the complete group to CI.

Evidence under artifacts/string-default-lob-workflow-review/ includes specs.json,
unit.log, integration.log, catalog.log, matrix.log, verify.py, inspect.py,
schema_check.py, inventory-results.json and four *-results.json files.

Passed result: `artifacts/lab/20261106T185703Z-d2015587/result.json`.

Slice 7 follows below. Other profiles and extra BINLOG selections remain for CI.


## JSON values and shared JSON fixture results

Slice 7 converts matrix-json and matrix-typedjson through DMLExecutionWorkflow.
DMLJSONWorkflows retains three earlier results per case. Original definitions,
eight SQL requests/predicates, session settings, metadata rules and profile
selections remain byte for byte. No production code, common runner or JSON
comparison code changed. Names follow MySQL's
[The JSON Data Type](https://dev.mysql.com/doc/refman/8.4/en/json.html).

### Placement with the other JSON tests

The JSON feature catalog already assigns seven cases. They had four CI owners.
Keep all seven in the existing data-types-values fixture:

| Cases | What they check | Previous CI group |
|---|---|---|
| matrix-json, matrix-typedjson | JSON documents and native scalar types; all four profiles | data-types-values |
| matrix-jsonpartial | Partial JSON row events; 8.4 source | data-types-values |
| json-year-compatibility | YEAR translation, refusal, restart and replay; 5.7 to 8.4 | data-types-values |
| ddl-compat-json-indexes | Indexed generated columns, ALTER, LIKE and forced-index reads; all profiles | table-column-index-changes |
| json-target57-limits | Version/engine refusals before a target write; 8.4 to 5.7 MyISAM | compatibility-policies-error-skipping |
| json-target84-schema | Target-only expression defaults/indexes, restart and replay; 5.7 to 8.4 | table-metadata-discovery |

A new separate JSON group would add ten jobs across profiles/variants. Moving
these three cases into the existing fixture keeps 183 jobs and avoids those
extra container startups. The group now has 28 registered IDs before profile
exclusions. Each job uses one fixture. The isolated YEAR, refusal and target-only
schema workflows keep their deliberate applier instances/restarts/replay steps.
They do not prepare a second fixture.

Cold metadata reads remain in metadata-columns-indexes. Its existing JSON
representative still covers typedjson and jsonpartial. General generated-column
and expression-dependency workflows keep their existing owners. Extra BINLOG
selections remain unchanged. No test was removed or treated as redundant because
its line coverage overlaps another test.

The matrix audit compares every profile/variant/suite/transport/case execution,
including multiplicity. All executions and catalog obligations remain unchanged.
Only the three named cases change ownership. Job IDs, dependencies, coverage
collections, profile exclusions and PR selections remain unchanged. A Python
policy test requires all cases in the JSON feature catalog to share this owner.

### Retained observations

- json keeps INSERT, primary-key UPDATE and ADD COLUMN results. Final checks keep
  object/array shape, empty objects, SQL NULL versus JSON null, DOUBLE type,
  signed/unsigned limits, 9007199254740993, booleans and exact Unicode bytes.
  The original final table must contain only the SQL NULL row.
- typedjson keeps the initial SQL NULL documents, native typed objects and the
  later typed array. Fixed queries check exact DECIMAL strings, DATE, TIME,
  DATETIME, TIMESTAMP, zero temporal values, unsigned limits and DECIMAL scale.
  Separate checks verify every binary payload and its BLOB/BIT JSON type. The
  unchanged second object must retain all scalar values after row 1 changes.
  Complete ordinary timestamp, BLOB, VARBINARY, BINARY and BIT values remain in
  all retained results. The original final table must be empty.

Exact integer and DECIMAL expectations do not pass through host floating-point
values. MySQL queries supply types and scalar strings. The existing server-based
JSON oracle still compares every path, type and scalar value with source/native.
It also checks binary subtype information. Fixed binary-payload queries inspect
MySQL's Base64 payload without assuming the displayed subtype prefix is the
same across versions. Partial-JSON source-event checks keep their current runner.

### Focused validation

The initial selection ran 203 Swift tests. Seven JSON methods failed because a
new predicate and observation shared one name. The other 196 methods passed.
After the name correction, all 11 JSON workflow methods passed. They passed again
after the native HEX and stored TIME expectation corrections below. The tests
cover original SQL bytes, metadata ownership, request/session order, retained results,
old predicates, counter deltas, exact GTID sets, offsets and cleanup. No unaffected
unit classes were repeated. All 31 planner tests and 12 group-selection tests
passed. Strict format lint and catalog structure checks passed. The full plan
still has 1,545 obligations and 182 instrumented collections.

The first forward/default/SQL integration run selected only the two changed
cases. matrix-json passed all 20 assertions. matrix-typedjson then found a wrong
new expectation: HEX(bits) returns 1FF because MySQL treats BIT as numeric in HEX.
It does not return the zero-padded binary string 01FF. The support bundle and
harness-failure.json were read before the correction. The bundled state was
STOPPED, had no active GTID and had only DONE intents. No replication error or
BLOCKED state occurred. Only the new expected text changed.

Only matrix-typedjson was selected for the rerun. Its first rebuild stalled
before compilation, with eight unreaped Git children and no compiler process.
TERM did not stop the sleeping Swift process; KILL stopped that process only.
The unchanged retry built normally. The original build log and process findings
remain. No fixture or support bundle existed for that build attempt.

That retry reached the next fixed scalar check. It found a second expectation
error: native SQL converts the input JSON TIME -838:59:58.123456 to the stored
value -630:59:58.123456. The existing [JSON support plan](JSON_SUPPORT.md) and JSONTypeTests already
document this conversion for both pinned versions. The new check must retain
the stored value. The second bundle was read first; state was STOPPED with no
active GTID and only DONE intents. Only the expected result changed. Source SQL
still uses the original -838-hour literal. All 11 JSON unit methods passed again.
Only typedjson was selected for the next integration run.

The completed typedjson rerun passed all 22 assertions and the existing shared
saved-schema restart. matrix-json was not rerun. Its 20 passed assertions and
cleanup checkpoint remain in the first run. That whole fixture is marked failed
because of typedjson's expectation error. Its outer saved-schema restart did not
run. Do not report the first fixture as a green run.

| Case | Passed assertions | Seconds | SQL client calls | Saved CI seconds / calls |
|---|---:|---:|---:|---:|
| matrix-json | 20 | 6.36 | 48 | 13.16 / 112 |
| matrix-typedjson | 22 | 5.86 | 45 | 14.35 / 124 |

The saved CI group compared more accumulated poc tables. These local selections
add retained tables and have different comparison inputs. The measurements do
not establish a controlled speed ratio. Coverage below belongs to each whole
fixture. The first includes work from the failed typedjson check. Do not assign
these line sets to individual cases or compare them as equivalent inputs.

| Selected fixture | Setup seconds | Container startup seconds, included in setup | Coverage export seconds | Cleanup seconds | Swift runtime lines hit / mapped |
|---|---:|---:|---:|---:|---:|
| matrix-json evidence | 14.57 | 11.73 | 1.15 | 10.73 | 7,956 / 20,880 |
| matrix-typedjson evidence | 14.01 | 11.33 | 1.63 | 10.32 | 8,115 / 20,880 |

| Case | Source client writes | GTIDs before / after cleanup | DDL before / after cleanup | Changed rows before / after cleanup |
|---|---:|---:|---:|---:|
| matrix-json | 15 | 16 / 17 | 6 / 7 | 34 / 34 |
| matrix-typedjson | 15 | 14 / 15 | 4 / 5 | 18 / 18 |

Read-only state inspection confirms all 32 case GTIDs across the two fixtures
are APPLIED with source file/offsets. Each request's last GTID matches its end
position. Body and cleanup checkpoints match exact source GTID sets and offsets,
with expected counters. All DDL/row intents are DONE. The six retained tables are
retired across the two fixtures. Each original table remains current. Saved
schemas keep JSON columns, ADD COLUMN, TIMESTAMP(6), all binary families, widths
and nullability. Engine checks confirm source InnoDB and native/target MyISAM.

Evidence is under artifacts/json-value-workflow-review/: specs.json, unit logs,
planner-tests.log, group-tests.log, catalog.log, matrix.log, group-command.txt,
verify.py, inventory-results.json, integration logs, build-stall.json, inspect.py,
schema_check.py and two *-results.json files.

matrix-json case evidence: `artifacts/lab/20261106T192313Z-f5744236/mysql84-to-mysql57-myisam/correctness/default/20261106T192720Z-683c27aa-auto-autocommit-myisam/cases.json`. Whole fixture: failed; saved-schema restart: not_run.

matrix-typedjson case evidence: `artifacts/lab/20261106T195008Z-cf6a81fe/mysql84-to-mysql57-myisam/correctness/default/20261106T195411Z-16d04dcb-auto-autocommit-myisam/cases.json`. Whole fixture: passed; saved-schema restart: passed.

No other integration case/profile, whole group, full suite, benchmark or syntax
suite ran. Coverage excludes lab code and the Rust decoder. CI must check the
new combined group, other profiles/variants and existing BINLOG selections.

Slice 8 follows below. Other profiles and the combined group remain for CI.


## Spatial values and shared spatial fixture results

Slice 8 converts matrix-spatial through DMLExecutionWorkflow. DMLSpatialWorkflows
retains the INSERT, key-change and column/index-change results. Removing the
single workflow reference restores DMLCompatibilityCases.swift byte for byte.
The original definition, four SQL requests/predicates, profile selections,
metadata rules and source settings remain unchanged. No production code, parser,
common runner or native schema/row oracle changed. Names follow MySQL's
[Spatial Data Types](https://dev.mysql.com/doc/refman/8.4/en/spatial-types.html)
and [Supported Spatial Data Formats](https://dev.mysql.com/doc/refman/8.4/en/gis-data-formats.html).

### Shared container startup

All three cases assigned to the Spatial Data Types feature now belong to the
existing data-types-values fixture:

| Case | Profile scope | Previous CI owner |
|---|---|---|
| matrix-spatial | All four profiles | data-types-values |
| ddl-compat-spatial-prefix-indexes | Both 5.7-to-5.7 profiles; native 8.4 rejects the prefix definition | table-column-index-changes |
| target84-index-spatial-metadata | 5.7-to-8.4 InnoDB; existing target SRID constraint and invisible index | table-metadata-discovery |

The group now has 30 registered IDs before profile exclusions. Applicable cases
share its MySQL containers. A separate spatial group is not needed. No job or
container startup is added. The prefix-index case keeps its two deliberate
applier restarts. The target-only metadata case keeps its isolated apply/replay
steps. Neither case prepares another fixture. Cold geometry discovery remains
in metadata-columns-indexes. No case or assertion was removed.

The matrix audit preserves every profile/variant/suite/transport/case execution,
including multiplicity and extra BINLOG selections. Only the two listed cases
change CI ownership. Job IDs, catalog identities, dependencies, exclusions and
PR selections remain unchanged. A Python policy test requires all spatial feature
cases to share this owner. The existing JSON ownership test still passes.

### Values and index assertions

The new value workflow uses the same preparation/body/cleanup runner as the
other type cases. Three tables retain earlier results until final comparison.
It adds no per-case restart. Checks keep:

- GEOMETRY, POINT, LINESTRING, POLYGON, MULTIPOINT, MULTILINESTRING,
  MULTIPOLYGON and GEOMETRYCOLLECTION declarations.
- Complete stored Cartesian geometry bytes, including the four-byte SRID header,
  WKB type/count fields, nested components and negative coordinates. Independent
  Python struct packing supplies the fixed expected bytes; no production codec
  generates them. Unit tests also check known types, lengths and component counts.
- SQL NULL versus empty collections, the changed primary key and line, the new
  collection column, unchanged fields and the one remaining row after DELETE.
- POINT SRIDs 0/4326, payload lengths and both coordinates. Geographic fixed
  checks do not choose one coordinate order. The existing native comparison
  checks every stored point byte and catches a coordinate-order change during apply.
- Initial SPATIAL index sp and replacement sp2, full column p, NOT NULL,
  uniqueness/part order and MySQL's implicit 32-byte bounding-box prefix.
  Saved schemas must remove the implicit prefix from the SPATIAL declaration.

The geometry-prefix case still tests BTREE, not SPATIAL search. The target-only
case still tests an existing 8.4 SRID 0 constraint, not every spatial reference
system. PLAN/SPATIAL_SUPPORT.md now separates these tested forms from native
version restrictions and untested primary-key/default combinations. Its old
bootstrap entry now points to the focused metadata case.

### Focused checks and measurements

All 172 selected Swift tests passed, including 10 new spatial workflow methods.
They check frozen SQL, metadata ownership, every retained result, index changes,
request/session order, counters, exact GTID sets and file offsets. All 32 planner
tests and 12 group-selection tests passed. Strict format lint and catalog checks
passed. Structure remains 63 DDL scenarios, 235 registered cases and 56 support
requirements. The plan keeps 183 jobs, 1,545 obligations and 182 instrumented
collections.

One forward/default/SQL integration selected only matrix-spatial with coverage.
All 28 named assertions and the existing shared saved-schema restart passed.

| Case | Passed assertions | Seconds | SQL client calls | Saved CI seconds / calls |
|---|---:|---:|---:|---:|
| matrix-spatial | 28 | 3.81 | 26 | 10.41 / 88 |

The saved CI group compared more accumulated poc tables. This selection adds
retained tables and has different inputs. It does not establish a controlled
speed ratio. Coverage belongs to the whole fixture, including setup/restart,
and does not identify the spatial case's exclusive line set.

| Shared fixture measurement | Result |
|---|---:|
| Fixture setup, seconds | 14.83 |
| Container startup, seconds; included in setup | 11.98 |
| Coverage export, seconds | 1.70 |
| Fixture cleanup, seconds | 10.74 |
| Swift runtime lines hit / mapped | 7,533 / 20,880 |

The case sends 15 client writes in three source batches. Before cleanup it has
20 GTIDs, 10 DDL and 14 row changes. Cleanup advances to 21 GTIDs and 11 DDL,
with no additional row changes. Read-only SQLite inspection confirms every case
GTID is APPLIED with source file/offsets. Each request's last GTID matches its end
position. Both checkpoints match exact source GTID sets and offsets. All intents
are DONE. The three retained schemas are retired; the original remains current.
Saved types, nullability, added column and SPATIAL parts match the checks.

Engine checks confirm source InnoDB and native/target MyISAM. Final state is
STOPPED with no active GTID at the shared restart's later position. Both applier
invocations exited successfully. That restart writes reverse_poc.aux; it does
not write to every retained spatial table.

No other integration case/profile, combined group, full suite, benchmark or
syntax suite ran. The two moved cases keep unchanged implementations and existing
local evidence. CI must check the new combined group and other profiles/variants.
Coverage excludes lab code and the Rust decoder.

Evidence is under artifacts/spatial-value-workflow-review/: specs.json,
geometry-bytes.json, unit.log, planner-tests.log, group-tests.log, catalog.log,
matrix.log, group-command.txt, verify.py, inventory-results.json, integration.log,
inspect.py, schema_check.py and spatial-results.json.

Passed result: `artifacts/lab/20261106T201949Z-91870380/result.json`.

Slice 9 follows below. Other profiles, variants and combined groups remain for CI.


## Partial JSON event checks in the shared workflow

Slice 9 moves matrix-jsonpartial into DMLJSONWorkflows beside json and typedjson.
It already belongs to the shared data-types-values fixture with all seven JSON
feature cases. No new fixture, container startup, CI job or per-case applier
restart is added. Its source-8.4 restriction, MINIMAL/file-position selections,
extra BINLOG selection and cold metadata representative remain unchanged.

Original definition, four SQL requests/predicates, two expectsJSONDiff flags,
PARTIAL_JSON settings and statement order remain byte for byte. Three retained
tables keep the initial JSON, replaced elements and the result after removal.
Final queries check each array position and native INTEGER/DECIMAL/DATE type,
exact numeric/date strings, all 1,000 padding bytes, unchanged fields and the
empty original table after DELETE. The native server-based JSON oracle still
compares complete path/type/value sets.

### Event proof and shared-runner guard

DMLExecutionWorkflow now accepts an explicit jsonDiffPhases plan. It must match
every flagged phase, in order, without missing, extra or duplicate phases. Each
such request must declare one source transaction. A missing/mismatched plan still
fails before execution. Ordinary workflows keep empty event-check plans and
unchanged requests, ordering and counters.

The generated plan checks five writes: the two original partial UPDATEs and the
three partial UPDATEs used to retain earlier results. LabSQLPhase already records
each write's start/end file offsets and GTID delta. Event checks use those saved
ranges after the body batch; they do not read a later live boundary. A range must
stay in one file, advance its offset and contain exactly one source GTID.

LabJSONDiff is a narrow independent reader of mysqlbinlog's verbose output for
this two-column fixture. It does not use the production decoder or parse general
SQL. Each proof requires the expected GTID, one Update_rows_partial event, one
UPDATE for the expected table and the expected JSON_REPLACE/JSON_REMOVE expression
in the JSON column's after image. The row event must end within the saved range.
Full images, wrong tables/GTIDs, extra rows/events, operation text in a string or
before image and out-of-range events cannot satisfy the proof.

The harness checks the 8.4 mysqlbinlog version once, copies each required source
file once and decodes each exact range with checksum verification. Each proof
has a named assertion, raw file, decoded text and JSON record with the write,
GTID, offsets, event type and operation. Failure output uses the existing named
assertion and support-bundle path. A correct final row alone cannot pass.

The old per-phase checker remains for the fallback runner. This conversion does
not change it. The new fixture uses the shared preparation/body/cleanup path.

### Focused validation and measurements

All 200 selected Swift tests passed. This includes nine new workflow methods and
four independent event-reader methods. Tests keep original SQL and metadata
rules, all retained values, session setup, explicit phase plans, invalid-plan
refusals, counters and exact GTID/offset checkpoints. Event-reader tests reject
full images, mismatched tables/GTIDs, wrong operations, before-image/string
lookalikes, multiple updates, missing/duplicate writes, rotation, empty/reversed
ranges and event boundaries outside the window. Common-runner tests and affected
workflow membership tests also passed. Strict format lint and catalog checks
passed. Structure remains 63 DDL scenarios, 235 registered cases and 56 support
requirements. The matrix still has 183 jobs, 1,545 obligations and 182 instrumented
collections, with unchanged membership and order. No selection tool changed, so
its Python tests were not repeated. The normal JSON/source/native comparison
implementations and production code remain unchanged.

One forward/default/SQL run selected only matrix-jsonpartial with coverage.
All 19 assertions and the existing shared saved-schema restart passed. This
includes all five partial-event proofs, not just final row comparisons.

| Case | Passed assertions | Seconds | SQL client calls | Saved CI seconds / calls |
|---|---:|---:|---:|---:|
| matrix-jsonpartial | 19 | 6.70 | 48 | 16.68 / 146 |

The saved CI group compared more accumulated poc tables. This selection adds
retained tables and three extra event checks. Inputs differ. These numbers do
not establish a controlled speed ratio. Coverage belongs to the whole fixture,
including setup/restart, and does not identify an exclusive partial-JSON line set.

| Shared fixture measurement | Result |
|---|---:|
| Fixture setup, seconds | 15.25 |
| Container startup, seconds; included in setup | 12.12 |
| Coverage export, seconds | 1.57 |
| Fixture cleanup, seconds | 10.73 |
| Swift runtime lines hit / mapped | 7,707 / 20,880 |

### Saved source ranges

The five decoded files were read again from the one saved raw copy, using their
same start/stop offsets and checksum verification. Each output matched the saved
text exactly. The event header, table, operation and GTID also match each write's
recorded source boundary.

| Write | GTID | File: start–end | Partial row event: start–end | Operation |
|---|---|---|---|---|
| original-phase-2 | `17ac1612-da22-11f1-8f09-aa258c5e9cbd:19` | binlog.000003: 4984–6416 | 5234–6385 | JSON_REPLACE |
| original-phase-3 | `17ac1612-da22-11f1-8f09-aa258c5e9cbd:20` | binlog.000003: 6416–7822 | 6658–7791 | JSON_REMOVE |
| jp_after_replace-phase-2 | `17ac1612-da22-11f1-8f09-aa258c5e9cbd:24` | binlog.000003: 11928–13358 | 12176–13327 | JSON_REPLACE |
| jp_after_remove-phase-2 | `17ac1612-da22-11f1-8f09-aa258c5e9cbd:26` | binlog.000003: 14722–16151 | 14969–16120 | JSON_REPLACE |
| jp_after_remove-phase-3 | `17ac1612-da22-11f1-8f09-aa258c5e9cbd:27` | binlog.000003: 16151–17554 | 16390–17523 | JSON_REMOVE |

The case sends 15 client writes in three source batches. Before cleanup it has
14 GTIDs, four DDL and ten row changes. Cleanup advances to 15 GTIDs and five DDL,
with no additional row changes. Read-only SQLite inspection confirms every case
GTID is APPLIED with source file/offsets. Each request's last GTID matches its end
position. Both checkpoints match exact source GTID sets and offsets. All intents
are DONE. Three retained schemas are retired; the original remains current.
Saved schemas retain INT/JSON declarations and nullability.

Engine checks confirm source InnoDB and native/target MyISAM. Final state is
STOPPED with no active GTID at the shared restart's later offset. Both applier
invocations exited successfully. That restart writes reverse_poc.aux; it does
not write to every retained JSON table.

No other integration case/profile, complete group, full suite, benchmark or
syntax suite ran. CI must check combined JSON execution, other capture variants
and the existing BINLOG selection. Coverage excludes lab code and the Rust decoder.

Evidence under artifacts/json-partial-workflow-review/ includes specs.json,
unit.log, matrix.log, catalog.log, verify.py, inventory-results.json,
integration.log, inspect.py, proof_check.py, schema_check.py,
source-event-results.json and jsonpartial-results.json.

Passed result: `artifacts/lab/20261106T203447Z-50138882/result.json`.

Slice 10 is complete as a source and saved-evidence review. See
[area completion and key/index review](BETA7_KEY_INDEX_WORKFLOW_REVIEW.md).
All 23 local case reports passed 391 named assertions. The review records the
matrix-json outer-restart limit. It keeps both isolated lifecycle runners.

The [index workflow results](BETA7_KEY_INDEX_WORKFLOW_REVIEW.md#implementation-and-focused-results)
record all 12 conversions. All 57 original assertions and the shared restart
passed on forward MyISAM. Eleven focused unit tests passed.
The [primary-key and constraint results](BETA7_PRIMARY_KEY_CONSTRAINT_WORKFLOW_REVIEW.md#implementation-and-focused-results)
record both conversions. All 23 operation states and 15 original named assertions
passed on forward MyISAM. Fourteen focused unit tests passed.
The [conflict workflow results](BETA7_KEY_CONFLICT_WORKFLOW_REVIEW.md#implementation-and-focused-results)
record all 11 original assertions and both exact no-op boundary checks passing.
Fifteen focused unit tests passed. The
[INSERT SELECT/JOIN results](BETA7_INSERT_SELECT_JOIN_LOAD_DATA_REVIEW.md#implementation-and-focused-results)
record the JOIN checks in the existing JSON index workflow. Its 11 old final
observations and three new checks remain. The migration retains all ten SQL
selections. The standalone matrix-select case is retired. LOAD DATA is unchanged.
The focused forward default SQL run and saved-schema restart passed. Other
profiles and variants remain for CI.
Leave the full combined-group and cross-profile checks to CI.
