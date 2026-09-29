.PHONY: codec build test native-smoke native-suite upstream-tests
codec:
	cargo build --manifest-path rust/Cargo.toml --locked
build: codec
	swift build
	.build/debug/mysql-replicator --version
test: codec
	swift test
native-smoke:
	swift run replicator-lab native-smoke $(ARGS)
native-suite:
	swift run replicator-lab native-suite $(ARGS)
upstream-tests:
	swift run replicator-lab upstream-tests
