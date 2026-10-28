# SQL tests with source GTID preservation disabled

## Decision and scope

Implementation is complete. Focused validation results follow below.

Combine the two SQL selections for `without-source-gtids` into one group per
profile. Name the group `source-gtid-preservation-disabled`. Keep the variant ID
for existing commands. It means `target.preserveSourceGTIDs=false`. The source
still uses GTIDs. SQLite records source GTIDs; the target assigns its own GTIDs.

Keep all three case IDs and their current profile rules. Do not remove assertions
because code coverage overlaps. Keep BINLOG transport selections separate.
They already combine basic DML and generated columns, but that is not proof that
the proposed SQL selection passes.

This follows the [overall execution plan](BETA7_TEST_SUITE_CONSOLIDATION.md#current-execution-plan-after-the-modify-pilot)
and the [table/column/index review](BETA7_TABLE_COLUMN_INDEX_REVIEW.md).
The generated-expression and column-swap phase changes are committed as
`99fb9d6`. This review changes no test code or matrix selection.

## Saved measurements

Source: passing CI run `40454033524`, commit `efb3458`. Read its measurement
`summary.md` and `report.json`, then the eight SQL job records under
`artifacts/ci-review/40454033524/jobs/`.

K = `keys-rows-gtids`. G = `table-column-index-changes`.
Each row below used one fixture and one coverage collection.

| Profile | Selection | Lab seconds | Test seconds | Setup seconds | Cleanup seconds | Harness SQL calls |
|---|---|---:|---:|---:|---:|---:|
| 5.7 → 5.7 InnoDB | K | 48.5 | 8.3 | 11.1 | 10.6 | 87 |
| 5.7 → 5.7 InnoDB | G | 62.5 | 19.5 | 11.8 | 10.5 | 176 |
| 5.7 → 5.7 MyISAM | K | 60.0 | 9.3 | 16.6 | 11.0 | 102 |
| 5.7 → 5.7 MyISAM | G | 57.1 | 15.9 | 11.5 | 10.6 | 191 |
| 5.7 → 8.4 InnoDB | K | 53.9 | 9.3 | 11.8 | 10.6 | 87 |
| 5.7 → 8.4 InnoDB | G | 62.5 | 17.0 | 15.5 | 10.6 | 176 |
| 8.4 → 5.7 MyISAM | K | 92.7 | 42.5 | 13.1 | 10.9 | 240 |
| 8.4 → 5.7 MyISAM | G | 65.2 | 19.9 | 12.4 | 10.5 | 194 |

K selects `positive`. On the 8.4 source it also selects
`ddl-compat-tagged-gtids`. G selects only `ddl-compat-generated`.
Test seconds exclude setup, cleanup, coverage export and other harness work.
SQL calls include setup, waits and assertions. They are not applier statements.
Lab seconds are not total GitHub job time. Removing one setup/cleanup cycle per
profile should reduce runner time. The saving and the longest job time remain
unmeasured. Combining jobs can increase the duration of an individual job.

The recorded executed-line sets also contain distinct lines on both sides:

| Profile | K lines | G lines | Shared lines | K-only lines | G-only lines | Union |
|---|---:|---:|---:|---:|---:|---:|
| 5.7 → 5.7 InnoDB | 6,696 | 7,619 | 6,558 | 138 | 1,061 | 7,757 |
| 5.7 → 5.7 MyISAM | 6,628 | 7,368 | 6,490 | 138 | 878 | 7,506 |
| 5.7 → 8.4 InnoDB | 6,716 | 7,650 | 6,578 | 138 | 1,072 | 7,788 |
| 8.4 → 5.7 MyISAM | 8,230 | 7,334 | 7,036 | 1,194 | 298 | 8,528 |

These counts use each job record's `coverage.hit` set of source paths and line
numbers. Each pair has the same source digest. “Only” is relative to the other
job in that pair, not to the full suite. The counts include shared runner paths
and do not attribute lines to individual assertions. They support retaining
both selections. Compare the new combined line set with the old union after
implementation. Explain differences; do not require identical line numbers
across different runtime source revisions.

## Assertions and execution boundaries

| Case | Retain | Required boundary |
|---|---|---|
| `positive` | Four applied transactions and four row operations; source/native/target row values and normalized binlog operations; target GTID delta excludes source GTIDs; STOPPED checkpoint with exact source position and GTID set; four DONE row intents; saved target UUID; literal-password configuration. MyISAM SQL also checks three target metadata reads. | Use its separate state directory and count-limited applier. It must stop by itself after four transactions. Capture fresh binlog boundaries for this case. |
| `ddl-compat-generated` | Stored and virtual generated values after INSERT and UPDATE; NULL values; ADD generated column; subsequent INSERT and DELETE results. Retain source transaction counts, applied GTIDs and completed DDL intents. | Use the main applier. Keep observations before later DML removes or changes the rows. Keep the saved-schema restart check. |
| `ddl-compat-tagged-gtids` | Blue and green tag identities; two live restarts; binlog rotation; ordinary and tagged writes; six applied tagged groups; two DONE tagged DDL intents; independent `blue:1-3` and `green:1-3` counters. Keep offline stop at `uuid:green:1`, resume without a reachable source, exact final GTID set and row comparison. | Only the 8.4-source profile. Stop the live writer before replay resets the target test schema. Restore the live configuration before its next start. |

`SharedBootstrapDML.basicDML` already takes fresh boundaries. Its GTID check uses
the case delta, not the target's complete executed set. Earlier DDL and replay
therefore need not clear the target GTID history. `LabIsolatedApply` copies the
fixture configuration and keeps preservation disabled. Its client container
uses the existing database fixture; it does not start another Compose project.

`DDLReplayWorkflow` restores the live configuration. With preservation disabled,
it does not reset the target's binlogs or executed GTIDs. Its unlogged schema
reset and replay restore the expected final table before the live writer resumes.
These boundaries must remain visible in the test results.

## Proposed combined order

Use one `SharedCorrectness` invocation and one fixture per profile:

1. Prepare the database containers and configuration once.
2. Start the main applier. On the 8.4 source, run the tagged-GTID case first.
   Keep its explicit live restarts, rotation and offline stop/resume checks.
3. Run the generated-column case. Keep its intermediate value comparisons.
4. Drain the main applier. Check completed intents, then run the existing
   saved-schema restart and following write. Stop it before isolated work.
5. Run `positive` with its own state and four-transaction stop limit.
6. Collect all process coverage once. Clean up the fixture once.

This is the current runner's order for the combined selection. Do not concatenate
two lab commands in one CI job. That would repeat fixture setup. Do not force
one applier process across the explicit stop/restart checks. Ordinary DDL uses
the main applier; lifecycle tests retain their separate boundaries.

## Planner change

Add an explicit variant-specific SQL group selection in `tools/ci_matrix.json`.
It must span the existing feature areas. Keep scenario IDs in policy data, not
in Python conditions. Resolve dependencies and profile applicability through
the existing catalog. Leave all other variant selections unchanged.

The planner currently keeps this variant together only within each area.
Replace that special case with policy-driven grouping. Validate unknown cases,
duplicate assignment, missing owners and dependencies. Reject an applicable
case omitted from a complete variant selection. Each catalog obligation must
still have exactly one SQL owner. Preserve separate BINLOG jobs and their
non-owner status.

Current generated plan: 187 jobs, 1,545 catalog obligations and 186 coverage
collections. The proposed change removes four jobs and four collections:
183 jobs, the same 1,545 obligations, and 182 collections. Regenerate the plan
and growth projections to confirm these numbers. Keep the short PR selection
unchanged. Final PR selection remains a later step in the overall plan.

## Focused validation for implementation

- Run planner and selection unit tests. Assert the selected case set for all
  four profiles, unchanged obligations and BINLOG jobs, and no duplicate owners.
- Run the combined SQL selection locally on 8.4 → 5.7 MyISAM with coverage.
  It includes all three cases and the tagged replay-to-live transition.
- Run the combined SQL selection on 5.7 → 8.4 InnoDB with coverage. It checks
  the two-case selection and the transactional target. Do not run the other
  profiles locally unless these checks expose a profile-specific issue.
- Check one fixture setup/cleanup record per run, all named case results,
  count-limited STOPPED state, GTID assertions, coverage export and failure
  artifact paths. Use a support bundle first if a case fails.
- Compare calls and phase timings with the saved records. Local and CI hosts
  differ; do not report their elapsed-time difference as a measured speedup.
  Leave the remaining profiles and full-suite comparison to the next planned CI.

This review required no build or container run. The implementation must not
change source SQL, expected rows or stop/restart assertions to obtain a lower
job count.

## Implementation results

The review plan is committed as `408c044`. The implementation adds
`correctness_variant_groups` to the CI policy. It replaces the Python condition
that kept this variant together only within each feature area. No Swift case,
source SQL, expected result or runtime code changed in this slice.

All 80 focused Python checks passed: 30 matrix, 12 group-selection, 11 case-selection,
9 job-planning and 18 CI-runner tests. The full catalog plan passed ownership,
dependency, feature, migration and growth checks without starting containers.
It has 183 jobs, 1,545 obligations and 182 coverage collections. Comparing old
and new planners against the same catalog confirms that the other 179 execution
groups are unchanged, including BINLOG selections. The PR case list is unchanged.
The largest one-extra-profile model now has 250 jobs. The one-extra-source-variant
model has 246 jobs. These are separate planning scenarios, not additional runs.

The two combined SQL selections passed with existing coverage images:

| Profile | Cases | Fixture setups / cleanups | Saved CI SQL calls | Local SQL calls | Old union of executed lines | New executed lines | Old lines absent |
|---|---:|---:|---:|---:|---:|---:|---:|
| 8.4 → 5.7 MyISAM | 3 | 1 / 1 | 434 | 346 | 8,528 | 8,540 | 0 |
| 5.7 → 8.4 InnoDB | 2 | 1 / 1 | 263 | 201 | 7,788 | 7,788 | 0 |

The full source digests differ because the harness changed since the saved run.
The comparison reconstructed source hashes from `efb3458` and verified them
against the saved measurement digest. All runtime Swift source hashes match the
local coverage report after excluding `Sources/ReplicatorLab*`. The line-set
comparison therefore uses unchanged runtime source. All 20,880 mapped runtime
lines remain. The local InnoDB set equals its old union. The forward set contains
its old union plus 12 lines. No old covered runtime line was lost.

All selected case assertions passed. Both runs checked the saved-schema restart,
final row comparisons and clean state. Both isolated basic DML runs stopped at
four transactions and four row operations. Their binlog, target-GTID and SQLite
checks passed. The forward run also passed tagged rotation, live restarts and
offline stop/resume. Coverage export and fixture cleanup passed in both runs.

| Profile | Setup seconds | Case seconds | Coverage export seconds | Cleanup seconds |
|---|---:|---:|---:|---:|
| 8.4 → 5.7 MyISAM | 23.5 | 83.4 | 25.3 | 13.1 |
| 5.7 → 8.4 InnoDB | 28.4 | 45.1 | 10.3 | 11.9 |

Case seconds sum the selected case bodies. They exclude other runner work.
The old timings came from GitHub Actions; these came from a local host. Do not
claim an elapsed-time saving from this comparison. SQL call differences also
include the intervening harness improvements. This slice proves one shared
fixture, retained assertions and retained executed runtime lines.

Evidence:

- `artifacts/lab/20261028T210905Z-2b8108d8/result.json` — forward MyISAM.
- `artifacts/lab/20261028T211408Z-76264cc7/result.json` — InnoDB target.
- `artifacts/gtid-preservation-group-review/results.json` and `summarize.py` —
  SQL counts, phase times, source-hash verification and exact line differences.
- `artifacts/ci/matrix.json` — updated full plan.

The test guide now gives the group name and commands for one profile or the
matrix. No application or image build was needed. No other local integration
selection or full suite ran. Leave the other two profiles and full-suite
interaction checks to the next planned CI run.

Next: return to the remaining table/column work. Review column renames, compound
ALTER TABLE renames, multi-table RENAME and cross-schema relationships for shared
execution phases. Retain distinct engine/version rules and intermediate checks.
Use the saved run for that review; do not start containers until its next
implementation slice and validation scope are defined.
