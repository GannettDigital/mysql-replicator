# Remaining gaps before legacy test retirement

Initial assessment at `1ab705d`, 2026-10-07. That commit repairs the qualification
baselines and ports the filter family. No legacy runner is ready for wholesale
removal. This is an assessment of the remaining work, not a new qualification run.
The [migration review](TEST_SUITE_COVERAGE_MIGRATION.md) retains the earlier
measurements, fixture failures, repairs and filter-port evidence.
The implementation checkpoint at the end records subsequent progress; the
initial measurements below remain historical.

## Evidence we can use

The repaired baseline passed all 442 legacy DDL/DML case executions, in both
historical positioning modes, plus 129 shared correctness and 22 shared lifecycle
executions. These are executions, not counts of distinct features. Its accepted
catalog report contains 68 passing named obligations out of 730 required, with
28 partially evidenced scenario/profile combinations and none fully verified.

The subsequent filter port passed five shared cases per topology and four legacy
cases per positioning mode, including cleanup. All 339 Swift unit tests passed.
The shared correctness inventory now has 68 IDs: 67 applicable forward and 68
reverse. The filter comparisons used an immutable image, independent
`mysqlbinlog` observations and exact runtime line sets.

Local evidence directories (ignored by Git):

- `artifacts/coverage-migration/baseline-repair/`: full baseline, manifests,
  accepted catalog report and matched runtime comparison.
- `artifacts/coverage-migration/filter-port/`: family comparison, results and
  `filter-line-check.json`.
- `artifacts/coverage-migration/retirement-assessment/residual.json`: remaining
  original line gaps and their legacy invocation origins, calculated below.

Preserve these artifacts with the eventual retirement review. A checked-in count
does not replace the underlying results and provenance. Catalog evidence from the
repair checkpoint is historical: subsequent harness edits make it stale for
current-checkout import. Do not bypass that freshness check.

## Runtime gaps after the filter port

The last matched **whole-suite** forward comparison was 4,717 legacy versus
4,400 shared hits on 5,855 shipping Swift executable lines, with 330 legacy-only
lines. The new filter run hits 150 of those previously missing lines:

| Area | Original gaps now observed in shared forward |
| --- | ---: |
| `TableFilter.swift` | 140 |
| `ApplyRun.swift` | 8 |
| `LiveInspection.swift` | 2 |
| **Total** | **150** |

That leaves **180 original gaps still unobserved** in the available shared forward
evidence. This subtraction is a migration checklist, not a newly measured
whole-suite percentage: the full baseline and filter port used different harness
images. All shipping runtime source hashes match between the reports and the
current checkout. Only the new forward run is subtracted; reverse and unit hits
cannot waive a forward integration gap. That run also included composite DML and
JSON DDL refusal, so the 150 hits describe the selected run, not necessarily the
filter invocations alone.

| Runtime file | Remaining lines | Legacy producer / behavior to preserve |
| --- | ---: | --- |
| `DDLRename.swift` | 44 | Forward collation cleanup and multi-table swap |
| `TargetSession.swift` | 24 | Target SQL errors and explicit table-lock lifecycle |
| `StateStore.swift` | 22 | Uncertain DDL followed by CLI skip refusal |
| `StreamProcessor.swift` | 15 | GTID-only start (3), implicit adjacent-file rotation (11), requested positional start (1) |
| `CompatibilityPolicy.swift` | 13 | Collation mapping, changed-policy refusal and collision |
| `DDL.swift` | 12 | Translated DDL, rename, column drop, defaults and refusal paths |
| `TableLockEpoch.swift` | 11 | Optional explicit locking and cache reuse |
| `Codec.swift` | 9 | FLOAT/JSON row-event refusal |
| `Protocol.swift` | 7 | File-position `COM_BINLOG_DUMP` packet |
| `ApplySkip.swift` | 5 | Refuse skipping uncertain DDL |
| CLI `main.swift` | 5 | Skip invocation and diagnostic exit |
| `TargetReconnect.swift` | 5 | SQL failure classification |
| `ApplyRun.swift` | 3 | Persist rejected, unwritten groups before failing |
| `DMLExecution.swift` | 2 | Before-image / missing-row / changed-key collision failure |
| `TransactionAssembler.swift` | 2 | Source STOP event |
| `ApplyPipeline.swift` | 1 | 160-table discovery capacity |
| **Total** | **180** | |

