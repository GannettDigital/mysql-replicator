# MODIFY COLUMN and secondary indexes

Status: implemented and qualified on the pinned lab profiles, following `6dd6598`.
The scope below is bounded to the declared types and index forms.

The reported failure is a parser rejection at GTID
`71d49b37-bd58-11f1-b656-761022b7811a:23`, after 12 applied transactions. The
operator supplied the exact source statement, which succeeded with no warnings:

```sql
ALTER TABLE demo.explicit_default_engine MODIFY COLUMN name VARCHAR(120);
```

Make this the first regression case, `ddl-modify-demo-varchar-120`. Run the exact
statement against a controlled supported seed table with retained rows, then
INSERT a value longer than the old width, UPDATE it and DELETE it as a representative mixed-stream regression. Include a
seed where `name` was NOT NULL to exercise omitted nullability, and a column
collation different from the table default to exercise omitted encoding. Those
are test baselines, not assumptions about the operator's original table.
This slice does not resolve an existing BLOCKED checkpoint automatically.

## Outcome and boundaries

Replicate column modifications and ordinary secondary-index changes from MySQL
8.4 InnoDB to MySQL 5.7 MyISAM. Compare against the existing MySQL 8.4 native
MyISAM replica and direct 5.7 SQL observations. Execute the original logged SQL,
discover/verify the resulting metadata, then apply subsequent rows correctly.
Preserve engine, charset and collation semantics; no statement rewriting,
index shortening, value repair, automatic retries or error skipping.

The target retains one full, nonnullable integer primary key for row identity.
Secondary indexes must never become an alternative row locator. Existing row
types remain INT/BIGINT, signed or unsigned, VARCHAR and VARBINARY, within the
current width/encoding limits. This is an extension of the supported subset,
not a general ALTER TABLE implementation.

## Accepted syntax

| Operation | Supported scope |
| --- | --- |
| Modify column | `ALTER TABLE t MODIFY [COLUMN] c definition [FIRST\|AFTER other]` |
| Create secondary index | `CREATE [UNIQUE] INDEX name ON t (parts)` and `ALTER TABLE t ADD [UNIQUE] {INDEX\|KEY} name (parts)` |
| Drop secondary index | `DROP INDEX name ON t` and `ALTER TABLE t DROP {INDEX\|KEY} name` |
| Rename secondary index | `ALTER TABLE t RENAME {INDEX\|KEY} old TO new` |
| Replace index definition | One `ALTER TABLE t DROP INDEX old, ADD [UNIQUE] INDEX name (parts)`; allow reuse of the dropped name |

Index parts are existing columns, singly or in combination, with optional
VARCHAR/VARBINARY prefixes. Support ordinary BTREE indexes, explicit names and
ascending/default ordering; qualify optional `USING BTREE` spellings. Reject
unsupported index types/options before executing SQL. Index replacement changes
parts, order, prefixes or uniqueness through the listed DROP/ADD form. Keep it
one source group, one DDL intent and one target statement; never split it into
separate autocommitted operations. General mixed/multiple ALTER actions are deferred.

MODIFY covers widening and data-preserving narrowing within integer or string
families, signedness, nullability and placement. Include widening the existing
integer primary-key column while keeping its identity and valid key shape.
Do not add cross-family text/numeric conversion in this slice. Explicit supported
utf8mb4 collations and inherited defaults follow the existing query-context path.
Retain the current omitted/NULL-only default grammar; non-NULL literal defaults,
expressions, AUTO_INCREMENT, comments and generated columns are separate work.

