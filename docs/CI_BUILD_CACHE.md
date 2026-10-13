# Docker layers and GHCR in CI

CI stores Docker build layers and test images in
`ghcr.io/<owner>/<repository>-ci`. This package is separate from release images.
The workflow does not change package visibility. Keep this CI package private:
its build layers contain source files and compiler output.

## Build layers

The release and coverage Dockerfiles have separate dependency stages. Each stage
uses pinned Swift and Rust base images. Release builds also use the pinned musl
SDK. SQLite, Rust dependencies and Swift dependencies have separate stages.
Probe and application source changes do not invalidate these stages.

`tools/build_dependencies.py` reads the root package manifest. It creates empty
source placeholders and builds `MySQLNIO`, `Crypto` and `Yams` with the final
build flags. It then removes the placeholders. The next stage copies the real
sources and compiles the application in the same `/workspace` path.

The dependency stage retains `.build`, including dependency checkouts, objects
and build databases. These files are ordinary layer contents. CI exports all
intermediate layers with `type=registry,mode=max`. No Docker cache mounts or
cache-dance archive are needed. Host unit, lab and Periphery caches remain as
separate Actions caches.

| Changed input | Build work |
|---|---|
| Application source | Reuse the dependency layer; build the application |
| Dependency lock, manifest or vendor source | Rebuild the dependency layer |
| Toolchain or SDK | Rebuild its dependent layers |
| Release installer or example config | Reuse compiled application output; rebuild package checks |
| Probe or fixture source | Reuse native and Swift dependency layers; rebuild affected consumers |
| Packaging Makefile or license collection | Reuse compiler output; rebuild package or evidence steps |
| Report or workflow only | Reuse matching build layers |

The application build can still recompile its own Swift and Rust code. This
design does not promise incremental reuse of application objects across edits.
`tools/swift_cache.py` restores unchanged file timestamps when layer transport
loses precision. Changed file contents remain invalidated.

## Static release components

The static build has three independent dependency paths:

- `sqlite` compiles the pinned SQLite archive with the musl sysroot.
- `rust-dependencies` builds both locked crate dependency graphs. Temporary crate
  sources select the dependencies. The helper removes those sources and cleans
  only the temporary crate outputs. Real codec and probe sources compile later.
- `dependencies` compiles the root Swift dependency graph once. The application
  and probe inherit the same objects, toolchain, paths and compiler flags.

The probe is an optional root-package product. `REPLICATOR_PACKAGING=1` enables
it only in the static builder. Normal unit tests and Periphery do not include it.
The probe uses the production vendored MySQLNIO and the root Swift lockfile.
It still exercises SQLite, MySQL/TLS, Rust decoding and zstd through real calls.
Its Rust ABI remains separate from the production codec ABI.

`packaging/static.mk` defines native compiler settings. `native.mk` builds native
components. `compile.mk` links Swift executables. `evidence.mk` records ELF checks,
hashes, toolchains and notices. `packaging/Makefile` packages the existing output.
An edit to package recipes no longer invalidates compilation.

The real Rust crate cannot reuse a temporary placeholder archive. The helper
uses package-scoped `cargo clean` before it removes placeholder sources. This
also handles a later Docker COPY whose source timestamps predate the stub build.
Dependency objects remain available. Swift recipes remove only the executable
before linking, because SwiftPM does not track external Rust archive changes.

The layer layout changes once for this update. Its first build can be cold.
Subsequent builds can reuse the new layers through the same GHCR cache policy.

### Local reuse checks

The 2026-10-11 check used an isolated build context on Docker Desktop. Each edit
changed a source comment or package recipe comment. Each run exported and checked
the release packages. These times include package work and local export.

| Input change | Compiler work | Local elapsed time |
| --- | --- | ---: |
| None, after the initial build | All compiler layers cached | 1.1 s |
| Swift application source | Swift executables; dependency layers cached | 99.5 s |
| Rust codec source | Codec crate; Rust and Swift dependency layers cached | 56.2 s |
| Packaging Makefile | No compilation; package steps rerun | 54.0 s |

The first static build and the Ubuntu 16.04 runtime probe passed. The probe checked
MySQL/TLS, decoding and SQLite crash recovery. The Rust cache test also used real
source with an old timestamp. It proved that the dependency stub cannot replace
the real crate and that dependency objects remain reusable.

These are local layer checks. They do not measure GHCR transfer or GitHub runner
performance. Registry reuse must be measured again after these layers are built
on GitHub.

## Cache access and image transfer

Normal CI uses the workflow's `GITHUB_TOKEN`. Build jobs require `packages: write`.
Integration jobs require only `packages: read`. The organization must permit
package creation, and the repository must have Actions access to the CI package.
No personal access token is required.

Each image type has a separate cache reference. Main writes its main cache.
A same-repository PR writes only its branch cache. It can read its own cache,
its base branch cache and main. This permits reuse between layers of a PR stack.
Fork PRs write only an isolated Actions layer cache. An unavailable registry cache
causes a cold build. A registry publication failure is reported as a job failure.

Build jobs publish test images with a run ID and attempt tag. They put the
immutable digest, image type and tested commit in `ci-image-*/image.json`.
Integration jobs validate this record, pull by digest and assign the local tag
that the lab expects. Fork jobs retain the checksummed image archive transfer.
The lab still checks the source/fixture fingerprint. Release jobs still compare
the test binary with the binary in the release archive.

The coverage runtime contains the applier, its Swift shared libraries, Python,
SQLite, source files and the matching `llvm-profdata` and `llvm-cov`. It does not
need the Swift or Rust compiler. `REPLICATOR_LLVM_BIN` identifies the copied LLVM
tools, so coverage export does not depend on a system LLVM version.

GHCR does not use the Actions cache expiry policy. Keep current branch caches
and image digests needed by active runs or reruns. Old run tags and closed-branch
caches need a package retention policy. Automatic deletion is not added here.

## Measure reuse

The [PR #36 baseline](https://github.com/GannettDigital/mysql-replicator/actions/runs/38107774631)
passed all 18 smoke obligations before this cache change. It took about
22 minutes and used 40.6 runner-minutes. Its coverage build job took 13m32s.
That job spent 9m18s in the Docker build, 2m05s saving the image, and 1m25s
in cache post steps. The two smoke jobs took about six minutes each, including
image transfer. Periphery took 7m55s. These times are a baseline, not a prediction
for GHCR. Host cache reuse also needs measurement.

Use the normal CI build job times and Docker logs to assess cache reuse.
Check the log for cached dependency steps. A registry manifest that exists does not prove compiler reuse.

Also test a source edit after the first run. The dependency stage must remain
cached and the application stage must rebuild. Record build time, registry
transfer time and integration startup time separately. The five-minute PR target
requires measurement on GitHub workers.

References: [Docker registry cache](https://docs.docker.com/build/cache/backends/registry/),
[Docker cache mounts in Actions](https://docs.docker.com/build/ci/github-actions/cache/),
and [GHCR workflow access](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry).