An executable line can include multiple branches. These counts identify candidate
work; they do not prove that every branch on a hit line is tested. The intentional
`batch-crash` SIGKILL has passing behavioral assertions but no flushed LLVM
profile. Preserve that explicit unknown. Rust decoder internals are also outside
this measurement; keeping the decoder refusal fixtures remains necessary.

## Behavioral gaps, including ones percentages cannot show

The following is a migration mapping, not a claim that every old case is wholly
absent. Shared positives often exercise the same SQL but omit a legacy variant or
additional assertion.

| Legacy contract | Shared status | Remaining acceptance criteria |
| --- | --- | --- |
| Three wildcard filter cases | Ported on both topologies | Preserve exact native/target binlog operations, excluded effects, saved-state resume and included refusal; add the historical capture variants before retiring their old executions |
| Basic DML and `multirow` | Row values and key changes are exercised elsewhere | Preserve source/native/target normalized binlog sequences, exact SQLite counters/checkpoint/intents, absence of injected source GTIDs on the forward target, direct YAML credential use, and target-read count assertions |
| Matrix positives | Same SQL and independent per-phase predicates reused | Preserve bootstrap/discovery setup and MINIMAL/FULL variants; replicated CREATE supplies metadata differently |
| Twelve `matrix-reject-*` fixtures | Shared `reject-*` cases are DDL refusals | Port row-event/discovery refusals for ENUM/SET metadata, decimal scale/sign, TIME precision, BLOB width, generated-value divergence, 8.4 collation, FLOAT and JSON; assert target effects and unchanged durable progress |
| MODIFY/index and database positives | SQL, metadata and following rows largely shared | Retain named catalog assertions, binlog oracle, exact source boundaries and schema history; a successful `step()` is not equivalent evidence |
| Ordered table lifecycle (`ddl`, 70 dependent steps) | Individual operations overlap, full contract not ported | Preserve conditional CREATE with populated matching/different definitions, same/cross-schema LIKE, conditional DROP, TRUNCATE/recreate, warnings, following DML and schema history |
| Collation cleanup and collision | Generic reverse table-swap exists | Port forward default/explicit mapping, CREATE LIKE / INSERT SELECT / multi-table RENAME, saved rewrite audit, changed/removed-policy resume refusal and NO PAD/PAD uniqueness collision |
| DDL target errors and uncertainty | Shared refusals stop before target SQL | Port database/table permission failures, incompatible defaults, missing LIKE template, index byte limit and duplicate target index, lock timeout, skip refusal and index drift on resume; check target effects, pending intents and blocked following writes |
| Discovery and saved state | General saved-schema restart exists | Port absent/incompatible target tables, non-leading/composite PK discovery and resume through ADD/RENAME/key change, occupied changed key, 160 tables, explicit locks/cache reuse and refusal to initialize over existing state |
| Source/target lifecycle (11 cases) | Shared on both profiles | Preserve file-position and GTID-only variants; explicitly reproduce the source STOP and implicit rotation paths missed by the shared measurements |
| Fail-stop and recovery | Forward adapter still runs legacy `extended` | Port before-image mismatch, missing DELETE, native-channel exclusion, native error 1837 for multi-statement MyISAM, partial writes, all pending intents after mid-group SIGKILL and refused ordinary resume |
| Triggers/generated values | Shared trigger skip/DDL refusal and matching generated DML exist | Preserve preexisting source-trigger effects, preexisting target-trigger refusal and both generated-value divergence setups |
| Native observations | Retained adapter, 96 executions at initial checkpoint | Keep direct 5.7 versus native 8.4 observations, restricted/unrestricted engine defaults, source-error/no-binlog checks and independent artifacts |

Profile applicability needs a reason, not silent omission. For example, a 5.7
source cannot supply 8.4 FULL optional row metadata; reverse legacy metadata mode
uses bootstrapped labels. An ENUM-order refusal from the forward profile must not
be copied to reverse with an incorrect expectation. MyISAM partial persistence
and InnoDB rollback also require distinct assertions under the same scenario
intent.

## Catalog and runner barriers

**The shared runner is not yet a replacement catalog evidence producer.**
`DDLCoverageCases.evidenceContracts`, `DDLCoverageEvidence` and the catalog bindings
still reference the old DDL/native suites. Shared per-step observations and the
new filter assertion files do not constitute an accepted catalog bundle.

