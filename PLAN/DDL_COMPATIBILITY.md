# MySQL 5.7 DDL compatibility

This increment broadens ordered DDL application for an 8.4 ROW/FULL source and a
5.7 MyISAM target. It preserves the original SQL, journals an intent before
issuing it, validates resulting metadata, and advances the GTID only after the
operation succeeds. Disconnects or errors after submission remain uncertain
and block; this does not introduce automatic DDL replay or crash recovery.

## Supported additions

- CREATE/ADD/MODIFY/CHANGE definitions for the existing DML types: integer
  widths, DECIMAL, DATE/YEAR/TIME/DATETIME/TIMESTAMP, CHAR/VARCHAR,
  BINARY/VARBINARY, TEXT/BLOB families, ENUM and SET. ENUM/SET DML still requires
  source `binlog_row_metadata=FULL` to validate ordered labels.
- Literal and NULL defaults, CURRENT_TIMESTAMP defaults/ON UPDATE, integer
  AUTO_INCREMENT, inline secondary BTREE indexes, ALTER SET/DROP DEFAULT,
  common comma-separated column/index operations, and replacement primary keys.
  Tables must retain a supported nonnullable primary key. ADD NOT NULL requires
  an explicit default or generated expression. Column removal updates the
  surviving index parts. Supported ALGORITHM/LOCK clauses are passed through;
  5.7 decides whether the requested execution method is possible.
- ALTER DATABASE/SCHEMA encoding defaults and DROP DATABASE/SCHEMA, including
  IF EXISTS. DROP retires every cached schema in that database in the same
  SQLite transaction as checkpoint advancement. It does not issue USE against
  a nonexistent database. Partial database exclusions block DROP rather than
  deleting excluded tables.
- STORED and VIRTUAL generated columns with a bounded deterministic expression
  grammar. The manifest retains expression/kind; DML validates the full source
  image but binds only base columns. UPDATE/DELETE before-image checks still
  read the generated columns. Expressions are canonicalized structurally,
  preserving operator grouping, for schema prediction and drift checks.
  INSERT/UPDATE additionally compare computed generated fields with the source
  image before completing their intents. This catches mismatched expressions in
  external snapshots and differences in evaluation; ordinary columns do not
  acquire a post-write read. A mismatch blocks with the written intent pending.
- RANGE/RANGE COLUMNS, LIST/LIST COLUMNS, HASH/LINEAR HASH and KEY/LINEAR KEY
  partition manifests. ADD/DROP/TRUNCATE/REORGANIZE/COALESCE PARTITION,
  repartitioning, REMOVE PARTITIONING and validated EXCHANGE PARTITION are
  ordered DDL barriers. EXCHANGE validates both tables and filter boundaries.
  DROP/TRUNCATE/EXCHANGE effects are not reconstructed from row events.
  An externally prepared target must start with matching partition methods,
  expressions and bounds. TABLE_MAP does not carry the source partition layout;
  subsequent supported DDL maintains the recorded target layout in order.
- CREATE, CREATE OR REPLACE, ALTER and DROP VIEW; CREATE/DROP stored PROCEDURE
  and FUNCTION. Bodies are parsed by MySQL 5.7, with original DEFINER and SQL
  SECURITY. The target connection does not negotiate CLIENT_MULTI_STATEMENTS:
  compound routine bodies are a single CREATE, not a stream of commands.
  Creating a routine does not execute its body. Loadable UDF/SONAME syntax is
  not accepted. Routine execution effects retain the existing single-statement,
  single-included-table DML restriction.

Generated expressions support arithmetic/comparison/boolean operators and a
small explicit list of 5.7 built-ins in `DDLTokens.swift`. Arbitrary expressions,
subqueries, stored-function calls and nondeterministic functions are not accepted.
Subpartitions, arbitrary table options, multi-object DROP/RENAME, cross-schema
RENAME, CREATE TABLE SELECT, functional/descending/invisible indexes and 8.x-only
types/options and cross-family column conversions remain outside this increment.
No engine or collation rewriting is performed. In particular, explicit source
ENGINE=InnoDB still fails the MyISAM
contract; omitted ENGINE permits each server's configured local engine.

## Trigger and event policy