MySQL treats MODIFY as a new column definition: omitted non-index attributes are
not copied from the old definition. The implementation must resolve the new
definition rather than patching only its type/width. Keep existing index membership
unless the statement actually changes it. See the
[MySQL ALTER TABLE rules](https://dev.mysql.com/doc/refman/8.4/en/alter-table.html).

Prefixes require both a declared length and its interpretation: character counts
for nonbinary strings, byte counts for binary strings. Byte limits depend on the
engine and encoding. Use these distinctions in prediction and native boundary
fixtures; let server observations establish exact failures and warnings. See
[MySQL CREATE INDEX](https://dev.mysql.com/doc/refman/8.4/en/create-index.html).

Deferred: primary-key add/drop/replacement or composite primary keys; inline
index declarations in CREATE TABLE; unnamed indexes; FULLTEXT/SPATIAL, functional,
descending and invisible indexes; foreign/check constraints; DISABLE/ENABLE KEYS;
arbitrary index options; CHANGE/RENAME COLUMN; general ALGORITHM/LOCK clauses.
Record these as explicit gaps, not silently ignored tokens. Supported existing
indexes must survive CREATE LIKE, table RENAME and TRUNCATE. For DROP COLUMN,
either predict its affected index parts according to qualified native behavior
or reject that combination before mutation; never discover this incompatibility
only after executing the DDL.

## Implementation sequence

1. **Reference cases and catalog contracts.** Split bounded scenarios out of
   `column.modify`, `index.keys` and `index.byte-limits`, retaining the broader
   backlog rows. Register descriptive cases with source locations, including
   native/source-only outcomes and Swift rejections. Capture actual Query SQL:
   do not assume CREATE/DROP INDEX is logged with the spelling the client sent.
2. **Index metadata and state compatibility.** Extend `ApplyTable` with bounded,
   ordered secondary-index metadata: name, uniqueness, type and ordered parts
   (column, optional prefix length and direction). Discover it using 5.7-compatible
   `information_schema.STATISTICS` fields, including `NON_UNIQUE`, `SEQ_IN_INDEX`,
   `SUB_PART`, `INDEX_TYPE` and `COLLATION`. Compare structural properties, not
   estimates such as CARDINALITY or engine-private SHOW CREATE formatting.
   Replace the primary-index-only rejection in `TargetSession.verifySchema` with
   full supported-index validation. Preserve indexes in all table-model copies,
   LIKE templates, cached schemas and schema history. Require the needed INDEX
   privilege in fixtures and document it for operators.
3. **MODIFY planning and execution.** Add a typed MODIFY action to `DDL.swift`.
   Build its full predicted column definition and placement using historical
   table defaults and query context. Check affected indexes, existing key identity
   and model limits. Use the existing intent → unchanged SQL → metadata verification
   → schema publication → checkpoint ordering. Invalidate the table cache so the
   next TABLE_MAP/row event uses the new column order, type, signedness and width.
4. **Index planning and execution.** Add typed create/drop/rename/replacement
   actions and their accepted aliases. Validate the complete statement and final
   index model before target mutation. An index-only DDL still creates a schema
   version and increments DDL/transaction counts, with zero applied DML rows.
   Verify discovered after-metadata before marking it DONE; no fallback index SQL.
5. **Qualification and coverage report.** Run unit/native/Swift suites below;
   import fresh evidence for both profiles and publish before/after obligations
   and remaining gaps. Update supported syntax, configuration examples and the
   demo workbook only after the behavior is qualified.

Existing format-4 schema JSON contains only a primary key because the old runtime
rejects secondary indexes. Decode a missing secondary-index collection as empty,
and test clean STOPPED reopening with old fixtures. Do not discard new metadata
on resume or allow an older binary to silently treat a new indexed schema as an
old schema. Write extended state as format 5; the existing format-4 reader must
refuse it. Implement an atomic, validated format-4 → format-5 upgrade for clean
STOPPED state under the writer lock, preserving baseline, progress, counters and
history. Reject unsupported/corrupt old state before mutation. Migration of
BLOCKED/uncertain work is outside this slice. Test this compatibility gate before
enabling index DDL.

Ordinary target queries retain a 10-second deadline. `ddlTimeoutSeconds` separately
bounds DDL execution, defaulting to 300 seconds with an accepted range of 1–86400.
The configuration example includes this optional top-level setting. Expiry/disconnect after dispatch
must keep the pending intent and BLOCKED state, with an uncertain-outcome diagnostic.
Never retry or declare the target unchanged on timeout. Add a focused timeout test;
large-instance performance/operational qualification remains separate.

## Required named scenarios

Every positive case checks metadata and retained rows. Following DML is selected
for the changed behavior: a single row probe for width/encoding/lifecycle changes,
key-changing probes for indexes, and representative full INSERT/UPDATE/DELETE
sequences for mixed-stream handling. Index rename/drop use structural assertions
without redundant DML. The catalog binds following-DML evidence only to cases
that execute it; there is no blanket three-operation requirement. Test both file-position/MINIMAL row metadata and
GTID/FULL row metadata, with FULL row images in both.

| Qualification group | Required observations |
| --- | --- |
| `ddl-modify-width` | VARCHAR/VARBINARY widen; narrow with fitting data; binary/UTF-8/NUL/trailing-space values survive; later values exercise new bounds |
| `ddl-modify-integer` | INT→BIGINT including the existing PK; fitting reverse conversion; signed/unsigned transitions; later values cross the old type boundary where allowed |
| `ddl-modify-definition` | NULL↔NOT NULL on suitable data; omitted attributes use native new-definition semantics; explicit versus inherited supported encoding |
| `ddl-modify-placement` | FIRST/AFTER changes row ordinals; source table-map decoding and target bindings follow the new order |
| `ddl-index-create` | Standalone and ALTER aliases; ordinary/unique, single/composite and prefix indexes; prepopulated tables and following DML |
| `ddl-index-change` | Rename/drop aliases and single-statement DROP+ADD replacement, including changed order/prefix/uniqueness and reuse of the name |
| `ddl-index-inheritance` | LIKE from an indexed template, table rename, TRUNCATE and subsequent DML preserve the expected index definitions |
| `ddl-modify-indexed-column` | Widen an indexed column; retain full/prefix index semantics; compare source/native/5.7 metadata and byte limits |
| `ddl-index-unique-dml` | Unique-index enforcement, nullable unique parts, prefix/collation equality and successful key changes; replica-only conflicts stop subsequent work |
| `ddl-modify-index-failures` | Missing columns/indexes, name collisions, invalid prefixes, unsafe narrowing/null conversion, duplicate unique data and engine byte limits |
| `ddl-index-resume` | Clean stop/reopen retains extended metadata; detect external index drift; old-state compatibility and older-format refusal gates |

Separate failures that prevent the source statement from entering the binlog
from replication failures. Source rejection is a native observation, never a
Swift fail-stop pass. Include valid-on-source statements that fail on MyISAM,
plus deliberately prepared replica-only duplicate/null/conflict fixtures when
needed to exercise target execution errors. Record the native 8.4 outcome and
the direct 5.7 outcome independently; do not claim cross-version equivalence
when they differ. Observe warnings and any target effects, especially for
nontransactional indexes, instead of assuming failure rolled everything back.

For every target failure, assert BLOCKED, the failed GTID and diagnostic, an
unchanged completed checkpoint, and a following marker not applied. Parser/model
rejections occur before write intents; target execution failures retain their
intents. The existing `skip` command remains ineligible for any group with an
intent. This slice does not add retry/repair of a previously blocked transaction.

## Reference material and evidence

Use the existing ignored `.upstream/mysql-server` checkout at
`0896fcd61dec11a0904166911a0126f59daaa1bf` as the source/test reference:

- `mysql-test/t/alter_table.test` and its result: the paired InnoDB/MyISAM MODIFY
  cases around lines 1421–1440, WL#6555 RENAME KEY/INDEX cases around 1565 onward,
  and DROP/ADD replacement cases around 1970 onward. Import the relevant setup,
  SQL mode and expected warnings, not isolated statements without prerequisites.
- `mysql-test/t/key.test`, `key_myisam.test` and associated results: review and
  select exact uniqueness/prefix/engine cases before adding reference hashes.
- `sql/sql_yacc.yy` and `sql/sql_table.cc`, particularly
  `mysql_prepare_alter_table` and `prepare_key`, for full definition replacement,
  retained keys, key-part preparation and engine validation.

Use the pinned running 5.7 server as the version-specific behavior oracle. The
public `/refman/5.7/en/alter-table.html` URL currently redirects to a newer manual;
that page cannot establish 5.7 compatibility. Independently authored adaptations
must state which upstream section informed them and what was intentionally omitted.

Acceptance commands, using existing SwiftPM/Make automation and Docker caches:

```sh
swift test --filter 'ReplicatorApplyTests|DDLCoverageTests'
make ddl-catalog-check
make ddl-catalog-upstream-check
make native-ddl-suite
make ddl-suite
make dml-suite
make demo-suite
make ddl-catalog-report ARGS='--format json --evidence artifacts/ddl-suite/POSITION_RUN/coverage-evidence.json --evidence artifacts/ddl-suite/GTID_RUN/coverage-evidence.json'
```

Use the actual evidence paths printed by the new run. Save the pre-implementation
report and compare newly measured obligations after implementation. Require
index/column metadata, retained and following rows, normalized binlog effects,
schema-history/cache changes and GTID/position boundaries; an aggregate suite
pass is insufficient. Preserve all existing tests and intentional rejections.
Do not mark the broad backlog features complete, or reuse stale evidence after
changing schema/decoder/harness code.

Completion means the accepted syntax and named positive/failure cases pass both
profiles, old-state handling is explicit and tested, the catalog reports increased
measured coverage, and the workbook has a prepared MODIFY → index change → DML
sequence. Dump/load, automatic recovery and broader DDL/type support remain separate.

## Test granularity

The pinned upstream `alter_table.test` checks RENAME KEY/INDEX with SHOW CREATE
TABLE around lines 1576–1580, and MODIFY variants around lines 1414–1440 without
a full INSERT/UPDATE/DELETE loop after each statement. Follow that operation-specific
style. Add Swift-specific row probes where decoder interpretation, schema cache
refresh or key enforcement needs testing. Keep full mixed DDL/DML flows in selected
regressions and the demo, not in every syntax variant.

The implemented fixture matrix has 22 positive cases: three metadata-only index
rename/drop cases, eleven single-INSERT probes, three INSERT/UPDATE key probes,
and five representative full INSERT/UPDATE/DELETE flows (32 DML statements total).
Each case keeps exact metadata, retained-row, binlog, checkpoint and schema-history
checks. Following-DML assertions are absent from metadata-only cases. The existing
DML suite and ordered DDL regression stream remain intact.

Operational details: grant INDEX on intended databases; dropping an indexed
column and narrowing below a retained prefix length fail before a write intent.
This increment introduced SQLite format 5; clean STOPPED format-4 history upgrades
atomically after validation. The current runtime writes format 6 for binary relay
metadata and preserves old relay prefixes during upgrade; see
[relay compatibility](PERFORMANCE_BENCHMARK.md#binary-metadata-and-cached-timestamps). BLOCKED/uncertain old state requires its original runtime's
resolution path before upgrade. No engine, charset or index definition is rewritten.

## Qualification results (2026-10-01)

135 Swift tests passed. Each Swift DDL profile passed 114 cases; native profiles
passed 48 cases each. Both DML profiles and all 10 demo cases passed,
including the prepared workbook SQL. The upstream pin/hash/locator check passed
for 30 references; 12 dependency reviews remain open.

Fresh catalog evidence records **68/730** passing assertion/profile obligations,
28 partial combinations and zero fully verified combinations, compared with the
previous measured 48/690, 24 and zero. The [comparison and reproduction commands](../artifacts/modify-index-20261001/README.md)
record exact evidence paths and distinguish targeted DML from structural checks.
Artifacts are local and ignored by Git.

## Incremental reruns

`make ddl-suite ARGS='--slice modify-index --positioning gtid'` runs this slice
without the ordered/database/filter workloads. For the exact original regression,
use `make ddl-suite ARGS='--case ddl-modify-demo-varchar-120 --positioning gtid'`.
Each includes the shared basic DML prerequisite. `--list` shows all independent
case IDs and source locations; see [incremental checks](INCREMENTAL_CHECKS.md).
