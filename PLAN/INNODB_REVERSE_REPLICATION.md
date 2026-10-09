# MySQL 5.7 → 8.4 InnoDB replication

Status: reverse DML implemented; native comparison and DBA recovery added.
The existing qualified 8.4 → 5.7 MyISAM profile must retain its behavior. This document records the agreed scope and acceptance
criteria; completion and validation evidence are recorded below as work lands.

## Objective and contract

Support a dedicated, initially consistent MySQL 8.4 InnoDB destination fed by a
5.7 InnoDB source, with GTIDs, ROW logging and FULL row images. Use one ordered
applier initially. Source and target schemas must match at a consistent bootstrap
position, and no independent application writes may modify the destination.

SQLite remains the only replication-state database. Its durable relay files,
schema versions and write intents retain the evidence needed for DBA-assisted
recovery. Do not introduce a target-side checkpoint database. An uncertain commit
stops replication: row comparisons provide evidence, not universal commit proof.
The fallback when reconciliation is impractical is a new consistent copy.

The eventual test topology uses distinct instances in a one-way chain:

```text
5.7 InnoDB → replicator → 8.4 InnoDB → replicator → 5.7 MyISAM
```

## 1. Reverse harness and explicit profile

- Add explicit supported version/engine profiles without relaxing existing guards
  globally. Retain the current profile as the default for existing configurations.
- Add a disposable 5.7 source and 8.4 target harness with consistent seed data,
  GTIDs, TLS and supported schema types/primary keys.
- Validate destination data and source progress. Native 5.7 → 8.4 replication is
  not assumed to be a supported comparator.

Acceptance: reproducible reverse-flow fixtures and profile validation tests.

## 2. Metadata and target sessions

- Fill missing 5.7 table-map interpretation from the validated destination schema
  at the replay position; validate all metadata supplied by the source event.
- Handle version-specific session settings, replication-status queries and
  authentication. Qualify real managed-service privileges separately from Docker.
- Preserve source DDL defaults and ordered schema changes. Drain prior work and
  refresh caches at DDL barriers before interpreting dependent rows.
- Qualify signed/unsigned numbers, strings, composite keys, ENUM/SET and supported
  schema changes. Do not interpret historical events using today's source schema.

## 3. Transactional InnoDB execution

Persist durable intent/relay, then BEGIN, apply one source transaction, COMMIT,
then advance SQLite. Preserve source transaction boundaries; combine inserts
within a transaction only. Preparation may still overlap execution.

On failure, attempt rollback and distinguish confirmed rollback from uncertain
outcome. Preserve evidence if commit acknowledgement is lost. Handle foreign keys
explicitly; target triggers remain rejected. DDL has separate commit semantics.

Acceptance: multi-table transaction atomicity and rollback/disconnect tests, with
the existing MyISAM execution behavior unchanged.

## 4. Recovery inspection

Provide offline GTID/boundary/schema/key/before-image/after-image/phase/error
inspection using SQLite plus relay references. Optionally compare destination
rows, reporting matches-before, matches-after, absent, different or ambiguous.
Fold repeated changes to a key into transaction-level initial/final expectations;
PK changes require old and new keys. Retain the whole uncertain batch, since
later transactions can overwrite the effects of earlier transactions.

Acceptance: injected crashes yield actionable reports without manual relay decoding.

## 5. Explicit audited resolution

Provide mark-applied, retry-after-reconciliation and skip actions naming the exact
pending transaction and requiring an operator reason. Require exclusive ownership,
resolve transactions in order, preserve original evidence, and make resolution
itself crash-safe. Never infer a successful commit solely from a plausible match.
DDL skips require explicit schema reconciliation before dependent rows proceed.

Acceptance: representative failures can be resolved without manual SQLite edits.

## 6. Qualification and performance

Test disconnects before/during commit, kills after target commit but before
SQLite completion, target restarts, duplicate keys, missing rows, PK changes and
multiple transactions awaiting checkpoint. Run the 10K workload with latency
representative of deployment, and then the complete three-server chain.

Source progress is distinct from destination-generated GTIDs. Validate downstream
effects of recovery decisions as well as final row equality.

The current MyISAM applier accepts only single-statement, single-table source
groups. The reverse InnoDB profile preserves multi-statement/multi-table source
transactions, so the downstream MyISAM acceptance and partial-failure contract
must be extended and tested before qualifying this complete chain. Do not split
the InnoDB commits merely to conceal this downstream limitation.

## 7. Operations

Document consistent bootstrap, required binlog retention, clean shutdown,
investigation, resolution and rebuilding. For GKE, persist the complete state
directory on a block-backed volume with exclusive writer ownership. A persistent
volume preserves evidence but cannot remove the cross-database commit window.

## Milestones

1. Steps 1–3: working reverse DML profile and harness.
2. Steps 4–5: DBA-assisted recovery tooling.
3. Steps 6–7: deployment and full-chain qualification.

Parallel appliers and guaranteed automatic uncertain-commit recovery are outside
this scope. Do not claim Cloud SQL or production readiness from Docker tests alone.

