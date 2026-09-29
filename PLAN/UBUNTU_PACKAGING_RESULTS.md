# Ubuntu 16.04 container packaging results

Date: 2026-09-29. Status: **container userland spike passed; fleet qualification remains open**.

Reproduce with `make ubuntu-smoke`, or `swift run replicator-lab ubuntu-smoke`.
Implementation, pinned inputs and limits: [packaging/README.md](../packaging/README.md).

## Observed result

Run `replicator-ubuntu-20260929t214214z-73357994` passed all assertions and cleanup. Evidence and both Linux binaries are retained locally under `artifacts/ubuntu/<run>/`. They are ignored by Git. The test was developed in a temporary checkout; absolute paths in its logs identify that historical checkout.

| Check | Result |
| --- | --- |
| Runtime OS | Ubuntu 16.04.7, glibc 2.23; no newer runtime libraries installed |
| Target executables | x86_64 Linux musl, statically linked; no ELF interpreter or NEEDED libraries |
| Production CLI skeleton | `--version` runs, codec ABI 1, capabilities 0 |
| Swift / Rust compiler | 6.2.1 / 1.93.1 in pinned Docker images |
| Swift SDK | 6.2.1 Static Linux 0.0.1, archive checksum verified; SDK SBOM retained |
| Rust mysql_common | Selected pinned revision decodes 36 events / 6 row images from the committed source fixture with CRC checks |
| zstd | Compress/decompress roundtrip returns exact original fixture bytes |
| NIO | DNS resolution, timer and TCP connectivity passed |
| MySQLNIO / NIOSSL | MySQL 8.4.8 authentication and exact UINT64_MAX query over verified TLS passed |
| TLS negatives | Wrong hostname gives `failedToValidateHostname`; empty trust roots give `CERTIFICATE_VERIFY_FAILED` |
| SQLite | Pinned 3.53.4, WAL mode and FULL synchronization verified |
| SQLite process crash | SIGKILL after committed row plus open uncommitted transaction; recovered exactly the committed value and binary bytes |
| SQLite locking / checkpoint | Second writer gets SQLITE_BUSY; integrity_check succeeds; WAL truncate checkpoint succeeds |
| Restart | Second recovery process succeeds with identical assertions |
| Existing host tests | All 13 Swift tests pass |

The saved release executables are unstripped: the dependency probe is 204,638,312 bytes and the CLI skeleton is 149,344,464 bytes. These are qualification artifacts; release size/stripping and distribution packaging remain to be finalized.

The runtime image ID is `sha256:611966d4e08d3821f7b8c36604c039777c7ddd1d8dd2480f1299dfaf0b203f49`. Dependency lockfiles, ELF metadata, binary SHA-256 digests and SDK SBOM are preserved in `build-evidence/`. The probe is separate from the production executable: current production decoding, capture and apply capabilities remain unimplemented.

## Meaning and remaining gates

Docker Desktop here runs an aarch64 VM with kernel `6.10.14-linuxkit`. The x86_64 runtime is emulated. The builder uses native aarch64 tools to cross-compile for x86_64; Rust's C dependencies and SQLite use the same musl sysroot as Swift. No decoder/dependency source patch was needed. Cargo's host build scripts required explicitly selecting the available Clang linker.

This demonstrates a viable packaging route without depending on Ubuntu 16.04's old glibc. It does not boot Ubuntu 16.04's kernel or establish bare-metal performance. Keep these gates open:

- Run the same artifacts on an x86_64 VM/host with the fleet's actual kernel, CPU and filesystem class; collect the per-pair kernel inventory.
- Qualify fleet CA loading and rotation, external/Cloud SQL TLS routing, service-manager installation and restart, signal handling and permissions.
- Qualify the eventual production capture/relay/applier and typed C ABI using the same dependency stack. The packaging probe's fixed-fixture C entry point does not implement that ABI.
- Verify power-loss/storage-failure durability, disk-full behavior and realistic resource profiles. A clean filesystem after process SIGKILL is not a power-loss test.
- Complete distribution licensing/notices, production dependency update policy and release artifact packaging before shipping.

The Phase 1 deployment risk is reduced, but Phase 1 is not complete.

## Subsequent decoder qualification

Run `replicator-ubuntu-20260929t230511z-5a362b66` also passed with production codec ABI 2 / capability 1. The actual offline inspector now runs in Ubuntu and reproduces the four expected workload operations; all 36 JSON events match host inspection. This extends the earlier packaging result without closing the fleet-kernel gate. See [offline inspection](OFFLINE_INSPECT.md) for the supported subset.
