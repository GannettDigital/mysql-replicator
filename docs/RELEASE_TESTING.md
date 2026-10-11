# Release testing

Use one test catalog and one CI workflow. Select the test scope for the change.
Do not add a separate release test runner.

| Use | Trigger | Scope | Release evidence |
| --- | --- | --- | --- |
| Ordinary PR | Open, push or reopen | Unit tests, Periphery and two parallel engine smoke suites | No |
| Final PR in a release stack | Add `ci-full`; later pushes keep this scope | Full catalog, packages, coverage and Periphery | Candidate evidence |
| Test-suite investigation | Add `ci-expanded-coverage` | Full suite plus instrumented correctness and reconnect copies | Candidate evidence from release-binary checks |
| Main | Push after merge | Same full suite | Required for the release |
| Manual investigation | Dispatch with `suite=full` | Same full suite; expanded coverage is optional | Candidate evidence |
| Draft release | Push the release tag after main passes | Verify and copy the tested packages | Verify main evidence; no rebuild |

The full suite runs for all four profiles. It uses the existing shared lab.
Current catalog counts are:

| Profile | Applicable catalog obligations |
| --- | ---: |
| `mysql84-to-mysql57-myisam` | 366 |
| `mysql57-to-mysql84-innodb` | 118 |
| `mysql57-to-mysql57-myisam` | 116 |
| `mysql57-to-mysql57-innodb` | 118 |

An obligation is a case for one profile, suite and capture variant. These counts
measure our catalog. They do not measure all MySQL features.

Full CI has 120 shards, 718 obligations and 23 integration coverage collections.
It includes database creation, DDL, DML, indexes, bootstrap, foreign keys where
supported, refusals, ordered DDL, collation, filtering and discovery. It also
includes failure/recovery/offline/control sequences, reconnect, native-reference
DDL and demos. Capture variants run where the catalog marks them applicable.
The generated `ci-lab/matrix.json` is the authority when these counts change.
No test family was removed for this release model.

The workflow builds the lab once and each applier image once. It runs up to 16
integration jobs at the same time. Each job name shows profile, area, variant
and image. Stateful case sequences stay in one fixture. Unit tests and Periphery
run in parallel with the build path after scope selection.

## Test a stack before merge

Add the label to the top PR that contains the complete release candidate.
Create the repository label once if it does not exist:

```sh
gh label create ci-full --color 5319e7 --description 'Run the full shared release test suite'
gh pr edit <top-pr-number> --add-label ci-full
```

Use a maintainer account. Adding the label starts full CI. Each later push to that
PR starts full CI again. Remove both CI labels to restore smoke checks. Changes to `ci-full` or
`ci-expanded-coverage` start CI. Other label changes do not start test jobs or
cancel the active test run.
If a new PR becomes the top of the stack, put the label on that PR. Labels do not
move between PRs automatically.

Wait for **Full Suite / Release Evidence** and all required checks to pass before
merging the final candidate. Keep the run link with the release notes for review.
A normal smoke run does not produce release evidence. Do not require the full
check on every PR through branch protection; ordinary PRs intentionally skip it.

The PR run tests GitHub's merge commit for that PR and its current base branch.
It does not certify a future merge into main. If a lower stack layer changes,
update the top branch and run full CI again. A result for an old commit is stale.
After merge, wait for full CI on the exact final main commit. Do not substitute
candidate evidence because the source trees appear equivalent.

## Measure the full suite on a PR

Create the diagnostic label once, then add it to the top PR:

```sh
gh label create ci-expanded-coverage --color 1d76db --description 'Measure full-suite Swift coverage; retain release checks'
gh pr edit <top-pr-number> --add-label ci-full --add-label ci-expanded-coverage
```

The expanded label implies the full suite, even without `ci-full`. It adds
instrumented copies of shared correctness and lifecycle jobs. It keeps all
release-binary jobs. Coverage builds are not release artifacts. Remove only
`ci-expanded-coverage` to return to normal full CI while `ci-full` remains.

Read the scope counts in the coverage summary. Use the measurement artifact's
`test-value.md`, `test-value.csv` and `test-value.json` to compare cost and added
line coverage by profile, variant and area. These files include declared case
intent for an assertion review. See [measurement scope](CI_MEASUREMENTS.md).

## Run the full suite manually

After the workflow is available on main:

```sh
gh workflow run ci.yml --ref <branch-or-tag> -f suite=full
```

For code coverage research, add `-f expanded_coverage=true`. This retains all
release-binary assertions and adds instrumented correctness and lifecycle runs.
The current expanded plan has 227 shards and 130 integration collections. It
covers the same 718 obligations. Expanded coverage measures test-suite behavior.
It is not an extra release gate. Use the full plan without expanded coverage for
routine release checks.

Use `-f suite=pr-smoke` for a manual smoke check. Expanded coverage requires
`suite=full`. A manual run does not replace the required main push run.

## Review and retain evidence

Read `ci-measurement-report/summary.md` first. Check all four profile totals.
Use `report.json` for missing cases, shard time and code coverage. Inspect the
failed case's support bundle before a rerun. See [test lab](TEST_LAB.md).

A complete full run produces the `release-test-evidence` artifact. Its
`release-test-evidence.json` file records:

- Repository, tested commit, run ID, attempt and run link.
- Event, ref, release version and full test scope.
- Passed catalog totals and coverage collections for each profile.
- Results for unit tests, builds/integration, coverage, Periphery and measurements.
- SHA-256 of the tested packages' `SHA256SUMS` file.

This file links evidence to packages. It is not a cryptographic signature.
The release workflow checks the successful main CI run through the GitHub API.
It then checks the evidence identity, full scope, package manifest digest and
package checksums. It adds the evidence file to the draft release downloads.
Missing evidence, another run attempt or different packages stop draft creation.

Use **Re-run all jobs** to replace incomplete evidence. Do not combine artifacts
from different attempts. If release artifacts expire, rerun all jobs of the
original main push run for the tagged commit. Do not use a local rebuild.

## Why this model

A full run on every stack layer repeats expensive checks before the complete
change is ready. A full run on the top PR finds integration defects before merge.
Main then certifies the exact commit and packages that the release will publish.
New main pushes cancel obsolete main runs through the existing CI concurrency
policy. Do not suppress the final main run to save cache or test time.

Draft releases do not trigger `created`, `edited` or `deleted` Actions events.
The `published` event runs after publication, which is too late for qualification.
Keep draft creation as artifact promotion after testing. Keep image publication
as the existing `release: published` action.

The new PR can import GHCR layers from its base PR. Compare the same image's build
steps and transfer times with that base run. A new release image can still need a
cold build if the base ran smoke only. A full suite has more jobs than smoke;
total workflow time is not a cache comparison. Use the normal CI build job
times and Docker logs to assess cache reuse.

GitHub references:

- [Release events and draft limits](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#release).
- [PR merge commit behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request).
- [Manual workflow runs](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow).
