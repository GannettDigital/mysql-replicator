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

.PHONY: test-asan
test-asan: codec
	REPLICATOR_TEST_BINARY_DIR="$(CURDIR)/.build-asan/debug" swift test --scratch-path .build-asan --sanitize=address

.PHONY: live-suite
live-suite:
	swift run replicator-lab live-suite $(ARGS)
