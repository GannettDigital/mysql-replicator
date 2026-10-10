# Testing replication by profile

Shared fixtures enable automatic support bundles when the applier enters
`BLOCKED`. They use `format: directory` so you can read the files without extraction.
After a test, look in its `support-bundles/` artifact directory. Start with
`failure.json`, then check `state.sqlite`, `relay.frames`, and `bundle.json`.
The rejection tests check that the bundle preserves the failure and the blocked
checkpoint. A test failure outside the applier does not cause a support bundle.

The lab runs shared experiments against a source, an external-applier target,
and a native reference. A profile identifies the topology and replication
contract; it does not mean every feature of those MySQL versions is supported.

| Profile | Source | External target | Native reference |
| --- | --- | --- | --- |
| `mysql84-to-mysql57-myisam` | 8.4 InnoDB | 5.7 MyISAM | 8.4 MyISAM |
| `mysql57-to-mysql84-innodb` | 5.7 InnoDB | 8.4 InnoDB | 5.7 InnoDB |
| `mysql57-to-mysql57-myisam` | 5.7 InnoDB | 5.7 MyISAM | 5.7 MyISAM |

Partition experiments explicitly use an InnoDB native reference on all profiles
to preserve the same fixture; 8.4 cannot create the corresponding MyISAM table. Both MyISAM temporary-table LIKE cases
also declare a MyISAM source template explicitly. These exceptions are checked
before metadata comparison. The actual servers, settings, image IDs,
and applier binary hash are recorded. The native reference is a behavior/control
comparison; its version matches the source. In the 5.7 → 5.7 profile, all three servers use 5.7.

## List and run

Build prerequisites are in [CONTRIBUTING](../CONTRIBUTING.md). From the checkout:

```sh
make lab-list
make correctness TIER=smoke
make correctness
```

The list is an offline JSON inventory: no Docker provisioning or implicit use of
old evidence. `make correctness` runs the shared full correctness catalog for
all profiles; `TIER=smoke` selects a small representative subset. Use the full
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
after the changes on all profiles. Foreign keys and CHECK constraints remain
outside the supported DDL contract.

The `foreign-keys` family applies to the 5.7 → 8.4 InnoDB profile. It compares
parent/child rows, constraint metadata and supporting indexes with native 5.7
replication, exercises cascades, composite references, ordered DDL and restart,
and checks exclusions, rollback and offline recovery relationship evidence.
It runs as its own parallel CI area. Use
`make correctness PROFILE=mysql57-to-mysql84-innodb ARGS="--family foreign-keys"`.
MyISAM profiles retain `reject-foreign-key`.

The `filters` family runs wildcard exclusions, saved-state resume and included-DDL
refusal on all profiles. It keeps the independent native/target binlog oracle as
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
| `policy` | `live-skip-errors`: live capture with optional audit, DDL skip, InnoDB rollback/resume, exact GTID stop and MyISAM refusal |
| `offline` | `offline-skip-errors`: optional per-GTID audit, DDL skip-and-continue, InnoDB duplicate rollback/resume and MyISAM duplicate refusal |
| `offline` | `runtime-control`: exact GTID stop/resume, live/offline reload, refusal of checkpoint changes, and acknowledged stop while target writes are blocked |
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
shared, individually declared cases on all profiles. Both MyISAM profiles use the
shared recovery workflow. Other specialized suites retain their established
runners/assertions and are labeled adapters in the inventory.

| `--suite` | Scope |
| --- | --- |
| `correctness` | Shared replicated-DDL, DML, indexes, policies, filters and refusals |
| `lifecycle` | Shared source/target reconnect, restart, drain and uncertain-write cases |
| `recovery` | Shared MyISAM workflow; retained InnoDB rollback/inspection/audited retry runner |
| `demo` | Shared workbook, manual start, heartbeats, signals/resume, shell repair; profile-specific failure/skip and recovery |
| `native` | Original 8.4-source native DDL observation suite |
| `all` | All of the above; any missing required case makes the run incomplete |

For example: `make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite recovery"`.
Recovery qualification omits the old embedded benchmark. MyISAM `recovery` selects
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
`not_applicable` on topologies without the required capabilities. For example:

```sh
make lab-list ARGS="--suite demo" | jq '.scenarios'
make lab-test ARGS="--suite demo --coverage"
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite demo --case demo-skip-and-resume"
```

Demo test evidence lives under `artifacts/lab/RUN_ID/PROFILE/demo/default/`.
Each independent session records assertions, comparisons, pinned runtime metadata,
archived SQLite/relay state and, when enabled, `code-coverage/combined/`. These
workbook checks do not claim additional MySQL catalog coverage.

