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
RUN python3 tools/build_dependencies.py --configuration release --enable-code-coverage --enable-index-store -Xswiftc -enable-testing --jobs 2 --force-resolved-versions
# Swift edits must not rebuild the codec, zstd or the Rust test harness.
FROM toolchain AS codec
COPY rust rust
COPY tests/ReplicatorLabTests/Fixtures/source-positive.binlog tests/ReplicatorLabTests/Fixtures/source-positive.binlog
RUN cargo build --manifest-path rust/Cargo.toml --locked --jobs 2 \
    && mkdir -p /out \
    && cargo test --manifest-path rust/Cargo.toml --locked --jobs 2 --no-run --message-format=json > /out/rust-test-artifacts.jsonl

FROM dependencies AS sql-syntax
COPY Sources/MySQLSyntax Sources/MySQLSyntax
COPY tools/build_syntax.py tools/
RUN python3 tools/build_syntax.py --configuration release --enable-code-coverage --enable-index-store -Xswiftc -enable-testing --jobs 2 --force-resolved-versions
FROM sql-syntax AS build
COPY --from=codec /workspace/rust rust
COPY --from=codec /out/rust-test-artifacts.jsonl .build/rust-test-artifacts.jsonl
COPY Sources Sources
COPY tests tests
RUN rm -f .build/x86_64-unknown-linux-gnu/release/mysql-replicator .build/x86_64-unknown-linux-gnu/release/replicator-lab \
    && python3 tools/swift_cache.py restore --scratch-path .build \
    && swift build --build-tests --configuration release --enable-code-coverage --enable-index-store -Xswiftc -enable-testing --jobs 2 --force-resolved-versions \
    && python3 tools/swift_cache.py save --scratch-path .build \
    && cp .build/release/mysql-replicator /usr/local/bin/mysql-replicator \
    && mkdir -p /opt/packaging-evidence \
    && swift --version > /opt/packaging-evidence/toolchains.txt \
    && rustc --version >> /opt/packaging-evidence/toolchains.txt
COPY tools/coverage_runtime.py tools/
RUN python3 tools/coverage_runtime.py

# Build Periphery 3.5.1 independently of application sources. Its release archive is macOS-only.
FROM toolchain AS periphery-tool
RUN git clone https://github.com/peripheryapp/periphery.git /opt/periphery \
    && cd /opt/periphery \
    && git checkout --detach fb0130e09cbd1595b5e63b32a228701aea675569 \
    && swift build --configuration release --product periphery --jobs 2 --force-resolved-versions \
    && cp .build/release/periphery /usr/local/bin/periphery

# This small second parser build checks that the target has no app dependencies.
FROM toolchain AS syntax-tests
COPY Sources/MySQLSyntax Sources/MySQLSyntax
COPY tests/MySQLSyntaxTests tests/MySQLSyntaxTests
COPY tools/syntax_tests.py tools/code_coverage.py tools/
RUN python3 tools/syntax_tests.py --coverage --build-only

# Keep original /workspace paths for XCTest resources and the compiler index.
# Unit tests, Periphery and the lab all consume this build.
FROM build AS ci-build
COPY --from=periphery-tool /usr/local/bin/periphery /usr/local/bin/periphery
COPY --from=syntax-tests /workspace/artifacts/syntax-unit /workspace/artifacts/syntax-unit
COPY tools tools
COPY examples examples
COPY packaging packaging
COPY docker docker
COPY compose.yaml Makefile .dockerignore .periphery.yml VERSION ./
# The support catalog also references this investigation. Keep test-only documents
# after compilation so document changes do not invalidate compiled objects.
COPY PLAN/JSON_TRANSPORT_INVESTIGATION.md PLAN/
RUN python3 tools/ci_test_build.py check-test-inputs \
    && python3 tools/ci_test_build.py record-rust-tests \
    && test -d .build/release/index/store \
    && periphery version \
    && GITHUB_OUTPUT=/out/ci-inputs python3 tools/ci_test_build.py export-lab

FROM scratch AS ci-export
COPY --from=ci-build /workspace/artifacts/ci/prebuilt-lab.tar.gz /workspace/artifacts/ci/prebuilt-lab.tar.sha256 /out/ci-inputs /

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
