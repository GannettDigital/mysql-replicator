# Invoked inside the pinned Docker builder. Swift and native C inputs use the
# same musl sysroot; the builder's glibc headers/libraries must not leak in.
PACKAGING_SYSROOT := /root/.swiftpm/swift-sdks/swift-6.2.1-RELEASE_static-linux-0.0.1.artifactbundle/swift-6.2.1-RELEASE_static-linux-0.0.1/swift-linux-musl/musl-1.2.5.sdk/x86_64
PACKAGING_TARGET := x86_64-unknown-linux-musl
PACKAGING_CFLAGS := --target=$(PACKAGING_TARGET) --sysroot=$(PACKAGING_SYSROOT) -O2 -fPIC
export CC := clang
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER := clang
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER := clang
export CC_x86_64_unknown_linux_musl := clang
export AR_x86_64_unknown_linux_musl := llvm-ar
export CFLAGS_x86_64_unknown_linux_musl := $(PACKAGING_CFLAGS)
.PHONY: build
build:
	mkdir -p /out/native /out/evidence
	clang $(PACKAGING_CFLAGS) -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -c /opt/sqlite/sqlite3.c -o /out/native/sqlite3.o
	llvm-ar rcs /out/native/libsqlite3.a /out/native/sqlite3.o
	cargo build --manifest-path packaging/rust/Cargo.toml --locked --release --target $(PACKAGING_TARGET) -j 2
	# SwiftPM cannot track external Rust archives; force just the entry point to relink.
	touch packaging/Probe/Sources/PackagingProbe/main.swift
	swift build --package-path packaging/Probe --swift-sdk x86_64-swift-linux-musl --configuration release --jobs 2 --force-resolved-versions -Xcc -I/opt/sqlite -Xlinker -L/out/native -Xlinker -L/workspace/packaging/rust/target/$(PACKAGING_TARGET)/release
	cp packaging/Probe/.build/x86_64-swift-linux-musl/release/packaging-probe /out/packaging-probe
	cargo build --manifest-path rust/Cargo.toml --locked --release --target $(PACKAGING_TARGET) --target-dir packaging/rust/target -j 2
	touch Sources/ReplicatorCLI/main.swift
	REPLICATOR_CODEC_LIBRARY_PATH=/workspace/packaging/rust/target/$(PACKAGING_TARGET)/release swift build --product mysql-replicator --swift-sdk x86_64-swift-linux-musl --configuration release --jobs 2 --force-resolved-versions -Xcc -I/opt/sqlite -Xlinker -L/out/native
	cp .build/x86_64-swift-linux-musl/release/mysql-replicator /out/mysql-replicator
	file /out/packaging-probe /out/mysql-replicator > /out/evidence/elf.txt
	readelf -h -l -d /out/packaging-probe >> /out/evidence/elf.txt
	! readelf -l /out/packaging-probe | grep -q INTERP
	! readelf -d /out/packaging-probe | grep -q NEEDED
	! readelf -l /out/mysql-replicator | grep -q INTERP
	! readelf -d /out/mysql-replicator | grep -q NEEDED
	sha256sum /out/packaging-probe /out/mysql-replicator > /out/evidence/sha256.txt
	swift --version > /out/evidence/toolchains.txt
	rustc --version >> /out/evidence/toolchains.txt
	cp packaging/Probe/Package.resolved packaging/rust/Cargo.lock /out/evidence/
	cp Package.resolved /out/evidence/production-Package.resolved
	cp rust/Cargo.lock /out/evidence/production-Cargo.lock
	cp /root/.swiftpm/swift-sdks/swift-6.2.1-RELEASE_static-linux-0.0.1.artifactbundle/sbom.spdx.json /out/evidence/sdk-sbom.spdx.json
