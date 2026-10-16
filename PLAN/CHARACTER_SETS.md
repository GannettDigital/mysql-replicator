# Character sets and collations

Status: native text encodings implemented for beta.6. The full charset requirement
remains open. See the test results in [beta.6](beta.6.md).

`CharacterSetRegistry` separates server-version names, character-set identity,
and column support. DDL diagnostics, client-encoding selection, compatibility
mapping and row metadata checks use the same registry.

## Current column support

CHAR, VARCHAR and TEXT accept all 40 native 5.7 text encodings and their 221
collations. The additional `binary` encoding uses BINARY, VARBINARY and BLOB
column types. The registry includes all 222 native 5.7 collation IDs.
Native inventory queries confirmed the same IDs, names and maximum character
widths on 8.4.8, with the documented utf8/utf8mb3 aliases.

MySQL 5.7 calls the three-byte UTF-8 encoding `utf8`. MySQL 8.4 uses `utf8mb3` in
its native definitions. The collation IDs retain the same encoding identity.
DDL schema planning resolves these aliases to the target's metadata names.

The decoder keeps non-UTF-8 text values as bytes. It does not convert them
through Swift String. SQL parameters use `CONVERT(? USING charset)`. This gives
key predicates the column's text comparison rules. Target reads use
`CAST(column AS BINARY)`. CHAR space trimming uses the encoding of the space character. It remains
separate from BINARY zero padding. The relay retains the original event bytes. SQLite stores row-intent references
and the column schema, including charset and collation. Recovery decodes the
relay again with that saved schema. No SQLite schema migration is required.

VARCHAR width uses the encoding's maximum bytes per character. VARBINARY width
uses bytes. Each allows at most 65,535 declared bytes. MySQL row, index and engine
limits still apply. The shared suite includes 20,000-byte declarations and
18,000-byte values. It does not prove every native width boundary.

ENUM and SET use exact encoded label metadata; see [the design](ENUM_LABEL_METADATA.md). SQL statement decoding still requires supported source query
encodings. This increment does not add arbitrary non-UTF-8 DDL text.

## Compatibility policy

The DDL event uses a collation ID to describe `character_set_client`. For source
ID 255 and a 5.7 target, ID 45 identifies the same utf8mb4 byte encoding. This
selection does not translate `collation_connection`. A change to comparison
semantics still requires the explicit compatibility policy.

The policy remains limited to source `utf8mb4_0900_ai_ci` and the three supported
utf8mb4 destination collations. Adding a column encoding does not add a policy
mapping. Unknown or mismatched column collations still stop application.

## Checks and remaining work

`matrix-encodings` and `bootstrap-matrix-encodings` use the shared harness. They
check latin1 high bytes, ASCII NUL, utf8mb3 names and values, CHAR/BINARY padding,
case-insensitive keys, JSON type checks with a text key, defaults, DDL, multi-row
INSERT, UPDATE and DELETE. The shared run reopens saved schemas at a clean
checkpoint. Bootstrap phases use fresh state to check discovery after each source
change. The `widestrings` cases check widths above the previous common limit.

Codec tests check INSERT/UPDATE/DELETE, NULL, and optional metadata or saved
schema history. A recovery test saves a pending latin1 key and ASCII value,
closes SQLite, reconstructs the values from the relay, resolves the unissued
transaction for retry, and reopens the state. It checks restored SQL conversions.
SQL-plan tests check byte bindings and key predicates. ABI 11
adds an encoded-text column interpretation. It returns existing binary cells;
it does not change the persisted row-value format. Use the matching binary for
states that contain the new column interpretation.

Remaining work includes non-UTF-8 query text,
further native width boundaries, and
explicit offline replay and recovery checks against MySQL after uncertain writes.
Do not
mark the broad support requirement complete from these cases alone.

Use requirement `values.character-sets` in `tests/DDLCoverage/support.json` and
the [complete-support plan](COMPLETE_MYSQL_SUPPORT.md) to track these gaps.

## Native references

The repository pins are in `tests/DDLCoverage/upstream.json`.

- MySQL 5.7: `strings/ctype-utf8.c`, `strings/ctype-uca.c`,
  `strings/ctype-latin1.c`, and `strings/ctype-extra.c` define the encodings.
- MySQL 5.7 `mysys/charset.c` and MySQL 8.4 `mysys/charset.cc` resolve UTF-8 aliases.
- MySQL 5.7 `sql/field.cc` converts character widths to byte widths and packs
  fixed strings. The decoder retains the existing native CHAR/BINARY rules.

Source inspection establishes identity and representation. Shared tests establish
behavior for the selected cases.

## Common-encoding collation inventory

Branch `beta/6/07-character-collations` adds the remaining collations for the
four supported text encodings. Native inventory queries on 5.7.42 and 8.4.8
confirmed all 63 IDs and version-specific names. MySQL 8.4 also reports
`utf8mb3_tolower_ci` (ID 76); 5.7 does not. It is outside this shared subset.
The 8.4-only UCA 9.0 collations remain outside this increment.

The `collations` shared case creates one column for each native 5.7 collation.
It checks defaults, exact bytes, NULL, INSERT, UPDATE, DELETE, and ALTER. Its
primary key uses `utf8mb4_unicode_520_ci`. The bootstrap case uses the same phases
and checks discovered metadata. Codec tests decode all 63 table-map IDs. Recovery
tests restore new collation names and values from SQLite and retained relay data.
These tests do not exhaust the language-specific comparison rules of each collation.

The old `charset_latin1` refusal is retired. The `encodings` live and bootstrap
cases test the now-supported behavior. The catalog records this as a positive
requirement, with named evidence binding still open.

## Native charset increment

Branch `beta/6/08-native-character-sets` adds the remaining 36 encodings.
The `nativeencodings` live and bootstrap cases include CHAR, VARCHAR and TEXT
for each encoding. They use explicit raw bytes, NUL, trailing spaces, NULL,
defaults, ALTER, UPDATE and DELETE. The primary key uses UTF16.

UCS2 and UTF16 use a two-byte space. UTF32 uses a four-byte space. The decoder
must remove complete space characters. It must retain a low byte of `0x20` in a
non-space character. The native reference is 5.7 `Field_string::pack`,
`Field_string::unpack` and the charset `lengthsp` functions. Native probes on
5.7.42 and 8.4.8 confirmed all 36 fixture byte vectors and padding results.

ABI 12 adds three encoded-text interpretations for wide-character padding.
Rows still use binary cells. Existing saved interpretations remain readable.
Older binaries cannot read the new interpretations. SQLite keeps the charset,
collation and schema; the relay keeps source bytes. Recovery tests reconstruct
a UTF16 key and UTF32 value after SQLite close and reopen.

The registry establishes native identities. Focused tests do not qualify every
collation's language-specific comparison behavior or every encoding boundary.
The non-UTF-8 query-text and ENUM/SET work remains open.
