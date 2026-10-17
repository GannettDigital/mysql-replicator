# Oracle ANTLR parser evaluation

## Decision

Do not add the evaluated parser to the product. The architecture works, and its
speed is sufficient for DDL. However, the available port needs MySQL compatibility
fixes. Its license provenance also needs resolution. Keep the evaluation tools
as a reference. Continue with our Swift parser in a separate build target.

This result does not mean that third-party parsers are unsuitable in general.
It applies to the pinned Oracle-derived C++ port tested here.

## Inputs and scope

- ANTLR generator and C++ runtime: 4.13.2.
- `antlr/grammars-v4`: `89fd36482e8cb68a4e55df021a8adbc7541b52f2`.
- Current Oracle source inspected: `mysql/mysql-shell-plugins` at
  `b327bda586a2fa9aa6596315a1e518f891fd2bc2`.
- Native servers: MySQL 5.7.42 and 8.4.8 in disposable local containers.
- 64 curated cases at two version settings: 128 parser checks.
- 126 native checks. The two multiple-statement checks test our parser entry
  contract and are not native syntax rejection tests.
- 642 distinct Swift string literals, each tested at two version settings.
  This scan includes negative cases, descriptions, partial strings and SQL
  batches. Its acceptance count is not a MySQL support percentage.

Generated sources, downloads and full evidence are under
`artifacts/sql-parser-evaluation/`. The app dependency graph is unchanged by
this evaluation.

## Results

| Check | Result |
| --- | --- |
| Unmodified grammar and support code | 114 of 128 curated expectations matched |
| Two local C++ lexer support fixes | 117 of 128 curated expectations matched |
| Native syntax classification | All 126 expectations matched native error classification |
| Native execution | 91 statements succeeded; remaining cases include syntax and semantic rejections |
| macOS versus static Linux | Same acceptance, errors, selected ranges and mode trees for all 1,412 inputs |
| Source ranges | Token ranges and selected syntax ranges matched original UTF-8 bytes |
| Non-UTF-8 boundary | Latin1 and Shift-JIS examples passed after explicit conversion and byte-offset mapping |
| Structured extraction | Qualified names, rename pairs, ordered ALTER actions and generated expressions passed selected assertions |
| SQL modes | ANSI_QUOTES, NO_BACKSLASH_ESCAPES, PIPES_AS_CONCAT and HIGH_NOT_PRECEDENCE passed selected checks |

The local support fixes initialize a lexer state flag and make the executable
comment predicate call the existing version check. The latter fixes three
curated outcomes. The unmodified results remain available for comparison.

The remaining 11 differences are:

| Case | Native behavior | Parser behavior |
| --- | --- | --- |
| `X'00ff'`, `X''`, `B'01010101'` | Both servers accept the tested defaults | Both version settings reject them |
| `DEFAULT CHARSET=DEFAULT`, `COLLATE DEFAULT`, `CONVERT TO CHARACTER SET DEFAULT` | 5.7 accepts these forms | 5.7 setting rejects them |
| Invisible index and SRID column attribute | 5.7 rejects these forms | 5.7 setting accepts them |

The fixture scan also found `ENGINE=DEFAULT`. Native 5.7 and 8.4 both rejected
the tested `CREATE TABLE` form. It is not a parser defect in this comparison.

These tests classify native error 1064 as a syntax rejection. Other native
errors do not prove execution support. The parser does not validate metadata,
engine rules, foreign key relationships or replication safety.

## Build and speed

The first clean macOS build generated the parser in 1.16 seconds and compiled
and linked it in 25.69 seconds. The test executable was 4.68 MB. This includes
the C++ runtime and the test driver; it is not the product size increase.

The static x86_64 Linux executable was 9.47 MB before stripping. It ran in an
Ubuntu 16.04 container. It links the existing Swift musl SDK's libc++, libc++abi
and libunwind. No Java runtime is required. The final Linux build was incremental;
its 13.65-second time is not a clean-build measurement.

On this macOS host, 10,000 successful parses from 95 curated version/case pairs
took 0.60 seconds inside the measured parse operation. Total process work,
including input and JSON output, took about 0.72 seconds. Median parse time was
0.020 ms; p99 was 0.774 ms. Maximum resident memory was about 19.7 MB.
This is a DDL parser microbenchmark, not a replication benchmark.

Separate tests accepted expressions nested to 32, 128, 512 and 1,024 levels.
These examples do not prove bounded memory or stack safety for arbitrary SQL.
Any production parser still needs explicit input, token and nesting limits.

## License evidence

The [mirror README](https://github.com/antlr/grammars-v4/blob/89fd36482e8cb68a4e55df021a8adbc7541b52f2/sql/mysql/Oracle/README.md)
lists BSD-3-Clause. However, the
[original revision cited by that README](https://github.com/mysql/mysql-shell-plugins/blob/8928ada7d9e37a4075291880738983752b315fee/gui/frontend/src/parsing/mysql/MySQLParser.g4)
contains a GPL-2.0 header. The current Oracle grammar also contains that header.
Do not assume that the mirror README resolves this difference. No Oracle grammar
or generated parser is added to the shipped app.

## Next design

Create a dependency-free Swift syntax target. It must retain original bytes and
source ranges. Use a byte cursor for lexing, recursive descent for statements,
and precedence-based expression parsing. Use typed syntax nodes and explicit
SQL mode and version context. Keep target policy, schema prediction and native
metadata normalization outside the syntax target.

Migrate the tested lexer first. Preserve behavior through an applier adapter.
Then move expression and statement parsing in tested groups. A module rename
alone does not complete this separation. Keep native comparisons and malformed
input tests as part of the parser's own test suite.

Swift's own [parser implementation](https://github.com/swiftlang/swift-syntax/blob/main/Sources/SwiftParser/Parser.swift)
uses recursive descent, byte buffers, source preservation and nesting limits.
Its editor recovery inserts missing syntax. Our execution path must instead
reject incomplete or recovered parses. `SwiftParser` parses Swift, not SQL; use
its design as a reference, not as a dependency.

## Swift follow-up

The first extraction is implemented in `Sources/MySQLSyntax`:

- The applier now calls the separate byte lexer and typed expression parser.
- Metadata normalization and target eligibility remain in the applier.
- Static and coverage Dockerfiles have a separate `sql-syntax` build stage.
- `make syntax-test` and `make syntax-coverage` run without app dependencies.
- The isolated suite passes 16 tests with table-driven cases. It covers 326 of
  333 executable lines (97.90%) on macOS and Linux. The Linux check uses the
  pinned Swift 6.2.1 toolchain. The CI minimum is 95%.
- All 435 affected syntax, applier and lab unit tests pass.
- The tooling suite passes 157 tests, with two optional integration checks skipped.
- Periphery reports no unused code from the completed build index.
- The static application build succeeds. Its application compile reuses the
  parser objects produced by the syntax stage.
- A second application build with an applier-only source file reused all three
  `sql-syntax` steps from Docker cache. It compiled the applier without compiling
  `MySQLSyntax` again. The temporary test file was removed after this check.

The native metadata grammar and DDL statement extraction are not complete.
The separate charset and expanded-expression failures recorded in the original
plan remain open. See [the syntax layer](../docs/SQL_SYNTAX.md) for the boundary.
