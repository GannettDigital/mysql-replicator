# Interactive three-node replication demo

For a short command-by-command walkthrough, use the [four-terminal workbook](DEMO_WORKBOOK.md).

This is a retained version of the qualification topology, using the repository's
`compose.yaml`, the existing `docker/dml/compose.yaml` TLS overlay, and the
demo-only `docker/demo/compose.yaml` applier service. It runs a MySQL
8.4 InnoDB source, a native 8.4 MyISAM replica, and a 5.7 MyISAM target. All three
produce binlogs. The Swift/Rust runtime uses Ubuntu 16.04 x86_64, including under
Docker Desktop on a Mac. The Swift applier shares the 5.7 server's network
namespace and connects to `127.0.0.1`, with TLS hostname verification for target57.

`demo-up` prepares the servers, starts native reference replication, and starts
an idle Ubuntu applier container with `sleep infinity`. **It does not launch
mysql-replicator.** Log into the container and launch that process manually. It writes an actual source UUID,
GTID baseline and TLS paths into a ready-to-run `apply.yaml`; there are no replacement
placeholders and no table schema in configuration. Demo fixture provisioning is
lab automation, not a production dump/load feature.

The demo's `apply_fixture` accounts (`%` and `localhost`) have `ALL PRIVILEGES`
on `*.*` on the disposable 5.7 target, so interactive experiments can create and
use databases beyond `demo`. Source DDL still needs 5.7-compatible types and
collations. These grants are installed during setup; existing demo containers
retain their original grants until the demo is recreated.

## Prerequisites and setup

Run commands from the repository root. Requirements are the existing SwiftPM host
toolchain, Docker with Compose and amd64 support, and OpenSSL. The first image build
needs registry/toolchain access and can take several minutes. Subsequent builds use
the existing persistent BuildKit Swift/Cargo caches. No host mysqlbinlog or sqlite3
installation is needed for this demo.

```sh
make demo-up
make demo-status
```

After building this exact revision once, `make demo-up ARGS=--skip-build` reuses
`mysql-replicator-packaging:demo`. The session pins its image digest. Rebuild when
runtime or packaging code changes. Certificates last seven days; recreate an old
stack before presenting. Repeating `demo-up` refuses to overwrite an existing
session, including incomplete setup. It does not silently erase data.

Setup prints the exact config path, container names and commands, and saves them
in `artifacts/demo/<run>/COMMANDS.txt`. `artifacts/demo/current.json` identifies the
active session. At this point the applier container is `running`, the
`mysql-replicator` process is `NOT RUNNING`, SQLite is `NOT_STARTED`, and the source
has no Swift capture connection. The native reference
may already be running; that is intentional.

## 1. Enter the running container and start Swift

Setup prints the exact container name. Follow the [workbook](DEMO_WORKBOOK.md)
for commands that derive it from the current session. On the host:

```sh
docker exec -it <applier-name> /bin/bash
```

Then, **inside the container**:

```sh
cat /evidence/apply.yaml
mysql-replicator run --config /evidence/apply.yaml --initialize
```

The config, TLS files, volume, and password environment variables are already
prepared. The command stays in the foreground and prints progress/errors in your
terminal. Use other terminals for SQL and comparison commands. When replication
fails or you interrupt it with Ctrl-C, the binary exits; the container and shell
remain available for inspection. Container startup/restart never starts the binary.

Alternatively, the host convenience command launches the same binary detached,
waits for capture readiness, and prints a log-viewing command:

```sh
make demo-start
docker exec <applier-name> tail -f /evidence/applier.ndjson /evidence/applier.stderr
```

After a clean STOPPED exit, run the same command **without `--initialize`** to
resume from SQLite. If nothing was applied, it uses the recorded baseline; otherwise
it uses the last fully applied GTID/position. `make demo-start` selects initialization
for a new state directory and resume for existing STOPPED state. An active process
or unresolved failure is refused. Detached log files contain the latest attempt.

