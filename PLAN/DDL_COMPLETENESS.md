# DDL completeness and native engine behavior

Decision update, 2026-09-30. The [engine/charset foundation](DDL_NATIVE_DEFAULTS.md)
implements the first slice of this plan. The broader matrix remains a backlog. It supersedes the prototype's explicit
InnoDB-to-MyISAM CREATE rewrite and automatic collation substitution described in
[the initial DDL checkpoint](DDL_APPLY.md).

## Priority and scope

1. Remove forced engine/charset/collation rewriting and establish native engine
   selection and charset/default resolution as the reference.
2. Broaden DDL support, schema discovery and subsequent INSERT/UPDATE/DELETE
   coverage together. Publish the supported and rejected cases with evidence.
3. After those correctness gates, implement first-start handoff, SQLite-based
   restart/recovery and explicit operator resolution under
   [the start-boundary plan](START_BOUNDARY.md).

Statistics persist to SQLite for external readers; an embedded REST server or web
interface is not a deliverable. Dump/load remains entirely external. Automation
continues through SwiftPM and Make, retaining the mapped Docker build caches.

Current native findings: bare `ENGINE=DEFAULT` fails with syntax error 1064 on the
pinned servers; quoted `ENGINE='DEFAULT'` also requires a qualified temporary-engine
default to select MyISAM. Omitted ENGINE is the preferred positive baseline. See
the foundation document for the measured settings and current implementation limits.

## Coverage checklist prerequisite

The first [DDL coverage catalog](DDL_COVERAGE_CATALOG.md) step is implemented:
versioned scenario/profile/reference records, a shared case registry, and offline
`ddl-catalog-check` / `ddl-catalog-report` Make targets. The family matrix is the
starting taxonomy, not an exhaustive mapping of MySQL's tests. Existing fixture
passes remain historical evidence for their tested subsets; catalog qualification
remains partial. Pinned source scanning/review and named metadata/data evidence now
support the bounded lifecycle slice below; boundary-specific binlog/history and
query-context obligations remain gaps.

## Conditional CREATE/DROP and CREATE LIKE slice

The applier accepts `CREATE TABLE IF NOT EXISTS`, `DROP TABLE IF EXISTS`, and
permanent `CREATE TABLE [IF NOT EXISTS] destination LIKE template`. Definitions and
templates retain the existing supported type/key restrictions. The source SQL is
executed unchanged. Conditional CREATE with an existing destination preserves its
actual schema and data even when the proposed supported definition differs; SQLite
retains that schema version while completing the logged no-op's intent/checkpoint.
DROP of an absent table completes a no-op intent without inventing a schema.

LIKE discovers and validates the local template, including its engine, column
order, primary key and encoding defaults. It copies these defaults across schemas
rather than inheriting the destination database's defaults. A newly created clone
must be empty. MySQL opens the template even if IF NOT EXISTS preserves an existing
destination; the replicator requires it too. No engine/charset rewrite is added.

Native/direct-5.7 tests measure absent/matching/different conditional CREATE,
present/absent conditional DROP, same/cross-schema LIKE, existing destinations,
missing template/schema, and conditional LIKE with a missing template. Source
rejections (1050/1146/1049) emit no event; they are not applier tests. The separate
replica-only missing-template case starts from a valid source statement and
requires native error 1146 and Swift fail-stop, with the following event unapplied.

The 70-statement Swift/native stream adds following multirow inserts/deletes,
primary-key changes, signed INT and unsigned BIGINT boundaries, UTF-8/NUL/quote/
backslash/trailing-space bytes, and NULL versus empty text/binary values in both
position/MINIMAL-metadata and GTID/FULL-metadata profiles. All row images are FULL.
It does not expand supported row types, indexes, generated columns, temporary
tables, partitions, multi-object DDL or restart/recovery. Secondary-index and
AUTO_INCREMENT inheritance in LIKE remain explicitly unqualified.

