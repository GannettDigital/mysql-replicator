# Source reconnect

The applier automatically reconnects after a transient source transport failure.
The existing target connection and SQLite writer remain owned by the running
process. Safe target reconnect is covered separately in [TARGET_RECONNECT.md](TARGET_RECONNECT.md).
Neither path implements process-crash recovery, failover to a different source
UUID, or replay of uncertain MyISAM writes.

## Restart boundary and ordering

1. Stop and join the old capture/download workers; discard their queued work.
2. Allow an already-journaled target batch to finish. Record only acknowledged
   writes through the normal SQLite completion path. If execution, unlock or
   journaling fails, apply the target reconnect rules or stop with BLOCKED. A concurrent source disconnect must not
   hide a target failure.
3. Require no pending target intents. Discard unjournaled preparation and truncate
   the unapplied relay tail to the last completed group's relay boundary. Keep
   the applied GTID set, file/position, schema state and counters.
4. Wait, then construct a fresh connection, download cache, decoder and transaction
   assembler using SQLite's applied boundary (or the original recorded baseline
   if nothing was applied). Revalidate TLS, source UUID/settings and GTID coverage.

Downloaded/decoded positions are never restart checkpoints. Partial packets and
partial source transactions are read again. Already-applied groups are excluded
by GTID or the saved file/position. `stopAfterTransactions` remains a limit for the
whole invocation, rather than resetting on every reconnect. Normal binlog rotation
uses the existing ROTATE/FDE path and does not require a reconnect. After shutdown
or crash, MySQL can announce the next file without a physical ROTATE in the old
file (`sql/rpl_binlog_sender.cc`, `Binlog_sender::run` in the pinned upstream tree).
This transition requires a complete transaction boundary, the immediately next
numbered file with the same prefix, position 4 and a new validated FDE. A partial
transaction or skipped file is rejected.

## Retry policy

The optional top-level `sourceReconnect` setting in `apply.yaml` defaults to:

```yaml
sourceReconnect:
  enabled: true
  initialDelaySeconds: 1
  maximumDelaySeconds: 30
  maximumAttempts: 0
```

The delay doubles up to the cap. Zero maximum attempts means retry indefinitely;
a positive value limits consecutive retries without applied progress. Applied
progress resets the delay and consecutive budget. Setting `enabled` to false
restores fail-stop behavior for source transport failures.

Retryable failures are explicitly typed at source network boundaries: closed or
reset connections, connection refusal/timeouts, unresolved source host, dump idle
timeout, truncated packets at disconnect, blocking-stream EOF and MySQL's server
shutdown response. Authentication/TLS verification errors, missing/purged history,
source identity/settings mismatch, malformed protocol/events, unsupported data,
local storage failures and unsafe target errors are not retried by either path. An unknown error fails
closed. Nonblocking EOF retains its existing bounded-inspection behavior.

Progress emits `lifecycle: "RECONNECTING"`, `sourceReconnectEnabled`,
`sourceReconnectAttempts` and `sourceReconnectReason`. Attempts count retries
scheduled during this process invocation; the reason is present during backoff.
`source.reconnect_wait` records waiting time. SQLite stays RUNNING during reconnect;
a process crash during this time still requires explicit resolution. Existing
`automaticRecovery: false` means crash/uncertain-target recovery remains disabled.

SIGINT/SIGTERM interrupts backoff and records a clean STOPPED state once no target
work is pending. Cancellation during an active target write retains the existing
conservative rules. Saved BLOCKED/RUNNING states are not automatically reopened.

## Qualification

`make dml-suite ARGS='--positioning both --slice reconnect'` exercises a killed
dump connection, rotation, graceful source shutdown/restart, source SIGKILL/restart,
source loss during a large target group, cancellation during backoff, and changed
source settings on reconnect. It compares source/native/MySQL 5.7 rows and checks
SQLite group counts and transaction limits. Unit tests cover partial framing,
error classification, backoff, discarded relay tails, pending-intent rejection,
and concurrent source/target failures.

Validation for this change:

- 256 Swift tests passed, including relay-capacity accounting after truncation.
- GTID reconnect suite: 5 cases passed on the final runtime.
  Evidence: `artifacts/dml-suite/20261003T072656Z-b5c84bd4-auto-autocommit-myisam/`.
- File-position reconnect suite: 5 cases passed.
  Evidence: `artifacts/dml-suite/20261003T072423Z-99aa8e9e-position-autocommit-myisam/`.
- Existing GTID extended apply suite: 20 cases passed, including partial MyISAM
  effects, killed writers and refusal to resume uncertain state.
  Evidence: `artifacts/dml-suite/20261003T072428Z-5978f6b2-auto-autocommit-myisam/`.
