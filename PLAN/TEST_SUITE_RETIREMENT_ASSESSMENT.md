# Legacy DDL/DML runner retirement

The duplicate DML/DDL runners are removed. Their 442 case executions have passing
shared replacements, the same 68 named catalog obligations are accepted, and no
runtime lines are lost in either historical capture variant. Forward union line
coverage increased from 80.59% to 80.81% on the same 5,858-line runtime.

Full forward and reverse qualification passed before removal. Final-tree checks,
including Periphery, shared integration/recovery, fresh coverage/catalog export
and exact release-executable verification, also passed. See **Completed retirement
and final-tree validation** below and the [replacement map](TEST_SUITE_RETIREMENT_MAP.md).
Native observations, reverse audited recovery, demos, protocol qualification and
benchmarks retain their specialized runners; this migration does not establish
that they are redundant.

The assessments and failed attempts below are historical checkpoints, retained
as an audit trail. Their pending-work statements describe those checkpoints.

## Initial assessment (historical)

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

## Ordered DDL and collation checkpoint

The next increment ports the full 70-step ordered lifecycle as shared `ddl`,
including conditional no-ops, differing preexisting definitions, cross-schema
LIKE/defaults, schema history, following DML and normalized binlogs. The native
and target schemas preserve their separate database defaults. Forward collation
workflows preserve rewrite audits, CREATE LIKE / INSERT SELECT / multi-table
RENAME, changed/removed policy refusal on restart and PAD collision behavior.

The selected forward positional run passed 76 reported cases, including the
ordered parent/70 children and five collation invocations; the reverse ordered
run passed 71. Both cleaned up successfully. These are executions, not distinct
MySQL feature counts. The forward ordered bundle accepted 22/730 named catalog
obligations; this selection did not include the database/MODIFY/index bindings.
All ordered bindings now accept the same named shared assertions, preserving the
potential 68 previously evidenced obligations and the unchanged denominator.

Artifacts are in `artifacts/coverage-migration/retirement-work/ordered-checkpoint/`:
run references, checksums in the catalog report, logs, source snapshots and the
exact remaining line list. The selected forward run observed 74 of the 151
remaining original runtime gaps: 44 in DDLRename, 13 in CompatibilityPolicy,
10 in DDL and 7 in TargetSession. **77 original lines remain unobserved** at this
checkpoint. Shipping source hashes match; this is a checklist subtraction across
harness revisions, not a newly matched whole-suite comparison. Reverse hits do
not close forward gaps. The later fixture ports stale these historical bundles
for current-checkout import; retain them without bypassing freshness validation.

Negative/discovery/recovery ports follow this checkpoint. Their presence in the
inventory is not yet retirement evidence. Full matched legacy/shared runs,
assertion mapping, release-binary verification and dispatch-root removal remain
the final gates.

## Negative, discovery and recovery checkpoint

The selected forward GTID/FULL run passed all 64 reported cases and cleanup.
It includes bootstrapped ENUM/SET and composite keys, all 12 metadata/decoder
refusals, index resume/drift, 19 DDL/policy failure children and the 19 MyISAM
discovery/fail-stop children. The reverse sample passed basic DML, both bootstrap
fixtures, database lifecycle and indexed resume/drift. The first attempted
forward bootstrap run caught a fixture session-setting mismatch; role-specific
5.7/8.4 sessions fixed it before accepting these runs.

The successful forward run hit all **77 remaining original runtime lines**.
The original gap checklist is therefore empty, with unchanged shipping source
hashes. This still is not a matched whole-suite comparison: preserve that final
gate. Evidence and exact hashes are under
`artifacts/coverage-migration/retirement-work/failures-checkpoint/`; the full
run is `artifacts/lab/20261007T220442Z-5c442cc2/`. Reverse evidence is
`artifacts/lab/20261007T220645Z-59a98ac1/`. The killed writer retains behavioral
proof and an explicitly unflushed coverage profile.

The shared inventory now declares the individual failure/recovery children and
requires a passing result for each before completing the workflow. Forward
`--suite recovery` uses this shared implementation; reverse recovery remains its
separate adapter. Full correctness already includes the forward group, so
`--suite all` avoids running it again. The [replacement map](TEST_SUITE_RETIREMENT_MAP.md)
describes preserved assertions independently of the line counts. Legacy DDL/DML
runners remain available for the final matched comparison.

