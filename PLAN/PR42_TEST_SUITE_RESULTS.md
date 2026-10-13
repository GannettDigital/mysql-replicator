# PR #42 results and remaining long tests

## Evidence and scope

Compare PR #41, run [38193142028](https://github.com/GannettDigital/mysql-replicator/actions/runs/38193142028),
with PR #42, run [38204190176](https://github.com/GannettDigital/mysql-replicator/actions/runs/38204190176).
Use the successful full runs with expanded coverage. Cancelled label-triggered
runs are not part of this comparison.

PR #42 tested merge commit `b341bf6d67b956df785990c0601dd9b817c270c8`.
Its head was `f6b899bd4e7aa4f53438d68044a65843b88a0ce9`.
Local evidence is in `artifacts/ci/pr41-analysis/` and
`artifacts/ci/pr42-analysis/`. These directories are ignored by Git.
Read `ci-measurement-report/report.json`, `test-value.json`, and the individual
`line-maps/ci-measurement-coverage-*` records to reproduce the comparison.

This review covers timing, test assertions, and safe job boundaries. It does not
change test selection. The PR subset remains a later task.

## Result of the new DDL and bootstrap groups

All 718 catalog obligations passed. All 118 expected coverage collections arrived.
The integration line set is unchanged at 6,811 of 7,469 Swift runtime lines.
The combined unit and integration line set is unchanged at 7,255 lines, or 97.13%.
The coverage source digest is identical between the two runs.
These measurements exclude Rust and lab code.

| Measurement | PR #41 | PR #42 |
|---|---:|---:|
| Expanded integration jobs | 227 | 203 |
| Release DDL shard minutes | 39.5 | 33.4 |
| Release bootstrap shard minutes | 54.8 | 48.3 |
| All release shard minutes | 313.4 | 304.5 |
| All coverage shard minutes | 343.9 | 334.2 |
| Completed runner-minutes in the report | 804.5 | 766.8 |
| Recorded job span, minutes | 60.2 | 54.1 |

Runner-minutes are the sum across jobs. They are not elapsed time. The recorded
span ends at the last completed job in the measurement report. It excludes later
reporting work. Release and coverage builds were faster in PR #42. Do not assign
the full elapsed-time reduction to the new test groups.

All 24 changed DDL jobs finished within five minutes. Of the 24 bootstrap jobs,
20 finished within five minutes. Three took 302, 306, and 311 seconds. The reverse
bootstrap-1 coverage job took 431 seconds, including 394 seconds in the shard.
All eight root cases were slower in that job. SQL-client time was 117 seconds,
compared with 51 seconds for the same-version InnoDB bootstrap-1 coverage job.
SQL-client time includes process startup and query time. It is not applier time.
The evidence does not establish the cause of this isolated slowdown.

Keep the new groups. Do not split bootstrap again from this one observation.

## Remaining long areas

These are shard seconds, before extra CI job overhead. Coverage rows use the
instrumented binary. Native and specialized InnoDB recovery use release jobs.

| Selection | PR #41 seconds | PR #42 seconds |
|---|---:|---:|
| Forward default failure/recovery/offline, coverage | 393 | 400 |
| Forward GTID-full failure/recovery/offline, coverage | 389 | 371 |
| Forward position-minimal failures, coverage | 221 | 214 |
| Same-version MyISAM failure/recovery/offline, coverage | 243 | 234 |
| Reverse InnoDB offline/control, coverage | 138 | 126 |
| Same-version InnoDB offline/control, coverage | 117 | 112 |
| Forward demo | 310 | 310 |
| Same-version MyISAM demo | 263 | 284 |
| Reverse InnoDB demo | 370 | 346 |
| Same-version InnoDB demo | 318 | 323 |
| Native DDL | 239 | 325 |
| Reverse specialized InnoDB recovery | 71 | 69 |
| Same-version specialized InnoDB recovery | 62 | 59 |

