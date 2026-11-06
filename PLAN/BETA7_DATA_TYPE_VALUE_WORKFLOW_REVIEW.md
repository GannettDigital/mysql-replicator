# Data types: value and workflow review

Status: source and saved-evidence review complete. The first two implementation
slices are complete locally: decimaldefaults, integers, decimal and bits. Their
focused unit and forward integration checks passed; see the results below.
The character/binary conversions are committed as `415e94d`. Full-matrix
validation remains later work.

## Decision

Keep all 25 IDs in data-types-values and their existing execution selections.
The review found distinct values, metadata and lifecycle conditions. It found
no complete case replacement. Do not remove a type test because another test
executes the same Swift lines or also contains INSERT/UPDATE/DELETE.

There are 23 matrix cases. Twenty-two fit the existing DMLExecutionWorkflow:
no setup SQL, custom ordering, replacement case or partial-JSON event assertion
is required. Convert them in small slices with retained histories and final
observations. Leave matrix-jsonpartial on its current runner until it has an
explicit source-event/offset plan. Keep json-year-compatibility and large-values
on their isolated apply/replay/recovery paths.

The first implementation slice is matrix-decimaldefaults. It has fixed
numeric expectations and a small schema. Keep every original script and predicate.
Use dd_after_insert and dd_after_defaults to retain overwritten values/defaults.
Do not change the helper, native schema/default/JSON oracles or production code.

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
| 3 | zerofill, floatbounds, fixedfloating and floating | Keep native numeric comparisons, distinct FLOAT/DOUBLE metadata, rounding and retained key results. Select only changed cases in one forward fixture. Do not convert expectations through host Double by default. |
| 4 | All four legacy floating AUTO_INCREMENT cases through their shared template | Unit-test all generated SQL, declared types, both native error-1063 exclusions and session reset. Select all four changed cases in one 5.7-to-5.7 MyISAM fixture. Leave InnoDB and excluded profiles to CI. |
| 5 | temporal, precision and defaults | Fixed time/precision, zero/NULL, generated IDs and automatic timestamp checks. Unit-test source time_zone/timestamp placement and resets. Select changed cases in one forward fixture. |
| 6 | binarydefaults, textdefaults, fixed and lob | Independent bytes/defaults, source PAD mode, complete large payloads, lengths and empty/NULL states. Preserve native schema/default comparison. Select only changed cases in one forward fixture. |
| 7 | json and typedjson | Fixed paths, native scalar types, exact decimal/integer strings and unchanged server-based JSON oracle. Select both changed cases in one forward SQL fixture. Preserve extra BINLOG selections for CI. |
| 8 | spatial | Every geometry type, SRID, empty/NULL collections, key changes and SPATIAL index metadata. One forward case with coverage. Do not substitute display WKT for exact geometry checks. |
| 9 | Separate jsonpartial design/conversion | Preserve original bounded source-binlog checks and two diff phases. Test changed offset/event validation with one forward selected case and the 8.4 decoder. Do not bypass the helper guard. |
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

Next: Slice 3 — zerofill, floatbounds, fixedfloating and floating. Keep distinct
FLOAT/DOUBLE types, native rounding, extreme values, changed keys, defaults and
retained results. Select only those changed cases in one forward fixture. Reuse
one coverage build. Do not expand local validation to other profiles or suites.
