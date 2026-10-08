.PHONY: codec build test native-smoke native-suite upstream-tests
codec:
	cargo build --manifest-path rust/Cargo.toml --locked
	# SwiftPM does not track changes to externally linked Rust archives.
	swift package clean
build: codec
	swift build
	.build/debug/mysql-replicator --version
test: codec
	cargo test --manifest-path rust/Cargo.toml --locked
	swift test

.PHONY: coverage-unit coverage-report periphery
coverage-unit:
	python3 tools/code_coverage.py unit

# Explicit inputs prevent old integration runs from inflating the report.
coverage-report:
	python3 tools/coverage_report.py $(ARGS) $(INPUTS)

periphery:
	cargo build --manifest-path rust/Cargo.toml --locked
	periphery scan --strict
native-smoke:
	swift run replicator-lab native-smoke $(ARGS)
native-suite:
	swift run replicator-lab native-suite $(ARGS)
upstream-tests:
	swift run replicator-lab upstream-tests

.PHONY: ubuntu-smoke
ubuntu-smoke:
	swift run replicator-lab ubuntu-smoke $(ARGS)

.PHONY: deb
deb:
	swift run replicator-lab package-deb $(ARGS)

.PHONY: test-asan
test-asan: codec
	REPLICATOR_TEST_BINARY_DIR="$(CURDIR)/.build-asan/debug" swift test --scratch-path .build-asan --sanitize=address

.PHONY: live-suite
live-suite:
	swift run replicator-lab live-suite $(ARGS)

.PHONY: reverse-suite
reverse-suite:
	swift run replicator-lab reverse-suite $(ARGS)

.PHONY: integration-smoke
integration-smoke:
	swift run replicator-lab test --profile mysql84-to-mysql57-myisam --case positive --case ddl-modify-demo-varchar-120 --case ddl-index-create $(ARGS)

.PHONY: native-ddl-suite
native-ddl-suite:
	swift run replicator-lab native-ddl-suite

.PHONY: ddl-catalog-check ddl-catalog-report
ddl-catalog-check:
	@swift run replicator-lab ddl-catalog check $(ARGS)

ddl-catalog-report:
	@swift run replicator-lab ddl-catalog report $(ARGS)

.PHONY: ddl-catalog-upstream-check ddl-catalog-scan
ddl-catalog-upstream-check:
	@swift run replicator-lab ddl-catalog upstream-check $(ARGS)

ddl-catalog-scan:
	@swift run replicator-lab ddl-catalog scan $(ARGS)

.PHONY: release-check release-artifacts
release-check:
	python3 tools/release_version.py
	python3 -m unittest discover -s tools -p 'test_*.py'

# Docker only: export is gated by installation and archive tests.
release-artifacts: release-check
	docker build --platform linux/amd64 --target release-export -f docker/packaging/Dockerfile --output type=local,dest=artifacts/release .

.PHONY: reverse-correctness
reverse-correctness:
	swift run replicator-lab reverse-correctness $(ARGS)

# Canonical profile-driven lab commands. Specialized targets above retain their scope.
PROFILE ?= all
TIER ?= full
.PHONY: correctness lab-test lab-list lab-demo lab-benchmark
correctness:
	swift run replicator-lab test --profile $(PROFILE) --suite correctness --tier $(TIER) $(ARGS)
lab-test:
	swift run replicator-lab test --profile $(PROFILE) $(ARGS)
lab-list:
	@swift run replicator-lab test --profile $(PROFILE) --suite all --list $(ARGS)
lab-demo:
	swift run replicator-lab demo $(ACTION) --profile $(PROFILE) $(ARGS)
lab-benchmark:
	swift run replicator-lab benchmark --profile $(PROFILE) $(ARGS)
