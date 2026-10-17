# Executable version comments

Branch: `beta/6/69-executable-comments`.

## Native behavior and contract

MySQL can execute SQL inside `/*! ... */`. A version number after `!` sets the
minimum server version. Both pinned native lexers implement this in
`sql/sql_lex.cc`, in `MY_LEX_LONG_COMMENT`.

Direct probes on 5.7.42 and 8.4.8 show that the binlog retains active comments.
The source changes an inactive `/*!NNNNN ... */` into `/* NNNNN ... */` before
logging the query. A newer target must not activate that ordinary comment.
MySQL 8.4 also recognizes the six-digit version form. MySQL 5.7 consumes five
version digits. The parser view follows the target's format and exact version.

The applier sends executable comments to the target. It does not extract their
contents and force a lower version to execute them. For example:

```sql
/*!80400 ALTER TABLE t COMMENT='source-only' */;
```

MySQL 8.4 executes this ALTER. MySQL 5.7 accepts it without changing the table.
The applier journals the original SQL and sends it even when the whole statement
is inactive. Completion advances the checkpoint after the target acknowledges
it. A target error follows the existing BLOCKED and pending-intent rules.

Existing configured compatibility translations still apply to active SQL.
The comment wrappers stay in the target SQL. Trigger, event, filter and engine
policies also remain active. An inactive target clause does not install an object
and does not require that object's active-operation policy.

## Implementation

`SQLExecutableComments` produces a parser view, not executable SQL. It replaces
comment wrappers and inactive content with spaces. Byte offsets stay unchanged.
It respects SQL mode, quoted text, client-charset boundaries, ordinary comments,
and the native version-number formats. The original bytes remain available for
compatibility edits, target execution, failure reports and the SQLite journal.

Target preflight caches the exact VERSION() result. Each new target connection
reads it again. Metadata prediction and execution use the same version gate.
The DDL journal records `target-version-executable-comments` when the parser view
differs from the source bytes. No SQLite format migration is required.

Capture reads the first keyword through comment prefixes. It still accepts only
canonical BEGIN, COMMIT and ROLLBACK as transaction controls. A wrapped control
cannot become a false commit. Live and offline replay use the same apply path.

## Schema differences

A target can ignore a clause that the source executed. This can leave different
schemas, as with native version-gated SQL. The tool does not invent target columns
or discard source row values to hide that difference. Later incompatible row
metadata or values can block replication under the existing DML checks. The DBA
must resolve that difference before replication can continue.

A lower target's ignored clause is not evidence that the feature itself is
supported on that target. MySQL version and engine limits remain separate from
this comment syntax support.

## Tests

The syntax tests cover active and inactive gates, exact patch thresholds,
five/six-digit formats, quoting modes, client bytes, nested comments, malformed
input, limits and capture keywords. Apply tests cover target schema prediction,
filters, trigger/event policies, compatibility edits and a durable no-op intent.

Shared cases:

- `ddl-compat-executable-comments`: active comments, unchanged literal bytes,
  DML, saved-state restart, original SQL in the journal and offline replay.
- `ddl-compat-executable-comments-target-gate`: an 8.4 source executes a whole
  comment while the 5.7 target acknowledges it without changing the table.
- `ddl-compat-executable-comments-source-gate`: a 5.7 source disables a comment;
  its ordinary-comment form remains inactive on each target, including 8.4.

Full release qualification remains assigned to GitHub.

## Local verification — 2026-10-16

- The three shared cases passed all eight applicable profile/case combinations.
  Each profile checked live apply, saved-state restart and offline replay.
- The apply, codec and lab unit suites passed 623 tests.
- The syntax suite passed 49 tests. Its line coverage was 99.29% (1114/1122).
  The new executable-comment scanner had 100% line coverage (102/102).
  Line coverage does not prove every lexical combination.
- Periphery found no unused code.
- The catalog structure check passed: 63 scenarios, 240 registered cases and
  56 support requirements. This check does not qualify replication behavior.

Integration evidence: `artifacts/lab/20261016T194309Z-2b97b815/result.json`.
A read-only check of the forward profile's saved SQLite state confirmed that the
inactive `/*!80400 ALTER ... */` has identical source and target SQL, a DONE intent,
and no before/after schema IDs.
