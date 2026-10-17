# SQL parser evaluation

Status: executable evaluation complete. Do not adopt this ANTLR port unchanged.
Continue with a separate Swift syntax target. See [the results](SQL_PARSER_RESULTS.md).

## Reason

The applier has a lexer and a handwritten Swift parser. It does not parse all
SQL with regular expressions. However, each new DDL group adds grammar and
expression rules that we must maintain.

Use an existing MySQL grammar if it meets our requirements. A lexer alone only
identifies tokens. We need a parser to identify statement and expression structure.

## Candidates

| Candidate | Benefit | Work to assess |
| --- | --- | --- |
| [Oracle-derived ANTLR grammar](https://github.com/antlr/grammars-v4/tree/master/sql/mysql/Oracle) | MySQL-specific rules include DDL, routines, partitions and expressions. The grammar has server-version predicates. | The current grammar states MySQL 8.0 and later. Prove 5.7 coverage separately. Check the exact 8.4 revision, SQL modes, support classes and source offsets. |
| [Apache sqlparser-rs](https://github.com/apache/datafusion-sqlparser-rs) | Rust integration fits the existing Rust library. It has a MySQL dialect and an abstract syntax tree. | Test MySQL-specific DDL and routines. Its documentation says syntax parsing does not validate semantics. AST source spans are incomplete. |
| [TiDB parser](https://github.com/pingcap/tidb/tree/master/pkg/parser) | MySQL-focused parser generated from a Yacc grammar. It has an abstract syntax tree. | Test routines, version differences and exact source retention. Assess the extra Go runtime and build integration. |

Start with Oracle's grammar for syntax coverage. Use sqlparser-rs as the second
candidate because it fits our build. This is an evaluation order, not a decision
to add either dependency.

The Oracle-derived grammar README lists BSD-3-Clause. The two other projects list
Apache-2.0. Check the licenses of the exact pinned files and runtimes before use.
ANTLR supports [Swift and C++ targets](https://github.com/antlr/antlr4/blob/master/doc/targets.md).
Its Java tool generates the parser during development or build. A generated Swift
or C++ parser does not require a Java runtime in the deployed binary. The MySQL
grammar also needs target-specific support code; Swift support in ANTLR alone
does not prove that this grammar is ready for Swift.

## Required design

Keep SQL parsing separate from replication policy, schema prediction and durable
state. Convert a parse tree into the existing DDL action model through an adapter.
Keep the original SQL bytes. Apply compatibility changes only to identified
source ranges. Do not regenerate every statement from a generic SQL formatter.

Parse with the source version and SQL mode. Then check the target version and
engine. Handle non-UTF-8 input with an explicit mapping back to original bytes.
Preserve executable comments and literal bytes. Reject parse recovery results
that silently omit or insert syntax.

A parser does not reproduce MySQL's metadata formatting or all semantic rules.
Keep native metadata checks separate. In particular, a successful parse does not
prove that a generated expression will match INFORMATION_SCHEMA output.

Row events already provide structured DML data. This change concerns SQL in
query events and schema handling. It must not add SQL parsing to each row event.

## Evaluation steps

1. Pin candidate versions in a separate evaluation build.
2. Extract the current DDL fixtures and unit cases into a common SQL corpus.
3. Add native-valid and native-invalid cases from the 5.7 and 8.4 source trees.
   Include compound ALTER, routines, partition clauses, generated expressions,
   version comments, quoting modes and non-UTF-8 SQL.
4. Record acceptance, errors and extracted actions for each case. Compare source
   ranges with the original bytes. Parser acceptance alone is not a pass.
5. Test the adapter against the existing schema, journal and restart assertions.
6. Build the Linux static binary and the macOS binary. Measure build cost, binary
   size, parse time and memory use on normal and deeply nested statements.
7. Select a parser only after this comparison. Replace one DDL group at a time.
   Keep the existing assertions during the change.

## Current test evidence

The table-charset and charset-conversion cases passed all four profiles in
`artifacts/lab/20261015T013707Z-6f30c00e`.

The compound-charset run failed across versions. MySQL 5.7 accepts
`ALTER TABLE t DEFAULT CHARSET=DEFAULT`; the observed 8.4 target rejected it.
This needs a version-aware compatibility change, regardless of parser choice.
Evidence: `artifacts/lab/20261015T015448Z-fbb46c15`.

The separate generated-expression evaluation also failed with a target
after-schema mismatch. Its evidence is in the `beta6-ddl-next` worktree at
`artifacts/lab/20261015T020003Z-36f462f9`. The cause still needs comparison of
the saved expected schema with the target schema. Do not treat the new expression
grammar as qualified. Pause further grammar expansion while we assess reuse.
