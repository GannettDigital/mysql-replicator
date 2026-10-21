# Beta.7 operator issues

Status: implementation in progress on `beta/7/04-compatible-sql-routing`.
Initial review: 2026-10-20, commit `636bedb`. Progress updated on 2026-10-21.
The supplied incident bundle is from `0.1.0-beta.6`.

Inputs: the local `PLAN/beta7-opearability.md` notes and the supplied
`blocked-2026-10-20T213154Z-D8D8B5D2-89DC-479D-8910-C5895B825686.tar` bundle.
The original notes and bundle remain unchanged. Do not copy customer row values,
credentials, or full configuration into public issues or test fixtures.
Use synthetic schemas and rows to reproduce the failures.

## Implementation status

The findings below describe the initial review. Use this table for current status.

| ID | Status | Delivered work and remaining checks |
| --- | --- | --- |
| OP-01 | Implemented (`fc5792a`) | Argument errors use `argument_error`. File-read and YAML errors use `configuration_error`, with available file/key/line/column fields. `reply` suggests `replay`. Exit status remains 1. Focused CLI and configuration tests pass. Environment and server checks remain under OP-04. |
| OP-02 | Implemented (`fc5792a`) | Normal help shows command syntax. `config-help` selects a command, section, or setting. Metadata supplies types, defaults, null handling, units, choices, and examples. Tests compare model fields/types and policy defaults, decode examples, and check command-specific output. |
| OP-03 | Committed (`ec8c379`) | SwiftLog application handler; JSON logs on stderr; INFO phases and DEBUG query families/timings. Logs exclude SQL and bindings. Synchronous output has bounded records and no growing queue. Focused tests cover output, disabled formatting, slow sinks, flags, and offline replay startup with an absent local target socket. No full profile or performance run was made for this change. |
| OP-08 | Committed (`35e9967`) | Status separates applied and pending offsets. Recovery inspection includes saved source failures before target setup. Advice identifies supported operator actions. Empty startup state with a current source failure permits explicit retry. Focused middle-file tests and isolated MySQL 5.7 CLI checks pass. Uncertain writes still require DBA reconciliation. |
| OP-09 | Main fix implemented | Check and cache the timestamp session value. Avoid an unnecessary privileged SET (`9af61b7`). Restricted-account tests pass on 5.7 → 5.7 InnoDB. The full two-version reconnect matrix remains. |
| OP-10 | Main fix implemented | Preserve failed SQL, server message, error number, and SQLSTATE without changing the mutation outcome (`9af61b7`). Query-purpose labels and the full failure matrix remain. |
| OP-04 | Committed (`6cf57c3`) | Added `validate --config FILE --mode run|replay`. JSON checks cover settings, credentials, TLS, private filesystem probes, target readiness, and source or archive preambles. No state is opened and no target data is written. Unproved write and resume checks are explicit. 30 focused tests and isolated MySQL 5.7 run/replay checks pass. SQL traces confirm reads and session changes only; GTIDs, schemas, table counts, and local state stay unchanged. |
| OP-05 | Committed (`1d27330`) | Added `run --dry-run` and `replay --dry-run`. Real metadata reads and discarded writes use separate interfaces. Schema caching is shared with apply. DDL clears preview metadata; later reads use the unchanged target. No production state is opened. Focused tests and isolated SQL/BINLOG dry-run and normal replay checks pass, including explicit MyISAM locks. |
| OP-06 | Slice 1 committed (`8e17740`) | Target readiness checks now precede the full event scan. Reuse OP-04 checks for settings, engine, native channels, and session permissions. Writer ownership, scratch setup, GTID repair, and data writes stay after full validation. Startup cancellation remains resumable. Detailed `ctl status` phases were added in OP-12. |
| OP-07 | Committed (`8e17740`) | Save completed file validation and start metadata in SQLite. Resume at the saved applied byte offset after reading format metadata. GTID-only starts select a file by `Previous_gtids`. No per-transaction archive index or file hash. Focused tests and isolated SQL/BINLOG stop-and-resume checks pass. |
| OP-11 | Committed (`f7eed57`) | Metadata-family timings, per-discovery query reuse, and configurable `maximumCachedTables` (default 6000). SQL/BINLOG runs on 5.7 → 8.4 InnoDB and 8.4 → 5.7 MyISAM pass at zero/20 ms added RTT, with DDL and restart checks. See [measurements](OP11_SCHEMA_DISCOVERY_RESULTS.md). Larger table-count measurements remain future work. |
| OP-12 | Committed (`cfcf917`) | Live worker phases, monotonic ages, separate read/prepared/applied positions, and provisional ETA samples. Status reads memory only. |
| OP-13 | Implemented | Optional table statistics, 6000-entry default with a one-time limit warning and overflow totals, atomic applied counts, process snapshots, and paged status. Focused tests and four 10K replay runs pass. See [measurements](OP13_TABLE_STATISTICS_RESULTS.md). |

