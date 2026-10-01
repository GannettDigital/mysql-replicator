# DDL coverage catalog

This implements steps 1–2 and the first partial-evidence slice of step 3 of the
[catalog plan](../../PLAN/DDL_COVERAGE_CATALOG.md). The catalog is an offline,
reviewable checklist. It contains 61 scoped scenarios, 29 features across families
A–F, four fixture profiles and 29 pinned research references. The shared registry
contains 113 executable case declarations: 88 from `ddl-suite` and 25 from
`native-ddl-suite`. Baseline, setup/cleanup and extra research regressions have explicit non-catalog classifications.
All family inventories remain partial; broader feature rows must be split during
upstream/fleet review. These counts are not the size of the MySQL DDL language.

## Commands available now

From the repository root:

```sh
make ddl-catalog-check
make ddl-catalog-report
make ddl-catalog-report ARGS='--format json'
make ddl-catalog-upstream-check
make ddl-catalog-scan
swift test --filter DDLCoverageTests
```

Equivalent commands are `swift run replicator-lab ddl-catalog check` and
`swift run replicator-lab ddl-catalog report [--format markdown|json]`.
Check/report without `--evidence` do not invoke Docker, Git, MySQL, an upstream checkout, or previous
artifacts. Once the existing Swift package has been built/resolved, the commands
need no network. Reports go to stdout; redirect to a chosen file if desired.
The compiled CLI can perform the check in a checkout containing only the catalog
files and the repository marker `compose.yaml`.

`check` validates JSON structure and cross-file/registry relationships. Ordinary
implementation/research gaps are allowed and visible. Invalid records return a
nonzero exit with a field or scenario diagnostic. A successful check proves the
checklist is internally consistent; it does not qualify replication behavior.

Both Markdown and JSON reports are deterministic for the same catalog and compiled
registry. They separate implementation, intent and qualification, and distinguish
expected source/native/direct-5.7/Swift outcomes. JSON also includes required
assertions, current case-definition file/line locations and gaps.

Named schema/data assertion import is available through explicit `--evidence`
bundles. Full assertion qualification, a portable export command and completeness
`verify` remain pending; `verify` fails explicitly. No old suite pass is silently
imported as coverage. `make upstream-tests` remains
the Rust binlog codec test suite and has no DDL-completeness meaning.

## Files and status rules

- `catalog.json`: families, features, scenario contracts and explicit non-catalog
  case classifications. Scenario IDs express behaviors and are independent of
  source line numbers. Bindings can identify multiple ordered cases and their
  completion group.
- `profiles.json`: expected fixture settings and unresolved runtime measurements.
  Server/base-image references are configuration, not observed runtime image IDs.
  FULL/MINIMAL in profile IDs means **row metadata**; both Swift profiles use FULL
  row images. No other positioning/metadata combinations are implied.
- `upstream.json`: repository pin, selected file hashes/locators, associated result
  files and candidate inventory. Selected lifecycle sections and leaf prerequisites
  are reviewed; remaining dependency gaps are explicit. The offline `check` validates
  records without the checkout; `upstream-check` verifies them against local files.
- `schema/*.schema.json`: version 1 strict object shapes. The Swift validator
  implements only their documented vocabulary: local `$defs`/`$ref`, object
  properties/required/additionalProperties=false, arrays/items/minItems/uniqueItems,
  string minLength/pattern, integer minimum, booleans and enums. It rejects unknown
  or incompatible schema keywords. It is not a general JSON Schema validator.

`implementation` is `missing`, `partial` or `implemented` for the stated intent.
An implemented `observe` scenario is a native observation test, not Swift apply
support. Intent is `apply`, `reject` or `observe`. Native expected failure, 5.7
capability and Swift policy rejection are separate outcomes, not one supported flag.

Without selected evidence, every in-scope scenario reports **unverified**, including those with
previously passing integration cases. This preserves the historical test results
while requiring fresh per-assertion/build/profile evidence. Three lifecycle
scenarios now bind `schema-effects` and `following-dml`; all other assertion
bindings remain empty. An aggregate case pass never supplies them automatically. Unknown outcomes and unresolved settings remain gaps.

