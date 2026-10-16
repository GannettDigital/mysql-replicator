# Table-name case settings

Status: implemented on `beta/6/20-table-name-case`; selected live tests passed.

## Contract

Set `source.lowerCaseTableNames` to the source server's `lower_case_table_names`.
The default is 0. The target must use the same value. This applies to live capture,
reconnect, offline replay and recovery. The setting does not rename tables.

- Mode 0 preserves database and table name bytes. Case differences can identify
  different tables. Unicode normalization is not applied.
- Mode 1 uses MySQL's native lowercase mapping for database and table references.
  Column names retain their native spelling. Stored routine names are not folded
  as table names. Table filters use the same case rule.
- Mode 2 is not qualified. It preserves some stored names while comparing names
  without case. It requires a case-insensitive filesystem. Linux Docker volumes
  in this lab do not provide that environment.

Both servers must match. Cross-setting replication needs a separate collision and
metadata design. It is not enabled by this option.

## Native source

The pinned 5.7 source uses `my_casedn_str(files_charset_info, ...)` for database
and table names when `lower_case_table_names` is nonzero. `files_charset_info`
uses `my_charset_utf8_general_ci`. The generated native lowercase map already
used by this project supplies the corresponding scalar conversion.

References in `.upstream/mysql-server-5.7`: `sql/sql_parse.cc`, `sql/sql_base.cc`
and `sql/mysqld.cc`. The startup checks in `mysqld.cc` change mode 2 to mode 0
on a case-sensitive filesystem. MySQL 8.4 also binds this setting to its data
dictionary at initialization. Do not change it on an existing server directory.

## Saved state and archives

State format 10 records the case setting in `name_case`. Resume and recovery
reject a changed setting. Existing state upgrades only with mode 0. The relay
format and event bytes do not change. Back up stopped state before upgrading.

Fetched archives retain the source server setting. Replay checks it against the
configuration. External raw binlogs do not record this server setting. Their
operator declaration defaults to `source.lowerCaseTableNames`; an explicit
`archive.lowerCaseTableNames` must match it. Replay does not connect to the source.

## Checks

Unit tests cover parser names, filter case rules, distinct Unicode byte sequences,
saved-state migration, changed-setting refusal and archive/configuration mismatch.
The example-file test checks that the new option has documentation.

The shared `lowercase-tables` lab variant starts source, native reference and
target with mode 1. `ddl-compat-table-name-case` uses mixed-case references,
non-ASCII names, CREATE LIKE, RENAME, row changes and restart between DDL steps.
The SQL encoding case also restarts between encoded CREATE and ALTER.
All 472 selected unit tests passed. The two selected DDL cases passed on all
four profiles, with 27 shared steps per run:

| Profile | Evidence under `artifacts/lab/` |
| --- | --- |
| 8.4 → 5.7 MyISAM | `20261014T210233Z-cf266239` |
| 5.7 → 8.4 InnoDB | `20261014T210305Z-f9cd55c8` |
| 5.7 → 5.7 MyISAM | `20261014T210332Z-2025fa0d` |
| 5.7 → 5.7 InnoDB | `20261014T210337Z-af55c46b` |

The mode-1 `offline-replay` case also passed for both cross-version profiles:

- 8.4 → 5.7 MyISAM: `artifacts/lab/20261014T210614Z-1ffecf80`.
- 5.7 → 8.4 InnoDB: `artifacts/lab/20261014T210617Z-69816131`.

These runs fetch rotated files, replay fetched and external raw archives, stop
and resume, and create a support bundle. Replay uses a disabled source address
and no source credentials. Same-version offline runs were not repeated here.
Full charset and case-setting qualification remains open.