Remaining work before this plan can be closed:

- OP-09: check CREATE TABLE LIKE with a restricted account on MySQL 5.7 and
  8.4. Cover matching and mismatched timestamp session settings, both on a
  fresh connection and after reconnect.
- OP-10: complete query-purpose details in final errors and support bundles.
  Check restricted SET, missing table, denied SELECT, timeout, and lost COMMIT.
  Confirm that preparation failures retain `notIssued` for the source mutation.
- Run the full profile suite in GitHub Actions. Local checks remain focused.

Larger table-count and release-build performance measurements remain future
work. They are separate from these remaining error-handling checks.

## Issue list

| ID | Issue | Finding | Type |
| --- | --- | --- | --- |
| OP-01 | Report CLI and config errors correctly | A command typo is reported as a decoder failure | Confirmed defect |
| OP-02 | Show types, defaults, examples, and relevant command help | Nested help exists; its output needs work | Usability |
| OP-03 | Add log levels and useful operation messages | Progress JSON does not explain individual waits | Feature |
| OP-04 | Add a configuration and environment check command | No single command covers these checks | Feature |
| OP-05 | Add dry-run semantics with isolated state | A write-free preview needs a separate execution contract | Design and feature |
| OP-06 | Report target setup errors before a full archive scan | Validation currently precedes the target connection | Confirmed ordering issue |
| OP-07 | Save archive validation and seek information | The validation cache exists only in memory | Performance and restart |
| OP-08 | Expose failed coordinates and explain resume | Coordinates are saved; direct seek and operator output need work | Usability and verification |
| OP-09 | Remove unnecessary privileged DDL session changes | Unconditional timestamp-default SET is a strong suspect | Production defect investigation |
| OP-10 | Retain the failing target operation and server message | Error 1227 loses the privilege name and preparation statement | Confirmed diagnostic defect |
| OP-11 | Reduce schema-discovery round trips and stalls | The incident spends most of its time in target SQL/schema waits | Performance |
| OP-12 | Show current phase, wait reason, and estimate freshness | Status gives a checkpoint but little explanation for a stall | Observability |
| OP-13 | Add bounded statistics by table and operation | Current counters are mainly global | Feature |

## Evidence and corrections

The supplied configuration selects `mysql57-to-mysql57-innodb`, with source GTID
preservation disabled. It uses the default SQL transport. This is not evidence
of a BINLOG-transport failure or of an 8.4-to-5.7 compatibility problem.

The bundle records 289 completed transactions, 342 applied rows, and three target
reconnect attempts. SQLite has one PENDING group. Its start position equals the
last applied position. The group also has its end position and GTID. There are
no DDL intents. The diagnostic says `statement.phase=notIssued`. Thus the
checkpoint is present, and the failure occurred before the CREATE TABLE was issued.
A successful manual CREATE TABLE does not exercise all preparation statements
that the replicator sends, or prove that both connections use the same grants.

