# Testing replication by profile

The lab runs shared experiments against a source, an external-applier target,
and a native reference. A profile identifies the topology and replication
contract; it does not mean every feature of those MySQL versions is supported.

| Profile | Source | External target | Native reference |
| --- | --- | --- | --- |
| `mysql84-to-mysql57-myisam` | 8.4 InnoDB | 5.7 MyISAM | 8.4 MyISAM |
| `mysql57-to-mysql84-innodb` | 5.7 InnoDB | 8.4 InnoDB | 5.7 InnoDB |

Partition experiments explicitly use an InnoDB native reference where 8.4 cannot
create the corresponding MyISAM table. The forward temporary-table LIKE case
also declares a MyISAM source template explicitly. These exceptions are checked
before metadata comparison. The actual servers, settings, image IDs,
and applier binary hash are recorded. The native reference is a behavior/control
comparison; it is not the same server version as the external target.

## List and run

Build prerequisites are in [CONTRIBUTING](../CONTRIBUTING.md). From the checkout:

```sh
make lab-list
make correctness TIER=smoke
make correctness
```

The list is an offline JSON inventory: no Docker provisioning or implicit use of
old evidence. `make correctness` runs the shared full correctness catalog for
both profiles; `TIER=smoke` selects a small representative subset. Use the full
tier for every applicable family. Unit tests remain `make test`. Select one topology or an ordered scenario with:

```sh
make correctness PROFILE=mysql57-to-mysql84-innodb ARGS="--case ddl-index-create"
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--family database"
```

Equivalent CLI: `swift run replicator-lab test --profile PROFILE --suite correctness`.
Use `--list`, `--tier smoke|full`, `--family FAMILY`,
repeated `--case ID`, `--skip-build`, or `--coverage`. Cases include dependent
statements as a unit; prerequisite cases are selected automatically. Unknown IDs
and invalid combinations fail before provisioning. The default uses GTID
positioning, FULL row images, FULL optional metadata on 8.4, and the metadata available on 5.7. Historical forward capture variants are
also available, as described below; unsupported combinations are not inferred.

The shared runner creates schemas through source-side DDL, executes the same
DML/index/DDL fixtures, compares exact row bytes and expected metadata, checks
catch-up and intent completion, and reopens saved schemas before applying another
transaction. Engine differences are checked against the profile before schema
comparison; arbitrary data/DDL differences are not normalized away.

`--case ddl-compat-constraints` exercises named PRIMARY/UNIQUE constraints in
CREATE and ALTER, explicit index-name precedence, unnamed constraints, and DML
after the changes on both profiles. Foreign keys and CHECK constraints remain
outside the supported DDL contract.

The `filters` family runs wildcard exclusions, saved-state resume and included-DDL
refusal on both profiles. It keeps the independent native/target binlog oracle as
well as row, checkpoint and intent checks. MySQL 8.4 `mysqlbinlog` must be on PATH
(or set `MYSQLBINLOG` to its path); this is checked before fixture startup. Smoke
includes the wildcard workload; full includes resume and refusal. Selecting
`--case wild-ignore-included-rejection` automatically includes both prerequisites.
These cases bootstrap equivalent tables without logging, then use isolated state
directories for their measured source workload.

## Ordered and isolated experiments

The full correctness inventory includes these additional families. Use `--list`
for applicability reasons and the selected variant; source-version and engine
specific refusals are not silently reused with different expectations.

| Family | Experiment |
| --- | --- |
| `ordered` | `ddl`: 70 dependent table-lifecycle steps, conditional no-ops, LIKE, cross-schema moves, defaults, schema history and independent binlog comparisons |
| `collation` | Forward 0900 translation, cleanup/table swap, policy-change resume refusal and PAD collision |
| `bootstrap` | `bootstrap-matrix-*`: the DML matrix against preexisting table snapshots, with isolated checkpoints for each phase |
| `dml-refusals` | Forward `matrix-reject-*`: incompatible metadata, generated values and decoder refusals, with target effects and unchanged checkpoint checks |
| `discovery` | `ddl-index-resume`: saved indexed schema, resumed DML and external index-drift refusal |
| `offline` | `offline-replay`: finite fetch, external raw files, replay/resume without source credentials, native comparison, and support-bundle extraction |
| `failures` | `forward-failures`: restricted grants, target SQL errors, uncertain DDL, skip refusal, trigger policies and generated-value divergence |
| `recovery` | `myisam-recovery`: exact values, discovery/cache/explicit locks, partial writes, killed groups and refused replay; GTID variants only |

