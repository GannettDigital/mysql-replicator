# Measured migration from legacy qualification suites

Scope: measure and review gaps first. Do not remove legacy runners or commands
until the replacement assertions and variant coverage have been reviewed.

## Two independent measurements

1. **Runtime code coverage:** first-party Swift executable lines exercised by
   the applier inside the fixtures. Compare exact line sets, not percentages
   alone. Exclude `ReplicatorLab*` from this comparison and keep unit coverage
   separate so it cannot hide lost integration paths. Rust decoder internals and
   dependencies are not instrumented by the current coverage tooling.
2. **Behavioral qualification:** scenario × topology × positioning/metadata
   variant × required assertion. A source success, native observation, target
   result, binlog oracle, durable checkpoint and expected refusal are different
   obligations. Executing a line does not establish any of those assertions.

The DDL catalog is a scoped replication checklist linked to selected upstream
references. It is **not coverage of the entire MySQL MTR suite**. Its six family
inventories are partial and its upstream candidates remain pending review.
Do not divide our case count by an upstream file count and call that coverage.

## Measured forward result (2026-10-07)

All groups below use the same instrumented image and the same 5,855 mapped Swift
runtime lines. The forward comparison uses full shared correctness plus lifecycle. Legacy is
full DDL in both modes plus the seven passing DML selections described below;
the unresolved generated-column case makes it a partial legacy baseline.

| Group | Runtime lines hit | Coverage |
| --- | ---: | ---: |
| Measured legacy forward | 4,717 / 5,855 | 80.56% |
| Shared forward correctness + lifecycle | 4,401 / 5,855 | 75.17% |
| Shared reverse correctness + lifecycle (separate topology) | 4,582 / 5,855 | 78.26% |

The intersection is 4,387 lines: **330 legacy-only lines** and **14 shared-only
lines**. Their exact locations and producing invocations are saved in
[comparison.json](../artifacts/coverage-migration/20261007/comparison/comparison.json),
with a [module summary](../artifacts/coverage-migration/20261007/comparison/comparison.md)
and [explicit input manifest](../artifacts/coverage-migration/20261007/manifest.json).
These artifacts are local and ignored by Git.

| Legacy-only area | Lines | Producing examples / implication |
| --- | ---: | --- |
| `TableFilter.swift` | 140 | `wild-ignore`, resume, included rejection; shared defaults never activate filtering |
| `DDLRename.swift` | 44 | Collation-compatible cleanup/table-swap workflow; reverse table-swap hits cannot replace forward qualification |
| `TargetSession.swift` | 24 | Permission/index failures, partial writes, explicit table locking |
| `StateStore.swift` | 22 | Uncertain DDL timeout followed by CLI skip refusal |
| `StreamProcessor.swift` | 15 | GTID-only starts and implicit adjacent-file rotation; similar reconnect case names did not produce these hits in the shared run |
| `CompatibilityPolicy.swift` | 13 | Collation rewriting and collision/refused-policy-change paths |
| `TableLockEpoch.swift` | 11 | `schema-cache` explicitly exercises the optional table-lock policy |
| Other files | 61 | DDL, decoder refusals, positional protocol, cancellation/error handling and pipeline paths |

The applier killed in `batch-crash` exited 137 without a flushed profile. Its
behavioral case passed, but those unflushed code hits are unknown; they are not
silently treated as measured zero. Runtime line coverage does not measure Rust
internals, branch coverage or assertion strength.

Completed qualification: 127 shared correctness cases (63 forward, 64 reverse),
22 shared lifecycle cases, 273 legacy DDL case executions, 166 case executions
across the seven selected DML runs, and 96 native observation cases. The DML count
includes repeated positive prerequisites; it is not 166 distinct behaviors.
Each completed selection passed cleanup. Nine lab option/profile unit tests,
14 Python tooling tests and Periphery also passed. No production applier logic
changed. The full legacy DML attempt and full catalog import failures below remain
unresolved and are deliberately not reported as passes.

## Measurement scope and method

Use one frozen checkout and one immutable instrumented Linux image for:

| Group | Runs |
| --- | --- |
| Legacy forward | Full `ddl-suite` in both modes; seven passing DML selections after the full DML attempt failed |
| Shared forward | Full `correctness` plus `lifecycle`, forward profile |
| Shared reverse | Full `correctness` plus `lifecycle`, reverse profile |
| Native observations | `native` adapter, both historical native variants; no applier runtime coverage |

The forward line-set comparison is the direct legacy/shared comparison. Reverse
coverage is recorded separately; hits in an InnoDB run must not hide missing
MyISAM tests. Forward `recovery` still calls legacy DML `extended`, whose
implementation is measured here. It is deliberately not counted as a replacement
shared runner merely because it has a new command. Reverse `recovery` still calls
`ReverseQualification`. Reverse recovery, the `demo` adapters, old demos,
capture/native protocol qualification, packaging and benchmarks are not included
in this line comparison and need their own disposition before an entire legacy
CLI cutover.

