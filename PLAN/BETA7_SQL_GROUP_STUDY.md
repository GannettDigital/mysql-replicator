# Beta.7 SQL cost and test grouping

## Scope

Keep the tested behavior, profile limits, transport checks, assertions and restart
checks. Change execution-group boundaries and improve their cost reports. Do not
remove a case because its SQL or line coverage resembles another case.

The input is full run `40124425871`, at commit
`ec8152bc2a1e21fd8329412fb8e42b9ce48b6551`. Its report is partial because some
cases failed. Use passing groups for time estimates. Failed groups can identify
expensive SQL before the failure; they cannot establish complete coverage.

## Findings

The reverse default profile passed both DDL groups. `ddl-1` contained 44 cases
and took 39.1 minutes; `ddl-2` contained five and took 2.5 minutes. The first group
mixed partitions, stored objects, identifiers, character sets and table changes.
DML used eight-case chunks. Those groups took between 1.7 and 13.8 minutes.
These are execution-group times, not complete GitHub job times.

`SharedCorrectness.step` waits for replication and compares database metadata
after each SQL step. DML cases create separate tables in the same database.
Later comparisons also inspect earlier tables. Sharing a fixture saves startup
work, but can increase repeated comparisons as tables accumulate.

The SQL report identifies known schema-comparison batches, position checks,
metadata reads, other reads, simple source statements, and calls outside cases.
Mixed SQL remains unclassified. It preserves exact SQL bytes in fingerprints;
only random batch framing is omitted. Repeated position checks can be required
waits. Equal SELECT text can check different data at different points.

The current line maps cover whole execution groups. They cannot assign exact
coverage to individual cases. The reverse default DDL area has only two lines
not reached by other measured integration areas, but checks 49 catalog cases.
This is not evidence that its partition, constraint or restart assertions are
redundant. Bootstrap tests and replicated-CREATE tests also have different
starting conditions. Keep both until a replacement preserves those checks.

## Named groups

`tools/ci_matrix.json` now contains explicit DDL and DML case lists. The planner
preserves catalog order within a group and includes required dependencies.
It rejects unknown cases, omitted cases and duplicate primary assignments.
Profile exclusions remain in the inventory. A new DDL/DML case requires a group
assignment. Other families retain their existing grouping rules.

| DDL group | Recorded reverse-default case minutes |
|---|---:|
| Partitions | 7.3 |
| Stored objects and executable comments | 5.1 |
| Identifiers and character sets | 4.3 |
| Columns, generated expressions and keys | 13.8 |
| Table changes and maintenance | 7.1 |

| DML group | Recorded reverse-default case minutes |
|---|---:|
| Encodings and ENUM/SET values | 12.0 |
| Numeric and temporal values | 3.1 |
| Row operations | 1.1 |
| Structured values, defaults and large values | 5.7 |

These are sums from the previous passing case records, not measured durations
for the new groups. The scheduling estimate adds the largest observed overhead
for the old family, adds 20%, and rounds up to a whole minute. Other profiles
can take longer. Update estimates after full CI.

The catalog comparison retains all 2,095 obligations and every selected
profile/variant/suite/transport/case combination. No executions were added or
removed from that set. PR case selection and BINLOG selections are unchanged.
The full plan changes from 240 to 250 groups/jobs, and from 253 to 263 coverage
collections. Splitting the long DDL groups increases fixture count; consolidating
DML groups offsets part of that increase. The aim is a shorter longest job and
clear case selection. A lower total runner cost is not yet established.

CI records all per-case SQL costs and the 20 most expensive repeated-call
fingerprints per group. `report.json` keeps the details; the Markdown report
lists the most expensive cases. No SQL text or row values enter these summaries.

## Local comparison

Use the existing instrumented binary on `mysql57-to-mysql84-innodb`, default
variant, SQL transport. Run `ddl-compat-partition-hash-forms` and
`ddl-compat-hash-list` separately, then in one fixture. The cases previously
belonged to different DDL groups. All three runs use the same build-input digest,
application image, source maps, and server settings.

The host runs AMD64 containers on ARM64. No build or other lab test runs during
these measurements. Existing user containers remain running. A local time is
not a prediction of GitHub time.

Evidence is in `artifacts/sql-group-study/`:

- `before-plan.json`, `after-plan.json`, and `plan-comparison.json`: inventory and
  selected-execution comparison.
- `reverse-measurements/` and `group-estimates.json`: downloaded case times and
  the scheduling estimates.
- `previous-sql-costs/`: cost report for the six previously downloaded failure
  artifacts. This is a sample, not the entire full run.
- `hash-forms.json`, `hash-list.json`, and `partition-combined.json`: local run
  measurements, result paths and server image identities.

### Partition comparison results

All three runs passed. The combined run retains both cases and all recorded
assertion IDs. Four saved step checks, including their result snapshots, match
exactly. No measured runtime line is lost; the combined run reaches 27 additional
lines. These include existing-database cleanup and its saved schema transitions.

| Measurement | Separate fixtures | Combined fixture |
|---|---:|---:|
| Elapsed seconds | 234.93 | 159.21 |
| Fixtures | 2 | 1 |
| SQL client calls | 406 | 349 |
| SQL client seconds | 73.27 | 60.08 |
| Runtime lines reached | 8,269 | 8,296 |

The observed saving is 75.72 seconds (32.2%) and 57 SQL client calls. This is one
comparison on one profile, not a full-suite saving or repeated benchmark.
See `partition-comparison/` and `partition-step-comparison.json` in the evidence
directory. The local checks do not establish timing for all five DDL groups.

