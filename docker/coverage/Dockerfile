# Coverage is a separate developer image; shipping musl binaries and benchmarks
# remain uninstrumented. Keep LLVM tools with the binary that produced profiles.
FROM --platform=linux/amd64 rust:1.93.1-slim-bookworm@sha256:5b9332190bb3b9ece73b810cd1f1e9f06343b294ce184bcb067f0747d7d333ea AS coverage-rust
FROM --platform=linux/amd64 swift:6.2.1-jammy@sha256:6e33c70a59180c9b518f67728538312975cb3891177d20215cd2e31bdfe70791 AS toolchain
COPY --from=coverage-rust /usr/local/rustup /usr/local/rustup
COPY --from=coverage-rust /usr/local/cargo /usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
ENV CC=clang CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=clang
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev sqlite3 python3 && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/sqlite3 /usr/local/bin/sqlite3
WORKDIR /workspace
FROM toolchain AS dependencies
COPY Package.swift Package.resolved ./
COPY Vendor Vendor
COPY tools/build_dependencies.py tools/swift_cache.py tools/
# Ordinary layers retain objects, build databases and dependency checkouts.
# Application edits do not invalidate this expensive dependency compilation.
RUN python3 tools/build_dependencies.py --configuration release --enable-code-coverage --jobs 2 --force-resolved-versions
FROM dependencies AS build
COPY Sources Sources
COPY tests tests
COPY rust rust
RUN cargo build --manifest-path rust/Cargo.toml --locked \
    && rm -f .build/x86_64-unknown-linux-gnu/release/mysql-replicator \
    && python3 tools/swift_cache.py restore --scratch-path .build \
    && swift build --product mysql-replicator --configuration release --enable-code-coverage --jobs 2 --force-resolved-versions \
    && python3 tools/swift_cache.py save --scratch-path .build \
    && cp .build/release/mysql-replicator /usr/local/bin/mysql-replicator \
    && mkdir -p /opt/packaging-evidence \
    && swift --version > /opt/packaging-evidence/toolchains.txt \
    && rustc --version >> /opt/packaging-evidence/toolchains.txt
COPY tools/coverage_runtime.py tools/
RUN python3 tools/coverage_runtime.py

FROM --platform=linux/amd64 ubuntu:22.04@sha256:5ec03bb3441e8b0bf3b4f9cd4629a1ae763010dc3035bb8da3ae6cf026486401 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends python3 sqlite3 ca-certificates libstdc++6 zlib1g \
    && rm -rf /var/lib/apt/lists/* && ln -s /usr/bin/sqlite3 /usr/local/bin/sqlite3
COPY --from=build /out/coverage-runtime/ /
COPY --from=build /opt/packaging-evidence /opt/packaging-evidence
WORKDIR /workspace
COPY Sources Sources
COPY tools/code_coverage.py tools/
ENV REPLICATOR_LLVM_BIN=/usr/local/bin
RUN mysql-replicator --version && llvm-profdata --version && llvm-cov --version
LABEL org.mysql-replicator.code-coverage="swift"
ENTRYPOINT ["/usr/local/bin/mysql-replicator"]
