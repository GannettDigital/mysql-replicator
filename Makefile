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

.PHONY: dml-suite
dml-suite:
	swift run replicator-lab dml-suite $(ARGS)

.PHONY: ddl-suite
ddl-suite:
	swift run replicator-lab ddl-suite $(ARGS)

.PHONY: integration-smoke
integration-smoke:
	swift run replicator-lab ddl-suite --positioning gtid --case ddl-modify-demo-varchar-120 --case ddl-index-create $(ARGS)

.PHONY: benchmark
benchmark:
	swift run replicator-lab benchmark $(ARGS)

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

.PHONY: demo-up demo-start demo-status demo-compare demo-sql demo-fail demo-down demo-suite
demo-up demo-start demo-status demo-compare demo-fail demo-down demo-suite:
	swift run replicator-lab $@ $(ARGS)

demo-sql:
	swift run replicator-lab demo-sql "$(FILE)"

.PHONY: benchmark-capture
benchmark-capture:
	swift run replicator-lab benchmark-capture $(ARGS)
