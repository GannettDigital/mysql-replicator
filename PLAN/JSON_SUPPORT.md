# JSON support work

Status: the ordinary-value, typed-value and partial-update paths have unit tests.
The selected live, bootstrap and recovery cases now pass on all four profiles.
Some legacy opaque types still have SQL transport gaps, listed below.

## Required behavior

Support valid MySQL JSON values when the selected target can represent them.
Do not reject a value only because conversion to ordinary JSON text is easier.
Do not convert a typed value to a string or an approximate number.

An implementation gap is not a MySQL compatibility rule. If the SQL transport
cannot preserve a value, stop with its type and JSON path. Keep the source bytes
for diagnosis. Do not silently substitute another type.

## Native behavior

Both local upstream trees separate binary JSON storage from SQL text input.
`Field_json::store_binary` and `Field_json::store_json` accept the internal value.
The string form of `Field_json::store` parses SQL text. A prepared-statement
parameter does not expose the internal binary-storage function.

The binary format has ordinary JSON scalars, arrays and objects. It also has
MySQL typed values, called opaque values in the binary format. These include
DECIMAL, DATE, TIME, DATETIME, TIMESTAMP and binary SQL values. For example,
`JSON_ARRAY(CAST('2020-01-02' AS DATE))` contains a DATE, not a JSON string.
A plain text round trip changes that type.

Native 5.7 JSON text output can print an integral DOUBLE without a decimal point.
The output also omits the distinction between signed and unsigned positive
integers. Compare `JSON_TYPE` as well as displayed values.

Native 8.4 partial-update events carry JSON changes. FULL row images do not
disable `PARTIAL_JSON`. The decoder can apply the changes to the complete before
image without a target query. This produces the complete after image.

References: local MySQL 5.7 revision
`f7680e98b6bbe3500399fbad465d08a6b75d7a5c` and MySQL 8.4 revision
`0896fcd61dec11a0904166911a0126f59daaa1bf`, under the root `.upstream/` directory.
Relevant files:

- 5.7 `sql/json_binary.cc` and `sql/json_dom.cc`: binary types and text output.
- 5.7 and 8.4 `sql/item_json_func.cc`: typed SQL expressions to JSON values.
- 8.4 `sql-common/json_diff.cc` and `json_path.cc`: partial updates and paths.
- 8.4 `sql/sql_prepare.cc`: parameter type changes and statement preparation.
- 5.7 `sql/binlog.cc`: temporary-table DDL and GTID transaction restrictions.

## Implemented paths

| Value or event | Implementation |
| --- | --- |
| SQL NULL and JSON null | Retain separate values |
| Objects, arrays, strings and booleans | Decode full documents; retain exact UTF-8 bytes and array order |
| Signed and unsigned integers | Retain the native kind and all 64 bits; construct JSON with a signed or unsigned SQL expression |
| Finite DOUBLE | Use round-trip decimal text; check the target JSON type separately |
| DECIMAL | Retain packed bytes, precision, scale and exact decimal text; use a typed DECIMAL expression |
| DATE, TIME, DATETIME | Send binary temporal parameters through JSON_ARRAY; retain zero dates and microseconds |
| TIMESTAMP, BIT, binary strings and BLOB widths | Build a typed value through a session-local temporary field when CAST cannot produce that field type |
| Partial JSON updates | Apply REPLACE, INSERT and REMOVE operations to the FULL before image |
| Recovery | Re-decode saved relay bytes; include typed values and raw opaque bytes in recovery output |

A JSON document has a text template and typed leaves. The template has null at
those leaves. Bound SQL paths and typed expressions restore them with JSON_SET.
Source keys and values are parameters, not SQL text interpolation.

Before a temporal or binary JSON write, the applier checks the type and value
produced by the target expression. Ordinary before-image checks compare both
JSON text values and `JSON_TYPE` results. Object key order and whitespace do not
matter. Array order and string bytes do matter. No post-write read is added for
ordinary JSON columns. Generated-column checks retain their existing behavior.

Temporary fields hold no durable replication state. They require the target
user to have `CREATE TEMPORARY TABLES` permission in the affected database.
For InnoDB, the applier creates these tables before BEGIN. MySQL 5.7 GTID rules
forbid temporary-table DDL inside a multi-statement transaction. Each typed
scalar gets a separate temporary table because MySQL cannot open one temporary
table twice in one statement. The next group removes the tables. Closing the
connection also removes them.

The codec ABI is 9. Kind 10 carries a typed JSON document envelope. Kind 11
carries a JSON change vector. SQLite needs no schema migration. Decode output,
typed annotations, traversal and reconstructed documents have size limits.
The existing event-size configuration controls these limits.

JSON schema discovery and CREATE/ADD/MODIFY use the shared schema paths. Direct
JSON primary and secondary index columns remain invalid. JSON expression indexes
and non-NULL JSON defaults are outside this DDL increment.

## Remaining limits and qualification

These are SQL transport gaps, not invalid source JSON:

- Native 5.7 can store YEAR as opaque type 13. MySQL 8.4 converts a YEAR SQL
  expression to an integer. The current target check stops on that type change.
- Legacy opaque type 253 can differ from the type produced by CAST AS BINARY
  on another version. The current target check stops if the subtype or bytes
  differ. Other opaque subtypes without an implemented SQL constructor stop
  with the numeric type. The original bytes remain available.
