# Beta.7 operator issues

Status: implementation in progress on `beta/7/04-compatible-sql-routing`.
Initial review: 2026-10-20, commit `636bedb`. Progress updated on 2026-10-20.
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
| OP-03 | Implemented; not yet committed | SwiftLog application handler; JSON logs on stderr; INFO phases and DEBUG query families/timings. Logs exclude SQL and bindings. Synchronous output has bounded records and no growing queue. Focused tests cover output, disabled formatting, slow sinks, flags, and offline replay startup with an absent local target socket. No full profile or performance run was made for this change. |
| OP-08 | Partial | Audited retry for DDL rejected before an intent was saved (`3f3d3d0`). Unit tests cover all four profiles. Live and replay tests pass on 5.7 → 5.7 InnoDB. Coordinate output and the full failure matrix remain. |
| OP-09 | Main fix implemented | Check and cache the timestamp session value. Avoid an unnecessary privileged SET (`9af61b7`). Restricted-account tests pass on 5.7 → 5.7 InnoDB. The full two-version reconnect matrix remains. |
| OP-10 | Main fix implemented | Preserve failed SQL, server message, error number, and SQLSTATE without changing the mutation outcome (`9af61b7`). Query-purpose labels and the full failure matrix remain. |
| OP-04–07, OP-11–13 | Not started under this plan | Existing behavior remains as described below. |

Next: add OP-04 validation. Continue the delivery order below.

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

Proposed interface: `mysql-replicator validate --config FILE --mode run|replay`.
These are proposed options, not implemented commands.

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

Proposed scope: decode the selected range, apply filters and compatibility rules,
and report the planned executor and operations. Do not issue target DML, DDL,
GTID assignments, or scratch-table writes. Target metadata reads are permitted.

Do not implement this by applying inside a transaction and rolling back: MyISAM
writes and DDL are not generally rollbackable.

- Never initialize, lock as a writer, or update the production apply checkpoint.
- Keep preview state in memory, or in an explicitly separate directory. Any saved
  preview position must be labelled as inspected, never applied.
- Define how the preview models CREATE/ALTER/DROP for later row events. Use a
  separate schema model; report unresolved server-generated metadata honestly.
- Mark target checks that need actual execution as unchecked. A dry run cannot
  guarantee constraints, generated values, triggers, or target execution behavior.
- Define finite stop rules and reject ambiguous combinations with `--initialize`.

Acceptance: record all issued target commands in tests and prove there are no
writes or GTID changes. Production state stays byte-for-byte unchanged. Test DDL
followed by DML, filters, SQL/BINLOG selection, and early stop.

Dependency: OP-04 supplies reusable checks; OP-03 supplies readable progress.

## OP-06 — Replay startup order and validation scope

`ApplyRun` opens state and the control endpoint, then calls `archive.validate`
before connecting to the target. That validator walks the full archive. It checks
frame integrity, transaction structure, file continuity, the baseline, and stop
GTID availability. This work is not just filename enumeration or file hashing.

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

## OP-07 — Persistent archive index and restart seek

`ArchiveReplay.validation` is an in-memory cache. It helps retries within one
process, but a new process scans again. `run()` also walks from the first selected
file and skips already executed GTIDs. A saved apply position is not yet a direct
seek optimization.

- Store an archive index in SQLite, separate from applied-state records. Record
  file identity, validation progress, completed GTID ranges, transaction offsets,
  and the context needed to start decoding safely.
- Save validation progress at complete boundaries. Resume interrupted indexing
  without marking scanned transactions as applied.
- Detect replaced, changed, truncated, missing, or reordered files. Invalidate
  only what can safely be invalidated. Retain CRC checks while reading events.
- Follow the prior decision not to add whole-file SHA-256 hashing. State the
  immutable-archive assumption and the limits of filesystem identity checks.
- Start replay near the last durable boundary. Restore the FDE and any required
  table-map context. Use GTID-set membership to handle holes and multiple UUIDs;
  a single maximum sequence number is not enough.

Acceptance: restart with a large applied prefix reads substantially less data;
measure bytes read, not just elapsed time. Test interruption, rotation, file
replacement, incomplete tails, GTID holes, stop limits, and external raw archives.

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

## Suggested delivery order

1. Address the production DDL blocker and its diagnostics: OP-10 and OP-09.
2. Improve CLI errors/help and add logging: OP-01, OP-02, OP-03.
3. Add reusable validation checks, then dry run: OP-04 and OP-05. These remain
   distinct commands because readiness checks and replay previews have different cost.
4. Improve replay startup, index persistence, and recovery output: OP-06–OP-08.
5. Measure schema-discovery cost and reduce verified round trips: OP-11. Query
   attribution from OP-10 can start this investigation earlier.
6. Add phase-aware status and bounded detailed statistics: OP-12 and OP-13.

Each item can be reviewed separately. Run focused tests for each change. Leave
full profile testing to CI. Do not connect to the incident servers or mutate the
supplied bundle as part of this plan.
