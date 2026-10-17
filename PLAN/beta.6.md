# Beta.6 support work

Status: the implementation history is grouped into ten review branches and one
release branch. See [the current release stack](BETA6_RELEASE_STACK.md).
The entries below are historical; their publication status and branch counts
do not describe the new stack. Full release checks remain pending.
See the [current assessment](COMPLETE_MYSQL_SUPPORT.md#current-beta6-assessment)
for specific limits and incomplete tests. The entries below retain branch history.

## Baseline and release separation

The starting point is beta.5 stack tip `0499da659b16d669e95a0607ec428e34714eaeb2`.
Keep all beta.6 branches local until the full branch set is ready for review.
Do not push branches or open PRs yet. Then decide how to publish the stack with
the user. The proposed stack base is the beta.5 tip. Its PR branches stay unchanged. Beta.5 still needs passing checks, merge, and its tag and draft release.
Its version remains `0.1.0-beta.5` while support work starts on separate branches.
Do not include beta.6 commits in the beta.5 release. Tag the beta.5 release boundary,
even if beta.6 PRs are already open above it.

After beta.5 merges, compare its main tree with this baseline. Rebase the beta.6
stack onto the merged main commit if needed. Carry any later beta.5 fixes into
beta.6. Do not assume a squash merge preserves the old stack ancestry.

## Local branch bases

| PR branch | Base branch |
| --- | --- |
| `beta/6/01-support-catalog` | `beta/5/10-lab-command-help` |
| `beta/6/02-charset-registry` | `beta/6/01-support-catalog` |
| `beta/6/03-common-character-sets` | `beta/6/02-charset-registry` |
| `beta/6/04-fixed-scale-floating` | `beta/6/03-common-character-sets` |
| `beta/6/05-enum-zero` | `beta/6/04-fixed-scale-floating` |
| `beta/6/06-numeric-attributes` | `beta/6/05-enum-zero` |
| `beta/6/07-character-collations` | `beta/6/06-numeric-attributes` |
| `beta/6/08-native-character-sets` | `beta/6/07-character-collations` |
| `beta/6/09-legacy-floating-auto-increment` | `beta/6/08-native-character-sets` |
| `beta/6/10-exact-choice-metadata` | `beta/6/09-legacy-floating-auto-increment` |
| `beta/6/11-binary-choice-literals` | `beta/6/10-exact-choice-metadata` |
| `beta/6/12-native-decimal-defaults` | `beta/6/11-binary-choice-literals` |
| `beta/6/13-binary-defaults` | `beta/6/12-native-decimal-defaults` |
| `beta/6/14-native-text-defaults` | `beta/6/13-binary-defaults` |
| `beta/6/15-zero-width-columns` | `beta/6/14-native-text-defaults` |
| `beta/6/16-identifier-bytes` | `beta/6/15-zero-width-columns` |
| `beta/6/17-native-name-comparison` | `beta/6/16-identifier-bytes` |
| `beta/6/18-unicode-identifiers` | `beta/6/17-native-name-comparison` |
| `beta/6/19-query-encodings` | `beta/6/18-unicode-identifiers` |
| `beta/6/20-table-name-case` | `beta/6/19-query-encodings` |
| `beta/6/21-json-transport-review` | `beta/6/20-table-name-case` |
| `beta/6/22-fulltext-indexes` | `beta/6/21-json-transport-review` |
| `beta/6/23-json-load-data-review` | `beta/6/22-fulltext-indexes` |
| `beta/6/24-json-year-compatibility` | `beta/6/23-json-load-data-review` |
| `beta/6/25-json-year-translation` | `beta/6/24-json-year-compatibility` |
| `beta/6/26-json-generated-indexes` | `beta/6/25-json-year-translation` |
| `beta/6/27-table-options-alter` | `beta/6/26-json-generated-indexes` |
| `beta/6/28-multi-table-ddl` | `beta/6/27-table-options-alter` |
| `beta/6/31-mysql-syntax` | `beta/6/28-multi-table-ddl` |
| `beta/6/32-alter-charset` | `beta/6/31-mysql-syntax` |
| `beta/6/33-generated-syntax` | `beta/6/32-alter-charset` |
| `beta/6/34-spatial-prefix-indexes` | `beta/6/33-generated-syntax` |
| `beta/6/35-table-maintenance` | `beta/6/34-spatial-prefix-indexes` |
| `beta/6/36-check-compatibility` | `beta/6/35-table-maintenance` |
| `beta/6/37-subpartitions` | `beta/6/36-check-compatibility` |
| `beta/6/38-partition-maintenance` | `beta/6/37-subpartitions` |
| `beta/6/39-partition-expressions` | `beta/6/38-partition-maintenance` |
| `beta/6/40-partition-column-bounds` | `beta/6/39-partition-expressions` |

Branches 29 and 30 were unfinished experiments based on branch 28. Branch 32
replaces the charset work from branch 29. Branch 33 replaces the expression work from branch 30. Do not include those experiment branches in the PR stack.


These are the existing local branches. They are not the complete beta.6
branch set. Later branches will contain the remaining feature groups below.
The proposed base links keep each increment separate from the beta.5 changes.

## Branch order

The [complete-support plan](COMPLETE_MYSQL_SUPPORT.md) defines the scope and tests.
Use one branch per testable increment. Add branches when their work starts.
Do not open empty PRs for all planned work.

| Order | Branch or planned increment | Completion condition |
| --- | --- | --- |
| 1 | `beta/6/01-support-catalog` | Add the initial support audit to the existing catalog; validate profile and case references; keep qualification separate from implementation. |
| 2 | `beta/6/02-charset-registry` | Centralize charset/collation identities and server-version availability. Keep SQL compatibility policy separate from encoding. |
| 3 | `beta/6/03-common-character-sets` | Add byte-preserving transport, metadata and tests for a utf8mb3, latin1, ascii and binary subset. Keep remaining encodings and boundary checks open. |
| 4 | Scalars and identifiers | Cover fixed-scale floats, numeric attributes, ENUM zero/labels and native-valid identifiers. |
| 5 | JSON transport | Resolve each opaque subtype against native storage and the client protocol. |
| 6 | Table and DDL features | Add eligible options, indexes, ALTER, generated expressions, partitions and multi-object operations in separate PRs. |
| 7 | Row identity and relationships | Add unique-key/keyless paths and native-valid FK and transaction behavior. |
| 8 | Source event variants | Add row-image variants, compressed events, tagged GTIDs, eligible XA behavior and checksum modes in separate PRs. |
| 9 | Release report | Qualify the declared catalog on all four profiles; publish gaps and exact binary/test identities. |

## Initial branch results

- The catalog branch records 40 requirements. The audit remains partial.
  Twenty catalog and upstream-inspection tests passed. The catalog CLI check and
  JSON report also passed. No requirement is marked qualified.
- The charset-registry branch centralizes existing identities and support guards.
  It does not add a supported encoding. The apply and catalog selection passed
  245 tests. See [the charset work](CHARACTER_SETS.md).

## Common-charset validation

- Nine Rust unit tests passed.
- The apply, codec, schema-comparison and catalog selection passed 333 Swift tests.
- After adding the raw-text recovery case, all 27 restart/recovery unit tests passed.
  This includes closing SQLite, reading pending rows from retained relay bytes,
  restoring latin1/ASCII metadata, and rebuilding SQL conversions for retry.
- The four selected shared cases passed on all four profiles: `matrix-encodings`,
  `bootstrap-matrix-encodings`, `matrix-widestrings`, and
  `bootstrap-matrix-widestrings`. Each run also passed its saved-schema restart
  check. The final runs used unchanged build inputs.

  | Profile | Passing lab run under `artifacts/lab/` |
  | --- | --- |
  | `mysql84-to-mysql57-myisam` | `20261014T053159Z-b60237e8` |
  | `mysql57-to-mysql84-innodb` | `20261014T053201Z-6f17a262` |
  | `mysql57-to-mysql57-myisam` | `20261014T053314Z-e0056679` |
  | `mysql57-to-mysql57-innodb` | `20261014T053312Z-a6fdaf04` |

- The full suite remains a CI task. This increment does not qualify every charset,
  width boundary, replay scenario or crash outcome.

## Historical scope audit

This audit records the state before the later increments below. Some entries
are now implemented. Use docs/SUPPORT.md and the latest increment notes for
current limits.

The original complete-support plan and this worktree's copy have the same scope.
Only the status and link to this beta.6 work changed. Charset branches do not
complete that plan. The following groups still need implementation or native
behavior checks. Split each group into testable branches as work starts.

| Group | Remaining work | Current implementation evidence |
| --- | --- | --- |
| Stored values and identifiers | Remaining version-specific numeric attributes, escaped/non-UTF-8 ENUM/SET labels, native-valid non-ASCII identifiers, string boundaries and SQL modes. | `DMLColumnType.swift` now accepts fixed-scale floats but still limits metadata escapes. `Configuration.swift` restricts identifiers to ASCII. |
| JSON transport | Prove exact SQL transport for the remaining opaque subtypes and value ranges. | `JSONSQL.swift` has type-specific construction and verification paths. Existing JSON tests do not prove every native subtype. |
| Table and DDL features | Table options, FULLTEXT and other eligible indexes, column conversions, remaining ALTER forms, generated expressions, partitions/subpartitions, multi-table DROP and cross-schema RENAME. | `DDLParser.swift` accepts selected options and operations. `DDLTokens.swift` has a fixed expression function list. `Configuration.swift` limits index forms. |
| Version-dependent DDL | Classify CREATE TABLE SELECT, CHECK enforcement, views/routines/definers, conditional DDL and temporary-table events. | These require source and target checks. Parser acceptance alone cannot prove equivalent behavior. |
| Row identity and relationships | Unique-key fallback, keyless row matching, native-valid MyISAM groups, remaining FK relationships and source `foreign_key_checks` changes. | `DDLParser.swift` requires a primary key. `DDL.swift` rejects InnoDB DDL with source `foreign_key_checks=0`. Recovery must report ambiguous matching and possible relationship effects. |
| Source event variants | MINIMAL/NOBLOB row images, transaction compression, tagged GTIDs, eligible XA transactions, checksum modes and ignorable events. | `rust/src/lib.rs` requires CRC32 and rejects tagged previous-GTID sets. The current transaction path does not implement XA. Row metadata MINIMAL support is separate from row image MINIMAL support. |
| Qualification | Complete the requirement inventory and bind assertions to exact test/build evidence. Check live capture, replay, restart and failure handling for each applicable feature. | The 40-item catalog is a partial audit. No requirement is marked qualified. |

Charset work also remains: non-UTF-8 query text and ENUM/SET labels, width
boundaries, explicit offline replay and failure cases.
The common-charset tests do not close these requirements.

Do not count these as missing applier features without native evidence:

- MySQL 5.7 CREATE TABLE SELECT rejected under GTID consistency.
- Explicit engines or column features that the selected target cannot support.
- MyISAM statement groups that native GTID replication rejects.

Keep filter, trigger and scheduled-event safety policies visible as tool policies.
A filter crossing alone does not establish a native restriction. Features that
need a compatibility decision, such as CHECK enforcement across versions, remain
open until that decision and its tests are recorded.

## Next support increments

Continue stage 2 before table and event features:

1. Complete the remaining ENUM/SET literal forms and source query-text handling.
   Native charset transport, numeric attributes and ENUM zero are implemented.
2. Add native-valid identifiers with byte-exact table and schema identity.
3. Complete string-width boundaries, SQL mode cases, JSON opaque values, and
   explicit replay and failure-recovery checks. The existing positive cases do
   not qualify these paths.

Use the complete-support plan for the later JSON, DDL, key and event stages.
Each increment needs native behavior checks and focused shared cases.

## Current measurement rules

`tests/DDLCoverage/support.json` is a partial audit of known limits. Each item has
an owner stage, conditions, source/native behavior, implementation status and
required assertions. Candidate case IDs link to the shared test inventory. They
are not evidence bindings and do not claim that a case covers the full requirement.

The existing `ddl-catalog check` and `ddl-catalog report` commands include this
audit. No new test runner is added. All support requirements remain unverified.
Native restrictions, target limits and explicit safety policies are separate
from eligible implementation work. Items that need native research remain
visible and do not become automatic exclusions. No completeness percentage is
published from this partial inventory.

Next, split broad items into assertion/profile requirements as implementation
work begins. Add evidence import only with exact commit, fixture, assertion and
binary identity checks. Existing DDL evidence must not qualify new type or event
requirements by inference.

Run focused checks for each increment. Let full CI cover the broad regression
matrix. Use support bundles to inspect failures before rerunning a failed case.

## Fixed-scale floating-point increment

Branch `beta/6/04-fixed-scale-floating` adds FLOAT(M,D) and DOUBLE(M,D).
It retains binary row transport and adds default normalization and FLOAT endpoint
write expressions. Native SQL probes on 5.7.42 and 8.4.8 established default
behavior. A prepared-parameter probe confirmed the strict-mode endpoint issue.
See [the numeric design](FLOATING_POINT_SUPPORT.md) for details.

The selected numeric, DDL, catalog and recovery tests passed 64 unit tests.
The live and bootstrap cases for `fixedfloating` and `floatbounds` passed on
all four profiles. Each run also passed saved-schema restart. Final lab runs:

- `mysql84-to-mysql57-myisam`: `20261014T055819Z-8d2524fc`.
- `mysql57-to-mysql84-innodb`: `20261014T055819Z-5c108932`.
- `mysql57-to-mysql57-myisam`: `20261014T055819Z-331cc666`.
- `mysql57-to-mysql57-innodb`: `20261014T055819Z-6a5dbd92`.

These focused results do not replace full release qualification.
ZEROFILL and the other stage 2 requirements remain open.

## ENUM ordinal-zero increment

Branch `beta/6/05-enum-zero` adds the stored ENUM error value. It keeps this value
separate from a declared empty-string label. See [the write policy](ENUM_ZERO.md).
The selected unit tests passed 67 tests. They include mode restoration, failure
handling, InnoDB rollback and reconstruction from saved relay data.

The shared live and bootstrap cases passed on all four profiles, with saved-schema
restart. Final lab runs:

- `mysql84-to-mysql57-myisam`: `20261014T152426Z-67fd2207`.
- `mysql57-to-mysql84-innodb`: `20261014T152427Z-4e77c312`.
- `mysql57-to-mysql57-myisam`: `20261014T152428Z-fbf95d89`.
- `mysql57-to-mysql57-innodb`: `20261014T152426Z-a9cb8af2`.

Non-UTF-8 labels, supplementary-plane metadata and the remaining stage 2 work
are still open. Full qualification remains separate from these selected cases.

## Numeric attribute increment

Branch `beta/6/06-numeric-attributes` adds ZEROFILL and SIGNED syntax.
It preserves integer display widths and normalizes numeric padding in defaults
and row reads. See [the attribute notes](NUMERIC_ATTRIBUTES.md).
The selected unit tests passed 71 tests. Native probes used 5.7.42 and 8.4.8.

The live and bootstrap `zerofill` cases passed on all four profiles. Each run
also passed saved-schema restart and the included-table engine refusal check.
Final lab runs:

- `mysql84-to-mysql57-myisam`: `20261014T153949Z-66cda3c4`.
- `mysql57-to-mysql84-innodb`: `20261014T153949Z-4c70eb06`.
- `mysql57-to-mysql57-myisam`: `20261014T153949Z-51f8481a`.
- `mysql57-to-mysql57-innodb`: `20261014T153949Z-63527906`.

FLOAT/DOUBLE AUTO_INCREMENT remains open for the 5.7 target profiles.
These results do not close the remaining scalar or encoding requirements.

## Common-encoding collation increment

Branch `beta/6/07-character-collations` accepts all 63 MySQL 5.7 collations for
utf8mb4, utf8mb3, latin1 and ASCII. It retains the explicit 0900 mapping policy.
The selected Swift tests passed 71 tests. All nine Rust tests passed.

The live and bootstrap `collations` cases passed on all four profiles. Each
column has an explicit native collation. The checks compare stored bytes and
schema metadata after each phase. They do not exhaust linguistic sort behavior.
Final lab run directories:

- `mysql84-to-mysql57-myisam`: `20261014T160025Z-651d2d90`.
- `mysql57-to-mysql84-innodb`: `20261014T160025Z-e9882c54`.
- `mysql57-to-mysql57-myisam`: `20261014T160025Z-c72d93d0`.
- `mysql57-to-mysql57-innodb`: `20261014T160025Z-521c3be5`.

The forward failure workflow also passed, including engine and collation refusals,
permission errors, pending DDL records and blocked following events.
The old latin1 refusal is replaced by a positive catalog entry and the shared
`matrix-encodings` case. Named assertion evidence is not inferred from its pass.

## Native charset increment

Branch `beta/6/08-native-character-sets` adds byte transport and CHAR padding for
all remaining native 5.7 text encodings. The registry now has all 222 native
collations: 221 text collations plus binary. Native inventory probes confirmed
all IDs, names and widths on both pinned server versions.

The apply, codec, recovery and catalog tests passed 360 Swift tests. All nine
Rust tests passed. Native CHAR/VARCHAR probes passed for the 36 new encodings.
The live and bootstrap `nativeencodings` cases passed on all four profiles,
including saved-schema restart. Final lab runs:

- `mysql84-to-mysql57-myisam`: `20261014T161419Z-1aeda9d8`.
- `mysql57-to-mysql84-innodb`: `20261014T161419Z-4e107964`.
- `mysql57-to-mysql57-myisam`: `20261014T161419Z-2379b20f`.
- `mysql57-to-mysql57-innodb`: `20261014T161419Z-fecb31ea`.

ABI 12 retains binary cells and adds encoding-aware padding interpretations.
The saved schema remains in SQLite; the source bytes remain in the relay.
Non-UTF-8 ENUM/SET labels, query text and the remaining boundary and offline
qualification requirements are still open.

## Native 5.7 floating AUTO_INCREMENT increment

Branch `beta/6/09-legacy-floating-auto-increment` permits the native 5.7
FLOAT/DOUBLE AUTO_INCREMENT forms. The parser retains the attribute; DML sends
the explicit source key. MySQL 8.4 native error 1063 remains a version limit.

All 54 selected numeric, DDL, profile and catalog unit tests passed. Four live
and four bootstrap cases passed on each eligible profile, including saved-schema
restart. They cover FLOAT, DOUBLE, fixed FLOAT and unsigned DOUBLE:

- `mysql57-to-mysql57-myisam`: `20261014T162621Z-09f7c606`.
- `mysql57-to-mysql57-innodb`: `20261014T162621Z-e63e81b0`.

The shared inventory and execution paths use explicit profile exclusions.
The support inventory now has 43 requirements. The new positive requirement and
the two native version limits remain separate. An implemented requirement is
still unqualified until exact assertion evidence is bound to it.

## Exact ENUM/SET metadata increment

Branch `beta/6/10-exact-choice-metadata` reads native label bytes through temporary
target columns. It preserves numeric default semantics and compares schema text
by bytes. It keeps raw labels and required default ordinals in SQLite schemas.
The transaction, replay and checkpoint paths remain shared.

All 108 selected unit tests passed. The `exactchoices` and `choiceboundaries`
cases passed in live and bootstrap modes on all four profiles, including restart:

- `mysql84-to-mysql57-myisam`: `20261014T170217Z-76fba3ac`.
- `mysql57-to-mysql84-innodb`: `20261014T170217Z-dac8d8c6`.
- `mysql57-to-mysql57-myisam`: `20261014T170217Z-7e1983a0`.
- `mysql57-to-mysql57-innodb`: `20261014T170217Z-013a6c59`.

The runtime input digest was
`f70ec331dfae0390a92fb59989841223ac5d7667bbff305a5f37d4d2437ea368`.
The lab now sends SQL through standard input to prevent macOS from decomposing
Unicode command arguments. Native probes also checked routine bodies and vertical
status output through this input path.

This replaces the old non-BMP ENUM/SET rejection cases. It does not complete
all native literal forms, arbitrary binary labels/defaults, non-UTF-8 Query text,
or the remaining offline and failure qualification. See
[the metadata design](ENUM_LABEL_METADATA.md). The support catalog remains partial.

## Binary ENUM/SET literal increment

Branch `beta/6/11-binary-choice-literals` adds native hex and bit literals for
choice labels and defaults. Binary metadata retains raw bytes and default ordinals.
The lab compares raw SHOW CREATE output through an independent parser.

The first runs passed on both 5.7-to-5.7 profiles. The cross-version runs exposed
native error 3507 for `SET(X'ff',X'61') CHARACTER SET binary`. The source rejected
that DDL on 8.4; the reverse target rejected the same DDL after preparation.
The reverse support bundle retained the failed SQL, GTID, unchanged checkpoint
and statement outcome. The original artifacts remain under:

- Forward native-source refusal: `20261014T172023Z-14a750fc`.
- Reverse native-target refusal: `20261014T172019Z-e8a48122`.
- Initial 5.7 MyISAM pass: `20261014T172022Z-23dfb2c3`.
- Initial 5.7 InnoDB pass: `20261014T172021Z-7bcf4ec0`.

The shared `binarychoices` fixture now uses native-valid binary SET labels on all
profiles. `legacybinaryset` retains the non-UTF-8 SET case on 5.7-to-5.7 profiles.
See [native behavior and remaining checks](BINARY_CHOICE_METADATA.md).
The catalog now has 45 requirements. It remains partial and unqualified.

Final binary-choice runs passed, including saved-schema restart:

- `mysql84-to-mysql57-myisam`: `20261014T172902Z-c21edf3c`.
- `mysql57-to-mysql84-innodb`: `20261014T172902Z-2a2429d9`.
- `mysql57-to-mysql57-myisam`: `20261014T172905Z-7ebf5f82`.
- `mysql57-to-mysql57-innodb`: `20261014T172907Z-adfa7a67`.

All 105 selected unit tests passed. The runtime input digest was
`392cb6cc8f52a84ef8dce9bf465a9c30c927fb93c39a4a1e627bfa45d84b2dfe`.
These runs qualify the selected cases only. Full catalog bindings and broader
native-boundary, offline and failure checks remain open.

## Native DECIMAL default increment

Branch `beta/6/12-native-decimal-defaults` delegates default conversion to a
temporary target column. The parser retains numeric versus quoted literal form.
The target uses the logged SQL mode. It restores the previous mode and removes
the temporary table on success or failure. A cleanup failure closes the session.
The saved schema retains the existing canonical DECIMAL string format.

Native 5.7.42 and 8.4.8 probes both stored `1.235` as `1.24`, `-1.235` as `-1.24`,
and numeric or quoted `1.005e0` as `1.01` in DECIMAL(8,2). ZEROFILL changed display
padding, not the stored value. The parser no longer rejects these defaults because
they require rounding. Native range and SQL-mode rules still apply.

The pinned 5.7 implementation uses `Field_new_decimal::store_value`,
`Field_new_decimal::store(const char *, ...)` and `store(double)` in
`sql/field.cc`. The probe uses these server conversions instead of duplicating
them with a Swift floating-point approximation. It runs during schema preparation,
not for each row. DECIMAL row transport is unchanged.

All 276 selected apply and catalog unit tests passed. Five focused tests also
passed after the fixture correction. Full range/error, offline and failure
qualification remain separate catalog work.

The first DECIMAL fixture omitted a column after `ALTER ... DROP DEFAULT`.
Both native versions rejected that INSERT with error 1364. The fixture now
supplies SQL NULL explicitly. No applier failure bundle was expected for this
source SQL error. The failed run records remain at `20261014T174143Z-aafbf4f4`,
`20261014T174146Z-b41ed092`, `20261014T174149Z-07104e3a`, and
`20261014T174153Z-dd077333`. The shared binary-choice case passed in each run.

Final DECIMAL live, bootstrap and saved-schema restart runs passed:

- `mysql84-to-mysql57-myisam`: `20261014T174501Z-e8f517e7`.
- `mysql57-to-mysql84-innodb`: `20261014T174503Z-7abb2e49`.
- `mysql57-to-mysql57-myisam`: `20261014T174505Z-84adea4f`.
- `mysql57-to-mysql57-innodb`: `20261014T174508Z-021791cb`.

The runtime input digest was
`4f87ba0cae16dbda59b757c2d6c9cf1c358fdc1e7e53d0c7681d1c2b4e5e165a`.
The catalog now has 46 requirements. The new DECIMAL requirement is separate
from FLOAT/DOUBLE. Exact assertion bindings remain open; none is marked qualified.

## Binary default increment

Branch `beta/6/13-binary-defaults` adds exact BINARY and VARBINARY defaults.
Native probes on 5.7.42 and 8.4.8 stored `FF0001` correctly. The I_S display was
empty on 5.7 and `0xFF` on 8.4. A read-only `DEFAULT(column)` query returned all
bytes on both versions, including from an empty table. This avoids lossy display
metadata without scanning or changing application rows.

DDL preparation uses a temporary native column to resolve padding and conversion.
The saved schema keeps the previous string format for valid UTF-8 bytes. Other
defaults use optional raw bytes. The recovery test closes SQLite, reconstructs
pending rows and schemas from relay/state files, and verifies the retained bytes.

The lab compares exact native defaults. Shared cases include hex and bit literals,
embedded NUL, BINARY padding, empty values, BINARY(0), and CHAR with the binary
charset. They exercise CREATE, ALTER DEFAULT, ADD, MODIFY and row changes.
This increment does not claim all text literal or non-UTF-8 Query-event support.

All 283 selected unit tests passed.
The support catalog has 47 requirements; assertion bindings remain unqualified.

A native numeric probe stored `DEFAULT 1e2` as the bytes for `100`, not `1e2`.
Preparation retains numeric versus quoted literal form. ENUM/SET, DECIMAL and
binary preparation now share one parser-only literal marker. Resolution removes
that marker before saving the schema. The binary fixture checks this distinction.

Binary-default live, bootstrap and saved-schema restart runs passed:

- `mysql84-to-mysql57-myisam`: `20261014T175544Z-9d194df3`.
- `mysql57-to-mysql84-innodb`: `20261014T175558Z-0a0a80ad`.
- `mysql57-to-mysql57-myisam`: `20261014T175602Z-f0fff272`.
- `mysql57-to-mysql57-innodb`: `20261014T175605Z-0f6cc426`.

The runtime input digest was
`4b62806aaf777491d03bebff8a053a26c99c0876ba867333a7a54b68ca533393`.

## Native text default increment

Branch `beta/6/14-native-text-defaults` resolves CHAR/VARCHAR defaults through
native columns. Both 5.7.42 and 8.4.8 displayed `?` for a stored supplementary
character in I_S. A stored-default query returned the original UTF-8 bytes.
The same probe confirmed numeric versus quoted constants, latin1 and utf16 byte
literals, NUL and CHAR display padding.

Discovery and preparation use a shared read of the stored default. CHAR metadata
omits trailing U+0020 regardless of PAD_CHAR_TO_FULL_LENGTH. VARCHAR retains
trailing spaces. Saved defaults remain Unicode strings; their equality uses exact
UTF-8 bytes. The lab reads defaults as hex so NUL and whitespace cannot break its
metadata fields. It no longer converts displayed binary hex to a lossy string.

The shared cases cover supplementary and decomposed characters, wide and legacy
encodings, byte literals, numeric defaults, DDL and DML. They include a DDL event
with PAD_CHAR_TO_FULL_LENGTH. Non-UTF-8 Query-event text remains a separate gap.
Old state that saved a lossy `?` or truncated default must still fail schema drift
checks. Do not silently accept or rewrite that state without DBA review.

All 285 selected unit tests passed. Fifteen focused tests passed after the
additional exact-byte assertion.
The support catalog has 48 requirements and remains unqualified.

Text-default live, bootstrap and saved-schema restart runs passed:

- `mysql84-to-mysql57-myisam`: `20261014T180518Z-c8a45ef8`.
- `mysql57-to-mysql84-innodb`: `20261014T180522Z-f631e55c`.
- `mysql57-to-mysql57-myisam`: `20261014T180525Z-6c7fa92e`.
- `mysql57-to-mysql57-innodb`: `20261014T180528Z-2c3773e2`.

The runtime input digest was
`8e2f2cedb72aea4d86a145ea706b9b74576be53a369ce82acc68df861a8464aa`.

## Zero-width column increment

Branch `beta/6/15-zero-width-columns` adds VARCHAR(0) and VARBINARY(0).
Native 5.7.42 and 8.4.8 accepted CHAR(0), VARCHAR(0), BINARY(0) and VARBINARY(0)
with empty values and SQL NULL. Both InnoDB sources rejected the separate
VARCHAR(0) primary-key probe with error 1167. This source restriction is not a
missing positive column case.

The production change removes the artificial minimum of one for variable-width
columns. Unit recovery cases use real binlog decoding and persisted state for
empty UTF-8, utf16 and binary values. Shared live/bootstrap cases include all four
zero-width types, NULL, defaults and widening/shrinking around row updates.
All 45 selected unit tests passed. The catalog remains partial and unqualified.

Zero-width live, bootstrap and saved-schema restart runs passed:

- `mysql84-to-mysql57-myisam`: `20261014T181402Z-493c1a6f`.
- `mysql57-to-mysql84-innodb`: `20261014T181408Z-163a66a5`.
- `mysql57-to-mysql57-myisam`: `20261014T181408Z-d1311aca`.
- `mysql57-to-mysql57-innodb`: `20261014T181410Z-38111978`.

The runtime input digest was
`46e60a879a8fb156ce9212fadc74c7c18c323bc83b4fbb1f4a50d3a5dcab76f6`.

## Identifier cache increment

Branch `beta/6/16-identifier-bytes` separates table cache keys by UTF-8 bytes.
Native 5.7.42 and 8.4.8 accepted distinct names for `é` and `e` followed by
U+0301. Swift string equality treats those names as equal. The new key type
prevents cache collisions. Schema and wire-column comparisons also preserve bytes.
Saved schema JSON keeps its existing format. Cache keys are reconstructed on read.

All 359 selected apply and codec unit tests passed. This foundation does not yet
remove the ASCII identifier limit. Parser acceptance, native case comparison,
column lookups, filters and shared Unicode cases need a separate increment.
See [the identifier notes](IDENTIFIER_SUPPORT.md) for the native checks.

The selected composite-key, table-rename, bootstrap and index-resume checks passed
on all four profiles. The two InnoDB runs also passed foreign-key DDL, cascade,
rename and restart checks:

- `mysql84-to-mysql57-myisam`: `20261014T183824Z-9c86575c` (18 steps).
- `mysql57-to-mysql84-innodb`: `20261014T183827Z-506b7aed` (52 steps).
- `mysql57-to-mysql57-myisam`: `20261014T183853Z-fb264b28` (18 steps).
- `mysql57-to-mysql57-innodb`: `20261014T183856Z-4e2a47a1` (52 steps).

The runtime input digest was
`2df1ee8a7771da105543cc9e78777069e4d3e0a5dd9b32786b3bd2a9f3f3d66f`.

## Native name comparison increment

Branch `beta/6/17-native-name-comparison` uses the native system-charset lowercase
map for column, index, partition and relationship references. The pinned 5.7 and
8.4 maps have the same 696 non-identity entries. The generator checks both maps
and verifies the compressed range representation. Table identities remain exact.

This corrects ASCII references too. For example, `PRIMARY KEY(ID)` now resolves
column `id`. Schema comparisons keep definition bytes but compare column
references with native case rules. Wire column names still require exact bytes.
The shared `identifiercase` case exercises key references, ALTER DEFAULT, AFTER,
CHANGE, index rename/drop and following DML. The ASCII acceptance limit remains
until the parser and lab comparison code are ready for Unicode identifiers.

All 362 apply and codec unit tests passed. After the ASCII comparison fast path
was added, 27 focused identifier, schema-change and foreign-key tests passed.

Mixed-case live, bootstrap and saved-schema restart checks passed on all profiles:

- `mysql84-to-mysql57-myisam`: `20261014T184843Z-62a1b9c6`.
- `mysql57-to-mysql84-innodb`: `20261014T184844Z-eed4ca9a`.
- `mysql57-to-mysql57-myisam`: `20261014T184838Z-a02f96ff`.
- `mysql57-to-mysql57-innodb`: `20261014T184840Z-e3966cc1`.

The runtime input digest was
`9c29e0154e3276557d68fc71f195d7630cbcecbf3646e912410d5c6007e59317`.

## Unicode identifier increment

Branch `beta/6/18-unicode-identifiers` accepts native system-charset identifiers.
It counts Unicode scalars for the 64-character limit. It keeps table and database
names separate by their bytes. Column and index references use the native case
map. Metadata index sorting uses binary names so distinct indexes cannot interleave.

Both native versions accepted quoted and unquoted supplementary names through
a utf8mb4 client. They stored `?` and emitted warning 1300. The parser now tracks
that stored name and executes the original SQL without changing its bytes.
This conversion is separate from collation substitution policy.

The lab comparison now keeps distinct Unicode table and column names. It quotes
embedded backticks and compares exact schema text. Shared cases include composed
and decomposed names, Chinese names, a 64-character column, reserved words,
index and table rename, LIKE, row changes and bootstrap discovery.
A recovery unit test decodes a real-format table-map/row sequence, closes SQLite,
and reconstructs the pending Unicode schema and rows from saved state.

The broader unit run found a stale obligation count from the earlier latin1
increment. Its four refusal obligations became three positive obligations on two
profiles. The expected total is 728, not 730. The catalog test now states why.
All production tests in the 396-test run passed. The focused rerun of 12 Unicode,
lab-name and catalog tests passed after the assertion was corrected.

The first shared Unicode runs failed on all four profiles:
`20261014T190207Z-df92e1b6`, `20261014T190209Z-adc19c39`,
`20261014T190211Z-aa8cc0e1`, and `20261014T190213Z-1061ac9c`.
Their support bundles showed that the second Unicode table INSERT used the first
table's prepared statement. The client cache used Swift string equality.
It now hashes exact SQL bytes and compares the byte keys. Client row lookup also
keeps distinct Unicode column and table names. The original failure artifacts
remain available. All 383 selected unit tests passed after this fix.
The vendor file hashes and complete patch were checked against the pinned source.

Unicode DDL/DML, bootstrap discovery and saved-schema restart passed on all four
profiles. Each run completed 25 steps with the same runtime input digest:

- `mysql84-to-mysql57-myisam`: `20261014T191327Z-22ddf20f`.
- `mysql57-to-mysql84-innodb`: `20261014T191326Z-cd61240b`.
- `mysql57-to-mysql57-myisam`: `20261014T191325Z-c234e8c3`.
- `mysql57-to-mysql57-innodb`: `20261014T191931Z-e22e8344`.

The runtime input digest was
`b68b1396b27850bafea8fc586d540e49fe7e4c6068633e30c9dfcbe60c6ada73`.
An earlier same-version InnoDB attempt, `20261014T191329Z-bbd0339b`, stopped
during Docker Compose setup with a missing-image error. No applier case ran and
no failure bundle was expected. Its result and logs remain available. The retry
used unchanged build inputs after the other fixture builds had finished.

Non-UTF-8 Query text remains a gap. It now has an explicit charset diagnostic
before filtering or execution. Nonzero lower_case_table_names settings, Unicode
FK/generated-expression boundaries and complete offline qualification remain open.
The catalog remains partial; these selected tests are not release qualification.

## Increment 19: Query-event SQL encodings

Branch: `beta/6/19-query-encodings`.

The DDL lexer retains original byte offsets and handles multibyte characters
whose trailing bytes look like SQL punctuation. Native charset conversion
supplies identifier and literal metadata. COM_QUERY sends the original SQL
bytes. Pending DDL records retain source and target SQL bytes in base64.

All 321 selected unit tests passed. The new shared case checks latin1 and
Shift-JIS table names, text/binary/ENUM defaults, ALTER and following DML.
See [QUERY_ENCODINGS.md](QUERY_ENCODINGS.md) for results and scope.

Table-name case settings and the remaining JSON transport investigation are
next. FULLTEXT and other DDL groups follow these stage-2 items. Keyless recovery
and XA remain separate designs because they change restart behavior.

## Increment 20: table-name case contract

Branch: `beta/6/20-table-name-case`.

`source.lowerCaseTableNames` selects mode 0 or 1. Source and target must match.
Mode 1 uses the native lowercase map for database/table references and filters.
The original SQL remains unchanged. State format 10 pins this setting for
resume and recovery. Archives must match the configured setting.

All 472 selected unit tests passed. The new `lowercase-tables` variant tests all
three MySQL servers with mode 1. Selected live and offline results are recorded
in [TABLE_NAME_CASE.md](TABLE_NAME_CASE.md). Mode 2 and cross-setting replication
remain unqualified. The encoded-SQL case now restarts before latin1 and Shift-JIS
ALTER statements.

## Increment 21: remaining JSON transport review

Branch: `beta/6/21-json-transport-review`.

The pinned native source and disposable 5.7.42/8.4.8 probes confirm that ordinary
JSON parameters do not expose binary JSON field storage. YEAR becomes an integer
on 8.4. Binary CAST changes opaque subtype 253 to 15. An 8.4 wide-character
constructor can produce subtype 253, but it can change payload bytes. It is not
a general solution.

[JSON_TRANSPORT_INVESTIGATION.md](JSON_TRANSPORT_INVESTIGATION.md) records the
results, reproduction SQL, remaining range limits, and possible separate write
paths. No lossy conversion was added. Full support still has this explicit gap.

The requested stage-2 implementation/investigation increments are complete,
with the stated limits and selected test evidence. This is not full stage-2
catalog qualification. Continue with FULLTEXT and the remaining DDL families.
Keep keyless recovery and XA in separate designs.

## Increment 22: FULLTEXT index metadata and apply

Branch: `beta/6/22-fulltext-indexes`.

FULLTEXT definitions now use the shared schema, DDL and row-apply paths. Native
NULL direction and ignored prefixes are retained. Parser-plugin metadata comes
from SHOW CREATE and is checked on DDL and restart. Schema changes retain that
attribute. No new row transport or recovery state store is introduced.

The shared cases cover default-parser and ngram indexes, CREATE/ADD/DROP/RENAME,
CREATE TABLE LIKE, following row changes, initial discovery and saved-state
restart. The old FULLTEXT refusal selection becomes the existing engine-policy
refusal. [FULLTEXT_SUPPORT.md](FULLTEXT_SUPPORT.md) records test results, native
restrictions, a native search observation and remaining qualification.

All four profiles passed the 23 selected FULLTEXT steps with one input digest.
All 401 selected apply/lab unit tests passed; the final fixture changes passed
96 lab tests. The 17 CI-matrix tests passed. Native search differences found
during fixture review remain documented; they are not hidden as passed coverage.

Other DDL groups remain open. Keyless recovery and XA are still separate designs.

## Increment 23: JSON LOAD DATA review

Branch: `beta/6/23-json-load-data-review`.

The linked MySQL example imports JSON text. Native source inspection and direct
5.7.42/8.4.8 probes confirm that LOAD DATA uses the JSON text parser. Opaque-value
text becomes a string. Internal binary JSON fails with error 3140; the binary
character set fails with error 3144. LOCAL changes the file transfer, not JSON
storage conversion. No alternate applier write path was added.

[JSON_TRANSPORT_INVESTIGATION.md](JSON_TRANSPORT_INVESTIGATION.md) records the
article, native code path and probe results. The remaining exact-value transport
gaps stay open. The beta.6 branch set is still incomplete and remains local.

## Increment 24: YEAR inside JSON compatibility issue

Branch: `beta/6/24-json-year-compatibility`.

[JSON_YEAR_COMPATIBILITY.md](JSON_YEAR_COMPATIBILITY.md) separates the 5.7 to 8.4
YEAR constructor difference from binary-value gaps. It describes the current
strict behavior and the scope of a possible explicit YEAR-to-unsigned-integer
rule. This is a documentation change. No conversion is implemented or enabled.
Binary-value gaps remain open. Runtime tests were not repeated for this change.

## Increment 25: explicit JSON YEAR conversion

Branch: `beta/6/25-json-year-translation`.

Add `compatibility.jsonYearToInteger`, disabled by default and restricted to
5.7 to 8.4. Convert only opaque YEAR values to unsigned JSON integers. Use the
same target representation for writes and before-image checks. Retain source
bytes in relay/recovery records and include the policy in recovery reports.
Pin the policy in SQLite across restart, replay and recovery. Add a selected
correctness case for strict refusal, native constructor checks and replay.

See [JSON_YEAR_COMPATIBILITY.md](JSON_YEAR_COMPATIBILITY.md). Binary-value gaps
remain open. The branch remains local.

Validation: 491 selected unit tests passed. The final lab assertion changes
passed 96 lab unit tests. The selected reverse-profile correctness case passed
with live restart and offline replay. Evidence is under
`artifacts/lab/20261014T222611Z-d0b6ff01`. Full release qualification was not run.


## Increment 26: target-specific JSON DDL

Branch: `beta/6/26-json-generated-indexes`.

Add JSON extraction and CAST to schema expressions. Select functional-index,
expression-default, and indexed VIRTUAL-column support from the target version
and engine. Decode the outer escaping in 8.4 information_schema expressions.
Keep expression defaults and functional index parts in saved schema metadata.
Old saved schemas still decode without these optional fields.

The shared `ddl-compat-json-indexes` case covers four profiles. The reverse-only
`json-target84-schema` case covers an existing 8.4 table with functional indexes
and a JSON expression default, including restart and offline replay. This is
not an 8.4-to-8.4 replication qualification. See
[the JSON support guide](../docs/JSON_SUPPORT.md).

The broader generated-expression and DDL work remains open. Native references:
5.7 `sql/sql_table.cc` virtual-index engine checks and
`mysql-test/suite/gcol/t/rpl_gcol.test`; 8.4 `sql/dd/dd_table.cc`,
`sql/item.cc:convert_and_print`, and `sql-common/sql_string.cc:String::print`.

Validation for the initial implementation: 411 apply and lab unit checks passed.
The generated JSON index case passed on all four profiles. Each run also
reopened saved schema state. Evidence under `artifacts/lab/`:

| Profile | Run |
| --- | --- |
| 8.4 to 5.7 MyISAM | `20261014T225440Z-645ee541` |
| 5.7 to 8.4 InnoDB | `20261014T225442Z-3e269b8d` |
| 5.7 to 5.7 MyISAM | `20261014T225624Z-3ba752d6` |
| 5.7 to 5.7 InnoDB | `20261014T225629Z-058ed67c` |

The 8.4 target run also passed functional-index and JSON-default discovery,
row changes, restart, and offline replay. Follow-up checks add explicit
functional-index collation, automatic-name collisions, and
`json-target57-limits`. The last case checks native version and engine errors
before target SQL, with no target table and no checkpoint advance.

The final checks passed:

- `20261014T230517Z-664cc9a0`: all three native-limit refusals reported
  `statement.phase: notIssued`. No target table was created. Each saved state
  remained `BLOCKED` with zero applied transactions.
- `20261014T230516Z-06eaeead`: the 8.4 functional index with explicit
  `COLLATE utf8mb4_bin` passed discovery, indexed queries, row changes, restart,
  and offline replay. The target also evaluated its JSON expression default.

The final apply/lab unit run passed 411 checks. No full correctness sweep was
run for this increment. The selected tests cover the changed paths.


## Increment 27: table options and column conversions

Branch: `beta/6/27-table-options-alter`.

Parse table and column comments, physical/statistics options, AUTO_INCREMENT,
and same-engine rebuilds. Send the original SQL through the DDL journal.
Comments and physical options are not part of the row schema. They remain
in the recorded SQL. Uncertain DDL still requires DBA review.

Remove the blanket type-family check for MODIFY and CHANGE. MySQL performs
the conversion under the logged session settings. Keep schema validation,
primary-key requirements, FK validation and the DDL barrier. Native reference:
5.7 `sql/sql_table.cc:copy_data_between_tables` uses `Copy_field` to convert
stored values. Its row-format handling retains the old format when omitted.

Selected tests: `ddl-compat-table-options` and `ddl-compat-alter-conversions`.
These tests do not qualify every physical option or cross-version conversion.
Validation results will be recorded after the runs.

Native multi-table DROP review for the next increment:

- MySQL 5.7.42 with InnoDB: `DROP TABLE a,missing,b` reports error 1051,
  but removes both existing tables.
- MySQL 8.4.8 with InnoDB: the same statement reports error 1051 and keeps
  both existing tables.
- Probe logs: `/tmp/beta6-native-drop57.log` and
  `/tmp/beta6-native-drop84.log`. The tables were in the disposable
  `beta6_multi` database. Separate `SHOW TABLES` queries checked the result.
- The 5.7 source is `sql/sql_table.cc:mysql_rm_table_no_locks`. It continues
  through the list and records missing-table and foreign-key errors.
- Save all affected table schemas before target SQL. On an error, keep the
  DDL pending. Do not infer rollback from the target error.

The first conversion runs found an existing default-discovery defect. The
false outer join in `readStoredDefaultBytes` returned NULL for a NOT NULL
column, even when the stored default was non-NULL. Native 5.7 and 8.4 probes
confirmed this. See 5.7 `sql/field.h:Field::is_null`: a nonnullable field uses
`TABLE::has_null_row()` for this check.

For a NOT NULL default, clone only the field into a private temporary table,
with `CREATE TEMPORARY TABLE ... AS SELECT column ... LIMIT 0`. Insert DEFAULT
there and read the exact bytes. The existing ENUM/SET metadata path uses the
same native field-copy method. Do not copy or write application rows.
The selected tests also check empty tables with NOT NULL text and binary
columns. Original failed runs and their support bundles remain under
`artifacts/lab/20261014T231950Z-f08c5802` and
`artifacts/lab/20261014T231953Z-fd59d9da`.

Increment 27 selected validation: 413 apply/lab unit checks passed. The table
options and conversion cases passed on the two cross-version profiles:
`20261014T232832Z-06f39b32` (8.4 to 5.7 MyISAM) and
`20261014T232832Z-31fa9c3c` (5.7 to 8.4 InnoDB). The next increment will also
run these cases on the two same-version profiles. No full suite was run.


## Increment 28: multi-table DROP and cross-schema RENAME

Branch: `beta/6/28-multi-table-ddl`.

Parse up to 64 DROP names and preserve their SQL order. Save all existing
affected table schemas and affected FK peers in one DDL record before execution.
Send the original statement once. Retire schemas only with the completed GTID.
An execution or checkpoint error leaves the complete record pending.

Allow single and ordered multi-table RENAME across schemas. Retain table
encoding, update FK components, and use the existing atomic namespace update
in SQLite. Keep the filter boundary policy. Native 5.7 `sql/sql_rename.cc`
passes both database names to `mysql_rename_table`; views and triggers have
additional native limits. This increment does not expand view or trigger policy.

Selected cases: `ddl-compat-multi-table` and
`ddl-compat-cross-schema-relationships`. The latter uses FK cascades only on
InnoDB targets. Unit checks cover filtering, mode-1 names, ordered parsing,
complete pending records, checkpoint failure, schema retirement and reopen.

MySQL writes a generated DROP statement into the binlog. The test checks that
the applier retains that recorded statement, not the original client spelling.
A source 5.7 DROP can also log a partial result with a nonzero query error code.
The current source-error guard still rejects that event. Reproducing failed
source DDL across version/engine boundaries remains a separate support gap.

Selected integration checks passed on all four profiles. The table-option and
conversion cases also passed on the two same-version profiles. Evidence:

| Profile | Options and conversions | Multi-table DDL and relationships |
| --- | --- | --- |
| 8.4 to 5.7 MyISAM | `20261014T232832Z-06f39b32` | `20261015T010659Z-3e418c78` |
| 5.7 to 8.4 InnoDB | `20261014T232832Z-31fa9c3c` | `20261015T010700Z-9b4285ea` |
| 5.7 to 5.7 MyISAM | `20261015T011451Z-c5ee93bb` | Same run |
| 5.7 to 5.7 InnoDB | `20261015T011501Z-175e62ee` | Same run |

All run-level results, including cleanup, report `passed`. These are selected
cases, not a full release qualification. The unit run passed 416 checks.

Final cleanup removed an unused stored table-option value and an unused
string-array comparison helper. The SQL validation and execution paths are
unchanged. The final source passed all 416 apply/lab unit checks and strict
Periphery analysis against the updated Swift index. Periphery reported no
unused code. The integration results above precede this unused-code cleanup;
no broad integration sweep was repeated after it. Both branches remain local.

## Syntax and charset continuation

Branch 31 extracts `MySQLSyntax`, its isolated tests and its Docker build layer.
Branch 32 completes the selected charset ALTER cases and equivalent DEFAULT
syntax translation. See [the updated scope assessment](COMPLETE_MYSQL_SUPPORT.md#beta6-assessment-after-the-syntax-extraction)
and [charset evidence](ALTER_CHARSET.md). These increments do not close the full
support plan or qualify the release.

Branch 33 adds typed generated-expression forms and native metadata comparison.
Branch 34 adds geometry BTREE byte prefixes for 5.7 targets and a specific 8.4
version error. See [expression scope](GENERATED_EXPRESSIONS.md) and
[spatial prefix scope](SPATIAL_PREFIX_INDEXES.md). Their combined fixed-input
run `20261015T073916Z-20bde8e4` passed 21 applicable cases, with three native
version exclusions. The 421 build inputs stayed unchanged. Isolated syntax
coverage is 600/603 lines (99.50%). Periphery found no unused code. No beta.6
release is qualified yet.

Branch 35 adds FORCE and ENABLE/DISABLE KEYS. See
[maintenance behavior and tests](TABLE_MAINTENANCE.md). Branch 36 follows the verified [native 5.7 to 8.0 rule](CHECK_CONSTRAINTS.md).

Branch 36 adds a central native version-rule type and ignored 5.7 CHECK
handling. It retains source SQL, rule IDs and durable DDL completion. Enforced
8.4 checks still stop before target DDL on 5.7. See
[the implementation and checks](CHECK_CONSTRAINTS.md).

## Increment 37: partition and subpartition metadata

Branch: `beta/6/37-subpartitions`, based on branch 36.

Typed partition syntax stays in `MySQLSyntax`. The applier stores subpartition
names, methods and expressions, and reads the corresponding native metadata.
Selected lifecycle cases cover row effects, saved-state restart and offline
replay. See [scope and verification](PARTITION_SUPPORT.md). Remaining partition
forms stay open in the complete-support plan.

## Increment 38: KEY algorithm and partition maintenance

Branch: `beta/6/38-partition-maintenance`, based on branch 37.

The saved schema now records KEY ALGORITHM=1. Omitted algorithms use native
algorithm 2. Discovery reads the algorithm from SHOW CREATE TABLE because
`information_schema.PARTITIONS` does not expose it. DML uses the existing
schema cache.

Typed syntax covers REBUILD, ANALYZE, CHECK, OPTIMIZE and REPAIR PARTITION.
The applier checks administrative result rows for errors before it completes
the DDL intent. Native CHECK and LOCAL operations do not enter the binlog.

This increment also fixes schema equality. It now compares ordered
subpartitions and KEY algorithms. Branch 37 saved subpartitions but omitted
them from its custom equality operator. The new unit tests check each field,
child order and exact identifier bytes.

See [partition scope and test results](PARTITION_SUPPORT.md). The remaining
partition expressions, tablespace operations and EXCHANGE WITHOUT VALIDATION
remain open. This branch stays local.

Run `20261015T164911Z-24c49dc0` passed all 12 selected profile cases, including
offline stop/resume and the branch 37 regression. The affected unit run passed
478 tests. The three support-catalog tests and Periphery also passed. Syntax
coverage was collected because this increment changes `MySQLSyntax`; the
independent target covered 897/903 executable lines (99.34%).

## Increment 39: partition expressions and unchecked exchange

Branch: `beta/6/39-partition-expressions`, based on branch 38.

Partition bounds now use native constant evaluation before the applier saves
the DDL intent. The saved schema contains evaluated values. The original SQL
remains the statement sent to the target. Typed date/time literals use the
shared syntax target. Ordinary literal bounds need no evaluation query.

EXCHANGE WITHOUT VALIDATION retains native table checks and records both
tables in the DDL journal. The applier does not validate or move misplaced
rows. An uncertain exchange remains pending and cannot resume automatically.
See [partition implementation and test results](PARTITION_SUPPORT.md).

Both new workflows passed on all four profiles, including restart and offline
replay. The first run passed the same-version cases. A metadata spelling fix
in the harness allowed the cross-version reruns to pass. The affected unit run
passed 483 tests; eight focused comparison/catalog tests passed after the fix.
Syntax coverage was 903/909 lines (99.34%). Periphery passed. See the partition
plan for the run IDs, input digests and remaining limits. This branch stays
local and does not claim complete partition qualification.

## Increment 40: exact column partition bounds

Branch: `beta/6/40-partition-column-bounds`, based on branch 39.

Add binary and charset literals to RANGE/LIST COLUMNS bounds. Read native
partition metadata without loss of bytes. Preserve connection-charset bytes,
empty values and native DATE spelling. Add an independent harness comparison
for binary bounds. Record native misplaced-row errors and the limits of those
probes. See [partition details and verification](PARTITION_SUPPORT.md).

Both selected workflows passed on all four profiles with the same build.
The final affected unit run passed 494 tests. Syntax coverage was 922/928
lines (99.35%). The support-catalog tests and Periphery passed. Read-only
SQLite checks confirmed exact bounds in all four saved schemas. The branch
stays local. Full release qualification remains separate.

## Increment 41: CREATE TABLE SELECT contract

Branch: `beta/6/41-create-select-contract`, based on branch 40.

Check permanent CTAS against the native servers before adding apply logic.
MySQL 5.7 rejects it under GTID consistency. MySQL 8.4 records atomic CREATE
and row events in one group. Its START TRANSACTION clause cannot execute on
5.7 or native MyISAM. Classify this as a target limit for the forward profile.
Keep the capture rejection and verify that no target write or checkpoint
advance occurs. A blocked restart also retains the original state.

Add shared temporary CTAS cases for permanent row effects, clean restart and
offline stop/resume. Both selected cases passed on all four profiles. All 101
lab unit tests passed. The automatic support bundle retained the expected
capture failure and unchanged checkpoint. No replication code changed.
See [native contract, run IDs and limits](CREATE_TABLE_SELECT.md).

This branch stays local. Next, audit views, routines, definers and the remaining
conditional and temporary-object forms. Full release qualification remains open.

## Increment 42: stored-object DDL

Branch: `beta/6/42-stored-object-ddl`, based on branch 41.

Add ALTER PROCEDURE and ALTER FUNCTION characteristics. Accept parenthesized
view queries and multi-view DROP. Keep all object names for existence and
filter checks. Preserve original SQL and session context in the existing DDL
journal. Reject source error codes before a filter can skip partial DDL.

The new shared workflow passed on all four profiles with one build-input
digest. It checks definers, routine attributes, view check options, row effects,
restart and offline replay. The apply/lab unit checks passed after correcting
the shared CLI path for the support-bundle test. Periphery found no unused code.
See [stored-object evidence and remaining gaps](STORED_OBJECT_SUPPORT.md).

This branch stays local. Next are routine CREATE IF NOT EXISTS translation and
view renaming. The broad stored-object catalog group remains incomplete.

## Increment 43: conditional routine creation

Branch: `beta/6/43-conditional-routines`, based on branch 42.

Translate routine CREATE IF NOT EXISTS for 5.7 targets. Remove only the parsed
header clause when the routine is absent. Record a completed no-op when it
already exists. Keep the source SQL and compatibility rule in the DDL journal.
Keep existing bodies and definers. Targets that support the syntax receive it.

All 24 focused unit tests passed. The conditional and stored-object workflows
passed on the forward profile, including restart and offline replay:
`20261015T220915Z-34d9798a`. The conditional case requires an 8.4 source.
This branch stays local. View renaming is next.

## Increment 44: view rename workflows

Branch: `beta/6/44-view-renames`, based on branch 43.

Use one ordered namespace for table and view renames. Support single view
renames, view swaps, and mixed table/view lists. Preserve definitions, definers
and creation settings in the existing DDL journal. Keep views outside the
row-schema cache. Check native cross-database view rejection without a binlog
change. The target account needs SHOW VIEW for definition reads.

All 463 apply/lab unit tests passed. Periphery passed. The shared view workflow
checks live apply, restart and offline stop/resume on all four profiles. The
InnoDB regression also checks foreign-key rename relationships and following
DML. See [run IDs and scope](STORED_OBJECT_SUPPORT.md#view-rename-verification).

This branch stays local. Full release qualification remains open. The remaining
stored-object variants, unique-key/keyless identity, FK controls and event
variants remain in the complete-support plan.

## Increment 45: unique-key row identity

Branch: `beta/6/45-unique-row-identity`, based on branch 44.

Support tables without a primary key when a full, nonnullable scalar UNIQUE
index can identify each row. Preserve the declared primary key separately.
Save the selected index and ordered columns with each schema version. Use it
for SQL predicates and recovery output. Accept native promoted-key metadata.

The shared workflow covers key changes, index replacement, primary-key
addition/removal, text keys, AUTO_INCREMENT, clean restart and offline replay.
It passed on all four profiles. The final apply/lab unit run passed 468 tests,
including a regression for partially supplied optional metadata. Periphery
passed. See [exact run scope and build digests](ROW_IDENTITY.md#verification).

This branch stays local. Nullable, prefix, expression and keyless matching
remain outside this increment. Next, define full-row matching and duplicate
counts in recovery records before adding keyless application.


## Increment 46: full-row matching

Branch: `beta/6/46-keyless-row-matching`, based on branch 45.

Use the full base-row image when no supported primary or unique key exists.
UPDATE and DELETE change one matching copy. Preserve NULL, exact text and binary
values, DECIMAL precision, signed zero and JSON structure and scalar types.
Save the lookup mode with each schema. Recovery retains duplicate operations
and does not treat a full-row image as a unique key or proof of COMMIT.

The shared workflow covers live apply, clean restart, offline stop/resume,
missing-row errors, partial MyISAM writes, InnoDB rollback and DBA retry.
All four selected runs passed 32 shared steps with the same runtime binary.
The apply/lab unit run passed 472 tests, and Periphery passed.
See [the design and exact verification results](KEYLESS_ROWS.md).

This branch stays local. Full release qualification remains open. The next
relationship work covers self-references, cycles and source foreign_key_checks.

## Increment 47: foreign-key controls

Branch: `beta/6/47-foreign-key-controls`, based on branch 46.

Permit native-valid self-references and cyclic relationships on InnoDB. Restore
source `foreign_key_checks` for each row event and DDL statement. Keep different
settings in separate INSERT chunks. Retain the settings in offline recovery
reports and DDL diagnostics. Model the target version's default FK action.

The selected workflows compare source, native and target rows and schemas. They
include restart, offline replay, rollback after checks are restored, and saved
relationship checks. The selected checks passed on all four profiles with the
same binary. The unit run passed 549 tests, and Periphery passed.
See [scope and validation](FOREIGN_KEY_CONTROLS.md).

Keep this branch local. Remaining FK DDL and event-format gaps stay open in
[the complete support plan](COMPLETE_MYSQL_SUPPORT.md).

## Increment 48: foreign-key DDL

Branch: `beta/6/48-foreign-key-ddl`, based on branch 47.

Record permitted supporting-index removals before DDL. Save the exact target
schema after execution. Propagate FK-column renames through the relationship
component. Permit DROP DATABASE when all relationships stay inside that database,
and retire its saved FK schemas with the source GTID.

The shared workflow includes cascades after DDL, restart and offline replay.
See [scope and verification](FOREIGN_KEY_DDL.md). Keep this branch local.

## Increment 49: missing-parent foreign keys

Branch: `beta/6/49-missing-parent-foreign-keys`, based on branch 48.

Keep missing-parent relationships in saved schemas. Support child creation and
parent drops with source checks disabled. Discover incoming relationships when
the parent is created. Test child DML, cascades, restart and offline replay.
See [scope and verification](MISSING_PARENT_FOREIGN_KEYS.md). Keep this branch local.

## Increment 50: native parent-key rules

Branch: `beta/6/50-native-parent-key-rules`, based on branch 49.

Use native InnoDB parent-index rules. MySQL 8.4 sessions disable
`restrict_fk_on_non_standard_key`, as native replica threads do. Test nonunique,
composite-prefix and extended parent keys, cascades, restart and replay.
Keep missing-index rejection tests and support-bundle checks.
See [scope and verification](FOREIGN_KEY_PARENT_KEYS.md). Keep this branch local.

## Increment 51: FK syntax and column rules

Branch: `beta/6/51-foreign-key-syntax-columns`, based on branch 50.

Preserve MySQL 5.7 MATCH behavior on both InnoDB targets. Accept named supporting
indexes and unnamed constraints. Use native InnoDB storage rules for FK columns.
See [scope and verification](FOREIGN_KEY_SYNTAX_COLUMNS.md). Keep this branch local.

## Increment 52: cross-database foreign keys

Branch: `beta/6/52-cross-database-foreign-keys`, based on branch 51.

Support child database DROP and parent database DROP with source checks disabled.
Journal the surviving FK participants and validate them after DDL. Keep a test
for an unexpected target-only incoming FK. Test restart and offline replay.
See [scope and verification](CROSS_DATABASE_FOREIGN_KEYS.md). Keep this branch local.

## Increment 53: stored generated FK columns

Branch: `beta/6/53-generated-column-foreign-keys`, based on branch 52.

Accept stored generated FK parents and children. Keep native virtual-column and
action limits. Test native cascades, restart and offline replay.
See [scope and verification](GENERATED_COLUMN_FOREIGN_KEYS.md). Keep this branch local.

## Increment 54: compound FK indexes

Branch: `beta/6/54-compound-foreign-key-indexes`, based on branch 53.

Record exact index replacements for compound FK/index/column changes. Validate
the actual target schema without enumerating full-schema combinations. Test native
outcomes, cascades, restart and offline replay.
See [scope and verification](COMPOUND_FOREIGN_KEY_INDEXES.md). Keep this branch local.

## Increment 55: ALTER column keys

Branch: `beta/6/55-alter-column-keys`, based on branch 54.

Support inline primary keys and NOT NULL column additions without a default.
Restore logged AUTO_INCREMENT settings before DDL. Test native values, key changes,
restart and offline replay on all four profiles.
See [scope and verification](ALTER_COLUMN_KEYS.md). Keep this branch local.

## Increment 56: generated-column dependencies

Branch: `beta/6/56-generated-column-dependencies`, based on branch 55.

Check all ALTER actions before rejecting generated-column dependency changes.
Use identifier references and the target-specific 5.7 DROP restriction. Test
changed expressions, stored/ordinary conversion, later DML, restart and replay.
See [scope and verification](GENERATED_COLUMN_DEPENDENCIES.md). Keep this branch local.

## Increment 57: functional-index and default dependencies

Branch: `beta/6/57-expression-dependencies`, based on branch 56.

Check functional-index and expression-default dependencies across the complete
ALTER. Permit explicit removal or replacement in the same statement. Test an
existing 8.4 target schema, refusals, later DML, saved-state restart and replay.
See [scope and verification](COLUMN_EXPRESSION_DEPENDENCIES.md). Keep this branch local.

## Increment 58: DDL checklist and future events

Branch: `beta/6/58-ddl-completion-checklist`, based on branch 57.

Use the [specific DDL checklist](DDL_COMPLETION_CHECKLIST.md). Record row-image
variants, tagged GTIDs and XA as [future work](FUTURE_BINLOG_SUPPORT.md). These
remain limits on a complete-support claim. Keep this branch local.

## Increment 59: column and index syntax

Branch: `beta/6/59-column-index-syntax`, based on branch 58.

Add inline keys, serial attributes, grouped columns/indexes, physical index
options and execution options. Test native key names, later rows, restart and
replay. See [scope and results](COLUMN_INDEX_SYNTAX.md). Keep this branch local.

## Increment 60: compound table renames

Branch: `beta/6/60-compound-table-renames`, based on branch 59.

Apply ALTER renames and column/FK changes as one statement. Journal the final
name and all affected FK peers. Cross-schema moves, cascades, restart and replay
pass on all four profiles. Reject the reproduced native 8.4 parent-rename defect
before target SQL. See [scope and results](COMPOUND_TABLE_RENAMES.md). Keep this branch local.

## Increment 61: grouped constraints and index names

Branch: `beta/6/61-grouped-constraints-index-names`, based on branch 60.

Add grouped FK/CHECK clauses and native unnamed-index boundary rules. See
[scope and checks](GROUPED_CONSTRAINTS_AND_NAMES.md). Keep this branch local.

## Increment 62: primary-key parts

Branch: `beta/6/62-primary-key-parts`, based on branch 61.

Preserve primary-key prefixes and directions through discovery and saved schemas.
See [scope and tests](PRIMARY_KEY_PARTS.md). Keep this branch local.

## Increment 63: remaining ALTER forms

Branch: `beta/6/63-alter-forms`, based on branch 62.

Translate RENAME COLUMN with native column definitions. Accept ORDER BY,
validation clauses and additional physical options. See
[scope and checks](REMAINING_ALTER_FORMS.md). Keep this branch local.

## Increment 64: 8.4 index and SRID metadata

Branch: `beta/6/64-target84-index-srid`, based on branch 63.

Retain index visibility and spatial reference constraints in discovered and
saved schemas. See [scope and checks](TARGET84_INDEX_SRID.md). Keep this branch local.

## Increment 65: native DDL audit

Branch: `beta/6/65-ddl-native-audit`, based on branch 64.

Add INTERVAL function parsing, YEAR casts and remaining physical-option forms.
Extend shared expression and absent-definer tests. Record native restrictions,
privilege rules and the FULLTEXT reproduction in [the audit](DDL_NATIVE_AUDIT.md).
Keep this branch local. Full release qualification remains assigned to GitHub.

## Increment 66: simultaneous column names

Branch: `beta/6/66-simultaneous-column-renames`, based on branch 65.

Resolve CHANGE swaps and chains from original column identities. Map keys and
FK peers once. Test column order, following DML, restart, replay and failed
checkpoints. See [scope and results](SIMULTANEOUS_COLUMN_RENAMES.md).
Keep this branch local. Full release qualification remains assigned to GitHub.

## Increment 67: partition-column renames

Branch: `beta/6/67-partition-column-renames`, based on branch 66.

Accept column renames when one ALTER replaces or removes partitioning. Keep
native dependency checks for unchanged expressions. Add native trailing syntax,
subpartition and implicit-KEY tests, restart and replay. See
[scope and results](PARTITION_COLUMN_RENAMES.md). Keep this branch local.

## Increment 68: support status audit

Branch: `beta/6/68-support-status-audit`, based on branch 67.

Separate confirmed tool gaps, native restrictions, target limits, policies and
incomplete tests. Correct stale feature limits in the support guide, README,
DDL/DML guides and related plans. Keep historical branch results labelled as
history. The catalog report counts specific tool gaps and incomplete test groups
separately. Candidate case IDs do not qualify a requirement. Full release
qualification remains assigned to GitHub.

Validation: 117 selected lab/catalog unit tests passed. The catalog check accepts
63 DDL scenarios, 237 registered cases and 56 support requirements. Its report
separates 10 specific tool-gap groups, 28 incomplete-test groups and 18 native,
target or policy exclusions. These counts are not feature-support percentages.
Periphery found no unused code in the completed build index. This increment
changes reporting and documentation; it does not change apply behavior.

## Increment 69: executable version comments

Branch: `beta/6/69-executable-comments`, based on branch 68.

Retain executable comments in target SQL. Predict schema changes using the exact
target version. Journal fully inactive statements and await target acknowledgement.
Capture recognizes comment-wrapped DDL while it keeps transaction controls strict.
Shared cases cover active comments, source-disabled comments, the lower target's
version gate, restart and replay. See [the contract and results](EXECUTABLE_COMMENTS.md).
The catalog moves this requirement from a specific tool gap to implemented work
with incomplete qualification. The remaining inventory has nine specific tool-gap
groups; it is not a complete MySQL feature denominator.

## Increment 70: tagged GTIDs

Branch: `beta/6/70-tagged-gtids`, based on branch 69.

Preserve UUID, tag and sequence across decoding, source resume, checkpoints,
duplicate checks and replay. Tagged identities first required state format 11.
The follow-up GTID preservation work uses format 12 and assigns source GTIDs on
the target by default; see [settings and privileges](../docs/GTID_PRESERVATION.md).
The forward-profile tagged case passed with preservation disabled. It checked
tagged DDL/DML, rotation, restart and archive replay. See [scope and remaining tests](TAGGED_GTIDS.md).
Keep this branch local.

## Source GTID preservation: working-tree validation

`target.preserveSourceGTIDs` is a boolean and defaults to true. False retains
source identities only in SQLite. State format 12 records the setting. Older
state requires explicit false. See [privileges, Cloud SQL limits and MyISAM
execution](../docs/GTID_PRESERVATION.md).

On 2026-10-16, the source-GTID case passed on all four profiles, including
multi-row writes, keyless duplicates, restart and replay. Evidence:
`artifacts/lab/20261016T211104Z-ae86561f/result.json`. The broad unit selection
passed 630 tests. The later recovery/configuration/lab selection passed 162 tests;
the final lab selection passed 23 tests. These selections overlap. Periphery
reported no unused code. No Cloud SQL instance or performance run was tested.

The `gtids` test family has four default-profile preservation cases and one
forward tagged case with preservation disabled. The disabled variant does not
repeat unrelated correctness or lifecycle cases.

Release preparation still needs a separate CI change. The normal CI plan has
176 jobs and is valid. Expanded coverage would have 339 jobs, above GitHub's
256-job matrix limit. Removing the new GTID cases still gives 329 expanded jobs;
this limit is not caused by GTID preservation. Split the expanded plan across
multiple matrix jobs, or collect coverage in separate runs. Do not remove release
assertions to fit this limit. No expanded coverage run was started locally.

## Increments 71 through 78: operational additions

See [the additions and validation record](Beta.6.additions.md). These branches
add smaller support bundles, include filters, shared TLS policy, durable
statistics, progress estimates, CLI overrides, and a separate formatting check.
State format 13 pins the table filters. All branches remain local.