`positive` preserves the bootstrapped INSERT/UPDATE/DELETE sample, direct YAML
credentials, exact counters and independent source/native/target binlogs. It is
included in smoke. Smoke also checks database retirement immediately after
resuming saved schemas. The other isolated experiments run after the continuous
writer has drained. Explicit restart pairs share a state directory; unrelated failures
use distinct directories. Group child cases retain individual results in
`cases.json`; selecting the group runs its required ordered setup and assertions.
The MyISAM group runs last because its expected native failures deliberately leave
the native channel blocked. Native-only resets between independent refusal
experiments are fixture cleanup, never an applier recovery action.

The old DDL/DML runners have been retired after matched runtime coverage,
[assertion/variant mapping](../PLAN/TEST_SUITE_RETIREMENT_MAP.md), and named catalog
checks. Historical evidence and the precise limits remain in the retirement report.

## Outcomes and scope

Each selected scenario/profile has a stable ID, expected behavior and status:
`not_run`, `running`, `passed`, `failed`, `not_applicable` with a reason, or
`not_implemented` with a visible gap. Expected rejection is a passing test only
when it confirms the diagnostic, unchanged checkpoint and documented target
effects. Refusals before execution require no target writes; a post-write MyISAM
failure must preserve evidence of any retained writes.
A source success, native success and applier refusal are distinct outcomes.

A selected obligation that is missing or never ran makes the aggregate incomplete
and exits nonzero. Suite setup, restart, evidence collection and cleanup failures
also fail the run even if individual cases passed. Partial selections identify
their scope and do not claim full MySQL compatibility.

The reverse multi-table/defaults workflow is profile-specific. Foreign keys remain
an expected refusal; the support proposal is [MYSQL57_FOREIGN_KEYS](../PLAN/MYSQL57_FOREIGN_KEYS.md).
Bootstrap-table DML tests and replicated-CREATE tests prove different things:
both remain available, without presenting one as a substitute for the other.

## Existing specialized qualification

These suites use the common profile interface. Correctness, lifecycle and demo run
shared, individually declared cases on both profiles. Forward recovery uses the
shared MyISAM workflow. Other specialized suites retain their established
runners/assertions and are labeled adapters in the inventory.

| `--suite` | Scope |
| --- | --- |
| `correctness` | Shared replicated-DDL, DML, indexes, policies, filters and refusals |
| `lifecycle` | Shared source/target reconnect, restart, drain and uncertain-write cases |
| `recovery` | Shared forward MyISAM workflow; retained InnoDB rollback/inspection/audited retry runner |
| `demo` | Shared workbook, manual start, heartbeats, signals/resume, shell repair; profile-specific failure/skip and recovery |
| `native` | Original 8.4-source native DDL observation suite |
| `all` | All of the above; any missing required case makes the run incomplete |

For example: `make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite recovery"`.
Recovery qualification omits the old embedded benchmark. Forward `recovery` selects
the same `myisam-recovery` group included in full correctness; `--suite all` runs
that group once. Its ordered child cases are listed in the offline inventory.
The `dml-suite`, `ddl-suite`, `legacy-dml` and `legacy-ddl` commands are removed.
Use shared `correctness`, its `bootstrap` family and capture variants instead.
`reverse-suite` and the `reverse-correctness` compatibility alias remain.
The former `demo-*` and `reverse-demo-*` commands are replaced by `demo ACTION
--profile PROFILE`; their rehearsals are now named cases in `test --suite demo`.
Existing legacy sessions are never adopted or overwritten. To archive and remove
one, use `make lab-demo PROFILE=PROFILE ACTION=legacy-down`.

Demo selection supports `--family lifecycle|workbook|failure|resume` and `--case ID`.
Dependencies are included automatically; profile-specific cases report
`not_applicable` on the other topology. For example:

```sh
make lab-list ARGS="--suite demo" | jq '.scenarios'
make lab-test ARGS="--suite demo --coverage"
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite demo --case demo-skip-and-resume"
```

Demo test evidence lives under `artifacts/lab/RUN_ID/PROFILE/demo/default/`.
Each independent session records assertions, comparisons, pinned runtime metadata,
archived SQLite/relay state and, when enabled, `code-coverage/combined/`. These
workbook checks do not claim additional MySQL catalog coverage.