Commands used for the baseline:

```sh
make correctness ARGS="--coverage"
make dml-suite ARGS="--coverage --skip-build"
make ddl-suite ARGS="--coverage --skip-build"
make lab-test ARGS="--suite lifecycle --coverage --skip-build"
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite native"
```

The legacy runners need a MySQL 8.4 `mysqlbinlog` on PATH or `MYSQLBINLOG` set.
Record explicit evidence directories; never glob old runs into a coverage union.
An interrupted/failed run is diagnostic evidence, not a passing migration
baseline. An intentionally killed applier cannot flush its LLVM counters; retain
that missing-profile marker and qualify the crash behavior through assertions.

### Baseline failure requiring review

The full legacy DML attempt stopped in file-position mode at
`matrix-reject-generated`: it expected a rejection mentioning `EXTRA`, but the
applier exited successfully. The source has ordinary `v INT`, the target has
`v INT AS (id+1) STORED`, and the source inserts `(1,2)`. Current generated-column
execution omits generated fields from INSERT and compares the target-generated
value with the source image; these values match. This is a conflict between an
old blanket-rejection expectation and the current generated-column path, not
permission to silently turn a failed test into a pass.

The failed run is retained separately. Additional DML measurements explicitly
select the remaining 28 matrix cases in both positioning modes, plus reconnect,
target-reconnect and extended slices. Their exact argv and the excluded case are
in `artifacts/coverage-migration/20261007/dml-selections.json`. A comparison using
those passing selections is a **partial legacy baseline**, not a passing full
legacy DML suite. Review whether to replace the old expectation with a matching
generated-value case plus a divergent-value refusal before retirement.

### Catalog import drift found by the measurement

The full legacy file-position DDL run passes all 136 executed cases and cleanup,
but the current catalog importer rejects its fresh `coverage-evidence.json` with
`unknown, duplicate or invalid evidence case`. The run contains three helper
cases absent from `DDLCoverageCases.registry`:

- `ddl-compat-collation-cleanup-initial`
- `ddl-compat-collation-cleanup-changed`
- `ddl-compat-collation-cleanup-removed`

The recorded observations remain useful diagnostic evidence, but the whole
bundle is not accepted catalog qualification. Do not remove those case records
or bypass validation to make it import. Register/classify the helpers and rerun
fresh evidence before using the catalog as a retirement gate. The exact failed
import is saved in `artifacts/coverage-migration/20261007/catalog-import-attempt.json`.

`tools/compare_test_coverage.py` accepts an explicit manifest with named groups
of `{ "result": ".../result.json", "coverage": ".../code-coverage/combined/coverage.json" }`
entries and `comparisons` containing `{ "id": "forward", "baseline": "legacy-forward", "candidate": "shared-forward" }`.
The manifest uses `schema_version: 1`; paths are relative to the checkout.
It requires successful run/cleanup, one immutable instrumented runtime image and
matching runtime source hashes. Harness-only changes can therefore be compared
without invalidating the frozen runtime baseline. Runtime changes require new
measurements. JSON output retains exact lost/added lines and invocation origins;
Markdown summarizes each module on a common executable-line denominator.

```sh
python3 tools/compare_test_coverage.py \
  --manifest artifacts/coverage-migration/20261007/manifest.json \
  --output artifacts/coverage-migration/20261007/comparison
```

## Inventory findings before execution

The current registry contains **134 legacy DDL declarations and 48 native
declarations**. There are 64 shared correctness declarations (63 apply to the
forward profile, 64 to reverse) and 11 shared lifecycle cases per profile.
38 legacy DDL IDs also occur in shared correctness. This is a candidate mapping,
not proof that the assertions or fixture variants are equivalent. Legacy DML
also splits a shared fixture into several phase IDs; raw case-count percentages
would be misleading in both directions.

The current catalog has **63 scenarios, 152 scenario/profile combinations and
730 required assertion/profile obligations**. Its bindings reference only
`ddl-suite` and `native-ddl-suite`; shared runners currently export observations
but no catalog-compatible named assertion bundles. Removing the old DDL runner
now would remove the catalog's executable evidence producer. Native case passes
also do not automatically satisfy named assertion obligations.

Only **68 of the 730 logical obligations (9.32%)** currently have named assertion
bindings, across 14 scenarios. This measures instrumentation binding, not passing
qualification. The other 662 obligations must remain visible even though their
evidence producers are not yet implemented. The completed file-position legacy
DDL run records 165 passing assertion observations on 74 cases; many observations
contribute to the same logical obligation, so 165 must not be used as a numerator
against 730. Fresh catalog qualification remains blocked by the registry drift
described above.

