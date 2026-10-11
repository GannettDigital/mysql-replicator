# CI timing and coverage measurements

Use the beta.4 release stack to collect a baseline for all four profiles.
PR checks use unit tests, Periphery and two parallel smoke suites. Main retains
the full catalog. Add `ci-full` to the top release PR to run that catalog before
merge. See [release testing](RELEASE_TESTING.md) for the evidence and release gate.
The targets for later work are five minutes for PR feedback and twenty minutes
for the complete merge checks. This change does not claim those times.

## Normal CI

Each integration shard writes a measurement, including failed runs. The final
`Timing & Profile Coverage Report` job publishes `ci-measurement-report`.
Read `summary.md` first. Use `report.json` for job, step and shard times.
The `ci-measurement-*` artifacts contain the source-matched line maps and case
times for each shard. The report contains no row values, SQL or credentials.
Normal integration evidence can still contain sensitive data.

The report separates these measurements:

- Catalog coverage: passed obligations divided by applicable obligations for
  each selected profile and scope. Ordinary PR scope is `pr-smoke`. PRs with
  `ci-full` and main use `full`. Manual runs default to `full`. This is coverage of our selected catalog, not all MySQL features.
- Code coverage: the union of mapped Swift runtime lines reached by instrumented
  runs. It excludes Rust, dependencies and the lab. The existing combined Swift
  report also includes unit coverage.
- Time: job and step time from GitHub, shard time from a monotonic clock, and
  case time from the shared reporter. Case time includes waits and assertions.
  Nested cases overlap. Do not add their times to estimate total runtime.

Code coverage belongs to a shard, not an individual case. A shard includes
fixture setup and cleanup. A line reached by one profile alone is marked unique
relative to the other measured profiles. Equal line coverage does not prove
that two tests check the same behavior. SIGKILL paths cannot flush LLVM counters.

Missing shards, failed runs or missing expected coverage collections make the
report partial and fail its job. Missing catalog results are listed explicitly.
Keep the run ID, attempt and commit with downloaded evidence. Do not mix attempts.

## Expanded coverage for the release candidate

Start expanded coverage manually on the release candidate branch or tag.
The `ci-full` label runs the full PR suite without expanded instrumentation.
The `ci-expanded-coverage` label has no effect. After the workflow is available
on main, use:

```sh
gh workflow run ci.yml --ref <branch-or-tag> -f suite=full -f expanded_coverage=true
```

Expanded mode retains every release-binary shard. It adds instrumented copies
of shared correctness and lifecycle shards for every applicable variant.
Ordinary PR CI has two smoke shards and two integration coverage collections.
The current full plan has 120 shards and 227 expanded shards. Both full plans own
718 catalog obligations. There are 23 full-plan coverage collections and 130
expanded collections. The generated matrix is the authority if the catalog grows.

Native-reference and specialized recovery adapters do not export line coverage.
Their existing tests remain required. Demo collections remain instrumented.
This experiment is more expensive than normal CI. It is evidence for later
selection changes. It is separate from the PR smoke selection.

## Cold and warm build comparison

Add `ci-cache-study` to the final release PR to start `CI Cache Study`.
The workflow can also be started manually after it is available on main:

```sh
gh workflow run ci-cache-study.yml --ref <branch-or-tag>
```

The study builds release packages and the coverage image. It uses fresh runners
for the cold and warm phases. Both phases use the same commit and build commands.
Each run attempt has an isolated GHCR layer-cache reference. Compiler output
is stored in those layers. The study does not clear or overwrite normal CI
caches. Cold disables layer reuse. Warm imports that experiment's layers.
The study requires registry write access and does not run on fork PRs.

Download `ci-cache-comparison`. The comparison is invalid if a build fails, the
warm registry cache is missing, the cold run imported a cache,
or the commit or runner image differs. Read the build logs for Docker layer hits
and Swift timestamp restoration. `cache_hit` means that the warm registry
manifest was available. It does not prove that a build step used cached output.
Job times include registry login and manifest lookup. The build timer includes
layer cache transfer and output export. See [CI build caching](CI_BUILD_CACHE.md).

This is an exact-revision reuse test. It does not measure incremental compilation
after an edit, or unit-test and lab-tool build caches. Repeat complete pairs to
measure variation. Use **Re-run all jobs**, not **Re-run failed jobs**: a new run
attempt needs both phases to populate its isolated caches.

## Review the evidence

Collect one complete expanded report and at least two valid cold/warm pairs on
the release candidate. Compare runner-minutes as well as elapsed time. Check
build time, cache transfer, image download/load, fixture time and the longest
shards. Do not treat the delay before a dependent job starts as proven runner
queue time. GitHub step times have second-level precision.

Keep the existing release process. These measurements do not replace its required
main CI run. The release workflow must publish the exact packages from that run.
The full-suite evidence file binds the report to the tested package checksums.
No release rebuild is added.