## Editing workflow

1. Add or refine a feature/scenario and its exact prerequisites, operation and
   following workload. Split variants with different effects. Keep family review
   states partial until their declared inventory scope has been reviewed.
2. Reference the upstream pin and actual section, not just a filename. Record
   `related_reference` for independently authored scenarios. Preserve unresolved
   setup/includes/result variants as explicit research gaps.
3. Declare required profile IDs and expected outcomes for each role. Unknown is
   preferable to assuming an error code or that a source statement emits an event.
   A source `no_event` cannot claim native or Swift replicated success/rejection.
4. Define cases in
   [DDLCoverageCases.swift](../../Sources/ReplicatorLabCore/DDLCoverageCases.swift).
   Both harness execution and offline validation consume these declarations. A
   child case requires its completion group in the binding. Preserve existing IDs
   and ordering when only moving or renaming source code.
5. Bind the cases or document why a registered case is outside the DDL catalog.
   Run the catalog checker and targeted tests. Test a changed workload with its
   actual suite before claiming behavior, then add qualified evidence when that
   next-stage tooling is available.

Keep the JSON authoritative. Generated reports are review aids, not a second
hand-maintained status table. Do not change expected results just to make a run
pass; record an observed divergence and resolve it against the native/reference
contract.

## Validation of the first implementation step

On 2026-09-30, `swift test --filter ReplicatorLabTests` passed 27 tests, including
10 catalog tests. Both Make commands passed; JSON output parsed independently.
The compiled CLI produced the same report from a minimal temporary checkout with
only the catalog and `compose.yaml`, without `.upstream`, `.git`, or artifacts.
All 40 source locations resolved, all 26 ordered DDL/DML fixture definitions and
the native/rejection SQL constants matched the committed baseline, and the 17
reference hashes/locators matched the pinned local checkout. Automated upstream checking was added in step 2. No Docker suites were rerun for this metadata/
declaration refactor; existing SQL and assertions were unchanged.

Review outputs and the test log are retained locally in
`artifacts/ddl-catalog-step1/`. They validate the catalog implementation, not the
108 replication-profile obligations it currently declares.

## Local upstream inspection (step 2)

Both new commands default to `.upstream/mysql-server`, at the revision recorded in
`upstream.json`. Override with `ARGS='--mysql-source /path/to/mysql-server'`, or use
`swift run replicator-lab ddl-catalog scan --mysql-source /path/to/mysql-server`.
They require local Git and OpenSSL, a clean checkout at the exact pin, and fetch
nothing. Missing/wrong/dirty checkouts fail without resetting the source.

`upstream-check` validates every pinned file's SHA256 and exactly one anchor match
**within its declared line range**. It checks include/result/options paths and
rejects a `dependencies_reviewed` claim if discovered direct dependencies are
unrecorded, unresolved, or lead to unreviewed dependency references. A successful
check can still have research gaps: see `review_gaps` in its JSON report. It does
not run MTR or establish the server settings/results for our topology.

`scan` first runs that checker, then searches `.test` files in the catalog's declared
scan roots for DDL text, including statically reachable include-only wrappers.
It follows literal `source`/`--source` directives using the including directory
first, then `mysql-test/`, matching `client/mysqltest.cc::open_file`. Each file is
visited once; cycles remain visible as edges. Missing literal paths, dynamic paths
and unsupported include syntax remain unresolved. Branches and variables are not
evaluated. Files with intentional non-UTF8 test bytes use replacement characters
for ASCII text discovery; SHA256 always hashes the original bytes.