Run reconnect qualification for all profiles, or select one:

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
matches the checkout. All profiles use the same pinned image in a combined run. Changing fixture or
implementation inputs during qualification fails the aggregate.
For `correctness`, `lifecycle`, and MyISAM `recovery`, `--coverage` builds the instrumented image and exports each profile's coverage
separately. Merge explicitly selected reports with the existing `make coverage-report`
command. Its published runtime views exclude `ReplicatorLab*`; a separate harness
view uses only unit-test coverage. Raw per-fixture collections remain available
for provenance and migration comparisons. A combined line-coverage number does
not replace per-profile scenario results.
Instrumented runs are not performance measurements. Specialized adapters retain
their original image tags and build controls; build those suites before reusing
their images with `--skip-build`.

PR and main CI run the full catalog through one parallel matrix. Correctness and
source/target reconnect run for all default profiles, plus the forward
`position-minimal` and `gtid-full` capture variants. Demo, reverse recovery and
the applicable native-reference DDL suite run in the same workflow. There is no
separate weekly or release-tag qualification workflow.

The lab catalog generates the matrix; `tools/ci_matrix.json` only assigns
correctness families to areas and sets chunk sizes. New cases automatically join
their area, while an unassigned family or suite fails planning. The generated
`ci-lab` artifact contains `matrix.json`, including all obligations, explicit
not-applicable entries and exact shard selections. Each applicable obligation
has one owning shard; prerequisites can also run in dependent shards.

Jobs show profile, area, capture variant and image type. Large DDL, index and
bootstrap areas are split into case groups, with up to 16 jobs running at once.
Each job owns a fresh fixture. Ordered scenarios and the forward
failure → recovery → offline/control sequence stay together. CI builds the lab
once and each applier image once, then shares checksummed artifacts with the
whole matrix. Release jobs verify they use the packaged binary.

Generate and inspect the same plan locally:

```sh
swift build --product replicator-lab
python3 tools/ci_lab.py --plan .build/debug/replicator-lab
jq '.include[] | {profile, variant, area, suite, cases}' artifacts/ci/matrix.json
```

Reproduce a shard with the usual `make lab-test PROFILE=...` command
and its `ARGS="--suite ... --variant ... --case ..."` selections. Only correctness
and lifecycle accept `--variant`; omit case selectors for lifecycle, demo and
specialized adapters, which run their complete suite in CI.

The forward negative suites archive the native reference's error and the source
boundary before reseeding that disposable reference past rejected transactions.
Applier failure states remain intact. To check the recovery-to-offline transition locally:

```sh
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--case myisam-recovery --case offline-replay --case runtime-control"
```

CI uploads each shard's evidence separately. Published code coverage combines
unit tests with instrumented smoke and demo runs. Full correctness and reconnect
runs use the release image and do not contribute to line coverage.
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
multi-terminal experiments. Both MyISAM profiles also provide `fail`, `skip GTID`
and `compare --expect-blocked` actions for their controlled explicit-engine rejection.

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

Backlog profiling controls keep the historical defaults: `--applier-profile on`,
`--decoder-profile off`, and `--batch-transactions 8`. For a detailed 10K run:

```sh
make lab-benchmark PROFILE=mysql57-to-mysql84-innodb ARGS="--events 10000 --decoder-profile on"
```

Repeat with `--skip-build --applier-profile off --decoder-profile off` to measure
without detailed profiling. `--batch-transactions 32` changes the execution batch
limit and scales the journal preparation window; InnoDB still commits each source
transaction separately. The 25 ms age limit can produce smaller batches. Results include `stage-timings.json`,
optional `applier-profile.tsv` / `decoder-profile.tsv`, server durability settings,
and native/target binlog boundaries. `apply.detail.transaction.begin` and
`apply.detail.transaction.commit` include the SQL round trip; `capture.schema_wait`
measures time waiting for historical schema interpretation in the apply loop.

For server-side SQL profiling, add `--server-profile on` (backlog mode only;
default off). This enables timed Performance Schema statements, SQL stages,
transactions and waits on the disposable native and target servers. It writes
`server-profile-{native,target}.json`, sorted `.tsv` reports, and instrument
settings. Target foreground counters use the `apply_fixture` user, retaining
results after disconnect; native foreground counters use its new SQL/worker
threads. File I/O is server-wide and includes background redo work. Background
waits include idle time. These are nested elapsed timers, not additive CPU costs;
file `misc` includes sync and other operations, not just fsync. Autocommit commit
work appears inside INSERT execution and server commit stages, not a separate
client COMMIT. No durability settings change.

```sh
make lab-benchmark PROFILE=mysql57-to-mysql84-innodb ARGS="--events 10000 --applier-profile off --server-profile off"
make lab-benchmark PROFILE=mysql57-to-mysql84-innodb ARGS="--skip-build --events 10000 --applier-profile off --server-profile on"
```

