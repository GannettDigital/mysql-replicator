include packaging/static.mk
.PHONY: sqlite rust-dependencies probe-rust codec-rust demo-tools
sqlite:
	mkdir -p /out/native
	clang $(PACKAGING_CFLAGS) -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -c /opt/sqlite/sqlite3.c -o /out/native/sqlite3.o
	llvm-ar rcs /out/native/libsqlite3.a /out/native/sqlite3.o

rust-dependencies:
	python3 packaging/build_rust_dependencies.py --target $(PACKAGING_TARGET) --target-dir /workspace/packaging/rust/target rust/Cargo.toml packaging/rust/Cargo.toml

probe-rust:
	cargo build --manifest-path packaging/rust/Cargo.toml --locked --release --target $(PACKAGING_TARGET) -j 2

codec-rust:
	cargo build --manifest-path rust/Cargo.toml --locked --release --target $(PACKAGING_TARGET) --target-dir packaging/rust/target -j 2

# Optional demo tool; use the same compiled SQLite as the applier.
demo-tools:
	clang $(PACKAGING_CFLAGS) -resource-dir $(PACKAGING_SYSROOT)/usr/lib/swift/clang --rtlib=compiler-rt --unwindlib=none -static -fuse-ld=lld -DSQLITE_OMIT_LOAD_EXTENSION /opt/sqlite/shell.c /out/native/libsqlite3.a -lm -lpthread -o /out/sqlite3
	! readelf -l /out/sqlite3 | grep -q INTERP
	! readelf -d /out/sqlite3 | grep -q NEEDED