The scanner records file hashes, include edges with line numbers, possible result
variants through wrapper tests, per-test options/configuration/combinations, shell
hooks, nearby suite settings and the possible default configuration. It marks newly discovered
candidates `addition_for_review`. Existing records preserve their review states;
family scope hints are not semantic classifications. Comments/SQL strings can
produce false positives. Dynamic/generated SQL, unrecognized directives and suites
outside the declared roots can produce omissions. Configuration/option-file includes, suite.pm, hooks
and runtime result selection still need manual review. This is a candidate finder,
not an MTR parser, execution trace, exhaustive language inventory or coverage gate.

Reports go to ignored directories:

- `artifacts/ddl-catalog-upstream-check/<run>/upstream-check.json`
- `artifacts/ddl-catalog-scan/<run>/inventory.json` and `upstream-check.json`

`inventory.json` contains candidate additions plus a file/include graph, including
unresolved includes from scanned tests that the DDL heuristic did not select.
Reports do not modify the catalog, expectations, source checkout or review states.
Repeated scans of the same inputs produce identical JSON content; the containing
run directory is unique. Progress messages describe each major scan phase.

## Lifecycle reference review

Section IDs and exact line ranges/hashes in `upstream.json` are authoritative.
All mappings remain `related_reference`: the executable Swift fixtures were
independently authored, not ported MTR cases.

| Reference section | Reviewed behavior and setup | Remaining gap |
| --- | --- | --- |
| `mysql84.create.conditional` | Existing matching CHAR(0) NOT NULL definition; NO_ENGINE_SUBSTITUTION; result note 1050 | Absent/different definitions and source logging are not demonstrated |
| `mysql84.create.like` | Populated template, empty copy, cross-schema copy, existing/missing object errors; temporary shadowing; PS warning-count handling | 8.4 InnoDB/default collation results are not 5.7 MyISAM expectations; native/Swift and logging observations needed |
| `mysql84.drop.conditional` | Missing table(s): errors without IF EXISTS, note 1051 with it | Present/mixed-object drops and nontransactional partial effects need separate references and observations |
| `mysql84.rename.basic` | Session-count setup, populated CREATE SELECT sources, simple rename/chains, collisions and missing source | Error lists are masked in `.result`; numeric/symbolic expectations come from `.test`; cross-schema/ALTER spelling and MyISAM partial effects remain gaps |
| `mysql84.rename.myisam-sdi` | MyISAM availability/default prerequisites, datadir access and normalized SDI filenames | SDI filesystem checks do not transfer to 5.7; later locking/rollback sections remain pending |
| `mysql84.truncate.basic` | Two rows, TRUNCATE, count=0, INSERT, count=1 | Empty-table variant and row-event/binlog qualification remain pending |
| `mysql84.truncate.missing` | Missing table: 1146 / SQLSTATE 42S02 | Source rejection alone is not replicated rejection |
| `mysql84.truncate.auto-increment` | TRUNCATE produces generated values 1,2; DELETE then produces 3,4 | Must establish actual native/MyISAM/Swift outcomes |

Large files stay `pending_review` even where `scenario_ids` list reviewed sections.
Leaf include/result review does not imply whole-test or replication qualification.
All six family inventories remain partial and all 108 scenario/profile obligations
remain unverified without evidence. The first evidence slice below permits partial
qualification; native observations and missing lifecycle variants follow.

Step 2 validation on 2026-09-30: all 34 harness tests passed, including synthetic Git
fixtures for pin/hash drift, locator ambiguity, include lookup/cycles, missing and
dynamic includes, result variants, symlink rejection and deterministic scans. The
real pinned checkout passed 26 reference checks (10 with explicit dependency-review
gaps). The scan examined 2,244 tests, reported 2,102 candidates (2,093 additions)
and hashed 5,462 files. Its 277 unresolved include expressions include intentional
MTR meta-tests; they are review items, not automatically defects in MySQL.
No production workload or Docker fixture was changed by this increment.

The final test log and offline coverage report are retained in
`artifacts/ddl-catalog-step2/`; the generated source inventory is in
`artifacts/ddl-catalog-scan/20260930T203504Z-06d1c40b/`.

## Named assertion evidence and before/after comparison

