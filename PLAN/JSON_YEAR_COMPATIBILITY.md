# YEAR values inside JSON: MySQL 5.7 to 8.4

Status: explicit compatibility rule implemented; disabled by default.
Binary-value transport gaps remain separate open work.

## Scope

This issue affects a YEAR SQL value embedded inside JSON by a SQL expression.
It does not affect ordinary JSON such as `{"year":2026}` or a normal YEAR column.

```sql
CREATE TABLE years (y YEAR);
INSERT INTO years VALUES (2026);
SELECT JSON_TYPE(JSON_EXTRACT(JSON_ARRAY(y),'$[0]')) FROM years;
```

Direct probes on MySQL 5.7.42 and 8.4.8 show different results:

| Server | Internal JSON value | JSON_TYPE |
| --- | --- | --- |
| 5.7 | YEAR, opaque type 13 | OPAQUE |
| 8.4 | Unsigned integer containing 2026 | UNSIGNED INTEGER |

MySQL 5.7 can display the typed value as `base64:type13:MjAyNg==`. MySQL 8.4's
YEAR SQL constructor produces the number instead. This is a constructor change;
it does not mean that MySQL 8.4 lacks the YEAR column type or cannot retain
opaque type 13 in its internal JSON format.

## Configuration

For `mysql57-to-mysql84-innodb`, enable this rule before state initialization:

```yaml
compatibility:
  jsonYearToInteger: true
```

The default is `false`. The other three profiles reject `true`. With the rule
set to `false`, the applier stops if the target cannot preserve the source type.
The setting applies to `run` and `replay`.

With the rule set to `true`, opaque type 13 becomes an unsigned JSON integer.
The rule accepts zero and years from 1901 through 2155. It rejects malformed
YEAR bytes. It changes JSON_TYPE from OPAQUE to UNSIGNED INTEGER. JSON text and
comparison results can change. Normal YEAR columns and ordinary JSON numbers
are unchanged. Binary values and other opaque types are not converted.

The conversion applies to root values, object members and array elements.
Target writes and UPDATE/DELETE before-image checks use the same conversion.
Relay files and recovery row images retain the source type and bytes. Recovery
reports include the compatibility policy. Apply that policy when comparing
source evidence with target values. No automatic recovery is added.

SQLite saves the policy. A restart or recovery command with a different policy
fails. Existing state without this option retains strict behavior. To enable
the rule, prepare a new baseline and initialize new state. If the baseline has
YEAR values inside JSON, convert those values with the same rule.

## Tests

The `json-year-compatibility` correctness case is specific to the 5.7 to 8.4
profile. It checks strict refusal, zero, boundary years, root and nested values,
policy changes, restart, UPDATE/DELETE and offline replay. The source and native
5.7 replica must retain the opaque type. The target must match its own native
8.4 YEAR-to-JSON constructor. Unit tests cover malformed bytes, escaped JSON
paths, unchanged source evidence and policy checks in recovery.

MySQL 5.7 does not generate partial JSON updates. This policy does not enable
partial updates for that source version.

## Evidence

See [the JSON transport investigation](JSON_TRANSPORT_INVESTIGATION.md) for
native source revisions, constructor probes and LOAD DATA results. Those probes
establish the version difference. See [JSON support](JSON_SUPPORT.md) for current
tested paths and limits.


Local verification on 2026-10-14:

- 491 selected apply, codec, configuration and lab unit tests passed.
- The final lab assertion changes passed 96 lab unit tests.
- `json-year-compatibility` passed on MySQL 5.7.42 to 8.4.8.
- The live and replay runs each applied four transactions. Replay stopped at
  end of input with the same GTID checkpoint. Its source endpoint was unreachable.
- Evidence: `artifacts/lab/20261014T222611Z-d0b6ff01/result.json`.
- Image input digest: `77d04aa32c251c200b504758e36f19ce604207c2f1572010263210525b676876`.

These results qualify this selected rule. They are not a full release test run.
