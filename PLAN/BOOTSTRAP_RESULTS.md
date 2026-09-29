# Repository bootstrap results — 2026-09-29

This is an initial Phase 1 increment, not a Phase 1 exit report.

## Passed

- `./scripts/build.sh`: pinned `mysql_common` 0.38.2 commit compiled with `binlog`, Rust static adapter linked into Swift, executable reported ABI 1/capabilities 0. Host: macOS arm64, Swift 6.2.1, Rust/Cargo 1.93.1. This is a version-only ABI skeleton, not a decoder qualification run.
- CLI help/version exit 0; unsupported `run`/`inspect` commands exit 64.
- Python syntax and Compose configuration validation.
- `python3 tests/harness/native_smoke.py`: fresh 8.4.8 InnoDB source, 8.4.8 MyISAM native reference and 5.7.42 MyISAM future Swift target. Source/native exact rows agree after committed insert/update/delete, unsigned UINT64_MAX and rolled-back source insert. Both target engines remain MyISAM. Direct target MyISAM rollback probes retain their writes. The 5.7 application table stays at the seed boundary.
- Captured nine closed raw binlogs across the three servers, plus SHA-256 digests, versions/settings, seed/end boundaries, native status, operation manifest, expected/actual rows and container logs. Verified saved digests after capture. Isolated containers and volumes were removed successfully.

Successful run: `artifacts/native-smoke/20260929T190517Z-ae997a04/`. Artifacts are retained locally and ignored by Git. They were generated in a temporary staging checkout before the repository was installed at its final path; recorded Compose paths reflect that staging location.

## Findings and open gates

The first GTID-enabled run (`20260929T185639Z-771ef497`) stopped native apply with error 1837 on the initial multi-statement transaction. The container log records the `GTID_NEXT` diagnostic. The current script preserves this scenario under `--gtid` and captures native status at the barrier before failing. The successful baseline explicitly uses GTID OFF and positional replication; production GTID compatibility is unproven.

An intermediate positional run (`20260929T185850Z-688a327f`) passed row/engine/rollback assertions but failed when trying to invoke `mysqlbinlog`: the minimal 8.4 image does not include it. The final harness captures raw files and leaves independent decoding/logical comparison pending. The raw magic/size check and SHA-256 capture do not validate event CRCs or semantics.

Swift capture, codec decoding, SQLite persistence, JSON inspect and target apply are unimplemented. Upstream binlog tests have historical evidence in the imported decision, but were not rerun as part of this bootstrap. Normalized event comparison, negative comparator tests, failure injection, the full ABI contract and Ubuntu 16.04 packaging remain open. See IMPLEMENTATION_STATUS.md and the approved plan.

## GTID follow-up

The original all-OFF success above is historical control evidence only. The current harness keeps source GTIDs ON, configures both replicas OFF_PERMISSIVE/WARN and uses GTID auto-positioning. See [the follow-up results](GTID_QUALIFICATION.md); permissive replica settings alone do not resolve the observed MyISAM apply failure. The default was changed accordingly, and failed native runs now retain raw binlogs and labeled replication errors.

## Automation replacement

The Python and shell commands above describe historical bootstrap runs. Current automation uses SwiftPM and Make; see [Phase 1 progress](PHASE_1_PROGRESS.md) and the repository README for supported commands.