The optional configuration is explicit and defaults to:

```json
"ddlPolicy": { "triggers": "reject", "events": "reject" }
```

Other policy values are rejected. CREATE/ALTER/DROP trigger/event statements
block before target execution, including statements containing DEFINER and even
when table exclusions are configured. They are not silently ignored. Target
tables with existing triggers remain rejected, with TRIGGER privilege required
to prove metadata visibility.

This policy does not prove that the source has no preexisting triggers: row
events do not identify their origin. A preexisting source-only BEFORE trigger
can produce supported final row images. Triggers writing multiple included
tables remain outside the current DML-group contract. Keep the target dedicated
to replication, with its event scheduler disabled and no independent writers.

Routine creation needs CREATE ROUTINE and appropriate DEFINER privileges; view
creation needs CREATE VIEW and access to referenced objects. SHOW VIEW and
routine metadata visibility are needed for operational inspection. Definitions
using unavailable 5.7 syntax fail rather than being translated. Database-wide
exclusions apply to routines; view exclusions use the view's qualified name.

## Temporary tables and session context

Under ROW logging, ordinary temporary-table operations are absent from the
binlog. The applier consumes their effects on permanent tables. A permanent
CREATE LIKE with a temporary template is expanded by MySQL into CREATE TABLE in
the binlog; that resulting supported definition is applied normally. Actual
TEMPORARY DDL reaching this stream remains rejected, including logging-mode
switch scenarios; no cross-group temporary-session state is reconstructed.

DDL restores logged SQL mode, client/connection encoding and available timezone
context, and uses the source event timestamp including microseconds. Legacy
implicit TIMESTAMP defaults are rejected. The DML session is restored after
DDL. Unavailable expression collations fail rather than silently substituting a
5.7 collation.

The pinned `mysql_common` library frames Q_MICROSECONDS as three bytes but tries
to decode four. The adapter now reads that bounded 24-bit field correctly;
fractional source timestamps have regression coverage.

## Reproducible checks

```sh
make test
make ddl-suite ARGS='--slice compatibility --positioning gtid'
make ddl-suite ARGS='--case ddl-compat-partitions --positioning gtid'
make integration-smoke
```

`DDLCompatibilityCases.swift` defines the exact workload and per-step SQL
oracles. The live suite compares source 8.4, native 8.4 replication and our 5.7
target, checks durable checkpoints and pending intents, and retains observations
under `artifacts/ddl-suite/`. Partition cases use InnoDB for the native 8.4
reference because 8.4 cannot partition MyISAM; the external target remains 5.7
MyISAM. Fixture 5.7 is 5.7.42; the additional source-code reference is 5.7.44.
The ENUM/SET type fixture requires the GTID/FULL-metadata profile; the
file-position/MINIMAL-metadata profile runs the other compatibility fixtures.

The new cases are registered as bounded compatibility regressions in the
coverage catalog. Passing them does not mark the broader generated-column,
stored-program, partition, or DDL-family completeness obligations as qualified.

### Validation recorded 2026-10-03

- 276 Swift unit tests and 7 Rust unit tests passed; catalog structure and
  `git diff --check` passed.
- Compatibility fixtures passed in both profiles: 14 file-position cases and
  15 GTID cases, including the common DML prerequisite. Evidence directories:
  `20261003T163148Z-c3cbcd6d-position-autocommit-myisam` and
  `20261003T163501Z-e539cc53-auto-autocommit-myisam` under
  `artifacts/ddl-suite/`.
- The broader GTID regression run passed 124 cases, including the compatibility
  fixtures with the final production code, before encountering an outdated
  missing-template diagnostic assertion left over from single-column keys.
  Evidence: `20261003T165040Z-e85aca36-auto-autocommit-myisam`.
- After correcting that assertion, the entire ordered slice passed all 79
  cases, including missing-template, unsupported-DDL and denied-permission
  failures. Evidence: `20261003T170535Z-176b5242-auto-autocommit-myisam`.
  The two regression runs together have 131 distinct passing case IDs; this
  is not a claim of an uninterrupted full-suite pass. The timeout fixture's
  obsolete error-text assertion was also replaced with a check of structured
  `possiblyExecuted` state.