The retirement gate is to preserve all 68 currently evidenced obligations and
retain the other 662 as explicit unresolved obligations, with a reviewed
old-case/assertion/variant to new-case/assertion/variant mapping. Implementing all
730 is a broader qualification project, not a prerequisite invented for this
migration. Neither deleting unbound requirements nor counting ordinary case
passes as named assertions is acceptable. The four existing catalog profiles
describe forward/native variants; reverse results need their own explicit
contracts and cannot fill forward slots.

There are also functional dependencies beyond SQL fixtures:

| Entry point or tool | Current dependency | Safe disposition |
| --- | --- | --- |
| `test --suite recovery`, forward | `DMLQualification` extended GTID slice | Port its full behavior before deleting the runner |
| `test --suite legacy-dml/legacy-ddl/all` | Legacy adapters in `LabTests` | Remove adapters only after replacement inventories and assertions pass |
| `integration-smoke` and CI | Selected legacy MODIFY/index cases | Replace the selected sample and update artifact paths; keep testing the release executable |
| `verify_release_binary.py` | `mysql-replicator-packaging:dml` image tag | Retarget the verifier with CI; preserve exact archive/executed-binary hash comparison |
| Catalog registry and unit tests | Legacy declarations and assertion IDs | Migrate contracts explicitly; retain reusable fixture definitions independently of runner ownership |
| `native` | `NativeDDLQualification` | Retain the observation suite under the common profile interface; no applier hits is not grounds for deletion |
| `reverse-correctness` | Already delegates to `SharedCorrectness` | An alias can retire separately after commands/docs migrate; this saves no duplicate fixture implementation |
| Reverse recovery, advanced demos, capture/native protocol suites, Ubuntu packaging, benchmarks | Separate runners; outside this comparison | Keep until individually assessed; this report does not establish their redundancy |

`--coverage` currently accepts only shared correctness/lifecycle at the common
entry point. Recovery and native adapter success is not a shared coverage
measurement. CI's merged unit/integration percentage is useful reporting but
cannot serve as this retirement gate.

## Recommended remaining sequence

1. **Add capture variants and catalog evidence support.** Keep topology in
   `LabProfile`; represent positioning, optional metadata and bootstrap versus
   replicated schema separately. Initially preserve the two historical forward
   combinations, without requiring an untested Cartesian product. Requalify
   filters and lifecycle in those variants, including STOP/implicit rotation.
   Add shared named assertion bundles with the same provenance checks and an
   explicit binding migration; start with existing database/MODIFY/index cases.
2. **Port ordered DDL and forward collation workflows.** Preserve dependency
   closure and exact oracles. These address the largest remaining runtime block
   and much of the existing catalog evidence. Keep the independent binlog reader.
3. **Port negative, discovery/cache and recovery cases.** Declare each obligation
   separately, including counter assertions and engine-specific target effects.
   Move forward recovery off `DMLQualification`; preserve the reverse recovery
   adapter until its own audit is complete.
4. **Run the final comparison, then retire in slices.** Freeze a fresh checkout
   and one instrumented image; run full legacy and shared obligations with the
   declared variants. Require every old runtime gap to have a new integration hit
   or an explicitly reviewed explanation, and every legacy assertion to have a
   passing mapped replacement. Compare catalog obligations separately. Update
   Make/CLI/CI/docs and release-binary verification before deleting obsolete
   runners. Run Periphery after removing old dispatch roots, then shared
   qualification, unit/tooling tests and catalog validation on the final tree.

Old CLI roots, registry references and tests can keep obsolete helpers reachable
to Periphery. Its clean result today would not prove they are needed or safe to
remove. Do not add retain rules just to keep an obsolete test graph compiling.

No code removal or further fixture port was performed for this assessment.

## Capture variants and shared evidence checkpoint

The first migration increment adds `--variant position-minimal` and
`--variant gtid-full` to shared correctness and lifecycle. These preserve the
historical forward file-position/MINIMAL and GTID-only/FULL combinations,
independently of topology. Default behavior remains available. Historical
variants are explicitly not applicable to the reverse profile, whose 5.7 source
has no optional row-metadata setting. ENUM/SET matrix fixtures retain their
declared FULL override; the separate compatibility-types fixture remains in the
FULL variant. Bootstrap/discovery setup is still a distinct outstanding port.

Database creation and MODIFY/index now retain the old named assertions in shared
runs: inherited defaults and retained rows, warning codes, following DML, and
(for MODIFY/index) exact counters/checkpoints, published schema references and
independently normalized source/native/target binlogs. Shared runs use replicated
setup and counter deltas; legacy cases use separately bootstrapped tables and
fresh state. Matching assertions therefore does not retire bootstrap coverage.

