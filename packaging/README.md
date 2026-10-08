# Linux packaging and qualification

For downloading and running released binaries, see [installation](../docs/INSTALL.md).
Contributors can build verified release assets with `make release-artifacts`
(Docker and Python only). The commands below provide deeper qualification evidence.

Run `make release-image` afterwards to build a Linux/amd64 production image from
the verified archive. This uses `docker/release/Dockerfile`, a separate scratch
image containing the distribution, notices, a private writable state parent and
`/tmp`. It defaults to UID/GID 65532 and executes the replicator directly.
No compiler, shell, test probe or fixture is shipped in this image. Mount the CA
files required by your YAML; the scratch image has no system CA bundle.

The image check exercises version/help, non-root directory permissions and
offline binlog decoding, and compares the image executable with the archive.
It saves the tested image in `artifacts/release/` and adds its checksum. CI also
tests the standalone installer against the actual binary archive, with only the
download transport replaced. Publishing a GitHub release later promotes the saved
image to GHCR; it never recompiles or rebuilds the image. See
[release procedure](../docs/RELEASING.md) for visibility and publication steps.

Run from the repository root:

```sh
make ubuntu-smoke
# Equivalent:
swift run replicator-lab ubuntu-smoke
# Reuse an already built local test image (its ID is recorded):
make ubuntu-smoke ARGS=--skip-build
```

Prerequisites: Docker with Linux/amd64 execution support, host SwiftPM, OpenSSL and network access for the first build. The first build downloads the SDK and dependencies. No Swift, Rust or SQLite installation is made on the host by the Docker build. The lab command uses a fresh private Docker network and disposable database volumes, publishes no ports, and removes its containers/network/volumes on success or failure. It does not touch existing database containers. Test certificates and synthetic credentials are local fixture material.

## Persistent build caches

Docker BuildKit cache mounts retain the production `.build`, the probe's `.build`,
Cargo registry/git downloads and the musl Cargo target directory across image
rebuilds. Swift dependency compilation survives source `COPY` changes. Compiler
caches are locked during a build so concurrent harness builds cannot modify them
at once. These caches live in the Docker builder's managed storage, not in the
host macOS `.build`; no host-path setup is needed. Pruning Docker build caches
makes the next build cold again.

The Make build removes each Swift executable after building its Rust archive.
That forces a relink while preserving dependency
objects, so SwiftPM cannot silently reuse an executable linked to an older Rust
archive. Source and lockfile changes are still checked by the build tools.
`--skip-build` skips that verification entirely; use it only for an image already
built from the code being tested.

## What is built

The builder uses pinned Swift 6.2.1 and Rust 1.93.1 images and the checksum-verified Swift 6.2.1 Static Linux SDK. The builder runs on Docker's native CPU architecture; Swift and Rust cross-compile to x86_64 musl. C sources, including SQLite and zstd, use the same SDK sysroot. Native host build tools remain glibc programs; none of their libraries are linked into the target executable.

The runtime image is digest-pinned Ubuntu 16.04.7 with glibc 2.23. No newer glibc or Swift runtime is installed there. Build checks reject an ELF interpreter or dynamically needed libraries.

Two executables are produced:

- `mysql-replicator`: the current production executable, now including the bounded offline decoder and JSON inspector.
- `packaging-probe`: a separate Swift package exercising MySQLNIO 1.9.1, NIO 2.90.0, NIOSSL 2.37.0, pinned SQLite 3.53.4, the selected Rust mysql_common revision and zstd 0.13.3 / native zstd 1.5.7. It calls these libraries, preventing a successful link caused by dead-stripping all unused dependency code.

Both Swift and Rust dependency resolutions are committed. The packaging Rust crate uses the production codec revision/features without upstream's test-only MySQL C++ dependencies. Its self-test accepts only its compiled-in synthetic fixture and returns event/row counts. This probe is not the production decoder ABI or its error/ownership qualification.

## What runs

