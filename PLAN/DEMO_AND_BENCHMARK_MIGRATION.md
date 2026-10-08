# Demo and benchmark command consolidation

The common entry points are `test`, `demo ACTION --profile PROFILE`, and
`benchmark --profile PROFILE --mode MODE`. Developer/package tooling and the
specialized native/recovery adapters remain separate. The goal is one interactive
demo implementation and one named rehearsal catalog across the two topologies,
with explicit applicability for engine-specific experiments.

## Assertion audit

| Previous coverage | Shared demo case(s) |
| --- | --- |
| Shell/config/password setup, no initialized state, manual launch, idle heartbeat, duplicate start refusal | `demo-prepared`, `demo-start-idle` |
| Forward workbook CREATE SCHEMA/TABLE, DML, ADD COLUMN, exact rows/schema/engine/counters | `demo-success`, on both profiles |
| Native 3161 and external-applier explicit-engine refusal; unchanged checkpoint and following-marker absence; BLOCKED restart refusal | `demo-fail-stop`, forward only |
| Broad skip refusal, exact skip, saved boundary, queued/fresh rows, native still blocked, repeated resume | `demo-skip-and-resume`, forward only |
| Widened VARCHAR, index create/rename/replace, following long-value DML and exact counters | `demo-modify-index`, forward only |
| Idle SIGINT and post-workload SIGTERM: zero exit, shell remains, STOPPED/no diagnostic, unchanged counters/checkpoint | `demo-idle-sigint`, `demo-applied-sigterm`, both profiles |
| Saved GTID-only baseline and applied file-position override changed YAML; queued DDL/DML, repeated resume, reinitialize/concurrent-writer refusal | `demo-resume-baseline-gtid` on both; `demo-resume-applied-position` on forward, `demo-resume-applied-gtid` on reverse |
| Previous shared demo's preloaded-table INSERT/UPDATE, stop/resume and missing-shell repair | `demo-container-repair`, both profiles, separate fixture |
| Reverse composite-PK workbook, missing shell with saved state, later DML | `demo-reverse-workbook`, reverse only |
| Reverse duplicate-key failure, BLOCKED status, inspect pending GTID, conflict removal, audited retry, continued comparison and retained audit details | `demo-reverse-recovery`, reverse only; explicitly checks rollback too |

Dependencies preserve ordered workbook scenarios. Selecting a case also selects
its prerequisites; separate fixture groups prevent shell repair from inserting
checkpoint snapshots into the forward skip/history scenario. The inventory has
14 named cases, 11 applicable to forward and 10 to reverse. No new MySQL catalog
qualification is claimed from demo coverage.

Two intentional user-visible changes are documented in the workbooks: repeated
`up` reuses/repairs a session instead of rejecting it, and `compare` can read the
live checkpoint in its Docker volume without stopping a foreground writer.
Source SQL keeps its actual server defaults, including MySQL 8.4's default
connection collation; a convenience command must not make the workbook easier
than pasting the same SQL manually.

Coverage mode is pinned in the retained-session manifest. Short-lived CLI calls,
manual starts and detached starts use the instrumented image; cleanup exports
coverage and archives state before removing disposable resources. Old session
directories are not adopted. `demo legacy-down --profile PROFILE` exists only to
archive and remove them.

## Benchmark boundary

`backlog` uses the shared profile fixture on either topology. `streaming` and
`capture` retain the forward experiment's existing provisioning, transport and
tuning contracts through `ForwardBenchmarkFixture`. They no longer depend on an
interactive demo runner. Their reports record the selected mode/profile/topology.
The CLI requires an explicit profile, so the presence of `--profile` cannot
silently change which experiment `benchmark` runs. Reverse streaming/capture
remain explicitly unsupported.

See [test lab commands](../docs/TEST_LAB.md), the
[forward workbook](DEMO_WORKBOOK.md), [reverse workbook](REVERSE_DEMO_WORKBOOK.md),
and [benchmark options](PERFORMANCE_BENCHMARK.md).

## Measurement method

Before editing, the lab executable and runtime source hashes were saved under
`artifacts/demo-migration/` at revision
`57a3f5ee4952390e22557219e120dddbc9d37746`.
The legacy forward suite ran all three fixtures with instrumentation. The legacy
reverse suite first passed normally, then ran again using that saved executable
and an image derivative whose sole change enabled `LLVM_PROFILE_FILE`; its
archived profiles were exported using the producing image's LLVM tools.