## Restart defect exposed by the full comparison

The first full shared GTID run failed after the partition/hash-list sequence:
resume reported `discovered target requires a primary key with 1 to 16 columns`.
SQLite still marked `ddlcompat.stage` current even though the next database
lifecycle had dropped it. On startup `ApplyRun` validated saved schemas without
restoring them into `TargetSession.discovered`; DROP DATABASE builds its schema
retirement transitions from that cache. Tables not rediscovered by a subsequent
row event could therefore remain current in SQLite after their database vanished.

The fix restores each schema to the discovery cache only after verifying it
against the target. The shared database fixture now explicitly stops with two
saved tables, resumes, then drops the database before either table has another
row event. The existing final schema-count and saved-state restart checks must
pass. This preserves drift refusal and adds no metadata query.

The failing aggregate is `artifacts/lab/20261007T222121Z-b0555826/result.json`.
Other same-image comparison runs were interrupted and their disposable fixtures
removed; they are **not accepted evidence**. Their process/project identities are
recorded in `artifacts/coverage-migration/retirement-work/invalid-comparison.json`.
The runtime change invalidates earlier source-hash comparisons for the new tree.
The zero-original-gap result above remains a historical checkpoint; final parity
requires fresh legacy/shared runs on the corrected runtime, without translating
old line numbers or combining old and new source hashes.

A subsequent static review found shared fixture pollution: the replicated DML
matrix leaves `poc.matrix_input`, while the bootstrap SELECT/JOIN fixture creates
that same helper. Bootstrap now recreates its own `poc` snapshot, without logging,
after the continuous writer has drained. Its LOAD DATA output also has a distinct
filename. A focused run selects replicated and bootstrap SELECT/LOAD together.

The high-concurrency legacy DDL attempt also hit its unchanged 20-second capture
startup deadline at `ddl-index-rename`; the retained writer log reached RUNNING.
It is a failed run, not accepted evidence. The remaining attempts were interrupted
before changing fixture inputs, and the next comparison uses lower concurrency.
See `retirement-work/legacy-ddl-startup-timeout.log` and
`retirement-work/invalid-comparison-fixture-isolation.json` under the migration
artifacts. No deadline or behavioral assertion was relaxed.

Focused correction validation passed on both topologies: the database-resume and
partition sequence in `artifacts/lab/20261007T223706Z-8488600e/`, then replicated
and bootstrap SELECT/LOAD together in `artifacts/lab/20261007T225521Z-1878275a/`.
The final comparison uses image
`sha256:ca67cdd684a921ba34875b8b396bbc9b022e423027c9a62c6072b5c349558792`
and input digest `b2c06c9899b618b06d9bbc9c6a4487b7b473173b596d8473621e4a36c363b6a3`.
Its explicit execution matrix and pre-removal patch are saved under
`artifacts/coverage-migration/retirement-work/final-comparison/`. At most three
fixtures run concurrently. The corrected runtime maps 5,858 executable Swift
lines; do not compare that denominator directly with the earlier 5,855-line tree.

## Final comparison: catalog gate

On the corrected, unchanged image above, both full shared forward correctness
variants passed, including cleanup. The legacy DDL variants also passed. Loading
their bundles through the normal freshness/provenance validator accepts exactly
the same set of **68 named scenario/profile/assertion obligations out of 730** in
both producers: 28 partially evidenced scenario/profile combinations, zero fully
verified, and 662 unresolved obligations. The comparison checks identities, not
just equal counts.

The accepted reports and exact obligation list are
`final-comparison/catalog-legacy.json`, `catalog-shared.json` and
`catalog-parity.json` beneath the retirement-work artifacts. At that checkpoint, full legacy DML,
shared lifecycle and reverse correctness were still running; the catalog result
alone did not authorize runner removal.

## Final comparison: runtime and case gate

The four legacy runs and the shared forward correctness/lifecycle runs all passed,
including cleanup, on the same image and 5,858-line runtime. Exact line-set
comparisons have **zero legacy-only lines in each historical variant**, without
using reverse or unit coverage to close gaps:

