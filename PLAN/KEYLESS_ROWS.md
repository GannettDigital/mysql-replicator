# Tables without a usable unique key

Branch: `beta/6/46-keyless-row-matching`, based on branch 45.

## Native behavior

MySQL row apply seeks a primary key, then a nonnullable unique key. It can use
other indexes or a table scan when those keys are absent. It compares row
contents and changes one matching row per row event. Identical rows are valid.

The local 5.7 source describes these rules in `sql/log_event.cc`:
`search_key_in_table`, `decide_row_lookup_algorithm_and_key`, `record_compare`,
and `do_table_scan_and_update`. `record_compare` checks NULL flags and binary
field contents. It does not use a case-insensitive text comparison to decide
that two row images are identical.

## Apply behavior

Keep the primary-key and eligible unique-key paths. Otherwise save a `fullRow`
identity with all base columns, in column order. Its index name is empty. Do
not report these columns as a unique key or declared primary key.

Use NULL-safe predicates over the full base image. Emit `IS NULL` for NULL
fields. A local MySQL 8.4 probe showed that prepared nullable UNIQUE equality
with a NULL parameter could miss later matching rows. The literal `IS NULL`
form found them. Keep this case in the reverse-profile regression. Compare text
and binary data by bytes. Compare DECIMAL with an explicit DECIMAL cast to
avoid DOUBLE rounding. Compare ENUM and SET ordinals and BIT values
numerically. Use the existing FLOAT parameter and range handling. Preserve the
sign of zero with an additional ATAN2 predicate. Both pinned MySQL versions
retain this sign. JSON predicates check container types and sizes, member
paths, scalar types and values. This avoids treating a JSON string and a JSON
typed scalar as the same value.

Read the matching row and check its complete before-image. UPDATE and DELETE
use `LIMIT 1`. Check the affected-row count. A changed full-row image does not
need the unique-key collision precheck; a duplicate result is valid. Target
constraints still apply. Target-generated values retain their post-write check.

A nullable, prefix or nonunique index is not a unique row identity. Tables with
such indexes use full-row matching when no better key exists. The target may
scan the table for each row event. This path has no new performance claim.
Independent target writes remain outside the support contract. Tables still
need at least one base column. Native promoted-key metadata for unusual unique
indexes, such as generated or full-width BLOB keys, needs separate
qualification.

## Durable records and recovery

Save the selected mode and base columns in the existing schema JSON. Existing
row intents retain their schema version, source event offset, row ordinal and
raw relay event. No SQLite table migration is needed.

For full-row matching, recovery leaves `beforeKey` and `afterKey` absent. It
retains every operation in `rows` and `fullRowChanges`, including repeated
identical images. It excludes these rows from key-based `expectations`.

An image does not identify one physical copy. These records show the changes
requested by the source. They do not prove a COMMIT or the total number of
matching rows in the target. A DBA must reconcile the complete pending batch
and row counts before retry or acceptance. The preparation queue can retain
later groups that were not issued. Include those groups in the review and retry
decision. A connection failure does not trigger an automatic retry of an
uncertain write.

The existing engine rules remain in effect. InnoDB has audited recovery
actions. MyISAM retains blocked state and possible partial writes; it has no
audited retry command. A controlled MyISAM test restores the baseline and uses
a new state directory. That is a test repair, not automatic recovery.

## Verification

The shared `ddl-compat-keyless-rows` case covers duplicate rows, NULLs,
case/padding-distinct text, BLOBs, typed JSON, generated columns, key addition
and removal, DECIMAL, FLOAT, ENUM, SET, BIT, spatial bytes and latin1 text. It
checks live apply, clean restart and offline stop/resume with an unreachable
source. At the replay stop point, it removes one target duplicate and checks
partial MyISAM writes or InnoDB rollback, blocked restart, retained operations,
and repair followed by replay.

The first run found a harness ordering error: identical normalized row sets had
different server-side order. The harness now compares sorted normalized records
and retains duplicate lines. A later run reached the existing inline `ADD
column ... PRIMARY KEY` parser refusal. The key-change case now adds a primary
key to an existing unique-valued column. Adding an AUTO_INCREMENT column
without a default reached another existing parser restriction. Both DDL forms
remain in the broader plan. The original failure artifacts and support bundle
remain available.

The InnoDB replay tests also check the preparation queue. The queue can save
later transactions before the current transaction fails. The fixture checks the
active group's two rows, inspects all pending groups, and retries the complete
pending GTID set. After recovery, it restores the live configuration before the
continuous writer restarts.

All four selected runs passed 32 shared steps. The final unit run passed 472
apply/lab tests. Periphery passed. MySQLSyntax did not change, so its separate
syntax suite was not run.

| Profile | Lab fixture run | Build inputs |
| --- | --- | --- |
| 8.4 → 5.7 MyISAM | `20261016T013149Z-c8fb38ae` | A |
| 5.7 → 5.7 MyISAM | `20261016T013546Z-f8df6369` | A |
| 5.7 → 8.4 InnoDB | `20261016T014954Z-e570f607` | B |
| 5.7 → 5.7 InnoDB | `20261016T015044Z-83ccbf06` | B |

- Build-input digest A: `ebc324581fd6429ab1c89922cd763b396c1d4dba86fd991cdf41f2f692dfaa99`.
- Build-input digest B: `35c6c60115049bd9ba8ed61c273ccb031c47092d326719d69316d7703613905d`.
- All four runtime records have binary SHA-256: `4137e5567ff5a9c883c315ce74969429d970927002406140be75e22c1bef2330`.

Build B changes the harness recovery assertion and config restoration. It also
updates the support catalog. The apply source is unchanged from build A. The
two passed MyISAM runs were not repeated for these harness-only changes.
Both final InnoDB runs retained two pending groups with two and one operations.
They verified rollback, inspected duplicate images, retried the complete pending
set, completed replay, and restarted the original live writer.

Full release qualification and the remaining value boundary matrix stay open.
