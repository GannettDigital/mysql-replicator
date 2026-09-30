# DDL coverage catalog

This is the first implementation step of the
[catalog plan](../../PLAN/DDL_COVERAGE_CATALOG.md). The catalog is an offline,
reviewable checklist. It contains 55 scoped scenarios, 29 features across families
A–F, four fixture profiles and 17 pinned research references. The shared registry
contains 40 executable case declarations: 34 from `ddl-suite` and six from
`native-ddl-suite`. The DML baseline case has an explicit non-DDL classification.
All family inventories remain partial; broader feature rows must be split during
upstream/fleet review. These counts are not the size of the MySQL DDL language.

## Commands available now

From the repository root:

```sh
make ddl-catalog-check
make ddl-catalog-report
make ddl-catalog-report ARGS='--format json'
swift test --filter DDLCoverageTests
```

Equivalent commands are `swift run replicator-lab ddl-catalog check` and
`swift run replicator-lab ddl-catalog report [--format markdown|json]`.
Check/report do not invoke Docker, Git, MySQL, an upstream checkout, or previous
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

Upstream scan/check, evidence import/export, assertion provenance and completeness
`verify` are subsequent steps. These commands/options currently fail explicitly;
no old suite pass is silently imported as coverage. `make upstream-tests` remains
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
  files and candidate inventory. Relevant dependencies are explicitly unreviewed;
  the checker validates these records without reading the ignored checkout. File
  hash/anchor verification and include discovery are the next implementation step.
- `schema/*.schema.json`: version 1 strict object shapes. The Swift validator
  implements only their documented vocabulary: local `$defs`/`$ref`, object
  properties/required/additionalProperties=false, arrays/items/minItems/uniqueItems,
  string minLength/pattern, integer minimum, booleans and enums. It rejects unknown
  or incompatible schema keywords. It is not a general JSON Schema validator.

`implementation` is `missing`, `partial` or `implemented` for the stated intent.
An implemented `observe` scenario is a native observation test, not Swift apply
support. Intent is `apply`, `reject` or `observe`. Native expected failure, 5.7
capability and Swift policy rejection are separate outcomes, not one supported flag.

Every in-scope scenario currently reports **unverified**, including those with
previously passing integration cases. This preserves the historical test results
while acknowledging that per-assertion/build/profile evidence is not wired into
this catalog yet. `bindings[].assertion_ids` must remain empty in this step; the
required assertion contracts are explicit, but an aggregate case pass does not
satisfy them automatically. Unknown outcomes and unresolved settings remain gaps.

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
reference hashes/locators matched the pinned local checkout. Permanent automated
upstream checking remains step 2. No Docker suites were rerun for this metadata/
declaration refactor; existing SQL and assertions were unchanged.

Review outputs and the test log are retained locally in
`artifacts/ddl-catalog-step1/`. They validate the catalog implementation, not the
108 replication-profile obligations it currently declares.
