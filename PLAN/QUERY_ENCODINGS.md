# Query-event SQL encodings

Status: implemented on `beta/6/19-query-encodings`; selected tests passed.

## Native behavior

Query events retain SQL bytes and the client/connection charset settings. Native
replication restores that context before execution. It does not assume that the
SQL is UTF-8. The 5.7 lexer checks `my_ismbchar` before it interprets quote and
backslash bytes. A Shift-JIS character can contain byte 0x5c without starting an
escape. Identifier conversion uses the system charset. Ordinary string literals
use the connection charset.

Pinned source references:

- MySQL 5.7 `sql/sql_lex.cc`, `get_text` and identifier lexing.
- MySQL 5.7 `sql/sql_yacc.yy`, `IDENT_sys` and `text_literal`.
- MySQL 5.7 `strings/ctype-sjis.c`, `ctype-cp932.c`, `ctype-big5.c`,
  `ctype-gbk.c`, and `ctype-gb18030.c`, `ismbchar` functions.
- MySQL 5.7 `sql/log_event.cc`, `Query_log_event::do_apply_event`.
- MySQL 8.4 `sql/sql_lex.cc`, `sql/sql_yacc.yy`, and the corresponding
  `strings/ctype-*.cc` implementations.

Repository revisions are pinned in `tests/DDLCoverage/upstream.json`.

## Implementation

The lexer keeps byte offsets in the original SQL. It skips complete multibyte
characters where their trailing bytes can look like SQL syntax. The target's
native charset conversion supplies decoded identifier and literal metadata.
The conversion queries are read-only and run at the DDL barrier. A local cache
reuses repeated token conversions within the statement. Ordinary UTF-8 DDL keeps
the existing local parsing path.

String literals retain their connection-charset bytes as well as their text.
This matters for binary defaults and binary ENUM/SET labels. Parser-only bytes
are resolved before the schema is saved. Table filters use the same tokens and
logged SQL mode as the DDL parser.

The target receives the original SQL bytes through COM_QUERY under the logged
client charset. Authorized collation edits still use original byte offsets.
The `ddl_details.context_json` record includes source and target SQL in base64.
Failure diagnostics also retain raw SQL bytes. Existing state needs no SQLite
schema migration. The relay still retains the original Query event.

## Tests and remaining checks

All 321 selected apply, protocol and catalog unit tests passed. Tests cover exact
COM_QUERY bytes, multibyte quote/backslash boundaries, SQL mode, filter identity,
compatibility-edit offsets and pending DDL bytes after closing SQLite.

The shared `ddl-compat-query-encodings` case uses PREPARE with explicit encoded
bytes on the source. It checks latin1 and Shift-JIS identifiers, text/binary/ENUM
defaults, ALTER and following row changes. The suite also reopens saved state.
The encoded tables are dropped before that final restart; this run does not
prove a restart between encoded CREATE and ALTER. Filter checks are unit tests.

Both this case and `ddl-compat-unicode-names` passed on all four profiles
(32 steps per profile):

| Profile | Evidence under `artifacts/lab/` |
| --- | --- |
| 8.4 → 5.7 MyISAM | `20261014T204922Z-7aac1bb7` |
| 5.7 → 8.4 InnoDB | `20261014T204923Z-4daa9668` |
| 5.7 → 5.7 MyISAM | `20261014T205212Z-de83ddb8` |
| 5.7 → 5.7 InnoDB | `20261014T205241Z-7bdf49df` |

These selected cases do not qualify every charset,
literal introducer, generated expression or routine-body combination.

The next increment adds restart points before the latin1 and Shift-JIS ALTER
statements. Those stronger tests passed on all four profiles with table-name
mode 1. See [TABLE_NAME_CASE.md](TABLE_NAME_CASE.md) for evidence paths.
