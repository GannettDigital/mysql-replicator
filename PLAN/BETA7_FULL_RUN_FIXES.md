# Beta.7 full-run findings

Run: [40124425871](https://github.com/GannettDigital/mysql-replicator/actions/runs/40124425871).
Source commit: `ec8152bc2a1e21fd8329412fb8e42b9ce48b6551`.

This is the run before the common Linux build change. Read the downloaded
`ci-measurement-report/summary.md` and `report.json` first. The local copies and
selected failure bundles are under `artifacts/ci-run-40124425871/`.
Do not treat expected failures in negative-test support bundles as failed tests.
Use the enclosing `result.json` to identify a failed assertion.

## Build and job names

The run built one coverage image. The package build and release-runtime export
steps were skipped. `Debian Packaging & Integration Smoke` is the old name of
the aggregate required check. It only checks dependency results in this run.
The displayed name is now `Selected CI Checks`. The main branch has no branch
protection or required-status rules in the checked API results. Package creation
remains on main.

The common-build change removes the separate app builds for unit tests,
Periphery, the lab, and integration coverage. See
[BETA7_SINGLE_TEST_BUILD.md](BETA7_SINGLE_TEST_BUILD.md) for its checks and limits.

## Grouping

The reviewed run contained 240 execution groups in 125 jobs. Its policy packed up to
three groups with the same profile, variant, and image into one job.
`ci_lab.py` then starts a separate lab command for each group. These commands
create and remove separate fixtures. This saves job setup but does not reuse
MySQL containers. That policy did not balance groups by their measured time.

Distinguish three operations before changing this code:

1. Run compatible cases in one fixture. Preserve their required case order.
2. Start a new fixture when server options, bootstrap state, transport, or case
   isolation require it. Do not merge these cases only to reduce setup time.
3. Assign fixture runs to jobs. Use measured time and show each fixture boundary
   in the report. A job that holds multiple fixtures must not imply shared setup.

Review the case dependencies and fixture mutations before merging groups.
Compare catalog obligations and assertions before and after the change. Do not
remove tests because their line coverage overlaps.

## Failure inventory

The report contains 47 failed execution groups in seven areas:

| Area | Failed groups | Current evidence |
| --- | ---: | --- |
| `reconnect` | 10 | The sampled reverse SQL-transport result also fails `target-reconnect`: `missing unique target connection`. |
| `binlog-reconnect` | 4 | The sampled forward result fails `target-reconnect`: `missing unique target connection`. The harness selects all `apply_fixture` sessions, but the applier now has separate write and metadata sessions. |
| `bootstrap-1` | 8 | The sampled forward failure is `bootstrap-matrix-unicodeidentifiers`. The metadata connection did not set UTF-8 encoding. |
| `ddl-1` | 8 | The sampled forward failure is `ddl-compat-unicode-names`: discovery cannot find the Unicode table. Same metadata encoding defect. |
| `dml-2` | 8 | The sampled forward failure is `matrix-unicodeidentifiers`: the discovered schema differs after CREATE. Same metadata encoding defect. |
| `failure-recovery-offline` | 5 | The sampled forward result fails `myisam-recovery` with `wrong refusal`. Its bundle records MySQL error 1062 and a `possiblyExecuted` write. Check the expected assertion and saved state before changing recovery behavior. |
| `binlog-rows-json-replay` | 4 | The sampled forward result fails `offline-replay`. Its bundle says `cannot restore SQL mode after metadata probe: target connection closed`; the DDL phase is `notIssued`. Inspect the metadata connection and probe lifecycle. |

The SQL-mode failure followed two failed text-protocol operations. The saved
timings showed no 10-second query timeout. The writer retained the completed
BINLOG group's explicit GTID when DDL planning started its temporary-table
probes. Resetting `GTID_NEXT` at that boundary and after source DDL fixes the
focused offline replay case. The later connection-close error hid the original
probe failure.

These counts describe repeated failures, not 47 independent defects. The sampled
bundles do not establish the cause of every profile failure. Focused reruns are
recorded below. Full cross-profile verification remains
with GitHub Actions.

Periphery reports three declarations:

- `DiscoveryReads.Key.textProtocol`: an assign-only finding. This field is part
  of synthesized `Hashable` and `Equatable`. Do not remove it without preserving
  the distinction between text and prepared metadata queries.
- `ReplicatorLogging` imported by `DryRun.swift`: check and remove if unused.
- `ReplicatorCodec` imported by `SourceReadiness.swift`: check and remove if unused.

## Work order

1. Verify the common-build consumers on native x86_64 CI. Local emulation did
   not complete Swift unit execution or Periphery.
2. Read the remaining failed-case bundles. Separate test assumptions, output
   matching errors, and application defects.
3. Fix each cause and rerun only its affected cases locally. Keep recovery
   checks and catalog obligations intact.
4. Change fixture grouping using the measured times and fixture requirements.
5. Run the full suite once in GitHub after the focused checks pass. Check all
   expected coverage collections, assertions, and job results.

## Implemented changes and focused checks

- Shared build committed as `e54c2d6`. It has not been pushed by this agent.
- Metadata connections set `utf8mb4`/`utf8mb4_bin` before any query. The writer
  retains its existing session setup.
- BINLOG-to-DDL transitions reset `GTID_NEXT` before scratch-table probes.
  Completed source DDL resets it before post-DDL schema checks. Raw row groups
  still assign the next GTID directly.
- Target reconnect uses the writer lock to identify the write connection. The
  case also kills the metadata connection before restarting the target server.
- MyISAM recovery checks structured MySQL error number 1062. Its partial-row,
  pending-intent, and checkpoint assertions remain.
- Removed two unused imports. An explicit hash includes the query protocol in
  the discovery key. A unit test confirms separate entries for text and prepared
  queries. Periphery passes without a suppression.
- The current policy assigns one execution group per job and starts longer
  estimated groups first. The plan retains 240 groups, 2,095 obligations, and
  253 coverage collections. Its job count is now 240 instead of 125. Cases,
  profiles, variants, transports, dependencies and assertions remain unchanged.
- Shared fixtures now record setup and cleanup duration and outcome. The
  measurement report includes these records and totals by profile.

The local Linux runtime was rebuilt from the saved common build, with current
application sources and the same compiler flags. Only the changed Swift targets
needed compilation. The fixture image then received the current lab sources and
input label; the lab runs on the host. Local artifacts are retained under
`artifacts/shared-test-build/` and `artifacts/lab/`.

Focused checks completed:

- 26 configuration/discovery/GTID unit tests and nine dry-run/routing unit tests.
- Five discovery-cache tests after the explicit hash change, including the new
  protocol test. Local Periphery reports no unused code.
- 105 CI tool tests and workflow lint.
- `mysql84-to-mysql57-myisam`, SQL transport: Unicode DDL, Unicode DML,
  Unicode bootstrap, and MyISAM recovery. Recovery includes partial writes,
  pending intents, crash/replay refusal, and checkpoint checks.
- The same profile, BINLOG transport: offline replay, resume, and support bundles.

The added metadata disconnect first exposed a harness race. A source dump
connection can remain visible during target reconnect. The test now waits for
`RUNNING` with an increased target reconnect count before the second disconnect.
This confirms that the new target session completed preflight.

The final `target-reconnect` reruns passed with coverage:

- `mysql84-to-mysql57-myisam`, BINLOG transport:
  `artifacts/lab/20261025T045546Z-f450753b/result.json`.
- `mysql57-to-mysql84-innodb`, SQL transport:
  `artifacts/lab/20261025T045548Z-4129d2df/result.json`.

Both cases disconnect the writer and metadata sessions, restart the target,
compare final rows, and check the saved checkpoint. These focused runs do not
replace the full GitHub matrix. Native x86_64 execution of the common-build
consumers, the full cross-profile suite, and warm-cache timing remain pending.
The user must push the branch before those CI checks use these changes.