The pinned implementation reference is `sql/sql_table.cc::mysql_create_like_table`
at MySQL commit `0896fcd61dec11a0904166911a0126f59daaa1bf`: under ROW logging,
permanent destination plus permanent template logs the original LIKE statement;
temporary template/destination branches need separate work. Native observations
and catalog assertions remain distinct evidence, with no full completeness claim.

## Database and schema creation slice

Implemented syntax: `CREATE {DATABASE|SCHEMA} [IF NOT EXISTS] name`, with optional
`[DEFAULT] CHARACTER SET` / `CHARSET` and `[DEFAULT] COLLATE`, including optional
`=`. Identifiers remain ASCII; encryption, READ ONLY, version comments, ALTER and
DROP DATABASE/SCHEMA remain unsupported. This does not add dump/load management.

Execute the original SQL. Explicit charset/collation is resolved against target
capabilities; charset-only utf8mb4 must agree with the logged compatible default.
When both are omitted, use the Query event's **server collation**, not the local
target global default or the source's selected database. Restore the target session
collation around execution and check the resulting schema defaults. Unknown 5.7
collations (including inherited 0900) stop before mutation rather than substitute.
The existing query-context decoder also rejects default encryption enabled in the
source context; explicit ENCRYPTION syntax is outside this grammar.

MySQL `write_db_cmd_to_binlog` records the created schema as Query.db and sets
`suppress_use`. Do not issue `USE` before CREATE: the recorded database may not yet
exist. The table-DDL path retains its existing default-database handling.
Conditional creation retains actual existing defaults and contents, even when
compatible requested options differ. Following table creation discovers the new
database defaults normally. No table schema cache entry is invented for a database.

SQLite format 4 adds nullable `ddl_intents.database_json`: database name and
predicted before/after defaults (and any applied server-collation context). Database
intents have no before/after table-schema IDs. A successful CREATE or logged no-op
advances the normal GTID/offset checkpoint; a target SQL failure leaves a pending
intent and BLOCKED diagnostic. Existing format-3 directories are not migrated or
resumed by this slice; automatic recovery remains future work.

Native fixtures cover omission with a different USE database, explicit encoding,
charset-only/collation-only options, both aliases, matching/different conditional
no-ops and source duplicate error 1007 with no binlog event. The Swift suite adds
following table creation and INSERT/UPDATE/DELETE in both position/MINIMAL and
GTID/FULL metadata profiles. It checks explicit and inherited unsupported collations
and denied CREATE permissions, including unchanged checkpoints and blocked following
DDL. These are named cases in `DatabaseCreationCases.swift`; fixture databases used
by this slice are not pre-created on replicas.

Pinned references: `sql/sql_db.cc` (`write_db_cmd_to_binlog`,
`set_db_default_charset`, `mysql_create_db`) and `mysql-test/t/ctype_create.test`
with its result file, at `0896fcd61dec11a0904166911a0126f59daaa1bf`. Adapted UTF-8
scenarios are independently authored; they do not claim whole-file MTR coverage.

Validation on 2026-09-30: all 59 applier/harness unit tests passed; both native
engine-policy profiles passed 25 named cases each; file-position/MINIMAL and
GTID/FULL-metadata Swift profiles passed 88 named cases each, including cleanup.
The pinned upstream reference check passed. Fresh catalog evidence increased
passing assertion/profile obligations from 44/638 to 48/690, with 24 partial
scenario/profile combinations and no fully verified combinations. The larger
denominator includes newly documented gaps. See the local
[results and reproduction commands](../artifacts/database-creation-20260930/README.md).

## Engine selection: preserve the statement's meaning

