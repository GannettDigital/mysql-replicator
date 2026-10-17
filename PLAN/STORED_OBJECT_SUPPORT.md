# Views and stored routines

Branch: `beta/6/42-stored-object-ddl`, based on branch 41.

## Native behavior

View and routine DDL enters the binlog as Query events, including when
`binlog_format=ROW`. Routine calls and writes through views produce the row
effects that the applier must apply. The applier must not call the routine
again or repeat the view write from application SQL.

MySQL records the resolved definer in CREATE statements. View DDL also records
the view options. The target must retain that definer. Account creation and
privilege setup remain external operations. The target server checks its own
definer privileges and account rules. The applier does not replace the definer
with its connection user.

MySQL 5.7 and 8.4 permit ALTER PROCEDURE and ALTER FUNCTION. These operations
change routine characteristics, such as SQL SECURITY, data access and COMMENT.
They do not replace the routine body or parameter list. The source logs the
ALTER statement even with ROW logging.

Native DROP VIEW accepts a list and optional IF EXISTS, RESTRICT or CASCADE.
The latter two clauses do not add dependency removal. In 5.7, a failed list
can remove some views and then report an error. Such a source error remains
outside our successful-DDL contract. Do not interpret it as a complete DROP.

Local upstream references:

- 5.7 `sql/sp.cc`, `sp_update_routine`: update characteristics and log ALTER.
- 5.7 `sql/sql_yacc.yy`, `sp_a_chistics`, `view_select_aux` and DROP VIEW grammar.
- 5.7 `sql/sql_view.cc`, `mysql_create_view` and `mysql_drop_view`.
- 8.4 `sql/sp.cc`, `sp_binlog_create_routine_stmt` and `sp_update_routine`.

## This increment

- Accept ALTER PROCEDURE and ALTER FUNCTION. The target parses the complete
  source-accepted characteristics. It receives the original SQL and session
  context. Multiple SQL statements are not enabled on the target connection.
- Accept parenthesized view queries. The target parses the query body. A
  query form that requires a newer target still receives a native SQL error.
- Keep every name in a multi-view DROP. Check every object before execution
  and confirm its absence afterwards. Preserve the complete SQL in the DDL
  journal. No SQLite format change is needed.
- Check every view name against replication filters. A list that crosses
  included and excluded objects still requires explicit resolution. This is
  the existing multi-object DDL policy, not a claimed native restriction.
- Reject source DDL error codes before filter decisions. Filters must not hide
  a partially failed source DROP.

The shared `ddl-compat-stored-objects` case checks procedure and function
attributes, explicit definers, view LOCAL and CASCADED check options, permanent
row effects, multi-view DROP, following DML, saved SQL, restart and offline
stop/resume. The target and native replica must agree with source observations.
The offline phase uses an unreachable source.

## Conditional routine creation

Branch 43 adds routine CREATE IF NOT EXISTS translation for 5.7 targets.
The 8.4 implementation logs the clause even when a routine already exists.
For an absent routine, remove only the parsed header clause. For an existing
routine, issue no target CREATE and retain the body, definer and attributes.
Both paths use a DDL intent. Save the original SQL, target SQL and the rule
`mysql57-routine-create-if-not-exists`. A no-op has empty target SQL. A target
that supports the syntax receives the original statement. The version rule
is in `NativeReplicationRules`. No new configuration option or SQLite format
is required. Normal target exclusivity still applies.

## Remaining review

The current tests do not qualify all stored-program bodies, absent definers,
all privilege failures or partially failed source DDL.
The source-version/target-version differences in routine and view expressions
also need explicit checks. Do not mark the broad stored-object catalog group
complete from this increment alone.

Trigger and event policies do not change. Account and privilege replication
remain outside the application schema scope. An uncertain target DDL remains
pending for DBA resolution; no automatic DDL retry is added.

## Verification

The selected shared workflow passed on all four profiles:

| Profile | Lab run |
| --- | --- |
| 8.4 → 5.7 MyISAM | `20261015T214702Z-59e10225` |
| 5.7 → 8.4 InnoDB | `20261015T214844Z-c8e2e364` |
| 5.7 → 5.7 MyISAM | `20261015T215020Z-e673d1c6` |
| 5.7 → 5.7 InnoDB | `20261015T220134Z-068cc26c` |

All runs used build-input digest
`85d25a281a0d7a292acd5cdba5720bdc85c0246b133f9131044f6c8ad262fd5d`.
Each run checked live metadata and row effects, clean restart, original SQL in
completed DDL intents, and offline stop/resume with the source unavailable.

The focused run passed 31 unit tests. The broader apply/lab run passed 459 of
460 tests. One support-bundle test could not find the CLI because the command
lacked `REPLICATOR_TEST_BINARY_DIR` for the shared build directory. All five
support-bundle tests passed after that path was supplied. Periphery found no
unused code in the current build index. No MySQLSyntax code changed, so its
separate syntax suite was not run.

These selected runs do not qualify every stored-object form or replace the
full release suite.

## View renaming

Branch 44 uses the existing RENAME TABLE path for both tables and views.
MySQL applies each pair from left to right. A destination name must be free
at that step. View moves must stay within one database. Both native versions
return ER_FORBID_SCHEMA_CHANGE (1450) for a cross-database view move. See
`sql/sql_rename.cc` in both upstream trees.

The applier reads each initial object, then resolves the ordered namespace.
The target account needs SHOW VIEW to read view definitions.
It sends one original SQL statement. Before execution, the DDL journal stores
table schema transitions and view metadata transitions. The view record has
the database, name, query definition, definer, security mode, check option and
creation charset settings. View records do not enter the row-schema cache.
The journal uses an optional field in existing context JSON. Old records remain
readable. No SQLite schema migration is needed.

After execution, the applier checks the resulting table and view metadata.
It does not rewrite view queries when a base table moves. MySQL owns that
behavior. An uncertain statement remains pending under the existing DDL policy.

The shared `ddl-compat-view-renames` workflow checks a single rename, a view
swap, a table/view name swap, and a mixed rename list. It checks following
DML, clean restart, saved view metadata and offline stop/resume. It also checks
native error 1450 and unchanged binlog positions on each fixture server.

## View rename verification

The final view workflow passed on all four profiles with the same binary inputs.
Each run includes clean restart, offline stop/resume, saved view metadata and
native cross-database rejection checks.

| Profile | Lab run |
| --- | --- |
| 8.4 → 5.7 MyISAM | `20261015T230428Z-030017a3` |
| 5.7 → 8.4 InnoDB | `20261015T230652Z-e9e05ed0` |
| 5.7 → 5.7 MyISAM | `20261015T230904Z-13e400ff` |
| 5.7 → 5.7 InnoDB | `20261015T230258Z-365103b1` |

Build-input digest: `0ab16d76fb2acd87ab31e08be964c67ce1f0de36ff61396ca1ecaa6b86779b9a`.

The final 5.7 InnoDB run also passed the foreign-key workflow. The reverse
foreign-key regression passed in `20261015T225517Z-1c194a8d`, before the final
restoration of the single-rename parsed-name accessor. All 463 apply/lab unit
tests passed on the final source. Periphery found no unused code. The journal
unit test checks a failed checkpoint, retained PENDING metadata, successful
completion and reopened state. MySQLSyntax did not change.

These checks cover the selected cases. They do not replace full release
qualification or qualify all stored-program bodies and privilege variants.