### Numeric DML comparison results

Run `matrix-decimal` and `matrix-floatbounds` separately, then in one fixture,
with the same conditions as the partition comparison. All three runs passed.
The combined run retains both cases, all recorded assertion IDs, and all six
saved step checks with their expected and observed values. Full-database
snapshots include an additional table in the combined run; the harness still
checks equality across source, native and target after every step.

| Measurement | Separate fixtures | Combined fixture |
|---|---:|---:|
| Elapsed seconds | 170.20 | 96.12 |
| Fixtures | 2 | 1 |
| SQL client calls | 246 | 189 |
| SQL client seconds | 44.04 | 34.12 |
| Runtime lines reached | 7,394 | 7,394 |

No measured runtime line is lost or gained. The observed saving is 74.08 seconds
(43.5%) and 57 SQL client calls. Evidence is in `decimal.json`, `floatbounds.json`,
`numeric-combined.json`, `numeric-comparison/` and `numeric-step-comparison.json`.
This is another one-pass comparison; it does not measure all four DML groups.

### Validation and remaining measurement

- 109 CI tool tests and 26 lab-tool tests passed. These include group ownership,
  dependency closure, explicit assignment failures, trace pairing, copied-trace
  exclusion, fingerprints, SQL categories and CI report integration.
- The real catalog comparison found no missing or added selected executions.
  All 2,095 catalog obligations remain. All six focused integration runs passed.
- No application or harness Swift code changed. The same existing instrumented
  image served every local run. No full local suite was run.
- Full CI must verify all profiles, variants, new group combinations and all
  263 expected coverage collections. Compare its time and SQL reports with the
  earlier run. Do not claim a full-suite time reduction from these local pairs.

## JSON comparison batching

The harness previously opened a MySQL client for each JSON inspection query.
Each query checks at most 32 JSON paths in one row and column. Keep these queries
and combine them into batches of at most 32 queries or 256 KiB of query SQL.
Batch framing adds a small amount of SQL. A query larger than the byte limit runs
alone. Use the existing SQL batch reader to preserve result boundaries and exact
whitespace. Reject missing, extra, truncated or multiple-row inspection results.

Keep every type and scalar-value check. Keep SQL NULL distinct from JSON null.
Do not change row order, duplicate-row checks, intermediate comparisons, restart
checks or replay checks. No application code, test selection or fixture grouping
changes in this step.

Run `ddl-compat-keyless-rows` and `matrix-typedjson` together before and after the
change. Both runs use `mysql57-to-mysql84-innodb`, the default variant, SQL
transport and runtime coverage. Both pass. Builds run before measurement.

| Measurement | Before batching | After batching |
|---|---:|---:|
| Complete invocation, seconds | 339.71 | 300.88 |
| Selected cases, seconds | 244.64 | 205.92 |
| All SQL client calls | 1,171 | 945 |
| All SQL client seconds | 204.78 | 168.46 |
| JSON inspection queries | 378 | 378 |
| Client calls for JSON inspection | 378 | 153 |
| JSON inspection client seconds | 65.25 | 27.90 |
| Application runtime lines reached | 11,453 | 11,452 |

The complete invocation is 38.83 seconds shorter (11.4%). It includes fixture
setup, cleanup and coverage export. JSON batching removes 225 client calls.
One additional call differs outside the cases. Keyless JSON inspection changes
from 366 client calls to 147; typed JSON changes from 12 to six. All 378 inspection
queries retain the same SQL, role, case and execution count.

All 37 saved step results match exactly. This includes checks, expected values,
observed values, snapshots and warnings. Case and recorded assertion counts also
match. These are single local runs on AMD64 containers on an ARM64 host. They do
not establish a full-suite saving or an applier performance change.

The harness change requires different build-input digests and image IDs. The
comparison verifies the same application binary hash, server contents and server
settings. Application source hashes and mapped lines also match. The only changed
coverage source hash is `Sources/ReplicatorLabCore/LabJSONComparison.swift`.
The general comparison tool still requires identical build inputs. A separate
script records this specific harness-only comparison.

One runtime line is no longer reached: `Sources/ReplicatorApply/DMLBatch.swift:129`,
the call that flushes an expired batch. The integration cases do not control
this timer. The existing `testBatchCollectionBoundsIdleFlushAndNoRetryAfterFailure`
unit test advances an injected clock and checks the flush. That test passes.
Do not treat incidental timer coverage as a replacement for this controlled test.

Twelve focused JSON comparison and SQL batch unit tests pass. They cover result
mapping, path chunks, duplicate rows, exact empty values, NULL values, count and
byte limits, oversized queries, malformed replies and client errors. No full
local suite was run. Leave the remaining profiles and variants to full CI.

Evidence is in `artifacts/json-comparison-study/`: `before.json`, `after.json`,
`compare.py`, `comparison.json`, `json-unit.log` and `batch-age-unit.log`.
The next candidate is repeated per-column metadata and default-value probes in
the encoding cases. Measure those calls before changing them. Keep the same
comparison boundary after each source statement.

## Checks before removing work

Keep all current comparisons in this change. For a later optimization:

1. Select an expensive repeated query and identify its assertion and state.
2. Separate repeated setup from checks after an intermediate mutation or restart.
3. Propose batching or a smaller comparison scope only when it retains the check.
4. Compare exact assertion results and runtime line sets on the same build.
5. Run the changed cases locally, then verify every profile in full CI.

Do not narrow the PR selection in this study. First measure the new full groups.
