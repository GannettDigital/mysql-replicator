# Beta.6 support work

Status: work started. This is not a release qualification claim.

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

## Remaining scope audit

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