Runtime line sets are compared separately for each topology. Unit tests and lab
source lines cannot fill a missing integration path. Reports must match current
runtime source hashes and the executable-line denominator; successful assertions
and archived cleanup evidence are checked separately. Image identities differ
because this migration changes harness sources. `artifacts/demo-migration/compare.py`
records exact producing report paths, hashes, invocation labels and line deltas
in `comparison.json`. This one-time audit does not relax the reusable
`tools/compare_test_coverage.py` requirement for a single runtime image.

The initial exploratory shared runs exposed helper argument-order and numeric-YAML
issues, plus gaps caused by overriding source defaults and creating snapshots
while comparing. Those runs are diagnostic evidence, not retirement gates.

The overlapping exploratory runs also exposed Docker image retention: moving the
shared build tag could make a saved image ID unavailable to later CLI containers.
The affected runs were archived and cleaned up separately and remain failed
evidence. Shared builds retain an additional tag derived from the immutable image
ID; rebuilding a profile no longer removes the reference needed by an older
session. These image tags are developer caches, retained after fixture cleanup.

The InnoDB contract requires GTID positioning. Its post-apply resume case therefore
uses `demo-resume-applied-gtid`; the legacy positional case remains forward-only.
The same preparation, queued-DDL/DML, counter and repeat-resume assertions are
shared. Positional startup on reverse is not mislabeled as supported.

## Retirement results (2026-10-07)

The complete shared matrix passed **21 applicable cases** (11 forward, 10 reverse)
and cleanup, with 7 explicit `not_applicable` entries. The focused reverse
workbook/recovery rerun also passed after adding the persisted-audit assertion.
Measurements:

| Profile | Legacy runtime lines hit | Shared runtime lines hit | Lost | Added |
| --- | ---: | ---: | ---: | ---: |
| `mysql84-to-mysql57-myisam` | 3678 | 3736 | 0 | 58 |
| `mysql57-to-mysql84-innodb` | 3402 | 4082 | 0 | 680 |

Both comparisons use the same 5,858 mapped runtime lines and unchanged runtime
source hashes. No unit or cross-profile hits fill gaps. The final shared evidence
is `artifacts/lab/20261008T033529Z-eb495465/`; the focused audit evidence is
`artifacts/lab/20261008T035401Z-a2253893/`. The exact comparison is
`artifacts/demo-migration/comparison.json`.

All four benchmark smoke runs passed and cleaned up: forward two-table mixed
streaming, forward capture with rotation (100 events / 300 decoded rows), and
100-transaction backlog runs on both profiles. These are functional routing/fixture
checks, not new throughput measurements. Evidence:

- Streaming: `artifacts/performance/20261008T031738Z-29aeaba5/20261008T031738Z-b1b7f31c-auto-autocommit-myisam/`.
- Capture: `artifacts/capture-performance/20261008T032115Z-88937de9/20261008T032115Z-13d9093a-auto-autocommit-myisam/`.
- Forward backlog: `artifacts/lab-benchmark/mysql84-to-mysql57-myisam/20261008T033707Z-89a9e1da-auto-autocommit-myisam/`.
- Reverse backlog: `artifacts/lab-benchmark/mysql57-to-mysql84-innodb/20261008T033757Z-c2625ed3-auto-transaction-innodb/`.

With those gates satisfied, `DemoSession.swift` and `ReverseDemo.swift`, their
Make targets and direct dispatch were removed. The CLI gives migration guidance
for the retired names. CI runs the shared instrumented demo matrix instead of
an additional reverse-only legacy rehearsal, and includes its reports in the
existing combined-coverage artifact. Specialized recovery/native tools remain
explicit adapters. Shipping replication code was not changed.

After retiring the runners, the complete Swift unit suite passed (343 tests),
and shared correctness smoke passed all 18 selected cases (9 per profile), with
cleanup, in `artifacts/lab/20261008T035801Z-da596caf/`. The 22 Python tooling tests
also passed. Periphery exposed `readYAML` as newly unused after its last legacy
caller was removed; that helper was deleted too.

The final Swift rerun passed all 343 tests; `make periphery` completed with no
unused code detected. CLI migration errors and profile/mode rejection were also
checked before provisioning.