- The native JSON SQL constructor changes long TIME hours when it converts
  through a DATETIME structure. The applier compensates for this conversion.
  A stored TIME that has no exact constructor within the target TIME range
  still stops before the business write.
- Temporary-field construction depends on target field limits. For example,
  a stored JSON TIMESTAMP outside that target's TIMESTAMP range has no exact
  constructor in this path. The server error stops application.

Do not replace these values with strings to make a test pass. Further work must
find an exact SQL path or document the specific protocol limit.

Partial updates require a complete JSON before image. Invalid paths, impossible
changes, truncated payloads and unknown operation flags fail before application.
The normal FULL row-image requirement remains in force.

## Test cases

The shared catalog contains these cases for replicated CREATE and existing-table
discovery:

- `matrix-json` and `bootstrap-matrix-json`: ordinary values, SQL NULL, JSON null,
  full-range integers, Unicode, DML, and ADD of a JSON column.
- `matrix-typedjson` and `bootstrap-matrix-typedjson`: exact DECIMAL, temporal,
  TIMESTAMP, BIT, binary-string and BLOB values. Check JSON_TYPE and values.
- `matrix-jsonpartial` and `bootstrap-matrix-jsonpartial`: partial replacement
  and removal, including typed values. Inspect mysqlbinlog output to prove that
  the source emitted a change record. These cases require an 8.4 source.

Ordinary and typed cases apply to all four profiles. Bootstrap cases restart the
applier between phases. The former `matrix-reject-json-opaque` case is removed;
DECIMAL is now a positive case. The former JSON DDL refusal uses GEOMETRY.

Database qualification now runs the selected live, bootstrap and partial-update
cases. The large-value case also checks source-free replay, clean restart and
pending recovery. Do not infer database compatibility from unit SQL-string
checks.

## Local checks

The full Swift suite passed 462 tests. The Rust suite passed nine tests.
Tests include exact typed values, binary temporal parameters, all row operations,
mixed-column partial bitmaps, repeated row pairs, Unicode paths, array insertion,
invalid changes, resource limits, poisoned decoders and relay recovery.

Logs: `/tmp/beta5-json-swift-final.log` and `/tmp/beta5-json-rust-final.log`.
Periphery found no unused code. The tooling suite passed 148 tests with two
skips. `git diff --check` passed. No database integration test was run for this
increment.

After the final path-grammar correction, 21 focused JSON tests passed
(`/tmp/beta5-json-path-check.log`). The lab inventory selected 24 profile/case
pairs: 18 await execution and six partial-update pairs do not apply to 5.7
sources (`/tmp/beta5-json-selection-final.json`).

Additional logs: `/tmp/beta5-json-periphery-final.log` and
`/tmp/beta5-json-tools-final.log`.

## Beta.5 CI corrections

The integration runs found these implementation faults:

- MySQL 8.4 can coerce a string parameter before an unsigned CAST. Integer
  parameters now use the binary protocol with the correct signedness.
- Binary JSON DECIMAL metadata uses the internal MySQL decimal precision.
  Padding can make `DECIMAL(65,30)` report precision 66. The decoder accepts
  the native layout. SQL construction reduces padding only when the value
  fits exactly within precision 65.
- A temporal parameter needs an explicit SQL expression type on MySQL 8.4.
  TIME construction also needs the inverse of MySQL's DATETIME packing step.
  For example, native SQL stores `-838:59:58.123456` in JSON as
  `-630:59:58.123456`. Replication must retain the stored value.
- MySQL 5.7 can convert a JSON expression subquery to a string. Temporary
  typed fields now construct a stored JSON column. JSON_EXTRACT keeps that
  column's JSON type when a subquery is materialized.

The tests now compare each JSON path's type and value. They normalize only
DOUBLE display differences between MySQL versions. They retain exact integer,
DECIMAL, string and opaque-value text. SQL NULL and JSON null remain distinct.
The comparison uses the servers, not the production decoder, as its reference.

The partial-update test uses the host MySQL 8.4 `mysqlbinlog` command. The
minimal MySQL 8.4 server image does not include that command. CI already installs
it and sets `MYSQLBINLOG`.

Local default-profile results after the fixes:

| Profile | Evidence under `artifacts/lab/` |
| --- | --- |
| 5.7 InnoDB → 8.4 InnoDB | `20261014T025002Z-aa175cbc` |
| 8.4 InnoDB → 5.7 MyISAM | `20261014T025706Z-d994e77b` |
| 5.7 InnoDB → 5.7 MyISAM | `20261014T025845Z-143ca58d` |
| 5.7 InnoDB → 5.7 InnoDB | `20261014T030419Z-bea87d63` |

These runs include ordinary and typed JSON DML, bootstrap phases, table-filter
refusal, and the large-value workflow. The forward run also includes partial
JSON and the forward failure workflow. The reverse run preceded the final
5.7 subquery wrapper and host-decoder harness corrections.

The forward file-position/MINIMAL run passed all three JSON DML cases:
`20261014T030651Z-68376af0`. Its large-value replay case is explicitly not
applicable because offline replay uses GTIDs. This is not evidence for replay
from file-position-only configuration.

The affected Swift unit targets passed 392 tests. The Rust suite passed nine
tests. The DDL catalog structure check passed with 63 scenarios and 186
registered cases. These checks do not qualify unselected MySQL features.
