# DDL engine and charset foundation

This is the first implementation slice of [DDL completeness](DDL_COMPLETENESS.md),
after checkpoint `3618fd4`. It does not complete the broader DDL/type matrix or add
restart/recovery. The original [prototype results](DDL_APPLY.md) remain historical.

## Implemented behavior

The applier fully parses the bounded grammar, predicts and validates its resulting
schema, records a DDL intent, and executes the original source query. It no longer
adds ENGINE=MyISAM, adds CHARACTER SET utf8mb4 to columns, or substitutes a legacy
collation for utf8mb4_0900_ai_ci. The journal retains the actual source SQL, including
MySQL's generated DROP suffix. Unknown syntax still stops before target DDL.

Omitted ENGINE uses the target's configured default, checked as MyISAM on the apply
session. Explicit MyISAM is preserved. Explicit InnoDB is rejected before mutation
as outside the MyISAM-only contract; this is not represented as a native failure on
an unrestricted server. The separate native suite proves both unrestricted InnoDB
creation and error 3161 under `disabled_storage_engines=InnoDB` with strict engine
substitution behavior.

The pinned 8.4.8 and 5.7.42 fixtures reject bare `ENGINE=DEFAULT` with error 1064.
Quoted `ENGINE='DEFAULT'` parses, but selected InnoDB when the temporary engine
remained InnoDB despite a MyISAM normal default. With **both**
`default_storage_engine=MyISAM` and `default_tmp_storage_engine=MyISAM` on each target,
quoted DEFAULT selects MyISAM. The applier checks this additional session setting
for that syntax. Prefer omission; do not assume DEFAULT spellings or behavior from
another version. The local `ha_resolve_by_name` implementation and retained native
binlogs are the references for this observed behavior.

The supported lifecycle includes CREATE, nullable non-key ADD (including FIRST/
AFTER), non-key DROP COLUMN, same-database single-table RENAME, DROP TABLE and now
TRUNCATE. TRUNCATE is journaled as a DDL group, verified empty, and followed by a
new schema version before subsequent rows. No automatic retry is added.

## Charset/default handling

The Rust adapter now exposes an additive ABI 4 `rc_query_context_decode` function,
reusing upstream status-variable parsing and checking full consumption/duplicates.
Swift receives typed SQL mode and charset/collation identifiers. Raw event bytes
remain available; unknown, truncated or missing required query context blocks DDL.
The existing event JSON schema remains 3; status bytes are still emitted raw there.

The parser retains omitted charset/collation clauses and explicit declarations.
Preparation resolves them through target charset/collation catalogs and database/
table defaults at the event's boundary. COLLATE alone identifies its charset.
Table creation uses the owning schema's default, not the session's current schema.
Discovered schema records now include the table default charset/collation and the
resolved column charset. These are internal state, never configuration manifests.
After execution, actual metadata must equal the prediction; later drift is rejected.

For a charset-only utf8mb4 declaration, the logged default collation must be both
available and the same as the target's applicable default. MySQL 5.7 lacks the 8.4
session default-collation variable; incompatible semantics stop rather than rewrite
SQL or silently use a different collation. Explicit unsupported 0900 collations also
stop. Existing externally provisioned DML-only collation differences remain the
separate narrow contract documented in [schema discovery](SCHEMA_DISCOVERY_AND_RETENTION.md).

The accepted query grammar is still ASCII, without expressions, text defaults,
stored programs, timestamp columns or database DDL. It requires a known
ASCII-compatible client charset and rejects escaped/control bytes in identifiers.
It restores source SQL mode for DDL and the fixed DML transport settings afterward.
Other decoded session variables do not affect this restricted grammar; this is not
general query-context replay. Connection encoding is distinct from column encoding.
Arbitrary encodings, non-ASCII queries and additional session-dependent syntax remain
unqualified and must be added with their own semantic and byte-preservation tests.

The row codec/SQL binding subset remains INT/BIGINT, VARBINARY and the previously
qualified utf8mb4 VARCHAR collations, with one integer primary key. For example,
latin1 DDL is valid natively but is blocked before execution by this applier's current
row-type/charset support. Removing hard-coded declarations does not claim general
charset support. The broad charset/index/key/type backlog remains in the main plan.

