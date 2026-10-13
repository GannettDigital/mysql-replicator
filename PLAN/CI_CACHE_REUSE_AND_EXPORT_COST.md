# CI cache reuse and image export cost

Status: measured; follow-up work is deferred.
Date: 2026-10-11.

## Result

PR #40 reused the compilation layers from PR #39. SQLite, Rust dependencies
(including zstd), Swift dependencies (including NIO/NIOSSL), the application,
and the packaging probe did not compile again.

The first PR #40 build had no cache for its own branch. The `main` cache was also
absent. It imported the cache from the base branch for PR #39. This confirms
reuse between stack branches, not only reuse after a rerun on one branch.
The later PR #40 build also reused the compilation layers.

## Evidence

| Run | Commit | Evidence |
| --- | --- | --- |
| PR #39 | `b8c64e6` | [Completed CI run 38159721064](https://github.com/GannettDigital/mysql-replicator/actions/runs/38159721064) |
| PR #40, first attempt | `b97caf0` | [Run 38163592590](https://github.com/GannettDigital/mysql-replicator/actions/runs/38163592590); coverage build passed; release job was later cancelled |
| PR #40, after cache-study removal | `958444a` | [Run 38163858026](https://github.com/GannettDigital/mysql-replicator/actions/runs/38163858026); both image build jobs passed |

The first PR #40 logs show these branch cache suffixes:

- PR #39, `beta/4/11-static-build-reuse`: `c0e15abee0419a2baf9f`.
- PR #40, `beta/4/12-coverage-value`: `316c0eb6e1ea89325c8e`.

The PR #40 suffix was absent at the first package and coverage cache import.
The PR #39 suffix was available. The logs show `CACHED` for the compiler stages
and no compiler output in either PR #40 build attempt.

| Measurement | PR #39 | PR #40 at `958444a` |
| --- | ---: | ---: |
| Build and verify Linux packages | 12m02s | 10s |
| Build instrumented runtime and matching LLVM exporter | 7m52s | 4s |
| Entire release build job | 13m07s | 2m55s |
| Entire coverage build job | 8m15s | 18s |

Sources: PR #39 `ci-measurement-report/summary.md` and `report.json`, plus the
completed build job logs and step times. PR #40 jobs:

- [Release build 114542525206](https://github.com/GannettDigital/mysql-replicator/actions/runs/38163858026/job/114542525206).
- [Coverage build 114542525192](https://github.com/GannettDigital/mysql-replicator/actions/runs/38163858026/job/114542525192).

Local copies were retained under `artifacts/ci/cache-pr39-pr40/`. These files
are ignored build evidence. GitHub artifact and log retention can expire.

## Remaining cost

The PR #40 release job spent 1m44s in `Export the tested release runtime`.
Its log shows about 74 seconds materializing cached layers for the `build`
stage. That stage holds compiler and dependency files as well as final output.
The compiler stages still used cached output. Image export, Docker loading,
registry transfer, setup and validation account for the remaining job work.

This is the next build-cost area to investigate. No additional dependency-cache
fix is indicated by this comparison.

## Proposed follow-up

1. Measure layer sizes and the time spent restoring, extracting, exporting,
   loading and pushing the release runtime. Separate these costs from compilation.
2. Check whether a small stage containing only final binaries and evidence can
   avoid materializing the full builder filesystem during runtime export.
   Treat this as a hypothesis until a fresh-runner measurement confirms it.
3. Check whether package export and runtime export can share the required output
   more efficiently. Keep the package and integration binary identity check.
4. Compare normal CI jobs before and after a change. Retain static ELF checks,
   Ubuntu 16.04 package checks, license evidence and release-binary tests.

Do not restore the retired CI Cache Study workflow for this work. Use normal
build job evidence. Record both step times and total job times.

## Limits

This comparison covers CI, reporting and documentation edits. It does not prove
GitHub cache reuse after application source, dependency or toolchain changes.
PR #39 introduced a new build layout, so its times are not a controlled cold
baseline. These observations are not a CI time guarantee.

Passing image builds does not establish that the full test suite passed.
PR #40 test failures need a separate review. Use the support bundles and the
measurement report as described in [AGENTS.md](../AGENTS.md).

See [CI build caching](../docs/CI_BUILD_CACHE.md) and
[CI measurements](../docs/CI_MEASUREMENTS.md) for the current implementation.
