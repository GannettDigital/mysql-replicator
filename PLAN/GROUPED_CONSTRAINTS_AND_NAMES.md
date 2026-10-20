# Grouped constraints and native index names

Branch: beta/6/61-grouped-constraints-index-names.

Parenthesized ADD groups now accept named PRIMARY/UNIQUE, FK and CHECK clauses.
The existing source-version CHECK policy applies inside these groups. Removing
ignored 5.7 checks retains adjacent columns, constraints and commas. A group
that contains only ignored checks produces no target DDL.

Unnamed ordinary keys use native collision names. PRIMARY is reserved even when
the table has no primary key. MySQL 5.7 uses at most 30 UTF-8 bytes of the base
name for a collision suffix. MySQL 8.4 uses 61. Both try suffixes 2 through 99.
The code follows the target version. Explicit names are unchanged.

Direct probes confirmed ASCII long names, PRIMARY and multibyte names on 5.7.42
and 8.4.8. If the 8.4 byte truncation splits a UTF-8 character, native MySQL
rejects the generated name with error 1280. The applier reports this before SQL.
Native references: make_unique_key_name in both pinned sql/sql_table.cc files;
5.7 MAX_FIELD_NAME is 34 in sql/sql_const.h.

Long unnamed collision names can differ across versions. Later DDL that names a
source-generated index can therefore fail on the target, as with native SQL.
Use explicit names when those names must remain stable across server versions.
This increment does not introduce a source-to-target index-name mapping.

All 22 selected column/index, CHECK and schema-change tests passed. The shared
case ddl-compat-grouped-constraints covers three 5.7-source profiles, later rows,
saved-state restart and offline replay. It is added for the GitHub release checks;
it has not been run locally in this increment. An 8.4 source CHECK remains a
separate target-version restriction.

The shared grouped-constraint case passed on the reverse InnoDB profile in
`20261016T175556Z-c45d133e`, including restart and offline stop/resume.