Choose manual or detached launch, not both. `docker logs` does not capture output
from Docker exec sessions. Manual foreground output stays in that terminal;
detached output goes to the two files above. `demo-status` reads SQLite diagnostics
for either launch method and shows captured logs when those files exist.

The host copy of `apply.yaml` documents the installed config; editing that host copy
does not change the copy in the Docker volume. The ready config is intended for
this container/network, not direct execution on the Mac host.

No transaction-count limit is imposed. The reader requests one-second heartbeats;
the demo uses a 30-second idle read timeout. Ordinary pauses should leave the
applier running. A genuine disconnect still stops it: automatic recovery remains
unimplemented. Existing state prevents a second initialization, whether the first
process was launched manually or through `make demo-start`.

## 2. Run the successful SQL and compare

Open [01-success.sql](../examples/demo/01-success.sql) to explain or execute each
statement manually in the source mysql shell printed by setup, or run the file:

```sh
make demo-sql FILE=examples/demo/01-success.sql
make demo-compare
make demo-status
```

The script creates database `demo`, creates `demo.items`, inserts/updates/deletes
rows, adds a nullable column, then applies more DML. Run it once per fresh stack.
Statements are autocommit, matching the current GTID-to-MyISAM contract. The database
uses an explicit collation understood by 5.7. Table ENGINE is omitted, so each
server chooses its configured default. No engine/charset rewrite occurs.

Expected rows:

| id | value | quantity | note |
| --- | --- | --- | --- |
| 1 | updated | 11 | after DDL |
| 3 | third | 30 | NULL |

Expected Swift counters: eight applied source transactions, three DDL statements,
six row changes. The two-row INSERT counts as two row changes. Source is InnoDB;
native and Swift targets are MyISAM. Both targets use OFF_PERMISSIVE/WARN and the
Swift apply session uses GTID_NEXT=AUTOMATIC.

`demo-compare` waits for native and Swift to reach a sampled source boundary, then
compares database defaults, column metadata and exact row text encoded as HEX. It
checks the expected engine difference and saves `comparison.json` with observations
from all three servers and the Swift checkpoint. Pause manual source writes while
comparing; a changed source boundary rejects the comparison. The demo comparison
is scoped to its `demo.items` fixture, not arbitrary databases/tables or performance.
The larger automated suites additionally compare binlog effects and broader cases.

For manual inspection, use the printed source shell command and replace the
container suffix `source-1` with `native-1` or `target57-1`:

```sql
SELECT * FROM demo.items ORDER BY id;
SHOW CREATE TABLE demo.items;
```

## 3. Run the controlled failure last

```sh
make demo-fail
make demo-status
make demo-compare ARGS=--expect-blocked
```

`demo-fail` first performs a successful comparison and saves the current checkpoint,
then executes [02-failure.sql](../examples/demo/02-failure.sql) **on source only**.
The source accepts explicit `ENGINE=InnoDB` creation. The native replica has InnoDB
disabled and stops with error 3161. Swift stops with an explicit-engine diagnostic
before changing the target. The following valid INSERT of marker row 999 remains
only on source. `failure.json` records these assertions and the unchanged Swift
applied checkpoint. Expected rejection makes `demo-fail` exit successfully; an
unexpected result exits nonzero.

To type the failure SQL yourself, first run `make demo-compare`, execute the two
mutations in 02-failure.sql on source, then run
`make demo-compare ARGS=--expect-blocked`. Do not run demo-fail again afterward.
A normal comparison after failure is expected to fail because source has moved
beyond the blocked replicas. Native and Swift diagnostics need not have identical
error codes; this demo compares their stop boundary and lack of following effects.

## 4. Inspect state and explain qualification

`demo-status` lists all four containers and separately identifies any running
mysql-replicator process by its executable in /proc. It also shows native
receiver/applier status, captured logs for detached starts, and live SQLite
replication state/DDL intents. A healthy idle container is not evidence of a running
replicator: after failure it stays up while the process is absent and SQLite is BLOCKED. Setup also prints a direct
read-only SQLite command. That command executes inside the Docker helper against
the Docker-managed volume, using the same pinned SQLite version as the runtime.
Never open live SQLite/WAL files through a host bind mount or copy them while the
writer is active. There is no REST service.

