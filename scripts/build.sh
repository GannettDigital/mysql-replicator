#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build --manifest-path rust/Cargo.toml --locked
swift build
.build/debug/mysql-replicator --version
