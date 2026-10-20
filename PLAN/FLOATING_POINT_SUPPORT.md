# FLOAT and DOUBLE support

Status: implementation and unit tests complete. Shared integration cases exist
for all four profiles. Use the exact commit's full-CI results for release
qualification; the initial unit-only results below are historical.

## Stored row values

FLOAT uses an IEEE binary32 bit pattern. DOUBLE uses an IEEE binary64 bit pattern.
The Rust decoder reads the little-endian binlog bytes without a decimal-text
conversion. Swift retains the bits in distinct value cases. The SQL client sends
binary FLOAT/DOUBLE parameters and reads binary results from prepared statements.

Before-image checks compare bits, with no tolerance. Positive and negative zero
remain distinct. Finite subnormal values remain intact. NaN and infinity are
rejected: ordinary SQL writes can change these values. UNSIGNED columns reject
negative row values. Negative zero is permitted.

FLOAT and DOUBLE can be primary-key columns. The target uses MySQL's key lookup
rules; row comparison still checks the exact stored bits. Recovery output includes
a readable decimal string and an `ieeeBits` hexadecimal string. The latter is
the exact value. Recovery does not infer commit success from an approximate match.

This increment introduced codec ABI 7. Kinds 8 and 9 carry the IEEE bits in
`unsigned_value`. The current ABI is 11 after the JSON, spatial and charset additions.
Build Swift and Rust from the same revision. No SQLite schema migration is
needed for floating-point values.

## DDL and defaults

| Form | Behavior |
| --- | --- |
| FLOAT, DOUBLE | Supported, including UNSIGNED |
| FLOAT(p) | 0–24 becomes FLOAT; 25–53 becomes DOUBLE |
| DOUBLE PRECISION | Normalized as DOUBLE |
| REAL | FLOAT with logged REAL_AS_FLOAT mode; otherwise DOUBLE |
| FLOAT(M,D), DOUBLE(M,D) | Supported for native widths 1–255 and scales 0–30, with D no greater than M |
| ZEROFILL | Supported; implies UNSIGNED |
| DOUBLE(p) | Rejected by native 5.7 and 8.4 syntax |
| Numeric and exponent defaults | Accepted within the numeric parser; MySQL executes the original expression |
| NULL defaults | Retained as SQL NULL |

Native replication does not reconstruct stored values from INFORMATION_SCHEMA.
Its row path unpacks the stored bytes. Its DDL path executes the logged query
under the recorded session settings. It does not reject a default because its
display text has fewer digits than its stored value.

The external applier follows that distinction. It sends the original default
expression to the target. It does not replace that expression with rounded text.
For example, `FLOAT DEFAULT 1.23456789` remains unchanged in the SQL request.
Schema comparison uses the six-significant-digit display used by MySQL for
FLOAT defaults. That comparison does not prove equality of the default's stored
bits. Actual row values use the binary path and exact comparisons described above.

Default metadata prediction follows the plain FLOAT/DOUBLE storage rules for
range clipping and underflow. The target still decides whether the original DDL
succeeds under its logged SQL mode. Server errors remain errors. Defaults that
cannot be parsed as finite Double values remain unsupported. These limits do not
replace the separate row-value checks.

## Native references

Both local upstream trees were checked. In MySQL 5.7:

- `Field_real::pack` and `unpack` copy the binary floating-point bytes, with byte
  order conversion where required.
- `Field_float::store`, `Field_double::store`, and `Field_real::truncate` define
  SQL write behavior.
- `Protocol_binary::store` sends four bytes for FLOAT and eight for DOUBLE.
- `Field_float::val_str` calls `my_gcvt` with `MY_GCVT_ARG_FLOAT`. That function
  limits display precision to `FLT_DIG`, which is six significant digits.
- `Query_log_event::do_apply_event` executes DDL through `mysql_parse`.

