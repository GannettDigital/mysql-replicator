# Beta.6 initial CI failures

Snapshot: 2026-10-16. PRs 55–65 are still running. This is not a complete result
for the stack. No jobs were cancelled or rerun during this review.

## Fixed locally

| First PR | Failure | Correction | Check |
| --- | --- | --- | --- |
| 55 | DDL evidence test expects 730 obligations; the branch has 728 | Move the existing next-branch assertion correction into the first affected branch | Six DDL evidence tests passed |
| 56 | Periphery reports the unused string-array comparison overload | Add tests for exact Unicode bytes, order, length and empty values; later branches use the overload | Nine identifier tests passed |
| 64, also 65 | The pinned Swift image has no `make` | Run `swift format lint --strict --parallel --recursive Sources tests` directly | The exact command passed in the pinned Linux container |

Fix commits: `70b7bd0`, `9211ade`, `a0237f8`. Merge commits carry these fixes
through the local stack without rewriting the published history. Nothing was
pushed. The push helper still accepts the updated descendants.

Periphery reported no unused code after the new tests. Its reused local index
also reported duplicate declarations from earlier branch builds. Treat the next
clean CI Periphery run as the final check, not this reused-index result.

## Integration failures still open

### SQL script framing

PR 55 run `38981724485` has two direct fixture errors:

- Job `117246385853`, forward failure sequence: a `DELIMITER $$` client command
  reaches the server as SQL during the trigger setup.
- Job `117246385763`, native DDL sequence: the seed ends in a semicolon and the
  caller adds another semicolon. The server rejects the resulting multi-statement
  request before the expected source rejection checks run.

`NativeHarness.sqlCommand` now preserves UTF-8 through stdin. It also assigns one
custom delimiter to the entire input. Existing callers pass both individual
statements and mysql client scripts. These need distinct framing. Keep byte-safe
stdin. Let the mysql client process scripts, including their delimiter commands.
Keep stored routine bodies intact when the input is one SQL statement. Do not
solve the failures by weakening expected-error assertions or reverting to argv
transport, which can change Unicode spelling on macOS.

The forward-failure bundle contains the earlier, expected trigger/event policy
rejections. The later malformed fixture command fails before it reaches the
applier, so there is no support bundle for that setup error.

### Obsolete DDL skip case

PR 60 run `38981745802`, job `117246844523`, fails `offline-skip-errors` on the
5.7-to-5.7 InnoDB profile. The test expects `ddl.unsupported_alter` for
`ALTER TABLE skip_poc.items ENABLE KEYS`. Beta.6 supports that statement.
The saved output has no DDL skip. It has `mysql.1062: 1` before and after restart.
Transactions and applied rows match the other assertions.

Replace the obsolete DDL refusal with a deterministic failure. Keep both DDL and
DML skip coverage, audited and counts-only variants, restart checks, and the
MyISAM partial-write refusal. Do not merely remove the DDL counter assertion.
Check the shared live-mode case too; it uses the same test code.

### Demo control event

PR 55 job `117246385867` fails `demo-success`. Its support bundle reports
`noncanonical or unsupported SQL control statement` at `binlog.000003:2404`.
This may also follow from whole-script framing, but the saved bundle does not
contain the rejected event's SQL. The earlier completed relay data cannot prove
that cause. Inspect or reproduce the source event before changing the assembler.
Do not relax transaction-boundary checks based only on this error message.

## Saved evidence

Downloaded artifacts are under `artifacts/ci-failures/` in the beta.6 release
worktree: `pr55-offline`, `pr55-native`, `pr55-demo`, and `pr60-offline`.
Read their `result.json` files, support-bundle `failure.json` and `bundle.json`,
and the replay skip/resume NDJSON reports before rerunning a failed case.
No full-suite rerun or production apply change was made during this review.
