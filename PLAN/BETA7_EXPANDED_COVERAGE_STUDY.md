# Beta.7 expanded coverage study

## Status

The proposed duplicate coverage run was not started. The local
`study/beta7-test-coverage` branch was not pushed. This proposal is superseded by
[the single instrumented suite](BETA7_SINGLE_TEST_BUILD.md). Keep the measurements
below as historical input. Do not run the old study script under `artifacts/`.

GitHub's latest completed CI run is
[39509695777](https://github.com/GannettDigital/mysql-replicator/actions/runs/39509695777),
at main commit `35fd687b77730f4cb9e9c7b558716d56592bf7df`. It passed all 2,085
catalog obligations for that revision. It collected selected coverage from
nine groups and 23 fixtures. It did not measure the full suite's runtime lines.

## What the available report tells us

These times sum release execution groups across profiles and variants. They are
runner cost, not elapsed workflow time. Source and test changes since that run
prevent a direct current-coverage comparison.

| Area | Release runner-minutes | Groups | Instrumented groups in that run |
|---|---:|---:|---:|
| DDL | 385.5 | 20 | 0 |
| DML | 309.6 | 60 | 0 |
| Bootstrap | 207.8 | 20 | 0 |
| Indexes and column changes | 128.2 | 40 | 0 |
| Foreign keys | 55.5 | 4 | 0 |
| Ordered DDL | 38.8 | 10 | 0 |

The longest DDL jobs took about 31–40 minutes. They need a timing review, but
this report does not show whether they add few or many runtime lines.

The older [expanded review](FULL_SUITE_REORGANIZATION.md) identified indexes and
column changes as a high-cost area with few exclusive lines. Use that finding
to choose a candidate for inspection. Do not use it to remove current cases:
that report mapped 7,469 runtime lines, the latest main run mapped 17,849, and
the current local comparison mapped 20,852.

DML and bootstrap can reach the same Swift lines while testing different
behavior. Bootstrap discovers existing tables from fresh state; DML applies
changes during replication. Rust decoding is not included in Swift line
coverage. Keep these checks unless the behavior and assertions are retained.

## Read and verify the results

1. Confirm the run's `headSha` equals the study commit and that full coverage
   was selected. Save the run ID and attempt.
2. Download `ci-measurement-report` first. Read `summary.md`, `report.json` and
   `test-value.json`. Check all planned groups, catalog obligations and coverage
   collection counts. Missing groups are not evidence of zero cost or coverage.
3. Use the current unit report when subtracting unit coverage. Check matching
   source hashes. The new full plan has no repeated PR-baseline groups. Use exclusive lines
   after unit subtraction.
4. Start with indexes and column changes. Inspect exact exclusive lines after
   unit subtraction, then inspect the assertions and SQL for the groups that
   reach them. Review DDL separately for its long execution time.
5. For a small line gain, find a focused unit check or an existing integration
   case that can retain the behavior. Keep version, engine, transport, restart,
   error and schema-history checks. Whole-group coverage does not identify the
   responsible case; use focused local runs to establish that relationship.
6. Measure only the proposed replacement locally, using the current coverage
   image and matching inputs. Compare line sets and saved results before changing
   CI selection. Leave the full database suite to GitHub.

If a test fails, inspect its support bundle before rerunning it. Fix and rerun
only the affected local case. Do not use an incomplete full report to
justify test removal. Job timing can be unavailable when the GitHub API fails;
use recorded execution-group times and keep that limit explicit.

## Decision to make after the run

Select one area with high measured cost and a small number of extra paths.
For each proposed removal, record the exact replacement cases, assertions,
profiles and line locations. If no group meets that condition, retain the cases
and optimize setup, query cost or job balance instead. Select the final short PR
case lists after this review.

## Local files

The ignored directory `artifacts/next-coverage-review/` contains:

- `main-report/`: the latest main timing and selected-coverage report.
- `main-workflow.yml`: the checked manual-dispatch inputs on GitHub main.
- `study.json` and `expanded-plan.json`: the pinned revision and planned counts.
- `start.sh`: obsolete dispatch script; do not use it.

The preceding local measurements are in
[BETA7_COVERAGE_SAMPLE_COMPARISON.md](BETA7_COVERAGE_SAMPLE_COMPARISON.md).
