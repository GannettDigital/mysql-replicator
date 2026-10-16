# JSON transport investigation

Status: native-source review and direct probes complete. This does not qualify
all JSON values. The remaining limits are client-SQL transport gaps, not invalid
source JSON.

## Result

Keep the current exact-value constructors and checks. Do not replace an opaque
value with a string, integer or another opaque subtype. Ordinary prepared
parameters do not provide access to MySQL's internal binary JSON storage API.

Two version differences are confirmed:

- MySQL 5.7 stores a YEAR SQL value in JSON as opaque type 13. MySQL 8.4 stores
  the same expression as an unsigned integer. The target can retain a type-13
  value in its binary JSON format, but its YEAR SQL constructor does not create it.
- MySQL 5.7 `CAST(... AS BINARY)` in JSON creates opaque type 253. MySQL 8.4
  creates type 15. Both report `JSON_TYPE = BLOB`. A type-name check alone would
  accept a changed subtype.

MySQL 8.4 has another type-253 constructor for strings with a character set whose
minimum width is more than one byte. This is not a general replacement. For
example, conversion of one byte `FF` to utf16 produces `00FF`. It changes the
payload. The text output of type 253 also differs between versions. A candidate
path needs byte checks and tests of the stored binary JSON before use.

## Direct probes

Probes ran on disposable MySQL 5.7.42 and 8.4.8 servers. They did not use the
replicator decoder as the reference. These results describe the server's SQL
constructors; they do not prove replication or crash recovery.

| Expression inside JSON_ARRAY | 5.7.42 | 8.4.8 |
| --- | --- | --- |
| YEAR field containing 2026 | OPAQUE, `base64:type13:MjAyNg==` | UNSIGNED INTEGER, `2026` |
| `CAST(X'01020304' AS BINARY)` | BLOB, subtype 253, payload `01020304` | BLOB, subtype 15, same payload |
| Prepared `?` bound from binary SQL variable `X'01020304'` | BLOB, subtype 15 | BLOB, subtype 15 |
| `CONVERT(X'01020304' USING utf16)` | STRING; decoded UTF-8 `C482CC84` | BLOB; unquoted bytes `01020304` |
| `CONVERT(X'FF' USING utf16)` | Not used to establish a constructor | BLOB; unquoted bytes `00FF` |

The 8.4 source confirms subtype 253 for the wide-character path. Its JSON text
formatter prints that subtype as raw string content. The 5.7 formatter uses the
`base64:type253:` form. Do not use text equality across versions as a binary
subtype test.

Example probe, for a disposable server:

```sql
CREATE DATABASE json_transport;
CREATE TABLE json_transport.y (v YEAR);
INSERT INTO json_transport.y VALUES (2026);
SELECT JSON_TYPE(JSON_EXTRACT(JSON_ARRAY(v),'$[0]')),
       JSON_UNQUOTE(JSON_EXTRACT(JSON_ARRAY(v),'$[0]'))
FROM json_transport.y;
SELECT JSON_TYPE(JSON_EXTRACT(JSON_ARRAY(CAST(X'01020304' AS BINARY)),'$[0]')),
       HEX(JSON_UNQUOTE(JSON_EXTRACT(JSON_ARRAY(CAST(X'01020304' AS BINARY)),'$[0]')));
SELECT JSON_TYPE(JSON_EXTRACT(JSON_ARRAY(CONVERT(X'FF' USING utf16)),'$[0]')),
       HEX(JSON_UNQUOTE(JSON_EXTRACT(JSON_ARRAY(CONVERT(X'FF' USING utf16)),'$[0]')));
DROP DATABASE json_transport;
```

## Why a JSON parameter does not solve this

The 8.4 prepared-statement decoder handles `MYSQL_TYPE_JSON` with the string
parameter types and calls `Item_param::set_str`. The 5.7 conversion setup also
uses the string path for that type code. A JSON field parses string input as
JSON text. Changing the parameter type code does not call
`Field_json::store_binary`.

The row replication path can call internal field storage functions. That is why
native replication can retain a value that SQL constructors cannot recreate.
This difference is separate from whether the target version accepts the binary
JSON format.

## Other subtype and range limits