All four catalog profiles currently describe forward/native fixture variants;
there are no reverse-profile obligations yet. The upstream manifest pins both
5.7 and 8.4 source trees, but that is not reverse qualification. Add explicit
reverse expectations and assertions when extending the catalog, while preserving
the original forward obligations for the migration comparison.

The DDL catalog also excludes much standalone DML, capture, reconnect and
recovery behavior. Keep those as explicit lab obligations rather than forcing
them into DDL scenarios. The retirement checklist must cover both inventories;
100% of the current DDL catalog would still not prove whole-suite parity.

## Gaps established by source review

These are migration obligations, not a declaration that every similarly named
legacy case is unique. Preserve the asserted behavior and variant when mapping.

| Area | Legacy evidence beyond current shared runners | Required migration work |
| --- | --- | --- |
| Capture variants | File-position and GTID-only starts; implicit rotation; MINIMAL/FULL optional metadata and bootstrapped-schema discovery | Declare variants independently of topology and run the same applicable cases; retain negative metadata cases and verify the intended interruption branch |
| Independent oracle | Basic DML and MODIFY/index checks normalize source/native/target binlogs using `mysqlbinlog` | Preserve binlog ordering/value checks alongside shared row comparisons |
| Catalog assertions | Named `schema-effects`, `following-dml`, `normalized-binlog`, `source-boundary`, `schema-history` with build/profile provenance | Export shared assertion evidence, migrate bindings explicitly, and compare each obligation |
| Ordered DDL | Conditional CREATE/DROP/LIKE, populated mismatched definitions, cross-schema clones, truncate/recreate, warning checks and following DML | Port dependent workflows and their exact oracles; table lifecycle differs from database lifecycle |
| Filters | `wild-ignore`, resume after excluded groups, mixed events and included rejection | Add shared filter scenarios and assert excluded GTID/checkpoint behavior |
| Collation policy | CREATE LIKE/INSERT SELECT/table-swap translation, policy-change resume refusal, NO PAD/PAD collision | Forward-specific cases must remain explicit; do not infer from generic DDL success |
| DML rejection/discovery | ENUM error values/order/MINIMAL metadata, SET order, decimal sign/scale, TIME precision, BLOB width, generated mismatch, missing/incompatible tables | Port bootstrap/discovery failures; rejecting FLOAT/JSON CREATE is not the same path as rejecting row events |
| DDL failure/uncertainty | CREATE database/table permission failures, incompatible defaults, missing LIKE template, MyISAM index limit, duplicate target index, lock timeout, skip refusal | Preserve target SQL errors, pending DDL intents, unchanged checkpoints and blocked following writes |
| Saved state | Index drift refusal, composite-key resume/collision, 160-table capacity, schema cache reuse | Keep explicit assertions beyond the shared successful saved-schema restart |
| Fail-stop/recovery | Before-image mismatch, missing DELETE, active native channel, multi-statement MyISAM refusal, partial MyISAM writes, mid-group crash/refused resume | Move the forward recovery adapter's legacy dependency only after replacement assertions pass |
| Trigger/generated values | Preexisting source trigger effects, preexisting target trigger refusal, generated-value divergence | Preserve these independently of shared CREATE/DROP trigger policy and generated-column success cases |
| Native observations | Direct 5.7 SQL versus 8.4 native behavior; restricted/unrestricted engines; source failures with no binlog event | Retain as a named profile-driven observation suite, not discard because it produces no applier line hits |

## Removal gates and Periphery

1. Freeze passing baseline evidence, source hashes, image ID and the required
   obligation list. Maintain a reviewed old-case/assertion → new-case/assertion
   mapping, including prerequisites and profile variants.
2. Port one family at a time. Require its expected diagnostics, native comparisons
   and durable-state assertions; record genuinely inapplicable cases with reasons.
3. Rerun matched runtime coverage. Every legacy-only integration line needs a new
   integration hit or a reviewed explanation. A rise in total percentage, a unit
   hit, or a reverse-profile hit cannot silently waive a forward obligation.
4. Compare catalog obligations independently. Preserve both existing verified
   assertions and still-unverified required assertions; shrinking the denominator
   is not progress. Restore missing instrumentation before claiming parity.
5. Remove old CLI/Make/CI dispatch and adapter dependencies, then run Periphery.
   Old entry points are roots, so running Periphery before their removal cannot
   establish that their implementation is unnecessary. Catalog registries and
   tests can also keep helpers reachable: review those references rather than
   adding retain rules to obtain a clean scan.
6. Delete only the obsolete runners/helpers; retain shared fixture definitions,
   native observation contracts and independent oracles. Run shared qualification,
   unit tests, catalog validation, coverage comparison and Periphery on the
   resulting checkout. Update CI, workbooks and contributor commands together.

No legacy suite has been removed by this measurement work.
