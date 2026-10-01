# DDL coverage catalog implementation

Definition, 2026-09-30, committed as `5270352`. **Steps 1–2 are implemented:**
versioned JSON records/schemas, shared executable case registry, offline check and
Markdown/JSON report commands, pinned local upstream checking and candidate scanning. See [catalog usage and limits](../tests/DDLCoverage/README.md).
The catalog contains 61 scenarios and now maps 113 DDL/native case declarations,
including explicitly classified baseline/setup/cleanup cases. All family inventories remain
partial. Without selected evidence, qualifications remain unverified. The first
Step 3 slice imports checksummed, fingerprinted schema/data assertions for rename
and populated/empty TRUNCATE, conditional CREATE/DROP, CREATE LIKE and database creation. Selected lifecycle sections/results and prerequisites
have been reviewed; contrast-only references and whole-file/transitive review gaps
remain explicit. Step 3 is partially implemented: boundary/binlog/history and
query-context qualification, export and completeness verification remain pending.
Step 4 remains pending; historical integration passes have not been promoted into
assertion-level catalog evidence.
The conditional/LIKE slice extends the bounded production DDL grammar; recovery policy is unchanged.

## What defines the checklist

Use three inputs together:

1. **Server grammar and execution code:** enumerate statement forms, clauses,
   affected objects and relevant session context. Parsing a form does not establish
   that it works with MyISAM, MySQL 5.7 or our row decoder.
2. **MySQL Test Run (MTR) scenarios:** inspect tests, expected results, included
   files, engine wrappers, `.opt` settings and prerequisites. Extract behaviors,
   including failure/partial-effect cases. One upstream file can contain many
   scenarios; multiple files can exercise the same behavior.
3. **Our native/Swift harness:** establish outcomes for the actual source/native/
   target versions, engines and settings. Upstream expectations guide these tests;
   they do not automatically become expected outcomes for our topology.

The initial upstream is the existing clean, ignored MySQL 8.4.8 checkout at
`.upstream/mysql-server`, commit `0896fcd61dec11a0904166911a0126f59daaa1bf`.
A later 5.7 source reference must have its own explicit pin. Research source pins
and the server versions/image digests actually tested are separate fields.