| Value | Current exact path or remaining limit |
| --- | --- |
| Signed/unsigned integers and DECIMAL | Typed expressions; preserve signedness and exact decimal text. Native decimal padding can exceed declared precision; the constructor reduces padding only when the value still fits exactly. |
| DATE and DATETIME | Binary temporal parameters plus typed CAST; zero dates and microseconds are retained. |
| TIME | Invert the native TIME-to-DATETIME packing step before construction. If there is no inverse within SQL TIME's range, stop before the write. Both pinned versions use this conversion. |
| TIMESTAMP | Use a temporary TIMESTAMP field. A stored JSON value outside that field's representable range has no constructor in this path. Session time zone can also affect the field range. |
| BIT and BLOB widths | Use a temporary field of the same type and verify the result. |
| Binary types 15 and 254 | Use VARBINARY/BINARY fields. Their field width limits still apply; a legal binary JSON payload can exceed the corresponding SQL field width. |
| YEAR/type 13 | Temporary YEAR works on 5.7. No exact constructor found on 8.4. |
| Type 253 | Binary CAST works on 5.7. The 8.4 wide-character candidate covers only payloads that survive conversion unchanged and needs separate verification work. |
| Other opaque type codes | The decoder preserves bytes. No general SQL constructor exists in the current implementation. Native GEOMETRY SQL expressions produce JSON objects, not an opaque spatial payload. |

Do not classify all type codes from 0 to 255 as values produced by the supported
source versions. Separate known native constructors from binary-format payloads
that can arrive from older history, imports or other server implementations.

## LOAD DATA does not bypass the JSON parser

The [MySQL JSON example](https://dev.mysql.com/blog-archive/taking-the-new-mysql-5-7-json-features-for-a-test-drive/)
loads one JSON text document per line. It does not load MySQL's internal binary
JSON representation. Its timing comparison measures queries on JSON and TEXT
columns after import; it does not compare replication transport methods.

The native LOAD DATA paths in both pinned versions call
`Field::store(bytes, length, charset)`. For a JSON column, `Field_json::store`
converts text to utf8mb4, calls `Json_dom::parse`, then serializes the result.
`LOCAL` changes file transfer; it does not select `store_binary`. Loading into a
user variable and assigning the column with SET still uses SQL expressions.

Direct probes on 5.7.42 and 8.4.8 gave the same results:

| Input and mode | Result on both versions |
| --- | --- |
| `{"x":1}` with CHARACTER SET utf8mb4 | Stored as JSON OBJECT. |
| `"base64:type13:MjAyNg=="` with CHARACTER SET utf8mb4 | Stored as JSON STRING, not opaque YEAR/type 13. |
| Bytes `04 01` (binary JSON literal true) with CHARACTER SET utf8mb4 | Error 3140: invalid JSON text. |
| Valid JSON text with CHARACTER SET binary | Error 3144: cannot create JSON from the binary character set. |

The probes used server-side files under `secure_file_priv`, strict SQL mode,
newline records and `ESCAPED BY ''`. Neither failed load added a row.

LOAD DATA can import ordinary JSON text. It does not close the opaque-subtype or
extended-value transport gaps. Do not add a second write path for this purpose.
A separate throughput study could assess it for bulk INSERT workloads, but that
would also need transaction, error-skip and recovery tests.

Additional native references: both `sql/sql_load.cc`, field assignment in
`read_sep_field` and `read_fixed_length`; both `sql/field.cc`,
`Field_json::store(const char *, size_t, const CHARSET_INFO *)`.

## Separate transport choices

A general solution would require a different target write path:

1. Use a target extension that accepts validated binary JSON. This changes the
   deployment requirements and needs its own design and security review.
2. Generate target-compatible row events and submit them through `BINLOG`.
   MySQL 5.7 requires SUPER. MySQL 8.4 checks SUPER, BINLOG_ADMIN or
   REPLICATION_APPLIER. This is a replication-event execution path, not a JSON
   parameter. It requires a separate review of event conversion, session state,
   transaction boundaries, privileges and uncertain-write recovery.

Neither option is enabled here. An exact constructor for a bounded subset can
be added separately, but it must not silently fall back to an approximate value.
Keep original bytes in relay/recovery output and report the type and JSON path
when the current transport cannot preserve them.

## Pinned native references

The local trees use 5.7 revision `f7680e98b6bbe3500399fbad465d08a6b75d7a5c`
and 8.4 revision `0896fcd61dec11a0904166911a0126f59daaa1bf`.

- Both: `sql/sql_prepare.cc`, parameter conversion and value decoding.
- Both: `sql/field.cc`, `Field_json::store`, `store_json` and `store_binary`.
- Both: `sql/item_json_func.cc`, `sql_scalar_to_json`.
- 5.7: `sql/json_dom.cc`; 8.4: `sql-common/json_dom.cc`, JSON text formatting
  and opaque-type comparison.
- Both: `sql/sql_binlog.cc`, `mysql_client_binlog_statement` and event checks.

See [JSON_SUPPORT.md](JSON_SUPPORT.md) for the implemented paths and prior
integration results. Full stage-2 qualification still needs boundary, replay and
restart evidence for each catalog requirement; these probes do not replace it.
