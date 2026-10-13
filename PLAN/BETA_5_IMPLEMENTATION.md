# Beta.5 implementation order

## 1. Replay startup and support bundles

- Check the first `Previous_gtids` event against the saved SQLite checkpoint
  before scanning the archive. For new state, use the configured baseline.
- Report the file name, required GTIDs, and applied GTIDs when history is missing.
- Do not hash archive files during fetch or replay. Use event CRCs for corruption
  checks. Reuse successful validation within one replay session if the archive
  files have not changed.
- Keep the full archive check before target writes. Check file continuity, CRCs,
  transaction boundaries, and the requested stop GTIDs.
- Report validation progress on stderr. Keep stdout for JSON result records.
- Create missing support bundle output directories. Include archive inventory
  and preamble diagnostics before large binlog files consume the bundle limit.
- Test early rejection, corruption, archive changes, resume, and bundle limits.

Archive files must remain unchanged while replay runs. Header checks alone do
not prove that all required transactions are present.

## 2. Test selection

Use one path-to-test map for local checks and PR checks. Separate report tools
from build, release, fixture, and runtime code. Use the broader checks for unknown
paths. Keep full main and release checks until a separate change is approved.
Test the selector against saved examples of changed files.

The user moved this step before command help. Documentation, report tools, and
test selectors can skip application builds. Changes to `Makefile` and
`ci.yml` select the two-profile PR checks, not all correctness variants.
Keep runtime CLI and logging changes in the PR integration selection until a separate module and tests justify a narrower rule.

## 3. Command help

Use Swift Argument Parser for commands, options, and help. Keep the existing
commands, YAML configuration, and JSON result format. Add help for each command.
Do not add a command-line option for each YAML setting.

## 4. Column types

First, record a type support matrix for all four profiles. Include decoding,
target discovery, DML, DDL, and recovery comparisons. Then add BIT and FLOAT/DOUBLE
in separate increments. Add JSON after those increments. Review spatial types
separately before implementation.

Each type increment needs INSERT, UPDATE, DELETE, boundary-value, and restart
tests. A target must reject source types or values that it cannot represent.
Do not infer support from a parser accepting a type name.

## Delivery

Keep these changes in separate reviewable increments. Run the checks for each
increment before starting the next one. The user will push the branches.

## Replay integrity decision

Native MySQL replication checks event CRCs as it reads events. It does not require
an SHA-256 hash of each complete binlog. See the MySQL 8.4 documentation for
[`binlog_checksum` and checksum verification](https://dev.mysql.com/doc/refman/8.4/en/replication-options-binary-log.html).
The local 5.7 and 8.4 binlog sender and replica readers use event checksum tests.

An archive hash checks whether a file still matches a previously recorded copy.
It does not prove GTID continuity or authenticate the source. Creating a hash at
replay startup cannot detect damage that occurred before that hash was created.
A hash cannot repair a file. MySQL serves a replacement by file name and position.
For fetched and external files, use event CRCs, framing, GTID history, and
transaction checks. New manifests use version 2 without hashes. Replay accepts
version 1 manifests but ignores their saved hashes. Support bundles keep hashes
to identify the files collected for diagnosis.

The full validation scan remains a separate policy. It prevents target writes
when a later archive file is corrupt or incomplete. It also delays application
until all files have been read. Native replication validates events as it goes.
Changing to that model would permit a committed prefix before a later archive
error. Do not describe header checks as equivalent to full validation.

## Replay increment verification

After archive hash removal, all 416 Swift unit tests passed.
The tests include version 2 manifests without hashes, version 1 manifests with
ignored hashes, CRC failures, early history rejection, changed files, validation
reuse, cancellation, saved SQLite GTIDs, and support bundle output limits.
Log: `/tmp/beta5-no-archive-hash-tests.log`.

Before archive hash removal, the `offline-replay` case passed on all four profiles
with the Linux coverage binary. It checked fetch, rotation, external raw files, partial replay, resume,
source-free replay, native result comparison, and support bundle extraction.
Local evidence: `artifacts/lab/20261013T194612Z-0fe53864/result.json`.
The runtime image was `sha256:ad4cc59ee31e774edf08f218830b9fc632fbe8a27c76422679292d00c56a2839`.
The build input digest was `74ccb930336fe42a8038523da707b6ea18651852c243bed494e2a26fd1e93e55`.
The logs show one validation scan per invocation and reuse before application.
These small fixtures do not measure throughput on a 300 GB archive.

## Test-selection increment verification

Python tool checks completed: 148 tests, no failures, and two optional Swift
cache integration tests skipped. The selector tests use temporary Git repositories
to check renames, deletions, merge bases, more than 300 changed files, local edits,
and unavailable history. They also exercise the CI entry point and its outputs.
Result-gate tests reject failed, cancelled, missing, and unexpected skipped jobs.
Log: `/tmp/beta5-test-selection-tools.log`.

The local command plans were accepted by the existing lab with `--list` for both
PR selections and all five full-suite families. The workflow YAML parsed, and
`make test-selection` produced valid JSON. No database suite was run for this
Python/workflow change. The changed CI job graph still needs a GitHub run after
push. This increment does not change the full CI matrix or the selected PR cases.
