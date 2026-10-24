# Beta.7 local test-group study

## Scope

The component-selection change is commit `f360a98`. This study starts the next
step: compare test cost and retained checks before removing repeated work.
It does not change CI selections or remove database tests.

The full plan has 2,095 case/profile/variant obligations in 246 execution groups.
CI assigns these groups to 130 jobs. The current grouping shares job setup and
image downloads. It keeps a separate database fixture for each execution group.
Local runs cannot measure GitHub queue, artifact download or runner setup time.

## Review of repeated case entries

The normal full plan has five repeated identities when the key includes profile,
variant, suite, transport, image type and case ID. All use
`mysql84-to-mysql57-myisam`, the default variant and SQL transport:

| Case | Image type | Groups |
|---|---|---|
| `positive` | release | `dml-6`, `sample` |
| `ddl-modify-demo-varchar-120` | release | `indexes-1`, `sample` |
| `ddl-index-create` | release | `indexes-2`, `sample` |
| `positive` | coverage | PR baseline, `sample` |
| `ddl-index-create` | coverage | PR baseline, `sample` |

The two same-version coverage smoke groups have no explicit case list in the
matrix. They are excluded from this count. Their actual results must be checked
before a removal decision. The CI test-value report now lists both repeated
identities and groups without explicit lists.

The shared runner uses the same case functions for these entries. The index
cases recreate their seed tables before each case. However, the sample group
restarts after its smaller selection. The larger groups restart after more
schema changes. Case identity alone does not compare that saved-schema state.

Different source versions, target engines, capture variants and transports are
separate behavior checks. Bootstrap and replicated DDL also test different schema
starting states. Equal line coverage does not make these checks interchangeable.

The saved beta.6 [CI run 39509695777](https://github.com/GannettDigital/mysql-replicator/actions/runs/39509695777)
reported 133.8 release seconds and 127.9 coverage seconds for the sample area.
Its instrumented sample reached 33 lines beyond the two PR baseline groups,
including two lines not reached by other measured areas. Normal full CI measured
only selected groups. These counts do not establish whether the release groups
reached those lines. Beta.7 changed the source and catalog, so those old line
counts cannot be combined with current coverage.

## Local experiment

Compare two separate invocations with one combined invocation:

1. Run `database-explicit` by itself.
2. Run `database-existing-different` by itself. The catalog adds its required
   `database-explicit` prerequisite.
3. Run both cases in one invocation.

Run this sequence with the release image. Use a separate coverage sequence to
measure line differences when the matching image is available. Keep the profile `mysql57-to-mysql57-innodb`, default capture variant and SQL transport.
Run all measurements in sequence. Complete image builds first.

The host is macOS ARM64. Docker reports an ARM64 VM with 14 CPUs and about
7.65 GiB of memory. Test images use AMD64 emulation. Existing demo and unrelated
containers remain running. The accepted comparison is one pass, not a controlled CI benchmark.
Lab and applier image preparation is excluded from the measurements. MySQL
fixture setup includes Compose image builds; these reuse cached layers. The release image built
successfully. The cold coverage dependency build stalled after compilation of
`NIOTLS`. Both remaining Swift build processes were sleeping without compiler
children. The cause is not established. The dependency files were saved before
the build was stopped. No separate build ran during the release measurements.

Fresh runtime coverage is not available from this experiment. The old coverage
image has different build inputs and cannot be used as a substitute. Do not
claim that this experiment retained the same executed lines.

Both cases are required:

- `database-explicit` creates an absent database with explicit compatible defaults.
- `database-existing-different` checks that `IF NOT EXISTS` keeps existing
  defaults and table data even when the statement requests different defaults.

Each case checks schema effects and subsequent INSERT, UPDATE and DELETE
operations. The runner also checks checkpoints and restart behavior. Some common
checks run outside named cases. They must be reviewed when fixture boundaries
change.

This is a small test of the comparison method. The current full CI database
family already runs these cases together. Savings in this experiment are not
additional savings from the committed CI job grouping.

## Measured release results

All three invocations passed on 2026-10-23 (local time). The comparison accepted
matching build inputs, applier image, MySQL image contents and server settings.

| Measurement | Separate runs | Combined run |
|---|---:|---:|
| Complete invocation time | 184.16 s | 104.20 s |
| Fixtures | 2 | 1 |
| Unique cases | 2 | 2 |
| Case executions | 3 | 2 |
| Unique recorded check IDs | 6 | 6 |
| Recorded check executions | 9 | 6 |
| Harness SQL client calls | 379 | 229 |
| SQL calls outside named cases | 117 | 58 |
| SQL client elapsed time | 63.98 s | 39.80 s |

The combined run used 43.4% less elapsed time and
39.6% fewer SQL client calls in this pass. It retained both cases and all
four named assertions. The six recorded check IDs include those four assertions
and the two case records. The combined run executed the prerequisite once and
used one set of fixture setup, final checkpoint and restart checks. Polling can
cause small changes in SQL call counts.

This supports measuring fixture cost separately from case cost. It does not prove
that another selection can share a fixture safely. The database family already
uses this combined selection in full CI. No new CI saving or code-coverage gain
is claimed. Fresh runtime line coverage remains unmeasured.

The comparison and CI report changes pass 16 focused Python tests. These tests
cover dropped cases and checks, coverage differences, stale metadata, interrupted
runs, image-content changes, and repeated-case classification.

## Image identity check

The first three release invocations passed, but the report rejected their
server image IDs. Docker Compose adds the unique fixture project name to its
image labels. This changes the image ID even when Docker reuses the build layers.
The older image IDs were no longer available for inspection after later runs.

The recorder now saves the server image layers and runtime configuration before
the next run. Comparison ignores only generated `com.docker.compose.*` labels.
It still checks the filesystem layers, architecture, OS and all other image
configuration. The three focused invocations were repeated with this recording.
Their results are under `verified-images/`. The first measurements remain saved
but are not the accepted comparison.

## Evidence

Local files are under `artifacts/test-group-study/` in the beta.7 worktree:

- `run.py`: the three-command sequence, with separate release and coverage modes.
  Only the release mode completed in this study.
- `verified-images/release-*.json`: command, elapsed time, result paths and
  MySQL image snapshots.
- Matching `.log` files: full process output.
- `verified-images/release-comparison/`: JSON and Markdown comparison.
- `coverage-dependencies.tar`: files saved from the stopped coverage build.
- `repeated-cases.json`: the repeated case inventory used for review.

`tools/lab_compare.py` requires matching build inputs, runtime images, MySQL
settings and coverage source maps. It compares case and named-check sets and
retains exact missing/gained line lists. Its reports omit SQL text and row data.
The original trace files retain the SQL for local review.

## Decision and next comparison

This section records the decision at the end of the initial study. The
[subsequent sample review](BETA7_SAMPLE_REVIEW.md) records the next comparison.

Keep the current tests and CI selections. The exact repeated entries are
candidates for review, not confirmed redundant tests.

Next, compare the sample selection with the full groups that contain its cases.
Use matching source and image inputs. Check the final saved schemas and restart
assertions, as well as the named cases. Collect line coverage with the matching
coverage image. Do not remove the sample coverage run until its additional lines
are covered elsewhere or the corresponding behavior has a retained test.

After this review, measure the long DDL groups and divide them at independent
case boundaries. Preserve prerequisites in each group. The saved CI run shows
30–40 minute DDL groups, so their balance can affect total CI time more than the
roughly two-minute sample runs. Confirm this with current per-case measurements
before choosing new boundaries.
