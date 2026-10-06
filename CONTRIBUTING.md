# Contributing to mysql-replicator

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

### 2. Running Unit Tests

Run the Rust unit tests and Swift unit test suite:

```sh
make test
```

For AddressSanitizer testing:

```sh
make test-asan
```

### Code coverage

Use Python 3.9+ and the LLVM tools included with Swift (Xcode's command-line
tools on macOS). Coverage is opt-in and uses separate build directories/images:

```sh
make coverage-unit
make integration-smoke ARGS="--coverage"
# Other selected or full DML/DDL suites accept the same flag:
make dml-suite ARGS="--coverage --slice basic --positioning gtid"
make ddl-suite ARGS="--coverage --slice compatibility --positioning gtid"
make demo-suite ARGS="--coverage"
```

Unit reports appear under `artifacts/coverage/unit/`. Harness evidence contains
`code-coverage/<invocation>/report/` and `code-coverage/combined/`; demo evidence
places these inside `captured/`. Each contains `index.html`, `coverage.lcov`,
`coverage.json` and a summary. Open `index.html` to see covered and uncovered
source lines. The combined view identifies which invocations covered each line.
The summary separates runtime coverage from harness coverage and lists each module.
For interactive experiments use `make demo-up ARGS="--coverage"`, then the usual
demo commands; `make demo-down` stops the writer and exports its coverage.

Combine **explicitly selected** reports from the same source revision:

```sh
make coverage-report INPUTS="artifacts/coverage/unit artifacts/ddl-suite/RUN_ID/code-coverage/combined"
```

The result is `artifacts/coverage/combined/index.html` plus portable LCOV.
Source hashes reject stale reports, including edits in a dirty checkout. Raw
profiles are exported with the exact producing LLVM toolchain before merging;
do not merge macOS and Linux `.profraw` files directly. Coverage unions executable
lines across builds; function/branch coverage and platform-specific denominators
are not treated as interchangeable. Hit counts are diagnostic, not performance
measurements. Python report tests run with
`python3 -m unittest discover -s tools -p 'test_*.py'`.

The scope is **first-party Swift under `Sources/`**, including the harness.
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

CI uploads unit, per-invocation integration, and combined HTML/LCOV artifacts,
and posts the combined percentage in the job summary. Failed producing jobs
mark the summary as partial. No external coverage account or token is required;
there is no percentage gate until we establish a useful baseline.

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
# Small DML/DDL sample used by CI:
make integration-smoke

# Basic DML qualification:
make dml-suite ARGS="--slice basic"

# DDL qualification with GTID positioning:
make ddl-suite ARGS="--slice modify-index --positioning gtid"

# Debian packaging smoke test on Ubuntu 16.04:
make deb
```

Integration checks need OpenSSL, the SQLite CLI, and MySQL 8.4 `mysqlbinlog` in
`PATH` (or set `MYSQLBINLOG` to its executable path). See
[incremental checks](PLAN/INCREMENTAL_CHECKS.md) for selection and evidence details.

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
```

Docker builds Linux x86_64 once, verifies static linking, collects dependency
notices, packages `.deb` and `.tar.gz`, tests their installed contents and exports
checksummed assets to `artifacts/release/`. macOS/arm64 distribution is deferred.
See [packaging](packaging/README.md) for qualification limits and
[the beta release procedure](docs/RELEASING.md) for the PR stack and publication.

For performance work use `make benchmark` or `make benchmark-capture`; see
[the benchmark guide](PLAN/PERFORMANCE_BENCHMARK.md). These remain uninstrumented.
