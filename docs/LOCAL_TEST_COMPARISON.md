# Compare local test groups

Use a small local comparison before changing CI groups. Keep the source revision,
MySQL settings, profile, variant and transport the same. Run timing tests with the
release image. Run a separate comparison with the coverage image when you need
line coverage. Do not compare release times with instrumented times.

`tools/lab_compare.py` records a lab invocation and compares saved results. It
reads case results, named assertions, SQL traces and optional coverage. It does
not change the test selection or remove tests. Use shared fixture results that
include `runtime.json`, `cases.json` and `sql-trace.jsonl`. An adapter without
these files needs additional exports before this tool can compare it.

## Prepare the images

Build the matching lab runner and image before the measurement. Use the normal
lab command without `--skip-build` for an initial run. Add `--coverage` to prepare
and check the coverage image. See [TEST_LAB.md](TEST_LAB.md) for build controls.

Do not run a build or another test at the same time as the comparison. Keep the
host load stable. Existing demo containers can affect local times. Record this
condition in the study notes. Local results do not predict GitHub runner times.

## Record and compare

This example compares two separate invocations with one combined invocation.
The second case requires `database-explicit`, so its separate invocation also
runs that prerequisite. The combined invocation runs each case once.

```sh
python3 tools/lab_compare.py record --output artifacts/study/a.json -- \
  .build/debug/replicator-lab test --profile mysql57-to-mysql57-innodb \
  --suite correctness --case database-explicit --skip-build
python3 tools/lab_compare.py record --output artifacts/study/b.json -- \
  .build/debug/replicator-lab test --profile mysql57-to-mysql57-innodb \
  --suite correctness --case database-existing-different --skip-build
python3 tools/lab_compare.py record --output artifacts/study/combined.json -- \
  .build/debug/replicator-lab test --profile mysql57-to-mysql57-innodb \
  --suite correctness --case database-explicit \
  --case database-existing-different --skip-build
python3 tools/lab_compare.py compare \
  --baseline artifacts/study/a.json artifacts/study/b.json \
  --candidate artifacts/study/combined.json --output artifacts/study/comparison
```

Use new output paths for repeated runs. The recorder does not overwrite a
measurement. Add `--coverage` to each lab command for a coverage comparison.
Do not run other lab invocations while the recorder is active. It detects the
new top-level result file and requires exactly one result per invocation.

The recorder saves each MySQL image's filesystem layers and runtime
configuration after the command. This inspection is outside the measured time.
Compose adds a different project label to each fixture image. The comparison
ignores only `com.docker.compose.*` labels. It still checks layers, architecture,
OS, other labels, entrypoint, environment and other image configuration.
Do not replace or remove the fixture image before recording completes.

You can also give `compare` existing top-level `artifacts/lab/RUN/result.json`
files. Without measurement files, elapsed time is `unmeasured`. Do not estimate
elapsed time from file timestamps or add nested case times. Older records lack
image snapshots and require exact server image IDs. They can therefore reject
separate Compose runs even when the server files did not change.

## Read the results

The output directory contains `comparison.json` and `comparison.md`.

- **Elapsed seconds:** the complete invocation, including fixtures, cleanup and
  any coverage export. `--skip-build` excludes the lab runtime image build.
  Fixture setup still runs Compose builds for MySQL images. Prepare those
  layers first and check that the measured runs use cached layers.
- **Unique cases:** profile, variant, suite, transport and case ID combinations.
  Execution counts also show repeated prerequisites.
- **Unique assertions:** case records plus their named assertion IDs, with the
  same profile, variant, suite and transport. These are recorded checks, not a
  count of every assertion in Swift source.
- **SQL calls and time:** harness MySQL client calls, split between active cases
  and calls outside cases. These include Docker and client startup time. They do
  not measure the applier's target SQL calls. Calls outside cases can include
  setup, waits, final checks and cleanup.
- **Coverage differences:** first-party Swift runtime lines lost or gained in
  the candidate. Rust, dependencies and lab code are excluded. Coverage is for
  complete fixtures, not individual cases. Timing-dependent paths can vary.

The comparison rejects failed results, mixed builds, different server settings,
missing traces, unfinished SQL calls and incompatible coverage source maps. A
failed lab process retains its measurement and result path. Inspect its support
bundle before another run.

A successful comparison command means that the inputs can be compared. Inspect
`same_case_and_assertion_sets`, missing cases, missing assertions and coverage
changes. Equal names and line sets do not prove equivalent behavior. Review SQL,
expected outcomes, fixture isolation and restart boundaries before removing work.

A one-pass timing result is a local observation. Repeat important measurements
with the run order reversed. Confirm CI job time and runner cost in GitHub.