1. Record Docker CPU architecture/kernel, runtime OS, glibc version, static ELF metadata, binary hashes and toolchain versions. Run `mysql-replicator inspect` on the saved source binlog and compare the four workload operations with independent expectations.
2. Exercise Rust event framing/CRC/row decoding on the committed source fixture and zstd compression/decompression.
3. Resolve a local MySQL server through DNS, fire a NIO timer, authenticate through MySQLNIO over verified TLS, and query an exact UINT64_MAX value. Confirm an active TLS cipher and reject a wrong hostname and an untrusted CA.
4. Write and commit an exact value and binary bytes to SQLite with WAL/FULL synchronization, then begin an uncommitted write. After the writer reports that boundary, kill its container with SIGKILL.
5. Start a fresh process on the same Docker volume: require only the committed row, run integrity_check, verify exclusion of a second writer and truncate the WAL through SQLite's checkpoint API. Restart that process and repeat the assertions.
6. Preserve evidence and binaries under `artifacts/ubuntu/<run>/`, then clean up.

An expected TLS rejection is a passing assertion, but any unexpected connection/build/recovery failure fails the run. There is no Docker requirement for ordinary `make test`.

The initial run passed; see [recorded Ubuntu packaging results](../PLAN/UBUNTU_PACKAGING_RESULTS.md).

## Debian packaging (`.deb`)

Build the standalone Debian package locally or in CI:

```sh
make deb
# Custom output directory (version comes from VERSION):
make deb ARGS="--output dist"
# Equivalent:
swift run replicator-lab package-deb [--output DIR] [--skip-build] [--skip-verification]
```

The package version is derived from `VERSION`; `package-deb --version` overrides
are no longer supported. To change it, edit `VERSION` and run
`python3 tools/release_version.py --write` before rebuilding.

### Package structure
- `/usr/bin/mysql-replicator` (statically linked x86_64 musl binary, mode `0755`)
- `/lib/systemd/system/mysql-replicator.service` (systemd service unit, mode `0644`)
- `/etc/mysql-replicator/apply.example.yaml` (configuration template, marked as Debian conffile)
- `/var/lib/mysql-replicator/` (service-owned state parent, mode `0750`; initialization creates its `state` child)
- `/usr/share/doc/mysql-replicator/` (project license, notices and dependency license inventory)

The service reads `/etc/mysql-replicator/apply.yaml`. Copy and edit the commented
template before starting it. Existing JSON configurations must be converted to
YAML; the service no longer reads `apply.json`. The service runs as
`mysql-replicator`, resumes only previously initialized state and does not restart
a failure automatically. See the install guide for first start and clean resume.

The packaging pipeline:
1. Compiles the static x86_64 musl binary inside the Docker builder using the pinned Swift Static Linux SDK and Rust toolchain.
2. Stages the Debian directory structure and metadata (`DEBIAN/control`, `conffiles`, `postinst`, `prerm`), using `dpkg-deb --root-owner-group -Zxz`; post-install assigns the private state parent to the service account.
3. Automatically verifies package installation (`dpkg -i`) and checks executable/service presence in a clean Ubuntu 16.04 container.
4. Exports the resulting `.deb` and `.deb.sha256` to the host (`artifacts/deb/` by default).

## What this can establish

A passing test establishes that this dependency stack can build as a static x86_64 executable and perform these operations in Ubuntu 16.04 **userland** under the recorded Docker kernel. Docker on Apple Silicon emulates the x86_64 runtime; these timings are not fleet performance measurements. Containers share Docker's kernel, so an Ubuntu 16.04 container does not boot Ubuntu's original kernel.

The fleet's actual kernel, CPU, filesystem, CA configuration and service manager still require a VM/host test. Process-kill WAL recovery does not demonstrate power-loss durability. This fixture verifies a supplied CA file; it does not test the fleet's system trust store or certificate rotation. No replication reader/applier, Cloud SQL connectivity, performance profile, systemd unit or complete production ABI is qualified by this command.

Sources: [Swift Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html), [Swift 6.2.1 download/checksum metadata](https://www.swift.org/install/linux/ubuntu/22_04/), [Docker multi-platform execution](https://docs.docker.com/build/building/multi-platform/), [SQLite downloads and published SHA3 hashes](https://www.sqlite.org/download.html).
SQLite archive SHA3-256: `628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`; the Dockerfile pins the matching archive's SHA-256. Static dependencies must be updated by rebuilding and redistributing the executable; this experiment's versions are reproducibility pins, not a promise of indefinite release suitability.
