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
both profiles; `TIER=smoke` selects one case from every family. Unit tests remain
`make test`. Select one topology or an ordered scenario with:

```sh
make correctness PROFILE=mysql57-to-mysql84-innodb ARGS="--case ddl-index-create"
make correctness PROFILE=mysql84-to-mysql57-myisam ARGS="--family database"
```

Equivalent CLI: `swift run replicator-lab test --profile PROFILE --suite correctness`.
Use `--list`, `--tier smoke|full`, `--family database|ddl|dml|indexes|policy|rejections`,
repeated `--case ID`, `--skip-build`, or `--coverage`. Cases include dependent
statements as a unit; prerequisite cases are selected automatically. Unknown IDs
and invalid combinations fail before provisioning. Current shared correctness
variants use GTID positioning, FULL row images, FULL optional metadata on 8.4,
and the metadata available on 5.7. File-position and other historical variants
remain in the legacy adapters; unsupported combinations are not inferred.

The shared runner creates schemas through source-side DDL, executes the same
DML/index/DDL fixtures, compares exact row bytes and expected metadata, checks
catch-up and intent completion, and reopens saved schemas before applying another
transaction. Engine differences are checked against the profile before schema
comparison; arbitrary data/DDL differences are not normalized away.

## Outcomes and scope

Each selected scenario/profile has a stable ID, expected behavior and status:
`not_run`, `running`, `passed`, `failed`, `not_applicable` with a reason, or
`not_implemented` with a visible gap. Expected rejection is a passing test only
when it confirms the diagnostic, unchanged checkpoint and absence of target writes.
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

These suites use the common profile interface and retain their established
runners/assertions. They are labeled adapters in the inventory, rather than
claiming that all their cases have moved to the shared runner.

| `--suite` | Scope |
| --- | --- |
| `correctness` | Shared replicated-DDL, DML, indexes, policies and refusals |
| `lifecycle` | Forward source/target reconnect tests; reverse port explicitly missing |
| `recovery` | InnoDB rollback/inspection/audited retry; forward extended fail-stop/refusal tests |
| `demo` | Common retained-session start, compare, stop, resume and container repair |
| `legacy-dml` | Original forward DML suite, including bootstrap and positioning variants |
| `legacy-ddl` | Original forward DDL suite and its catalog-bound assertions |
| `native` | Original 8.4-source native DDL observation suite |
| `all` | All of the above; reports incomplete while required ports remain missing |

For example: `make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite recovery"`.
Recovery qualification omits the old embedded benchmark. Original commands such
as `dml-suite`, `ddl-suite`, `reverse-suite`, and `reverse-correctness` remain for
existing scripts. Old demo commands retain their original sessions and advanced
failure exercises. New commands never adopt or overwrite those sessions.

The [DDL catalog](../tests/DDLCoverage/README.md) still distinguishes case passes
from named assertion qualification. Its historical profile IDs describe specific
variants of the forward lab profile. Shared-run results do not automatically
satisfy those bindings; their source/native/target assertions remain separate.

## Evidence and code coverage

`artifacts/lab/RUN_ID/result.json` records the selected matrix and overall outcome.
Shared runs store per-profile `cases.json`, per-step SQL/observations, `runtime.json`,
logs, SQLite/relay state and final `result.json` beneath that directory. Failure
artifacts include source boundaries/binlogs when available. Adapter suites retain
their established artifact categories; the runners provide their own evidence paths to the aggregate, keeping concurrent
runs separate.
DDL/native adapters list registered cases; other legacy adapters explicitly report
suite-level inventory until their assertions are registered individually.

For shared correctness, `--skip-build` reuses `mysql-replicator-packaging:lab` only if its input fingerprint
matches the checkout. Both profiles use the same pinned image in a combined correctness run. Changing fixture or
implementation inputs during qualification fails the aggregate.
`--coverage` builds the instrumented image and exports each profile's coverage
separately. Merge explicitly selected reports with the existing `make coverage-report`
command; a combined line-coverage number does not replace per-profile scenario results.
Instrumented runs are not performance measurements. Legacy adapters retain their
original image tags and build controls; build those suites before reusing their
images with `--skip-build`.

PR CI runs the same smoke cases and demo lifecycle for both profiles, retains
specialized forward integration/reverse recovery checks, and merges shared
applier coverage with unit coverage. `Full Profile Qualification` runs the full
correctness matrix weekly, on release tags, and through manual workflow dispatch.
It uploads each profile's evidence separately.

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

`compare` verifies the preloaded `reverse_poc.items` and `reverse_poc.aux` tables,
including checkpoints. The example also creates `lab_example` through replication;
inspect it in the printed shells or use the correctness suite for automated DDL
assertions. The fixture database name is retained across profiles for shared SQL.
Audited `inspect`/`resolve` actions are available only for the InnoDB profile.

The original [forward workbook](../PLAN/DEMO_WORKBOOK.md) and
[reverse workbook](../PLAN/REVERSE_DEMO_WORKBOOK.md) continue to describe the legacy
commands and their separate retained sessions.

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
Backlog evidence lives in `artifacts/lab-benchmark/PROFILE/`; historical measurement
adapters retain their original categories. Do not compare timings across different
workloads, modes, instrumentation, durability settings or transports as applier
speed alone.