Explain the separate automated qualification harness and catalog after showing
this small live example. This demo does not establish fleet performance, general
DDL support, automatic recovery, or zero data loss on MyISAM host failure. The
native reference's same-version behavior is one oracle; 5.7 compatibility is still
qualified explicitly. See [DDL completeness](DDL_COMPLETENESS.md) and
[future recovery](START_BOUNDARY.md).

## 5. Cleanup and rehearse again

```sh
make demo-down
make demo-up ARGS=--skip-build
```

`demo-down` sends SIGTERM to the actual Swift writer and waits for it to exit
before stopping the idle container and copying SQLite/relay files. This works for
manual and detached starts. It archives captured log files when present, then
removes only this demo's containers, network and disposable volumes. It
retains host artifacts, including `captured/state/state.sqlite`, for review.
It does not prune unrelated Docker resources or alter qualification-suite stacks.
Fixture credentials and TLS keys in these artifacts are for this isolated lab only.

Ctrl-C/SIGTERM received by the binary while idle or between complete transactions
produces a successful `STOPPED` summary and persists `STOPPED` without an error
diagnostic. Partial capture/apply interruptions and actual errors remain `BLOCKED`;
known transport failures take precedence over a concurrent stop request. A forced
kill cannot guarantee this graceful shutdown. The binary currently prints progress
only after applying a transaction, so silence while waiting for source changes is
normal; `make demo-status` shows the live process and SQLite lifecycle.

