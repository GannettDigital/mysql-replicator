# Both executables share the root package, target and dependency objects.
include packaging/static.mk
SWIFT_FLAGS := --swift-sdk x86_64-swift-linux-musl --configuration release --jobs 2 --force-resolved-versions -Xcc -I/opt/sqlite -Xlinker -L/out/native
.PHONY: probe build
probe:
	mkdir -p /out
	# SwiftPM does not track external archives. Force a relink after Rust changes.
	rm -f .build/x86_64-swift-linux-musl/release/packaging-probe
	python3 tools/swift_cache.py restore --scratch-path .build
	swift build --product packaging-probe $(SWIFT_FLAGS)
	python3 tools/swift_cache.py save --scratch-path .build
	cp .build/x86_64-swift-linux-musl/release/packaging-probe /out/packaging-probe

build:
	mkdir -p /out
	rm -f .build/x86_64-swift-linux-musl/release/mysql-replicator
	python3 tools/swift_cache.py restore --scratch-path .build
	swift build --product mysql-replicator $(SWIFT_FLAGS)
	python3 tools/swift_cache.py save --scratch-path .build
	cp .build/x86_64-swift-linux-musl/release/mysql-replicator /out/mysql-replicator
