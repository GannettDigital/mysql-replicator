# Native replication compatibility rules

`Sources/ReplicatorApply/NativeReplicationRules.swift` is the common place for
rules that preserve native replication behavior across source and target
versions. These rules apply automatically. They are separate from the optional
collation and JSON value translations in `compatibility` configuration.

The current implementation selects the source and target release series from
`replicationProfile`. It does not obtain a new source connection during replay.
Both supported series, 5.7 and 8.4, are fully on one side of the current version
boundary. A future 8.0 profile must supply its patch version. Chained-origin
version metadata is not currently used to select these rules.

| Rule | Source condition | Target action |
| --- | --- | --- |
| `source-before-8.0.16-ignores-checks` | Source is older than 8.0.16. | Omit CHECK definitions, as native replication does. |
| CHECK target limit | Source has CHECK support; target is older than 8.0.16. | Stop before target DDL. Do not discard the source constraint. |

## CHECK clauses from MySQL 5.7

MySQL 5.7 parses CHECK clauses but does not create a constraint. Native 8.0 and
8.4 replication workers discard these definitions when they apply old-source
DDL. An ordinary SQL client does not have this behavior.

The syntax target identifies each CHECK clause and its byte range. The applier
removes only the parsed clause and any required comma. It preserves other SQL
bytes, including encoded literals. It does not evaluate an ignored expression.
For a compound ALTER, the target executes the remaining operations.

A check-only ALTER has no target DDL statement. It still uses the normal DDL
journal and completes its GTID. `ddl_details` retains the source SQL and the rule
ID in `context_json.nativeCompatibilityRules`. `ddl_intents.target_sql` is empty
for this case. The current schema ID stays unchanged. Existing failure and
recovery rules still apply to an incomplete journal entry.

No CHECK object is created, including a NOT ENFORCED object. This permits later
column changes that native 5.7 accepts. Enforced 8.4 checks remain a target limit
on the 5.7 profile. This work does not add an 8.4 to 8.4 profile.

## Add another rule

1. Confirm the behavior in the native SQL thread and record the source reference.
2. Add its version or capability decision to `NativeReplicationRules`. Do not
   put version tests in the syntax lexer or expression parser.
3. Implement the transformation at the DDL or value boundary that needs it.
   Preserve source bytes and record the rule when target SQL changes.
4. Test both sides of the version boundary, mixed statements, restart, and
   offline replay. Keep a target limitation distinct from an ignored source
   feature.

See [CHECK evidence and tests](../PLAN/CHECK_CONSTRAINTS.md).
