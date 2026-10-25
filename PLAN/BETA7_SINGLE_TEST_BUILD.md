# Beta.7: one instrumented test build

## Decision

Run normal CI tests with the coverage binary. Do not run the same group again
with the production binary. Keep uninstrumented performance benchmarks.
After merge, build production packages and run short checks on that binary.
Publish those saved packages without a rebuild.

This replaces the proposed [expanded study](BETA7_EXPANDED_COVERAGE_STUDY.md).
That study branch was not pushed and its run was not started.
Keep this CI work first when preparing the beta.7 PR stack. Do not reorder the
current working branches until release preparation.

## Implemented changes

- Full tests retain all 2,095 catalog obligations across four profiles.
  Cases, variants, SQL/BINLOG selections, dependencies and assertions remain.
- Each full apply group runs once with coverage. The separate PR baseline and
  its full-only extension no longer run as extra full-suite fixtures. Their
  cases remain in the normal full-catalog groups.
- InnoDB recovery now exports coverage, including its recovery CLI commands.
  Native-only observations do not run the replicator and have no line map.
- Main builds the static binary, `.deb`, archive and image. Two parallel checks
  select `positive` and `offline-replay`, on the forward MyISAM and reverse
  InnoDB profiles. They check data, checkpoints, replay and resume.
- Full results record the Git tree. Main checks that tree against a successful
  full PR or manual run through GitHub's API. A squash commit can match; a
  change to any tracked file cannot match.
- Release evidence format 3 links full tests, production checks and package
  checksums. The tag workflow publishes saved main packages.

| Plan | Groups | Jobs | Catalog obligations | Coverage collections |
| --- | ---: | ---: | ---: | ---: |
| Previous full | 244 | 129 | 2,095 | 22 |
| Previous expanded | 477 | 246 | 2,095 | 255 |
| Initial full plan | 240 | 125 | 2,095 | 253 |
| Main production checks | 2 | 2 | 4 | 0 |

These are generated plan counts, not measured GitHub times. The new full plan
removes 237 groups relative to the previous expanded plan. It adds coverage to
the two InnoDB recovery groups and removes four supplemental baseline groups.
Coverage collection count does not measure covered lines.

## Verification and next measurement

Use focused Python checks for planning, grouping, scope, reporting and release
promotion. Check that the full inventory and all previous required selections
remain. Check that failed jobs, missing reports, changed trees and changed
packages cannot authorize release preparation. Run the lab option tests and
one InnoDB recovery case with coverage. Leave the full database suite to GitHub.

The next `ci-full` run will measure each apply area. Inspect `summary.md` and
`test-value.json`. Find expensive areas with few exclusive lines after unit
coverage. Review their assertions before proposing a smaller test selection.
Full runs no longer contain separate PR baseline groups, so their reports do
not claim an exact delta from the PR selection.

The production binary still needs a small runtime check. It uses musl, bundled
SQLite and release Rust; the coverage image uses glibc, system SQLite and debug
Rust. Do not use the coverage image as a release package.

See [release testing](../docs/RELEASE_TESTING.md) for commands and retry rules.

## Local results

- The plan comparison found identical inventories and all 240 required group
  selections. It compared cases, dependencies, profiles, variants and transports.
- Focused CI, reporting, selection and release-tool Python checks passed.
- All 27 `LabProfileTests` passed.
- One `mysql57-to-mysql84-innodb` recovery run passed. It checked native results,
  multi-table transactions, composite keys, rollback, inspection, retry and resume.
  Its combined report covered 7,401 of 20,852 Swift runtime lines. This is one
  test group's coverage, not full-suite coverage.
- Workflow YAML parsing, job dependency checks and Swift format checks passed.

The local recovery run reused the previously measured instrumented binary.
Runtime sources and dependency/build inputs were unchanged; only lab sources
changed. The check verified runtime source hashes and identical binary hashes,
then refreshed the image's source files and harness-input label. The ignored
`artifacts/single-test-build/` directory retains that check and its logs.
GitHub will build its coverage image through the normal Dockerfile.

No full database suite or GitHub run was started for this change.

## Common compilation for test jobs

The previous workflow still compiled the project for Linux unit tests, the lab,
the coverage runtime and macOS Periphery. The next workflow uses one Linux
release build with coverage, test access and the compiler index enabled.

1. `test-build` builds the application, lab, Swift tests and Rust tests. It also
   prepares the isolated SQL parser tests and a pinned Linux Periphery binary.
2. Unit tests use `swift test --skip-build` and the saved Rust test executables.
   Periphery uses `--skip-build` and the same release index. These jobs can run
   in parallel with integration jobs.
3. The lab job downloads its executable and Swift runtime libraries. It selects
   tests from the catalog without a Swift compiler.
4. Integration jobs download the small coverage runtime. It contains the same
   application binary as the unit test image, without the compiler or index.
5. Main retains its separate production package build and short runtime checks.

The dependency, syntax and application layers use the same compiler options.
A separate Rust stage caches the codec and its tests. Swift source edits do not
rebuild Rust dependencies such as zstd. BuildKit runs at most two build stages
at once; each compiler uses two jobs. This limit does not reduce parallel test jobs.
The first run needs new layers because the options changed. Later runs can reuse
those layers from GHCR. The Periphery source commit is pinned to version 3.5.1;
its tool layer does not depend on application source files.

The large test image is transferred by registry digest. Forks use a checked
archive. The build job exports the lab from BuildKit without loading the large
image into Docker when it can publish to GHCR. This reduces disk use on the
hosted runner. Image transfers and the common build time must be measured in the
next GitHub run before we claim a reduction in elapsed time.

The isolated parser package is a deliberate second compilation of MySQLSyntax.
It checks that the parser can build without app dependencies. It is prepared in
the build job and runs without compilation in the unit job. The cache-tool test
builds only its own small fixture. Periphery no longer checks macOS-only code.


### Shared-build checks

The local Linux build compiled the application, lab, Swift tests, compiler index,
and Periphery. A separate check built the final Rust stage and ran all 12 saved
Rust tests without Cargo. The final consumer image reused the compiled Swift
outputs; the exact final Dockerfile still needs a GitHub run.

All 102 focused CI tool tests, nine coverage tool tests, and 11 release-evidence
tests passed. Workflow lint, YAML parsing, and whitespace checks passed. The
isolated parser suite passed all 49 tests on macOS with 99.32% line coverage.
Its `--skip-build` run passed with the same coverage and no compilation.

The x86_64 Linux image runs through QEMU on this ARM Mac. The app version and
DDL catalog checks passed. Swift unit execution and Periphery did not complete
within the local time limits. This does not establish their cause or a passing
Linux test result. Verify both consumers on the native x86_64 GitHub runner.
No full database suite was rerun for this build change.


The later [full-run fixes](BETA7_FULL_RUN_FIXES.md) assign one execution group to
each job. That plan has 240 jobs with the same 2,095 obligations and 253 coverage
collections. This replaces the initial 125-job packing above.