The slow same-version MyISAM DML coverage job is a separate issue. It took 512
seconds, but 311 seconds were in `Set up job`. Its shared-test step took 185
seconds. Do not repartition its tests because of that setup delay.

## Assertion review

### Failure, recovery, and offline workflows

The area has 541 exclusive integration lines in both runs. Different profiles
can hit the same lines while testing different storage-engine behavior.

| Root case | Distinct checks | Decision |
|---|---|---|
| `forward-failures` | Trigger/event policy, generated-value mismatch, target triggers, index errors, uncertain DDL timeout, permission errors, pending intents, unchanged checkpoints, blocked following writes, and native error codes | Keep the complete workflow. Its restricted grants and deliberate divergence differ from successful DDL cases. |
| `myisam-recovery` | Exact row bytes, multi-row/key-change binlogs, discovery, 160-table capacity, composite-key resume, schema cache, partial writes, mid-group SIGKILL, and refused automatic replay | Keep the complete workflow. Shared inputs do not replace its intermediate state and crash assertions. |
| `offline-replay` | Fetch, rotation, raw external archives, replay without source credentials, partial stop/resume, exact checkpoint, and support-bundle contents | Keep. Live replication does not replace this path. |
| `offline-skip-errors` | Offline error-skip policy and durable outcomes | Keep. The live skip selection runs separately in the refusal area. |
| `runtime-control` | Exact GTID stop, reload during issued work, rejected reseeding, acknowledged drain, and resume | Keep. The target locks create an active batch for reload and stop checks. Do not shorten the waits without replacing the synchronization. |

`SharedForwardFailures` restores target grants and reseeds the native reference.
`SharedMyISAMRecovery` resets its own tables and initializes its own saved state.
Offline and control cases also create their own fixtures inside the shared server
set. There is a reasonable boundary between the complete forward-failure workflow
and the recovery/offline workflows. Keep each workflow's internal order intact.

The current catalog order differs from execution order. Do not use a numeric
case-count split here. Use named families: `failures` and `recovery` + `offline`.
This creates an extra group only for forward default and GTID-full. The
position-minimal selection has failures only. Other profiles have no
`forward-failures` case.

Using the two runs' root-case times and retaining the full measured residual
for each new fixture gives these estimates:

| Proposed group | Estimated shard seconds |
|---|---:|
| Forward failures | 214–228 |
| Forward recovery and offline/control | 245–263 |

The residual is shard time minus selected root-case time. It includes setup,
common resume checks, cleanup, and coverage export. It is not pure startup time.
These are estimates, not results from the proposed split. Extra job overhead
still applies, so five minutes is a target, not a guaranteed limit.

The split adds two release jobs and two coverage jobs. It is likely to add about
86–91 seconds per affected coverage fixture. It reduces the longest job at the
cost of more runner-minutes. Validate the isolated workflows locally before CI.

### Demo workflows

The demo area has 398 exclusive integration lines in both runs. It checks
operator commands and state retention, not only successful row application.

`LabDemoQualification.Run.execute` already uses independent sessions:

- `workbook`: prepared shell, pinned image, repeated setup, manual start, idle
  heartbeats, and workbook DDL/DML. MyISAM also checks blocked DDL, exact skip,
  following writes, and MODIFY/index operations in this session.
- `container-repair`: replace a missing shell without changing data or checkpoint.
- `idle-resume`: SIGINT before writes and resume from the saved baseline.
- `position-resume`: SIGTERM after writes and resume from the saved applied
  position or GTID set. Repeated resume must preserve counters and schemas.
- `reverse-workbook`, on InnoDB: composite-key transactions, repaired-shell
  resume, rollback, inspection, and audited retry.

Each session already creates and removes its own server fixture. Split the job
at these session boundaries. Do not split the workbook's dependent cases.

| Proposed job area | Sessions | Coverage collections per profile |
|---|---|---:|
| `demo-workbook-repair` | `workbook`, `container-repair` | 2 |
| `demo-resume-recovery` | `idle-resume`, `position-resume`, plus InnoDB `reverse-workbook` | 2 for MyISAM; 3 for InnoDB |