| Capture variant | Legacy hits | Shared hits | Lost lines | Additional shared lines |
| --- | ---: | ---: | ---: | ---: |
| File-position / MINIMAL | 4,633 | 4,659 | 0 | 26 |
| GTID-only / FULL | 4,700 | 4,713 | 0 | 13 |
| Forward union (also includes default shared lifecycle) | 4,721 | 4,734 | 0 | 13 |

The union changes from 80.59% to 80.81%; this is runtime line coverage, not branch
coverage or MySQL feature completeness. Every one of the **442 legacy case
executions** maps to a passing shared replacement in the same capture variant.
The assertion-level review is in the [replacement map](TEST_SUITE_RETIREMENT_MAP.md).
Both GTID groups retain one explicitly unflushed `batch-crash` profile; SIGKILL
behavioral proof does not manufacture LLVM hits.

The explicit manifests, checksummed input references, line lists and invocation
origins are in `final-comparison/per-variant/`, `final-comparison/combined/`, and
`final-comparison/case-mapping.json`. The earlier DDL-only comparison is an
intermediate subset, not a separate contribution to these totals. Reverse full
correctness subsequently passed with cleanup in
`artifacts/lab/20261007T235944Z-2fca5605/`. The entire execution matrix finished
successfully before removal began.


## Completed retirement and final-tree validation

Removed `DMLQualification`, `SuiteSelection`, their obsolete parser tests,
`dml-suite`/`ddl-suite`, and the `legacy-dml`/`legacy-ddl` adapters. Useful selection
and GTID-count assertions now live with the shared profile tests. Forward
`--suite recovery` uses the shared MyISAM workflow; `--suite all` avoids executing
it twice. The independent fixture/catalog declarations remain in use.

Make, CLI help, CI artifact paths, the release-binary verifier, CONTRIBUTING,
test-lab, reverse-profile and catalog/upstream documentation now use shared
commands. The smoke selection includes the database-drop-after-resume regression.
The release verifier uses the shared `mysql-replicator-packaging:lab` image.

Validation after removing the old dispatch roots:

- **340 Swift unit tests** and **14 tooling tests** passed. Five obsolete parser
  tests were replaced by one shared-selection test; the pre-removal total was 344.
- **Periphery strict scan passed**, with no unused declarations and no new retain
  rules. `DDLCompatibilityCases.independent` is still used by the catalog's
  declarations; it is not an orphan merely because the old selector is gone.
- Catalog structure passed: **63 scenarios, 185 declarations**. Removed CLI
  commands reject execution; the common all-suite JSON inventory has no legacy
  adapters.
- The shared integration sample plus database-resume regression passed (four
  cases), reverse database-resume passed (one), and direct forward recovery passed
  (19 child cases plus its parent), all including cleanup.
- A fresh instrumented ordered-family run passed **71 case results** and exported
  usable coverage on the final tree. Its GTID-only/FULL catalog bundle was accepted
  with **22/730 assertions**, 11 partial scenario/profile combinations and zero
  fully verified. This deliberately selected subset is separate from the full
  pre-removal **68/730 parity** result; no stale bundle was imported or combined
  with it.
- Linux archive and Debian installation/reinstallation checks passed.
  Each final noninstrumented fixture recorded the exact release binary SHA-256:
  `c72f406533ff31b29359434041e7bf1b64916ddf956f8d56f4ea62f1c45025a8`.
- All **55 shipping Swift source hashes** remain identical to the matched full
  comparison after retirement. Only harness/entry-point changes followed that
  comparison; unit/reverse hits never waived a forward coverage gap.

Final result paths, runtime IDs and result checksums are recorded in
`artifacts/coverage-migration/retirement-work/post-removal-validation.json`.
`post-removal-runtime.json` records the runtime-hash equality, and
`catalog-post-removal.json` is the fresh accepted partial report. Unit, tooling,
Periphery, release-build and executable-hash logs are retained alongside them.
The final instrumented run is `artifacts/lab/20261008T010704Z-7fb36787/`.

The full comparison's harness-input hashes necessarily become historical after
removing files. Preserve its manifests, reports and pre-removal patch rather than
bypassing freshness checks. The catalog still has **662 unresolved obligations**;
Rust internals and the deliberately unflushed killed-writer profile remain outside
this Swift line-coverage claim. Those are existing qualification limits, not
coverage silently discarded by retiring the duplicate runners.
