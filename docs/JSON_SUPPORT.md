# JSON support

The replicator supports ordinary JSON documents on all four tested profiles.
This includes objects, arrays, strings, booleans, JSON null, and supported numeric
values. SQL NULL and JSON null remain separate values.

MySQL stores JSON in a binary format. Row-based binlog events use that format.
The replicator decodes these events and writes equivalent values to the target.
Object key order and whitespace can change. Array order is preserved.

For example, this source statement is supported:

```sql
INSERT INTO example (id, obj)
VALUES (1, '{"id":1,"val":"some"}');
```

The examples assume a table with an `id` primary key and an `obj JSON` column.

## Store binary data as a Base64 string

Avoid MySQL-specific binary values inside application JSON documents. For
example, this expression puts raw bytes inside JSON:

```sql
JSON_OBJECT('data', CAST(X'01020304' AS BINARY))
```

MySQL accepts the expression. However, MySQL 5.7 and 8.4 can assign different
internal binary subtypes to the result. Ordinary JSON text cannot retain that
subtype. This can prevent exact transfer through SQL clients and JSON tools.

For portable JSON, encode the bytes as Base64. Store the result as a JSON string.
Use a field name or an encoding field to identify the encoding. For example,
bytes `01020304` become:

```json
{"base64_data":"AQIDBA=="}
```

Write the document with ordinary SQL:

```sql
INSERT INTO example (id, obj)
VALUES (1, '{"base64_data":"AQIDBA=="}');
```

The application must encode and decode the Base64 value. MySQL and the
replicator treat the value as a JSON string. No binary-value compatibility rule
is necessary.

The replicator does not automatically convert existing typed binary values to
Base64 strings. Such a conversion would change their type and application
behavior. Existing support for exact binary values remains available.

## YEAR values from MySQL 5.7

MySQL 5.7 can put a typed YEAR value inside JSON through a SQL expression.
The equivalent expression on MySQL 8.4 produces an unsigned JSON integer.

For the `mysql57-to-mysql84-innodb` profile, enable this rule if you accept that
change:

```yaml
compatibility:
  jsonYearToInteger: true
```

The default is `false`. Set the rule before state initialization. Use the same
conversion for JSON values in the target baseline. The saved policy must remain
the same on restart and during recovery.

The rule applies to live replication and offline replay. It converts zero and
years from 1901 through 2155. It changes `JSON_TYPE()` and can change comparisons.
Normal YEAR columns and ordinary JSON numbers remain unchanged. See the
[YEAR compatibility notes](../PLAN/JSON_YEAR_COMPATIBILITY.md) for test results.

## JSON indexes and defaults

Support depends on the target version and storage engine.

| Feature | MySQL 5.7 MyISAM | MySQL 5.7 InnoDB | MySQL 8.4 InnoDB |
| --- | --- | --- | --- |
| Index on a STORED generated scalar column | Yes | Yes | Yes |
| Index on a VIRTUAL generated scalar column | No: native engine limit | Yes | Yes |
| Functional index on a scalar expression | No: native version limit | No: native version limit | Yes |
| Non-NULL JSON expression default | No: native version limit | No: native version limit | Yes |

Extract a scalar value before you index JSON. For example:

```sql
CREATE TABLE example (
  id INT PRIMARY KEY,
  obj JSON,
  name VARCHAR(40) AS (obj->>'$.name') STORED,
  KEY by_name (name)
);
```

This form works with all tested target profiles. The parser accepts
`JSON_EXTRACT`, `JSON_UNQUOTE`, `->`, `->>`, JSON constructors, and supported
`CAST` expressions. The full generated-expression matrix is not qualified. Missing tests do not
identify a specific unsupported expression. See [support status](SUPPORT.md#support-status).
A direct index on a JSON column is invalid in native MySQL.

MySQL 8.4 also accepts these forms:

```sql
CREATE TABLE example (
  id INT PRIMARY KEY,
  obj JSON DEFAULT (JSON_OBJECT()),
  KEY by_name ((CAST(obj->>'$.name' AS CHAR(40))))
);
```

The current 8.4 target profile has a 5.7 source. That source cannot create
functional indexes or JSON expression defaults. You can include these features
in an existing 8.4 target table. The applier records their metadata and preserves
it during row changes, restart, and offline replay. Target-only indexes and
defaults must not change the visible column layout. Target constraints still
apply to every write.

The DDL parser also selects these rules from the target profile. It does not
apply a 5.7 restriction to an 8.4 target. Tests of parser acceptance do not prove
live replication from an 8.4 source to an 8.4 target; no such profile exists.

JSON defaults need a parenthesized expression. Native MySQL 8.4 rejects
`obj JSON DEFAULT '{}'`; use `obj JSON DEFAULT ('{}')`.

## Other limits

The replicator preserves signed and unsigned 64-bit integers, supported DECIMAL
values, and finite DOUBLE values. Selected temporal and binary values also have
exact SQL construction paths. Support for these special types is not complete.
Some binary subtypes and temporal values cannot be recreated exactly through the
current target SQL path.

If the replicator cannot preserve a value under the configured policy, it stops.
It retains the source bytes for diagnosis. It does not silently replace the
value with a string or an approximate number.

Partial JSON updates from MySQL 8.4 require a complete before image.
Use `binlog_row_image=FULL` on the source.

See the [test lab guide](TEST_LAB.md) for the JSON test cases. The
[implementation notes](../PLAN/JSON_SUPPORT.md) contain detailed type limits,
test history, and links to the native-source investigation.
