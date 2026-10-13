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
