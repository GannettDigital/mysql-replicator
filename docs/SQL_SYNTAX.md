# SQL syntax layer

`MySQLSyntax` is a separate Swift build target. It has no dependency on the
replicator, binlog codec, MySQL client, SQLite, or a server. It uses Foundation
for byte buffers. Its unit tests need only Swift and Python for the report tools.

## Boundary

The syntax target contains:

- A byte lexer with original source ranges, SQL quoting modes and explicit
  character decoding callbacks.
- Multibyte character boundary checks for supported client encodings.
- A precedence-based expression parser that produces typed nodes.
- Strict parse errors and limits for statement size, token count and nesting.

`ReplicatorApply` contains the adapter. It applies MySQL stored-name rules,
checks target eligibility, and formats expressions for native metadata comparison.
Native character conversion can occur through the adapter's decoder callback.
The syntax target itself cannot issue SQL.

The AST identifies expression structure. It is not a complete lossless SQL
printer. Keep the original bytes and token ranges for compatibility edits.
Do not reconstruct executable SQL from metadata-normalized expressions.

## Current scope

The target contains the lexer and a growing typed expression grammar. It includes
CASE, predicates, bit operators, intervals, numeric/byte literals and selected
special function syntax.
DDL statement parsing still uses `DDLParser` in the applier. Move those grammar
groups into syntax nodes in later changes. Keep schema prediction and engine
policy outside the syntax target. The target does not yet implement full MySQL syntax. See the
[generated-expression increment](../PLAN/GENERATED_EXPRESSIONS.md) for its native
metadata rules and test evidence.

`SQLExecutableComments` builds a parser view that retains Query SQL byte offsets.
It uses the exact target version, SQL mode and client encoding. The applier
sends the original executable comments to MySQL; it never executes this parser
view. Ordinary comments that the source disabled stay inactive. Native SHOW CREATE
metadata retains its separate lexer mode. See [the contract and tests](../PLAN/EXECUTABLE_COMMENTS.md).
The catalog marks `ddl.executable-comments` as implemented with remaining test
combinations, not as a confirmed unsupported form.

The expression parser handles PIPES_AS_CONCAT and HIGH_NOT_PRECEDENCE.
Other mode-sensitive grammar and statement extraction remain separate work.

## Design rules

Use a byte cursor for lexing and recursive descent for statement structure.
Use precedence-based parsing for expressions. Give syntax nodes typed fields.
Retain source ranges when adding grammar groups. Keep version and SQL-mode
context explicit. Do not use regular expressions as a SQL grammar.

Swift's own [parser](https://github.com/swiftlang/swift-syntax/blob/main/Sources/SwiftParser/Parser.swift)
uses recursive descent, source preservation and nesting limits. These are design
references. `SwiftParser` itself parses Swift and is not a SQL dependency.
Parser-combinator libraries are another valid approach, but they would still
require us to supply and maintain the MySQL grammar.

The replication execution path must consume the complete input and reject a
failed parse. It must not insert missing tokens or silently omit invalid SQL.
Keep metadata spelling rules out of the parser.

## Unit tests and coverage

```sh
make syntax-test
make syntax-coverage
```

The helper creates a small local Swift package under `artifacts/syntax-unit`.
It links to the same source and test directories as the root package. It does not
copy or fork the parser implementation. It has no third-party dependencies.

The coverage command measures only `MySQLSyntaxTests`. It writes an HTML report,
JSON and LCOV under `artifacts/coverage/syntax-unit`. It fails below 95% executable
line coverage. The normal CI unit job runs this command and uploads a separate
`mysql-syntax-unit-coverage` artifact. The target also appears in normal runtime coverage.

For each grammar change, test accepted syntax, rejected syntax, AST structure,
precedence, modes, byte ranges and resource limits. Use native 5.7 and 8.4 results
to establish new expectations. A high line percentage is not proof of complete
MySQL grammar coverage.

## Build cache

Both static and coverage Docker builds have a `sql-syntax` stage. The stage copies
only `Sources/MySQLSyntax` before it compiles that target. Other application
sources enter a later stage. A change to applier code therefore does not invalidate
the parser layer. The application still links the parser into one binary.
