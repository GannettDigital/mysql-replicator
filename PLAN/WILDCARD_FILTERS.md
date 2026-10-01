# Wildcard table exclusions

The optional top-level apply configuration field `replicateWildIgnoreTable`
emulates MySQL's wildcard ignore rule for the supported replication flow:

```json
{
  "replicateWildIgnoreTable": ["temp.%", "scratch.%", "poc.ignore\\_%"]
}
```

Merge this field into the existing apply configuration; it is not a complete
config file. The example config defaults to an empty array (no exclusions).
Rules match the full `database.table` name, regardless of the current `USE`
database for row events or qualified DDL. `%` matches zero or more characters,
`_` matches one character, and `\` escapes the next character. In JSON, `\\_`
represents a literal underscore. Names are case-sensitive; configured filtering
requires `lower_case_table_names=0` on both source and target. Patterns use ASCII,
are limited to 128 entries of at most 512 bytes, and require nonempty database
and table components separated by one dot.

`temp.%` also suppresses database-level `CREATE DATABASE/SCHEMA`, `ALTER DATABASE`
and `DROP DATABASE` for `temp`. A table-specific rule such as `temp.stage_%` does
not suppress creation of its owning database. The native implementation tests
`database.` against these patterns for database-level statements.

Row exclusions are decided from checked TABLE_MAP identity before consulting the
target or interpreting column values. Excluded tables can be absent on the
replica and use types the applier cannot otherwise apply (for example DECIMAL,
JSON and DATETIME). Framing, CRC, table-map references, row flags, transaction
boundaries and resource limits remain enforced. Excluded row payloads are opaque;
they are not certified as valid decoded values. Included events keep the existing
schema/type/full-image checks. Mixed included/excluded row events apply only the
included effects, subject to the existing single-statement/single-target-table
applier contract. No SQL is rewritten.

DDL scope is classified separately from supported column syntax. Excluded
CREATE/ALTER/DROP/TRUNCATE TABLE, standalone index operations, simple view DDL,
RENAME TABLE and database DDL need no target schema or DDL intent. CREATE LIKE
uses the destination for filtering; its template is a read dependency. DDL
renaming/mutating both included and excluded objects stops for explicit resolution.
Unknown SQL, executable comments and ambiguous quoting stop rather than silently
skip an object whose identity has not been established. Full MySQL SQL grammar,
DEFINER/view modifiers, stored routines, grants and trigger statements are not
added by this slice. Table filters are not a general database-object exclusion
policy. Unsupported included DDL still blocks as before.

At each complete source group the normal durable checkpoint includes the GTID and
end position even if every effect was filtered. No row/DDL write intent or schema
cache entry is created for excluded work. `transactionsApplied` is the processed
source-group count (includes filtered groups); `rowsApplied` and `ddlApplied`
count target operations. Existing timestamped history retention and SQLite/relay
limits remain in force. Filtering does not remove events from the local relay.

On a clean stop, resume with the same config using `run --config apply.json`.
Saved GTIDs/position take precedence over the config baseline, including ignored
GTIDs. Patterns are read on each start, so operators can change them while stopped
for subsequent events. Removing an exclusion does **not** backfill earlier ignored
events or create missing historical schemas/data; prepare the target externally
before including those tables. A schema change while excluded can require a new
externally established baseline/state; saved-schema validation still protects
re-included tables. Saved excluded schemas are not queried during
resume preflight. The existing BLOCKED-state resolution requirements still apply.
Use the current binary when relying on this config field; older binaries do not
implement wildcard exclusions.

## Validation and reference

```sh
make ddl-suite ARGS='--slice filters'
# Fast single-profile development rerun:
make ddl-suite ARGS='--slice filters --positioning gtid --skip-build'
```

The independent slice configures the same ignore patterns on the native 8.4
replica and Swift, and compares included data and emitted binlog row effects.
It covers excluded schema/table creation, unsupported types and explicit InnoDB,
ALTER/index/rename/drop, escaped `_`, wildcard schema names, mixed row updates,
fully ignored multi-statement groups, an included near-match table name,
fail-stop for unsupported included DDL, GTID/position/counter progression,
no target intents for ignored work and clean
resume after ignored groups. Both positioning/metadata profiles run by default.
The common basic DML comparison runs first. Unit tests cover pattern edge cases,
qualified/default database names, boundary-crossing DDL rejection, opaque row
handling, checksum failure and checkpoint persistence. These tests do not claim
full replication-filter compatibility across arbitrary SQL.

Reference: [MySQL 8.4 replica options, replicate-wild-ignore-table](https://dev.mysql.com/doc/refman/8.4/en/replication-options-replica.html#option_mysqld_replicate-wild-ignore-table).
Local pinned MySQL source: `.upstream/mysql-server/sql/rpl_filter.cc`,
`Rpl_filter::tables_ok` and `db_ok_with_wild_table`; test inspiration:
`.upstream/mysql-server/mysql-test/suite/rpl/t/rpl_filter_wild_tables_dynamic.test`.
These are reference semantics, not an imported passing upstream suite.

Validation on 2026-10-01: both file-position/MINIMAL and GTID/FULL profiles passed
all four named cases, including the basic prerequisite. The filter workload
processed 25 groups with three row mutations and two included DDL operations;
resume processed one more row exactly once. Unsupported included DDL retained
BLOCKED state and stopped its following marker. No discarded DDL was credited
as grammar coverage. See `artifacts/incremental-filters-20261001/summary.json`.