Four catalog bindings explicitly accept `shared-correctness` alongside `legacy`.
They map the same case and assertion IDs to the same two historical profile IDs:

| Catalog scenario | Shared obligations per historical profile |
| --- | --- |
| `ddl.database.create.supported` | schema-effects, following-dml |
| `ddl.column.modify.supported` | schema-effects, following-dml, source-boundary, schema-history, normalized-binlog |
| `ddl.index.secondary.supported` | schema-effects, following-dml, source-boundary, schema-history, normalized-binlog |

Bundles retain the input/runtime/settings checks, checksummed assertion files,
cleanup gate and one-bundle-per-profile rule. Unmigrated cases cannot enter a
shared bundle; partial case selections cannot qualify a complete binding.
Default/reverse runs cannot fill historical forward catalog slots. The catalog
still has 730 obligations; this increment cannot qualify the 44 old named
obligations attached to the ordered table-lifecycle cases, or the 662 obligations
that lacked accepted evidence in the baseline.

Validation artifacts are under
`artifacts/coverage-migration/capture-variants/`. Qualification uses immutable
image `sha256:532edf3cad3bb94e286db2d9da36bc4e0c812c5c011baa97a820f00ab65330c0`.
Shipping runtime sources are unchanged. The completed forward family runs each
passed all 31 selected cases, 247 source steps and cleanup. Their catalog import
accepted **24/730 named obligations**, across six partially evidenced
scenario/profile combinations, with zero fully verified scenarios. The
six-case sample was also accepted as a valid bundle but qualified zero whole
bindings, as expected from its incomplete case selection.

The matched filter comparison selects only the three corresponding invocation
profiles, excluding prerequisites and the shared continuous writer:

| Variant | Legacy hits | Shared hits | Legacy-only | Shared-only |
| --- | ---: | ---: | ---: | ---: |
| file-position / MINIMAL | 3,506 | 3,532 | 9 | 35 |
| GTID-only / FULL | 3,550 | 3,585 | 0 | 35 |

Both comparisons use the same image and 5,855 mapped shipping Swift lines. The
nine positional differences are `LiveInspection.swift:118–123,251–253`: error
wrapping and receiver cancellation. They are hit by 30 other invocation profiles
in that same successful positional run. The earlier positional sample hit them
inside the filter invocation too. This is consistent with asynchronous shutdown
timing, not a removed runtime path; retain the raw difference and its evidence in
`filter-cancellation-review.json`. It does not waive dedicated failure/recovery
assertions. The unchanged filter assertions passed in both variants, including
independent binlogs, saved progress, excluded effects and included-DDL refusal.

The original unresolved runtime list falls from **180 to 151**:

| Original gap area now observed | Lines |
| --- | ---: |
| File-position protocol | 7 |
| GTID-only start / implicit rotation / requested positional start | 15 |
| STOP event | 2 |
| Target error classification | 5 |
| **Total newly observed** | **29** |

This is subtraction from the original gap list using unchanged shipping hashes,
not a new whole-suite percentage. Only forward integration evidence is used;
reverse and unit hits cannot close forward gaps. The five classification lines
were hit during `source-reconnect-batch` in the default forward lifecycle run;
this does not replace explicit SQL-error assertions. `residual.json` preserves
the remaining exact lines and their legacy origins. Rust and the deliberately
unflushed SIGKILL profile retain their earlier measurement limitations.

Other completed checks: 44 lifecycle executions (three forward variants and
default reverse), seven smoke cases per topology, four positional matrix cases
covering FULL overrides/generated values/composite keys, seven reverse database
and 22 reverse MODIFY/index cases, eight fresh legacy filter/prerequisite executions, 341 Swift unit tests
and 14 Python tooling tests. Cleanup passed for these runtime runs. The catalog
structure check passes with 63 scenarios and 185 declarations. Exact runs,
result checksums and the final comparisons are recorded in `summary.json`.

No legacy runner or adapter has been removed. Ordered DDL and forward collation
remain next, followed by negative/discovery/cache/recovery fixtures and the final
matched whole-suite comparison. Indexed resume/drift, bootstrapped table
discovery, release-binary verification and the recovery adapter remain explicit
retirement gates even where ordinary positive cases now share named assertions.