Configure and verify the source's default as InnoDB and both targets' default as
MyISAM. A statement with no ENGINE clause uses the receiving server's default;
the source's `default_storage_engine` setting is not replicated. An explicit
InnoDB clause can instead create InnoDB on the replica. A MyISAM default alone
does **not** turn it into an error. The existing prototype suite already observed
that distinction. [MySQL cross-engine replication](https://dev.mysql.com/doc/refman/8.4/en/replication-solutions-diffengines.html).

Therefore:

- Stop synthesizing `ENGINE=MyISAM` in target SQL. Preserve omission, default
  selection or an explicit engine request; never erase an explicit engine to make
  incompatible DDL succeed. MyISAM remains a target deployment/preflight setting.
- Use omitted ENGINE as the documented positive baseline. Qualify explicit
  default selection separately: test the requested spelling `ENGINE=DEFAULT`
  and the quoted `ENGINE='DEFAULT'` on the pinned servers, including actual logged
  SQL and native apply. Do not assume both spellings parse or resolve identically.
  The pinned MySQL resolver recognizes the name DEFAULT, while its grammar routes
  ENGINE through `ident_or_text`; that alone is not end-to-end replication evidence.
- Preserve actual native errors and stop on target failure. Do not shorten indexes,
  drop options/constraints, change types or substitute collations to obtain success.
  In particular, remove the prototype's automatic `utf8mb4_0900_ai_ci` to
  `utf8mb4_unicode_ci` rewrite from the intended replication policy. Provisioning
  compatibility is an external concern; unsupported replicated DDL is a diagnostic.
- Explicit InnoDB is outside the intended MyISAM apply contract. Qualify a native
  rejection profile using engine-creation restrictions and strict substitution
  behavior before labeling a Swift rejection native-equivalent. Keep an unrestricted
  native control that records InnoDB creation. If the production/reference profile
  permits that creation, Swift's early rejection is a declared MyISAM-only coverage
  restriction, not a native failure. Do not mutate the target into InnoDB and then
  attempt to convert it back.

`disabled_storage_engines` restricts creation/conversion without unloading the
engine; investigate it rather than attempting to remove InnoDB needed by MySQL's
own storage. Qualify it with `NO_ENGINE_SUBSTITUTION`, the source query's SQL mode,
and both native-applier and ordinary SQL sessions on the pinned versions. An
unavailable/disabled engine must not silently fall back. The first native fixture now measures these settings on the pinned versions;
production deployment compatibility remains unqualified.
[Engine restrictions](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_disabled_storage_engines),
[engine selection and substitution](https://dev.mysql.com/doc/refman/8.4/en/storage-engine-setting.html).

Local research reference: ignored `.upstream/mysql-server`, pinned commit
`0896fcd61dec11a0904166911a0126f59daaa1bf`; inspect `sql/sys_vars.cc`
(`Sys_default_storage_engine`, `NOT_IN_BINLOG`), `sql/sql_yacc.yy` (ENGINE grammar),
`sql/parse_tree_helpers.cc` (`resolve_engine`), `sql/handler.cc`
(`ha_resolve_by_name`) and `sql/sql_table.cc` (engine viability/substitution).
Use `mysql-test/t/disabled_storage_engines.test` and relevant `mysql-test/suite/rpl/`
and DDL tests as scenario sources, recording paths/revision and adapted expectations.
Do not infer Swift support merely from an upstream test passing.

## Character sets: event context and native default resolution

The prototype's `columnSQL` emits `CHARACTER SET utf8mb4` whenever a collation is
present. Its schema model records only the collation, its validator accepts a few
utf8mb4 collations, and its DDL parser substitutes 0900 with unicode_ci. These are
current subset restrictions, not a general character-set implementation. Remove
those assumptions alongside the engine fix; a COLLATE clause does not imply utf8mb4.

There are two distinct binlog sources of encoding information:

- **QUERY_EVENT for DDL:** the SQL contains explicit clauses; status variables
  carry `Q_CHARSET_CODE` (client charset, connection collation and server collation),
  optional `Q_CHARSET_DATABASE_CODE` and `Q_DEFAULT_COLLATION_FOR_UTF8MB4`.
  Native `Query_log_event::do_apply_event` restores this context before executing
  the query and reports unknown required charsets/collations. The current bridge
  preserves query status bytes but does not yet provide general context replay.
- **TABLE_MAP_EVENT for rows:** `DEFAULT_CHARSET` or `COLUMN_CHARSET` optional
  metadata carries collation IDs for character columns, including with MINIMAL
  metadata in the pinned 8.4 implementation. FULL adds such fields as column names;
  charset handling must not assume FULL is required. The table-map “default” is a
  compact encoding for column metadata, **not** the database/server default used
  when executing DDL. A new table need not produce a row map until later DML.

Source references at the pinned revision:
[`statement_events.h`](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/libs/mysql/binlog/event/statement_events.h),
[`rows_event.h`](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/libs/mysql/binlog/event/rows_event.h),
and [`sql/log_event.cc`](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/sql/log_event.cc).
The local sources show both status serialization and restoration; they are the
implementation reference for the next native fixtures.

Follow MySQL's resolution rules at the operation's historical boundary:

| Definition | Resolution |
| --- | --- |
| Explicit CHARACTER SET and COLLATE | Use that pair and validate compatibility |
| Only COLLATE | Use that collation's associated character set; do not prepend utf8mb4 |
| Only CHARACTER SET | Use the selected character set's applicable default collation, including logged/version-specific context |
| Neither on a column | Inherit the table's defaults |
| Neither on a table | Inherit the database containing that table, even when the query's current database differs |
| Neither on CREATE DATABASE | Use the effective server defaults in native query execution context, including replicated context where applicable |

Changing a database/table default does not retroactively reinterpret existing
column bytes. Distinguish default changes from explicit column/table character-set
conversion. Connection/query encoding is also separate from stored column encoding.
[Column rules](https://dev.mysql.com/doc/refman/8.4/en/charset-column.html),
[table rules](https://dev.mysql.com/doc/refman/8.4/en/charset-table.html),
[database rules](https://dev.mysql.com/doc/refman/8.4/en/charset-database.html).
Local `sql/sql_table.cc::set_table_default_charset` resolves the owning schema's
collation, and native query apply restores logged session context. Consequently,
“use the target server default for every missing field” would also be wrong.

Implementation requirements for this increment:

1. Expose typed, bounded query status/context through the Rust/Swift interface and
   diagnostic JSON as needed. Preserve original query bytes; decode/execute under
   their actual client encoding rather than assuming every query is UTF-8. Qualify
   session reset between DDL and the DML connection/binding settings.
2. Preserve explicit/omitted clauses and let qualified native semantics determine
   defaults. Extend internal discovered schema with character-set name/ID and
   collation name/ID where relevant, queried from `information_schema.COLUMNS`,
   `TABLES`, `SCHEMATA` and collation/charset catalogs. Validate supported ID/name
   mappings across 8.4 and 5.7; no prefix guessing or arbitrary numeric remapping.
3. Retain database/table defaults and resolved column encoding with historical schema
   versions and provenance. Bootstrap discovery uses the prepared target at its
   known boundary; subsequent defaults evolve in source order. For row decoding,
   prefer event metadata and validate it against that history. If older/missing
   metadata cannot be resolved safely, stop; never query today's source defaults
   to fill a historical gap or guess utf8mb4.
4. Expand exact byte/character-length handling and parameter binding for each newly
   supported charset. The existing UTF-8/binary decoder and four-bytes-per-character
   checks are insufficient for arbitrary charsets. Unknown or 5.7-incompatible
   required collation/context stops with a precise diagnostic. Preserve the existing
   externally provisioned DML-only compatibility subset as separately documented;
   it does not authorize rewriting newly replicated DDL.

Add native/Swift fixtures for latin1, utf8mb3, utf8mb4 and binary columns; mixed
column charsets; COLLATE-only/CHARSET-only/neither; server/schema/table/column
inheritance; fully qualified CREATE into a different database; defaults changed
between events; ALTER DEFAULT versus CONVERT; query literals/identifiers with a
different client encoding; `_bin` collation versus binary bytes; and unknown IDs or
8.4-only collations on 5.7. Compare resolved metadata, HEX byte values, row decode,
index byte lengths, errors and following DML under MINIMAL and FULL metadata.
Include replay after later source default/schema changes to detect accidental use
of present-day metadata. No silent transcoding, replacement characters or collation
substitution may make a failing case pass.

## Native-first qualification matrix

Keep the topology: source MySQL 8.4 InnoDB, native MySQL 8.4 MyISAM reference,
Swift-applied MySQL 5.7 MyISAM target; all produce binlogs. Source GTIDs remain
ON/ON, targets OFF_PERMISSIVE/WARN, Swift apply sessions GTID_NEXT=AUTOMATIC.
Test positional and GTID starts and the supported FULL/MINIMAL metadata modes.
Native is a harness reference, not a production dependency.

First measure each scenario on the native branch, with fresh state for expected
failures. Then implement/qualify the Swift result. Keep a versioned matrix with
statement/fixture ID, source acceptance and logged representation, settings,
native result, 5.7 capability, Swift result, SQLSTATE/error/warnings, before/after
schema and data, binlog effects, stopped boundary and evidence paths. Classify
native success, native failure, 5.7 incompatibility and not-yet-implemented
separately. A source-side syntax error produces no event to replicate.

| Order | DDL family | Required cases and following DML |
| --- | --- | --- |
| A | Engine policy | Omitted/default/explicit engine; CREATE, drop/recreate and ALTER ENGINE; actual table engines on both replicas; engine restrictions and substitution modes |
| B | Core table lifecycle | CREATE/DROP with conditional clauses, TRUNCATE, CREATE LIKE, same/cross-schema rename and multi-table rename/drop; missing objects, existing destinations and temporary-table/logging behavior |
| C | Columns and defaults | ADD/DROP/MODIFY/CHANGE/RENAME COLUMN, FIRST/AFTER, multi-clause ALTER, nullability, literal/expression defaults and AUTO_INCREMENT; widen/narrow conversions, retained values, warnings and rejected forms |
| D | Keys and indexes | CREATE/DROP INDEX, ALTER ADD/DROP PRIMARY/UNIQUE/secondary/composite/prefix indexes; duplicate data, key changes, byte limits, FULLTEXT/SPATIAL and unsupported 8.4 index forms |
| E | Database and encoding | CREATE/ALTER/DROP DATABASE, default database context, database/table/column charset and collation, CONVERT TO CHARACTER SET, identifier quoting/case and renamed objects |
| F | Remaining fleet DDL | Generated columns, CHECK/foreign keys, partitions, table options/row formats, ALGORITHM/LOCK, views, routines, triggers, events and CREATE SELECT; classify native logging, engine and 5.7 limits before claiming support |

Each family is a qualification backlog, not unconditional acceptance of all SQL.
Prioritize actual fleet migrations within it. Avoid accidental side effects such
as replaying source row events into target triggers that fire again. Unsupported
objects or row/key/type shapes must remain explicit gaps even if their CREATE SQL
would execute successfully. For each supported schema change, prove subsequent
INSERT/UPDATE/DELETE using that schema; broaden the decoder/schema validator and
key handling as necessary. Preserve all existing DML regressions.

Include the concrete long-index incompatibility: a unique utf8mb4 key whose byte
length fits the source InnoDB layout but exceeds MyISAM's limit. Cover values
below, at and above the boundary, composite and prefix keys, and ALTER on populated
tables. Record SQL mode and page/row format; do not assume all non-unique oversized
index forms fail rather than warn/truncate. The documented MyISAM key limit is
1000 bytes; InnoDB limits depend on its layout. Test actual errors and effects,
without making either reference succeed by editing the index.
[MyISAM limits](https://dev.mysql.com/doc/refman/8.4/en/myisam-storage-engine.html),
[index length semantics](https://dev.mysql.com/doc/refman/8.4/en/create-table.html).

## Execution and schema history

Prefer preserving source DDL semantics over an expanding SQL rewrite policy.
Evaluate forwarding a validated single DDL statement with its query-event context,
using parsing for classification, affected-object discovery and support checks.
Do not turn the prototype into an unrestricted statement executor. Qualify source
SQL mode, charset/collation, database, timestamp/time zone and other relevant query
status variables; unknown semantic context blocks. Preserve native binlog-generated
SQL forms as well as client spellings. Never split a multi-object/clause statement
into independently committed rewrites to make it pass.

Retain ordered DDL barriers and the durable intent before execution. After success,
discover the actual target schema, verify it against the declared operation, retire
affected historical versions and invalidate table-map/prepared-statement caches
before following DML. Current source metadata cannot describe an older event.
Conditional no-ops, implicit commits, rename dependencies and default-database
changes each need boundary tests. Discover schemas internally, without config
schema manifests.

DDL on large instances can exceed the prototype's 10-second query timeout. Define
and test a DDL-specific timeout/cancellation policy and metadata-lock behavior.
A timed-out or disconnected statement may still execute: preserve its intent and
block until its outcome is established. No automatic retry/recovery is introduced
as part of this completeness increment.

## Test-harness reporting follow-up

Review feedback, 2026-09-30: numeric messages such as `passed DDL/DML step 1`
do not explain the scenario or help locate its implementation. Apply the following
reporting convention across test suites, starting with the DDL/DML case loop in
`Sources/ReplicatorLabCore/DMLQualification.swift`:

- Give every case a stable, searchable ID and a descriptive name explaining the
  operation and behavior being checked; ordinal progress may be additional context.
- Include the case definition's repository-relative source path and line number
  in progress output so the scenario can be found directly in the codebase.
- Use the same case identity in start/pass/failure messages and saved results;
  failures should also identify the specific assertion that failed.
- Capture source locations at the case definition rather than the shared logging
  helper, and keep line numbers generated rather than manually maintained.

Implemented for `ddl-suite`, `dml-suite` and `native-ddl-suite`: case definitions
capture their source locations, and progress/failures share IDs with incremental
`cases.json` and final result entries. Success is reported after the scenario's
assertions complete, not merely when its applier process exits. The shared reporter
is available for extending this convention to the other harness suites.

## Acceptance for the next increment

- No hard-coded engine/charset or collation substitution remains in the accepted
  DDL path; encoding follows event context and historically resolved native defaults.
  Omitted/default engine cases are backed by actual source/native/Swift evidence;
  configuration and session defaults are checked, not inferred from seeded tables.
- The matrix enumerates supported cases and explicit gaps. Native successes in
  the agreed common 8.4/5.7 subset pass schema/data/binlog comparisons; native
  failures assert the expected category, diagnostic, partial effects and stop.
- Every positive change has following DML and schema-cache checks. Every negative
  has a later transaction that must not apply, with no false completed checkpoint.
  Compare normalized effects and boundaries, not identical raw binlog bytes/GTIDs.
- SQLite intents/history remain bounded under the existing pressure-triggered,
  minimum-age cleanup, with pending references pinned. Run Swift/Rust tests and
  DDL/DML suites through existing Make/SwiftPM automation; retain evidence.
- The earlier 80-test/14-operation prototype result remains historical evidence
  only. It does not pass this revised engine-policy or DDL-completeness gate.

Recovery and operator skipping are the next separate implementation stage after
these gates, as detailed in [START_BOUNDARY.md](START_BOUNDARY.md). Broader fleet
coverage remains visible; neither this plan nor the old subset completes Phase 1.
