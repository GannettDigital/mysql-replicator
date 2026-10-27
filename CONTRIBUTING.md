# Contributing to mysql-replicator

Use the [profile-driven test lab](docs/TEST_LAB.md) for correctness tests,
interactive demos and benchmarks across the four supported profiles. Start with
`make lab-list`. Use `make lab-plan` to inspect a selection before you run it.
See [local test commands](docs/TEST_LAB.md#local-test-commands) for examples.

Thank you for your interest in contributing to `mysql-replicator`!

## Code of Conduct

We are committed to providing a welcoming, inclusive, and harassment-free environment for everyone. Please be respectful and constructive in all interactions.

## Prerequisites

- **Swift:** Swift 6.2.1 with Swift Package Manager
- **Rust:** Rust 1.93.1 (`cargo`)
- **Docker:** Docker engine with Docker Compose and Linux/amd64 support (for full qualification suites)
- **Make:** GNU Make
- **Native libraries:** SQLite headers/libraries (`libsqlite3-dev` on Ubuntu; macOS SDK supplies them)
- **Python:** Python 3.9+ for release and coverage tooling

## Development Workflow

### 1. Building the Codebase

Build the Rust codec and the Swift binaries:

```sh
git clone https://github.com/GannettDigital/mysql-replicator.git
cd mysql-replicator
make build
.build/debug/mysql-replicator --help
```

### 2. Select checks for a change

Use the same changed-file rules as PR CI:

```sh
make test-selection ARGS="--base origin/main" | jq
make test-selected ARGS="--base origin/main"
```

For a stacked PR, use the preceding branch as the base. Use `--base HEAD` for
local edits only. Documentation and listed report tools do not need an
application build. Test-selector changes also use Python checks. Runtime changes,
`Makefile`, and `ci.yml` retain unit tests, Periphery, and two profile selections.
Dependency/package builds, fixtures, other workflows, and unknown paths select
full checks.
See [PR test selection](docs/PR_TEST_SELECTION.md) for the rules and limits.

### 3. Running Unit Tests

Run the Rust unit tests and Swift unit test suite:

```sh
make test
```

The SQL lexer and expression parser are in `MySQLSyntax`. Run their unit tests
without Rust, MySQL libraries, Docker, or a database server:

```sh
make syntax-test
make syntax-coverage
```

The second command writes `artifacts/coverage/syntax-unit/index.html`. It measures
only the syntax target's own tests and requires at least 95% line coverage.
The normal unit job also runs these tests and publishes the isolated report.
Line coverage does not prove grammar coverage. Add positive and negative cases,
SQL modes, precedence, source ranges, and limits for each grammar change.
See [the syntax layer](docs/SQL_SYNTAX.md) for its boundary and current scope.

Command parsing lives in `ReplicatorCommandLine`. It has no database dependencies.
Its tests check help, argument validation, and parsed requests. CLI process tests
also check stdout, JSON errors on stderr, and exit status without MySQL:

```sh
swift test --filter ReplicatorCommandLineTests
```

For AddressSanitizer testing:

```sh
make test-asan
```

The reverse profile uses a MySQL 5.7 source/native InnoDB reference and an 8.4
InnoDB destination. Run its specialized recovery checks through the shared interface:

```sh
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite recovery"
```

That adapter retains evidence under `artifacts/reverse-suite/` and omits its old
embedded benchmark. All profiles exercise the same demo lifecycle and applicable
workbook scenarios with `make lab-test ARGS="--suite demo"`. Use `make lab-benchmark`
for comparable measurements; see [reverse replication](docs/REVERSE_REPLICATION.md)
for bootstrap and offline recovery.

### Code coverage

Use Python 3.9+ and the LLVM tools included with Swift (Xcode's command-line
tools on macOS). Coverage is opt-in and uses separate build directories/images:

```sh
make coverage-unit
make correctness TIER=smoke ARGS="--coverage"
# Select shared fixtures or a family:
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--coverage --case positive"
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--coverage --family ddl --variant gtid-full"
make lab-test ARGS="--suite demo --coverage"
```

Unit reports appear under `artifacts/coverage/unit/`. Harness evidence contains
`code-coverage/<invocation>/report/` and `code-coverage/combined/` within each
fixture's evidence directory. Each contains `index.html`, `coverage.lcov`,
`coverage.json` and a summary. Open `index.html` to see covered and uncovered
source lines. The combined view identifies which invocations covered each line.
These are raw collection reports and include every mapped Swift module. Use the
scoped report below for runtime and harness percentages.
For interactive experiments use
`make lab-demo PROFILE=PROFILE ACTION=up ARGS="--coverage"`, then the usual shared
demo actions; `ACTION=down` stops the writer and exports its coverage. Coverage
mode persists across commands in the session manifest.

Combine **explicitly selected** reports from the same source revision:

```sh
make coverage-report INPUTS="artifacts/coverage/unit artifacts/lab/RUN_ID/PROFILE/correctness/VARIANT/FIXTURE_ID/code-coverage/combined"
```

The result is `artifacts/coverage/combined/index.html`, with four linked reports:

| Directory | Code | Inputs |
|---|---|---|
| `runtime/` | Production Swift, excluding `ReplicatorLab*` | Unit + selected integration |
| `runtime-unit/` | Same production scope | Unit only |
| `runtime-integration/` | Same production scope | Selected integration only |
| `harness/` | `ReplicatorLab` and `ReplicatorLabCore` | Unit only |

Each directory contains HTML, `coverage.json`, LCOV and a summary. The root also
contains `metrics.json`, `summary.md`, and `runtime.svg`. Harness hits from
integration collections never contribute to its unit-only report. Missing inputs
show **unavailable**, not 0% coverage. Each view uses its own executable-line
mapping; combined coverage unions those mappings and hits. The root report is
marked partial unless suite completion is supplied explicitly. For a locally
verified successful run, add
`ARGS="--unit-result success --integration-result success"` to `make coverage-report`.
Use original unit/per-fixture collection reports as inputs, not an already mixed
report. The low-level `tools/code_coverage.py merge` command remains available
for raw collection consumers and migration comparisons.
Source hashes reject stale reports, including edits in a dirty checkout. Raw
profiles are exported with the exact producing LLVM toolchain before merging;
do not merge macOS and Linux `.profraw` files directly. Coverage unions executable
lines across builds; function/branch coverage and platform-specific denominators
are not treated as interchangeable. Hit counts are diagnostic, not performance
measurements. Python report tests run with
`python3 -m unittest discover -s tools -p 'test_*.py'`.

The collection scope is **first-party Swift under `Sources/`**. Published runtime
coverage excludes `Sources/ReplicatorLab*/`; harness coverage is separate.
Rust unit tests still run, but Rust decoder internals and dependencies are not
part of this percentage. Coverage shows execution, not the strength of assertions.
The instrumented Linux image uses glibc and the Swift runtime; the separate normal
packaging smoke test still exercises the shipped static musl build. Benchmarks
continue to use the uninstrumented image. `--skip-build` selects the matching
coverage image when combined with `--coverage`.

Profiles flush on normal exit, including handled application failures. SIGKILL,
aborts and forcibly terminated fixtures can lose their profiles; DML/DDL runs
record these in `code-coverage/profile-status.json`. Missing profiles after a
normal exit fail collection. Do not interpret absent crash coverage as an
unexercised path. Failed suites retain the evidence available before cleanup.

Runtime PR CI combines one unit report and two integration smoke collections:
`mysql84-to-mysql57-myisam` and `mysql57-to-mysql84-innodb`.
One Linux build prepares the application, lab, test binaries and compiler index.
Unit tests, Periphery and integration jobs then use those outputs in parallel.
They do not compile the application again. Periphery now checks Linux code;
it does not check declarations that are compiled only on macOS.

The Swift unit test command has a five-minute limit. CI flushes test output
as it is written and saves it in the `unit-test-log` artifact. If a test hangs,
use this log to find the last test that started. A timeout fails the job;
it does not count as a successful test or a complete coverage report.

PRs with `ci-full` and default manual runs use the full four-profile matrix.
Each apply group uses the coverage binary once. Main builds production packages
and runs short application and replay checks. See [release testing](docs/RELEASE_TESTING.md).
Downloaded report discovery excludes demo `evidence-*` snapshots, which copy
existing measurements. Duplicate inputs in original collections still fail;
missing collections or failed suites produce a partial report.

CI uploads raw unit/integration collections, integration evidence, and the four
scoped reports in `combined-swift-coverage`. It also writes a job summary and a
small `coverage-summary` artifact. Complete CI coverage requires the unit job
and packaging/integration gate to succeed, with all planned instrumented
fixture reports. Each coverage shard also checks its own expected report count.
Full tests collect coverage from correctness, reconnect, recovery and demos.
Native-only observations run MySQL without the replicator. There is no separate
release qualification workflow.

CI uses a release build with coverage and test access enabled for each PR test run.
The common build also prepares the isolated SQL parser test binary. That small
separate build checks that the parser has no application or Rust dependencies.
The integration image contains the application and LLVM exporters, without the
compiler or test index. Unit tests and Periphery use the larger test image.
Both images come from the same application build.
Main builds the production image and packages.
PR and manual test runs generate their matrix from the lab catalog and the
reviewed group policy. Each integration job runs one group with a shared fixture.
Jobs name the profile, area, variant and image;
up to 16 run concurrently with `--skip-build`. Dependent operations within a
scenario remain sequential, including the failure/recovery/offline transition.
`tools/ci_matrix.json` defines grouping and coverage expectations;
`tools/ci_matrix.py` rejects missing assignments and expands prerequisites.
`tools/ci_lab.py` runs the same shared lab commands used locally. The generated
plan is retained in the `ci-lab` artifact. See [the test lab](docs/TEST_LAB.md)
for local plan inspection and reproduction.

The **Selected CI Checks** check requires all selected jobs to pass. It accepts
skips only for jobs excluded by the selector. The runtime PR selection does not
build packages. Full CI checks native-reference DDL, recovery and demos. Main
checks packages. A successful PR smoke run does not replace full release tests.

Test jobs verify image digests or archive checksums and the lab source/fixture fingerprint, and
release shards check that their applier matches the release archive binary.
The instrumented image retains its matching LLVM exporter. Artifacts are scoped
to the workflow run; individual shard evidence has a distinct artifact name.
The release workflow still promotes the exact packages from successful main CI.
Full CI records the tested Git tree, run attempt and profile results. Main links
that record to its production checks and package checksums. Draft creation
checks this evidence before promotion.

SwiftPM/Cargo build caches are separated by OS, architecture, toolchain, build
variant, runner image and dependency locks. Host jobs restore the installed
Swift toolchain (including its tool-cache completion marker) in the same archive
as its build outputs, before running `setup-swift`. That action copies toolchain
files during installation, giving compiler headers fresh timestamps even when
the Swift version is unchanged. Pairing them with the objects avoids mixing
headers from one installation with objects from another. Each job keeps its own
pair; a separately shared toolchain cache could race during initial population.
The v2 host cache keys require one fresh build before warm reuse can be measured.
These archives are larger, so compare transfer time as well as compilation time.

Docker builds store compiler output in ordinary dependency layers. They export
these layers to GHCR with `mode=max`. Application sources enter a later layer.
Test jobs pull the runtime image by digest. Fork PRs retain archive transfer.
See [CI build caching](docs/CI_BUILD_CACHE.md) for access, layer boundaries,
branch isolation and measurement instructions.
Both the package export and the separate runtime-image export explicitly import
the release layer cache; a hit on the first target does not warm every
intermediate step needed by the second target.
Unit coverage clears old counters and forces relinking after Rust builds.
Periphery uses the current incremental build's index store, rather than cleaning
and recompiling it. The packaging probe has an independent Docker stage so
application-only edits leave it cached. Main CI populates shared caches.
GHCR branch caches can be read by later PRs in the stack. Host Actions caches
still follow GitHub's branch access rules. Cold builds remain valid.

`tools/swift_cache.py` saves nanosecond timestamps beside each Swift build cache.
The release build applies it separately to the applier and `packaging/Probe`,
with the probe's own package directory as the root for its input paths.
After restoring a cache, it restores timestamps only for files whose SHA-256,
size and permissions still match. This handles fresh source checkouts and cache
transports that lose timestamp precision without treating changed inputs as
unchanged. It covers package sources, dependency checkouts and build outputs;
system headers/toolchains remain under SwiftPM's normal invalidation checks.
Existing caches without this manifest work normally and acquire one after a
successful build. Installer, Debian configuration and example changes no longer
invalidate the release compilation layer. Rust changes still force relinking.

The tooling tests exercise real compiler reuse, paired toolchain/build archive
restoration, and source/header invalidation on Linux CI. Run the same check
locally with:

```sh
SWIFT_CACHE_INTEGRATION=1 python3 -m unittest discover -s tools -p 'test_swift_cache.py'
```

Compare both cold and warm Actions runs after changing CI. Record build, image
transfer and shard times separately: splitting jobs adds image downloads, and
organization runner queues can dominate a large PR stack. The initial targets
are five minutes for PR feedback and twenty minutes for full pre-merge checks.
These are targets. The current build and image transfer times still need work.

A separate `Coverage PR Comment` workflow updates one comment per PR, including
fork PRs. It runs trusted default-branch code and reads only bounded JSON metadata
from the triggering run; it never executes or extracts PR artifacts. Comments
include counts, percentages, partial status and a link to the downloadable report.
Old-head runs and older reruns cannot replace a newer comment. Base deltas require
a successful CI push run for the exact tested base commit and identical test,
harness, toolchain configuration and reporting inputs. Missing or expired baseline
artifacts produce an unavailable comparison, not a zero baseline.
Main production checks do not collect coverage. A base delta is unavailable
without a matching measured baseline. PR reports retain their absolute counts.

Coverage publication uses GitHub Actions summaries, downloadable artifacts and
PR comments. It does not require GitHub Pages or an external hosting service.
Open the README's **CI** link and select a completed full PR or manual test run to see coverage
percentages in its summary; download `combined-swift-coverage`,
extract it, and open `index.html` locally for annotated source and LCOV reports.
Check the report's completeness status and tested commit before using its numbers.
Artifacts follow the repository's retention policy.

The generated `runtime.svg` remains inside the report artifact. CI does not write
generated files or commits back to the repository. PR comments become active once
`coverage-comment.yml` is on the default branch. No Pages setting or
`COVERAGE_PAGES_ENABLED` variable is needed.

No external coverage service or personal token is required. There is no percentage
gate until we establish a useful baseline. This is Swift execution coverage, not
MySQL catalog qualification or a measure of assertion quality.

### Unused Swift code

Install [Periphery 3.5.1](https://github.com/peripheryapp/periphery/releases/tag/3.5.1),
then run `make periphery`. CI uses the same pinned, checksum-verified macOS release.
The scan builds both executables and tests with a fresh index, reports first-party
code, and fails on findings. There is no blanket public-API exemption or baseline.
Codable properties are retained because serialized fields are an external contract;
the CLI's top-level entry point has a narrow annotation for Periphery 3.5.1.
Periphery analyzes Swift; it does not identify unused Rust code.

### 3. Targeted Qualification Suites

Run incremental integration checks against local container fixtures:

```sh
# Inspect the two-profile PR baseline without starting containers:
make lab-plan ARGS="--selection pr --commands"

# Inspect the same named groups that CI uses:
make lab-list GROUP=all | jq '[.groups[].area] | unique'
make lab-plan GROUP=keys-rows-gtids PROFILE=all

# Run one complete group on one profile and capture variant:
make lab-test GROUP=keys-rows-gtids PROFILE=mysql57-to-mysql84-innodb ARGS="--variant default"


# Basic DML qualification:
make correctness ARGS="--case positive"

# DDL qualification with GTID positioning:
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--family indexes --variant gtid-full"

# Shared full DML/DDL correctness on all profiles:
make correctness

# Debian packaging smoke test on Ubuntu 16.04:
make deb
```

Shared profile checks need OpenSSL and the SQLite CLI. Shared filter/index checks
and legacy integration checks also need MySQL 8.4 `mysqlbinlog` in
`PATH` (or set `MYSQLBINLOG` to its executable path). See
[the test lab](docs/TEST_LAB.md#capture-variants-and-catalog-evidence) for capture
variants and catalog evidence, and [incremental checks](PLAN/INCREMENTAL_CHECKS.md)
for legacy selections.

### 4. DDL Coverage Catalog Checks

Validate that catalog JSON definitions remain consistent:

```sh
make ddl-catalog-check
```

## Pull Request Guidelines

1. **Commit Messages:**
   - Use clear, concise imperative commit messages (e.g., `Add Debian package build and verification workflow`).
   - Match the established repository style in `git log`.
2. **Testing:**
   - Always add or update automated test cases for bug fixes and new features.
   - All tests (`make test`) must pass before submitting a pull request.
3. **Licensing & Attribution:**
   - All contributions are made under the Apache License, Version 2.0.
   - Any external code must be appropriately attributed in the `NOTICE` file.

## Release engineering

`VERSION` is the application SemVer; generated Swift constants are committed so
ordinary SwiftPM builds need no generator or version file at runtime. After a
version change, run `python3 tools/release_version.py --write`. CI rejects drift.
The Debian version maps the prerelease separator to `~` and appends revision `-1`.
Do not change config/state/codec protocol versions to match the release number.

```sh
make release-check
make release-artifacts
make release-image
```

Docker builds Linux x86_64 once, verifies static linking, collects dependency
notices, packages `.deb` and `.tar.gz`, tests their installed contents and exports
checksummed assets to `artifacts/release/`. The image command uses that archive,
tests the non-root production container and adds its saved image to the assets.
No registry login or publication is performed by either command.
macOS/arm64 distribution is deferred.
See [packaging](packaging/README.md) for qualification limits and
[the beta release procedure](docs/RELEASING.md) for the PR stack and publication.

For comparable backlog measurements use `make lab-benchmark PROFILE=PROFILE`;
see the [test lab guide](docs/TEST_LAB.md). For the original forward streaming
and capture experiments use `make lab-benchmark PROFILE=mysql84-to-mysql57-myisam`
with `ARGS="--mode streaming"` or `ARGS="--mode capture"`; see
[the benchmark guide](PLAN/PERFORMANCE_BENCHMARK.md). These remain uninstrumented.

## Swift syntax and format

Use Swift 6.2.1 and run `make lint`. This check uses the formatter in the Swift
toolchain. It parses Swift files and checks their format without building the
project. Run `make format` to apply the format in `.swift-format`. CI runs this
check in parallel with Periphery and other checks. Compiler and unit-test jobs
still check types and behavior. Vendor code and upstream MySQL trees are excluded.