Both groups must select their complete applicable case lists and dependency
closure. Do not use the current `workbook` family alone: its dependencies cross
the lifecycle and failure families. Keep the 35-second idle-heartbeat check.
It is an explicit behavior test, not an arbitrary delay to remove.

This change adds four jobs but no database fixtures or coverage collections.
It adds CI checkout, image-load, and artifact overhead. It can reduce elapsed
job time without a comparable increase in database setup work.

The measured demo residual is 113–190 seconds per complete job. The report does
not divide that time by session. If that residual is allocated equally among
the existing sessions, the proposed groups take about 109–222 shard seconds.
This is a rough estimate only. Add session setup/body/cleanup timing to validate
it. Do not treat root-case time alone as the cost of a demo session.

Demo observations also use separate SQL calls for schema, database encoding,
engines, table presence, column presence, and rows. They do not yet use the
metadata batching from shared correctness. This is a later transport-cost
candidate. Keep comparison boundaries and exact-byte row checks. First export
the existing SQL-client counters from each demo fixture.

### Native DDL and specialized InnoDB recovery

Keep these tests. Native DDL compares source acceptance, direct 5.7 execution,
and native 8.4 replication. It checks warnings, rejected statements that must
not create binlog events, database defaults, CREATE LIKE inheritance, and engine
restrictions. Successful external-apply tests do not replace these observations.

`NativeDDLQualification.run` creates two independent fixtures: unrestricted
engines and InnoDB disabled on the replicas. The restriction changes the expected
behavior of explicit and default engines. These are distinct configurations.

The aggregate CI record represents both fixtures as one `native` catalog item.
Per-case results exist in fixture evidence, but the measurement summary does not
expose their policy-specific timings. The increase from 239 to 325 seconds does
not identify a slow case. First export setup, body, cleanup, SQL-client cost,
and child-case times for each engine policy. A later split can run these two
existing fixtures in parallel without creating more fixtures.

Native DDL does not run the applier. Its missing applier coverage is expected.
Do not rank it as a zero-coverage test. Specialized InnoDB recovery checks
rollback, inspection, and audited retry through its dedicated runner. It takes
about one minute per profile. Keep it intact; it is not a long-job priority.

## Recommended implementation order

These options are now deferred. See [future CI optimizations](CI_FUTURE_OPTIMIZATIONS.md).
The current task selects PR checks and keeps the full-suite job structure.

1. Split demos at the existing session boundaries. Record each session's setup,
   body, cleanup, and SQL-client cost. Keep expected coverage collections tied
   to the selected sessions, rather than one total per profile.
2. Separate complete forward failures from recovery/offline workflows. Keep the
   smaller profile selections together. Accept the extra setup cost explicitly.
3. Add native engine-policy timing and child-case reporting. Keep native job
   selection unchanged until the next measurement identifies its cost.
4. Run full CI with expanded coverage. Compare exact catalog keys, per-area and
   per-profile line sets, session counts, job duration, and runner-minutes.
5. Then choose explicit PR cases and assess the sample/smoke supplements.

Steps 1 and 2 would change normal full CI from 108 to 114 integration jobs and
expanded CI from 203 to 211. Expected expanded coverage collections would change
from 118 to 120. All 718 catalog obligations must remain. Native catalog
granularity remains unchanged in this proposal.

A local simulation against the generated PR #42 expanded matrix confirms 211
jobs and 120 collections. Every selected case keeps the same execution count
for its image, profile, variant, and suite. Each proposed job contains its
declared prerequisites. This validates the proposed selection only. It does not
prove fixture independence at runtime. The simulation result is saved as
`artifacts/ci/pr42-analysis/proposed-groups-check.json`.

There is no evidence in this review to delete a slow workflow as a duplicate.
No runtime code, test assertions, matrix selection, or wait duration changed
during this review.
