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
VERSION ?= 0.1.0
.PHONY: build
build:
	mkdir -p /out/native /out/evidence
	clang $(PACKAGING_CFLAGS) -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -c /opt/sqlite/sqlite3.c -o /out/native/sqlite3.o
	llvm-ar rcs /out/native/libsqlite3.a /out/native/sqlite3.o
	cargo build --manifest-path packaging/rust/Cargo.toml --locked --release --target $(PACKAGING_TARGET) -j 2
	# SwiftPM does not track external Rust archives. A timestamp-only source
	# touch can be skipped by content-based incremental builds; remove the output.
	rm -f packaging/Probe/.build/x86_64-swift-linux-musl/release/packaging-probe
	swift build --package-path packaging/Probe --swift-sdk x86_64-swift-linux-musl --configuration release --jobs 2 --force-resolved-versions -Xcc -I/opt/sqlite -Xlinker -L/out/native -Xlinker -L/workspace/packaging/rust/target/$(PACKAGING_TARGET)/release
	cp packaging/Probe/.build/x86_64-swift-linux-musl/release/packaging-probe /out/packaging-probe
	cargo build --manifest-path rust/Cargo.toml --locked --release --target $(PACKAGING_TARGET) --target-dir packaging/rust/target -j 2
	rm -f .build/x86_64-swift-linux-musl/release/mysql-replicator
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

# Optional demo tooling: inspect the live WAL in Docker's own filesystem.
.PHONY: demo-tools
demo-tools:
	clang $(PACKAGING_CFLAGS) -resource-dir $(PACKAGING_SYSROOT)/usr/lib/swift/clang --rtlib=compiler-rt --unwindlib=none -static -fuse-ld=lld -DSQLITE_OMIT_LOAD_EXTENSION /opt/sqlite/shell.c /out/native/libsqlite3.a -lm -lpthread -o /out/sqlite3
	! readelf -l /out/sqlite3 | grep -q INTERP
	! readelf -d /out/sqlite3 | grep -q NEEDED

# Build Debian package (.deb) from static musl binary
.PHONY: deb
deb:
	@if [ ! -f /out/mysql-replicator ]; then \
		echo "==> /out/mysql-replicator not found; building binary first..." >&2; \
		$(MAKE) -f packaging/Makefile build; \
	fi
	mkdir -p /out/deb
	rm -rf /out/deb-staging
	mkdir -p /out/deb-staging/DEBIAN
	mkdir -p /out/deb-staging/usr/bin
	mkdir -p /out/deb-staging/lib/systemd/system
	mkdir -p /out/deb-staging/etc/mysql-replicator
	mkdir -p /out/deb-staging/var/lib/mysql-replicator
	cp /out/mysql-replicator /out/deb-staging/usr/bin/mysql-replicator
	chmod 0755 /out/deb-staging/usr/bin/mysql-replicator
	cp packaging/debian/mysql-replicator.service /out/deb-staging/lib/systemd/system/mysql-replicator.service
	chmod 0644 /out/deb-staging/lib/systemd/system/mysql-replicator.service
	cp examples/apply.example.json /out/deb-staging/etc/mysql-replicator/apply.example.json
	chmod 0644 /out/deb-staging/etc/mysql-replicator/apply.example.json
	sed "s/@VERSION@/$(VERSION)/g" packaging/debian/control.in > /out/deb-staging/DEBIAN/control
	chmod 0644 /out/deb-staging/DEBIAN/control
	cp packaging/debian/conffiles /out/deb-staging/DEBIAN/conffiles
	chmod 0644 /out/deb-staging/DEBIAN/conffiles
	cp packaging/debian/postinst /out/deb-staging/DEBIAN/postinst
	chmod 0755 /out/deb-staging/DEBIAN/postinst
	cp packaging/debian/prerm /out/deb-staging/DEBIAN/prerm
	chmod 0755 /out/deb-staging/DEBIAN/prerm
	dpkg-deb -Zxz --build --root-owner-group /out/deb-staging /out/deb/mysql-replicator_$(VERSION)_amd64.deb
	sha256sum /out/deb/mysql-replicator_$(VERSION)_amd64.deb > /out/deb/mysql-replicator_$(VERSION)_amd64.deb.sha256
	dpkg-deb --info /out/deb/mysql-replicator_$(VERSION)_amd64.deb
	dpkg-deb --contents /out/deb/mysql-replicator_$(VERSION)_amd64.deb