Run `make ddl-suite` to build the labelled Ubuntu runtime and execute both Swift
profiles. The six new named steps test empty-table TRUNCATE followed by binary
INSERT, primary-key/NULL UPDATE and DELETE, plus UPDATE/DELETE after rename.
The suite retains existing checks and now writes observed schema/data values for
named assertions. Each completed profile produces `coverage-evidence.json` beside
`result.json`, `cases.json` and `coverage-runtime.json`.

Use the explicit paths printed by that run (one bundle per profile):

```sh
make ddl-catalog-report ARGS='--format json' > before.json
make ddl-suite
make ddl-catalog-report ARGS='--format json --evidence artifacts/ddl-suite/POSITION_RUN/coverage-evidence.json --evidence artifacts/ddl-suite/GTID_RUN/coverage-evidence.json' > after.json
```

`POSITION_RUN` and `GTID_RUN` are placeholders for the actual run directories.
Compare `assertion_summary` and each scenario's `profile_evidence`: these show
passed/required assertions, missing assertion IDs and partial profile counts.
The catalog has 690 required assertion/profile obligations across 144 scenario /
profile combinations. Twelve scenarios currently have two instrumented assertions
each in two Swift profiles: at most 48 passing obligations and 24 partial combinations.
The denominator increased because earlier research obligations remain, native
profiles were added, and replica-only missing-template failure has its own contract.
Full scenario verification remains zero until the other obligations are bound.
This measures DML following those DDL operations, not all standalone DML coverage.

The two bound assertions are `schema-effects` and `following-dml`. Recorded checks
include exact column types/signedness, defaults, nullability, primary keys, table /
column collations, local engine selection, source warnings and exact rows. All
bound cases, their `ddl` parent and run cleanup must pass. Binlog ordering, SQLite
history and end-of-group checkpoints still execute, but their aggregate passes
cannot fill the unbound `normalized-binlog`, `source-boundary` or `schema-history`
assertions. Those remain listed as missing.

Evidence is accepted only with checksummed artifacts, matching code/fixture and
catalog/profile fingerprints, labelled runtime build identity and captured server
versions/settings. The input fingerprint includes relevant dirty and untracked
source/test files, vendor inputs, locks and Docker/build configuration; generated
caches and Markdown documentation are excluded. A changed contract/source/harness
binary marks evidence stale. `--skip-build` requires a matching labelled image.
Duplicate bundles for a profile are rejected to prevent selecting individual
passes across runs. Historical cases.json files without this provenance are not
accepted. Per-event applier-session context and full completeness verification
are explicitly unfinished.

