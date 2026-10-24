# Release testing

Use one test catalog and one CI workflow. Test the release candidate before merge.
Build production packages after merge. Do not repeat the full suite on main.

| Use | Trigger | Work |
| --- | --- | --- |
| Ordinary PR | Open, push or reopen | [Changed-file selection](PR_TEST_SELECTION.md), unit tests and Periphery where required |
| Final PR in a release stack | Add `ci-full` | Full four-profile suite with coverage |
| Manual full run | Dispatch with `suite=full` | Same full suite with coverage |
| Main | Push after merge | Build packages, check the production binary, match source to full test results |
| Draft release | Push a matching release tag after main passes | Verify and copy the saved packages; no rebuild |

All selected replicator tests use the coverage binary. Native-only observations
run MySQL and do not produce replicator coverage. Performance benchmarks use an
uninstrumented binary. The old `ci-expanded-coverage` label and dispatch input
remain aliases for full coverage. They do not add duplicate runs.

The full plan has 2,095 catalog obligations, 240 execution groups, 125 jobs and
253 integration coverage collections. An obligation is one case for a profile,
suite and capture variant. These counts measure our catalog, not all MySQL
features. The generated `ci-lab/matrix.json` is the authority when counts change.

| Profile | Applicable catalog obligations |
| --- | ---: |
| `mysql84-to-mysql57-myisam` | 825 |
| `mysql57-to-mysql84-innodb` | 422 |
| `mysql57-to-mysql57-myisam` | 412 |
| `mysql57-to-mysql57-innodb` | 436 |

The workflow builds the lab once and the coverage image once. Up to 16 integration
jobs run in parallel. Job names show profile, area, variant and image. Stateful
sequences stay in one fixture. Unit tests and Periphery run in parallel with the
image build. All previous profile, variant, transport and assertion checks remain.

## Before merge

Add `ci-full` to the top PR that contains the complete release candidate:

```sh
gh pr edit <top-pr-number> --add-label ci-full
```

Wait for **Full Suite / Test Evidence** and all required checks to pass.
If a lower stack branch changes, update the top branch and repeat full CI.
Do not require this full check on each stack PR through branch protection.
Ordinary PRs can use a smaller selection.

The full run saves `full-test-evidence/full-test-evidence.json`. It records the
Git tree, commit, version, run, attempts, build identity and profile results.
The Git tree identifies all tracked files. It includes source, tests, dependency
locks, build files and workflows. A squash merge can change the commit ID without
changing this tree.

## After merge

Main builds the static Linux binary, `.deb`, archive and production image.
Package checks install the `.deb` and check the archive. Two parallel lab checks
use the exact archive binary: `mysql84-to-mysql57-myisam` and
`mysql57-to-mysql84-innodb`. Each selects `positive` and `offline-replay`.
These cases check connections, decoded row application, saved checkpoints,
offline replay and resume. They compare results with native MySQL replication.
They do not repeat the full suite.

This small production check is required because the builds differ. The coverage
image uses glibc, system SQLite and a debug Rust library. The production image
uses musl, bundled SQLite and a release Rust library. Coverage results alone do
not test packaging or these library differences.

The **Match merged source to full tests** job finds a successful full CI run for
the same Git tree. It checks the run and commit through the GitHub API. The run
must belong to this repository and use its CI workflow. A PR run can use GitHub's
synthetic merge commit. A manual run must test its exact head commit. Fork results
cannot authorize a release; run full CI on a branch in this repository instead.

A missing result or a different tree stops release preparation. It does not
silently start the full suite. If the merge changed any tracked file, run:

```sh
gh workflow run ci.yml --ref main -f suite=full
```

Check that the manual run tested the required main commit. After it passes,
rerun the failed main jobs. To test an older commit, use a branch or tag at that
commit. The finder searches
the latest 1,000 successful CI runs. Its CLI also accepts `--test-run <run-id>`
for an older retained result. Expired test artifacts require another full run.
Keep the full result until release preparation completes; its retention is 90 days.

## Release and retries

Main saves `release-test-evidence.json` beside the packages. Format version 3
links the successful full test run, matching Git tree, production checks and
package checksum manifest. This is a test record, not a cryptographic signature.
The release workflow requires a successful main push run on the tagged commit.
It verifies this record and package checksums, then copies those exact packages
to the draft release. It does not rebuild them.

Use **Re-run failed jobs** when a test or report fails. Earlier results from the
same run can be reused only if the matrix and build identities still match.
Failed or cancelled required jobs, missing coverage, or failed artifact uploads
prevent a complete result. Use **Re-run all jobs** if a build changed or artifacts
expired. Do not copy test results from another run.

GitHub job timing is optional. Test results, coverage counts, source identity and
package checksums are required. An API failure during source verification must
be retried; it cannot be treated as proof of passing tests.

Read `ci-measurement-report/summary.md` first. Use `report.json` for missing cases
and `test-value.json` for the exact lines reached by each area. See
[measurement scope](CI_MEASUREMENTS.md). For a failed integration case, inspect
its support bundle before a rerun. See [the test lab](TEST_LAB.md).