The recorded times are inclusive and can overlap. Do not add them together:

| Measurement | Recorded value | Meaning |
| --- | --- | --- |
| `capture.decode` | 0.030 s, 1,905 calls | Typed row decoding is small in this sample |
| `capture.schema_wait` | 441.70 s, 28 calls, 2 failures | Capture waits for target-backed schema resolution |
| `target.schema` | 208.47 s, 27 calls | Schema work takes substantial time |
| `target.sql` | 444.27 s, 1,881 calls, 2 failures | Includes metadata, session, and row SQL |
| `target.reconnect_wait` | 7.00 s, 3 calls | Backoff alone does not explain the delay |
| Apply worker | 26.96 s busy / 392.12 s idle | The worker often lacks prepared work |
| `progress.emit` | 0.018 s | Output is not the measured bottleneck in this run |

These values do not identify an individual slow query. They also do not prove
whether latency, server metadata work, locks, or repeated queries caused the delay.
Detailed apply profiling was not enabled in the supplied configuration.

## OP-01 — CLI and configuration error categories

`reply --config ...` fails in ArgumentParser, but `argumentFailure` maps an unknown
first command to `DecoderError`. The final output then says `binlog_decode_failed`.

- Report an unknown command directly, with a `replay` suggestion where applicable.
- Give argument errors and YAML errors distinct categories. Include a config path,
  key path, and line/column when the YAML decoder supplies them.
- Preserve machine-readable output on stderr. Do not attach invented binlog offsets.
- Define and document exit status values before changing their current contract.

Acceptance: unknown commands, misplaced flags, missing values, duplicate options,
and invalid YAML produce useful messages without opening state or connections.
Help and version remain successful, side-effect-free operations.

Code: `Sources/ReplicatorCommandLine/CommandLine.swift`,
`Sources/ReplicatorCLI/main.swift`, `Sources/ReplicatorConfiguration`.

## OP-02 — Typed and command-specific help

`ctl --help` and `ctl status --help` already work. However, the executable appends
the full config override catalog to every help response. The catalog uses `VALUE`
for every setting and stores type/default information only in description text.

- Add structured option metadata: type, required/optional, allowed values, units,
  default or no default, example, and applicable commands/modes.
- Show nested command syntax before configuration details. Show only relevant
  overrides, or provide a separate full configuration-help view.
- Keep YAML and existing option names. This does not require a config-format rewrite.
- Extend the existing example/model checks to detect stale defaults and types.

Acceptance: help explains integer, boolean, string, list, map, enum, and nullable
values. `ctl` lists its actions; each action shows its own options. Examples parse.

Code: `ConfigurationOptions.swift`, `ConfigurationOverrides.swift`, command parser.

## OP-03 — Leveled application logging

Use SwiftLog as the application logging API, with an explicit backend and output
contract. Existing MySQLNIO logger use is not an application-level logging policy.

Proposed flags: `--verbose` selects info; `--debug` selects debug. Specify defaults
and flag precedence. SwiftLog uses `warning` for the warning level.

- INFO: startup phases, selected mode, archive scan progress, target setup,
  reconnects, DDL start/end, checkpoints, drain, and blocked state.
- DEBUG: query purpose and duration, schema-cache decisions, transport selection,
  and bounded event context. Do not log each row at INFO.
- Keep operational logs on stderr and command-result JSON on stdout. Preserve
  existing progress consumers when introducing levels or a new JSON envelope.
- Exclude passwords and bound row values from ordinary logs. Sensitive bundle
  collection remains a separate, documented function.

Acceptance: an operator can explain an idle replay from INFO messages. DEBUG can
identify slow schema operations. Disabled messages avoid expensive formatting.
Test parseable output and log backpressure; do not assume output is free.

## OP-04 — Validate configuration and environment

Implemented and committed in `6cf57c3`. This command is available now:

```sh
mysql-replicator validate --config apply.yaml --mode run
mysql-replicator validate --config replay.yaml --mode replay
```

The command writes a JSON checklist. Each check is `passed`, `failed`, or
`notChecked`. Failed checks include a suggested next step. Exit status is 1
when a check fails. `notChecked` identifies work that needs a full event scan,
a binlog stream, saved-state access, or actual target writes.

OP-04 is the standalone readiness command. OP-05 adds `--dry-run` to inspect
events without writes. OP-06 reuses target readiness checks during normal replay
startup, before the full archive scan. These are separate purposes.
See [validation behavior and limits](../docs/COMMAND_LINE.md#configuration-and-environment-validation).

- Check syntax, credentials resolution, TLS files, profiles, limits, and paths.
- Check target connection, version, engine contract, required privileges, and
  required session values. Identify checks that cannot be proved without writes.
- In run mode, check the source connection and source contract.
- In replay mode, never connect to the source. Report archive file count, size,
  readability, and preamble checks without a compulsory full content scan.
- Test directory writability with private temporary files and remove them.
  Do not initialize production SQLite, advance state, write target tables, or
  create GTID scratch objects. Do not label this check strictly read-only if
  it creates filesystem probes or changes disposable session settings.

Acceptance: a structured check list identifies the failing check and a useful next
step. Bad TLS or target credentials fail before a multi-day archive is scanned.
Validation is a readiness check, not proof that all future DDL/DML will succeed.

## OP-05 — Dry run with separate state

Implemented scope: decode the selected range, apply filters and compatibility rules,
and report the planned executor and operations. Do not issue target DML, DDL,
GTID assignments, or scratch-table writes. Target metadata reads are permitted.

Do not implement this by applying inside a transaction and rolling back: MyISAM
writes and DDL are not generally rollbackable.

- Never initialize, lock as a writer, or update the production apply checkpoint.
- Keep preview state in memory, or in an explicitly separate directory. Any saved
  preview position must be labelled as inspected, never applied.
- Use the shared `SchemaMetadataCache` with a supplied metadata reader. Discard
  DDL and clear the preview cache. Read the actual, unchanged target schema on
  the next lookup. Do not predict schema changes. Later events can fail because
  CREATE, ALTER, DROP, or RENAME was not executed.
- Mark target checks that need actual execution as unchecked. A dry run cannot
  guarantee constraints, generated values, triggers, or target execution behavior.
- Define finite stop rules and reject ambiguous combinations with `--initialize`.

Acceptance: record all issued target commands in tests and prove there are no
writes or GTID changes. Production state stays byte-for-byte unchanged. Test DDL
followed by DML, filters, SQL/BINLOG selection, and early stop.

Read and write interfaces are separate. Normal apply opens two physical MySQL
connections. Server schema queries use the metadata connection. The write
connection owns transactions, session settings, locks, and temporary tables.
Session-dependent reads and reads under an explicit table lock stay on that
connection. Both connections must report the same server UUID and version.
Dry run opens only the metadata connection and replaces the writer with a
connection that discards commands. It inspects SQL templates; it does
not verify final bindings, scratch expressions, or target execution behavior.

Cache policy: no TTL, periodic refresh, or automatic eviction. Entries remain
until explicit DDL invalidation/replacement or target-session reconstruction.
The applier is the only target writer. The table limit bounds memory use.

Future work: add bounded metadata read-ahead on the separate connection.
A DDL barrier must discard old metadata and prepared work that depends on it.
New metadata reads must wait for the DDL to complete. Invalidate both names for
rename and include FK dependencies and database DDL. Session-local reads must
stay on the write session. A separate connection cannot bypass server metadata
locks. Measure this change before enabling it.

Dependency: OP-04 supplies reusable checks; OP-03 supplies readable progress.

## OP-06 — Replay startup order and validation scope

Initial behavior: `ApplyRun` opened state and the control endpoint, then called
`archive.validate` before connecting to the target. That validator walks the
full archive. It checks frame integrity, transaction structure, file continuity,
the baseline, and stop GTID availability.

Slice 1: after opening state and control, connect to the target and run reusable
readiness checks before `archive.validate`. Check a saved target UUID without
binding a new identity. Permit only session changes during these probes. Keep
writer ownership, scratch setup, GTID repair, and application writes after full
validation. Keep existing target retry policy and complete in-memory validation
reuse. Cancellation before or during validation saves a resumable STOPPED state.
Logs show `Validate target readiness` before archive scan progress. The control
endpoint remains available. OP-12 now supplies detailed phase reporting.

Retain complete prevalidation. OP-07 now saves completed file checks and uses
saved replay offsets. Lazy validation remains outside this change.

Focused checks passed: unavailable-target ordering (including a late corrupt
frame), cancellation before connection/scan, and isolated MySQL 5.7 checks for
invalid binlog settings, a late CRC error before target writes, and successful
one-transaction replay. Full profile testing remains for CI.

- Run quick configuration, inventory, and target-readiness checks first.
- Separate connection/readiness checks from write-capable target setup.
- Keep validation progress visible through logs and `ctl status`.
- Decide explicitly between retaining complete prevalidation and validating
  unread files as replay proceeds. Lazy validation changes the guarantee: later
  corruption can be found after earlier transactions have applied.
- Prefer cached complete validation first, through OP-07. Do not silently remove
  CRC, transaction-boundary, or missing-history checks to reduce startup time.

Acceptance: invalid target settings fail before the full scan. Valid archives
retain integrity checks. A later corrupt file behaves according to the documented
validation policy. Replay never needs a source connection.

## OP-07 — Saved file metadata and restart offsets

Implemented. Keep one record per file; do not build a per-transaction
archive index. Binlog `position` is a byte offset within the file.

- Save completed validation in `archive_validation` in the existing SQLite
  database. Include file size, identity, timestamps, `Previous_gtids`, first
  transaction GTID/offset, completed GTIDs, rotation, and validation settings.
- Compare file metadata on restart. Reuse unchanged file checks. Rescan changed
  files or incomplete scans. Do not hash files. Operators must keep input files
  immutable; filesystem metadata cannot prove byte-for-byte equality.
- Keep file order, rotation, GTID continuity, baseline, and stop-limit checks.
  Validate all uncached files before target writes.
- Use existing durable coordinates: `state.applied_file/applied_position`,
  `groups.source_file/start_position/end_position`, and
  `snapshots.source_file/source_position`. GTIDs and offsets already advance
  together. Do not duplicate them in a new checkpoint table.
- Read the format and `Previous_gtids` events, then seek to the saved applied
  offset. Retain event framing and CRC checks after the seek. A cold validation
  scan also verifies that the offset is a complete boundary and that its prefix
  contains no unapplied GTIDs. Saved checkpoints come from verified SQLite state.
- Without a saved applied offset, use file `Previous_gtids` sets to select the
  resume file. Scan that file for missing GTIDs. Keep holes, UUIDs, and tags.
- Save file records only after a complete file scan. These records do not advance
  application state. Keep persistence callbacks in serial startup validation;
  the capture producer does not access SQLite.

The 29 focused unit and CLI tests pass. They cover SQLite reopen, cancellation between files, corrupt and
truncated files, atomic replacement, invalid cache versions/settings, file
ordering, GTID holes, inclusive stop limits, direct seek, EOF, and rotation.
Two older startup tests now request cancellation before target setup, because
OP-06 moved target checks before archive scanning.

Isolated MySQL 5.7 MyISAM checks pass for SQL and BINLOG transport. Both stop at
GTID 12 / offset 2213, restart with the same state, and apply GTIDs 13–14. Final
rows and SQLite checkpoints match. The warm validation reads no event payloads.
The replay pass reads 870 bytes, including format metadata, from a 2,885-byte
fixture. Evidence: `/tmp/beta7-op07-live/`. Full profile suites remain for CI.

## OP-08 — Recovery coordinates and operator workflow

The reported coordinates are already saved in `state` and `groups`. The missing
DDL intent in this incident is consistent with failure during DDL preparation.
It does not mean that the failed source transaction was lost.

- Show last committed position separately from failed transaction start/end,
  current scan position, and any prepared-but-uncommitted position.
- Explain why state is blocked and which commands are allowed next. Do not
  suggest `--initialize` as a way to resume an existing state directory.
- Test supported skip or DBA-resolution paths, then restart from the recorded
  boundary without reapplying committed transactions.
- Keep uncertain target outcomes blocked. Saved coordinates alone do not prove
  that an interrupted target write did not occur.

Acceptance: inject pre-write DDL rejection, uncertain DML, and decode failure in
middle archive files. Status, bundles, and recovery inspection identify the
correct boundaries. Tests distinguish logical resume from OP-07's seek speed.

Implemented:

- Status and final errors keep `appliedPosition` separate from
  `pendingTransactions` (GTID, start, and end). The list contains at most 16
  unresolved groups; `pendingTransactionCount` gives the full count. Status
  reads these fields from memory without extra SQLite queries.
- Recovery inspection includes `sourceFailurePosition`, including failures before
  target setup. Decoder errors report the physical archive offset. An incomplete
  transaction does not get an invented end offset.
- `recovery` gives the reason and supported next steps. DDL rejected before a
  write intent permits retry. Uncertain writes still need target reconciliation.
- A state with no target binding can be inspected and explicitly retried only
  when it is empty and has a source failure that matches the current diagnostic.
  `recovery resolve retry --gtids none` records the decision. It does not advance
  the applied checkpoint. Resume uses the same state directory without
  `--initialize`.

Validation:

- 19 focused recovery tests pass. Cases cover middle-file DDL rejection,
  uncertain COMMIT, validation and row-decoder errors, invalid startup state,
  support-bundle offsets, and resume after an explicit resolution.
- Isolated MySQL 5.7 CLI checks confirm that final status, recovery inspection,
  and automatic support bundles agree for a middle-file decode failure and a
  DDL rejection. After file repair and explicit retry, replay completes with
  the same state directory.
- The uncertain COMMIT test uses an injected durable journal. It checks
  reconciliation and resume boundaries; it is not a network-disconnect test.
- The full suite remains for GitHub Actions. Operations, replay, reverse-flow
  documentation, and recovery command help describe the new output and limits.

Current scan and prepared positions must remain distinct from the applied
checkpoint. OP-12 now supplies their continuous live reporting. OP-09 still needs
its target-version reconnect checks. OP-10 still needs complete failure-purpose
output and error cases; DEBUG query-purpose labels already exist in TargetSession.
Complete these focused checks before closing this plan.

## OP-09 — DDL session privilege failure

The incident has error 1227, no issued CREATE TABLE, and preservation disabled.
`setDDLSession` unconditionally sends:

```sql
SET SESSION explicit_defaults_for_timestamp=1;
```

The checked-in MySQL 5.7 source calls `check_has_super` for this session setter
(`sql/sys_vars.cc`, `check_explicit_defaults_for_timestamp`). It checks privilege
even when assigning the current value. This is a strong candidate for the failure,
but the bundle does not identify the exact failed preparation statement.

- Reproduce CREATE TABLE LIKE with a synthetic schema and a non-SUPER account.
- Inspect the session value first. Avoid an unnecessary privileged SET when it
  already matches the required semantics. Cache the result per connection.
- If the required value differs, give a specific error and operator action.
  Do not silently change timestamp semantics or require SUPER for unrelated DDL.
- Check the account and effective grants used by the replicator, not only the
  account used for the successful manual command.

Acceptance: CREATE TABLE LIKE succeeds without SUPER when required session values
already match. A mismatched restricted value fails before DDL with a clear cause.
Test fresh sessions and reconnects on both target versions.

Code: `Sources/ReplicatorApply/DDLSession.swift`, `TargetSession.swift`.

## OP-10 — Target SQL failure details

`TargetSession.query` discards most MySQL server error text. It records the target
statement only for mutation calls. A failed metadata query or session SET can
therefore leave the source DDL visible but hide the command that actually failed.

- Preserve error number, SQLSTATE, and the useful server message.
- Record a stable query purpose, execution phase, and safe SQL template for
  metadata/session failures. Keep this separate from the row-write outcome trace.
- Retain `notIssued` for the source mutation when preparation fails. Do not turn
  an unsuccessful SET or SELECT into an uncertain user-data write.
- Put these details in the final error and support bundle without requiring DEBUG.
  Ordinary errors must not expose credentials or bound customer values.

Acceptance: restricted SET, missing table, denied SELECT, timeout, and lost COMMIT
produce distinct diagnostics. Existing reconnect and recovery decisions remain
correct. OP-09 should name its exact failing operation after this change.

## OP-11 — Schema discovery on a remote target

Implemented with focused validation. See [the results and remaining scale checks](OP11_SCHEMA_DISCOVERY_RESULTS.md).

The incident is dominated by schema resolution and target SQL waits. Schema
caching already exists. Investigate queries within each first discovery, repeated
verification, FK graph traversal, and cache loss after reconnect or DDL.

- Give metadata query families separate timings and call counts. Separate target
  execution from reconnect delay, queue waits, archive scan, and decode work.
- Capture the slow query family, table, timeout, and reconnect reason.
- Reuse metadata results within one discovery before adding more concurrency.
  Keep ordered DDL invalidation, schema checks, and FK visibility rules intact.
- Add a deterministic lab option for target network delay. Use an isolated proxy
  or scoped `tc` rules. Measure actual RTT and document whether delay is one-way.
- Compare zero-delay and 20 ms RTT with many tables and representative FK graphs,
  plus repeated writes to warm the cache. Include SQL and BINLOG selection where
  supported. Compare the same workload and metadata contract.

Acceptance: a report identifies round trips per first table and repeated table,
metadata time, row-write time, and overall throughput. The warmed cache avoids
repeated discovery. A DDL barrier or reconnect cannot leave stale metadata.
Do not assume larger batches or more row workers will fix this wait.

## OP-12 — Live status and ETA during slow work

Identical status replies can mean no committed progress, not necessarily a dead
process. Status currently lacks enough phase and freshness information to tell.
The reported ETA varies greatly at low transaction rates.

- Add status generation time, last-progress time, current phase, and elapsed time
  in that phase. Expose target reconnects, archive validation, schema discovery,
  and target execution as different waits.
- Keep committed, read, and prepared positions separate.
- Show estimate sample duration and transaction count. Mark a sparse estimate as
  provisional. Continue to provide an estimate where possible; do not replace
  useful approximate values with an unexplained `unknown`.
- Do not make a short `ctl status` request wait for a database query.

Acceptance: status remains responsive during a long metadata query or archive
scan. Test sparse progress, stalls, reconnects, paused execution, and time changes.
Do not sum inclusive stage timings to calculate wall time.

Implemented: `activity` reports live phases for the coordinator, capture, and
target workers. Each phase has a monotonic duration. Status also reports reply
time, checkpoint age, last-progress time, and separate read and prepared
positions. The applied position still comes from the SQLite checkpoint.
Status copies memory only. It does not call SQLite or MySQL. Sparse ETA samples
are provisional. Old samples retain their approximate ETA with age and stale
status. Paused runs still have no active ETA unless the goal is complete.

Focused checks on 2026-10-20:

- Eleven unit tests passed. They cover status replies while a worker is held
  in a metadata, archive-validation, reconnect, or execution phase; nested phase
  cleanup; separate positions; sparse rates; stalls; and clock changes.
- A local 5.7 → 8.4 InnoDB replay passed with 4 related tables and 32 row
  transactions, at zero and 20 ms added RTT. Final rows matched the source.
  The follow-up UPDATE, ALTER, INSERT, and saved-state restart also passed.
- During the delayed initial replay, 74 status requests returned. The maximum
  response time was 2.5 ms. Replies showed real schema queries and target
  execution, with read and prepared positions. This is a local socket result,
  not a guarantee for every host.
- Evidence: `artifacts/operability/op12-live-status-20261021/`. The status
  samples are in `20ms/status-initial.json`; per-case results contain final
  summaries. The held-worker unit test covers a long archive-validation wait;
  this small archive does not measure a multi-day validation scan.

## OP-13 — Statistics by schema, table, and operation

Add optional aggregates for observed events, planned operations, applied rows,
filtered rows, skipped transactions, and failures. Keep these categories separate.
Include DDL operation types, encountered column/index types, and relevant timing
categories. Do not treat a column type as a per-row event.

- Bound the number of table entries and memory use. Define eviction or aggregation
  behavior for dynamic tables, and identity changes after RENAME/DROP.
- Keep frequent updates in memory. Persist snapshots or batch deltas in SQLite;
  avoid an extra commit for every event or row.
- Specify which counters are durable and which are best-effort since process start.
  Keep applied counts tied to confirmed completion, including during replay retry.
- Provide a compact default status and an explicit detailed view/export. Include
  the aggregates in support bundles.

Acceptance: INSERT/UPDATE/DELETE, DDL, filters, skips, failures, restart, and rename
produce defined counts. Measure overhead and output size on the existing 10K
harness. Large table counts must not produce unbounded memory or status responses.

Implemented with `statistics.tableDetails` (default false),
`statistics.maximumTableEntries` (default 6000), and
`statistics.snapshotIntervalSeconds` (default 30). Applied counts share the
checkpoint commit. Event observations, plans, failures, types, and query times
are process-local measurements with saved snapshots. Entries retain name history
after RENAME/DROP. New names use an overflow entry after the limit. The tool
warns once per process when the limit is reached.

Normal status stays compact. `ctl status --details --offset N --limit N` returns
at most 100 entries from memory. Support bundles include the saved entries in
SQLite. Filtered events without decoded rows have a separate counter; the tool
does not infer their row count. See [operations](../docs/OPERATIONS.md#table-statistics)
for count definitions, persistence, gaps while collection is disabled, and export.

Validation: 21 focused Swift tests and 4 Python helper tests pass. Four 10K
5.7 → 8.4 InnoDB replay runs pass, including DDL, restart, and saved row-counter
checks. Collection increased mean elapsed time in this local debug run by 26%.
Most of the difference appeared in target SQL time; the runs do not isolate
counter CPU cost. Keep collection optional. Status replies stayed below 7 ms.
The [measurement report](OP13_TABLE_STATISTICS_RESULTS.md) records exact scope,
output sizes, and limitations. The full profile suite remains for CI.

## Suggested delivery order

1. Address the production DDL blocker and its diagnostics: OP-10 and OP-09.
2. Improve CLI errors/help and add logging: OP-01, OP-02, OP-03.
3. Add reusable validation checks, then dry run: OP-04 and OP-05. Use the
   `validate` command for readiness checks and `run --dry-run` or `replay --dry-run`
   for event inspection. These checks have different costs.
4. Improve replay startup, file metadata persistence, and recovery output: OP-06–OP-08.
5. Measure schema-discovery cost and reduce verified round trips: OP-11. Query
   attribution from OP-10 can start this investigation earlier.
6. Add phase-aware status and bounded detailed statistics: OP-12 and OP-13.

Each item can be reviewed separately. Run focused tests for each change. Leave
full profile testing to CI. Do not connect to the incident servers or mutate the
supplied bundle as part of this plan.
