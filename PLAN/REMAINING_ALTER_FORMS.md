# Additional ALTER forms

Branch: `beta/6/63-alter-forms`.

## Column renames

MySQL 5.7 has no RENAME COLUMN syntax. The applier reads the current target
SHOW CREATE TABLE and changes each RENAME COLUMN clause to CHANGE COLUMN.
It retains the native column definition, including defaults, generated
expressions and comments. It makes inherited text encoding explicit. This
prevents a table-default change in the same ALTER from changing column encoding.

The helper in MySQLSyntax identifies column definition ranges. It does not
predict schema changes. ReplicatorApply performs the translation and validates
the resulting schema through the existing CHANGE path. The translated SQL uses
the source client charset. An exact round trip is required for non-UTF-8 text.

Failure reports retain source SQL and target SQL. The DDL intent contains the
SQL sent to the target. Existing expression-dependency and FK checks still
apply. There is no automatic retry after an uncertain DDL result.

## Other forms

The parser accepts ORDER BY and WITH/WITHOUT VALIDATION. It also accepts physical
table options for compression, encryption, tablespaces, storage, directories,
connection strings, password, merge-table lists and insert method. It sends the
original options to MySQL. The target checks engine, plugin and filesystem rules.
The existing engine contract still applies. This does not implement external
file transfer, tablespace import or server administration.

MySQL 8.4 options AUTOEXTEND_SIZE, ENGINE_ATTRIBUTE, SECONDARY_ENGINE_ATTRIBUTE
and SECONDARY_ENGINE have specific errors on 5.7 targets.

## Checks

The isolated syntax suite passes 41 tests, with 99.31% line coverage.
Eight focused apply tests pass after the encoding-placement fix.
The shared cases `ddl-compat-column-renames` and `ddl-compat-alter-options` check
native results, later DML, saved-state restart and offline replay.

The first forward run passed `ddl-compat-primary-key-parts`. It then found an
invalid position for CHARACTER SET in translated CHANGE SQL. Its support bundle
retains the pending intent and unchanged checkpoint. The fix places the charset
after the column type. The repeat run applied the rename and encoding changes. It then found invalid
clause order in the test source SQL: native MySQL requires ORDER BY after the
other ALTER clauses. The fixture now uses that order. The final forward repeat passes both shared cases, including live apply,
restart and offline replay. It also checks SHOW CREATE output with an explicit
charset but no collation. The translation inserts the missing collation after
the charset clause.
Full release qualification remains assigned to GitHub.

The first physical-options fixture returned native MyISAM error 1031 for
compression/encryption. The corrected fixture tests those options only on
InnoDB. MyISAM tests STATS_SAMPLE_PAGES, PASSWORD, ordering and validation.
The failed bundle retains a pending intent with no new table schema. The
applier does not remove unsupported engine options.

Final passing runs: forward `20261016T180509Z-25434f85` (23 steps), and
reverse `20261016T180825Z-69588c2c` (12 steps for InnoDB options).
