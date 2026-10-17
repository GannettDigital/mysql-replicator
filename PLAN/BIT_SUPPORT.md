# BIT support

Status: implementation and unit tests complete. Shared integration cases exist
for all four profiles. Use the exact commit's full-CI results for release
qualification; the initial unit-only results below are historical.

## Behavior

- Accept `BIT(1)` through `BIT(64)`. An omitted width means `BIT(1)`.
- Preserve the width in saved table schemas. Require the source and target
  widths to match, including on the 5.7 metadata path.
- Decode the packed binlog bytes into UInt64. Do not use floating-point values.
- Bind values as unsigned MySQL integers. Read target values with
  `CAST(column AS UNSIGNED)` for before-image and recovery comparisons.
- Support BIT primary keys, NULL values, and INSERT, UPDATE, and DELETE.
- Accept numeric, `b'101'`, and `0b101` defaults in CREATE, ADD, and MODIFY.
  Save defaults in canonical `b'101'` form. Reject values outside the width.
- Keep the existing ALTER COLUMN SET DEFAULT parser limits. Use a numeric
  default there, or MODIFY the column to set a bit-literal default.
- Reject invalid widths, malformed metadata, truncated values, nonzero unused
  high bits, AUTO_INCREMENT, and conversion between BIT and other type families.

BIT remains a separate wire type. It does not consume a signedness bit or a
character-set entry in optional TABLE_MAP metadata. No codec ABI change or SQLite
migration is needed. Row diagnostics use the existing unsigned decimal-text
representation. The schema records that the value is BIT and retains its width.

## Native reference

The local MySQL 5.7 and 8.4 trees agree on these rules:

- `Field_bit::do_save_field_metadata` writes width modulo eight, then width
  divided by eight.
- `Field_bit::pack` writes the partial high byte first, then the whole bytes.
  `Field_bit::store` and `val_int` confirm big-endian byte order.
- MySQL 5.7 `sql_show.cc` renders BIT defaults as `b'...'` without leading zeros.

References: MySQL 5.7
[`field.cc`](https://github.com/mysql/mysql-server/blob/f7680e98b6bbe3500399fbad465d08a6b75d7a5c/sql/field.cc)
and [`sql_show.cc`](https://github.com/mysql/mysql-server/blob/f7680e98b6bbe3500399fbad465d08a6b75d7a5c/sql/sql_show.cc);
MySQL 8.4
[`field.cc`](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/sql/field.cc).

## Verification

The Swift suite passed 436 tests. The Rust suite passed eight tests. New checks
cover widths 1, 7, 8, 9, 63, and 64; zero, maximum, high-bit, asymmetric-byte, and
NULL values; all three row operations; malformed input; metadata alignment;
DDL defaults; primary-key SQL; saved schema; relay recovery; and restart state.
The wire fixtures use independently constructed bytes and CRCs.

Logs: `/tmp/beta5-bit-swift.log` and `/tmp/beta5-bit-rust.log`.
Periphery found no unused code (`/tmp/beta5-bit-periphery.log`).
`git diff --check` passed. The lab accepted selection of both BIT cases for all
four profiles without starting containers (`/tmp/beta5-bit-selection.json`).

The shared catalog now includes `matrix-bits` and `bootstrap-matrix-bits` for all
four profiles. These cases cover replicated CREATE and existing-table discovery.
They also cover ADD/MODIFY, defaults, primary-key changes, and values above
Int64.max. Full CI includes these cases. The local results listed above cover
unit tests and offline selection, not database integration. Review the full-CI
results for integration qualification.

[FLOAT/DOUBLE](FLOATING_POINT_SUPPORT.md), [JSON](JSON_SUPPORT.md), and
[spatial support](SPATIAL_SUPPORT.md) are implemented as separate increments.