## Implementation evidence

- Plan saved before implementation.
- Initial DML increment implemented: explicit profile, separate source/target
  contracts, historical-schema handshake for 5.7, separate InnoDB executor, and
  profile binding in SQLite format 9. Source transactions can span statements
  and tables; committed progress remains batched in SQLite.
- Reverse Docker fixture passed against 5.7.42 and 8.4.8, including composite PK
  changes, repeated writes, unsigned BIGINT, decimal/ENUM/SET/binary data, clean
  resume, and a confirmed rollback after the second statement fails. Initial
  evidence: `artifacts/reverse-suite/20261006T221314Z-9aaf94ad-auto-transaction-myisam/`.
- Lost-COMMIT and rollback-failure paths have unit fault tests. The live fixture
  uses no SUPER privilege on the target account. This is not Cloud SQL validation.
- At this initial increment, dynamic DDL and foreign keys were blocked. DDL
  qualification is added in the correctness increment below; FK/full-chain work
  remains deferred.
- Operator documentation: `docs/REVERSE_REPLICATION.md`. CI runs the reverse
  fixture using the same executable as the existing integration/release image.
- Unit qualification: 308 Swift tests pass, including rollback/COMMIT-loss,
  producer cancellation at schema barriers, strict-vs-legacy metadata checks,
  profile binding and format-8 checkpoint migration.
- Final validation (2026-10-06): 7 Rust tests pass; Periphery reports no unused
  code. Existing MyISAM integration sample passes all 3 selected/dependent
  checks: `artifacts/ddl-suite/20261006T222305Z-9101007e-auto-autocommit-myisam/`.
- Final reverse fixture passes with the same executable as the MyISAM fixture:
  `artifacts/reverse-suite/20261006T222436Z-e543ad83-auto-transaction-myisam/`.
  The directory suffix is inherited from the shared native harness naming;
  `result.json` records the actual InnoDB reverse profile and server versions.
  Validation logs are copied to `artifacts/reverse-suite/validation/`.

## Native comparison, recovery and demo increment

Scope agreed after the initial DML commit: complete the native comparator and
DBA recovery, then provide a 5.7 → 8.4 demo. Do not expand DDL, foreign keys or
the downstream MyISAM transaction contract in this increment.

- Native reference: the same 5.7 InnoDB source feeds native 5.7 InnoDB and our
  8.4 InnoDB target. Compare data, normalized schema, GTID coverage, duplicate-key
  rollback and resume. The 10K backlog uses one INSERT and one UPDATE on separate
  tables per transaction; replay paths run sequentially to reduce contention.
- All fixture servers use linux/amd64, durable InnoDB and single ordered appliers.
  Destination versions differ. Wall time includes startup/control overhead;
  record server counter deltas and our stage timings, not a claim about CPU time.
- Offline recovery reads the existing SQLite and relay evidence under the writer
  lock. Reports include all pending groups, schemas, row images, composite keys,
  old/new keys, folded expectations and diagnostics. Target comparison stays
  manual; the tool never infers a successful COMMIT from matching rows.
- `mark-applied` and `skip` resolve the first pending group. `retry` requires the
  exact entire remaining GTID set and operator reconciliation of the whole batch.
  All actions require a reason and atomically archive evidence with progress in
  `recovery_audit`. Crashed RUNNING state and unjournaled relay tails are handled.
- The independent reverse demo reuses the same topology and seed/schema setup.
  Its lifecycle test covers start, DML, native comparison, drain and clean resume.
- No target state journal, parallel appliers, dynamic DDL/FK support or full-chain
  changes were introduced. Cloud SQL and physical process-kill-at-COMMIT tests
  remain future qualification.

Operator commands and boundaries: [reverse replication guide](../docs/REVERSE_REPLICATION.md).

Validation on 2026-10-06:

- 317 Swift unit tests pass. Periphery reports no unused code.
- Existing MyISAM DML/DDL sample passes with the same Linux executable used for
  the final reverse run: `artifacts/ddl-suite/20261006T230355Z-35d6af30-auto-autocommit-myisam/`.
- Final native/reverse 10K comparison, rollback, composite-key recovery inspection
  and audited retry/resume pass:
  `artifacts/reverse-suite/20261006T230803Z-6559ff5f-auto-transaction-innodb/`.
  Native: 15.80 seconds (~633 transactions/s); replicator: 65.85 seconds
  (~152 transactions/s), 4.17× wall time for this two-statement workload.
  These results do not replace the different MyISAM benchmark.
- Target counter deltas: both paths record 10,000 commits and 10,000 handler
  updates. Our target records 30,062 prepared executions and 50,167 Questions;
  native records no prepared executions. Global handler/Questions counts also
  include internal and control/status work; do not equate them to user row counts.
- Reverse demo lifecycle passes after adding a catch-up barrier before drain:
  `artifacts/reverse-demo-suite/20261006T230231Z-be3ad459-auto-transaction-innodb/`.
- Qualification artifacts and logs are local/ignored. CI now runs the 100-transaction
  reverse suite, recovery exercise and separate demo lifecycle on the release image.