Run reconnect qualification for both profiles, or select one:

```sh
make lab-test ARGS="--suite lifecycle"
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite lifecycle --skip-build"
```

The 11 lifecycle cases use equivalent bootstrapped integer tables and default to
GTIDs; capture variants below also exercise file-position starts.
They cover source socket loss, rotation, clean/crash restart, interruption during
an 8,000-row group, backoff cancellation, and changed source settings; target
socket loss/restart, active-group drain, saved-state resume with an unavailable
target, backoff drain, lost mutation replies and changed target settings.
Successful cases compare source/native/target rows and saved checkpoints.
The InnoDB lost-reply case observes a provisional write before disconnecting,
then checks rollback and durable pending-row evidence. The applier still reports
an unconfirmed rollback and blocks ordinary resume; this does not authorize
automatic replay or qualify a lost COMMIT reply. The forward case uses a table
lock on INSERT instead of an InnoDB row lock on UPDATE. All cases run in order, with distinct state
directories except the explicit resume pairs. DDL timeout and skip-refusal
fixtures run in the shared `forward-failures` group.

The [DDL catalog](../tests/DDLCoverage/README.md) still distinguishes case passes
from named assertion qualification. Its historical profile IDs describe specific
variants of the forward lab profile. Shared-run results qualify only explicitly
migrated bindings through the named assertion bundles described below.

The [coverage migration review](../PLAN/TEST_SUITE_COVERAGE_MIGRATION.md) compares
legacy and shared runtime line sets separately from catalog assertions and lists
the gates for retiring old runners. Declaration overlap alone is not parity.
The [retirement assessment](../PLAN/TEST_SUITE_RETIREMENT_ASSESSMENT.md) records
the original gaps, measured migration checkpoints and final removal evidence.

### Capture variants and catalog evidence

Correctness and lifecycle accept `--variant default|position-minimal|gtid-full|all`.
The default keeps each topology's usual GTID start with a file/offset. The two
historical forward variants use file-position with MINIMAL optional row metadata,
or GTID-only start with FULL metadata. `--variant all` lists/runs each separately;
the historical variants are explicitly not applicable to the 5.7-source profile.
MySQL 5.7 has no `binlog_row_metadata` setting. Lifecycle's default integer-only
workload uses MINIMAL on the 8.4 source; explicit variants preserve their setting
across restarts. Matrix fixtures that require FULL labels declare that override.

```sh
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--variant position-minimal --family filters --coverage"
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite lifecycle --variant gtid-full --coverage --skip-build"
```

Forward historical correctness runs also write `catalog/coverage-evidence.json`.
Only explicitly migrated database/MODIFY/index and ordered table-lifecycle bindings accept the
`shared-correctness` producer. Their named checks include source warnings,
following rows, and (for MODIFY/index) normalized source/native/target binlogs,
durable boundaries and schema history. All required cases for a binding must
pass; selecting one representative case does not qualify the entire family.
Default/reverse runs retain their lab assertions but cannot fill historical
catalog profile slots. Import one bundle per historical profile with the existing
DDL catalog report command; do not combine passing subsets of different runs.
The logical catalog suite IDs and all 730 required obligations remain intact;
those identifiers do not retain old runner entry points.

## Evidence and code coverage

`artifacts/lab/RUN_ID/result.json` records the selected matrix and overall outcome.
Shared runs store per-profile `cases.json`, per-step SQL/observations, `runtime.json`,
logs, SQLite/relay state and final `result.json` beneath that directory. Failure
artifacts include source boundaries/binlogs when available. Adapter suites retain
their established artifact categories; the runners provide their own evidence paths to the aggregate, keeping concurrent
runs separate.
The native adapter lists registered cases; reverse recovery and other specialized
adapters explicitly report suite-level inventory.

For shared correctness and lifecycle, `--skip-build` reuses `mysql-replicator-packaging:lab` only if its input fingerprint
matches the checkout. Both profiles use the same pinned image in a combined run. Changing fixture or
implementation inputs during qualification fails the aggregate.
For `correctness`, `lifecycle`, and explicitly forward-only `recovery`, `--coverage` builds the instrumented image and exports each profile's coverage
separately. Merge explicitly selected reports with the existing `make coverage-report`
command. Its published runtime views exclude `ReplicatorLab*`; a separate harness
view uses only unit-test coverage. Raw per-fixture collections remain available
for provenance and migration comparisons. A combined line-coverage number does
not replace per-profile scenario results.
Instrumented runs are not performance measurements. Specialized adapters retain
their original image tags and build controls; build those suites before reusing
their images with `--skip-build`.