## Reproducible qualification

Use SwiftPM/Make, with the existing persistent Docker compiler caches:

```sh
make test
make native-ddl-suite
make ddl-suite
make dml-suite ARGS=--skip-build
```

`native-ddl-suite` runs disposable source 8.4, native 8.4 and ordinary-SQL 5.7 targets
under unrestricted and restricted engine profiles. It records a matrix of SQL,
errors/status and actual schemas, plus raw binlogs and mysqlbinlog traces. This is
native/default research, not a Swift-apply test. Its restricted profile also sets
the temporary engine default; the unrestricted profile retains InnoDB there as a
control. Explicit InnoDB failure is last and stops native apply.

`ddl-suite` exercises Swift in both file/position + MINIMAL and GTID + FULL modes.
Its 26 interleaved groups include omitted and quoted-default engines, inherited
VARCHAR charset, explicit table defaults, COLLATE-only columns, rename/recreate,
TRUNCATE, compatible charset-only defaults from query context, and following INSERT/UPDATE/DELETE. It checks both replicas actually use
MyISAM, exact schemas/values, unchanged CREATE SQL in SQLite, ordered binlog operation
kinds, source progress and 12 DDL/14 row counters. The negative cases cover explicit
InnoDB, unsupported collation, incompatible charset-only defaults, unsupported
latin1 row encoding, unsupported type and denied CREATE. Rejections assert stopped
progress; engine/charset cases also assert that later DDL is not applied.

Case output includes a stable ID, a description of the expected behavior, and the
repository-relative file and line where that case is defined. For example, a case
is reported as `passed [add-column-first] ADD nullable VARCHAR FIRST inherits the
table charset and collation (Sources/ReplicatorLabCore/DMLQualification.swift:<line>)`.
The source line is captured automatically; search for the case ID if reviewing a
run from an older revision. Cases emit `starting` before work and `passed` only after
all their assertions. A failure retains the same identity and the failing assertion.

Each run writes incremental `cases.json` records (`id`, `name`, `source_file`,
`source_line`, `status`, optional `parent_id` and `error`), also included in final
`result.json` (`cases` for DDL/DML, `case_results` alongside the native observation
matrix). DDL row snapshots use `<server>-ddl-<case-id>.tsv` filenames. These reporting
changes do not alter the SQL workloads or replication assertions.

Reporting follow-up after `cdcaead`: `swift test --filter ReplicatorLabTests`
passed all 17 harness tests, including three reporting tests. Both native DDL
profiles and both position/GTID modes of `ddl-suite` and `dml-suite` passed with
cleanup. The Swift suites used `ARGS=--skip-build` because the replication runtime
was unchanged. All 94 saved case records matched console output and pointed to
their actual definition lines. Logs and the run index are in
`artifacts/case-reporting-validation/`.

Validation completed on 2026-09-30: 82 Swift tests and 2 Rust tests passed;
the 82 Swift tests also passed with AddressSanitizer (the Rust archive is not
instrumented). Both native engine profiles, both Swift DDL modes and both DML
regression modes passed, including fixture cleanup. The DDL/DML runs used the same
immutable runtime image. Evidence is retained under `artifacts/`:

| Suite/profile | Run directory |
| --- | --- |
| Native, unrestricted engines | `native-ddl-suite/20260930T181729Z-07db70c9-auto-autocommit-myisam` |
| Native, InnoDB disabled | `native-ddl-suite/20260930T181856Z-ec8720c6-auto-autocommit-myisam` |
| DDL, file/position | `ddl-suite/20260930T181804Z-bf065044-position-autocommit-myisam` |
| DDL, GTID | `ddl-suite/20260930T182315Z-38fbde98-auto-autocommit-myisam` |
| DML, file/position | `dml-suite/20260930T182007Z-f75c3a46-position-autocommit-myisam` |
| DML, GTID | `dml-suite/20260930T182106Z-af4a6b36-auto-autocommit-myisam` |

Build/test logs and published-source hashes are retained in
`artifacts/ddl-defaults-validation/`.
Further DDL families, richer charsets/types/indexes, historical database-default DDL,
long-running ALTER policy and full query-context replay remain next work. First-start
adoption and SQLite restart/operator resolution follow those correctness gates.
