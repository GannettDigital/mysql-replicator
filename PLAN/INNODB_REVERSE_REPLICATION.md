# MySQL 5.7 → 8.4 InnoDB replication

Status: implementation started. The existing qualified 8.4 → 5.7 MyISAM profile
must retain its behavior. This document records the agreed scope and acceptance
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
- Dynamic DDL and foreign keys remain explicitly blocked for the reverse
  profile. These and steps 4–7 are pending; milestone 1 is not fully complete.
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
