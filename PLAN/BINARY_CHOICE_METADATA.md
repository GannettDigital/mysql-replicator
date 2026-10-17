# Binary ENUM and SET labels

Status: implementation on `beta/6/11-binary-choice-literals`.
Focused live and bootstrap checks passed on all eligible profiles.

## Native behavior

MySQL 5.7.42 accepts binary ENUM and SET labels that are not UTF-8. Its
INFORMATION_SCHEMA output can truncate COLUMN_TYPE at the first invalid byte.
A native probe for `ENUM(0xFF,0x61) CHARACTER SET binary` reported only `enum('`.
The native field and a temporary CTAS copy retained both labels.

MySQL 8.4.8 reports binary ENUM/SET columns with NULL charset and collation
metadata. It can show binary defaults as hex literals. The applier normalizes
these fields to the explicit `binary` charset and collation.

MySQL 8.4.8 rejects this exact SET definition with native error 3507:

```sql
CREATE TABLE t(s SET(X'ff',X'61') CHARACTER SET binary DEFAULT X'ff2c61');
```

This is a source restriction for the forward profile and a target-version limit
for the reverse profile. The 5.7-to-5.7 profiles can use it. The applier does not
substitute labels or rewrite this schema to avoid the native error.

The pinned 8.4 `Field_enum::sql_type` has a hex fallback for invalid UTF-8.
`Field_set::sql_type` has no equivalent fallback. `fill_dd_columns_from_create_fields`
in `sql/dd/dd_table.cc` stores the displayed type in `column_type_utf8`.

## Implementation

DDL accepts hex and bit string literals in ENUM/SET labels and defaults.
They remain byte strings. Numeric ENUM defaults remain separate from byte
literals. Other column families still need separate binary-default support.

Schema discovery uses a temporary native column. For binary columns, it checks
the valid ordinal or bit range before reading the labels. This gets the count
without trusting truncated metadata. The search has at most 16 ENUM iterations
or 6 SET iterations. Each iteration updates and reads one temporary row.
The existing schema cache keeps this work out of the row apply loop.

Discovery uses a scoped non-strict SQL mode. This permits a copy of duplicate
labels that native non-strict CREATE can retain. The code restores the previous
mode and removes the temporary table. A cleanup or restore failure closes the
connection and blocks apply.

SQLite schemas retain binary label and default bytes. Row values remain ENUM
ordinals or SET masks. Replay and recovery use the same schemas and codec paths.

## Test comparison

The test harness reads raw SHOW CREATE bytes for binary choices. A separate
parser compares 5.7 raw quoted bytes with 8.4 hex literals. It does not use the
applier's metadata parser or treat truncated INFORMATION_SCHEMA text as complete.
Row assertions also check exact bytes, masks and defaults on all three servers.

`matrix-binarychoices` and its bootstrap form apply to all profiles.
`matrix-legacybinaryset` and its bootstrap form apply only to the two
5.7-to-5.7 profiles. Their explicit exclusions state native error 3507.

## Remaining checks

Complete byte-boundary, non-strict duplicate-label, offline and uncertain-write
qualification. Native 8.4 hex rendering uses `%x` per byte, without fixed-width
padding. Inspect that behavior before using SHOW CREATE as an oracle for labels
that combine invalid UTF-8 with bytes below 0x10. This is a known test-oracle risk,
not proof that native row replication rejects those labels.

## Focused evidence

All 105 selected unit tests passed. They include binary labels/defaults, the
independent SHOW CREATE parser, and pending-row recovery from SQLite and relay
files. Catalog validation passed with 45 unqualified support requirements.

The shared binary choice case passed in live and bootstrap mode on all four
profiles. The legacy binary SET case passed in both modes on both 5.7-to-5.7
profiles. Each run also reopened saved schemas and applied another transaction.
See [beta.6](beta.6.md) for the run IDs and retained native-failure evidence.
