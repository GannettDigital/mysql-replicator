.PHONY: codec build test upstream-tests
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
.PHONY: syntax-test syntax-coverage
syntax-test:
	python3 tools/syntax_tests.py
syntax-coverage:
	python3 tools/syntax_tests.py --coverage

coverage-unit:
	python3 tools/code_coverage.py unit

# Explicit inputs prevent old integration runs from inflating the report.
coverage-report:
	python3 tools/coverage_report.py $(ARGS) $(INPUTS)

periphery:
	cargo build --manifest-path rust/Cargo.toml --locked
	periphery scan --strict
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

.PHONY: release-check release-artifacts release-image
release-check:
	python3 tools/release_version.py
	python3 -m unittest discover -s tools -p 'test_*.py'

# Docker only: export is gated by installation and archive tests.
release-artifacts: release-check
	docker build --platform linux/amd64 --target release-export -f docker/packaging/Dockerfile --output type=local,dest=artifacts/release .

# Uses the already verified archive, tests the runtime image, and saves its bytes.
release-image:
	python3 tools/release_image.py

# Shared test commands. Use PROFILE=all for the profile matrix.
# ARGS selects suites, families, cases, variants and transport.
PROFILE ?= all
GROUP ?=
TIER ?= full
.PHONY: correctness lab-test lab-list lab-plan lab-demo lab-benchmark lab-performance
correctness:
	swift run replicator-lab test --profile $(PROFILE) --suite correctness --tier $(TIER) $(ARGS)
# GROUP selects complete CI fixture groups. Without GROUP, select catalog cases.
ifneq ($(strip $(GROUP)),)
lab-test:
	@python3 tools/lab_groups.py --run --group $(GROUP) --profile $(PROFILE) $(ARGS)
lab-plan lab-list:
	@python3 tools/lab_groups.py --group $(GROUP) --profile $(PROFILE) $(ARGS)
else
lab-test:
	swift run replicator-lab test --profile $(PROFILE) $(ARGS)
lab-plan:
	@python3 tools/lab_selection.py $(if $(filter all,$(PROFILE)),,--profile $(PROFILE)) $(ARGS)
lab-list:
	@swift run replicator-lab test --profile $(PROFILE) --suite all --list $(ARGS)
endif
lab-demo:
	swift run replicator-lab demo $(ACTION) --profile $(PROFILE) $(ARGS)
lab-performance:
	swift run replicator-lab test --profile $(PROFILE) --suite performance $(ARGS)
lab-benchmark:
	swift run replicator-lab benchmark --profile $(PROFILE) $(ARGS)

# The selector is shared with PR CI. JSON stays on stdout.
.PHONY: test-selection test-selected
test-selection:
	@python3 tools/test_selection.py $(ARGS)
test-selected:
	@python3 tools/test_selection.py --run $(ARGS)

.PHONY: lint format
lint:
	swift format lint --strict --parallel --recursive Sources tests
format:
	swift format format --in-place --parallel --recursive Sources tests
