# Oracle parser evaluation

Run these tools from the repository root. They write only evaluation files under
`artifacts/sql-parser-evaluation`. They do not change app dependencies.

Requirements: Python 3, Java 21, macOS clang++, and Docker for the native and
static Linux checks. The Java generator runs at build time only.

```sh
python3 tools/sql-parser-evaluation/fetch.py
python3 tools/sql-parser-evaluation/build.py
python3 tools/sql-parser-evaluation/build.py --patched
python3 tools/sql-parser-evaluation/evaluate.py
python3 tools/sql-parser-evaluation/evaluate.py --patched
```

The patched build tests two C++ lexer support fixes. It does not fix all grammar
differences. Both result sets are retained. `inputs.json` records input URLs and
hashes. The source commits and ANTLR version are pinned in `fetch.py`.

For native checks, use disposable MySQL 5.7 and 8.4 containers with root access
and no password. The script drops and recreates only the `antlr_eval` database.
Do not point it at a shared or production server.

```sh
python3 tools/sql-parser-evaluation/native.py --mysql57 CONTAINER57 --mysql84 CONTAINER84
python3 tools/sql-parser-evaluation/check_results.py
python3 tools/sql-parser-evaluation/measure.py
```

The build below uses the existing local packaging builder and its static musl
SDK. Generate the patched parser on macOS first. Run all source generation before
the Linux build; do not change its inputs while compilation is active.

```sh
docker run --rm --platform linux/amd64 --entrypoint python3 \
  -v "$PWD:/work" -w /work mysql-replicator-demo-builder:latest \
  tools/sql-parser-evaluation/build_linux.py
python3 tools/sql-parser-evaluation/measure.py --linux
```

The fixture scan extracts ordinary Swift string literals. It skips interpolated
strings and does not evaluate Swift expressions. Some extracted text is a test
description or SQL batch. Use the curated native comparison to assess defects.
Do not interpret the scan's acceptance count as a support or coverage percentage.

See [the evaluation results](../../PLAN/SQL_PARSER_RESULTS.md). Resolve the recorded
license difference before any product use of the downloaded grammar.
