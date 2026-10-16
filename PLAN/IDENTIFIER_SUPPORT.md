# MySQL identifier support

Status: implementation in progress. No complete-support claim.

## Native checks

The local probes used MySQL 5.7.42 and 8.4.8 with `lower_case_table_names=0`.
Both versions accepted these cases:

- Separate tables and columns named `é` and `e` followed by U+0301.
- Unquoted Chinese table and column names.
- A column name with 64 Chinese characters. A 65-character name failed.
- A column reference `É` for a column defined as `é`. The reference did not
  select the separate decomposed name.

A 64-character Chinese table name failed because its encoded filename was too
long. The SQL name limit and the filesystem name limit are separate constraints.
A trailing-space column name failed with error 1166.

With a utf8mb4 client, a quoted supplementary character became `?` in the stored
name. Native conversion raised a warning. Do not claim that MySQL rejects every
such statement. The implementation must account for the logged client charset
before it can reproduce this conversion.

## Source evidence

The pinned 5.7 source is `f7680e98b6bbe3500399fbad465d08a6b75d7a5c`.
The pinned 8.4 source is `0896fcd61dec11a0904166911a0126f59daaa1bf`.

- `sql/sql_yacc.yy`, `IDENT_sys`: convert quoted identifiers to the system charset.
- 5.7 `sql/sql_class.cc`, `THD::convert_string`: conversion errors can produce
  warnings and replacement characters.
- 5.7 `strings/ctype-utf8.c`, `my_strcasecmp_utf8`, and 8.4
  `strings/ctype-utf8.cc`, `my_strcasecmp_utf8mb3`: compare case through the
  native character map. Do not use Swift canonical string equality as a substitute.

## Implementation order

1. Preserve bytes in table cache keys and schema comparisons. Keep saved JSON
   compatible with existing state.
2. Apply native case rules to column, index and relationship references. Keep
   table case rules separate.
3. Extend lexer, quoting, filters and discovery. Test exact names in the lab
   comparison code too; the test oracle must not merge names.
4. Test live DDL/DML, bootstrap, restart and replay on the four profiles.
   Include reserved words, backticks, name lengths and case settings.

The first increment keeps the existing ASCII acceptance limit. It does not
claim that the remaining steps are complete.

## Native case map

`tools/mysql_identifier_map.py` checks both pinned source trees. It emits the
shared lowercase map in `NativeIdentifierLowercase.swift`. It fails if the
versions differ or the number of mapped characters changes. Use `--check` to
compare the generated file without changing it.

The native map uses the older system-charset rules. For example, U+0130 maps to
`i`, not `i` followed by U+0307. Do not replace it with Swift `lowercased()`.
Definition names remain byte-exact. Column references use native case comparison.
The parser still limits accepted identifiers to ASCII in branch 17.

## Unicode parser increment

Branch 18 removes the ASCII name limit. Names in the schema model use UTF-8 and
must fit the native 64-character system-charset limit. The lexer counts scalars,
not UTF-8 bytes or Swift grapheme clusters. It preserves source SQL byte ranges.

An additional native probe confirmed the same supplementary-to-`?` conversion
for unquoted names on both versions. The parser records the native stored name.
It does not rewrite the source SQL. The lexer does not apply this conversion to
string literals. The scope parser uses the same effective identifier names when
it checks table filters.

The live input must use UTF-8 for non-ASCII Query text in this increment.
Other client charsets need a separate byte-aware parser path. The implementation
must not decode latin1 or Shift-JIS bytes as UTF-8 merely because the bytes form
a valid UTF-8 sequence. The new diagnostic includes the logged client charset ID.

Table case handling for nonzero lower_case_table_names remains open. The existing
four Linux profiles use zero. Do not claim full identifier qualification from
these selected fixtures.

## Prepared statement keys

The first shared Unicode run failed on all four profiles. Two distinct table
names used the same prepared statement. The client cache used Swift `String`
keys, which compare composed and decomposed Unicode forms as equal. The second
INSERT therefore reached the first table and failed with duplicate-key error 1062.
The failed run artifacts and support bundles remain available.

The cache now uses the exact SQL bytes as dictionary keys. Dictionary lookup
hashes the bytes and compares keys to resolve hash collisions. It does not use
SHA-256 or a hex string. The connection still limits the cache to 128 statements.
Client row lookup also compares column and table name bytes. Unit tests check
separate statements, exact reuse, error eviction, and separate row columns.