PR CI runs the same smoke, reconnect and demo cases for both profiles, retains
specialized forward integration/reverse recovery checks, and merges shared
applier coverage with unit coverage. `Full Profile Qualification` runs the full
correctness and reconnect matrix weekly, on release tags, and through manual workflow dispatch.
It uploads each profile's evidence separately. Current published CI coverage uses
unit tests and instrumented integration/shared smoke, not the full weekly matrix.
See [coverage reports and publication](../CONTRIBUTING.md#code-coverage) for PR
comments and downloading the HTML/LCOV reports linked from the README.
Publishing does not require GitHub Pages.

## Interactive demo

Select one profile explicitly. Each has a separate retained session:

```sh
make lab-demo PROFILE=mysql57-to-mysql84-innodb ACTION=up
make lab-demo PROFILE=mysql57-to-mysql84-innodb ACTION=start
make lab-demo PROFILE=mysql57-to-mysql84-innodb ACTION=sql ARGS=examples/lab-demo.sql
```

Use `ACTION=status`, `compare`, `stop`, or `down`. `up` prints SQL-shell commands
and the generated YAML configuration. Repeating `up` repairs a missing idle
container while preserving its pinned image and saved state. `down` archives
state and removes only that disposable session. Pause source writes for comparison.

`compare` verifies `demo.items` (when present) and the preloaded `reverse_poc.items`
and `reverse_poc.aux`, including schema, expected engine differences and checkpoints.
It reads SQLite in its Docker volume after the completed boundary without
interrupting either a foreground or detached writer. The example also creates `lab_example` through replication;
inspect it in the printed shells or use the correctness suite for automated DDL
assertions. The fixture database name is retained across profiles for shared SQL.
Audited `inspect`/`resolve` actions are available only for the InnoDB profile.

The [forward workbook](../PLAN/DEMO_WORKBOOK.md) and
[reverse workbook](../PLAN/REVERSE_DEMO_WORKBOOK.md) use these same commands for
multi-terminal experiments. The forward profile also provides `fail`, `skip GTID`
and `compare --expect-blocked` actions for its controlled explicit-engine rejection.

For instrumentation, create the session with `ACTION=up ARGS=--coverage`.
Coverage mode and the image are pinned in `artifacts/demos/PROFILE/current.json`;
subsequent commands preserve that choice. `down` drains the writer and exports
coverage before archiving/removing its volume. Recreate sessions made before this
migration to obtain the SQLite-equipped demo image; retained sessions never rebuild
or switch their image implicitly.

## Comparable benchmarks

```sh
make lab-benchmark PROFILE=mysql84-to-mysql57-myisam ARGS="--events 10000"
make lab-benchmark PROFILE=mysql57-to-mysql84-innodb ARGS="--events 10000"
```

Both use `--mode backlog --workload insert`: generate a fixed backlog, replay it
through native replication and the external applier sequentially, verify final
rows/checkpoints, and record wall time, target counters and stage timings. Startup
and polling overhead are included. `--workload multi-table-transaction` is an
explicit InnoDB-only experiment, never silently substituted for `insert`.

The historical forward sysbench streaming and blackhole capture experiments are
available with `--mode streaming` and `--mode capture`, respectively. These are
separate measurements and are currently unavailable for the reverse profile.
All modes require one explicit profile. For example:

```sh
make lab-benchmark PROFILE=mysql84-to-mysql57-myisam ARGS="--mode streaming --events 10000"
make lab-benchmark PROFILE=mysql84-to-mysql57-myisam ARGS="--mode capture --events 10000"
```

Streaming/capture retain their transport and tuning options from the
[benchmark guide](../PLAN/PERFORMANCE_BENCHMARK.md), and share a dedicated forward
measurement fixture rather than the interactive demo implementation.
Backlog evidence lives in `artifacts/lab-benchmark/PROFILE/`; historical measurement
adapters retain their original categories. Do not compare timings across different
workloads, modes, instrumentation, durability settings or transports as applier
speed alone.