Demo usability follow-up:

- `reverse-demo-up` now provisions a running idle applier shell; starting/stopping
  replication is separate from container lifetime. Existing sessions can repair
  a missing applier without reseeding or resetting configuration/checkpoints.
- Status distinguishes container state from NOT_STARTED/RUNNING/STOPPED/BLOCKED,
  labels the inherited Compose roles, and summarizes native health without
  printing expected missing-container errors.
- The four-terminal guide is [REVERSE_DEMO_WORKBOOK.md](REVERSE_DEMO_WORKBOOK.md).
- Extended lifecycle qualification passes: idle status, start, comparison, drain,
  missing-container repair with saved state, duplicate-key BLOCKED status, audited
  retry/resume and cleanup. Evidence:
  `artifacts/reverse-demo-suite/20261006T235559Z-ae91b5e7-auto-transaction-innodb/`.


## Shared reverse correctness increment

The next agreed priority is correctness parity for applicable existing fixtures,
including source-side CREATE DATABASE and CREATE TABLE, ahead of more performance
or physical crash-injection work. This supersedes the earlier DDL deferral; it
does not expand foreign-key/cascade support or the downstream MyISAM contract.

- `make reverse-correctness` uses the existing database-creation, DDL compatibility,
  DML matrix and MODIFY/index SQL/expectations. Topology: 5.7 InnoDB source,
  native 5.7 InnoDB reference, external 8.4 InnoDB destination.
- DDL stays a drained, journaled barrier. Explicit engines are checked against
  the target contract. The 8.4 contract restores 5.7 utf8mb4 defaults and removes
  only the obsolete SQL-mode bits that upstream 8.4 replication ignores.
- Normalize version-specific metadata presentation: temporal DEFAULT_GENERATED /
  CURRENT_TIMESTAMP and 8.4's hex-rendered binary defaults. Keep row bytes exact
  and preserve literal/default/ENUM/SET text in the test oracle.
- Treat logged 5.7 conditional temporary-table DROP cleanup as an audited no-op.
  Test a permanent table sharing its name to prove cleanup cannot remove it.
- Restore validated SQL plans for all tables before an InnoDB transaction begins
  after DDL invalidation. No table locks or target journal are introduced.
- Compare rows and schema after each step, check original independent expected
  results, require GTID catch-up and clean intent completion, then reopen saved
  schemas. Extra coverage includes implicit DDL commit and CREATE LIKE → INSERT
  SELECT → multi-table RENAME → DROP.
- Refusal fixtures check engine, FK, event, trigger policy and unsupported types:
  no issued target statement, no checkpoint advance, no following DML, durable
  diagnostics. Source/native acceptance is checked separately.
- Evidence and the explicit scope exclusions are described in
  [REVERSE_REPLICATION.md](../docs/REVERSE_REPLICATION.md#shared-correctness-suite).
  CI runs this suite on the same release executable as the other integration tests.

Additional gaps exposed by shared fixtures:

- MySQL COLUMN_TYPE loses supplementary-plane ENUM/SET labels. Dynamic DDL now
  rejects them before issuing SQL. Positive ENUM coverage uses quoted/BMP Unicode
  labels; supplementary UTF-8 remains covered in ordinary text columns.
- The comparison oracle accounts for partition identifier quoting and view-only
  placeholder rows in information_schema.PARTITIONS, and uses explicit utf8mb4
  client/results encoding. These presentation differences do not normalize data.
- A 5.7 CREATE EVENT exposed incorrect multi-database query-status decoding in
  the pinned Rust dependency. The adapter now bounds and skips each database
  name's NUL terminator, handles the native over-limit sentinel, and rejects
  truncation/duplicate fields. Trigger/event policy diagnostics also take
  precedence over unsupported session metadata.

Qualification investigation note: an early run at
`artifacts/reverse-correctness/20261007T013426Z-1bcae547-auto-transaction-innodb/`
timed out waiting for a source GTID without an applier error. It did not retain
the source binlog, so the cause was not established. Later runs passed that
boundary. Failure artifacts now include the awaited/source boundaries, source
binlog and container logs to make a recurrence diagnosable.

Validation (2026-10-06 local time):

- Complete `reverse-correctness --skip-build`: **64 cases, 384 steps passed**
  against MySQL 5.7.42 source/native and 8.4.8 target. Evidence:
  `artifacts/reverse-correctness/20261007T021905Z-f3ab467a-auto-transaction-innodb/`.
  Final state is STOPPED with zero unfinished row/DDL intents, two audited
  trigger skips and two temporary-cleanup skips. Saved schemas reopen and the
  next source transaction applies successfully.
- `make test`: 328 Swift tests and 8 Rust tests passed.
- `make periphery`: no unused code detected.
- Forward `make integration-smoke` and the selected `matrix-choices` DML suite
  passed on the rebuilt release executable. Evidence:
  `artifacts/ddl-suite/20261007T022010Z-08c71c52-auto-autocommit-myisam/` and
  `artifacts/dml-suite/20261007T022201Z-772b2c76-auto-autocommit-myisam/`.
