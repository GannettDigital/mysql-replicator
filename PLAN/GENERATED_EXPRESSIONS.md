# Generated expression syntax and metadata

Status: implementation on `beta/6/33-generated-syntax`. Selected live checks passed on all four profiles. This is not a full expression or partition qualification claim.

## Parser boundary

`MySQLSyntax` now parses CASE, BETWEEN, IN, IS, LIKE, REGEXP, bit operators,
byte constants, exponent numbers, intervals and special built-in syntax. It
returns typed nodes. The parser checks SQL modes for `||` and `NOT` precedence.
It limits both parser recursion and the depth of the resulting tree.

The applier formats those nodes for schema comparison. It keeps the source SQL
bytes for execution. The native target checks function eligibility. There is no
application-maintained list of permitted deterministic function names. Successful
syntax parsing does not mean that a target accepts a function in a generated
column, default or partition expression.

The unfinished string-producing parser in `beta/6/30-generated-expressions` is
not imported. The new implementation extends the independent syntax target and
uses its existing build layer and isolated coverage checks.

## Saved failure and native behavior

The earlier run `20261015T020003Z-36f462f9` stopped with a target after-schema
mismatch. Its support bundle and schema comparison show that native 5.7 prints
`n IS NULL` as `isnull(n)`. Native 8.4 prints the IS form. Native also prints
negated comparisons with the inverse operator. The applier now compares these
forms through typed nodes. It does not edit executable SQL to those spellings.

Native probes on 5.7.42 also confirm SUBSTRING as `substr`, DATE_ADD as an
interval expression, numeric leading-zero removal, and retained exponent
notation. The local upstream references are `sql/sql_yacc.yy` expression
precedence and productions, and `sql/item_cmpfunc.cc` predicate printing.

The harness comparison remains independent of the production parser. It maps
only the exact IS NULL and TRIM spellings observed for this fixture. It retains
raw metadata snapshots. It compares generated row values after INSERT, UPDATE,
DELETE, ALTER, CREATE LIKE and restart.

## Checks and remaining work

The isolated syntax suite has 21 tests and 99.50% executable line coverage
(600/603 lines) on macOS. The selected syntax, apply and lab unit run passed 440
tests before the narrow harness comparison change. Record the final live and
unit results below after that change passes.

This increment does not complete all SQL expression forms, partition syntax,
SQL-mode combinations or cross-version evaluation rules. Those remain catalog
requirements. Do not mark the broad generated-expression requirement qualified
from one shared fixture.

## Combined fixed-input confirmation

Run `20261015T073916Z-20bde8e4` passed at stack commit `735d35b`. It ran
21 applicable charset, generated-expression and geometry-prefix cases across
the four profiles. Three cases were excluded for native version restrictions.
The outer lab result passed. All 421 build inputs stayed unchanged. The
build-input digest is
`a1782ef199a53cf7e0991118ce527af8ea37a84dd158574bef32c58bf045b82d`.
This is selected-case evidence, not full feature or release qualification.