A clean stop can be resumed using the existing SQLite checkpoint. After the deliberate
failure, use `mysql-replicator skip '<pendingGTID>' --config /evidence/apply.yaml`
inside the applier container, then resume without `--initialize`. This excludes
only the captured failed group with no write intents. It advances GTID/position
coverage atomically and preserves applied counters; it does not execute the SQL
or resolve uncertain writes. Run `examples/demo/03-after-skip.sql` on source to
verify a fresh INSERT reaches 5.7. The native replica remains blocked.
See [the workbook](DEMO_WORKBOOK.md#skip-the-rejected-ddl-and-resume) for commands
and the separate `make ddl-suite` validation. A fresh rehearsal still needs a
fresh stack/baseline; never delete only SQLite and replay the old baseline
against an already changed target. Setup failures retain a session
record so `demo-down` can clean up before retrying. Avoid running lifecycle
commands concurrently or restarting individual MySQL containers during a rehearsal.

## Automated rehearsal

```sh
make demo-suite
# Only with an image already built from the current runtime/packaging code:
make demo-suite ARGS=--skip-build
```

The suite uses isolated sessions under `artifacts/demo-suite/`,
`artifacts/demo-suite-idle-stop/`, and `artifacts/demo-suite-detached/`,
independent of the interactive stack. Named cases
verify a running shell-ready container with no replication process/state, manual
CLI launch inside that container, refusal of repeated setup/start, 35 seconds of
idle heartbeat operation, successful SQL/schema/data/counters, and the failure
boundary with the shell still available. The explicit-skip case refuses a wider
GTID set, skips the rejected CREATE through the CLI, resumes the queued marker
and a fresh INSERT, verifies the native replica remains blocked, then restarts
again without replay. Separate cases check idle SIGINT with
exit code zero and SIGTERM after the successful workload, asserting STOPPED, no
diagnostic, and unchanged checkpoints/counters. Resume cases queue source DDL/DML
while stopped, deliberately change YAML start coordinates, then verify GTID-baseline
fallback and applied file-position restart. A repeated restart must not replay work
or reset counters. BLOCKED state, reinitialization, and concurrent CLI writers are
refused. Each session archives evidence
and removes its own disposable stack. It does not import
new broad DDL-catalog coverage from these demonstration assertions.

Historical validation before the idle-container change, 2026-09-30: all nine
focused host tests passed; that Docker
rehearsal passed all four named cases and cleanup. Its local
[result](../artifacts/demo-suite/20261001T021431Z-cdec01b7-auto-autocommit-myisam/result.json),
[comparison](../artifacts/demo-suite/20261001T021431Z-cdec01b7-auto-autocommit-myisam/comparison.json)
and [failure evidence](../artifacts/demo-suite/20261001T021431Z-cdec01b7-auto-autocommit-myisam/failure.json)
are retained under ignored artifacts. The rehearsal runs an isolated stack, so it
can be repeated without consuming the interactive session's start boundary.

Validation of the idle-container revision, 2026-09-30: the focused session test
passed, and all five Docker rehearsal cases passed. Manual launch, idle heartbeats,
SQL/schema comparison, and fail-stop with the container still running are recorded
in the [manual-session results](../artifacts/demo-suite/20261001T025252Z-ebf0dd8c-auto-autocommit-myisam/result.json).
Detached startup and cleanup of an active writer passed in the
[detached-session results](../artifacts/demo-suite-detached/20261001T025459Z-4c8b7fbd-auto-autocommit-myisam/result.json).
Those historical results predate the graceful-stop fix: their archived state
records BLOCKED with `live inspection cancelled`. Current qualification requires
STOPPED for idle SIGINT and SIGTERM after applying the successful workload.
Process detection was exercised under Docker Desktop's amd64 emulation as well.

Graceful-stop validation, 2026-09-30: 39 focused Swift tests and all six Docker
rehearsal cases passed. The [idle SIGINT result](../artifacts/demo-suite-idle-stop/20261001T033219Z-6d3d89bd-auto-autocommit-myisam/result.json)
records STOPPED, exit code zero, zero applied work, and an unchanged baseline.
The [post-workload SIGTERM result](../artifacts/demo-suite-detached/20261001T033312Z-c1406c19-auto-autocommit-myisam/result.json)
retains eight transactions, three DDL statements, six rows, and the applied
checkpoint with no error diagnostic. The [failure regression](../artifacts/demo-suite/20261001T032934Z-2c516a3f-auto-autocommit-myisam/result.json)
still blocks explicit-engine DDL without advancing past the failure.

Clean-stop resume validation, 2026-09-30: 46 focused Swift tests and all eight Docker
rehearsal cases passed. The [GTID baseline/repeated-resume case](../artifacts/demo-suite-idle-stop/20261001T035414Z-4a26d80f-auto-autocommit-myisam/result.json)
applied queued DDL/DML exactly once despite YAML pointing ahead of the saved
baseline. The [applied file-position case](../artifacts/demo-suite-detached/20261001T035554Z-8888b00c-auto-autocommit-myisam/result.json)
resumed after eight transactions, applied another DDL and three DML statements,
and retained cumulative counters (12 transactions, 4 DDL, 9 rows). Both exercised
another restart with no new events and concurrent-writer refusal. BLOCKED-state
resume and reinitialization of existing state were refused without replacing
saved diagnostics/checkpoints.


Explicit-skip validation, 2026-09-30: 53 focused Swift tests passed, including
seven skip tests for atomic rollback, wrong/broader sets, write-intent refusal,
writer ownership, inconsistent history, multi-SID coverage, first-group skip and
both restart protocols. `make demo-suite` passed all nine named cases and cleaned
up all three isolated stacks. The [skip rehearsal](../artifacts/demo-suite/20261001T051349Z-bd0a6cdb-auto-autocommit-myisam/cases.json)
used the Ubuntu CLI, preserved counters at 8/6/3 while skipping GTID 18, then
reached 10/8/3 after the queued and fresh INSERTs. A second restart did not replay
work; the rejected table remained absent and the native reference stayed blocked.
[The skip summary](../artifacts/demo-suite/20261001T051349Z-bd0a6cdb-auto-autocommit-myisam/skip.json)
records the consumed GTID/position. `make ddl-catalog-check` passed; the broader
DDL suite was documented for the next demo step, not rerun or counted as new
catalog evidence in this increment. The interactive demo stack was unchanged.