Compare profiling off/on to assess overhead. Statement and stage names differ
between native row replication and SQL clients, and the reverse reference is
MySQL 5.7 while the external target is 8.4. The gap between client `target.sql`
and server statement time includes scheduling, protocol and transport overhead;
it is not a direct measurement of network latency. `target.connect`,
`capture.resolve`, `capture.connect` and `capture.preflight` separately time
connection and source setup before useful replay work. `capture.shutdown.receiver`,
`capture.shutdown.connection` and `capture.shutdown.event_loop` measure teardown
in the final apply timings. Snapshot queries run outside
the timed replay windows and use the separate root observer account.

The application and benchmark default to eight source transactions per execution
batch. `batch.maximumPreparedBatches` accepts 1..16 and defaults to eight. It bounds
all submitted batches, including completed batches awaiting a checkpoint. One
slot retains overlap of row planning but serializes durable preparation with
completion. `batch.overlapPreparation: false` also disables coordinator planning
overlap at batch handoff and uses one slot.

With four or more slots, the coordinator collects a preparation window of up to
half the queue capacity, shares one relay sync and one FULL SQLite commit across
that window, then submits its execution batches in order. For example, eight
slots and eight transactions per execution batch can prepare four batches (32
source transactions) together. The existing row, byte, age and table-change
limits apply to the whole preparation window; a single oversized source group
still runs alone. DDL, schema, stop and reconnect barriers retain their ordering.
Published completions can also share one SQLite checkpoint commit. Larger queues
increase the bounded set of durable intents that can remain pending after a crash.

For a backlog comparison with the same binary, use `--prepared-batches 2` and
`--prepared-batches 8`, keeping `--batch-transactions 8` and profiling settings
unchanged. This controls durable preparation and queue depth, not the number of
target connections or InnoDB source transactions committed together. MyISAM
INSERT coalescing remains bounded by each execution batch. Timer and size limits
can produce smaller batches.

The final summary's `applyQueue` reports the current target session's queue
capacity, maximum outstanding batches, executed/unissued batch counts, and
worker `busySeconds`, `idleSeconds`, and `spanSeconds`. Span covers the first
batch start through the last completed batch, excluding startup before the first
batch and shutdown afterward. Idle includes any gap between batches, including
source starvation and DDL barriers; it is most useful on a DML-only backlog.
Busy includes target execution and its checks. These are elapsed durations,
not CPU measurements. While execution is active, busy time includes only
completed batches and idle time includes gaps preceding batches already started.

The decoder caches those interpretations by database, table and wire column
metadata. `capture.schema_cache.hit` / `.miss` report reuse; a repeated numeric
table ID alone is insufficient. DDL, new format contexts and skipped ranges
invalidate the cache; reconnect creates a new cache. Retention is bounded to
1,024 table entries, with eviction causing a fresh ordered lookup. Checksums,
table-map decoding and consumer-side schema validation still run for each map.
The live/offline stream reuses the codec's validated format context for TABLE_MAP
probes. With no table filter, each included map uses one metadata probe and one
normal decode that installs the resolved schema. With a filter, an identity probe
runs first so excluded tables can retain opaque unsupported columns. Probes do
not advance the decoder or change its live table cache; framing/CRC and schema
checks remain enforced. The old per-map `decode.call.probe_format` calls disappear;
`decode.call.probe_identity` is needed only when a table-filter callback is present.
GTID UUID text is cached for the last source SID, with byte comparison on each GTID.

Apply/replay carry raw event bytes directly to the relay writer. External inspection
output still uses Base64 when requested; the internal byte buffer is not a JSON
field. Decoded-queue byte accounting includes that buffer. Existing relay files
and recovery/inspection formats are unchanged.

Timers from different workers overlap. Inclusive and self times are elapsed time,
not CPU time, and must not be summed as end-to-end duration.
See the [reverse InnoDB investigation](../PLAN/REVERSE_INNODB_PERFORMANCE.md)
for the 10K measurements, native binlog behavior, and proposed optimization order.

The historical forward sysbench streaming and blackhole capture experiments are
available with `--mode streaming` and `--mode capture`, respectively. These are
separate measurements and are currently unavailable for the 5.7-source profiles.
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

## Adding a profile

Production `ReplicationProfile` selects a `SourceContract` and a target engine/version
contract independently. The lab declares the same topology in `LabProfile` and its
Compose overlay. `LabMySQLVersion` supplies server administration SQL; engine
capabilities select rollback, failure and recovery expectations. Add the profile
to these registries, then run the existing catalog. Do not copy a suite.

The CI matrix is generated from this catalog. New profiles automatically receive
applicable correctness, lifecycle and demo jobs; update `tools/ci_matrix.json` for
the expected demo coverage report count. Keep version-specific exclusions explicit.
The 5.7 MyISAM profile reuses MyISAM recovery and the GTID demo resume workflow.
8.4 optional-metadata refusals, 0900 translation and the historical 8.4-specific
failure group do not apply. Streaming/capture benchmarks remain 8.4-only; the
shared backlog benchmark supports all profiles.

See [5.7 MyISAM setup](MYSQL57_MYISAM.md) for deployment boundaries.