Start the candidate inventory with `mysql-test/t`, `mysql-test/suite/rpl`,
`mysql-test/common/rpl` and `mysql-test/common/binlog`, following their includes.
Record additional suites when discovered; do not claim this root list exhausts
all MySQL tests. Reconcile the inventory against families A–F in
[DDL completeness](DDL_COMPLETENESS.md#native-first-qualification-matrix).
Each family's inventory starts `partial`; expansion and exclusions remain visible.

Filename matching only discovers candidates. For example,
`mysql-test/t/create_if_not_exists.test` covers routines/functions/triggers at this
pin. Table conditional-create and LIKE scenarios are in `mysql-test/t/create.test`.
Do not label a filename match as a reviewed table scenario.

## Repository layout and ownership

Catalog layout (evidence schema and evidence matching remain for step 3):

| Path | Purpose |
| --- | --- |
| `tests/DDLCoverage/catalog.json` | Canonical families, feature inventory and scenario contracts |
| `tests/DDLCoverage/upstream.json` | Repository pins and reviewed test/code references, including dependencies |
| `tests/DDLCoverage/profiles.json` | Explicit required server/settings combinations |
| `tests/DDLCoverage/schema/` | Version 1 JSON Schemas for these files and qualification evidence |
| `tests/DDLCoverage/README.md` | Authoring workflow, status meanings and commands |
| `Sources/ReplicatorLabCore/DDLCoverage.swift` | Swift models, semantic validation, evidence matching and report generation |
| `tests/ReplicatorLabTests/DDLCoverageTests.swift` | Validator, evidence and reporting tests |

JSON is the source of truth. Generate the readable coverage table from it;
maintain explanations and reviewed exclusions by hand. Use SwiftPM and Make for
all permanent automation. Raw binlogs, SQLite copies and run logs stay in ignored
`artifacts/`; upstream source stays in ignored `.upstream/`. Reference upstream
material by pinned path/section and record adaptation provenance; copying a test
or fixture requires its license/notice review.

## Data contract

Each JSON document has `schema_version: 1`. Reject unsupported schema versions and
unknown fields so misspelled expectations cannot silently disappear.

**Families and features.** A family has a stable ID, name, inventory review state
(`partial` or `reviewed_for_declared_scope`), scan scope, and outstanding questions.
A feature identifies a grammar form/clause and links its scenario IDs. A discovered
candidate is `pending_review`, `mapped` to scenarios, or `excluded` with a reason.
Maintain candidates separately from test results: an unreviewed test file is an
inventory gap, not a passing or failing scenario.

**Upstream references.** Each reference has an ID, repository/revision, path,
kind (`test`, `result`, `include`, `options`, `grammar`, `implementation`), file
SHA-256, and a locator: symbol or section anchor plus line range at the pinned
revision. Record direct dependencies and whether their relevant transitive setup
has been reviewed; unresolved conditional/dynamic includes stay explicit.
Test references link their expected-result variants where available. A scenario
labels references `adapted_from`, `related_reference` or `semantic_reference` and
states changes to engines, schema, transaction shape and expected behavior.
Existing independently written fixtures must not be retroactively called ports.

**Scenarios.** Each entry contains:

| Field | Required meaning |
| --- | --- |
| `id`, `name`, `family`, `feature` | Stable semantic identity and descriptive behavior; IDs survive source-line changes |
| `scope`, `scope_reason` | `in_scope` or `excluded`; exclusions always have a reason and review reference |
| `implementation` | `missing`, `partial` or `implemented`; describes code, not qualification |
| `intent` | `apply`, `reject` or `observe`; rejection coverage never counts as apply support |
| `prerequisites`, `operation`, `following_workload` | Schema/data/session setup, SQL shape, subsequent operations and affected objects |
| `upstream_refs` | Exact reference IDs, relationship and adaptation notes; unresolved provenance is explicit |
| `required_profiles` | Concrete profile IDs, not an inferred Cartesian product |
| `expectations` | Per-profile source acceptance/logging, native apply, direct 5.7 SQL and Swift outcomes |
| `required_assertions` | Stable assertion IDs for semantics and progress, with justified non-applicable checks |
| `bindings` | Suite and case IDs, execution order/dependencies, role, profiles and supplied assertions |
| `gaps` | Missing implementation, reference research, assertions or profile coverage |

Split scenarios when prerequisites or expected effects differ: existing versus
missing table, same versus different definition, populated versus empty, and
unrestricted versus disabled engines are different obligations. A scenario can
require several named cases in an ordered workload. Every step is not necessarily
an independently executable test.

Store expected outcomes separately for `source`, `native84`, `target57_sql` and
`swift57`. Outcome values are `success`, `rejection`, `not_applicable` or `unknown`;
success additionally identifies `changed` or `no_op`, and source logging identifies
`event`, `no_event` or `unknown`. Rejections state SQL error number/SQLSTATE where
available, or Swift diagnostic category. Capture warnings and partial effects.
`unknown` is a research gap. `not_applicable` requires a reason. Direct SQL on 5.7
is capability evidence, not proof of Swift replication or native 5.7 replication.

**Profiles.** Resolve exact versions/image digests and record the effective server
and session settings used: source/native/target engines (normal and temporary
defaults), disabled engines, SQL mode, charset/collations, GTID settings,
positioning, binlog format, row image, row metadata and query-event context.
Source ON/ON, targets OFF_PERMISSIVE/WARN and Swift `GTID_NEXT=AUTOMATIC` remain the
existing contract. Connection/query encoding and column encoding are separate.

Initially model the combinations we actually run:

- Swift positional start with MINIMAL **row metadata**, FULL row images.
- Swift GTID start with FULL row metadata and FULL row images.
- Native unrestricted-engine observation profile.
- Native restricted-engine observation profile, including temporary-engine defaults.

Do not report coverage of MINIMAL row images or all positioning/metadata combinations
from those two Swift profiles. Record actual settings instead of assuming defaults;
missing settings in historical artifacts remain unknown.

## Example mapping and the initial inventory

This abbreviated scenario illustrates the design. The complete implemented record
is in `tests/DDLCoverage/catalog.json`; it includes all required fields:

```json
{
  "id": "ddl.table.truncate.populated",
  "name": "TRUNCATE a populated table, retain its schema, then apply DML",
  "family": "B",
  "feature": "table.truncate",
  "scope": "in_scope",
  "implementation": "implemented",
  "intent": "apply",
  "upstream_refs": [
    {"id": "mysql84.truncate.basic", "relationship": "related_reference"}
  ],
  "required_profiles": ["swift.position.metadata-minimal", "swift.gtid.metadata-full"],
  "bindings": [
    {
      "suite": "ddl-suite",
      "role": "swift_apply_with_native_reference",
      "case_ids": ["truncate-nonempty-table", "insert-after-truncate", "update-binary-null", "delete-unsigned-maximum"],
      "completion_case_id": "ddl"
    }
  ],
  "gaps": ["Import current evidence as historical; verify the complete assertion contract before qualifying this scenario."]
}
```

The `ddl` parent contains group-level schema-history, counter and binlog assertions.
Its pass must not automatically satisfy every child's assertion requirements:
bind each assertion to the relevant operation/boundary. A shared group check
satisfies only the specifically documented group obligation.

Seed the catalog with the existing native and Swift DDL cases, preserving IDs,
plus the following lifecycle obligations. This is an initial inventory, not a
claim that the upstream suite has been exhaustively classified:

| Feature | Separate scenarios to inventory | Initial reference / existing binding |
| --- | --- | --- |
| Engine selection | Omitted, quoted default, bare default syntax, explicit allowed/disabled engine | `disabled_storage_engines.test`; grammar/engine resolver; native `omitted`, `quoted_default`, `bare_default`, `explicit`; Swift `create-local-engine`, `recreate-default-engine`, `explicit_innodb` |
| Conditional CREATE | Absent table; existing matching table; existing different definition; warning/logging and following DML | `create.test` existing-table case around lines 16–20; differing-definition and absent-table cases require explicit references or documented derived scenarios |
| Conditional DROP | Present table; missing table; warnings; multi-object partial effects separately | `drop.test` error-message section around lines 226–238 |
| CREATE LIKE | Same/cross schema; existing destination; missing source/schema; populated template produces no copied rows; inherited engine/defaults/indexes | `create.test`, section `Test for CREATE TABLE .. LIKE ..` around lines 288–333 |
| Rename | RENAME and ALTER spelling; same/cross schema; destination exists; source missing; chains/multiple objects separately | `rename.test` opening section; `rename_myisam.test` lock/cross-schema cases; `suite/rpl/t/rpl_alter.test`; existing Swift `rename-table` |
| TRUNCATE | Populated, empty, missing, following rows; AUTO_INCREMENT and temporary-table variants separately | `truncate.test` opening cases; existing Swift `truncate-nonempty-table` and following DML |
| Columns and defaults | Existing ADD/DROP coverage; MODIFY/CHANGE/RENAME, placement, nullability/defaults, multi-clause changes and conversions | Family C inventory, starting with `alter_table.test` and replication equivalents; map existing ADD/DROP case IDs |
| Keys/indexes | Primary, unique, secondary, composite/prefix, duplicate data and byte-limit boundaries | Family D inventory; record decoder/key-shape gaps separately from SQL acceptance |
| Database/encoding | Database DDL and defaults, inherited/explicit encodings, conversions and query context | Family E inventory; map current charset/default cases and preserve unsupported latin1/0900 distinctions |
| Other DDL | Generated columns, constraints, partitions, options, views, programs, triggers, events, CREATE SELECT | Family F remains visible; review applicability and record reasoned deferrals |

For the upcoming lifecycle slice, inspect code at `sql/sql_yacc.yy::create_table_stmt`,
`sql/sql_table.cc::mysql_create_like_table` / `mysql_alter_table`,
`sql/sql_rename.cc::mysql_rename_tables`, and
`sql/log_event.cc::Query_log_event::do_apply_event`. The first import records file
hashes, exact locators and test dependencies; these research pointers alone are
not completed reference records.

## Qualification and evidence rules

There is no manually assigned `covered: true`. Compute a scenario/profile's
qualification from its contract, binding and a selected evidence bundle:

| Qualification | Meaning |
| --- | --- |
| `unverified` | No complete, matching evidence; includes parser-only checks and legacy aggregate passes |
| `partial` | Some required assertions/profiles pass; missing obligations remain listed |
| `verified` | Every required assertion for the declared outcome passed on matching inputs/settings |
| `failed` | A selected matching run violated an assertion or failed to finish the case |
| `stale` | Evidence exists but code, scenario, profile or fixture identity differs |
| `excluded` | Reviewed scope exclusion; never counted as supported or verified |

Keep separate report columns for native expected rejection, 5.7 incompatibility,
Swift intentional rejection and unimplemented Swift support. A verified rejection
proves stopping behavior; it does not mean the feature is supported for application.
A source syntax rejection with no event cannot certify a Swift stop boundary.

Extend `QualificationCase`/`QualificationReporter` with catalog scenario/profile
references and named assertion results, preserving current names and source
locations. Add a declarative case registry shared with execution so validation can
resolve bindings offline; do not discover cases by running Docker or grepping
Swift source. Support multiple ordered case bindings and retain assertions even
if a later case or suite cleanup fails.

A run manifest must include run ID/time, suite, code revision/dirty state and
content fingerprints, catalog/profile/fixture hashes, toolchain/runtime image
identity, actual server versions/settings, and assertion IDs/outcomes/evidence.
Fingerprint the relevant Swift/Rust sources, dependency lockfiles/vendor inputs,
harness/tests and Docker/build configuration, including untracked relevant files;
a Git commit alone cannot identify a dirty build or reused runtime image. Also
record the binary/image build provenance. Documentation-only edits need not stale
runtime evidence. Contract changes invalidate their affected qualifications.

A completeness verification requires the selected required runs to finish their
assertions and cleanup successfully. Preserve individual successes for diagnosis,
but do not use a passing child to bypass failed or incomplete parent obligations.

Retain raw evidence in run directories; a portable exported bundle contains the
manifest, case/assertion results, relative artifact paths and SHA-256 checksums.
Reject missing files, path escapes, mismatched hashes and incompatible identities.
Reports consume explicit bundles/run IDs; never silently select whichever passing
run is convenient. Missing local artifacts mean unavailable evidence, not success.
Historical results can be displayed with their known provenance and limitations;
do not synthesize missing assertion or build metadata to make them qualify.

For successful DDL require actual schema/defaults/engine checks, following DML
with exact values, normalized binlog effects, schema-history/cache behavior and
correct source boundaries. After DROP, following workload may recreate the name
or use an unaffected table; do not require DML against a nonexistent table.
For rejected DDL check diagnostics, partial effects/intents, stopped progress and
a later event that must remain unapplied. For conditional no-ops first measure
whether the source logs an event: never invent a transaction/checkpoint for a
statement that produced none. Check warnings where meaningful.

Summaries show inventory review coverage, implemented scenarios, verified applies,
verified rejections, gaps and exclusions separately, per family/profile. Include
the declared denominator and inventory revision; a high percentage of a small
selected subset must not be presented as completeness of MySQL DDL.

## SwiftPM / Make interface

`check` and `report [--format markdown|json]` are available. The remaining commands
and `report --evidence` below are the planned interface and currently fail explicitly:

| Make | SwiftPM command | Behavior |
| --- | --- | --- |
| `make ddl-catalog-check` | `swift run replicator-lab ddl-catalog check` | Offline shape/semantic validation, registry bindings and deterministic report checks; no Docker/network |
| `make ddl-catalog-upstream-check` | `swift run replicator-lab ddl-catalog upstream-check --mysql-source .upstream/mysql-server` | Verify local pin, referenced files/hashes/locators/dependencies; missing checkout is a clear error |
| `make ddl-catalog-scan` | `swift run replicator-lab ddl-catalog scan --mysql-source .upstream/mysql-server` | Produce candidate inventory/diff under artifacts for review; never auto-mark coverage or edit expectations |
| `make ddl-catalog-report ARGS='--evidence <bundle>'` | `swift run replicator-lab ddl-catalog report --evidence <bundle>` | Emit deterministic JSON/Markdown inventory and evidence status; repeat evidence flag for multiple bundles |
| `make ddl-catalog-verify ARGS='--evidence <bundle> --family B'` | `swift run replicator-lab ddl-catalog verify --evidence <bundle> --family B` | Enforce the selected catalog contract; nonzero for missing/stale/failed required evidence |

`report` without evidence shows the inventory and unverified obligations. Malformed
catalogs/bundles cause nonzero exit; ordinary research gaps are visible in reports.
`check` validates structure even with planned gaps; it must not imply qualification.
`verify` selects all in-scope scenario/profile obligations of the requested family,
not just those already implemented. Expected rejection passes when its assertions
match. Unresolved expectations and incomplete inventory for the declared family
scope prevent a completeness gate from passing. No command fetches upstream or
starts databases implicitly. Existing suites continue to execute the actual tests.
`make upstream-tests` remains the separate Rust binlog codec qualification command.

## Implementation sequence and acceptance

1. **Contract and offline tooling.** Add schema-versioned models/files, registry,
   check/report commands and Make targets. Inventory all current DDL case IDs,
   their supported shapes and gaps; seed lifecycle variants before changing DDL.
   Test duplicate/dangling IDs, invalid status combinations, profile applicability,
   paths, schema versions and registry resolution without Docker or upstream clones.
2. **Pinned reference inventory.** Implement local scan/upstream-check. Review and
   map the table-lifecycle test sections and their actual prerequisites/results.
   Test changed pins/hashes, missing includes and ambiguous anchors. Leave A–F
   review gaps explicit; a filename scan alone cannot complete this step.
3. **Evidence integration.** Extend native/Swift suites with assertions, profiles
   and provenance; add verify/export/report support. Test successful apply,
   verified rejection, assertion failure, no-event/no-op behavior, partial coverage,
   stale/missing evidence and a deliberately broken expected value. Run existing
   suites through Make and reconcile every bound case/assertion with saved output.
4. **Use the checklist.** Before implementing conditional CREATE/DROP, CREATE LIKE
   or rename extensions, enumerate their scoped scenarios and establish native /
   5.7 observations. Each implementation PR updates catalog obligations, tests and
   evidence together. Recovery, skip controls and dump/load stay in their existing
   separate plans; the catalog may list those deferrals without implementing them.

Done for this catalog increment means the offline checker runs from a clean
checkout without ignored artifacts, every existing DDL case has a binding or an
explicit non-catalog classification, lifecycle gaps are enumerable, and a reviewer
can reproduce why any selected scenario is verified or still a gap. It does not
mean all DDL families are complete. The catalog's own validation must not accept
missing tests or stale evidence as coverage.

## First evidence-driven test increment

The pinned scan returned 2,102 research candidates, not 2,102 verified behaviors.
The first selected gaps were already-empty TRUNCATE and completing the following
DML after a same-schema rename. Six named steps extend the ordered suite from 26
to 32 operations: TRUNCATE/INSERT/key-changing UPDATE/DELETE on an empty table,
and key-changing UPDATE/DELETE after rename. They run in both existing Swift
profiles against source InnoDB, native 8.4 MyISAM and Swift-applied 5.7 MyISAM.
No production DDL grammar or applier behavior changed in this increment.

`DDLCoverageCases.evidenceContracts` binds two required assertions, schema-effects
and following-dml, to exact case IDs for three scenarios (rename, populated
TRUNCATE, empty TRUNCATE). The harness checks column types/signedness, nullability,
defaults, keys, charset/collation, local engine selection and exact row values;
source warnings and the observed source boundary are retained. Statement-order
binlog checks, SQLite history and group checkpoint checks continue to run, but do
not automatically satisfy scenario-specific catalog assertions.

This intentionally yields **partial** qualification. The schema/data denominator
is not substituted for the full catalog denominator. No current bundle can yield
full verification, even if its two instrumented assertions pass. Explicit bundle
selection rejects duplicate profiles and checks artifact hashes, source/fixture
and contract fingerprints, build/image identity, runtime versions/settings, named
case results and successful completion/cleanup. Dirty builds are identified by
content, and changed sources/contracts produce stale evidence. Failed runs retain
assertion diagnostics. Per-event applier session context remains an explicit gap.

## Conditional/LIKE implementation increment

Native observation now precedes the implementation: twelve additional cases run
in both native profiles, including direct SQL on 5.7. Successful conditional
no-ops log events; CREATE LIKE copies the receiving node's local template engine,
column/default/key metadata and no rows. Source-only errors and replica-only
missing-template failure have separate catalog contracts.

The ordered Swift suite grows from 32 to 70 statements (27 DDL, 56 affected DML
rows), adding eight scenario contracts with metadata and following-DML assertions.
Both file-position/MINIMAL and GTID/FULL metadata profiles execute multirow
operations, key moves, integer limits and exact text/binary values. The registry
has 97 declarations (79 Swift-suite and 18 native-suite); the catalog has 56
scenarios and 132 scenario/profile combinations. Its 638 assertion/profile
obligations retain the earlier observation requirements, add the implementation
checks, add native profiles and add a replica-only missing-template contract.
The successful 2026-09-30 rerun records growth from 12 to 44 passing
obligations and from six to 22 partial combinations. See the local
[comparison artifacts](../artifacts/ddl-conditional-like-20260930/README.md) for
exact run paths and reproduction commands. No full verification is
inferred from these passes. Native matrix results are not yet imported as named
assertion evidence.

The next changes, in priority order, are:

1. Bind boundary-specific normalized row/binlog effects, SQLite applied position /
   GTIDs and schema-history/cache invalidation. Establish warning/context contracts
   and test the evidence gate with deliberately wrong expected rows/checkpoints
   before promoting any scenario to verified.
2. Extend LIKE template qualification to additional supported indexes/defaults
   only after native comparisons, then ALTER RENAME, cross-schema rename and
   multi-object error/partial-effect tests. Keep temporary-table logging separate.
3. Give standalone DML its own obligations/evidence mapping. These catalog totals
   count only DML following a specific DDL; standalone DML baseline/negative cases
   are not silently included.

Recovery, skip controls and dump/load management stay outside this increment.

## Database creation increment

`ddl.database.create.supported` adds a bounded six-case CREATE DATABASE/SCHEMA
contract. Both schema-effects and following-dml assertions require every case in
a profile: omitted server defaults, explicit options, charset-only, collation-only,
and matching/different existing-database no-ops. Native observations/direct SQL
remain separate from Swift qualification. A source duplicate with error 1007/no
event is a separate scenario; three Swift rejection scenarios cover explicit and
inherited unsupported collations and denied CREATE permissions.

The catalog now has 61 scenarios, 113 registered declarations (88 Swift-suite and
25 native-suite), 29 pinned references and 690 required assertion/profile obligations.
The six accepted cases can add four passing assertion/profile obligations, taking
the prior 44 to 48 and the partial combinations from 22 to 24. This grouping requires
all six cases; it does not count individual SQL statements as covered scenarios.
Full verification and the remaining database lifecycle backlog stay unqualified.
