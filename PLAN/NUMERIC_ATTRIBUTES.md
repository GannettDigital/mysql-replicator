# Numeric attributes

Status: beta.6 implementation. Full release qualification remains separate from
the selected numeric cases.

ZEROFILL implies UNSIGNED on integer, DECIMAL, FLOAT and DOUBLE columns. Integer
display widths remain part of the saved schema when ZEROFILL is present. A
width limits display padding; it does not limit the stored integer range.
For example, TINYINT(1) ZEROFILL can store 255.

MySQL assigns a default width when an integer declaration omits it or uses zero.
The unsigned widths are 3, 5, 8, 10 and 20 for TINYINT through BIGINT. Both pinned
server versions produced these forms in the local metadata probes. Explicit
SIGNED does not add a stored attribute. YEAR modifiers normalize to YEAR because
native metadata does not retain them as separate unsigned or ZEROFILL attributes.

Default metadata can contain leading zero padding. The applier compares its
numeric value. DECIMAL before-image reads remove display padding with exact
string operations. They do not convert through floating point. Binary integer
and floating-point parameters remain unchanged. No SQLite schema change is
needed; the existing column type string retains the display width and modifiers.

The original DDL still goes to MySQL. The applier does not rewrite engine clauses
or waive native SQL errors. DOUBLE(p) without a scale failed the syntax probes on
both 5.7.42 and 8.4.8. FLOAT(p) remains the separate native binary-precision form.
Floating-point AUTO_INCREMENT is supported on the two 5.7-to-5.7 profiles.
MySQL 5.7 accepts FLOAT, DOUBLE, fixed-scale forms and UNSIGNED forms. MySQL 8.4
rejects this attribute with error 1063. The applier does not remove the attribute
or substitute another column type. The source or target version limit stays
separate from the positive 5.7 support cases.

Branch `beta/6/09-legacy-floating-auto-increment` uses the normal binary floating
parameters. Every row contains the source-generated key. The target does not
generate a replacement value. The shared live and bootstrap cases check generated
values, explicit zero, a fractional key, an explicit high key, following generated
values, ALTER, UPDATE and DELETE. Profile-specific native exclusions appear in the
lab inventory and apply to both the live and bootstrap runners.

The shared `zerofill` cases check live CREATE, bootstrap discovery, defaults,
unsigned boundaries, display-width changes, ADD/MODIFY, UPDATE, DELETE and
saved-schema restart. Unit tests check metadata normalization, width/range
separation and reconstruction of ZEROFILL schemas and values from the relay.
See [beta.6](beta.6.md) for final results.

Native references are `Create_field::init`, `Field_num::prepend_zeros`, and the
numeric `sql_type` methods in the pinned 5.7 `sql/field.cc`, plus 8.4
`sql/create_field.cc` and `sql/field.cc`.