For subsequent DDL/DML work, follow the prioritized list in the
[catalog implementation plan](../../PLAN/DDL_COVERAGE_CATALOG.md#first-evidence-driven-test-increment).

The first evidence increment was run on 2026-09-30: all 38 harness tests and both
expanded DDL-suite profiles passed, including cleanup. Re-running the catalog with
the two completed bundles increased recorded passing assertion/profile obligations
from 0 to 12 (of 470), with six partial scenario/profile combinations and zero full
verifications. Registered case declarations increased from 40 to 46. The saved
[before/after comparison](../../artifacts/ddl-coverage-increment-20260930/README.md)
contains exact reproduction commands and distinguishes new cases from newly recorded
evidence for existing checks. Those artifacts are local and ignored by Git.

## Conditional/LIKE and following DML increment

`NativeLifecycleQualification.swift` supplies twelve named source/native/direct-5.7
observations per native profile. `lifecycle-matrix.json` records source boundaries,
logging, diagnostics and metadata. These are research artifacts, not imported
catalog assertion evidence. Source failures cannot prove Swift rejection.

`DDLCoverageCases.changes` adds 38 ordered steps for conditional CREATE (absent,
matching, different), conditional DROP (present, absent), LIKE (same/cross schema,
conditional existing), following DML and cleanup. Together with the existing
steps this is 70 statements, 27 DDL and 56 affected DML rows per profile. Multirow
operations and key changes follow schema discovery; exact hex oracles distinguish
UTF-8, trailing spaces, embedded NUL, NULL and empty values. Whitespace-preserving
SQL output prevents an empty final field from disappearing in the row oracle.

A separate `ddl-like-missing-template` test prepares a source-only template,
emits valid source DDL, and compares native error 1146 to Swift's fail-stop,
including unchanged applied state and a blocked following event. All templates
stay inside the existing single-primary-key/type subset. General index/default/
AUTO_INCREMENT inheritance and temporary-table LIKE are not qualified.

Validation on 2026-09-30: all 57 applier/harness unit tests passed; both native
profiles passed all 18 named cases; both expanded Swift profiles passed all 79
named cases, including cleanup. The combined report records 44 / 638 passing
assertion/profile obligations and 22 partial combinations, compared with the
saved predecessor's 12 / 470 and six partial combinations. Full verification
remains zero. The [comparison and reproduction commands](../../artifacts/ddl-conditional-like-20260930/README.md)
include exact evidence paths and explain the increased denominator. These artifacts
are local and ignored by Git. The reviewed predecessor is commit `6f07e0b`;
the conditional/LIKE implementation was committed as `90d6ae4`.

## Database creation slice

`DatabaseCreationCases.swift` declares six accepted CREATE DATABASE/SCHEMA cases
plus explicit/inherited unsupported-collation and permission-denied failures.
Each accepted case checks database defaults, following table metadata/local engine,
DML and retained seed data. Cases run before the existing ordered table-DDL stream
in `make ddl-suite`; grant setup names the new schemas without creating them.
Database-only intents store metadata in `ddl_intents.database_json` (SQLite format
4), with no table-schema IDs. The existing retention policy covers these intents.

The native suite adds seven cases per profile, including duplicate error 1007 with
an unchanged source binlog boundary. `database-creation-matrix.json` records defaults,
warnings and source boundaries; decoded source binlogs retain the Query context.
The supported catalog scenario requires **all six** accepted cases for each of its
two bound assertions. The earlier database lifecycle backlog still covers ALTER,
DROP and remaining options. No source rejection is counted as Swift apply coverage.

Validation on 2026-09-30: 59 unit tests passed; both native engine-policy profiles
passed 25 cases each; file-position/MINIMAL and GTID/FULL-metadata Swift profiles
passed 88 cases each, including cleanup. The upstream reference check passed.
Fresh evidence records 48/690 passing assertion/profile obligations, 24 partial
combinations and zero fully verified combinations (previously 44/638, 22 and zero).
The [comparison and reproduction commands](../../artifacts/database-creation-20260930/README.md)
retain the exact evidence paths and distinguish passing assertions from unbound
native/rejection obligations. Artifacts are local and ignored by Git.

## MODIFY and secondary-index slice

`ModifyIndexCases.swift` defines 22 positive variants. Every variant checks exact
column/index metadata and retained rows. DML probes follow the behavior under
test: a single INSERT for most type/lifecycle changes, INSERT/UPDATE for key
changes, and full INSERT/UPDATE/DELETE in five representative mixed-stream cases.
Index rename/drop cases have no DML workload or following-DML evidence claim.

Two bounded scenarios bind schema effects, normalized binlogs, source boundaries,
schema history and selected following-DML probes. Named MyISAM key-size/duplicate
failures, timeout, and indexed-state resume/drift checks remain separately
classified; these do not imply complete index/error coverage. Native observations
are not imported as native-profile assertions. See the
[implementation scope and qualification](../../PLAN/DDL_MODIFY_AND_INDEXES.md).

Validation on 2026-10-01: 135 Swift tests, 114 cases per Swift DDL profile, 48
cases per native profile and 10 demo cases passed. Both existing DML profiles
passed. Fresh evidence records 68/730 passing obligations, 28 partial combinations
and zero fully verified combinations (previously 48/690, 24 and zero). See the
[comparison and exact reproduction commands](../../artifacts/modify-index-20261001/README.md).
