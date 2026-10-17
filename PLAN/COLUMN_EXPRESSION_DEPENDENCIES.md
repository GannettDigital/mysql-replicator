# Functional-index and expression-default dependencies

Branch: `beta/6/57-expression-dependencies`, based on branch 56.

## Native rules

MySQL 8.4 checks all ALTER clauses before it rejects a column dependency.
A dependent functional index or default expression can be removed or replaced
in the same statement that renames or drops its referenced column. Clause order
does not matter. A retained expression must remain valid.

Direct probes on MySQL 8.4.8 InnoDB confirmed these forms:

| Operation | Native result |
| --- | --- |
| Rename a column; retain its functional index | Error 3837 |
| Rename a column and drop its functional index, in either order | Accepted |
| Drop a column and its functional index | Accepted |
| Rename a column; replace its functional index with an expression using the new name | Accepted |
| Rename the index and its referenced column without changing the expression | Error 1054 |
| Rename or drop a column; retain a default expression that uses it | Error 3766 |
| Rename a column; SET or DROP the dependent default in the same ALTER | Accepted |
| Drop a column; change its dependent default to a literal | Accepted |
| Rename a column; MODIFY the dependent column with a new default expression | Accepted |
| Drop both the referenced column and the column with the default expression | Accepted |
| Replace the default but retain a reference to the removed column name | Error 1054 |

The upstream reference is MySQL 8.4 `sql/sql_table.cc`,
`check_if_field_used_by_generated_column_or_default`, near line 14700.
It excludes dropped columns, changed defaults and explicitly modified columns
from the original dependency check. Functional indexes use hidden generated
columns. Later native checks validate the replacement expressions.

MySQL 5.7 does not support functional indexes or expression defaults. The existing
target-version checks still apply. This change does not translate these features
for a 5.7 target.

## Implementation

`ColumnExpressionDependencies` extends the previous generated-column helper.
It checks original expressions against the complete set of ALTER actions.
Explicit index removal or replacement removes the old index dependency.
SET DEFAULT, DROP DEFAULT, MODIFY, CHANGE or DROP can remove an old default
dependency. Index renaming alone does not remove an expression dependency.

A retained dependency produces an error with the referenced column and the
index or dependent column name. This check runs before target SQL. It does not
rewrite expressions or split source DDL into separate target statements.
The target validates new expressions.

Schema prediction still records the full before and after schemas in SQLite.
Normal DDL verification checks the actual result. No durable-state format change
is required.

## Verification

The new `expression-target84-dependencies` case uses the 5.7 to 8.4 InnoDB
profile. It starts with matching visible columns. The target has functional
indexes and expression defaults; the source and native 5.7 replica have ordinary
indexes and defaults. This is an existing-target-schema test. It does not claim
that a 5.7 source can emit 8.4 expression syntax.

The case checks:

- Unchanged index and default dependencies stop apply without a target change
  or checkpoint advance.
- Compound ALTER removes dependencies in both clause orders.
- A replacement ordinary index uses the new column name.
- Row values match the source and native replica after each operation.
- Retained functional indexes still answer indexed queries.
- Target metadata loses only the intended functional indexes and defaults.
- Each live transaction resumes saved state in a new process.
- Offline replay resumes after the first ALTER with an unreachable source address.
- Following INSERT, UPDATE and DELETE use the changed schema.

The unit tests also cover expression replacement, case-insensitive names,
multiple dependencies and string literals that contain column-like text.
The first unit run found a test-helper error: single-column DROP uses a separate
parsed statement form. The helper now converts that form to its ALTER action.
All 501 existing apply/lab tests passed in that run. The subsequent focused run
passed all 13 expression tests, including the four new tests.

Both selected integration cases passed on the 5.7 to 8.4 InnoDB profile:
`expression-target84-dependencies` and the existing `json-target84-schema` case.
The new case stopped before target SQL for both expected dependency errors.
Both produced support bundles. Live apply and resumed offline replay reached
the same GTID after all seven transactions.

Result: `artifacts/lab/20261016T154914Z-444adef1/result.json`.
Binary SHA-256:
`01f321eeb115d6d703452541546d64583158c766d8e8b163e7d8b051cc07fed2`.
Periphery and the DDL catalog structure check passed. These were selected cases,
not the full correctness matrix. The isolated syntax suite was not run because
MySQLSyntax and its build setup did not change.

## Remaining scope

The expression catalog remains partial. These tests do not qualify every function,
SQL mode, placement rule or ALTER combination. Native cross-version and engine
limits remain separate from tool gaps. See [the complete support plan](COMPLETE_MYSQL_SUPPORT.md).