See the pinned MySQL 5.7
[`field.cc`](https://github.com/mysql/mysql-server/blob/f7680e98b6bbe3500399fbad465d08a6b75d7a5c/sql/field.cc),
[`protocol_classic.cc`](https://github.com/mysql/mysql-server/blob/f7680e98b6bbe3500399fbad465d08a6b75d7a5c/sql/protocol_classic.cc),
[`dtoa.c`](https://github.com/mysql/mysql-server/blob/f7680e98b6bbe3500399fbad465d08a6b75d7a5c/strings/dtoa.c),
and [`log_event.cc`](https://github.com/mysql/mysql-server/blob/f7680e98b6bbe3500399fbad465d08a6b75d7a5c/sql/log_event.cc).
MySQL 8.4 uses the same packing and display rules in
[`field.cc`](https://github.com/mysql/mysql-server/blob/0896fcd61dec11a0904166911a0126f59daaa1bf/sql/field.cc).

## Verification

The full Swift suite passed 442 tests. The Rust suite passed eight tests.
After the default-metadata correction, 36 focused tests passed. They include
the original default SQL, rounded schema display, and exact row-bit comparison.

New tests check normal and subnormal bounds, both zeros, both signs, 0.1, maximum
finite values, adjacent IEEE values, NULL, all row operations, invalid metadata,
truncated values, NaN/infinity refusal, signedness metadata, binary parameters,
DDL forms, saved schema, relay recovery, and restart state.

Logs: `/tmp/beta5-float-swift.log`, `/tmp/beta5-float-rust.log`, and
`/tmp/beta5-float-defaults.log`.
Periphery found no unused code (`/tmp/beta5-float-periphery.log`).
`git diff --check` passed. The lab accepted the new case selection for all four
profiles without starting containers (`/tmp/beta5-float-selection.json`).

The shared catalog includes `matrix-floating` and `bootstrap-matrix-floating`
on all four profiles. The cases include a default with more than six digits,
primary-key changes, DML, subnormal and maximum values, ADD, and MODIFY.
The fixed-scale refusal cases were replaced by `matrix-fixedfloating` and
`bootstrap-matrix-fixedfloating` in beta.6. The generic unsupported-DDL and filter
cases now use an explicit engine outside the selected target profile.

Full CI includes these cases. The local results listed above cover unit tests
and offline selection, not database integration. Use exact binary-value checks
when reviewing the CI results: SQL text alone does not distinguish all
FLOAT values. [JSON support](JSON_SUPPORT.md) is implemented separately.

## Beta.6 fixed-scale work

Fixed-scale metadata retains M and D. Row transport still uses IEEE bytes. The
binlog metadata carries the floating-point width, not M and D. Saved target
schema supplies these attributes, as it does for other absent source metadata.
No codec or SQLite schema change is needed.

Default comparison follows `Field_real::truncate` and the fixed-format metadata
presentation. It does not replace the original default expression sent to MySQL.
The local 5.7.42 and 8.4.8 probes produced matching defaults for FLOAT(10,2),
DOUBLE(20,6), FLOAT(30,20), DOUBLE(200,0), and a value rounded to zero.

The selected unit tests include fixed-scale schema reload and reconstruction of
row values from retained relay bytes. The shared live and bootstrap cases check
rounding, defaults, NULL, signed and unsigned values, large ranges, ADD, MODIFY,
primary-key changes, UPDATE and DELETE. See [beta.6](beta.6.md) for final results.

For FLOAT(M,D), a legal decimal endpoint can round outward in binary32. For
example, FLOAT(8,2) stores 999999.99 as 1000000. Native row apply copies these
bits, but a prepared SQL parameter of 1000000 fails strict range checking.
Write expressions bound the SQL input to the declared decimal endpoints. The
target then stores the same FLOAT bits. Validation rejects values outside the
rounded storage endpoints. Key predicates compare the stored value after promotion to DOUBLE. This avoids
the range shortcut used by UPDATE and DELETE for rounded FLOAT endpoints. It can
require a table scan when a primary key includes a fixed-scale FLOAT column.
Plain FLOAT/DOUBLE and fixed-scale DOUBLE key predicates remain unchanged.
`matrix-floatbounds` and its bootstrap case check both signs, unsigned values,
primary-key updates and DELETE at these boundaries. Strict SQL mode remains on.
