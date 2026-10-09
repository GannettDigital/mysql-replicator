While we will be planning to test actual binlkogs in replay mode,
it would be more efficent to look at the full range of issues discovered after such test.

Possibly, to do this we need a similar functionality to MySQL skip error - i.e. if we bump into a specific issue that we cannot handle,
it would be best to put that error into a skip error list, and allow replication to keep going (possibly while logging skipped GTIDs into the sqlit if config flag is set)
and allowing us to discover more issues.

Possibly, error conditions should have unique ids  , intg (could be good for similar feel to mysql) or some other way of uniquely identify specific error.

## Agreed implementation, 2026-10-09

- Use stable named error codes and whole-GTID skip decisions, never message matching or individual-row skips.
- Per-GTID audit must be optional. `skipErrors.recordSkippedTransactions: false` retains only aggregate skip counts and the normal durable GTID/position checkpoint. Operators must plan consistency checks and recovery using evidence maintained elsewhere.
- Avoid hidden per-skip growth in the normal journal: remove completed skipped groups/intents and update the latest covering snapshot atomically with progress and counters. With auditing enabled, retain a separate diagnostic row subject to normal history retention.
- First increment: replay only, explicit allowlist, selected DDL and DML planning errors before writes, and MySQL 1062 in InnoDB after confirmed whole-transaction rollback. Batches preserve source order and committed/skipped prefixes. MyISAM SQL errors, issued DDL, uncertain commits and unconfirmed rollback still block.
- Aggregate counts appear in progress and survive clean resume. Detailed audit includes the GTID, source coordinates, stable code, MySQL number/SQLSTATE when present, execution outcome, available SQL and table identities.
- Follow-up: decoder/discovery continuation at structurally validated GTID boundaries, broader deliberately classified errors, and better correlation of cascading errors after skipped DDL. Corrupt framing/checksums and missing history remain fatal.

Configuration and current code list: [offline replay](../docs/OFFLINE_REPLAY.md#continue-past-selected-errors-during-replay-testing).
Shared integration scenario: `offline-skip-errors`, run on both profiles. Unit fault checks cover checkpoint rollback, uncertain execution, mixed batches and bounded unaudited history.
