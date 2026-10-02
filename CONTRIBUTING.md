# Contributing to mysql-replicator

Thank you for your interest in contributing to `mysql-replicator`!

## Code of Conduct

We are committed to providing a welcoming, inclusive, and harassment-free environment for everyone. Please be respectful and constructive in all interactions.

## Prerequisites

- **Swift:** Swift 6.2 or later with Swift Package Manager
- **Rust:** Rust 1.93 or later (`cargo`)
- **Docker:** Docker engine with Docker Compose and Linux/amd64 support (for full qualification suites)
- **Make:** GNU Make

## Development Workflow

### 1. Building the Codebase

Build the Rust codec and the Swift binaries:

```sh
make build
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
