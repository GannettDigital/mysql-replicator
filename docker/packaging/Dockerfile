# Native builder; both toolchains cross-compile to the same x86_64 musl target.
FROM --platform=$BUILDPLATFORM rust:1.93.1-slim-bookworm@sha256:5b9332190bb3b9ece73b810cd1f1e9f06343b294ce184bcb067f0747d7d333ea AS rust-toolchain
FROM --platform=$BUILDPLATFORM swift:6.2.1-jammy@sha256:6e33c70a59180c9b518f67728538312975cb3891177d20215cd2e31bdfe70791 AS toolchain
COPY --from=rust-toolchain /usr/local/rustup /usr/local/rustup
COPY --from=rust-toolchain /usr/local/cargo /usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
RUN apt-get update && apt-get install -y --no-install-recommends unzip make file && rm -rf /var/lib/apt/lists/*
RUN rustup target add x86_64-unknown-linux-musl
RUN swift sdk install https://download.swift.org/swift-6.2.1-release/static-sdk/swift-6.2.1-RELEASE/swift-6.2.1-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz --checksum 08e1939a504e499ec871b36826569173103e4562769e12b9b8c2a50f098374ad
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip -o /tmp/sqlite.zip \
    && echo '1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d  /tmp/sqlite.zip' | sha256sum -c - \
    && unzip -q /tmp/sqlite.zip -d /opt && mv /opt/sqlite-amalgamation-3530400 /opt/sqlite && rm /tmp/sqlite.zip
FROM toolchain AS probe
WORKDIR /workspace
COPY packaging/Probe/Package.swift packaging/Probe/Package.resolved packaging/Probe/
RUN --mount=type=cache,target=/workspace/packaging/Probe/.build,sharing=locked swift package --package-path packaging/Probe resolve --force-resolved-versions
COPY packaging/rust packaging/rust
COPY tests/ReplicatorLabTests/Fixtures/source-positive.binlog tests/ReplicatorLabTests/Fixtures/source-positive.binlog
COPY packaging/Probe/Sources packaging/Probe/Sources
COPY packaging/Makefile packaging/
COPY tools/swift_cache.py tools/
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/usr/local/cargo/git --mount=type=cache,target=/workspace/packaging/rust/target,sharing=locked --mount=type=cache,target=/workspace/packaging/Probe/.build,sharing=locked make -f packaging/Makefile probe

# Application edits do not invalidate the independent ABI/dependency probe.
FROM probe AS build
COPY tests tests
COPY packaging/collect_notices.py packaging/
COPY packaging/licenses packaging/licenses
COPY tools/release_version.py tools/
COPY VERSION ./
COPY Vendor Vendor
COPY Package.swift Package.resolved ./
COPY Sources Sources
COPY rust rust
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/usr/local/cargo/git --mount=type=cache,target=/workspace/packaging/rust/target,sharing=locked --mount=type=cache,target=/workspace/packaging/Probe/.build,sharing=locked --mount=type=cache,target=/workspace/.build,sharing=locked make -f packaging/Makefile build
FROM --platform=linux/amd64 ubuntu:16.04@sha256:1f1a2d56de1d604801a9671f301190704c25d604a416f59e03c04f5c6ffee0d6 AS runtime
COPY LICENSE NOTICE /usr/share/doc/mysql-replicator/
COPY --from=build /out/packaging-probe /usr/local/bin/packaging-probe
COPY --from=build /out/mysql-replicator /usr/local/bin/mysql-replicator
COPY --from=build /out/evidence /opt/packaging-evidence
COPY tests/ReplicatorLabTests/Fixtures/source-positive.binlog /opt/inspect-fixtures/source-positive.binlog
COPY tests/ReplicatorCodecTests/Schema/source-positive.json /opt/inspect-fixtures/source-positive.json
ENTRYPOINT ["/usr/local/bin/packaging-probe"]

# The production runtime remains unchanged; demo tools use the same pinned SQLite.
FROM build AS demo-tools
RUN make -f packaging/Makefile demo-tools
FROM runtime AS demo
COPY --from=demo-tools /out/sqlite3 /usr/local/bin/sqlite3

# Build and verify Debian package (.deb)
# Packaging-only edits must not invalidate the compiler layer. Dependency
# notices are collected above while Swift/Cargo cache mounts are available.
FROM build AS deb
ARG VERSION
COPY LICENSE NOTICE ./
COPY packaging/debian packaging/debian
COPY packaging/install.sh packaging/
COPY examples examples
RUN if [ -n "$VERSION" ]; then make -f packaging/Makefile deb VERSION="$VERSION"; else make -f packaging/Makefile deb; fi

# Verify .deb installation in clean Ubuntu 16.04
FROM --platform=linux/amd64 ubuntu:16.04@sha256:1f1a2d56de1d604801a9671f301190704c25d604a416f59e03c04f5c6ffee0d6 AS deb-test
COPY --from=deb /out/deb/ /tmp/deb/
RUN cd /tmp/deb && sha256sum --check *.sha256 \
    && dpkg -i /tmp/deb/*.deb \
    && /usr/bin/mysql-replicator --version \
    && test -f /lib/systemd/system/mysql-replicator.service \
    && test -f /etc/mysql-replicator/apply.example.yaml \
    && test -d /var/lib/mysql-replicator

# Scratch export target for Docker BuildKit --output
FROM scratch AS deb-export
COPY --from=deb /out/deb/ /

# Package both formats from the SAME compiled binary, then test before export.
FROM deb AS release
COPY docs/INSTALL.md docs/INSTALL.md
RUN make -f packaging/Makefile release
FROM deb-test AS release-test
COPY --from=release /out/release /release
COPY packaging/test-release.sh /test-release.sh
RUN sh /test-release.sh && touch /release-verified
FROM scratch AS release-export
COPY --from=release /out/release/ /
COPY --from=release-test /release-verified /release-verified
