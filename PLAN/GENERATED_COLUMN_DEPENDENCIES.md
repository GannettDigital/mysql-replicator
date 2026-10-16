# Generated-column dependency changes

Branch: `beta/6/56-generated-column-dependencies`, based on branch 55.

## Native rules

Probes on MySQL 5.7.42 and 8.4.8, with InnoDB and MyISAM, confirmed:

- CHANGE can rename a base column if the same ALTER replaces or drops each
  generated expression that uses its old name. Clause order does not matter.
- CHANGE can rename a generated column if the same ALTER updates its dependents.
- A STORED generated column can become an ordinary column. Existing values remain.
- An ordinary column can become a STORED generated column. MySQL recalculates it.
- Both versions reject a rename that leaves an unchanged expression using the
  old column. 5.7 reported 1054; 8.4 reported 3108 in the probe.
- 5.7 rejects DROP of a referenced base column with error 3108, even when the
  same ALTER drops or replaces the dependent generated column. Remove the
  dependency in a separate ALTER first. 8.4 accepts the combined form.

The last rule is a target-version limit. An 8.4 source can record SQL that the
5.7 target cannot execute. The applier reports the affected base and generated
columns before it sends target SQL. It does not split a source DDL statement
into multiple target statements.

Native references are MySQL 5.7 `sql/sql_table.cc`,
`mysql_prepare_alter_table` near line 8027, and MySQL 8.4
`check_if_field_used_by_generated_column_or_default` near line 14700.
The 8.4 function excludes expressions removed or changed in the full ALTER.

## Implementation

A dependency helper examines original generated expressions and all ALTER actions.
For a rename, an explicitly changed or dropped generated column no longer blocks
that rename. The target still validates its new expression. For a DROP, the
central `NativeReplicationRules` value selects the original-dependency check
required by 5.7.

Identifier tokens identify references. A string such as '`a`' is not a reference
to column `a`. Identifier comparison follows the existing native name rules.
Partition dependency checks also use identifiers. This change does not rewrite
partition expressions or add implicit generated-expression rewriting.

The normal DDL path records complete old and new schemas before SQL. The target
executes the source statement. Following row events use the new generated-column
flags: computed columns are checked but not written. Columns converted to ordinary
storage become writable. No new SQLite format or replay state is required.

## Verification

The shared `ddl-compat-generated-dependencies` case applies to all four profiles.
It checks stored and virtual expression chains, both clause orders, dependent
column removal, text literals, stored/ordinary conversion, INSERT, UPDATE,
DELETE, saved-state restart and offline replay.

The selected apply and lab run passed 501 unit tests. After the harness comparison
fix below, all eight focused dependency/comparison tests passed. Periphery passed.
The isolated syntax suite was not run: this increment does not change MySQLSyntax
or its build setup.

All four selected integration runs passed 28 steps each, including restart and
offline replay:

| Profile | Result file under `artifacts/lab/` |
| --- | --- |
| 8.4 → 5.7 MyISAM | `20261016T153215Z-120117c8/result.json` |
| 5.7 → 8.4 InnoDB | `20261016T153407Z-4ca59373/result.json` |
| 5.7 → 5.7 MyISAM | `20261016T153619Z-429463cd/result.json` |
| 5.7 → 5.7 InnoDB | `20261016T153712Z-697e4dad/result.json` |

All four used binary SHA-256
`d832845bd03e835b81e0d6cc416b27aaec9210d2649c5fe6d809168ab87f0838`.
These were selected cases, not the full correctness matrix.

The first forward and reverse runs stopped in the harness metadata comparison:
`artifacts/lab/20261016T152705Z-e7ee0103/result.json` and
`artifacts/lab/20261016T152854Z-0e423357/result.json`. The applier accepted CREATE.
No BLOCKED state or support bundle was produced. The saved comparison shows
8.4's charset prefix and quote escaping for the fixture's literal '`a`'; 5.7
prints the same literal without that wrapper. The harness now maps this exact
metadata spelling. Unit tests retain other literals unchanged. Raw snapshots
and row-value comparisons remain independent of the production parser.

## Remaining limits

The selected dependency changes do not complete all expression syntax, SQL-mode
combinations or cross-version evaluation rules. Native restrictions on VIRTUAL
and STORED conversion remain. Branch 57 adds [functional-index and expression-default dependency
changes](COLUMN_EXPRESSION_DEPENDENCIES.md). The broader expression catalog stays partial.
