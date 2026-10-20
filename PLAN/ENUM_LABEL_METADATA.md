# Exact ENUM and SET label metadata

Status: implemented on `beta/6/10-exact-choice-metadata`; selected live and bootstrap checks passed on all four profiles.

## Native metadata loss

MySQL 5.7 `Field_enum::sql_type` and `Field_set::sql_type` convert labels to the
output string's charset. `sql_show.cc` uses `system_charset_info` for SHOW CREATE
and INFORMATION_SCHEMA column types. This is three-byte UTF-8. A supplementary
character can appear as `?`. SHOW CREATE is therefore not an exact fallback.

A 5.7.42 probe created `ENUM('😀','?','a') CHARACTER SET utf8mb4 DEFAULT '😀'`.
SHOW CREATE displayed `enum('?','?','a')` and default `?`. These definitions must
not be treated as equivalent.

## Native probe that retains the labels

`CREATE TEMPORARY TABLE scratch AS SELECT enum_column FROM original LIMIT 0`
retains the native ENUM type and its default in 5.7.42. Inserting ordinals 1, 2,
and 3 into this temporary column and selecting `column+0, HEX(column)` returned:

| Ordinal | Bytes |
| --- | --- |
| 1 | `F09F9880` |
| 2 | `3F` |
| 3 | `61` |

Inserting DEFAULT returned ordinal 1 and `F09F9880`. The temporary table's own
SHOW CREATE still displayed question marks. The stored bytes provide the check.
This probe changes only a temporary table. It does not change the application table.

The native source path is `create_table_from_items` in `sql/sql_insert.cc` and
`Create_field(Field*, Field*)` in `sql/field.cc`. The constructor retains the
ENUM/SET type library and copies the original default.

## Implementation

`ChoiceMetadata.swift` uses a temporary InnoDB column to read each ENUM ordinal
or SET bit. Inserts use batches of at most 256 values. No application row is
copied. The code drops the temporary table on success and failure. A cleanup or
SQL-mode restore failure closes the connection and stops apply.

DDL preparation uses the target's native column conversion to normalize labels
and defaults. The parser keeps numeric defaults separate from quoted defaults.
The logged application DDL is still issued once through the existing intent path.
Temporary probes run before a target data transaction. They do not replace the
SQLite journal and do not advance the applied checkpoint.

Saved schemas contain exact raw label bytes and default ordinals where metadata
can lose information. Optional fields preserve the format of ordinary old UTF-8
schemas. Ambiguous old metadata is not silently accepted. Definition and default
comparisons use UTF-8 bytes, not Swift's canonical Unicode string equality.
The existing schema cache avoids probes for each applied row.

The target account needs `CREATE TEMPORARY TABLES` on replicated databases.
The schema's labels can be visible in temporary table definitions and SQL logs.
The temporary tables contain label probes, not application rows.

The lab now sends SQL through file-backed standard input. Darwin's Process API
can decompose Unicode command arguments: `é` becomes bytes `65 CC 81` instead of
`C3 A9`. SQL input must preserve the source bytes. The input path also handles
stored routine bodies and native status output.

## Qualification checks

- Confirm SET bitmask reads, all target versions, generated columns and defaults.
- Limit probe size and batch ordinal inserts. Do not read application row data.
- Preserve exact ordered label bytes in the saved schema. Keep ordinal zero
  separate from an empty label and SQL NULL.
- Resolve source DDL labels in their declared encoding. Do not use a lossy
  INFORMATION_SCHEMA string as source evidence.
- Compare default ordinals as well as displayed default strings. Native collation
  rules can map a default spelling to a different label spelling.
- Keep the existing schema cache. Probe on discovery or DDL changes, not per row.
- Verify temporary-table privileges and cleanup after errors or disconnects.
- Test live DDL, bootstrap discovery, restart and pending-row recovery. Remove
  current label refusals only when those checks pass.

See [current support](../docs/SUPPORT.md) for the implemented contract.
Full offline, failure and native-boundary qualification remains open. This
increment does not add non-UTF-8 Query event text or every native literal form.
The next [binary choice increment](BINARY_CHOICE_METADATA.md) adds hex/bit literals
and binary defaults. It also records the native 8.4 SET restriction.

## Focused evidence

All 108 selected metadata, DDL, recovery, catalog and process-input unit tests
passed. Both shared cases and their bootstrap forms passed on all four profiles,
including saved-schema restart. See [beta.6](beta.6.md) for run IDs.

The live cases use GTID-enabled sources. They verify supplementary UTF-8,
latin1, UTF16, UTF16LE, UTF32 and GB18030 labels; quoted and numeric ENUM defaults;
SET default normalization; ALTER DEFAULT; ordinal INSERT/UPDATE/DELETE; primary-key
updates; empty labels; trailing spaces; escaped quotes and backslashes; NULL;
and SET bit 63. Recovery tests retain raw label bytes in SQLite and reconstruct
pending row values from the relay.

Native MySQL rejects a numeric SET default that is not a label. The boundary
fixture uses the valid label default `s64` and checks its stored bit value.
The failed source setup runs remain in local artifacts. The initial latin1
default failure exposed the macOS process-argument conversion described above.
